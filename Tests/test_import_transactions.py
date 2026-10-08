"""Per-file import publication with synthetic ULogs and real SQLite failures."""
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources')]
import analyzer
import library_repository as repository
from fixture_ulog import synthetic_ulog


class ImportTransactionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='katalog-import-transaction-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'public.ulg'
        self.source.write_bytes(synthetic_ulog(samples=3))
        self.identity = analyzer.digest_file(self.source)
        self.database = self.root / 'library' / 'library.sqlite'
        self.client = '00000000-0000-0000-0000-000000000001'
        db = analyzer.open_database(self.database)
        try:
            db.execute('INSERT INTO clients VALUES(?,?)', (self.client, 'Synthetic client'))
            db.commit()
            repository.initialize(db)
        finally:
            db.close()

    def scan(self, source=None):
        return analyzer.scan(source or self.source, self.database, skip_snapshot=True, client_id=self.client)

    def recorded_state(self):
        db = analyzer.open_database(self.database, read_only=True)
        try:
            tables = ('logs', 'flight_details', 'analysis_revisions', 'spatial_tracks',
                      'files', 'sources', 'source_observations', 'log_clients', 'kl_dirty', 'kl_meta')
            state = {table: list(map(tuple, db.execute('SELECT * FROM ' + table + ' ORDER BY 1')))
                     for table in tables}
            state['revision_bytes'] = db.execute("SELECT value FROM settings WHERE key='analysisRevisionStorageBytes'").fetchone()[0]
            return state
        finally:
            db.close()

    def reject_observation(self, identity):
        db = analyzer.open_database(self.database)
        try:
            # Test-generated content IDs contain only hexadecimal characters.
            db.execute("CREATE TRIGGER fixture_reject_observation BEFORE INSERT ON source_observations "
                       "WHEN new.log_id='" + identity + "' BEGIN SELECT RAISE(ABORT,'fixture late write'); END")
            db.commit()
        finally:
            db.close()

    def test_changed_source_publishes_only_retryable_path_error(self):
        original_analyze = analyzer.analyze_file

        def replace_before_parse(path, *args, **kwargs):
            Path(path).write_bytes(synthetic_ulog(drone_name='Replacement', samples=3))
            return original_analyze(path, *args, **kwargs)

        with patch.object(analyzer, 'analyze_file', side_effect=replace_before_parse):
            result = self.scan()
        self.assertEqual(result['importStats']['failed'], 1)
        self.assertEqual(result['importStats']['imported'], 0)
        self.assertNotEqual(analyzer.digest_file(self.source), self.identity)
        failed = self.recorded_state()
        self.assertEqual(len(failed['logs']), 1)
        error_id, _, encoded = failed['logs'][0]
        self.assertTrue(error_id.startswith('unreadable:'))
        error = json.loads(encoded)
        self.assertEqual(error['status'], 'error')
        self.assertIn('changé pendant', error['issues'][0])
        self.assertEqual(failed['sources'], [(error_id, str(self.source))])
        self.assertEqual(failed['log_clients'], [(error_id, self.client)])
        for table in ('analysis_revisions', 'spatial_tracks', 'files', 'source_observations', 'kl_dirty'):
            self.assertEqual(failed[table], [], table)
        self.assertEqual(failed['revision_bytes'], '0')

        retry = self.scan()
        self.assertEqual(retry['importStats']['imported'], 1)
        saved = self.recorded_state()
        self.assertEqual(len(saved['logs']), 1)
        self.assertEqual(saved['logs'][0][0], analyzer.digest_file(self.source))
        self.assertEqual(json.loads(saved['logs'][0][2])['droneName'], 'Replacement')

    def test_changed_source_during_reanalysis_preserves_recorded_analysis(self):
        with patch.object(analyzer, 'PARSER_VERSION', 'public-previous-parser'):
            self.scan()
            analyzer.detail(self.identity, self.database)
        before = self.recorded_state()
        original_analyze = analyzer.analyze_file

        def replace_before_parse(path, *args, **kwargs):
            Path(path).write_bytes(synthetic_ulog(drone_name='Replacement', samples=3))
            return original_analyze(path, *args, **kwargs)

        with patch.object(analyzer, 'analyze_file', side_effect=replace_before_parse):
            result = self.scan()
        self.assertEqual(result['importStats']['failed'], 1)
        after = self.recorded_state()
        self.assertEqual([row for row in after['logs'] if row[0] == self.identity], before['logs'])
        for table in ('flight_details', 'analysis_revisions', 'spatial_tracks', 'source_observations'):
            self.assertEqual(after[table], before[table], table)
        self.assertEqual(after['revision_bytes'], before['revision_bytes'])
        self.assertIn((self.identity, self.client), after['log_clients'])
        self.assertIn((self.identity, str(self.source)), after['sources'])
        self.assertEqual(after['files'], [])  # The changed path must be retried.
        self.assertEqual(after['kl_dirty'], [])

    def test_late_sql_failure_rolls_back_analysis_cache_sources_and_client(self):
        self.scan()
        new_source = self.root / 'new.ulg'
        new_source.write_bytes(synthetic_ulog(drone_name='New public drone', samples=3))
        identity = analyzer.digest_file(new_source)
        self.reject_observation(identity)
        before = self.recorded_state()
        with self.assertRaisesRegex(sqlite3.IntegrityError, 'fixture late write'):
            self.scan(new_source)
        self.assertEqual(self.recorded_state(), before)

    def test_duplicate_name_update_is_rolled_back_and_can_be_retried(self):
        self.scan()
        duplicate = self.root / 'card' / 'duplicate.ulg'
        duplicate.parent.mkdir()
        duplicate.write_bytes(self.source.read_bytes())
        metadata = duplicate.parent / 'data'
        metadata.mkdir()
        (metadata / 'name.txt').write_text('Synthetic card name')
        self.reject_observation(self.identity)
        before = self.recorded_state()
        with patch.object(analyzer, 'analyze_file', side_effect=AssertionError('A duplicate must not be parsed')):
            with self.assertRaisesRegex(sqlite3.IntegrityError, 'fixture late write'):
                self.scan(duplicate)
        self.assertEqual(self.recorded_state(), before)

        db = analyzer.open_database(self.database)
        try:
            db.execute('DROP TRIGGER fixture_reject_observation')
            db.commit()
        finally:
            db.close()
        with patch.object(analyzer, 'analyze_file', side_effect=AssertionError('A duplicate must not be parsed')):
            result = self.scan(duplicate)
        self.assertEqual(result['importStats']['duplicates'], 1)
        after = self.recorded_state()
        self.assertEqual(len(after['logs']), 1)
        self.assertEqual(json.loads(after['logs'][0][2])['droneName'], 'Synthetic card name')
        self.assertEqual({path for _, path in after['sources']}, {str(self.source), str(duplicate)})
        self.assertEqual(after['spatial_tracks'], before['spatial_tracks'])

    def test_error_record_is_not_published_without_its_source(self):
        db = analyzer.open_database(self.database)
        try:
            db.execute("CREATE TRIGGER fixture_reject_error_source BEFORE INSERT ON sources "
                       "WHEN new.log_id LIKE 'unreadable:%' BEGIN SELECT RAISE(ABORT,'fixture error source'); END")
            db.commit()
        finally:
            db.close()
        before = self.recorded_state()
        with patch.object(analyzer, 'digest_file', side_effect=PermissionError('fixture denied')):
            with self.assertRaisesRegex(sqlite3.IntegrityError, 'fixture error source'):
                self.scan()
        self.assertEqual(self.recorded_state(), before)


if __name__ == '__main__':
    unittest.main()
