"""Public fixtures for source visibility, duration coverage and signal severity."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources')]
import analyzer
import library_repository as repository
import library_sources as sources
import library_archives as archives
from signal_assessment import assessment, SignalAccumulator
from fixture_ulog import synthetic_ulog


class ClarityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-clarity-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.database = self.root / 'library' / 'library.sqlite'
        self.db = analyzer.open_database(self.database)
        self.addCleanup(self.db.close)

    def log(self, name, drone='controller', status='ok', flight=None, messages=None, topics=None):
        identity = hashlib.sha256(name.encode()).hexdigest()
        value = analyzer.base_log(self.root / (name + '.ulg'), self.root, identity, 1)
        value.update(droneID=drone, status=status, flightSeconds=flight, durationSeconds=10,
                     messages=messages or [], topics=topics or [], date='2026-01-01')
        value['metadata']['parserVersion'] = analyzer.PARSER_VERSION
        analyzer.remember_log(self.db, value)
        self.db.commit()
        return value

    def message(self, level='WARNING', text='Battery signal', family='Batterie'):
        return {'id': level + text, 'timestampSeconds': 1, 'text': text, 'level': level,
                'family': family, 'isAlert': repository.PRIORITIES.get(level, 0) >= 4,
                'title': text, 'groupKey': family + '|' + level + '|' + text}

    def cache(self, value, events=None, parser=None):
        detail = copy.deepcopy(value)
        if events is not None:
            detail['events'] = events
        self.db.execute('INSERT OR REPLACE INTO flight_details VALUES(?,?,?)',
                        (value['id'], parser or analyzer.PARSER_VERSION, json.dumps(detail)))
        self.db.commit()

    def query(self, **request):
        return repository.query(self.db, request)

    def selected(self, value, **request):
        return self.query(scope={'logIDs': [value['id']], **request.pop('scope', {})}, **request)['snapshot']['logs'][0]

    def test_flight_totals_are_global_scoped_and_distinguish_zero_from_unknown(self):
        self.log('known', flight=4)
        self.log('landed', flight=0)
        self.log('unknown', drone='card:fixture')
        self.log('unidentified', drone='unknown:fixture', status='partial', flight=2)
        self.log('error', status='error', flight=100)
        self.log('negative', flight=-1)
        self.log('string', flight='20')
        page = self.query(limit=1)
        self.assertEqual(page['totals']['flightSeconds'], 6)
        self.assertEqual(page['totals']['flightLogCount'], 3)
        self.assertEqual(page['totals']['scannedDroneCount'], 1)
        self.assertEqual(page['totals']['provisionalDroneCount'], 2)
        self.assertEqual(page['totals']['droneCount'], 3)
        self.assertEqual(page['totals']['logs'], 7)
        self.assertEqual(self.query(limit=1, cursor=page['nextCursor'])['totals'], page['totals'])
        selected = self.query(scope={'droneKeys': ['ulog:card:fixture']})['totals']
        self.assertIsNone(selected['flightSeconds'])
        self.assertEqual(selected['flightLogCount'], 0)
        selected = self.query(scope={'logIDs': [hashlib.sha256(b'landed').hexdigest()]})['totals']
        self.assertEqual(selected['flightSeconds'], 0)
        self.assertEqual(selected['flightLogCount'], 1)
        self.assertIsNone(self.query(scope={'logIDs': ['missing']})['totals']['flightSeconds'])

    def test_flight_totals_respect_compact_message_filter(self):
        self.log('one', flight=5, messages=[self.message()])
        self.log('two', flight=40, messages=[self.message('INFO', 'GPS ready', 'GNSS')])
        result = self.query(scope={'families': ['Batterie']}, limit=1)
        self.assertEqual((result['totals']['flightSeconds'], result['totals']['flightLogCount']), (5, 1))

    def test_unknown_reading_and_partial_reading_do_not_claim_no_signals(self):
        for status in ('error', 'partial'):
            value = self.log(status, status=status)
            self.assertEqual(self.selected(value)['signalAssessment']['state'], 'unknown')
        self.assertEqual(self.selected(self.log('complete'))['signalAssessment']['state'], 'none')
        unknown = self.log('unknown-level', messages=[self.message('UNKNOWN')])
        self.assertEqual(self.selected(unknown)['signalAssessment']['state'], 'unknown')

    def test_untranslated_events_retain_max_firmware_severity_and_counts(self):
        value = self.log('event-log', status='partial', topics=['event'], messages=[self.message('WARNING')])
        self.cache(value, [{'eventID': 42, 'internalLevelName': 'ERROR', 'externalLevelName': 'CRITICAL',
                            'translationStatus': 'unknown', 'message': None},
                           {'eventID': 43, 'internalLevelName': 'INFO', 'externalLevelName': 'INFO',
                            'translationStatus': 'translated', 'message': 'Ready'}])
        result = self.selected(value)['signalAssessment']
        self.assertEqual(result, {'state': 'critical', 'level': 'CRITICAL', 'primaryText': 'Événement PX4 42',
                                  'occurrenceCount': 2, 'eventCount': 2, 'untranslatedEventCount': 1})
        self.assertEqual(analyzer.snapshot(self.db)['logs'][0]['signalAssessment'], result)
        event_only = self.log('events-only', topics=['event'])
        self.cache(event_only, [{'eventID': 42, 'internalLevelName': 'ERROR', 'translationStatus': 'unknown'}])
        selected = self.selected(event_only)
        self.assertEqual(selected['signalAssessment']['state'], 'error')
        self.assertFalse(selected['summaryHasAlerts'])

    def test_filtered_messages_exclude_events_failsafe_and_masked_text(self):
        value = self.log('filtered', topics=['event'], messages=[self.message('ERROR', 'Failsafe activated'), self.message('INFO', 'GPS ready', 'GNSS')])
        value['failsafeObserved'] = True
        analyzer.remember_log(self.db, value); self.db.commit()
        self.cache(value, [{'eventID': 42, 'internalLevelName': 'CRITICAL', 'translationStatus': 'unknown'}])
        filtered = self.selected(value, scope={'search': 'GPS'})['signalAssessment']
        self.assertEqual((filtered['state'], filtered['occurrenceCount'], filtered['eventCount']), ('none', 0, 0))
        scoped = self.selected(value, scope={'search': 'GPS'})
        self.assertFalse(scoped['selectionIncludesEvents'])
        self.assertFalse(scoped['selectionIncludesFailsafe'])
        masked = self.selected(value, maskedMessageKeys=[repository.classification_key(value['messages'][0])])['signalAssessment']
        self.assertEqual((masked['state'], masked['occurrenceCount']), ('critical', 1))
        self.cache(value, [])
        masked = self.selected(value, maskedMessageKeys=[repository.classification_key(value['messages'][0])])['signalAssessment']
        self.assertEqual((masked['state'], masked['occurrenceCount']), ('none', 0))

    def test_legacy_or_previous_event_cache_degrades_absence_but_keeps_signal(self):
        value = self.log('legacy', topics=['event'])
        self.cache(value)
        self.assertEqual(self.selected(value)['signalAssessment']['state'], 'unknown')
        self.cache(value, [], parser='previous')
        self.assertEqual(self.selected(value)['signalAssessment']['state'], 'unknown')
        self.cache(value, [{'eventID': 7, 'level': 'ERROR', 'translationStatus': 'unknown'}], parser='previous')
        self.assertEqual(self.selected(value)['signalAssessment']['state'], 'error')

    def test_failsafe_counts_only_once_if_already_observed_in_text(self):
        value = self.log('failsafe', messages=[self.message('ERROR', 'Failsafe activated')])
        value['failsafeObserved'] = True
        self.assertEqual(assessment(value)['occurrenceCount'], 1)
        accumulator = SignalAccumulator()
        accumulator.observe_message(self.message('INFO', 'Voltage [ALARM]'), count=3)
        self.assertEqual(accumulator.result(value, events_complete=True)['occurrenceCount'], 4)
        self.assertEqual(accumulator.result(value, events_complete=True)['state'], 'warning')

    def test_projection_six_read_only_requires_preparation_then_migrates_without_ulog(self):
        value = self.log('migration', flight=3)
        self.query()
        summaries = list(self.db.execute('SELECT summary FROM logs'))
        revisions = list(self.db.execute('SELECT payload FROM analysis_revisions'))
        self.db.execute('ALTER TABLE kl_logs DROP COLUMN signal_messages_json')
        self.db.execute('DROP INDEX kl_logs_flight_totals')
        self.db.execute('ALTER TABLE kl_logs DROP COLUMN flight_seconds')
        self.db.execute('ALTER TABLE kl_event_cache DROP COLUMN signal_events_json')
        self.db.execute("UPDATE kl_meta SET value='6' WHERE key='projectionVersion'"); self.db.commit()
        reader = analyzer.open_database(self.database, read_only=True)
        try:
            with self.assertRaisesRegex(ValueError, 'index doit être actualisé'):
                repository.query(reader, {}, read_only=True)
        finally:
            reader.close()
        with patch.object(analyzer, 'analyze_file', side_effect=AssertionError('No ULog reparsing')):
            result = self.query()
        self.assertEqual(result['totals']['flightSeconds'], 3)
        self.assertEqual(list(self.db.execute('SELECT summary FROM logs')), summaries)
        self.assertEqual(list(self.db.execute('SELECT payload FROM analysis_revisions')), revisions)
        self.assertTrue(Path(self.db.execute("SELECT value FROM settings WHERE key='indexMigrationBackup'").fetchone()[0]).is_file())

    def test_source_retirement_restart_restore_preserves_all_history_and_shared_duplicates(self):
        first, second = self.root / 'first', self.root / 'second'
        first.mkdir(); second.mkdir()
        for path in (first / 'one.ulg', first / 'duplicate.ulg', second / 'same.ulg'):
            path.write_bytes(synthetic_ulog())
        analyzer.scan(first, self.database); analyzer.scan(second, self.database)
        before = {table: [tuple(row) for row in self.db.execute('SELECT * FROM ' + table)]
                  for table in ('logs', 'sources', 'files', 'analysis_revisions')}
        annotations = self.database.parent / 'annotations.json'; annotations.write_text('{"stockNumbers":{"fixture":"17"}}')
        retired = sources.set_removed(self.database, first, True)
        self.assertEqual((retired['activeCount'], retired['removedCount']), (1, 1))
        self.assertFalse(retired['logsDeleted'])
        reader = analyzer.open_database(self.database, read_only=True)
        try:
            self.assertEqual(analyzer.snapshot(reader)['sourceFolders'], [str(second)])
            self.assertEqual(len(analyzer.snapshot(reader)['logs'][0]['sourcePaths']), 3)
        finally:
            reader.close()
        listed = sources.source_folders(self.database, include_removed=True)
        self.assertEqual([item['logCount'] for item in listed['folders']], [1, 1])
        self.assertEqual(len(sources.source_folders(self.database)['folders']), 1)
        restored = sources.set_removed(self.database, first, False)
        self.assertEqual((restored['activeCount'], restored['removedCount']), (2, 0))
        self.assertEqual(sources.set_removed(self.database, first, False), restored)
        self.assertEqual({table: [tuple(row) for row in self.db.execute('SELECT * FROM ' + table)] for table in before}, before)
        self.assertEqual(annotations.read_text(), '{"stockNumbers":{"fixture":"17"}}')
        self.assertTrue(all(path.is_file() for path in first.glob('*.ulg')))

    def test_global_source_pagination_and_query_roots_ignore_page_paths(self):
        value = self.log('one')
        for number in range(3):
            path = self.root / ('root-%d' % number)
            path.mkdir()
            self.db.execute('INSERT INTO folders VALUES(?)', (str(path),))
            self.db.execute('INSERT INTO sources VALUES(?,?)', (value['id'], str(path / 'deep' / 'copy.ulg')))
        self.db.commit()
        first = sources.source_folders(self.database, limit=1)
        self.assertEqual((first['activeCount'], first['total'], first['nextOffset']), (3, 3, 1))
        second = sources.source_folders(self.database, limit=1, offset=1)
        self.assertNotEqual(first['folders'][0]['path'], second['folders'][0]['path'])
        roots = [str(self.root / ('root-%d' % n)) for n in range(3)]
        self.assertEqual(self.query(limit=1)['snapshot']['sourceFolders'], roots)
        sources.set_removed(self.database, roots[0], True)
        self.assertEqual(self.query(limit=1)['snapshot']['sourceFolders'], roots[1:])

    def test_explicit_manual_scan_restores_retired_root(self):
        folder = self.root / 'manual'; folder.mkdir()
        (folder / 'one.ulg').write_bytes(synthetic_ulog())
        analyzer.scan(folder, self.database)
        sources.set_removed(self.database, folder, True)
        self.assertEqual(sources.source_folders(self.database)['activeCount'], 0)
        analyzer.scan(folder, self.database)
        self.assertEqual(sources.source_folders(self.database)['activeCount'], 1)

    def test_reassociation_registers_and_restores_only_roots_with_matched_logs(self):
        original = self.root / 'original'; original.mkdir()
        data = synthetic_ulog()
        (original / 'one.ulg').write_bytes(data)
        analyzer.scan(original, self.database)
        matched = self.root / 'matched'; matched.mkdir()
        (matched / 'same.ulg').write_bytes(data)
        result = archives.reassociate(self.database, matched)
        self.assertEqual(result['matched'], 1)
        self.assertIn(str(matched), sources.active_folders(self.db))
        sources.set_removed(self.database, matched, True)
        self.assertNotIn(str(matched), sources.active_folders(self.db))
        archives.reassociate(self.database, matched)
        self.assertIn(str(matched), sources.active_folders(self.db))
        unrelated = self.root / 'unrelated'; unrelated.mkdir()
        (unrelated / 'other.ulg').write_bytes(b'Unrelated public fixture, never parsed')
        self.assertEqual(archives.reassociate(self.database, unrelated)['matched'], 0)
        self.assertNotIn(str(unrelated), sources.active_folders(self.db))

    def test_source_commands_write_reviewable_json_and_unknown_root_is_rejected(self):
        folder = self.root / 'cli'; folder.mkdir()
        self.db.execute('INSERT INTO folders VALUES(?)', (str(folder),)); self.db.commit()
        output = self.root / 'result.json'
        for command in ('retire-source', 'restore-source'):
            self.assertEqual(analyzer.main([command, '--database', str(self.database), '--folder', str(folder), '--output', str(output)]), 0)
            self.assertEqual(json.loads(output.read_text())['removed'], command == 'retire-source')
        self.assertEqual(analyzer.main(['source-folders', '--database', str(self.database), '--output', str(output), '--limit', '1']), 0)
        self.assertEqual(json.loads(output.read_text())['total'], 1)
        with self.assertRaisesRegex(ValueError, 'source enregistrée'):
            sources.set_removed(self.database, self.root / 'other', True)

    def test_folder_states_are_explicit_and_old_schema_listing_is_read_only(self):
        self.assertEqual(sources.folder_state(self.root), 'present')
        self.assertEqual(sources.folder_state(self.root / 'missing'), 'missing')
        self.assertEqual(sources.folder_state('/Volumes/KataLog-public-fixture/missing'), 'offline')
        with patch.object(sources.os, 'scandir', side_effect=PermissionError):
            self.assertEqual(sources.folder_state(self.root), 'inaccessible')
        self.db.execute('DROP TABLE source_folder_retirements')
        self.db.execute('INSERT INTO folders VALUES(?)', (str(self.root),)); self.db.commit()
        before = self.database.read_bytes()
        self.assertEqual(sources.source_folders(self.database)['activeCount'], 1)
        self.assertEqual(self.database.read_bytes(), before)

    def test_folder_counts_boundaries_unicode_dedup_and_legacy_without_index(self):
        roots = ['/', '/synthetic/root', '/synthetic/root-other',
                 '/synthetic/racine-é', '/synthetic/racine-éclair']
        self.db.executemany('INSERT INTO folders VALUES(?)', ((root,) for root in roots))
        rows = [('duplicate', '/synthetic/root/one.ulg'), ('duplicate', '/synthetic/root/deep/copy.ulg'),
                ('second', '/synthetic/root/two.ulg'), ('sibling', '/synthetic/root-other/one.ulg'),
                ('unicode', '/synthetic/racine-é/one.ulg'), ('unicode-sibling', '/synthetic/racine-éclair/one.ulg'),
                ('absolute', '/absolute.ulg'), ('relative', 'relative.ulg')]
        self.db.executemany('INSERT INTO sources VALUES(?,?)', rows)
        self.db.commit()
        expected = {'/': 6, '/synthetic/root': 2, '/synthetic/root-other': 1,
                    '/synthetic/racine-é': 1, '/synthetic/racine-éclair': 1}
        def counts():
            return {row['path']: row['logCount'] for row in sources.source_folders(self.database)['folders']}
        self.assertEqual(counts(), expected)
        plan = [row[3] for row in self.db.execute('EXPLAIN QUERY PLAN SELECT COUNT(DISTINCT log_id) FROM sources WHERE path>=? AND path<?', ('/synthetic/root/', '/synthetic/root0'))]
        self.assertTrue(any('SEARCH sources USING COVERING INDEX sources_path_log' in row for row in plan), plan)
        # Existing read-only libraries remain usable until their writer has
        # added the optimization; a query must never perform DDL itself.
        self.db.execute('DROP INDEX sources_path_log'); self.db.commit()
        before = self.database.read_bytes()
        self.assertEqual(counts(), expected)
        self.assertEqual(self.database.read_bytes(), before)
        self.assertFalse(self.db.execute("SELECT 1 FROM sqlite_master WHERE type='index' AND name='sources_path_log'").fetchone())
        writer = analyzer.open_database(self.database)
        try:
            self.assertTrue(writer.execute("SELECT 1 FROM sqlite_master WHERE type='index' AND name='sources_path_log'").fetchone())
        finally:
            writer.close()
        self.assertEqual(counts(), expected)


if __name__ == '__main__':
    unittest.main()
