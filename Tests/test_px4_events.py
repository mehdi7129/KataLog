"""Exact firmware-artifact binding and raw PX4 event preservation."""
import hashlib
import io
import json
import lzma
from pathlib import Path
import struct
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import px4_events as events


def definition():
    return {'version': 2, 'components': {'1': {'namespace': 'synthetic',
            'enums': {'state_t': {'type': 'uint8_t', 'entries': {'2': {'description': 'ready'}}}},
            'event_groups': {'default': {'events': {'7': {'name': 'invented_voltage',
            'message': 'Voltage {1:.2} state {2}', 'description': 'Synthetic detail',
            'arguments': [{'type': 'float'}, {'type': 'state_t'}]}}},
            'health': {'events': {'8': {'name': 'invented_health', 'message': 'Synthetic health', 'arguments': []}}}}}}}


def dataset(instance=0, ids=None, levels=None, stamps=None):
    ids = [0x1000007, 0x1000008, 0x2000009] if ids is None else ids
    n = len(ids)
    args = struct.pack('<fB', 12.5, 2) + bytes(20)
    data = {'id': np.array(ids), 'timestamp': np.array([10_000_000 + i * 1000 for i in range(n)] if stamps is None else stamps),
            'log_levels': np.array([0x46] * n if levels is None else levels),
            'event_sequence': np.array([65535 if i == 0 else i - 1 for i in range(n)])}
    data.update({f'arguments[{i}]': np.full(n, value) for i, value in enumerate(args)})
    return SimpleNamespace(name='event', multi_id=instance, data=data)


def ulog(datasets=None, definitions=None, version_hash=True):
    payload = lzma.compress(json.dumps(definitions if definitions is not None else definition()).encode())
    return SimpleNamespace(data_list=[dataset()] if datasets is None else datasets,
        msg_info_dict={'metadata_events_sha256': hashlib.sha256(payload).hexdigest()} if version_hash else {},
        msg_info_multiple_dict={'metadata_events': [[payload[:20], payload[20:]]]}, payload=payload)


