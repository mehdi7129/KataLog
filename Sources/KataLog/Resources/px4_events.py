"""Lossless PX4 event records; translations require an exact local artifact.

Reference: PX4 v1.14 Event.msg and logger/component_information: the SHA256
in metadata_events_sha256 identifies the compressed all_events.json.xz bytes.
Arguments are little endian, packed without padding (mavlink/libevents).
No network access or master dictionary fallback is performed here.
"""
from copy import deepcopy
import hashlib
import json
import lzma
import math
from pathlib import Path
import re

SCHEMA_VERSION = 1
MAX_ARTIFACT_BYTES = 4 * 1024 * 1024
MAX_DEFINITION_BYTES = 16 * 1024 * 1024
LEVELS = ('EMERGENCY', 'ALERT', 'CRITICAL', 'ERROR', 'WARNING', 'NOTICE', 'INFO', 'DEBUG')
REFERENCE = 'https://github.com/PX4/PX4-Autopilot/blob/v1.14.0/msg/Event.msg'


def json_value(value):
    """Preserve unknown metadata, including bytes and non-finite values."""
    if hasattr(value, 'item'):
        try:
            value = value.item()
        except (ValueError, TypeError):
            pass
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else {'encoding': 'nonfinite', 'value': str(value)}
    if isinstance(value, (bytes, bytearray, memoryview)):
        return {'encoding': 'hex', 'value': bytes(value).hex()}
    if isinstance(value, dict):
        return {str(key): json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)) or hasattr(value, 'tolist'):
        return [json_value(item) for item in (value.tolist() if hasattr(value, 'tolist') else value)]
    return {'encoding': 'repr', 'type': type(value).__name__, 'value': str(value)}


def export_log_metadata(ulog):
    """All info records remain available; named views never replace raw info."""
    info = json_value(getattr(ulog, 'msg_info_dict', {}))
    multiple = json_value(getattr(ulog, 'msg_info_multiple_dict', {}))
    boot_keys = {'sys_console', 'boot_console', 'boot_console_output'}
    boot = {key: value for key, value in multiple.items() if key in boot_keys}
    performance = {key: value for key, value in multiple.items() if key.startswith('perf_')}
    return {'schemaVersion': SCHEMA_VERSION, 'info': info, 'infoMultiple': multiple,
            'bootConsole': boot, 'performance': performance,
            'unknownInfo': {key: value for key, value in info.items()
                            if not key.startswith(('ver_', 'sys_', 'metadata_'))}}


def _integer(value):
    if isinstance(value, bool):
        raise ValueError('boolean where integer expected')
    number = int(value)
    if number != value:
        raise ValueError('non-integer value')
    return number


def _sha(value):
    if isinstance(value, bytes):
        value = value.decode('ascii', errors='replace')
    return value.lower() if isinstance(value, str) and re.fullmatch(r'[0-9a-fA-F]{64}', value) else None


def _artifact_bytes(chunks):
    if isinstance(chunks, (bytes, bytearray)):
        return bytes(chunks)
    payload = bytearray()
    for chunk in chunks:
        if not isinstance(chunk, (bytes, bytearray, memoryview)):
            raise ValueError('metadata_events chunks must be bytes')
        if len(payload) + len(chunk) > MAX_ARTIFACT_BYTES:
            raise ValueError('event artifact exceeds compressed byte budget')
        payload.extend(chunk)
    return bytes(payload)


def _definitions(payload):
    if len(payload) > MAX_ARTIFACT_BYTES:
        raise ValueError('event artifact exceeds byte budget')
    if payload.startswith(b'\xfd7zXZ\x00'):
        decoder = lzma.LZMADecompressor(memlimit=64 * 1024 * 1024)
        decoded = decoder.decompress(payload, max_length=MAX_DEFINITION_BYTES + 1)
        if len(decoded) > MAX_DEFINITION_BYTES or not decoder.eof or decoder.unused_data:
            raise ValueError('invalid, concatenated or oversized compressed dictionary')
    else:
        decoded = payload
    result = json.loads(decoded)
    if not isinstance(result, dict) or not isinstance(result.get('components'), dict):
        raise ValueError('dictionary is not a libevents definition')
    version = result.get('version')
    if type(version) is not int or version not in (1, 2):
        raise LookupError('unsupported libevents definition version')
    # Parser performs enum/argument validation when the corresponding ID is used.
    for comp_id, comp in result['components'].items():
        if not str(comp_id).isdigit() or not 0 <= int(comp_id) <= 255:
            raise ValueError('invalid component ID')
        if not isinstance(comp, dict) or not isinstance(comp.get('namespace'), str):
            raise ValueError('invalid component definition')
        if not isinstance(comp.get('event_groups', {}), dict):
            raise ValueError('invalid event groups')
        for group in comp.get('event_groups', {}).values():
            if not isinstance(group, dict) or not isinstance(group.get('events', {}), dict):
                raise ValueError('invalid event group')
            for event_id, event in group.get('events', {}).items():
                if not str(event_id).isdigit() or not 0 <= int(event_id) <= 0xffffff:
                    raise ValueError('invalid event sub ID')
                if not isinstance(event, dict) or not isinstance(event.get('message'), str):
                    raise ValueError('invalid event definition')
                if not isinstance(event.get('arguments', []), list):
                    raise ValueError('invalid event arguments')
    return result


