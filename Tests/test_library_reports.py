"""Streaming report gates use only invented data; no network or real ULogs."""
import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_repository as repository
import library_reports as reports


def message(text='Synthetic warning', family='Batterie', level='WARNING', alert=True, timestamp=1):
    return {'id': hashlib.sha256((text + str(timestamp)).encode()).hexdigest(),
            'timestampSeconds': timestamp, 'level': level, 'text': text, 'family': family,
            'title': text, 'groupKey': family + '|' + level + '|' + text, 'isAlert': alert}


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='katalog-report-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.database = self.root / 'library.sqlite'
        self.db = analyzer.open_database(self.database)
        self.addCleanup(self.db.close)
        self.values = []
        self.add('one', 'controller-1', [message(), message('Boot résumé', 'Système', 'INFO', False, 2)], 10)
        self.add('two', 'controller-2', [message('GPS prêt', 'GPS', 'INFO', True)], 20)
        self.add('failsafe', 'controller-3', [], 30, failsafe=True)
        self.add('broken', 'controller-4', [], 999, status='error')

    def add(self, name, drone, messages, duration=0, failsafe=False, status='ok'):
        source = self.root / (name + '.ulg'); source.write_bytes(b'Source untouched ' + name.encode())
        identity = hashlib.sha256(name.encode()).hexdigest()
        value = analyzer.base_log(source, self.root, identity, 1)
        value.update(droneID=drone, droneName=drone, date='2026-01-01T12:00:00Z',
                     messages=copy.deepcopy(messages), durationSeconds=duration,
                     failsafeObserved=failsafe, status=status)
        analyzer.remember_log(self.db, value)
        self.db.execute('INSERT INTO sources VALUES(?,?)', (identity, str(source)))
        self.db.commit(); self.values.append(value)
        return value

    def request(self, scope=None, options=None, annotations=None, masks=None):
        return {'reportVersion': 1, 'query': {'queryVersion': 1, 'scope': scope or {},
            'annotations': annotations or {'schemaVersion': 1}, 'maskedMessageKeys': masks or []},
            'mode': 'selection' if scope else 'full', 'scopeDescription': 'Fixture full' if not scope else 'Fixture selection',
            'viewRevision': 7, 'options': options or {'format': 'html'}}

    def export(self, request=None):
        capture = self.root / ('capture-' + str(time.monotonic_ns()))
        captured = reports.capture_report(self.database, capture, request or self.request())
        destination = self.root / ('report-' + str(time.monotonic_ns()))
        result = reports.prepare_report(capture, destination)
        return capture, captured, destination, result

    def test_capture_is_immutable_after_live_import_and_annotation_mutation(self):
        request = self.request(annotations={'schemaVersion': 1, 'stockNumbers': {'ulog:controller-1': '42'}})
        capture = self.root / 'capture'
        captured = reports.capture_report(self.database, capture, request)
        request['query']['annotations']['stockNumbers']['ulog:controller-1'] = '999'
        self.add('later', 'new-controller', [message('Later')])
        result = reports.prepare_report(capture, self.root / 'report')
        payload = json.loads((self.root / 'report/rapport.json').read_text())
        self.assertEqual(result['revision'], captured['revision'])
        self.assertEqual(len(payload['logs']), 4)
        self.assertEqual(next(log for log in payload['logs'] if log['droneID'] == 'controller-1')['stockNumber'], '42')
        self.assertEqual(result['messageCount'], 3)

    def test_streamed_selection_parity_with_query_and_failsafe_contract(self):
        for scope in [{}, {'families': ['GPS']}, {'levels': ['INFO'], 'alertOnly': True},
                      {'search': 'resume'}, {'droneKeys': ['ulog:controller-1']}, {'statuses': ['error']}]:
            request = self.request(scope=scope)
            oracle = repository.query(self.db, {**request['query'], 'kind': 'logs', 'includeMessages': True})
            _, _, root, result = self.export(request)
            payload = json.loads((root / 'rapport.json').read_text())
            self.assertEqual({value['id'] for value in payload['logs']}, {value['id'] for value in oracle['snapshot']['logs']})
            self.assertEqual(result['messageCount'], oracle['totals']['messages'])
            summary = json.loads((root / 'summary.json').read_text())
            for key in ['recordedSeconds', 'alertLogs', 'failsafeLogs', 'familyLogCounts', 'droneCount']:
                self.assertEqual(summary[key], oracle['totals'][key])

    def test_masks_and_family_overrides_apply_before_export(self):
        original = self.values[0]['messages'][0]
        key = repository.classification_key(original)
        request = self.request(scope={'families': ['Custom']},
            annotations={'schemaVersion': 1, 'familyOverrides': {key: 'Custom'}}, masks=[key])
        _, _, root, result = self.export(request)
        self.assertEqual(result['messageCount'], 0)
        request['query']['scope']['includeMasked'] = True
        _, _, root, result = self.export(request)
        payload = json.loads((root / 'rapport.json').read_text())
        self.assertEqual(result['messageCount'], 1)
        self.assertEqual(payload['logs'][0]['messages'][0]['family'], 'Custom')
        self.assertTrue(payload['logs'][0]['messages'][0]['isMasked'])

    def test_oversized_single_log_messages_stream_in_full_not_page_truncated(self):
        text = 'Unicode ⚠ " </script> ' * 500
        log = self.add('large', 'controller-large', [message(text + str(i), timestamp=i) for i in range(650)])
        capture, captured, root, result = self.export()
        self.assertGreater((root / 'rapport.json').stat().st_size, reports.MAX_INLINE_JSON_BYTES)
        self.assertEqual(result['renderMode'], 'summary-with-attachments')
        payload = json.loads((root / 'rapport.json').read_text())
        exported = next(value for value in payload['logs'] if value['id'] == log['id'])
        self.assertEqual(len(exported['messages']), 650)
        self.assertEqual(exported['messages'][0]['text'], text + '0')
        self.assertFalse(result['manifest']['truncated'])
        self.assertEqual(captured['totalMessages'], 653)

    def test_unknown_metadata_and_cached_details_only_never_open_ulog(self):
        value = copy.deepcopy(self.values[0])
        value['parameters'] = {'SERIAL_SYNTHETIC': 'unchanged'}
        value['metadataDetails'] = {'info': {'custom': {'encoding': 'hex', 'value': '00ff'}}}
        value.update(parameterDetails={'initial': [{'name': 'PUBLIC', 'type': 'int', 'value': 7}]},
                     dropouts=[{'durationMilliseconds': 375}], batteryDetails={'serial_number': 'synthetic-pack'},
                     gnssDetails={'instances': []}, telemetryCatalogue=[{'field': 'voltage_cell_v[0]', 'unit': 'V'}])
        value['events'] = [{'id': 'raw', 'eventID': 1, 'timeSeconds': None, 'level': 'UNKNOWN', 'message': None,
                            'argumentsHex': '00ff', 'definitionSource': None}]
        self.db.execute('INSERT INTO flight_details VALUES(?,?,?)', (value['id'], 'fixture', json.dumps(value)))
        self.db.commit()
        before = {path: path.read_bytes() for path in self.root.glob('*.ulg')}
        with patch.object(analyzer, 'analyze_file', side_effect=AssertionError('must not read sources')):
            _, _, root, result = self.export(self.request(options={'format': 'html', 'includeCachedDetails': True}))
        payload = json.loads((root / 'rapport.json').read_text())
        selected = next(log for log in payload['logs'] if log['id'] == value['id'])
        self.assertEqual(selected['parameters'], value['parameters'])
        self.assertEqual(selected['metadataDetails'], value['metadataDetails'])
        for key in ('parameterDetails', 'dropouts', 'batteryDetails', 'gnssDetails', 'telemetryCatalogue'):
            self.assertEqual(selected[key], value[key])
        self.assertEqual(result['manifest']['detailedCachedLogCount'], 1)
        self.assertEqual(before, {path: path.read_bytes() for path in before})

    def test_each_privacy_option_removes_secret_from_every_exported_file(self):
        secret = 'PRIVATE-NEEDLE-42'
        value = self.values[0]
        value.update(droneID=secret, droneName=secret, sourcePaths=['/Users/' + secret + '/card.ulg'],
                     fileName=secret + '.ulg', dateSource=secret, issues=[secret], coverage=[secret],
                     metadata={secret: secret}, metrics=[{'key': secret, 'label': secret, 'value': 48.12345, 'unit': secret, 'detail': secret}],
                     messages=[message(secret, family=secret)])
        value['messages'][0]['position'] = {'latitude': 48.12345, 'longitude': 2.54321, 'timeSeconds': 1, 'segment': 0}
        value['messages'][0].update(source=secret, tag=42, rawTimestamp=123456, rawLogLevel=52, sourceIndex=3)
        value.update(parameterDetails={'initial': [{'name': secret, 'value': secret}]},
                     dropouts=[{'source': secret}], batteryDetails={'serial_number': secret},
                     gnssDetails={'latitude': 48.12345, 'longitude': 2.54321},
                     telemetryCatalogue=[{'source': secret}],
                     analysisRevision={'id': secret, 'analysisSHA256': secret, 'createdAt': secret})
        value['metadata'].update(analysisRevisionID=secret, analysisRevisionDate=secret, analysisRevisionSHA=secret)
        analyzer.remember_log(self.db, value); self.db.commit()
        self.db.execute('INSERT OR REPLACE INTO flight_details VALUES(?,?,?)', (value['id'], analyzer.PARSER_VERSION, json.dumps(value)))
        self.db.commit()
        for option in ('excludePaths', 'excludeIdentity', 'excludeCoordinates'):
            request = self.request(options={'format': 'html', option: True, 'includeCachedDetails': True},
                                   annotations={'schemaVersion': 1, 'stockNumbers': {'ulog:' + secret: secret}})
            request['scopeDescription'] = secret
            _, _, root, result = self.export(request)
            self.assertFalse(result['rawDataIncluded'])
            for path in root.rglob('*'):
                if path.is_file():
                    text = path.read_text()
                    for needle in (secret, '48.12345', '2.54321', '/Users/'):
                        self.assertNotIn(needle, text, path.name)
            payload = json.loads((root / 'rapport.json').read_text())
            self.assertEqual(sum(len(log['messages']) for log in payload['logs']), result['messageCount'])
            self.assertTrue(result['manifest']['effectivePrivacy']['freeTextRemoved'])
            self.assertTrue(all('source' not in message and 'tag' not in message and 'rawTimestamp' not in message
                                for log in payload['logs'] for message in log['messages']))
            for log in payload['logs']:
                for key in ('analysisRevision', 'parameterDetails', 'dropouts', 'batteryDetails', 'gnssDetails', 'telemetryCatalogue'):
                    self.assertNotIn(key, log)

    def test_internal_cached_report_keeps_exact_analysis_revision_fingerprint(self):
        value = copy.deepcopy(self.values[0]); value['parameters'] = {'PUBLIC': '7'}
        encoded = json.dumps(value)
        self.db.execute('INSERT INTO flight_details VALUES(?,?,?)', (value['id'], analyzer.PARSER_VERSION, encoded))
        identity = analyzer.archive_analysis(self.db, value['id'], 'detail', analyzer.PARSER_VERSION, encoded)
        self.db.commit()
        _, _, root, _ = self.export(self.request(options={'format': 'html', 'includeCachedDetails': True}))
        payload = json.loads((root / 'rapport.json').read_text())
        result = next(log for log in payload['logs'] if log['id'] == value['id'])
        self.assertEqual(result['analysisRevision']['id'], identity)
        self.assertEqual(result['analysisRevision']['analysisSHA256'], hashlib.sha256(encoded.encode()).hexdigest())
        self.assertTrue(result['analysisRevision']['current'])

    def test_capture_tampering_rejected_before_destination_created(self):
        capture, _, _, _ = self.export()
        context = capture / 'context.json'; context.write_text(context.read_text() + ' ')
        with self.assertRaisesRegex(ValueError, 'changé'):
            reports.prepare_report(capture, self.root / 'tampered')
        self.assertFalse((self.root / 'tampered').exists())

    def test_cancelled_generation_cleans_unpublished_staging_under_one_second(self):
        capture, _, _, _ = self.export()
        calls = 0
        def cancel():
            nonlocal calls
            calls += 1
            return calls > 15
        start = time.monotonic()
        with self.assertRaises(reports.ReportCancelled):
            reports.prepare_report(capture, self.root / 'cancelled', cancel)
        self.assertLess(time.monotonic() - start, 1)
        self.assertFalse((self.root / 'cancelled').exists())

    def test_full_attachment_checksums_and_original_database_are_unchanged(self):
        repository.initialize(self.db)
        before = hashlib.sha256(self.database.read_bytes()).hexdigest()
        source_hashes = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in self.root.glob('*.ulg')}
        _, _, root, result = self.export()
        for entry in result['files']:
            path = root / entry['name']
            self.assertEqual(path.stat().st_size, entry['sizeBytes'])
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), entry['sha256'])
        self.assertEqual(before, hashlib.sha256(self.database.read_bytes()).hexdigest())
        self.assertEqual(source_hashes, {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in source_hashes})

    def test_progress_counts_all_selected_logs_without_private_names(self):
        capture, captured, _, _ = self.export()
        progress = self.root / 'progress.json'
        reports.prepare_report(capture, self.root / 'with-progress', progress=progress)
        value = json.loads(progress.read_text())
        self.assertEqual(value['completed'], captured['totalLogs'])
        self.assertEqual(value['total'], captured['totalLogs'])
        self.assertIn('composition', value['current'])
        self.assertNotIn(str(self.root), value['current'])


if __name__ == '__main__': unittest.main()
