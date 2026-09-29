"""GPS units/gaps/budgets and detail-cache invariants independent of network."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
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


def sensor(stamps, modern=False, instance=0, **values):
    n = len(stamps)
    data = {'timestamp': np.array(stamps)*1e6, 'fix_type': np.full(n, 6)}
    if modern:
        data.update(latitude_deg=np.full(n, 48.1), longitude_deg=np.full(n, 2.3), altitude_msl_m=np.full(n, 125.5))
    else:
        data.update(lat=np.full(n, 481000000), lon=np.full(n, 23000000), alt=np.full(n, 125500))
    data.update({k: np.array(v) for k, v in values.items()})
    return SimpleNamespace(name='sensor_gps', multi_id=instance, data=data)


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
        if not originals:self.skipTest('Set KATALOG_PRIVATE_FIXTURES to the external reference corpus')
        self.file=self.source/'flight.ulg';shutil.copyfile(originals[0],self.file)
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
            self.assertEqual(analyzer.detail(self.log['id'],self.db),detail)
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

if __name__=='__main__':unittest.main()
