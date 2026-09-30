"""Deterministic binary ULogs containing only invented, public test data."""
import hashlib
import json
import lzma
import struct

MAGIC = b'ULog\x01\x12\x35'
GCS_UUID = bytes(range(0x11, 0x1D))
CONTROLLER_UUID = '000200000000' + GCS_UUID[::-1].hex()


def record(kind, payload):
    if len(payload) > 65535:
        raise ValueError('ULog fixture record exceeds uint16 frame size')
    return struct.pack('<HB', len(payload), ord(kind)) + payload


def info(name, value):
    value = value.encode('utf-8') if isinstance(value, str) else value
    key = ('char[%d] %s' % (len(value), name)).encode('ascii')
    return record('I', bytes([len(key)]) + key + value)


def synthetic_ulog(drone_name=None, samples=513, include_uuid=True, events=True):
    data = MAGIC + bytes([1]) + struct.pack('<Q', 1_000_000)
    data += record('F', b'sensor_gps:uint64_t timestamp;uint64_t time_utc_usec;int32_t lat;int32_t lon;int32_t alt;uint8_t fix_type;uint8_t satellites_used;float eph;float epv;')
    data += record('F', b'dance_status:uint64_t timestamp;uint8_t[12] uuid;')
    data += record('F', b'vehicle_land_detected:uint64_t timestamp;bool landed;')
    data += record('F', b'battery_status:uint64_t timestamp;float voltage_v;float current_a;bool connected;')
    if include_uuid:
        data += info('sys_uuid', CONTROLLER_UUID)
        data += info('ver_hw', 'DROTEK_IO_STAR_TROIS')
    if drone_name:
        data += info('drone_name', drone_name)
    data += info('fixture_unknown', b'invented public evidence')
    parameter = b'float TEST_PARAM'
    data += record('P', bytes([len(parameter)]) + parameter + struct.pack('<f', 1.25))
    definition = {'version': 1, 'components': {'1': {'namespace': 'px4', 'event_groups': {'default': {'events': {'123': {'name': 'synthetic_voltage', 'message': 'Synthetic voltage {1:.1}', 'arguments': [{'name': 'voltage', 'type': 'float'}]}}}}}}}
    if events:
        artifact = lzma.compress(json.dumps(definition).encode())
        data += info('metadata_events_sha256', hashlib.sha256(artifact).hexdigest())
        key = b'uint8_t[%d] metadata_events' % len(artifact)
        data += record('M', b'\x00' + bytes([len(key)]) + key + artifact)
        data += record('F', b'event:uint64_t timestamp;uint32_t id;uint16_t event_sequence;uint8_t log_levels;uint8_t[25] arguments;')
    for topic, message_id in [('sensor_gps', 1), ('dance_status', 2), ('vehicle_land_detected', 3), ('battery_status', 4)] + ([('event', 5)] if events else []):
        data += record('A', struct.pack('<BH', 0, message_id) + topic.encode())
    for index in range(samples):
        stamp = 1_000_000 + index * 100_000
        values = struct.pack('<HQQiiiBBff', 1, stamp, 1_893_456_000_000_000 + index * 100_000,
                             10_000_000 + index, 20_000_000 + index, 100_000, 6, 20, .1, .2)
        data += record('D', values)
        data += record('D', struct.pack('<HQ12s', 2, stamp, GCS_UUID))
        data += record('D', struct.pack('<HQB', 3, stamp, index in (0, samples - 1)))
        data += record('D', struct.pack('<HQffB', 4, stamp, 16.0 - index / max(samples, 1), 1.0, 1))
    data += record('L', struct.pack('<BQ', 52, 1_100_000) + b'Synthetic GPS warning')
    data += record('L', struct.pack('<BQ', 54, 1_200_000) + b'Synthetic informational message')
    if events:
        data += record('D', struct.pack('<HQIHB25s', 5, 1_200_000, (1 << 24) | 123, 7, 0x44, struct.pack('<f', 16.0).ljust(25, b'\x00')))
    return data
