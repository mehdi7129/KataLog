"""Output collisions must be rejected before importing or mutating library data."""
import contextlib
import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources')]
import analyzer
import output_paths
import library_storage
from fixture_ulog import synthetic_ulog


class OutputPathTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='katalog-output-paths-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'original.ulg'
        self.original = synthetic_ulog(samples=3)
        self.source.write_bytes(self.original)
        self.library = self.root / 'library'
        self.database = self.library / 'library.sqlite'
        result = analyzer.scan(self.source, self.database)
        self.identity = result['logs'][0]['id']

    def main(self, arguments):
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as errors:
            status = analyzer.main(arguments)
        return status, errors.getvalue()

    def assert_rejected(self, arguments):
        before = self.database.read_bytes()
        status, error = self.main(arguments)
        self.assertEqual(status, 1, error)
        self.assertIn('sortie', error.lower())
        self.assertEqual(self.database.read_bytes(), before)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_direct_scan_cannot_replace_database(self):
        before = self.database.read_bytes()
        with self.assertRaisesRegex(ValueError, 'sortie'):
            analyzer.scan(self.source, self.database, output=self.database)
        self.assertEqual(self.database.read_bytes(), before)

    def test_direct_detail_cannot_replace_database(self):
        before = self.database.read_bytes()
        with self.assertRaisesRegex(ValueError, 'sortie'):
            analyzer.detail(self.identity, self.database, output=self.database)
        self.assertEqual(self.database.read_bytes(), before)

    def test_direct_refresh_cannot_replace_database(self):
        before = self.database.read_bytes()
        with self.assertRaisesRegex(ValueError, 'sortie'):
            analyzer.refresh_analysis(self.database, output=self.database)
        self.assertEqual(self.database.read_bytes(), before)

    def test_scan_progress_cannot_modify_original_before_analysis(self):
        new_database = self.root / 'fresh' / 'library.sqlite'
        with self.assertRaisesRegex(ValueError, 'sortie'):
            analyzer.scan(self.source, new_database, progress=self.source)
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertFalse(new_database.exists())

    def test_scan_json_cannot_replace_original(self):
        with self.assertRaisesRegex(ValueError, 'sortie'):
            analyzer.scan(self.source, self.database, output=self.source)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_main_protects_previously_imported_sources(self):
        self.assert_rejected(['snapshot', '--database', str(self.database), '--output', str(self.source)])

    def test_source_symlink_cannot_be_replaced(self):
        alias = self.root / 'source-alias.json'
        alias.symlink_to(self.source)
        self.assert_rejected(['snapshot', '--database', str(self.database), '--output', str(alias)])
        self.assertTrue(alias.is_symlink())

    def test_database_hardlink_cannot_be_replaced(self):
        alias = self.root / 'database-alias.json'
        os.link(self.database, alias)
        before_inode = alias.stat().st_ino
        self.assert_rejected(['snapshot', '--database', str(self.database), '--output', str(alias)])
        self.assertEqual(alias.stat().st_ino, before_inode)

    def test_database_parent_symlink_cannot_bypass_guard(self):
        alias = self.root / 'library-alias'
        alias.symlink_to(self.library, target_is_directory=True)
        self.assert_rejected(['snapshot', '--database', str(self.database), '--output', str(alias / 'library.sqlite')])

    def test_literal_tilde_in_relative_output_matches_the_actual_writer_path(self):
        database = self.root / '~' / 'library.sqlite'
        with contextlib.chdir(self.root):
            with self.assertRaisesRegex(ValueError, 'sortie'):
                analyzer.scan(self.source, database, output='~/library.sqlite')
        self.assertFalse(database.exists())

    def test_database_alias_also_reserves_its_real_library_controls(self):
        alias = self.root / 'aliased.sqlite'
        alias.symlink_to(self.database)
        config = self.library / 'annotations.json'
        self.assert_rejected(['snapshot', '--database', str(alias), '--output', str(config)])
        self.assertFalse(config.exists())

    def test_control_files_and_sidecars_are_reserved_before_creation(self):
        names = ('library.sqlite-wal', 'library.sqlite-shm', 'library.sqlite-journal', 'gcs-queue.sqlite',
                 '.library-writer.lock', '.restore-journal.json', '.archive-journal.json',
                 'annotations.json', 'views.json', 'fleet.json', 'settings.json',
                 'gcs-collection.json', 'gcs-settings.json', 'import-options.json')
        for name in names:
            with self.subTest(name=name):
                target = self.library / name
                before = target.read_bytes() if target.exists() else None
                self.assert_rejected(['snapshot', '--database', str(self.database), '--output', str(target)])
                self.assertEqual(target.read_bytes() if target.exists() else None, before)

    def test_output_and_progress_must_differ(self):
        output = self.root / 'result.json'
        before = self.database.read_bytes()
        with self.assertRaisesRegex(ValueError, 'sortie'):
            analyzer.scan(self.source, self.database, output=output, progress=output)
        self.assertEqual(self.database.read_bytes(), before)
        self.assertFalse(output.exists())

    def test_missing_database_and_outputs_reserve_case_and_normalization_variants(self):
        new_database = self.root / 'fresh' / 'library.sqlite'
        with self.assertRaisesRegex(ValueError, 'sortie'):
            analyzer.scan(self.source, new_database, output=new_database.with_name('Library.sqlite'))
        self.assertFalse(new_database.exists())
        with self.assertRaisesRegex(ValueError, 'sortie'):
            analyzer.scan(self.source, new_database, output=self.root / 'RÉSULTAT.json', progress=self.root / 're\u0301sultat.json')
        self.assertFalse(new_database.exists())

    def test_additional_html_output_is_validated_before_creating_database(self):
        new_database = self.root / 'fresh' / 'library.sqlite'
        with self.assertRaisesRegex(ValueError, 'sortie'):
            analyzer.scan(self.source, new_database, additional_outputs=(new_database,))
        self.assertFalse(new_database.exists())

    def test_engine_entry_file_is_protected_even_with_a_custom_filename(self):
        engine = self.root / 'custom-engine.py'
        engine.write_text('# synthetic engine entry')
        with patch.object(analyzer, '__file__', str(engine)):
            with self.assertRaisesRegex(ValueError, 'sortie'):
                analyzer.scan(self.source, self.database, output=engine)
        self.assertEqual(engine.read_text(), '# synthetic engine entry')

    def test_new_query_result_uses_indexed_lookup_without_traversing_originals(self):
        paths = [str(self.root / 'unavailable' / f'{index}.ulg') for index in range(2000)]
        with sqlite3.connect(self.database) as db:
            db.executemany('INSERT INTO sources VALUES(?,?)', [(self.identity, path) for path in paths])
        with patch.object(output_paths, 'path_identity', wraps=output_paths.path_identity) as identities:
            output_paths.validate_outputs((self.root / 'new-result.json',), database=self.database)
        inspected = {str(call.args[0]) for call in identities.call_args_list}
        self.assertNotIn(str(self.source), inspected)
        self.assertTrue(set(paths).isdisjoint(inspected))
        self.assertLess(len(inspected), 50)

    def test_missing_recorded_source_path_is_still_reserved(self):
        self.source.unlink()
        with self.assertRaisesRegex(ValueError, 'sortie'):
            output_paths.validate_outputs((self.source,), database=self.database)
        self.assertFalse(self.source.exists())

    def test_storage_new_result_never_opens_corrupt_active_database_or_sidecars(self):
        files = [Path(str(self.database) + suffix) for suffix in ('', '-wal', '-shm')]
        for path in files:
            path.write_bytes(('synthetic corrupt ' + path.name).encode())
        before = {path: path.read_bytes() for path in files}
        result = self.root / 'restored.json'
        with patch.object(output_paths.sqlite3, 'connect', side_effect=AssertionError('Active SQLite must not be opened')), \
                patch.object(library_storage, 'restore', return_value={'restored': True}) as restore:
            status, error = self.main(['restore', '--archive', str(self.root / 'backup.zip'), '--library', str(self.library), '--output', str(result)])
        self.assertEqual(status, 0, error)
        restore.assert_called_once()
        self.assertEqual({path: path.read_bytes() for path in files}, before)

    def test_storage_existing_result_reads_only_copies_and_preserves_sidecars(self):
        archive = self.root / 'backup.zip'
        library_storage.backup(self.library, archive)
        result = self.root / 'restored.json'
        result.write_text('{}')
        active = sqlite3.connect(self.database)
        self.addCleanup(active.close)
        active.execute("INSERT INTO settings VALUES('syntheticPendingWAL','true')")
        active.commit()
        files = [Path(str(self.database) + suffix) for suffix in ('', '-wal', '-shm')]
        before = {path: path.read_bytes() for path in files}
        connect = output_paths.sqlite3.connect
        opened = []

        def connect_copy(location, **kwargs):
            opened.append(location)
            self.assertNotIn(self.database.as_uri(), location)
            return connect(location, **kwargs)

        with patch.object(output_paths.sqlite3, 'connect', side_effect=connect_copy), \
                patch.object(library_storage, 'restore', return_value={'restored': True}):
            status, error = self.main(['restore', '--archive', str(self.root / 'backup.zip'), '--library', str(self.library), '--output', str(result)])
        self.assertEqual(status, 0, error)
        self.assertTrue(opened)
        self.assertEqual({path: path.read_bytes() for path in files}, before)
        self.assertEqual(json.loads(result.read_text()), {'restored': True})

    def test_storage_corrupt_library_with_existing_result_is_rejected_without_changes(self):
        library_storage.backup(self.library, self.root / 'backup.zip')
        self.database.write_bytes(b'synthetic corrupt active database')
        result = self.root / 'existing.json'
        result.write_text('existing result')
        with patch.object(library_storage, 'restore', side_effect=AssertionError('Must reject before restore')):
            self.assert_rejected(['restore', '--archive', str(self.root / 'backup.zip'), '--library', str(self.library), '--output', str(result)])
        self.assertEqual(result.read_text(), 'existing result')

    def test_pending_restore_never_opens_active_sqlite_even_through_database_alias(self):
        journal = self.library / '.restore-journal.json'
        journal.symlink_to(self.root / 'missing-journal')
        alias = self.root / 'database-alias.sqlite'
        alias.symlink_to(self.database)
        with patch.object(output_paths.sqlite3, 'connect', side_effect=AssertionError('Recovery must finish first')):
            output_paths.validate_outputs((self.root / 'new-result.json',), database=alias)

    def test_repeated_backup_and_restore_allow_existing_healthy_status_result(self):
        archive, result = self.root / 'backup.zip', self.root / 'status.json'
        backup = ['backup', '--library', str(self.library), '--destination', str(archive), '--output', str(result)]
        restore = ['restore', '--archive', str(archive), '--library', str(self.library), '--output', str(result)]
        for arguments in (backup, backup, restore, restore):
            status, error = self.main(arguments)
            self.assertEqual(status, 0, error)
        self.assertEqual(self.source.read_bytes(), self.original)

    def test_restore_result_cannot_replace_a_source_only_known_by_incoming_backup(self):
        incoming_source = self.root / 'incoming-original.ulg'
        incoming_bytes = synthetic_ulog(drone_name='Incoming synthetic drone', samples=3)
        incoming_source.write_bytes(incoming_bytes)
        incoming_library = self.root / 'incoming-library'
        analyzer.scan(incoming_source, incoming_library / 'library.sqlite')
        archive = self.root / 'incoming.zip'
        library_storage.backup(incoming_library, archive)
        self.assert_rejected(['restore', '--archive', str(archive), '--library', str(self.library), '--output', str(incoming_source)])
        self.assertEqual(incoming_source.read_bytes(), incoming_bytes)

    def test_reset_result_collision_is_rejected_before_reset(self):
        config = self.library / 'annotations.json'
        config.write_text('{}')
        self.assert_rejected(['reset-library', '--database', str(self.database), '--library', str(self.library), '--output', str(config)])
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM logs').fetchone()[0], 1)
        self.assertEqual(config.read_text(), '{}')

    def test_request_collision_is_rejected_before_creating_client(self):
        request = self.root / 'request.json'
        request.write_text(json.dumps({'name': 'Synthetic client'}))
        before = request.read_bytes()
        self.assert_rejected(['create-client', '--database', str(self.database), '--request', str(request), '--output', str(request)])
        self.assertEqual(request.read_bytes(), before)
        with sqlite3.connect(self.database) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM clients').fetchone()[0], 0)

    def test_report_result_cannot_replace_capture_or_generated_report_files(self):
        capture, destination = self.root / 'capture', self.root / 'prepared-report'
        for target in (capture / 'library.sqlite', capture / 'context.json', destination / 'rapport.json'):
            with self.subTest(target=target):
                self.assert_rejected(['export-captured', '--capture', str(capture), '--destination', str(destination), '--output', str(target)])
                self.assertFalse(target.exists())
                self.assertFalse(destination.exists())

    def test_default_json_and_progress_names_and_reports_in_source_folder_remain_allowed(self):
        output, progress = self.library / 'library.json', self.library / 'progress.json'
        result = analyzer.scan(self.root, self.database, output=output, progress=progress)
        self.assertEqual(json.loads(output.read_text())['importStats'], result['importStats'])
        self.assertEqual(json.loads(progress.read_text())['completed'], 1)
        report = self.root / 'report.json'
        status, error = self.main(['snapshot', '--database', str(self.database), '--output', str(report)])
        self.assertEqual(status, 0, error)
        self.assertEqual(json.loads(report.read_text())['logs'][0]['id'], self.identity)
        self.assertEqual(self.source.read_bytes(), self.original)


if __name__ == '__main__':
    unittest.main()
