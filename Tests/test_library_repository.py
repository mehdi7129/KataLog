"""Public, deterministic oracle for indexed selection and bounded queries."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_repository as repository


def message(text='[test] Battery warning', family='Batterie', level='WARNING', alert=True, time=1):
    return {'id': hashlib.sha256((text + str(time)).encode()).hexdigest(), 'text': text,
            'family': family, 'level': level, 'isAlert': alert, 'timestampSeconds': time,
            'groupKey': family + '|' + level + '|' + text, 'title': text.removeprefix('[test] ')}


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-query-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.database = self.root / 'library.sqlite'
        self.db = analyzer.open_database(self.database)
        self.addCleanup(self.db.close)
        self.logs = []
        self.add('one', 'controller-1', '2026-01-01T12:00:00Z', [message(), message('Résumé prêt', 'Autres', 'INFO', False, 2)], duration=10)
        self.add('two', 'controller-1', '2026-01-02T12:00:00Z', [message()], duration=20)
        self.add('three', 'controller-2', '', [], duration=30, failsafe=True)
        self.add('four', 'controller-3', '2026-01-03T12:00:00Z', [message('GPS 100% _ prêt', 'GPS', 'INFO', True)], duration=40, status='partial')
        self.add('five', 'controller-4', '', [], status='error')

    def add(self, name, drone, date, messages, duration=0, failsafe=False, status='ok', metadata=None):
        identity = hashlib.sha256(name.encode()).hexdigest()
        source = self.root / (name + '.ulg')
        value = analyzer.base_log(source, self.root, identity, 1)
        value.update(droneID=drone, droneName='Drone ' + drone, date=date, durationSeconds=duration,
                     failsafeObserved=failsafe, status=status, messages=copy.deepcopy(messages))
        if metadata:
            value['metadata'].update(metadata)
        analyzer.remember_log(self.db, value)
        self.db.execute('INSERT INTO sources(log_id,path) VALUES(?,?)', (identity, str(source)))
        self.db.commit()
        self.logs.append(value)
        return value

    def query(self, **args):
        return repository.query(self.db, {'queryVersion': 1, **args})

    def cache_events(self, log, events=None, parser=None):
        detail = copy.deepcopy(log)
        if events is not None:
            detail['events'] = events
        self.db.execute('INSERT OR REPLACE INTO flight_details VALUES(?,?,?)', (log['id'], parser or analyzer.PARSER_VERSION, json.dumps(detail)))
        self.db.commit()

    def test_global_totals_match_explicit_oracle_and_no_messages_in_list(self):
        result = self.query()
        self.assertEqual(result['totals'], {'logs': 5, 'validLogs': 4, 'recordedSeconds': 100,
            'droneCount': 4, 'failsafeLogs': 1, 'alertLogs': 4, 'messages': 4,
            'groupCount': 3, 'familyLogCounts': {'Batterie': 2, 'GPS': 1},
            'scannedDroneCount': 4, 'provisionalDroneCount': 0, 'flightSeconds': None, 'flightLogCount': 0})
        values = result['snapshot']['logs']
        self.assertTrue(all(value['messages'] == [] for value in values))
        self.assertEqual(sum(value['summaryMessageCount'] for value in values), 4)
        self.assertTrue(next(value for value in values if value['droneID'] == 'controller-2')['summaryHasAlerts'])
        self.assertTrue(all('sourceAvailability' in value for value in values))

    def test_stale_analysis_coverage_is_global_beyond_page_and_excludes_errors(self):
        stale_id, error_id = self.logs[0]['id'], self.logs[-1]['id']
        for index in range(201):
            self.add('new-%03d' % index, 'current-controller', '2027-01-01T12:00:00Z', [])
        self.db.execute('UPDATE logs SET parser_version=? WHERE id IN (?,?)', ('previous-parser', stale_id, error_id))
        self.db.commit()
        repository.initialize(self.db)
        reader = analyzer.open_database(self.database, read_only=True)
        self.addCleanup(reader.close)
        with patch.object(repository, 'project_log', side_effect=AssertionError('A read query must not parse canonical JSON')):
            first = repository.query(reader, {'limit': 200}, read_only=True)
            scoped = repository.query(reader, {'scope': {'droneKeys': ['ulog:current-controller']}}, read_only=True)
        self.assertNotIn(stale_id, {log['id'] for log in first['snapshot']['logs']})
        self.assertEqual(first['totals']['libraryStaleAnalysisLogs'], 1)
        self.assertEqual(scoped['totals']['libraryStaleAnalysisLogs'], 1)
        self.assertEqual(scoped['totals']['logs'], 201)

    def test_compact_filter_uses_one_covering_metadata_copy_and_indexed_page_counts(self):
        self.query()
        statements = []
        self.db.set_trace_callback(statements.append)
        self.addCleanup(lambda: self.db.set_trace_callback(None))
        result = self.query(scope={'families': ['Batterie']})
        self.assertEqual(result['totals']['messages'], 2)
        self.assertFalse(any('CREATE TEMP TABLE kl_query_eligible' in sql for sql in statements))
        self.assertTrue(any('CREATE TEMP TABLE kl_query_selected AS SELECT rowid AS log_ordinal,id' in sql and 'INDEXED BY sqlite_autoindex_kl_logs_1' in sql for sql in statements))
        self.assertTrue(any('CROSS JOIN kl_messages m INDEXED BY kl_messages_definition' in sql and 'WHERE m.log_id=' in sql for sql in statements))

    def test_latest_named_controller_uses_bounded_index_probes_and_keeps_tie_order(self):
        named = []
        for suffix, name in [('name-a', 'Name A'), ('name-b', 'Name B')]:
            value = self.add(suffix, 'named-controller', '2026-01-02T12:00:00Z', [])
            identity = value['id']
            value['droneName'] = name
            analyzer.remember_log(self.db, value)
            named.append((identity, name))
        unknown = self.add('newer-unknown-name', 'named-controller', '2026-01-03T12:00:00Z', [])
        unknown['droneName'] = 'Drone non identifié'
        analyzer.remember_log(self.db, unknown)
        self.db.commit()
        self.query()
        statements = []
        self.db.set_trace_callback(statements.append)
        self.addCleanup(lambda: self.db.set_trace_callback(None))
        page = self.query(kind='drones')
        row = next(item for item in page['drones'] if item['id'] == 'ulog:named-controller')
        self.assertEqual(row['name'], max(named)[1])
        self.assertTrue(any('SELECT n.drone_name FROM kl_logs n INDEXED BY kl_logs_names' in sql and 'LIMIT 1' in sql for sql in statements))
        self.assertFalse(any('ROW_NUMBER() OVER' in sql for sql in statements))
        self.assertTrue(any('FROM kl_logs l INDEXED BY kl_logs_scope_meta' in sql for sql in statements))
        statements.clear()
        selected = self.query(scope={'droneKeys': ['ulog:named-controller']})
        self.assertEqual(selected['totals']['logs'], 3)
        self.assertTrue(any('CREATE TEMP TABLE kl_query_eligible' in sql and 'INDEXED BY kl_logs_drone_date' in sql for sql in statements))

    def test_registry_preaggregation_matches_scoped_identity_and_annotation_oracle(self):
        uuid = '1234567890ABCDEF12345678'
        self.add('direct-gcs', 'controller-1', '2026-01-04', [], metadata={'gcsUUID': uuid, 'gcsIdentityStatus': 'observed'})
        self.add('second-controller', 'controller-2', '2026-01-05', [], metadata={'gcsUUID': uuid, 'gcsIdentityStatus': 'observed'})
        self.add('ambiguous-controller', 'controller-1', '2026-01-06', [], metadata={'gcsUUID': '234567890ABCDEF123456789', 'gcsIdentityStatus': 'observed'})
        annotations = {'stockNumbers': {'ulog:controller-1': 'LEGACY-1', 'ulog:controller-2': 'LEGACY-2',
                                       'gcs:' + uuid: 'CANONICAL', 'gcs:34567890ABCDEF1234567890': 'NO-LOG'}}
        fast = self.query(kind='drones', annotations=annotations)
        reference = self.query(kind='drones', annotations=annotations, scope={'statuses': ['ok', 'partial', 'error']})
        self.assertEqual(fast['drones'], reference['drones'])
        self.assertEqual(fast['total'], reference['total'])

    def test_registry_includes_authorized_no_log_and_only_real_dated_gcs_observations(self):
        uuid = '112233445566778899AABBCC'
        invalid_date_uuid = '2233445566778899AABBCCDD'
        (self.root / 'fleet.json').write_text(json.dumps({'schemaVersion': 1, 'revision': 1, 'drones': [
            {'uuid': uuid, 'authorized': True, 'lastSeenAtUTC': '2026-02-01T12:03:04Z', 'lastSeenSource': 'gcs-telemetry', 'name': 'Public fixture'},
            {'uuid': invalid_date_uuid, 'authorized': True, 'lastSeenAtUTC': '2026-02-01', 'lastSeenSource': 'gcs-telemetry'},
            {'uuid': '33445566778899AABBCCDDEE', 'authorized': False, 'lastSeenAtUTC': '2026-02-01T12:00:00Z', 'lastSeenSource': 'gcs-telemetry'}]}))
        page = self.query(kind='drones')
        row = next(item for item in page['drones'] if item['id'] == 'gcs:' + uuid)
        self.assertEqual(row['logCount'], 0)
        self.assertIsNone(row['stockNumber'])
        self.assertEqual(row['lastGCSDate'], '2026-02-01T12:03:04Z')
        self.assertEqual(row['lastGCSSource'], 'gcs-telemetry')
        self.assertEqual(row['sourceStatus'], 'none')
        self.assertIsNone(row['sourceCheckedAt'])
        invalid = next(item for item in page['drones'] if item['id'] == 'gcs:' + invalid_date_uuid)
        self.assertIsNone(invalid['lastGCSDate'])
        self.assertNotIn('gcs:33445566778899AABBCCDDEE', {item['id'] for item in page['drones']})
        first = self.query(kind='drones', limit=1)
        fleet = json.loads((self.root / 'fleet.json').read_text()); fleet['revision'] = 2
        (self.root / 'fleet.json').write_text(json.dumps(fleet))
        with self.assertRaisesRegex(ValueError, 'données ou filtres'):
            self.query(kind='drones', limit=1, cursor=first['nextCursor'])

    def test_registry_source_status_is_only_a_dated_stored_check_and_read_only(self):
        self.query()
        self.db.execute('INSERT INTO source_observations VALUES(?,?,?,?)', (self.logs[0]['id'], str(self.root / 'one.ulg'), 'present', '2026-02-01T10:00:00Z'))
        self.db.execute('INSERT INTO source_observations VALUES(?,?,?,?)', (self.logs[1]['id'], str(self.root / 'two.ulg'), 'missing', '2026-02-01T11:00:00Z'))
        self.db.commit(); repository.initialize(self.db)
        reader = analyzer.open_database(self.database, read_only=True)
        self.addCleanup(reader.close)
        before = self.database.read_bytes()
        page = repository.query(reader, {'kind': 'drones'}, read_only=True)
        row = next(item for item in page['drones'] if item['id'] == 'ulog:controller-1')
        self.assertEqual(row['sourceStatus'], 'present-at-check')
        self.assertEqual(row['sourceCheckedAt'], '2026-02-01T10:00:00Z')
        unknown = next(item for item in page['drones'] if item['id'] == 'ulog:controller-2')
        self.assertEqual(unknown['sourceStatus'], 'unknown')
        self.assertIsNone(unknown['sourceCheckedAt'])
        self.assertIsNone(unknown['lastGCSDate'])
        self.assertEqual(self.database.read_bytes(), before)

    def test_fleet_events_are_separate_raw_occurrences_with_explicit_cache_coverage(self):
        events = [{'id': 'event:0:0', 'eventID': 123, 'timeSeconds': 1,
                   'internalLevelName': 'WARNING', 'externalLevelName': 'INFO',
                   'message': 'Synthetic voltage', 'translationStatus': 'translated', 'argumentsHex': '00'},
                  {'id': 'event:0:1', 'eventID': 999, 'timeSeconds': None,
                   'internalLevelName': 'CRITICAL', 'externalLevelName': 'WARNING',
                   'message': None, 'translationStatus': 'unknown', 'argumentsHex': 'ff'}]
        self.cache_events(self.logs[0], events)
        self.cache_events(self.logs[1], [], parser='previous-parser')
        self.cache_events(self.logs[2])
        first = self.query(kind='events', limit=1)
        self.assertEqual(first['total'], 2)
        self.assertEqual(first['coverage'], {'selectedLogs': 5, 'cachedLogs': 3, 'unavailableLogs': 2,
            'legacyCacheLogs': 1, 'invalidCacheLogs': 0, 'eventLogs': 1, 'translatedLogs': 1, 'previousParserLogs': 1})
        self.assertEqual(first['occurrences'][0]['event'], events[0])
        second = self.query(kind='events', limit=1, cursor=first['nextCursor'])
        self.assertEqual(second['occurrences'][0]['event'], events[1])
        self.assertIsNone(second['nextCursor'])
        internal = self.query(kind='events', eventLevelSource='internal', eventLevels=['WARNING'])
        external = self.query(kind='events', eventLevelSource='external', eventLevels=['WARNING'])
        self.assertEqual(internal['occurrences'][0]['event']['eventID'], 123)
        self.assertEqual(external['occurrences'][0]['event']['eventID'], 999)
        self.assertEqual(self.query(kind='events', eventSearch=' VOLTAGE ')['total'], 1)
        self.assertEqual(self.query(kind='events', eventSearch='999')['total'], 1)
        self.assertEqual(self.query(kind='events', scope={'families': ['GPS']})['total'], 0)
        self.assertEqual(self.query(kind='groups')['total'], 3)
        with self.assertRaises(ValueError):
            self.query(kind='events', cursor=first['nextCursor'], eventLevelSource='external')

    def test_event_cache_changes_are_incremental_invalidate_cursors_and_never_redecode_summaries(self):
        self.cache_events(self.logs[0], [{'id': 'first', 'eventID': 1}])
        first = self.query(kind='events', limit=1)
        self.cache_events(self.logs[0], [{'id': 'first', 'eventID': 1}, {'id': 'second', 'eventID': 2}])
        with patch.object(repository, 'project_events', wraps=repository.project_events) as event_project, patch.object(repository, 'project_log', wraps=repository.project_log) as log_project:
            changed = self.query(kind='events', limit=1)
            self.assertEqual(event_project.call_count, 1)
            self.assertEqual(log_project.call_count, 1)
        self.assertGreater(changed['revision'], first['revision'])
        self.assertEqual(changed['total'], 2)
        self.db.execute('DELETE FROM flight_details WHERE log_id=?', (self.logs[0]['id'],)); self.db.commit()
        empty = self.query(kind='events')
        self.assertEqual(empty['total'], 0)
        self.assertEqual(empty['coverage']['cachedLogs'], 0)
        with self.assertRaisesRegex(ValueError, 'changé'):
            self.query(kind='events', cursor=changed['nextCursor'])

    def test_corrupt_detail_cache_does_not_block_canonical_library_queries(self):
        self.db.execute('INSERT INTO flight_details VALUES(?,?,?)', (self.logs[0]['id'], analyzer.PARSER_VERSION, 'not-json'))
        self.db.commit()
        result = self.query(kind='events')
        self.assertEqual(result['coverage']['invalidCacheLogs'], 1)
        self.assertEqual(result['coverage']['cachedLogs'], 1)
        self.assertEqual(result['total'], 0)
        self.assertEqual(self.query()['totals']['logs'], 5)

    def test_nonfinite_cached_event_is_invalid_without_partial_publication(self):
        self.cache_events(self.logs[0], [{'id': 'valid', 'timeSeconds': 0}, {'id': 'invalid', 'rawTimestamp': float('nan')}])
        result = self.query(kind='events')
        self.assertEqual(result['coverage']['invalidCacheLogs'], 1)
        self.assertEqual(result['total'], 0)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM kl_events').fetchone()[0], 0)
        self.assertEqual(self.query()['totals']['logs'], 5)

    def test_global_catalogue_includes_info_only_families_raw_levels_manual_rules_and_pages(self):
        self.add('catalogue', 'catalogue-controller', '', [message('No alarm', 'Info only', 'RAW_15', False)])
        annotations = {'familyOverrides': {'orphan-rule': 'Manual family'}}
        cursor, families, levels = None, [], []
        while True:
            page = self.query(kind='catalogue', scope={'families': ['Absent']}, annotations=annotations, limit=2, cursor=cursor)
            families.extend(page['families']); levels.extend(page['levels'])
            cursor = page['nextCursor']
            if cursor is None: break
        self.assertEqual(families, ['Autres', 'Batterie', 'GPS', 'Info only', 'Manual family'])
        self.assertEqual(levels, ['INFO', 'RAW_15', 'WARNING'])
        self.assertNotIn('Info only', self.query()['totals']['familyLogCounts'])

    def test_family_level_alert_search_filters_intersect_messages(self):
        result = self.query(scope={'families': ['GPS'], 'levels': ['INFO'], 'alertOnly': True, 'search': '100%'}, includeMessages=True)
        self.assertEqual(result['totals']['logs'], 1)
        self.assertEqual(result['totals']['messages'], 1)
        self.assertEqual(result['totals']['alertLogs'], 1)
        self.assertEqual(result['snapshot']['logs'][0]['messages'][0]['text'], 'GPS 100% _ prêt')
        self.assertEqual(self.query(scope={'families': ['Batterie'], 'levels': ['INFO']})['totals']['logs'], 0)

    def test_failsafe_has_no_invented_message_match(self):
        self.assertEqual(self.query(scope={'alertOnly': True})['totals']['failsafeLogs'], 0)
        self.assertEqual(self.query(scope={'search': 'failsafe'})['totals']['logs'], 0)
        self.assertEqual(self.query()['totals']['failsafeLogs'], 1)
        self.add('failsafe-message', 'controller-failsafe', '', [message('GPS warning', 'GPS')], failsafe=True)
        self.assertEqual(self.query(scope={'families': ['GPS']})['totals']['failsafeLogs'], 0)

    def test_metadata_search_includes_historical_and_new_copy_paths(self):
        value = self.logs[0]
        value['sourcePaths'] = ['/fixture/historical/card/log.ulg']
        analyzer.remember_log(self.db, value)
        self.db.execute('INSERT INTO sources VALUES(?,?)', (value['id'], '/fixture/relocated-copy/log.ulg'))
        self.db.commit()
        self.assertEqual(self.query(scope={'logSearch': 'historical/card'})['totals']['logs'], 1)
        self.assertEqual(self.query(scope={'logSearch': 'relocated-copy'})['totals']['logs'], 1)

    def test_unknown_dates_and_inclusive_days(self):
        scope = {'dateFrom': '2026-01-02', 'dateTo': '2026-01-03', 'includeUnknownDates': False}
        self.assertEqual(self.query(scope=scope)['totals']['logs'], 2)
        scope['includeUnknownDates'] = True
        self.assertEqual(self.query(scope=scope)['totals']['logs'], 4)
        self.assertEqual(self.query(scope={'includeUnknownDates': False})['totals']['logs'], 3)

    def test_metadata_search_and_literal_wildcards_unicode(self):
        self.assertEqual(self.query(scope={'logSearch': 'four.ulg'})['totals']['logs'], 1)
        self.assertEqual(self.query(scope={'search': 'GPS 100% _ PRET'})['totals']['logs'], 1)
        self.assertEqual(self.query(scope={'search': 'GPS\t100%    _ prêt'})['totals']['logs'], 1)
        self.assertEqual(self.query(scope={'search': 'not%_here'})['totals']['logs'], 0)
        self.assertEqual(self.query(scope={'statuses': ['partial']})['totals']['logs'], 1)

    def test_annotation_classification_override_preserves_source_family(self):
        annotations = {'schemaVersion': 1, 'familyOverrides': {repository.classification_key(message()): 'Énergie'}}
        result = self.query(scope={'families': ['Énergie']}, annotations=annotations, includeMessages=True)
        self.assertEqual(result['totals']['logs'], 2)
        self.assertEqual(result['totals']['familyLogCounts'], {'Énergie': 2})
        for value in result['snapshot']['logs']:
            self.assertEqual(value['messages'][0]['sourceFamily'], 'Batterie')
            self.assertEqual(value['messages'][0]['family'], 'Énergie')

    def test_legacy_family_override_and_classification_precedence(self):
        override = {message()['groupKey']: 'Legacy', repository.classification_key(message()): 'New'}
        self.assertEqual(self.query(annotations={'familyOverrides': override}, scope={'families': ['New']})['totals']['logs'], 2)
        override.pop(repository.classification_key(message()))
        self.assertEqual(self.query(annotations={'familyOverrides': override}, scope={'families': ['Legacy']})['totals']['logs'], 2)

    def test_mask_hides_messages_preserves_logs_and_can_be_included(self):
        masks = [repository.classification_key(message())]
        result = self.query(maskedMessageKeys=masks)
        self.assertEqual(result['totals']['logs'], 5)
        self.assertEqual(result['totals']['messages'], 2)
        self.assertEqual(self.query(maskedMessageKeys=masks, scope={'families': ['Batterie']})['totals']['logs'], 0)
        unmasked = self.query(maskedMessageKeys=masks, scope={'includeMasked': True}, includeMessages=True)
        messages = [item for log in unmasked['snapshot']['logs'] for item in log['messages']]
        self.assertEqual(sum(item['isMasked'] for item in messages), 2)

    def test_stock_annotations_do_not_merge_controllers(self):
        annotations = {'stockNumbers': {'ulog:controller-1': 'TEST-001', 'ulog:controller-2': 'TEST-001'}}
        result = self.query(annotations=annotations, scope={'logSearch': 'TEST-001'})
        # Direct ulog annotation is the canonical key even without a GCS UUID.
        self.assertEqual(result['totals']['logs'], 3)
        self.assertEqual(result['totals']['droneCount'], 2)
        self.assertEqual({log['stockNumber'] for log in result['snapshot']['logs']}, {'TEST-001'})

    def test_unique_gcs_link_and_conflict_do_not_guess(self):
        uuid = '1234567890ABCDEF12345678'
        self.add('gcs', 'controller-1', '2026-01-04', [], metadata={'gcsUUID': uuid, 'gcsIdentityStatus': 'observed'})
        result = self.query(scope={'droneKeys': ['gcs:' + uuid]}, annotations={'stockNumbers': {'gcs:' + uuid: 'TEST-002'}})
        self.assertEqual(result['totals']['logs'], 3)
        self.assertTrue(all(log['stockNumber'] == 'TEST-002' for log in result['snapshot']['logs']))
        self.add('conflict', 'controller-1', '2026-01-05', [], metadata={'gcsUUID': '234567890ABCDEF123456789', 'gcsIdentityStatus': 'observed'})
        self.assertEqual(self.query(scope={'droneKeys': ['gcs:' + uuid]})['totals']['logs'], 1)
        self.assertEqual(self.query(scope={'droneKeys': ['ulog:controller-1']})['totals']['logs'], 2)

    def test_groups_occurrences_are_bounded_and_group_filter_matches(self):
        groups = self.query(kind='groups', limit=2)
        self.assertEqual(groups['total'], 3)
        self.assertEqual(len(groups['groups']), 2)
        selected = next(item for item in groups['groups'] if item['family'] == 'Batterie')
        result = self.query(kind='messages', groupID=selected['id'], limit=1)
        self.assertEqual(result['total'], 2)
        self.assertEqual(len(result['occurrences']), 1)
        next_page = self.query(kind='messages', groupID=selected['id'], limit=1, cursor=result['nextCursor'])
        self.assertIsNone(next_page['nextCursor'])
        self.assertNotEqual(result['occurrences'][0]['logID'], next_page['occurrences'][0]['logID'])

    def test_cursor_no_duplicates_and_rejects_scope_or_revision_change(self):
        first = self.query(limit=2)
        second = self.query(limit=2, cursor=first['nextCursor'])
        third = self.query(limit=2, cursor=second['nextCursor'])
        identities = [log['id'] for reply in (first, second, third) for log in reply['snapshot']['logs']]
        self.assertEqual(len(set(identities)), 5)
        self.assertIsNone(third['nextCursor'])
        with self.assertRaisesRegex(ValueError, 'changé'):
            self.query(limit=2, cursor=first['nextCursor'], scope={'statuses': ['ok']})
        self.add('revision', 'controller-5', '', [])
        with self.assertRaisesRegex(ValueError, 'changé'):
            self.query(limit=2, cursor=first['nextCursor'])

    def test_log_sort_order_is_stable_and_invalidates_cursor(self):
        recent = self.query(limit=2)
        oldest = self.query(limit=2, sortOrder='oldest')
        all_oldest, cursor = [], None
        while True:
            page = self.query(limit=2, sortOrder='oldest', cursor=cursor)
            all_oldest.extend(page['snapshot']['logs'])
            cursor = page['nextCursor']
            if cursor is None:
                break
        expected = sorted(self.logs, key=lambda item: (item['date'], item['id']))
        self.assertEqual([item['id'] for item in all_oldest], [item['id'] for item in expected])
        self.assertNotEqual(recent['scopeHash'], oldest['scopeHash'])
        with self.assertRaisesRegex(ValueError, 'filtres ont changé'):
            self.query(limit=2, sortOrder='oldest', cursor=recent['nextCursor'])
        with self.assertRaisesRegex(ValueError, 'tri invalide'):
            self.query(sortOrder='random')
        filtered = self.query(scope={'droneKeys': ['ulog:controller-1']}, sortOrder='oldest')
        self.assertEqual([item['date'] for item in filtered['snapshot']['logs']], sorted(item['date'] for item in filtered['snapshot']['logs']))

    def test_projection_incremental_no_canonical_decode_after_first_build(self):
        first = self.query()
        with patch.object(repository, 'project_log', wraps=repository.project_log) as project:
            self.query()
            self.assertEqual(project.call_count, 0)
            value = self.logs[0]
            value['durationSeconds'] = 101
            analyzer.remember_log(self.db, value)
            self.db.commit()
            changed = self.query()
            self.assertEqual(project.call_count, 1)
            self.assertEqual(changed['totals']['recordedSeconds'], 191)
            self.assertGreater(changed['revision'], first['revision'])

    def test_source_link_change_invalidates_cursor_without_message_reprojection(self):
        first = self.query(limit=1)
        self.db.execute('INSERT INTO sources VALUES(?,?)', (self.logs[0]['id'], str(self.root / 'copy.ulg')))
        self.db.commit()
        with patch.object(repository, 'project_log', wraps=repository.project_log) as project:
            changed = self.query()
            self.assertGreater(changed['revision'], first['revision'])
            self.assertEqual(project.call_count, 1)
            self.assertEqual(changed['totals']['messages'], 4)
        with self.assertRaisesRegex(ValueError, 'changé'):
            self.query(limit=1, cursor=first['nextCursor'])

    def test_delete_updates_index(self):
        self.query()
        self.db.execute('DELETE FROM logs WHERE id=?', (self.logs[0]['id'],))
        self.db.commit()
        changed = self.query()
        self.assertEqual(changed['totals']['logs'], 4)
        self.assertEqual(changed['totals']['messages'], 2)

    def test_compact_presence_updates_changed_definitions_without_reusing_identity(self):
        first = self.query(scope={'families': ['Batterie']})
        self.assertEqual(first['totals']['messages'], 2)
        ordinal = self.db.execute('SELECT rowid FROM kl_logs WHERE id=?', (self.logs[0]['id'],)).fetchone()[0]
        self.logs[0]['messages'] = [message('New GPS', 'GPS')]
        analyzer.remember_log(self.db, self.logs[0]); self.db.commit()
        with patch.object(repository, 'refresh_presence', wraps=repository.refresh_presence) as refresh:
            battery = self.query(scope={'families': ['Batterie']})
            self.assertEqual(refresh.call_count, 1)
            self.assertIsNotNone(refresh.call_args.args[1])
        self.assertEqual(battery['totals']['messages'], 1)
        self.assertEqual(self.db.execute('SELECT rowid FROM kl_logs WHERE id=?', (self.logs[0]['id'],)).fetchone()[0], ordinal)
        gps = self.query(scope={'families': ['GPS']})
        self.assertEqual(gps['totals']['messages'], 2)
        self.db.execute('DELETE FROM logs WHERE id=?', (self.logs[0]['id'],)); self.db.commit()
        self.assertEqual(self.query(scope={'families': ['GPS']})['totals']['messages'], 1)
        self.assertEqual(self.query(scope={'families': ['GPS']})['totals']['familyLogCounts'], {'GPS': 1})

    def test_compact_presence_unions_multiple_families_overrides_masks_and_error_status(self):
        self.add('six', 'controller-6', '', [message(), message('GPS other', 'GPS')], status='error')
        result = self.query(scope={'families': ['Batterie', 'GPS']})
        self.assertEqual(result['totals']['logs'], 4)
        self.assertEqual(result['totals']['messages'], 5)
        self.assertEqual(result['totals']['alertLogs'], 3)
        self.assertEqual(result['totals']['familyLogCounts'], {'Batterie': 2, 'GPS': 1})
        key = repository.classification_key(self.logs[0]['messages'][0])
        overridden = self.query(scope={'families': ['GPS']}, annotations={'familyOverrides': {key: 'GPS'}})
        self.assertEqual(overridden['totals']['logs'], 4)
        self.assertEqual(overridden['totals']['familyLogCounts'], {'GPS': 3})
        masked = self.query(scope={'families': ['Batterie', 'GPS']}, maskedMessageKeys=[key])
        self.assertEqual(masked['totals']['messages'], 2)
        self.assertEqual(masked['totals']['familyLogCounts'], {'GPS': 1})

    def test_presence_dense_and_sparse_encodings_are_exact_and_bounded(self):
        dense = bytes([0b10000010, 0b00000101])
        expected = sum(1 << value for value in (1, 7, 8, 10))
        self.assertEqual(repository.presence_bits('bits-v1', dense), expected)
        sparse = b''.join(__import__('struct').pack('>Q', value) for value in (1, 7, 8, 10))
        self.assertEqual(repository.presence_bits('ordinals-v1', sparse), expected)
        with self.assertRaises(ValueError):
            repository.presence_bits('ordinals-v1', b'bad')
        with self.assertRaises(ValueError):
            repository.presence_bits('ordinals-v1', __import__('struct').pack('>Q', 1_000_001))

    def test_projection_v3_additive_presence_migration_backs_up_before_changes(self):
        self.query()
        self.db.execute("UPDATE kl_meta SET value='3' WHERE key='projectionVersion'")
        self.db.execute('DROP TABLE kl_definition_presence'); self.db.commit()
        result = self.query(scope={'families': ['Batterie']})
        self.assertEqual(result['totals']['messages'], 2)
        self.assertEqual(self.db.execute("SELECT value FROM kl_meta WHERE key='projectionVersion'").fetchone()[0], str(repository.PROJECTION_VERSION))
        path = self.db.execute("SELECT value FROM settings WHERE key='indexMigrationBackup'").fetchone()[0]
        import library_storage
        backup = library_storage.inspect_backup(path)
        self.assertEqual(backup['databaseVersions'], {'library.sqlite': 1})
        self.assertEqual(backup['logCount'], 5)

    def test_projection_v5_message_provenance_migration_is_backed_up_and_exact(self):
        value = self.logs[0]
        value['messages'][0].update(source='ULog:logging_tagged', tag=42,
            rawTimestamp=2 ** 63 + 1, rawLogLevel=52, sourceIndex=3)
        analyzer.remember_log(self.db, value); self.db.commit()
        self.query()
        self.db.execute('ALTER TABLE kl_messages DROP COLUMN metadata_json')
        self.db.execute("UPDATE kl_meta SET value='5' WHERE key='projectionVersion'"); self.db.commit()
        page = self.query(kind='messages', scope={'logIDs': [value['id']]})
        item = next(occurrence['message'] for occurrence in page['occurrences'] if occurrence['message']['isAlert'])
        self.assertEqual(item['source'], 'ULog:logging_tagged')
        self.assertEqual(item['tag'], 42)
        self.assertEqual(item['rawTimestamp'], 2 ** 63 + 1)
        self.assertEqual(item['rawLogLevel'], 52)
        self.assertEqual(item['sourceIndex'], 3)
        self.assertEqual(self.db.execute("SELECT value FROM kl_meta WHERE key='projectionVersion'").fetchone()[0], str(repository.PROJECTION_VERSION))
        path = self.db.execute("SELECT value FROM settings WHERE key='indexMigrationBackup'").fetchone()[0]
        import library_storage
        self.assertEqual(library_storage.inspect_backup(path)['logCount'], 5)

    def test_compact_scope_equals_sql_fallback_for_groups_messages_and_masks(self):
        key = repository.classification_key(self.logs[0]['messages'][0])
        requests = [
            {'kind': 'logs', 'scope': {'families': ['Batterie', 'GPS']}, 'includeMessages': True},
            {'kind': 'groups', 'scope': {'alertOnly': True}},
            {'kind': 'messages', 'scope': {'search': 'prêt'}},
            {'kind': 'logs', 'maskedMessageKeys': [key]},
            {'kind': 'messages', 'annotations': {'familyOverrides': {key: 'Manual'}}},
        ]
        expected = [self.query(**request) for request in requests]
        # Force the documented ordinal budget fallback on this synthetic index.
        self.db.execute('UPDATE kl_logs SET rowid=1000001 WHERE id=?', (self.logs[-1]['id'],))
        self.db.commit()
        actual = [self.query(**request) for request in requests]
        for left, right in zip(expected, actual):
            self.assertEqual(left['totals'], right['totals'])
            for field in ('groups', 'occurrences'):
                self.assertEqual(left.get(field), right.get(field))
            if 'snapshot' in left:
                self.assertEqual([item['id'] for item in left['snapshot']['logs']], [item['id'] for item in right['snapshot']['logs']])
                self.assertEqual([item['messages'] for item in left['snapshot']['logs']], [item['messages'] for item in right['snapshot']['logs']])

    def test_read_only_query_never_creates_or_updates_projection(self):
        reader = analyzer.open_database(self.database, read_only=True)
        self.addCleanup(reader.close)
        with self.assertRaisesRegex(ValueError, 'préparé'):
            repository.query(reader, {}, read_only=True)
        self.query()
        before = self.database.read_bytes()
        result = repository.query(reader, {}, read_only=True)
        self.assertEqual(result['totals']['logs'], 5)
        self.assertEqual(before, self.database.read_bytes())
        self.add('dirty', 'new-controller', '', [])
        with self.assertRaisesRegex(ValueError, 'actualisé'):
            repository.query(reader, {}, read_only=True)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM kl_dirty').fetchone()[0], 1)

    def test_cli_query_and_ensure_index_contract(self):
        request, output = self.root / 'request.json', self.root / 'query.json'
        request.write_text(json.dumps({'queryVersion': 1, 'kind': 'groups', 'limit': 1}))
        self.assertEqual(analyzer.main(['ensure-index', '--database', str(self.database), '--output', str(output)]), 0)
        self.assertEqual(json.loads(output.read_text())['queryVersion'], 1)
        self.assertEqual(analyzer.main(['query', '--request', str(request), '--database', str(self.database), '--output', str(output), '--read-only']), 0)
        result = json.loads(output.read_text())
        self.assertEqual(result['total'], 3)
        self.assertEqual(len(result['groups']), 1)

    def test_single_oversized_message_fails_before_publishing_output(self):
        self.add('huge', 'controller-huge', '', [message('x' * 5000)])
        with patch.object(repository, 'MAX_QUERY_BYTES', 6500):
            with self.assertRaisesRegex(ValueError, 'budget'):
                self.query(kind='messages', scope={'droneKeys': ['ulog:controller-huge']})

    def test_byte_budget_shrinks_page_without_losing_occurrences(self):
        with patch.object(repository, 'MAX_QUERY_BYTES', 6500):
            first = self.query(kind='messages', limit=200)
            self.assertGreater(len(first['occurrences']), 0)
            self.assertLess(len(first['occurrences']), 4)
            self.assertIsNotNone(first['nextCursor'])
            pages = [first]
            while pages[-1]['nextCursor']:
                pages.append(self.query(kind='messages', cursor=pages[-1]['nextCursor']))
            self.assertEqual(sum(len(page['occurrences']) for page in pages), 4)
            self.assertTrue(all(len(json.dumps(page, ensure_ascii=False).encode()) <= 6500 for page in pages))

    def test_malformed_and_future_contracts_fail_closed(self):
        for value in ({'queryVersion': 2}, {'queryVersion': True}, {'limit': 0}, {'limit': True}, {'limit': 201},
                      {'scope': {'dateFrom': 'bad'}}, {'scope': {'dateFrom': '2026-02-01', 'dateTo': '2026-01-01'}},
                      {'annotations': {'schemaVersion': 2}}, {'annotations': {'familyOverrides': []}}, {'cursor': '???'}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.query(**value)
        self.query()
        self.db.execute("UPDATE kl_meta SET value='99' WHERE key='projectionVersion'")
        self.db.commit()
        with self.assertRaises(ValueError):
            self.query()

    def test_drone_registry_ignores_dashboard_filters_includes_no_log_annotations(self):
        annotations = {'stockNumbers': {'ulog:controller-1': 'TEST-001', 'ulog:controller-2': 'TEST-001', 'gcs:1234567890ABCDEF12345678': 'TEST-003'}}
        reply = self.query(kind='drones', annotations=annotations, scope={'families': ['Absent'], 'dateFrom': '2099-01-01'}, limit=2)
        self.assertEqual(reply['total'], 5)
        self.assertEqual(len(reply['drones']), 2)
        page = self.query(kind='drones', annotations=annotations, cursor=reply['nextCursor'])
        all_drones = reply['drones'] + page['drones']
        self.assertEqual(sum(drone['logCount'] for drone in all_drones), 5)
        empty = next(drone for drone in all_drones if drone['stockNumber'] == 'TEST-003')
        self.assertEqual(empty['logCount'], 0)
        self.assertEqual(empty['sourceStatus'], 'none')
        shared = [drone for drone in all_drones if drone['stockNumber'] == 'TEST-001']
        self.assertEqual(len(shared), 2)
        self.assertNotEqual(shared[0]['id'], shared[1]['id'])

    def test_migration_backup_preserves_canonical_records_and_known_legacy_cache(self):
        cached = self.logs[0]
        self.db.execute('INSERT INTO flight_details VALUES(?,?,?)', (cached['id'], 'legacy-parser', json.dumps(cached)))
        self.db.commit()
        self.query()
        path = Path(self.db.execute("SELECT value FROM settings WHERE key='indexMigrationBackup'").fetchone()[0])
        self.assertTrue(path.is_file())
        import library_storage
        target = self.root / 'restored-migration'
        library_storage.restore(path, target)
        restored = analyzer.open_database(target / 'library.sqlite')
        try:
            self.assertEqual(restored.execute('SELECT COUNT(*) FROM logs').fetchone()[0], 5)
            self.assertEqual(restored.execute('SELECT parser_version FROM flight_details').fetchone()[0], 'legacy-parser')
        finally:
            restored.close()

    def test_failed_projection_build_does_not_destroy_canonical_data(self):
        with patch.object(repository, 'project_log', side_effect=RuntimeError('simulated interruption')):
            with self.assertRaises(RuntimeError):
                self.query()
        self.db.rollback()
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM logs').fetchone()[0], 5)
        self.assertEqual(self.query()['totals']['logs'], 5)

    def test_registry_search_canonical_name_stock_identity_and_cursor_fingerprint(self):
        annotations = {'stockNumbers': {'ulog:controller-1': 'TEST-001', 'ulog:controller-2': 'TEST-001'}}
        reply = self.query(kind='drones', annotations=annotations, registrySearch='test-001', limit=1)
        self.assertEqual(reply['total'], 2)
        with self.assertRaisesRegex(ValueError, 'changé'):
            self.query(kind='drones', annotations=annotations, registrySearch='controller', cursor=reply['nextCursor'])
        self.assertEqual(self.query(kind='drones', registrySearch='controller-4')['total'], 1)

    def test_group_mask_preview_complete_even_if_current_scope_is_narrow(self):
        groups = self.query(kind='groups', scope={'families': ['Batterie']})
        group = groups['groups'][0]
        self.assertTrue(group['classKeysComplete'])
        self.assertEqual(group['classKeys'], [repository.classification_key(message())])
        self.assertEqual(group['classKeyCount'], 1)
        preview = self.query(kind='group-keys', groupID=group['id'], scope={'families': ['Absent']})
        self.assertEqual(preview['total'], 1)
        self.assertEqual(preview['classKeys'], group['classKeys'])

    def test_occurrence_keyset_pagination_same_log_timestamp_and_unknown_date(self):
        self.add('ties', 'ties-controller', '', [message('A', time=0), message('B', time=0), message('C', time=-1)])
        request = {'kind': 'messages', 'limit': 1}
        seen, cursor = [], None
        while True:
            page = self.query(**request, cursor=cursor)
            seen.extend((row['logID'], row['message']['id']) for row in page['occurrences'])
            cursor = page['nextCursor']
            if not cursor: break
        self.assertEqual(len(seen), 7)
        self.assertEqual(len(set(seen)), 7)

    def test_indexed_status_is_global_read_only_and_reports_missing(self):
        self.query()
        absent = hashlib.sha256(b'not-in-library').hexdigest()
        result = analyzer.indexed_status(self.database, {'logIDs': [self.logs[0]['id'], absent], 'parserVersion': analyzer.PARSER_VERSION})
        self.assertEqual(result['missing'], [absent])
        self.assertEqual(result['logs'][0]['id'], self.logs[0]['id'])
        self.assertEqual(result['logs'][0]['status'], 'ok')
        self.assertEqual(result['logs'][0]['parserVersion'], analyzer.PARSER_VERSION)
        with self.assertRaises(ValueError): analyzer.indexed_status(self.database, {'logIDs': ['not-sha']})


if __name__ == '__main__':
    unittest.main()
