"""Public revision-retention fixtures: no source logs or personal identifiers."""
import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources')]
import analyzer
import library_archives as archives
import library_repository as repository
import library_storage as storage
from fixture_ulog import synthetic_ulog


class AnalysisRevisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-revisions-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.library = self.root / 'library'
        self.file = self.root / 'public.ulg'
        self.file.write_bytes(synthetic_ulog())
        self.database = self.library / 'library.sqlite'
        with patch.object(analyzer, 'PARSER_VERSION', '1.3.0'):
            self.log = analyzer.scan(self.file, self.database, skip_snapshot=True)
            self.identity = hashlib.sha256(self.file.read_bytes()).hexdigest()
            self.old_detail = analyzer.detail(self.identity, self.database)

    def versions(self):
        analyzer.scan(self.file, self.database, skip_snapshot=True)
        self.new_detail = analyzer.detail(self.identity, self.database)
        return analyzer.analysis_revisions(self.identity, self.database, read_only=True)

    def test_two_versions_are_immutable_readable_without_sources_and_paginated(self):
        result = self.versions()
        self.assertEqual(result['total'], 4)
        self.assertEqual({(row['kind'], row['parserVersion']) for row in result['revisions']},
                         {('summary', '1.3.0'), ('detail', '1.3.0'), ('summary', analyzer.PARSER_VERSION), ('detail', analyzer.PARSER_VERSION)})
        self.assertEqual(sum(row['current'] for row in result['revisions']), 2)
        first = analyzer.analysis_revisions(self.identity, self.database, limit=2, read_only=True)
        second = analyzer.analysis_revisions(self.identity, self.database, offset=first['nextOffset'], limit=2, read_only=True)
        self.assertEqual(first['revisions'] + second['revisions'], result['revisions'])
        self.file.unlink()
        before = self.database.read_bytes()
        for row in result['revisions']:
            with patch.object(analyzer, 'analyze_file', side_effect=AssertionError('Historical reads must not parse sources')):
                value = analyzer.detail(self.identity, self.database, read_only=True, revision=row['id'])
            self.assertEqual(value['analysisRevision']['id'], row['id'])
            self.assertEqual(value['metadata']['detailParserVersion'], row['parserVersion'])
            self.assertEqual(value['metadata']['detailCacheStatus'], 'historical')
            self.assertEqual(value['analysisRevision']['createdAtSource'], 'captured')
            self.assertTrue(value['sourceAvailability'])
            self.assertTrue(all(source['state'] == 'missing' for source in value['sourceAvailability']))
        self.assertEqual(self.database.read_bytes(), before)

    def test_repeated_cached_read_and_unchanged_import_do_not_duplicate_revisions(self):
        initial = self.versions()
        analyzer.scan(self.file, self.database, skip_snapshot=True)
        analyzer.detail(self.identity, self.database)
        self.assertEqual(analyzer.analysis_revisions(self.identity, self.database)['revisions'], initial['revisions'])

    def test_budget_refusal_keeps_summary_cache_and_projection_revision(self):
        self.versions()
        db = analyzer.open_database(self.database)
        self.addCleanup(db.close)
        before_logs = list(map(tuple, db.execute('SELECT * FROM logs')))
        before_details = list(map(tuple, db.execute('SELECT * FROM flight_details')))
        revision = db.execute("SELECT value FROM kl_meta WHERE key='revision'").fetchone()[0]
        db.execute("UPDATE settings SET value=? WHERE key='analysisRevisionStorageBytes'", (str(analyzer.MAX_REVISION_STORAGE_BYTES),))
        db.commit()
        value = json.loads(before_logs[0][2]); value['coverage'].append('Synthetic new analysis')
        with self.assertRaisesRegex(analyzer.RevisionBudgetError, '512 Mio'):
            analyzer.remember_log(db, value)
        with patch.object(analyzer, 'PARSER_VERSION', 'future-public-test'):
            with self.assertRaisesRegex(analyzer.RevisionBudgetError, '512 Mio'):
                analyzer.detail(self.identity, self.database)
        self.assertEqual(list(map(tuple, db.execute('SELECT * FROM logs'))), before_logs)
        self.assertEqual(list(map(tuple, db.execute('SELECT * FROM flight_details'))), before_details)
        self.assertEqual(db.execute("SELECT value FROM kl_meta WHERE key='revision'").fetchone()[0], revision)
        self.assertEqual(db.execute('SELECT COUNT(*) FROM kl_dirty').fetchone()[0], 0)

    def test_backup_restore_preserves_all_sha_dates_and_source_free_reads(self):
        expected = self.versions()
        self.file.unlink()
        archive = self.root / 'backup.zip'
        storage.backup(self.library, archive)
        restored = self.root / 'restored'
        storage.restore(archive, restored)
        database = restored / 'library.sqlite'
        actual = analyzer.analysis_revisions(self.identity, database, read_only=True)
        self.assertEqual(actual, expected)
        for row in actual['revisions']:
            value = analyzer.detail(self.identity, database, read_only=True, revision=row['id'])
            self.assertEqual(value['analysisRevision']['analysisSHA256'], row['analysisSHA256'])

    def test_cache_cleanup_retains_last_usable_revision_and_is_reversible(self):
        expected = self.versions()
        self.file.unlink()
        cleaned = archives.clean_detail_cache(self.database, self.library, [self.identity])
        self.assertEqual(cleaned['removedRevisionCount'], 2)
        self.assertEqual(cleaned['retainedRevisionCount'], 2)
        self.assertEqual(analyzer.analysis_revisions(self.identity, self.database)['total'], 2)
        retained = analyzer.detail(self.identity, self.database, read_only=True)
        self.assertEqual(retained['parameters'], self.new_detail['parameters'])
        self.assertEqual(retained['metadata']['detailCacheStatus'], 'previous')
        self.assertFalse(retained['analysisRevision']['current'])
        archives.restore_detail_cache(self.database, cleaned['recoveryDirectory'])
        self.assertEqual(analyzer.analysis_revisions(self.identity, self.database, read_only=True), expected)

    def test_invalid_revision_payload_foreign_identity_and_future_format_refused(self):
        expected = self.versions()
        target = expected['revisions'][0]['id']
        with self.assertRaisesRegex(ValueError, 'n’appartient'):
            analyzer.detail(self.identity, self.database, read_only=True, revision='0' * 64)
        db = analyzer.open_database(self.database)
        db.execute('UPDATE analysis_revisions SET size_bytes=size_bytes+1 WHERE id=?', (target,)); db.commit(); db.close()
        with self.assertRaisesRegex(ValueError, 'Empreinte ou taille'):
            analyzer.detail(self.identity, self.database, read_only=True, revision=target)
        with self.assertRaisesRegex(ValueError, 'Empreinte ou taille'):
            storage.backup(self.library, self.root / 'invalid.zip')
        db = analyzer.open_database(self.database)
        db.execute("UPDATE settings SET value='2' WHERE key='analysisRevisionSchema'"); db.commit(); db.close()
        with self.assertRaisesRegex(ValueError, 'Version des révisions'):
            analyzer.analysis_revisions(self.identity, self.database, read_only=True)

    def test_legacy_migration_records_capture_time_without_inventing_parse_date(self):
        db = analyzer.open_database(self.database)
        db.execute('DROP TABLE analysis_revisions')
        db.execute("DELETE FROM settings WHERE key LIKE 'analysisRevision%'")
        db.commit(); db.close()
        migrated = analyzer.analysis_revisions(self.identity, self.database)
        self.assertEqual(migrated['total'], 2)
        self.assertTrue(all(row['createdAtSource'] == 'captured' and row['current'] for row in migrated['revisions']))
        self.assertEqual({row['parserVersion'] for row in migrated['revisions']}, {'1.3.0'})

    def test_future_revision_schema_refuses_before_wal_or_additive_ddl(self):
        # A newer revision format can coexist with the supported canonical
        # database format. Refusal must preserve that library byte for byte.
        future = self.root / 'future.sqlite'
        db = sqlite3.connect(future)
        db.executescript("""
            PRAGMA user_version=1;
            CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            INSERT INTO settings VALUES('analysisRevisionSchema','2');
        """)
        before_schema = db.execute('SELECT type,name,sql FROM sqlite_master ORDER BY name').fetchall()
        before_journal = db.execute('PRAGMA journal_mode').fetchone()[0]
        db.close()
        before_sha = hashlib.sha256(future.read_bytes()).hexdigest()
        for read_only in (False, True):
            with self.subTest(read_only=read_only):
                with self.assertRaisesRegex(ValueError, 'Version des révisions'):
                    analyzer.open_database(future, read_only=read_only)
                self.assertEqual(hashlib.sha256(future.read_bytes()).hexdigest(), before_sha)
                db = sqlite3.connect(future)
                self.assertEqual(db.execute('SELECT type,name,sql FROM sqlite_master ORDER BY name').fetchall(), before_schema)
                self.assertEqual(db.execute('PRAGMA journal_mode').fetchone()[0], before_journal)
                db.close()
                self.assertFalse(Path(str(future) + '-wal').exists())
                self.assertFalse(Path(str(future) + '-shm').exists())

    def test_cli_read_only_list_and_revision_do_not_modify_database(self):
        expected = self.versions()
        output = self.root / 'output.json'
        self.file.unlink()
        before = self.database.read_bytes()
        self.assertEqual(analyzer.main(['analysis-revisions','--log-id',self.identity,'--database',str(self.database),'--output',str(output),'--read-only']), 0)
        self.assertEqual(json.loads(output.read_text()), expected)
        self.assertEqual(analyzer.main(['detail','--log-id',self.identity,'--revision',expected['revisions'][0]['id'],'--database',str(self.database),'--output',str(output),'--read-only']), 0)
        self.assertEqual(json.loads(output.read_text())['analysisRevision']['id'], expected['revisions'][0]['id'])
        self.assertEqual(self.database.read_bytes(), before)


if __name__ == '__main__': unittest.main()