def _dictionary(ulog, firmware, dictionary_path):
    info = getattr(ulog, 'msg_info_dict', {})
    raw_hash = info.get('metadata_events_sha256', (firmware or {}).get('metadata_events_sha256'))
    expected = _sha(raw_hash)
    result = {'status': 'missing', 'sha256': None, 'expectedSHA256': expected,
              'definitionVersion': None, 'provenance': None,
              'binding': 'metadata_events_sha256', 'firmware': json_value(firmware or {})}
    multiple = getattr(ulog, 'msg_info_multiple_dict', {})
    payload = None
    try:
        if dictionary_path is not None:
            path = Path(dictionary_path)
            with path.open('rb') as handle:
                payload = handle.read(MAX_ARTIFACT_BYTES + 1)
            result['provenance'] = 'local:' + path.name
        elif 'metadata_events' in multiple:
            # Every entry is an artifact, whose parts are continued INFO_MULTIPLE
            # chunks. Conflicting repeated artifacts are rejected.
            artifacts = [_artifact_bytes(parts) for parts in multiple['metadata_events']]
            if not artifacts or any(part != artifacts[0] for part in artifacts[1:]):
                raise ValueError('conflicting or empty embedded event dictionaries')
            payload = artifacts[0]
            result['provenance'] = 'ULog:metadata_events'
        if payload is None:
            if raw_hash is not None and expected is None:
                result.update(status='invalid', reason='invalid metadata_events_sha256')
            return None, result
        if len(payload) > MAX_ARTIFACT_BYTES:
            raise ValueError('event artifact exceeds byte budget')
        result['sha256'] = hashlib.sha256(payload).hexdigest()
        if expected is None:
            result.update(status='incompatible', reason='no exact log artifact hash available')
            return None, result
        if result['sha256'] != expected:
            result.update(status='incompatible', reason='event artifact SHA256 differs from log')
            return None, result
        definitions = _definitions(payload)
        from pyulog.libevents_parse.parser import Parser
        parser = Parser()
        parser.load_definitions(deepcopy(definitions))
        parser.set_profile('dev')
        result.update(status='ready', definitionVersion=definitions['version'])
        return parser, result
    except LookupError as error:
        result.update(status='incompatible', reason=str(error))
    except (ValueError, TypeError, KeyError, OSError, EOFError, lzma.LZMAError, ImportError, RecursionError) as error:
        result.update(status='invalid', reason=str(error))
    return None, result


def _arguments(data, index):
    """No padding is fabricated when a malformed log lacks argument bytes."""
    if 'arguments' in data:
        values = list(data['arguments'][index])
    else:
        keys = sorted((key for key in data if re.fullmatch(r'arguments\[\d+\]', key)),
                      key=lambda key: int(key[10:-1]))
        indices = [int(key[10:-1]) for key in keys]
        values = [data[key][index] for key in keys]
        if indices != list(range(len(indices))):
            return b'', False, json_value(values)
    try:
        numbers = [_integer(value) for value in values]
        if any(not 0 <= number <= 255 for number in numbers):
            raise ValueError('argument outside uint8')
        return bytes(numbers), len(numbers) == 25, json_value(values)
    except (ValueError, TypeError, OverflowError):
        return b'', False, json_value(values)


