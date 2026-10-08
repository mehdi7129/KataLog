"""Large public selections keep the same membership, ordering and consumers."""
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_clients as clients
import library_proximity as proximity
import library_repository as repository
import library_reports as reports


class LargeSelectionTests(unittest.TestCase):
    def setUp(self):
        clock = patch.object(analyzer, 'utc_now', return_value='2026-01-05T12:00:00Z')
        clock.start()
        self.addCleanup(clock.stop)
        temporary = tempfile.TemporaryDirectory(prefix='katalog-large-selection-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.database = self.root / 'library.sqlite'
        self.db = analyzer.open_database(self.database)
        self.addCleanup(self.db.close)
        self.logs = []
        for index in range(4):
            source = self.root / ('fixture-%d.ulg' % index)
            source.write_bytes(('Untouched fixture %d' % index).encode())
            identity = hashlib.sha256(source.read_bytes()).hexdigest()
            log = analyzer.base_log(source, self.root, identity, source.stat().st_size)
            log.update(droneID='controller-%d' % (index // 2), droneName='Fixture drone',
                       date='2026-01-0%dT12:00:00Z' % (index + 1), status='ok', durationSeconds=10,
                       messages=[{'id': 'message-%d' % index, 'text': 'Fixture warning',
                                  'title': 'Fixture warning', 'family': 'GPS', 'level': 'WARNING',
                                  'groupKey': 'GPS|WARNING|Fixture warning', 'isAlert': True,
                                  'timestampSeconds': 1}],
                       track={'points': [{'latitude': 1, 'longitude': 2, 'timeSeconds': 1}]})
            analyzer.remember_log(self.db, log)
            self.db.execute('INSERT INTO sources VALUES(?,?)', (identity, str(source)))
            detail = dict(log, events=[{'id': 'event-%d' % index, 'eventID': index,
                                       'internalLevelName': 'WARNING', 'externalLevelName': 'INFO',
                                       'timeSeconds': 1, 'translationStatus': 'untranslated'}])
            self.db.execute('INSERT INTO flight_details VALUES(?,?,?)',
                            (identity, analyzer.PARSER_VERSION, json.dumps(detail)))
            self.logs.append(log)
        self.db.commit()
        repository.initialize(self.db)

    def expanded(self, values, count, prefix='absent-'):
        return list(values) + [prefix + str(index) for index in range(count - len(values))]

    def page_values(self, request, db=None, read_only=False):
        request = dict(request)
        values, totals = [], None
        while True:
            page = repository.query(db or self.db, request, read_only=read_only)
            totals = page.get('totals', {key: page[key] for key in ('totalLogs', 'locatedLogs') if key in page})
            values.extend(page.get('snapshot', {}).get('logs', page.get('groups', page.get('occurrences', page.get('markers', [])))))
            if not page['nextCursor']:
                return values, totals
            request['cursor'] = page['nextCursor']

    def test_native_variable_limit_and_full_accepted_log_id_list(self):
        wanted = [log['id'] for log in self.logs[:3]]
        request = {'scope': {'logIDs': wanted}, 'includeMessages': True, 'limit': 1}
        expected = self.page_values(request)
        for count in (self.db.getlimit(sqlite3.SQLITE_LIMIT_VARIABLE_NUMBER) + 1, 100_000):
            with self.subTest(count=count):
                large = dict(request, scope={'logIDs': self.expanded(wanted, count)})
                self.assertEqual(self.page_values(large), expected)

    def test_combined_filters_pages_and_event_levels_under_small_variable_budget(self):
        # Each list fits by itself; their sum and the second ulog predicate do not.
        self.db.setlimit(sqlite3.SQLITE_LIMIT_VARIABLE_NUMBER, 128)
        scope = {'logIDs': [log['id'] for log in self.logs[:3]],
                 'droneKeys': ['ulog:controller-0', 'ulog:controller-1'],
                 'statuses': ['ok'], 'families': ['Navigation'], 'levels': ['WARNING'],
                 'dateFrom': '2026-01-01', 'dateTo': '2026-01-04', 'search': 'fixture',
                 'logSearch': 'fixture', 'alertOnly': True, 'includeUnknownDates': False}
        expanded = dict(scope, **{field: self.expanded(scope[field], 80, 'ulog:absent-' if field == 'droneKeys' else 'absent-')
                                  for field in ('logIDs', 'droneKeys', 'statuses', 'families', 'levels')})
        annotations = {'familyOverrides': {'GPS|WARNING|Fixture warning': 'Navigation'}}
        for kind in ('logs', 'groups', 'messages', 'events', 'map', 'map-overview'):
            for order in ('recent', 'oldest'):
                with self.subTest(kind=kind, order=order):
                    request = {'kind': kind, 'scope': scope, 'annotations': annotations,
                               'limit': 1, 'sortOrder': order, 'includeMessages': True}
                    if kind == 'events':
                        request.update(eventLevels=['INFO'], eventLevelSource='external', eventSearch='untranslated')
                    expected = self.page_values(request)
                    self.assertTrue(expected[0])
                    large = dict(request, scope=expanded)
                    if kind == 'events':
                        large['eventLevels'] = self.expanded(['INFO'], 140)
                    self.assertEqual(self.page_values(large), expected)

    def test_ulog_prefilter_preserves_uuid_propagation_and_rejection(self):
        uuid = '112233445566778899AABBCC'
        log = self.logs[2]
        log['metadata'].update(gcsUUID=uuid, gcsIdentityStatus='observed')
        analyzer.remember_log(self.db, log)
        self.logs[3]['metadata'].update(gcsUUID=uuid, gcsIdentityStatus='rejected')
        analyzer.remember_log(self.db, self.logs[3])
        self.db.commit()
        repository.initialize(self.db)
        self.db.setlimit(sqlite3.SQLITE_LIMIT_VARIABLE_NUMBER, 128)
        for keys in (['ulog:controller-0', 'ulog:controller-1'], ['ulog:controller-0', 'gcs:' + uuid]):
            with self.subTest(keys=keys):
                small = {'kind': 'map-overview', 'scope': {'droneKeys': keys}}
                expected = self.page_values(small)
                self.assertEqual(len(expected[0]), 3)
                large = dict(small, scope={'droneKeys': self.expanded(keys, 100, 'ulog:absent-')})
                self.assertEqual(self.page_values(large), expected)

    def test_readonly_connection_replaces_selection_without_main_writes(self):
        self.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        before = self.database.read_bytes()
        reader = analyzer.open_database(self.database, read_only=True)
        self.addCleanup(reader.close)
        reader.setlimit(sqlite3.SQLITE_LIMIT_VARIABLE_NUMBER, 128)
        for wanted in ([self.logs[0]['id']], [], [self.logs[3]['id']]):
            with self.subTest(wanted=wanted):
                scope = {'logIDs': self.expanded(wanted, 150)}
                values, _ = self.page_values({'scope': scope}, reader, read_only=True)
                self.assertEqual([log['id'] for log in values], wanted)
                self.assertEqual(self.database.read_bytes(), before)
        values, _ = self.page_values({}, reader, read_only=True)
        self.assertEqual(len(values), 4)
        self.assertEqual(self.database.read_bytes(), before)

    def test_proximity_reuses_large_selection_for_candidate_and_final_queries(self):
        for log in self.logs:
            proximity.cache_track(self.db, log['id'], log['track'])
        self.db.commit()
        self.db.setlimit(sqlite3.SQLITE_LIMIT_VARIABLE_NUMBER, 128)
        wanted = [log['id'] for log in self.logs[:3]]
        for kind in ('map', 'map-overview'):
            with self.subTest(kind=kind):
                small = {'kind': kind, 'scope': {'logIDs': wanted}, 'limit': 1,
                         'proximity': {'latitude': 1, 'longitude': 2, 'radiusMeters': 10}}
                expected = self.page_values(small)
                self.assertEqual(len(expected[0]), 3)
                self.assertEqual(self.page_values(dict(small, scope={'logIDs': self.expanded(wanted, 150)})), expected)

    def test_reports_capture_and_prepare_match_small_selection(self):
        scope = {'logIDs': [log['id'] for log in self.logs[:3]], 'families': ['GPS'], 'levels': ['WARNING']}
        large = dict(scope, logIDs=self.expanded(scope['logIDs'], 33_000),
                     families=self.expanded(scope['families'], 33_000))
        before = {path: path.read_bytes() for path in self.root.glob('*.ulg')}
        exported = []
        for name, selection in (('small', scope), ('large', large)):
            capture, output = self.root / ('capture-' + name), self.root / ('output-' + name)
            manifest = reports.capture_report(self.database, capture, {'query': {'scope': selection}, 'options': {'format': 'json'}})
            self.assertEqual(manifest['totalLogs'], 3)
            self.assertEqual(manifest['totalMessages'], 3)
            result = reports.prepare_report(capture, output)
            exported.append((json.loads((output / 'rapport.json').read_text())['logs'], result['messageCount']))
        self.assertEqual(exported[0], exported[1])
        self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_client_assignment_and_unassignment_use_complete_large_selection(self):
        client = clients.command(self.database, 'create-client', {'name': 'Fixture client'})['id']
        wanted = [log['id'] for log in self.logs[:3]]
        request = {'scope': {'logIDs': self.expanded(wanted, 33_000), 'families': ['GPS']}, 'clientID': client}
        for _ in range(2):
            self.assertEqual(clients.command(self.database, 'assign-client', request)['assignedLogs'], 3)
            self.assertEqual(dict(self.db.execute('SELECT log_id,client_id FROM log_clients')), dict.fromkeys(wanted, client))
        request['clientID'] = None
        self.assertEqual(clients.command(self.database, 'assign-client', request)['assignedLogs'], 3)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM log_clients').fetchone()[0], 0)


if __name__ == '__main__':
    unittest.main()
