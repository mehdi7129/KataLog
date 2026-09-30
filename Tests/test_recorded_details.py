"""Public fixtures for message origin, typed parameters and subsystem fields."""
import json
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
import numpy as np

sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources')]
import analyzer
import flight_data
import library_repository as repository
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
