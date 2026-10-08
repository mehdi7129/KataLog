"""Storage must not hydrate evicted File Provider sources as a side effect."""
import contextlib
import hashlib
import io
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_archives as archives
import library_storage as storage
import local_files


class LocalSourceGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='katalog-local-source-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.library = self.root / 'library'
        self.library.mkdir()
        self.source = self.root / 'a-cloud.ulg'
        self.payload = b'synthetic-preserved-source'
        self.source.write_bytes(self.payload)
        self.identity = hashlib.sha256(self.payload).hexdigest()
        self.database = self.library / 'library.sqlite'
        db = analyzer.open_database(self.database)
        try:
            analyzer.remember_log(db, analyzer.base_log(self.source, self.root, self.identity, len(self.payload)))
            db.execute('INSERT INTO sources VALUES(?,?)', (self.identity, str(self.source)))
            db.commit()
        finally:
            db.close()

    @contextlib.contextmanager
    def evicted(self, *paths):
        paths = set(paths)
        original_stat, original_open, original_copy = Path.stat, Path.open, storage.shutil.copyfile
        attempts = []

        def metadata(path, *args, **kwargs):
            actual = original_stat(path, *args, **kwargs)
            if path not in paths:
                return actual
            values = {name: getattr(actual, name) for name in dir(actual) if name.startswith('st_')}
            values['st_flags'] = values.get('st_flags', 0) | 0x40000000
            return SimpleNamespace(**values)

        def open_local(path, *args, **kwargs):
            if path in paths:
                attempts.append(path)
                raise AssertionError('Cloud source opened before the local guard')
            return original_open(path, *args, **kwargs)

        def copy_local(source, *args, **kwargs):
            if Path(source) in paths:
                attempts.append(source)
                raise AssertionError('Cloud source copied before the local guard')
            return original_copy(source, *args, **kwargs)

        with patch.object(Path, 'stat', metadata), patch.object(Path, 'open', open_local), \
             patch.object(storage.shutil, 'copyfile', copy_local), patch.object(sys, 'platform', 'darwin'):
            yield
        self.assertEqual(attempts, [])

    def add_local_copy(self):
        path = self.root / 'z-local.ulg'
        path.write_bytes(self.payload)
        db = analyzer.open_database(self.database)
        try:
            db.execute('INSERT INTO sources VALUES(?,?)', (self.identity, str(path)))
            db.commit()
        finally:
            db.close()
        return path

    def test_pending_restore_is_rejected_before_inspecting_another_archive(self):
        journal = self.library / '.restore-journal.json'
        journal.write_text('{"restoreVersion":1}')
        before = self.database.read_bytes()
        with patch.object(storage, 'require_local_source', side_effect=AssertionError('archive inspected before recovery gate')):
            with self.assertRaisesRegex(ValueError, 'restauration interrompue'):
                storage.restore(self.root / 'not-yet-read.zip', self.library)
        self.assertEqual(self.database.read_bytes(), before)
        self.assertEqual(journal.read_text(), '{"restoreVersion":1}')

    def test_both_hash_entry_points_refuse_before_open(self):
        with self.evicted(self.source):
            for digest in (analyzer.digest_file, storage.digest):
                with self.subTest(digest=digest.__module__), self.assertRaisesRegex(OSError, 'Finder'):
                    digest(self.source)

    def test_archive_source_and_existing_target_refuse_before_copy_or_hash(self):
        target = self.root / 'archive.ulg'
        with self.evicted(self.source), self.assertRaisesRegex(OSError, 'Finder'):
            archives.verified_archive_copy(self.source, target, self.identity)
        self.assertFalse(target.exists())
        target.write_bytes(self.payload)
        with self.evicted(target), self.assertRaisesRegex(OSError, 'Finder'):
            archives.verified_archive_copy(self.source, target, self.identity)
        self.assertEqual(target.read_bytes(), self.payload)
        self.assertEqual(list(self.root.glob('*.partial')), [])

    def test_archive_uses_local_alias_and_keeps_originals(self):
        local = self.add_local_copy()
        destination = self.root / 'archive'
        with self.evicted(self.source):
            result = archives.archive_logs(self.database, self.library, destination, [self.identity])
        self.assertEqual((result['completed'], result['failed']), (1, 0))
        self.assertEqual((destination / (self.identity + '.ulg')).read_bytes(), self.payload)
        self.assertEqual(local.read_bytes(), self.source.read_bytes())

    def test_reassociate_reports_cloud_source_and_links_local_alias(self):
        local = self.add_local_copy()
        with self.evicted(self.source):
            result = archives.reassociate(self.database, self.root)
        self.assertEqual(result['matched'], 1)
        self.assertEqual(len(result['errors']), 1)
        self.assertIn('Finder', result['errors'][0])
        self.assertEqual(local.read_bytes(), self.source.read_bytes())

    def test_backup_records_unavailable_then_uses_local_alias(self):
        destination = self.root / 'backup.zip'
        with self.evicted(self.source):
            result = storage.backup(self.library, destination, include_ulog=True)
        self.assertEqual((result['archivedLogCount'], result['missingSourceCount']), (0, 1))
        self.assertEqual(result['preflight']['missingSourceCount'], 1)
        with zipfile.ZipFile(destination) as archive:
            self.assertFalse(any(name.endswith('.ulg') for name in archive.namelist()))
        self.add_local_copy()
        with self.evicted(self.source):
            result = storage.backup(self.library, destination, include_ulog=True)
        self.assertEqual((result['archivedLogCount'], result['missingSourceCount']), (1, 0))
        with zipfile.ZipFile(destination) as archive:
            self.assertEqual(archive.read('ulogs/' + self.identity + '.ulg'), self.payload)
        self.assertEqual(self.source.read_bytes(), self.payload)

    def test_backup_refuses_evicted_configuration_and_database(self):
        config = self.library / 'settings.json'
        config.write_text('{"schemaVersion":1}')
        destination = self.root / 'backup.zip'
        with self.evicted(config), self.assertRaisesRegex(OSError, 'Finder'):
            storage.backup(self.library, destination)
        self.assertFalse(destination.exists())
        with self.evicted(self.database), patch.object(storage.sqlite3, 'connect', side_effect=AssertionError('Must check before SQLite open')), self.assertRaisesRegex(OSError, 'Finder'):
            storage.backup(self.library, destination)
        self.assertFalse(destination.exists())

    def test_missing_darwin_constant_still_refuses_placeholder(self):
        with self.evicted(self.source), patch.object(local_files, 'stat_module', SimpleNamespace()), self.assertRaisesRegex(OSError, 'Finder'):
            storage.digest(self.source)

    def test_evicted_backup_and_cache_manifest_refused_before_read(self):
        backup = self.root / 'backup.zip'
        storage.backup(self.library, backup)
        target = self.root / 'new-library'
        with self.evicted(backup):
            for action in (lambda: storage.inspect_backup(backup), lambda: storage.restore(backup, target)):
                with self.assertRaisesRegex(OSError, 'Finder'):
                    action()
        self.assertFalse(target.exists())
        recovery = self.root / 'cache-recovery'
        recovery.mkdir()
        manifest = recovery / 'manifest.json'
        manifest.write_text('{}')
        with self.evicted(manifest), self.assertRaisesRegex(OSError, 'Finder'):
            archives.restore_detail_cache(self.database, recovery)

    def test_restore_cli_checks_cloud_archive_before_existing_result_preflight(self):
        backup = self.root / 'backup.zip'
        storage.backup(self.library, backup)
        output = self.root / 'existing-result.json'
        output.write_text('{"preserved":true}')
        messages = io.StringIO()
        with self.evicted(backup), patch.object(zipfile, 'ZipFile', side_effect=AssertionError('Archive opened before local guard')), contextlib.redirect_stderr(messages):
            result = analyzer.main(['restore', '--archive', str(backup), '--library', str(self.library), '--output', str(output)])
        self.assertEqual(result, 1)
        self.assertIn('Finder', messages.getvalue())
        self.assertEqual(output.read_text(), '{"preserved":true}')

    def test_backup_cli_preflight_checks_cloud_database_and_sidecars(self):
        output = self.root / 'existing-result.json'
        output.write_text('{"preserved":true}')
        destination = self.root / 'backup.zip'
        wal = Path(str(self.database) + '-wal')
        wal.write_bytes(b'synthetic evicted sidecar')
        for target in (self.database, wal):
            messages = io.StringIO()
            with self.subTest(target=target.name), self.evicted(target), contextlib.redirect_stderr(messages):
                result = analyzer.main(['backup', '--library', str(self.library), '--destination', str(destination), '--output', str(output)])
            self.assertEqual(result, 1)
            self.assertIn('Finder', messages.getvalue())
            self.assertFalse(destination.exists())
            self.assertEqual(output.read_text(), '{"preserved":true}')


if __name__ == '__main__':
    unittest.main()