class EventTests(unittest.TestCase):
    def test_exact_embedded_dictionary_decodes_packed_arguments_all_groups(self):
        result = events.extract_events(ulog(), 10, {'ver_sw': 'invented'})
        self.assertEqual(result['dictionary']['status'], 'ready')
        first, health, unknown = result['events']
        self.assertEqual(first['message'], 'Voltage 12.50 state ready')
        self.assertEqual(first['argumentValues'], [12.5, 2])
        self.assertEqual(first['internalLevel'], 4)
        self.assertEqual(first['externalLevel'], 6)
        self.assertEqual(first['level'], 'WARNING')
        self.assertEqual(first['argumentsHex'], (struct.pack('<fB', 12.5, 2) + bytes(20)).hex())
        self.assertEqual(health['translationStatus'], 'translated')
        self.assertEqual(health['group'], 'health')
        self.assertEqual(unknown['translationStatus'], 'unknown')
        self.assertIsNone(unknown['message'])
        self.assertAlmostEqual(health['timeSeconds'], .001)

    def test_all_instances_protocol_disabled_external_and_sequence_wrap_retained(self):
        result = events.extract_events(ulog([dataset(0, levels=[0x90, 0xf4, 0x7f]), dataset(3)]), 10)
        self.assertEqual(len(result['events']), 6)
        self.assertEqual({item['instance'] for item in result['events']}, {0, 3})
        self.assertEqual(result['events'][0]['level'], 'RAW_9')
        self.assertEqual(result['events'][1]['externalLevel'], 4)
        self.assertEqual([item['sequence'] for item in result['events'][:3]], [65535, 0, 1])
        self.assertEqual(len({item['id'] for item in result['events']}), 6)

    def test_missing_dictionary_keeps_raw_records_without_network(self):
        log = ulog(); log.msg_info_multiple_dict = {}; log.msg_info_dict = {}
        with patch('urllib.request.urlopen', side_effect=AssertionError('network prohibited')):
            result = events.extract_events(log, 10)
        self.assertEqual(result['dictionary']['status'], 'missing')
        self.assertEqual(len(result['events']), 3)
        self.assertEqual(result['events'][0]['translationStatus'], 'missing')
        self.assertIsNone(result['events'][0]['message'])

    def test_same_branch_name_never_substitutes_for_exact_artifact(self):
        log = ulog(version_hash=False)
        result = events.extract_events(log, 10, {'ver_sw': 'master'})
        self.assertEqual(result['dictionary']['status'], 'incompatible')
        self.assertIsNone(result['events'][0]['message'])

    def test_hash_mismatch_and_invalid_hash_do_not_translate(self):
        for expected in ['0' * 64, '../secret']:
            log = ulog(); log.msg_info_dict['metadata_events_sha256'] = expected
            result = events.extract_events(log, 10)
            self.assertEqual(result['dictionary']['status'], 'incompatible')
            self.assertIsNone(result['events'][0]['message'])

    def test_external_dictionary_requires_exact_compressed_hash(self):
        log = ulog(); log.msg_info_multiple_dict = {}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'all_events.json.xz'; path.write_bytes(log.payload)
            result = events.extract_events(log, 10, dictionary_path=path)
            self.assertEqual(result['dictionary']['status'], 'ready')
            path.write_text(json.dumps(definition()))
            self.assertEqual(events.extract_events(log, 10, dictionary_path=path)['dictionary']['status'], 'incompatible')

    def test_future_version_corrupt_json_conflicting_and_oversized_are_bounded(self):
        newer = definition(); newer['version'] = 99
        self.assertEqual(events.extract_events(ulog(definitions=newer), 10)['dictionary']['status'], 'incompatible')
        for payload in [b'not json', lzma.compress(b'not json'), lzma.compress(b'a' * 1025)]:
            log = ulog(); log.msg_info_multiple_dict = {'metadata_events': [[payload]]}
            log.msg_info_dict['metadata_events_sha256'] = hashlib.sha256(payload).hexdigest()
            with patch.object(events, 'MAX_DEFINITION_BYTES', 1024):
                self.assertEqual(events.extract_events(log, 10)['dictionary']['status'], 'invalid')
        log = ulog(); log.msg_info_multiple_dict['metadata_events'].append([b'other'])
        self.assertEqual(events.extract_events(log, 10)['dictionary']['status'], 'invalid')

    def test_malformed_arguments_do_not_invent_padding_or_discard_id(self):
        data = dataset(ids=[123]); del data.data['arguments[3]']
        result = events.extract_events(ulog([data]), 10)['events'][0]
        self.assertEqual(result['translationStatus'], 'invalid')
        self.assertEqual(result['eventID'], 123)
        self.assertEqual(result['argumentsHex'], '')
        self.assertEqual(len(result['rawArguments']), 24)

    def test_invalid_timestamp_remains_null_and_raw_is_exportable(self):
        result = events.extract_events(ulog([dataset(ids=[5], stamps=[np.nan])]), 10)
        record = result['events'][0]
        self.assertIsNone(record['timeSeconds'])
        self.assertEqual(record['translationStatus'], 'invalid')
        self.assertEqual(record['rawTimestamp'], {'encoding': 'nonfinite', 'value': 'nan'})
        self.assertEqual(len(record['argumentsHex']), 50)
        self.assertEqual(record['internalLevel'], 4)
        json.dumps(result, allow_nan=False)

    def test_unknown_enum_type_is_record_failure_only(self):
        definitions = definition()
        definitions['components']['1']['event_groups']['default']['events']['7']['arguments'][1]['type'] = 'missing_t'
        result = events.extract_events(ulog(definitions=definitions), 10)
        self.assertEqual(result['events'][0]['translationStatus'], 'invalid')
        self.assertEqual(result['events'][1]['translationStatus'], 'translated')

    def test_text_hostility_unicode_preserved_as_data(self):
        definitions = definition()
        definitions['components']['1']['event_groups']['health']['events']['8']['message'] = '⚠ Français </script> \\{unparsed}'
        result = events.extract_events(ulog(definitions=definitions), 10)
        self.assertIn('Français', result['events'][1]['message'])
        json.dumps(result, ensure_ascii=False, allow_nan=False)

    def test_metadata_unknown_binary_nested_boot_and_perf_preserved(self):
        log = ulog()
        log.msg_info_dict.update(custom={'binary': b'\x00\xff', 'value': np.int64(3)}, sensor_unknown=np.nan)
        log.msg_info_multiple_dict.update(sys_console=[['invented boot']], perf_counter_preflight=[['invented counter']], custom_unknown=[[b'xyz']])
        result = events.export_log_metadata(log)
        self.assertEqual(result['info']['custom']['binary'], {'encoding': 'hex', 'value': '00ff'})
        self.assertEqual(result['bootConsole']['sys_console'], [['invented boot']])
        self.assertIn('perf_counter_preflight', result['performance'])
        self.assertIn('custom_unknown', result['infoMultiple'])
        json.dumps(result, allow_nan=False)

    def test_no_event_topic_is_explicit_absence(self):
        result = events.extract_events(ulog([]), 10)
        self.assertEqual(result['events'], [])
        self.assertEqual(result['coverage'][0]['status'], 'absent')

    def test_real_pyulog_binary_event_array_and_dictionary_info_multiple(self):
        from pyulog import ULog
        def record(kind, payload):
            return struct.pack('<HB', len(payload), ord(kind)) + payload
        artifact = ulog().payload
        digest = hashlib.sha256(artifact).hexdigest().encode()
        key = b'char[64] metadata_events_sha256'
        content = ULog.HEADER_BYTES + bytes([1]) + struct.pack('<Q', 10_000_000)
        content += record('F', b'event:uint64_t timestamp;uint32_t id;uint16_t event_sequence;uint8_t[25] arguments;uint8_t log_levels;')
        content += record('I', bytes([len(key)]) + key + digest)
        key = f'uint8_t[{len(artifact)}] metadata_events'.encode()
        content += record('M', bytes([0, len(key)]) + key + artifact)
        content += record('A', struct.pack('<BH', 2, 1) + b'event')
        content += record('D', struct.pack('<HQIH', 1, 10_500_000, 0x1000007, 42) + struct.pack('<fB', 12.5, 2) + bytes(20) + bytes([0x46]))
        parsed = ULog(io.BytesIO(content))
        result = events.extract_events(parsed, 10)
        self.assertEqual(result['dictionary']['status'], 'ready')
        self.assertEqual(result['events'][0]['instance'], 2)
        self.assertEqual(result['events'][0]['message'], 'Voltage 12.50 state ready')
        self.assertEqual(result['events'][0]['timeSeconds'], .5)

    def test_short_timestamp_level_and_argument_arrays_preserve_every_id(self):
        data = dataset(ids=[7, 8])
        data.data['timestamp'] = data.data['timestamp'][:1]
        data.data['log_levels'] = data.data['log_levels'][:1]
        data.data['arguments[1]'] = data.data['arguments[1]'][:1]
        result = events.extract_events(ulog([data]), 10)
        self.assertEqual(len(result['events']), 2)
        self.assertEqual(result['events'][1]['eventID'], 8)
        self.assertEqual(result['events'][1]['translationStatus'], 'invalid')
        self.assertIsNone(result['events'][1]['timeSeconds'])


if __name__ == '__main__': unittest.main()
