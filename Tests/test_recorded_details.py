"""Public fixtures for message origin, typed parameters and subsystem fields."""
import builtins
import contextlib
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import numpy as np

sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources')]
import analyzer
import flight_data
import library_repository as repository
import library_reports as reports
from fixture_ulog import record, synthetic_ulog


class RecordedDetailsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-recorded-details-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.file = self.root / 'public.ulg'
        binary = synthetic_ulog(samples=8)
        key = b'int32_t TEST_COUNT'
        binary = binary[:16] + record('P', bytes([len(key)]) + key + struct.pack('<i', 7)) + binary[16:]
        binary += record('C', struct.pack('<BHQ', 52, 42, 1_100_000) + b'Synthetic GPS warning')
        key = b'float TEST_PARAM'
        binary += record('P', bytes([len(key)]) + key + struct.pack('<f', 2.5))
        key = b'int32_t TEST_COUNT'
        binary += record('P', bytes([len(key)]) + key + struct.pack('<i', 8))
        binary += record('O', struct.pack('<H', 375))
        self.file.write_bytes(binary)
        self.database = self.root / 'library.sqlite'
        self.log = analyzer.scan(self.file, self.database, skip_snapshot=True)
        db = analyzer.open_database(self.database, read_only=True)
        try: self.identity = db.execute('SELECT id FROM logs').fetchone()[0]
        finally: db.close()

    @contextlib.contextmanager
    def evicted_source(self, changed_signature=True):
        """Simulate metadata-only iCloud eviction; any hydration attempt fails."""
        actual = self.file.stat()
        attributes = {name: getattr(actual, name) for name in dir(actual) if name.startswith('st_')}
        attributes['st_flags'] = getattr(actual, 'st_flags', 0) | 0x40000000
        if changed_signature:
            attributes['st_ctime_ns'] += 1
        placeholder = SimpleNamespace(**attributes)
        original_stat, original_open, original_io_open = Path.stat, builtins.open, io.open
        attempts = []

        def metadata(path, *args, **kwargs):
            return placeholder if path == self.file else original_stat(path, *args, **kwargs)

        def guarded(original):
            def open_file(path, *args, **kwargs):
                if not isinstance(path, int) and Path(path) == self.file:
                    attempts.append(str(path))
                    raise AssertionError('A dataless ULog must never be opened to hydrate it.')
                return original(path, *args, **kwargs)
            return open_file

        with patch.object(Path, 'stat', metadata), patch.object(analyzer.sys, 'platform', 'darwin'), \
             patch.object(builtins, 'open', guarded(original_open)), patch.object(io, 'open', guarded(original_io_open)):
            yield placeholder
        self.assertEqual(attempts, [])

    def test_dataless_sources_keep_queries_cached_details_and_report_complete_without_opening_ulog(self):
        saved_detail = analyzer.detail(self.identity, self.database)
        db = analyzer.open_database(self.database, read_only=True)
        self.addCleanup(db.close)
        before = repository.query(db, {'kind': 'logs', 'includeMessages': True}, read_only=True)['snapshot']['logs'][0]
        summary_bytes = db.execute('SELECT summary FROM logs WHERE id=?', (self.identity,)).fetchone()[0]
        detail_bytes = db.execute('SELECT summary FROM flight_details WHERE log_id=?', (self.identity,)).fetchone()[0]
        for changed_signature in [False, True]:
            with self.subTest(changed_signature=changed_signature), self.evicted_source(changed_signature):
                current = repository.query(db, {'kind': 'logs', 'includeMessages': True}, read_only=True)['snapshot']['logs'][0]
                self.assertEqual(current['messages'], before['messages'])
                self.assertEqual(current['sourcePaths'], before['sourcePaths'])
                self.assertEqual(current['id'], self.identity)
                observation = current['sourceAvailability'][0]
                self.assertEqual(observation['state'], 'inaccessible', 'An unchanged cached stat must not claim the placeholder is present.')
                self.assertIn('Finder', observation['detail'])
                self.assertIn('Télécharger', observation['detail'])
                cached = analyzer.detail(self.identity, self.database, read_only=True)
                self.assertEqual(cached['metadata']['detailCacheStatus'], 'current')
                for key in ['messages', 'sourcePaths', 'parameterDetails', 'dropouts', 'batteryDetails', 'gnssDetails']:
                    self.assertEqual(cached[key], saved_detail[key])
                capture = self.root / f'capture-{changed_signature}'
                destination = self.root / f'report-{changed_signature}'
                reports.capture_report(self.database, capture, {'options': {'includeCachedDetails': True}})
                result = reports.prepare_report(capture, destination)
                exported = json.loads((destination / 'rapport.json').read_text())['logs'][0]
                self.assertEqual(result['logCount'], 1)
                self.assertEqual(result['messageCount'], len(before['messages']))
                self.assertEqual(exported['messages'], before['messages'])
                self.assertEqual(exported['sourcePaths'], before['sourcePaths'])
                self.assertEqual(exported['parameterDetails'], saved_detail['parameterDetails'])
        self.assertEqual(db.execute('SELECT summary FROM logs WHERE id=?', (self.identity,)).fetchone()[0], summary_bytes)
        self.assertEqual(db.execute('SELECT summary FROM flight_details WHERE log_id=?', (self.identity,)).fetchone()[0], detail_bytes)

    def test_dataless_reanalysis_keeps_previous_cache_and_uncached_detail_explains_finder(self):
        with self.evicted_source():
            with self.assertRaisesRegex(ValueError, 'Finder.*Télécharger'):
                analyzer.detail(self.identity, self.database)
        original = analyzer.detail(self.identity, self.database)
        db = analyzer.open_database(self.database)
        try:
            db.execute('UPDATE flight_details SET parser_version=? WHERE log_id=?', ('1.3.0', self.identity))
            db.execute('UPDATE logs SET parser_version=? WHERE id=?', ('1.3.0', self.identity))
            db.commit()
            saved = db.execute('SELECT summary FROM logs WHERE id=?', (self.identity,)).fetchone()[0]
        finally:
            db.close()
        with self.evicted_source():
            previous = analyzer.detail(self.identity, self.database)
            self.assertEqual(previous['metadata']['detailCacheStatus'], 'previous')
            self.assertEqual(previous['metadata']['detailParserVersion'], '1.3.0')
            self.assertEqual(previous['messages'], original['messages'])
            self.assertEqual(previous['sourceAvailability'][0]['state'], 'inaccessible')
            result = analyzer.refresh_analysis(self.database)
            self.assertEqual(result['reanalyzed'], 0)
            self.assertEqual(result['unavailable'], 1)
        db = analyzer.open_database(self.database, read_only=True)
        try:
            self.assertEqual(db.execute('SELECT summary FROM logs WHERE id=?', (self.identity,)).fetchone()[0], saved)
        finally:
            db.close()

    def test_dataless_digest_and_direct_analysis_refuse_open_even_without_python_flag_constant(self):
        with self.evicted_source(), patch.object(analyzer, 'stat_module', SimpleNamespace()):
            with self.assertRaisesRegex(OSError, 'Finder.*Télécharger'):
                analyzer.digest_file(self.file)
            with self.assertRaisesRegex(OSError, 'Finder.*Télécharger'):
                analyzer.analyze_file(self.file, self.root, digest=self.identity)
        self.assertEqual(analyzer.digest_file(self.file), self.identity, 'Hydrated sources must still verify normally.')

    def test_identical_normal_and_tagged_records_keep_distinct_origins_in_pages(self):
        db = analyzer.open_database(self.database, read_only=True)
        try:
            page = repository.query(db, {'kind': 'messages'}, read_only=True)
            items = [item['message'] for item in page['occurrences'] if item['message']['text'] == 'Synthetic GPS warning']
        finally: db.close()
        self.assertEqual(len(items), 2)
        self.assertEqual(len({item['id'] for item in items}), 2)
        self.assertEqual({item['source'] for item in items}, {'ULog:logging', 'ULog:logging_tagged'})
        self.assertEqual({item['tag'] for item in items}, {None, 42})
        self.assertEqual({item['rawTimestamp'] for item in items}, {1_100_000})
        self.assertEqual({item['rawLogLevel'] for item in items}, {52})
        self.assertEqual({item['sourceIndex'] for item in items}, {0})

    def test_typed_parameter_changes_preserve_values_previous_and_timing(self):
        detail = analyzer.detail(self.identity, self.database)
        values = detail['parameterDetails']
        initial = {item['name']: item for item in values['initial']}
        self.assertEqual(initial['TEST_COUNT']['value'], 7)
        self.assertEqual(initial['TEST_COUNT']['type'], 'int')
        self.assertEqual(initial['TEST_PARAM']['value'], 1.25)
        self.assertEqual(initial['TEST_PARAM']['type'], 'float')
        changes = {item['name']: item for item in values['changes']}
        self.assertEqual(changes['TEST_PARAM']['previousValue'], 1.25)
        self.assertEqual(changes['TEST_PARAM']['value'], 2.5)
        self.assertEqual(changes['TEST_COUNT']['previousValue'], 7)
        self.assertEqual(changes['TEST_COUNT']['value'], 8)
        self.assertEqual(changes['TEST_COUNT']['rawTimestamp'], 1_700_000)
        self.assertAlmostEqual(changes['TEST_COUNT']['timeSeconds'], .7)
        self.assertEqual(changes['TEST_COUNT']['timing'], 'last_data_timestamp')
        self.assertTrue(changes['TEST_COUNT']['changed'])
        self.assertIn('declared ULog parameter type is not retained', changes['TEST_COUNT']['typeSource'])
        self.assertEqual(detail['parameters']['TEST_COUNT'], '7')  # legacy display remains compatible
        json.dumps(values, allow_nan=False)

    def test_dropouts_keep_occurrences_raw_duration_and_recording_provenance(self):
        detail = analyzer.detail(self.identity, self.database)
        self.assertEqual(len(detail['dropouts']), 1)
        item = detail['dropouts'][0]
        self.assertEqual(item['rawTimestamp'], 1_700_000)
        self.assertEqual(item['durationMilliseconds'], 375)
        self.assertEqual(item['durationSeconds'], .375)
        self.assertEqual(item['source'], 'ULog:dropout')
        self.assertEqual(item['timing'], 'last_data_timestamp')
        self.assertAlmostEqual(item['timeSeconds'], .7)
        self.assertIn('does not prove a radio outage', item['interpretation'])

    def test_invalid_parameter_timestamp_and_type_changes_are_preserved(self):
        ulog = SimpleNamespace(initial_parameters={'A': 1}, changed_parameters=[
            (float('nan'), 'A', 1.0), (2_000_000, 'UNSEEN', b'\x00\xff')])
        value = flight_data.parameter_details(ulog, 1)
        self.assertIsNone(value['changes'][0]['timeSeconds'])
        self.assertEqual(value['changes'][0]['rawTimestamp']['encoding'], 'nonfinite')
        self.assertEqual(value['changes'][0]['previousType'], 'int')
        self.assertTrue(value['changes'][0]['changed'])
        self.assertEqual(value['changes'][1]['value'], {'encoding': 'hex', 'value': '00ff'})
        self.assertIsNone(value['changes'][1]['previousValue'])
        json.dumps(value, allow_nan=False)

    def test_battery_fields_units_sentinels_serials_and_instances_remain_source_data(self):
        dataset = SimpleNamespace(name='battery_status', multi_id=2, data={
            'timestamp': np.array([1, 2, 3, 4]) * 1_000_000, 'connected': np.array([1, 1, 1, 0]),
            'voltage_cell_v[0]': np.array([0, 4.1, np.nan, 4.2]), 'remaining': np.array([-.1, .5, 1, .9]),
            'serial_number': np.array([99, 99, 100, 100], dtype=np.uint16), 'cycle_count': np.array([0, 3, 3, 3]),
            'capacity': np.array([2000, 2000, 2000, 2000]), 'manufacturer_field': np.array([7, 8, 9, 10])})
        result = flight_data.subsystem_details(SimpleNamespace(data_list=[dataset]), {'battery_status'}, 1)
        self.assertEqual(result['instances'][0]['instance'], 2)
        fields = {item['field']: item for item in result['instances'][0]['fields']}
        cell = fields['voltage_cell_v[0]']
        self.assertEqual(cell['unit'], 'V')
        self.assertEqual(cell['validSampleCount'], 1)
        self.assertEqual(cell['lastValue'], 4.1)
        self.assertEqual(cell['lastRawValue'], 4.2)
        self.assertEqual(fields['remaining']['lastValue'], 100)
        self.assertEqual(fields['remaining']['rawUnit'], 'fraction')
        self.assertEqual(fields['remaining']['unit'], '%')
        self.assertEqual(fields['serial_number']['firstValue'], 99)
        self.assertEqual(fields['serial_number']['lastValue'], 100)
        self.assertIn('not controller or fleet identifiers', result['interpretation'])
        self.assertEqual(fields['cycle_count']['minimum'], 0)
        self.assertEqual(fields['cycle_count']['unit'], 'cycles')
        self.assertEqual(fields['capacity']['unitStatus'], 'unknown')
        self.assertEqual(fields['capacity']['lastValue'], 2000)
        self.assertEqual(fields['manufacturer_field']['unit'], '')
        json.dumps(result, allow_nan=False)

    def test_gnss_receivers_and_unknown_rtcm_fields_are_not_combined_or_relabelled(self):
        first = SimpleNamespace(name='sensor_gps', multi_id=0, data={'timestamp': np.array([1_000_000]),
            'lat': np.array([123456789]), 'rtcm_injection_rate': np.array([2.5]), 'manufacturer_rtcm_age': np.array([42])})
        second = SimpleNamespace(name='sensor_gps', multi_id=1, data={'timestamp': np.array([1_000_000]),
            'latitude_deg': np.array([10.5]), 'rtcm_crc_failed': np.array([True])})
        result = flight_data.subsystem_details(SimpleNamespace(data_list=[first, second]), {'sensor_gps'}, 1)
        self.assertEqual([item['instance'] for item in result['instances']], [0, 1])
        fields = {item['field']: item for item in result['instances'][0]['fields']}
        self.assertAlmostEqual(fields['lat']['lastValue'], 12.3456789)
        self.assertEqual(fields['lat']['lastRawValue'], 123456789)
        self.assertEqual(fields['rtcm_injection_rate']['unit'], 'Hz')
        self.assertEqual(fields['manufacturer_rtcm_age']['unitStatus'], 'unknown')
        self.assertEqual(fields['manufacturer_rtcm_age']['lastValue'], 42)
        self.assertNotIn('latitude_deg', fields)

    def test_missing_subsystem_fields_remain_absent_and_large_integers_exact(self):
        empty = flight_data.subsystem_details(SimpleNamespace(data_list=[]), {'battery_status'}, 0)
        self.assertEqual(empty['instances'], [])
        dataset = SimpleNamespace(name='battery_status', multi_id=0,
            data={'manufacturer_id': np.array([2 ** 63 + 1], dtype=np.uint64)})
        value = flight_data.subsystem_details(SimpleNamespace(data_list=[dataset]), {'battery_status'}, 0)
        item = value['instances'][0]['fields'][0]
        self.assertEqual(item['lastValue'], 2 ** 63 + 1)
        self.assertEqual(json.loads(json.dumps(value))['instances'][0]['fields'][0]['lastValue'], 2 ** 63 + 1)
        self.assertIsNone(item['lastTimeSeconds'])

    def test_previous_13_cache_without_source_does_not_invent_new_details(self):
        detail = analyzer.detail(self.identity, self.database)
        for key in ('parameterDetails', 'dropouts', 'batteryDetails', 'gnssDetails'):
            detail.pop(key, None)
        db = analyzer.open_database(self.database)
        try:
            db.execute('UPDATE flight_details SET parser_version=?,summary=? WHERE log_id=?',
                       ('1.3.0', json.dumps(detail), self.identity))
            db.commit()
        finally: db.close()
        self.file.unlink()
        saved = analyzer.detail(self.identity, self.database)
        self.assertEqual(saved['metadata']['detailCacheStatus'], 'previous')
        self.assertEqual(saved['metadata']['detailParserVersion'], '1.3.0')
        for key in ('parameterDetails', 'dropouts', 'batteryDetails', 'gnssDetails'):
            self.assertNotIn(key, saved)


if __name__ == '__main__': unittest.main()