def extract_events(ulog, startSeconds, firmwareMetadata=None, dictionary_path=None):
    """Return every event occurrence, including disabled/protocol/unknown IDs.

    timeSeconds is null for an invalid timestamp; rawTimestamp still preserves
    the input. No invented text, diagnosis, level, timestamp or argument value.
    """
    if not math.isfinite(startSeconds):
        raise ValueError('startSeconds must be finite')
    parser, dictionary = _dictionary(ulog, firmwareMetadata, dictionary_path)
    events = []
    malformed = 0
    datasets = [dataset for dataset in getattr(ulog, 'data_list', [])
                if dataset.name in ('event', 'event_v0')]
    for dataset in datasets:
        data = dataset.data
        count = len(data.get('id', []))
        instance = int(dataset.multi_id)
        stamps = data.get('timestamp')
        for index in range(count):
            raw_id = data['id'][index]
            raw_stamp = stamps[index] if stamps is not None and index < len(stamps) else None
            record = {'id': f'{dataset.name}:{instance}:{index}', 'eventID': json_value(raw_id),
                      'topic': dataset.name, 'instance': instance, 'sourceIndex': index,
                      'timeSeconds': None, 'rawTimestamp': json_value(raw_stamp),
                      'level': 'UNKNOWN', 'message': None, 'argumentsHex': '',
                      'definitionSource': None, 'sequence': None, 'logLevels': None,
                      'internalLevel': None, 'externalLevel': None,
                      'internalLevelName': 'UNKNOWN', 'externalLevelName': 'UNKNOWN',
                      'translationStatus': dictionary['status'] if parser is None else 'unknown',
                      'reference': REFERENCE}
            try:
                arguments, valid_arguments, raw_arguments = _arguments(data, index)
                record['argumentsHex'] = arguments.hex()
                if not valid_arguments:
                    record['rawArguments'] = raw_arguments
                if 'log_levels' in data:
                    packed_levels = _integer(data['log_levels'][index])
                    record['logLevels'] = packed_levels
                    if 0 <= packed_levels <= 255:
                        internal, external = packed_levels >> 4, packed_levels & 15
                        record.update(internalLevel=internal, externalLevel=external,
                                      internalLevelName=LEVELS[internal] if internal < 8 else f'RAW_{internal}',
                                      externalLevelName=LEVELS[external] if external < 8 else f'RAW_{external}')
                        record['level'] = record['internalLevelName']
                if 'event_sequence' in data:
                    record['sequence'] = _integer(data['event_sequence'][index])
                event_id = _integer(raw_id)
                record['eventID'] = event_id
                if not 0 <= event_id <= 0xffffffff:
                    raise ValueError('event ID outside uint32')
                timestamp = float(raw_stamp)
                if not math.isfinite(timestamp) or timestamp < 0:
                    raise ValueError('invalid timestamp')
                record['timeSeconds'] = timestamp / 1e6 - startSeconds
                if record['logLevels'] is None or not 0 <= record['logLevels'] <= 255:
                    raise ValueError('log_levels outside uint8')
                if record['sequence'] is not None:
                    if not 0 <= record['sequence'] <= 0xffff:
                        raise ValueError('event sequence outside uint16')
                if not valid_arguments:
                    raise ValueError('missing, malformed or non-25-byte argument payload')
                if parser is not None:
                    parsed = parser.parse(event_id, arguments)
                    if parsed is not None:
                        record.update(message=parsed.message(), description=parsed.description(),
                                      eventName=parsed.name(), group=parsed.group(), namespace=parsed.namespace(),
                                      argumentValues=[json_value(parsed.argument_value(i))
                                                      for i in range(parsed.num_arguments())],
                                      translationStatus='translated',
                                      definitionSource=f"{dictionary['provenance']} sha256:{dictionary['sha256']}")
            except (ValueError, TypeError, KeyError, IndexError, OverflowError, AttributeError) as error:
                malformed += 1
                record.update(translationStatus='invalid', invalidReason=str(error))
            except Exception as error:
                # libevents reports format/type errors via ParserException/struct.error.
                # A bad definition must not discard the raw occurrence or other IDs.
                malformed += 1
                record.update(translationStatus='invalid', invalidReason=f'{type(error).__name__}: {error}')
            events.append(record)
    translated = sum(record['translationStatus'] == 'translated' for record in events)
    return {'schemaVersion': SCHEMA_VERSION, 'events': events, 'dictionary': dictionary,
            'coverage': [{'domain': 'events', 'status': 'absent' if not datasets else
                          ('partial' if translated != len(events) else 'available'),
                          'detail': f'{len(events)} raw records; {translated} translated; {malformed} invalid',
                          'rawRecordCount': len(events), 'translatedCount': translated,
                          'invalidRecordCount': malformed}]}
