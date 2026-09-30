"""GPS units/gaps/budgets and detail-cache invariants independent of network."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import numpy as np

RESOURCE = Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'
sys.path.insert(0, str(RESOURCE))
import flight_data
import analyzer
from fixture_ulog import synthetic_ulog


def sensor(stamps, modern=False, instance=0, **values):
    n = len(stamps)
    data = {'timestamp': np.array(stamps)*1e6, 'fix_type': np.full(n, 6)}
    if modern:
        data.update(latitude_deg=np.full(n, 48.1), longitude_deg=np.full(n, 2.3), altitude_msl_m=np.full(n, 125.5))
    else:
        data.update(lat=np.full(n, 481000000), lon=np.full(n, 23000000), alt=np.full(n, 125500))
    data.update({k: np.array(v) for k, v in values.items()})
    return SimpleNamespace(name='sensor_gps', multi_id=instance, data=data)


def anonymous_ulog():
    """Shareable, valid ULog with entirely invented positions and no UUID."""
    def record(kind, payload):
        return struct.pack('<HB', len(payload), ord(kind)) + payload

    data = analyzer.ULog.HEADER_BYTES + bytes([1]) + struct.pack('<Q', 1_000_000)
    data += record('F', b'sensor_gps:uint64_t timestamp;int32_t lat;int32_t lon;int32_t alt;uint8_t fix_type;')
    parameter = b'float TEST_PARAM'
    data += record('P', bytes([len(parameter)]) + parameter + struct.pack('<f', 1.25))
    data += record('A', struct.pack('<BH', 0, 1) + b'sensor_gps')
    for index in range(3):
        data += record('D', struct.pack('<HQiiiB', 1, (index + 1) * 1_000_000,
                                       10_000_000 + index, 20_000_000 + index, 100_000, 6))
    data += record('L', struct.pack('<BQ', 52, 2_000_000) + b'Synthetic GPS warning')
    return data


class TrackTests(unittest.TestCase):
    def test_old_and_new_units_have_same_coordinates_and_relative_time(self):
        old = flight_data.extract_track([sensor([10, 11])], 10, 20)
        new = flight_data.extract_track([sensor([10, 11], modern=True)], 10, 20)
        for a, b in zip(old['points'], new['points']):
            for key in ('latitude', 'longitude', 'altitudeMeters', 'timeSeconds'):
                self.assertAlmostEqual(a[key], b[key])
        self.assertEqual(old['points'][1]['timeSeconds'], 1)
        self.assertAlmostEqual(old['points'][0]['altitudeMeters'], 125.5)

    def test_invalid_fix_coordinate_gap_and_timestamp_reversal_split_segments(self):
        d = sensor([0,1,2,3,4,5,30,29,31], fix_type=[6,6,0,6,6,6,6,6,6],
                   lat=[481000000,481000000,0,481000000,999000000,481000000,481000000,481000000,481000000])
        track = flight_data.extract_track([d], 0, 40)
        self.assertEqual(track['rejectedPointCount'], 3)
        self.assertEqual([p['segment'] for p in track['points']], [0,0,1,2,3,4])
        self.assertEqual([p['timeSeconds'] for p in track['points']], [0,1,3,5,30,31])

    def test_missing_fix_and_extrapolated_positions_are_not_shown(self):
        d = sensor([0,1]); del d.data['fix_type']
        self.assertIsNone(flight_data.extract_track([d], 0, 2))
        self.assertIsNone(flight_data.extract_track([sensor([0,1], fix_type=[0,8])], 0, 2))
        self.assertIsNone(flight_data.extract_track([], 0, 2))

    def test_zero_latitude_or_longitude_is_not_a_missing_value_with_valid_fix(self):
        d = sensor([0,1], modern=True, latitude_deg=[0,48], longitude_deg=[2,0])
        self.assertEqual(len(flight_data.extract_track([d], 0, 2)['points']), 2)

    def test_selects_one_receiver_with_most_valid_points_without_concatenation(self):
        invalid = sensor([0,1,2], instance=0, fix_type=[0,0,0])
        valid = sensor([0,1], instance=1)
        result = flight_data.extract_track([invalid,valid], 0, 3)
        self.assertIn('[1]', result['source']); self.assertEqual(result['originalPointCount'], 2)

    def test_preview_is_bounded_and_preserves_segment_boundaries(self):
        track = flight_data.extract_track([sensor(list(range(1000))+list(range(1100,2100)))], 0, 2200)
        preview = flight_data.track_preview(track)
        self.assertEqual(len(preview['points']), 256)
        self.assertEqual({p['segment'] for p in preview['points']}, {0,1})
        self.assertTrue({0,999,1100,2099}.issubset({p['timeSeconds'] for p in preview['points']}))
        self.assertEqual(preview['rejectedPointCount'], 0)
        many = [dict(timeSeconds=i,segment=i) for i in range(1000)]
        self.assertEqual(len(flight_data.bounded_points(many,256)),256)

    def test_alerts_use_actual_nearby_samples_never_bridge_gaps(self):
        track = flight_data.extract_track([sensor([0,1,2,20,21])], 0, 30)
        messages = [{'timestampSeconds':t} for t in [0.6,3,19,20.4,-1]]
        flight_data.position_messages(messages,track)
        self.assertEqual(messages[0]['position']['timeSeconds'],1)
        self.assertEqual(messages[3]['position']['timeSeconds'],20)
        for i in (1,2,4): self.assertNotIn('position',messages[i])

    def test_fleet_preview_keeps_alert_positions_without_loading_detail(self):
        log = {'durationSeconds': 1000, 'coverage': [],
               'messages': [{'timestampSeconds': 333.1}]}
        ulog = SimpleNamespace(start_timestamp=0, data_list=[sensor(list(range(1000)))])
        flight_data.enrich(log, ulog)
        self.assertEqual(len(log['track']['points']), 256)
        self.assertEqual(log['messages'][0]['position']['timeSeconds'], 333)
        self.assertNotIn('parameters', log)
        self.assertNotIn('topicDetails', log)


class DetailTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='katalog-details-'); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.source=self.root/'source';self.source.mkdir()
        private_fixtures=os.environ.get('KATALOG_PRIVATE_FIXTURES')
        originals=sorted(Path(private_fixtures).expanduser().rglob('*.ulg')) if private_fixtures else []
        self.file=self.source/'flight.ulg'
        if originals: shutil.copyfile(originals[0],self.file)
        else: self.file.write_bytes(synthetic_ulog())
        self.db=self.root/'library.sqlite'
        self.log=analyzer.scan(self.source,self.db)['logs'][0]

    def test_summary_is_small_and_full_detail_is_cached_on_demand(self):
        self.assertLessEqual(len(self.log['track']['points']),256)
        self.assertNotIn('parameters',self.log)
        detail=analyzer.detail(self.log['id'],self.db)
        self.assertGreater(len(detail['track']['points']),len(self.log['track']['points']))
        self.assertLessEqual(len(detail['track']['points']),4096)
        self.assertTrue(detail['parameters']);self.assertTrue(detail['topicDetails'])
        self.assertTrue(all(isinstance(v,str) for v in detail['parameters'].values()))
        # The immutable detail remains usable after loss of its source.
        self.file.unlink()
        with patch.object(analyzer,'analyze_file',side_effect=AssertionError('cached detail reparsed')):
            cached = analyzer.detail(self.log['id'],self.db)
            for key in ('id', 'droneID', 'parameters', 'parameterChanges', 'topicDetails', 'track', 'messages', 'metrics'):
                self.assertEqual(cached[key], detail[key])
            self.assertEqual(cached['sourceAvailability'][0]['state'], 'missing')
        db=analyzer.open_database(self.db)
        try: self.assertNotIn('parameters',analyzer.snapshot(db)['logs'][0])
        finally: db.close()

    def test_cached_analysis_error_is_reparsed_on_retry(self):
        db=analyzer.open_database(self.db)
        broken=dict(self.log, status='error', issues=['temporary parse failure'])
        analyzer.remember_log(db,broken);db.commit();db.close()
        with patch.object(analyzer,'analyze_file',wraps=analyzer.analyze_file) as parse:
            result=analyzer.scan(self.source,self.db)
        self.assertEqual(parse.call_count,1)
        self.assertEqual(result['logs'][0]['status'],'ok')
        self.assertEqual(result['importStats']['unchanged'],0)

    def test_changed_source_cannot_be_mistaken_for_original_log(self):
        self.file.write_bytes(b'other content')
        with self.assertRaisesRegex(ValueError,'absente ou modifiée'):
            analyzer.detail(self.log['id'],self.db)

    def test_parser_upgrade_reanalyzes_without_duplicate_identity(self):
        with patch.object(analyzer,'PARSER_VERSION','next-parser'):
            again=analyzer.scan(self.source,self.db)
        self.assertEqual(len(again['logs']),1)
        self.assertEqual(again['logs'][0]['id'],self.log['id'])
        self.assertEqual(again['logs'][0]['metadata']['parserVersion'],'next-parser')


class TelemetryIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-telemetry-integration-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'sources'; self.source.mkdir()
        self.file = self.source / 'public.ulg'; self.file.write_bytes(synthetic_ulog())
        self.database = self.root / 'library.sqlite'
        self.log = analyzer.scan(self.source, self.database)['logs'][0]

    def test_import_keeps_new_details_lazy_and_exact_dictionary_available_in_detail(self):
        self.assertNotIn('metadataDetails', self.log)
        self.assertNotIn('telemetryCatalogue', self.log)
        detail = analyzer.detail(self.log['id'], self.database)
        self.assertEqual(detail['eventDictionary']['status'], 'ready')
        self.assertEqual(detail['events'][0]['eventID'], (1 << 24) | 123)
        self.assertEqual(detail['events'][0]['argumentsHex'][:8], '00008041')
        self.assertIn('fixture_unknown', detail['metadataDetails']['unknownInfo'])
        self.assertTrue(detail['telemetryCatalogue'])

    def test_series_recipe_is_bounded_total_missing_fields_explicit_and_cache_unchanged(self):
        result = analyzer.telemetry_series(self.log['id'], self.database, {'seriesVersion': 1, 'recipe': 'battery', 'budget': 24})
        self.assertEqual(len(result['series']), 2)
        self.assertEqual(result['missingFields'], ['battery_status[0].remaining', 'battery_status[0].discharged_mah'])
        self.assertLessEqual(result['displayedPointCount'], 24)
        self.assertEqual(result['logID'], self.log['id'])
        db = analyzer.open_database(self.database, read_only=True)
        try: self.assertEqual(db.execute('SELECT COUNT(*) FROM flight_details').fetchone()[0], 0)
        finally: db.close()

    def test_field_series_window_and_cli_flags(self):
        result = analyzer.telemetry_series(self.log['id'], self.database, {'topic': 'battery_status', 'field': 'voltage_v', 'timeFrom': .2, 'timeTo': .5, 'budget': 10})
        self.assertTrue(result['series'][0]['points'])
        self.assertTrue(all(.2 <= point['timeSeconds'] <= .5 for point in result['series'][0]['points']))
        output = self.root / 'series.json'
        self.assertEqual(analyzer.main(['series', '--log-id', self.log['id'], '--database', str(self.database), '--recipe', 'gnss', '--budget', '32', '--output', str(output)]), 0)
        self.assertLessEqual(json.loads(output.read_text())['displayedPointCount'], 32)

    def test_read_only_detail_parses_without_persisting_cache(self):
        result = analyzer.detail(self.log['id'], self.database, read_only=True)
        self.assertEqual(result['status'], 'ok')
        db = analyzer.open_database(self.database, read_only=True)
        try: self.assertEqual(db.execute('SELECT COUNT(*) FROM flight_details').fetchone()[0], 0)
        finally: db.close()

    def test_skip_snapshot_uses_bounded_index_result_and_preserves_original(self):
        before = (self.file.read_bytes(), analyzer.stat_signature(self.file.stat()))
        with patch.object(analyzer, 'snapshot', side_effect=AssertionError('unbounded snapshot called')):
            result = analyzer.scan(self.source, self.database, skip_snapshot=True)
        self.assertEqual(result['logs'], [])
        self.assertEqual(result['importStats']['unchanged'], 1)
        self.assertGreater(result['revision'], 0)
        self.assertEqual(before, (self.file.read_bytes(), analyzer.stat_signature(self.file.stat())))

    def test_missing_or_mutated_source_series_cannot_show_wrong_content(self):
        self.file.write_bytes(synthetic_ulog(drone_name='Changed public fixture'))
        with self.assertRaisesRegex(ValueError, 'absente ou modifiée'):
            analyzer.telemetry_series(self.log['id'], self.database, {'recipe': 'battery'})

    def test_global_refresh_retains_unavailable_history_and_refreshes_exact_sha(self):
        db = analyzer.open_database(self.database)
        stale = dict(self.log)
        stale['metadata'] = dict(self.log['metadata'], parserVersion='previous')
        db.execute('UPDATE logs SET parser_version=?,summary=? WHERE id=?', ('previous', json.dumps(stale), self.log['id']))
        db.commit(); db.close()
        self.file.unlink()
        result = analyzer.refresh_analysis(self.database)
        self.assertEqual((result['total'], result['unavailable'], result['reanalyzed']), (1, 1, 0))
        self.file.write_bytes(synthetic_ulog())
        result = analyzer.refresh_analysis(self.database)
        self.assertEqual((result['total'], result['unavailable'], result['reanalyzed']), (1, 0, 1))
        db = analyzer.open_database(self.database, read_only=True)
        try:
            saved = json.loads(db.execute('SELECT summary FROM logs').fetchone()[0])
            self.assertEqual(saved['droneID'], self.log['droneID'])
            self.assertEqual(saved['metadata']['parserVersion'], analyzer.PARSER_VERSION)
        finally: db.close()
        self.file.unlink()
        with self.assertRaisesRegex(ValueError, 'absente ou modifiée'):
            analyzer.telemetry_series(self.log['id'], self.database, {'recipe': 'battery'})


class CanonicalDetailTests(unittest.TestCase):
    """Run without private logs: card identity, availability and cache upgrades."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-canonical-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.card = self.root / 'card'
        self.file = self.card / 'log' / '2030-01-01' / '00_00_00.ulg'
        self.file.parent.mkdir(parents=True)
        (self.card / 'data').mkdir()
        (self.card / 'data' / 'name.txt').write_text('Synthetic anonymous controller')
        self.file.write_bytes(anonymous_ulog())
        self.db = self.root / 'library.sqlite'
        self.summary = analyzer.scan(self.card, self.db)['logs'][0]

    def test_card_identity_and_provenance_remain_canonical_in_detail(self):
        self.assertTrue(self.summary['droneID'].startswith('card:'))
        value = analyzer.detail(self.summary['id'], self.db)
        for key in ('id', 'droneID', 'droneName', 'date', 'dateSource', 'fileName'):
            self.assertEqual(value[key], self.summary[key])
        self.assertTrue(value['parameters'])
        self.assertEqual(value['metadata']['detailCacheStatus'], 'current')
        self.assertEqual(value['sourceAvailability'][0]['state'], 'present')

    def test_legacy_cached_wrong_identity_is_repaired_even_without_source(self):
        value = analyzer.detail(self.summary['id'], self.db)
        value['droneID'] = 'unknown:' + self.summary['id']
        db = analyzer.open_database(self.db)
        try:
            db.execute('UPDATE flight_details SET summary=? WHERE log_id=?', (json.dumps(value), self.summary['id']))
            db.commit()
        finally:
            db.close()
        self.file.unlink()
        repaired = analyzer.detail(self.summary['id'], self.db)
        self.assertEqual(repaired['droneID'], self.summary['droneID'])
        self.assertEqual(repaired['parameters'], value['parameters'])

    def test_old_cached_detail_survives_parser_upgrade_after_source_loss(self):
        value = analyzer.detail(self.summary['id'], self.db)
        previous_version = analyzer.PARSER_VERSION
        self.file.unlink()
        with patch.object(analyzer, 'PARSER_VERSION', 'next-parser'):
            cached = analyzer.detail(self.summary['id'], self.db)
        self.assertEqual(cached['metadata']['detailCacheStatus'], 'previous')
        self.assertEqual(cached['metadata']['detailParserVersion'], previous_version)
        self.assertTrue(any('ne sont pas recalculées' in text for text in cached['coverage']))
        for key in ('id', 'droneID', 'parameters', 'parameterChanges', 'topicDetails', 'track', 'messages'):
            self.assertEqual(cached[key], value[key])
        db = analyzer.open_database(self.db)
        try:
            row = db.execute('SELECT parser_version FROM flight_details WHERE log_id=?', (self.summary['id'],)).fetchone()
            self.assertEqual(row[0], previous_version, 'Fallback must never relabel the old analysis as current.')
        finally:
            db.close()

    def test_new_parser_reanalyzes_when_verified_source_still_exists(self):
        analyzer.detail(self.summary['id'], self.db)
        with patch.object(analyzer, 'PARSER_VERSION', 'next-parser'):
            value = analyzer.detail(self.summary['id'], self.db)
        self.assertEqual(value['metadata']['detailCacheStatus'], 'current')
        self.assertEqual(value['metadata']['detailParserVersion'], 'next-parser')
        self.assertEqual(value['droneID'], self.summary['droneID'])

    def test_changed_source_uses_previous_cache_and_not_new_content(self):
        original = analyzer.detail(self.summary['id'], self.db)
        self.file.write_bytes(b'new and unrelated content')
        with patch.object(analyzer, 'PARSER_VERSION', 'next-parser'):
            value = analyzer.detail(self.summary['id'], self.db)
        self.assertEqual(value['metadata']['detailCacheStatus'], 'previous')
        self.assertEqual(value['messages'], original['messages'])
        self.assertEqual(value['sourceAvailability'][0]['state'], 'modified')

    def test_removed_source_is_visible_after_rescan_and_history_remains(self):
        self.file.unlink()
        snapshot = analyzer.scan(self.card, self.db)
        self.assertEqual(snapshot['importStats']['discovered'], 0)
        self.assertEqual(len(snapshot['logs']), 1)
        value = snapshot['logs'][0]
        self.assertEqual(value['sourcePaths'], self.summary['sourcePaths'])
        state = value['sourceAvailability'][0]
        self.assertEqual(state['state'], 'missing')
        self.assertTrue(state['checkedAt'].endswith('Z'))
        self.assertTrue(any('actuellement indisponible' in text for text in value['coverage']))

    def test_replaced_source_retains_original_path_in_availability(self):
        self.file.write_bytes(b'new content')
        snapshot = analyzer.scan(self.card, self.db)
        old = next(value for value in snapshot['logs'] if value['id'] == self.summary['id'])
        self.assertEqual(old['sourcePaths'], [])
        self.assertEqual(old['sourceAvailability'][0]['path'], str(self.file))
        self.assertEqual(old['sourceAvailability'][0]['state'], 'modified')

    def test_metadata_change_without_content_change_is_not_modified(self):
        self.file.touch()
        value = analyzer.source_availability(self.file, self.summary['id'])
        self.assertEqual(value['state'], 'present')

    def test_unmounted_volume_is_offline_not_deleted(self):
        path = Path('/Volumes/Synthetic-Test-Volume/log/flight.ulg')
        original_stat = Path.stat
        def missing_volume(target, *args, **kwargs):
            if str(target).startswith('/Volumes/Synthetic-Test-Volume'):
                raise FileNotFoundError('synthetic volume offline')
            return original_stat(target, *args, **kwargs)
        with patch.object(Path, 'stat', missing_volume):
            value = analyzer.source_availability(path, self.summary['id'])
        self.assertEqual(value['state'], 'offline')

    def test_permission_denied_is_inaccessible_not_missing(self):
        original_stat = Path.stat
        def denied(target, *args, **kwargs):
            if target == self.file:
                raise PermissionError('synthetic access denied')
            return original_stat(target, *args, **kwargs)
        with patch.object(Path, 'stat', denied):
            value = analyzer.source_availability(self.file, self.summary['id'])
        self.assertEqual(value['state'], 'inaccessible')

if __name__=='__main__':unittest.main()
