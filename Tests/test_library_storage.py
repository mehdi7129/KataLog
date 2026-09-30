"""Public fixtures for coherent SQLite backup and reversible restore."""
import hashlib
import json
from pathlib import Path
import sqlite3
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_storage as storage


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-storage-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.library = self.root / 'library'
        self.library.mkdir()
        self.database = self.library / 'library.sqlite'
        db = analyzer.open_database(self.database)
        self.source = self.root / 'original.ulg'
        self.source.write_bytes(b'synthetic-source-read-only')
        self.identity = hashlib.sha256(self.source.read_bytes()).hexdigest()
        log = analyzer.base_log(self.source, self.root, self.identity, self.source.stat().st_size)
        analyzer.remember_log(db, log)
        db.execute('INSERT INTO sources(log_id,path) VALUES(?,?)', (self.identity, str(self.source)))
        db.commit()
        db.close()
        (self.library / 'annotations.json').write_text(json.dumps({'schemaVersion': 1, 'stockNumbers': {'ulog:' + log['droneID']: 'TEST-001'}}))
        (self.library / 'views.json').write_text(json.dumps({'schemaVersion': 1, 'revision': 2, 'views': [], 'maskedMessageKeys': ['text-v1:7:WARNINGfixture']}))
        (self.library / 'gcs-collection.json').write_text(json.dumps({'schemaVersion': 1, 'host': '', 'downloadDirectory': str(self.root / 'collection'), 'reconnect': True, 'queue': [{'id': 'job-test', 'state': 'downloading'}]}))
        (self.library / 'import-options.json').write_text(json.dumps({'schemaVersion': 1, 'archiveDirectory': str(self.root / 'chosen-archive')}))
        self.destination = self.root / 'backup.zip'

    def test_sqlite_backup_includes_committed_wal_and_configs(self):
        db = sqlite3.connect(self.database)
        self.addCleanup(db.close)
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('INSERT INTO settings(key,value) VALUES(?,?)', ('fixture', 'committed-WAL'))
        db.commit()
        result = storage.backup(self.library, self.destination)
        self.assertEqual(result['logCount'], 1)
        self.assertEqual(result['archivedLogCount'], 0)
        target = self.root / 'restored'
        storage.restore(self.destination, target)
        restored = sqlite3.connect(target / 'library.sqlite')
        try:
            self.assertEqual(restored.execute("SELECT value FROM settings WHERE key='fixture'").fetchone()[0], 'committed-WAL')
        finally:
            restored.close()
        self.assertEqual(json.loads((target / 'views.json').read_text())['revision'], 2)
        self.assertEqual(json.loads((target / 'import-options.json').read_text())['archiveDirectory'], str(self.root / 'chosen-archive'))

    def test_backup_inspects_same_verified_capture_without_second_database_copy(self):
        original = storage.shutil.copyfileobj
        def refuse_archive_database_extraction(source, destination, *args, **kwargs):
            if isinstance(source, zipfile.ZipExtFile) and str(getattr(destination, 'name', '')).endswith('.sqlite'):
                raise AssertionError('redundant database extraction')
            return original(source, destination, *args, **kwargs)
        with patch.object(storage.shutil, 'copyfileobj', side_effect=refuse_archive_database_extraction):
            result = storage.backup(self.library, self.destination)
        self.assertEqual(result['logCount'], 1)
        # Independent inspection of an externally supplied archive still uses
        # its own staging bytes and cannot trust any original library file.
        with patch.object(storage.shutil, 'copyfileobj', wraps=storage.shutil.copyfileobj) as copier:
            self.assertEqual(storage.inspect_backup(self.destination)['logCount'], 1)
            self.assertGreaterEqual(copier.call_count, 1)

    def test_backup_preflight_counts_state_and_sources_on_destination_volume(self):
        called = []
        original = storage.shutil.disk_usage
        def destination_volume(path):
            called.append(Path(path)); return original(path)
        with patch.object(storage.shutil, 'disk_usage', side_effect=destination_volume):
            result = storage.backup(self.library, self.destination, include_ulog=True)
        preflight = result['preflight']
        self.assertEqual(called, [self.destination.parent.resolve()])
        self.assertEqual(preflight['sourceCount'], 1)
        self.assertEqual(preflight['sourceBytes'], self.source.stat().st_size)
        self.assertEqual(preflight['missingSourceCount'], 0)
        self.assertGreater(preflight['estimatedRequiredBytes'], 2 * (preflight['stateBytes'] + preflight['sourceBytes']))
        self.assertEqual(preflight['estimate'], 'conservative-peak')
        self.assertGreaterEqual(preflight['elapsedSeconds'], 0)

    def test_backup_preflight_insufficient_space_precedes_any_capture(self):
        with patch.object(storage.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 1})()), patch.object(storage, 'copy_database', side_effect=AssertionError('No copy before admission')):
            with self.assertRaisesRegex(ValueError, 'Espace insuffisant'):
                storage.backup(self.library, self.destination, include_ulog=True)
        self.assertFalse(self.destination.exists())
        self.assertEqual(list(self.root.glob('katalog-backup-*')), [])
        self.assertTrue(self.source.exists())

    def test_backup_missing_source_is_counted_in_stat_preflight_and_verified_manifest(self):
        self.source.unlink()
        result = storage.backup(self.library, self.destination, include_ulog=True)
        self.assertEqual(result['preflight']['sourceBytes'], 0)
        self.assertEqual(result['preflight']['missingSourceCount'], 1)
        self.assertEqual(result['missingSourceCount'], 1)

    def test_backup_late_full_disk_keeps_preexisting_archive_and_cleans_staging(self):
        import errno
        self.destination.write_bytes(b'previous backup retained')
        with patch.object(storage, 'copy_database', side_effect=OSError(errno.ENOSPC, 'simulated late full disk')):
            with self.assertRaises(OSError):
                storage.backup(self.library, self.destination, include_ulog=True)
        self.assertEqual(self.destination.read_bytes(), b'previous backup retained')
        self.assertEqual(list(self.root.glob('katalog-backup-*')), [])
        self.assertTrue(self.source.exists())

    def test_complete_restore_relinks_sha_without_touching_original_or_lease(self):
        before = (self.source.read_bytes(), self.source.stat().st_mtime_ns)
        storage.backup(self.library, self.destination, include_ulog=True)
        target = self.root / 'restored'
        target.mkdir()
        lease = target / '.library-writer.lock'
        lease.write_bytes(b'held')
        inode = lease.stat().st_ino
        (target / 'annotations.json').write_text('{"schemaVersion":1,"stockNumbers":{"old":"preserved"}}')
        result = storage.restore(self.destination, target)
        self.assertEqual(lease.stat().st_ino, inode)
        self.assertEqual(lease.read_bytes(), b'held')
        self.assertEqual(result['archivedLogCount'], 1)
        restored = sqlite3.connect(target / 'library.sqlite')
        try:
            paths = [Path(row[0]) for row in restored.execute('SELECT path FROM sources WHERE log_id=?', (self.identity,))]
        finally:
            restored.close()
        new_source = next(path for path in paths if path != self.source)
        self.assertEqual(storage.digest(new_source), self.identity)
        self.assertEqual((self.source.read_bytes(), self.source.stat().st_mtime_ns), before)
        self.assertTrue((Path(result['recoveryDirectory']) / 'before.zip').exists())
        job = json.loads((target / 'gcs-collection.json').read_text())
        self.assertFalse(job['reconnect'])
        self.assertTrue(job['queuePaused'])
        self.assertEqual(job['queue'][0]['state'], 'interrupted')

    def test_missing_original_is_reported_not_claimed_archived(self):
        self.source.unlink()
        result = storage.backup(self.library, self.destination, include_ulog=True)
        self.assertEqual(result['missingSourceCount'], 1)
        self.assertEqual(result['archivedLogCount'], 0)
        self.assertEqual(storage.inspect_backup(self.destination)['missingSourceCount'], 1)

    def rewrite_archive(self, change):
        with zipfile.ZipFile(self.destination) as archive:
            values = {info.filename: archive.read(info.filename) for info in archive.infolist()}
        change(values)
        with zipfile.ZipFile(self.destination, 'w') as archive:
            for name, value in values.items():
                archive.writestr(name, value)

    def test_corruption_rejected_before_active_files_change(self):
        storage.backup(self.library, self.destination)
        self.rewrite_archive(lambda values: values.update({'state/annotations.json': b'broken'}))
        original = (self.library / 'annotations.json').read_bytes()
        with self.assertRaises(ValueError):
            storage.restore(self.destination, self.library)
        self.assertEqual((self.library / 'annotations.json').read_bytes(), original)
        self.assertFalse((self.library / '.restore-journal.json').exists())

    def test_zip_escape_and_symlink_entries_are_rejected(self):
        storage.backup(self.library, self.destination)
        self.rewrite_archive(lambda values: values.update({'../escaped.json': b'bad'}))
        with self.assertRaisesRegex(ValueError, 'non sûre'):
            storage.inspect_backup(self.destination)
        storage.backup(self.library, self.destination)
        with zipfile.ZipFile(self.destination, 'a') as archive:
            info = zipfile.ZipInfo('state/settings.json')
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, 'outside')
        with self.assertRaisesRegex(ValueError, 'non sûre'):
            storage.inspect_backup(self.destination)

    def test_unknown_future_backup_version_is_refused(self):
        storage.backup(self.library, self.destination)
        def future(values):
            manifest = json.loads(values['manifest.json'])
            manifest['backupVersion'] = 99
            values['manifest.json'] = json.dumps(manifest).encode()
        self.rewrite_archive(future)
        with self.assertRaisesRegex(ValueError, 'Version de sauvegarde'):
            storage.inspect_backup(self.destination)

    def test_swap_failure_rolls_back_and_keeps_root_lease(self):
        storage.backup(self.library, self.destination)
        target = self.root / 'target'
        target.mkdir()
        lease = target / '.library-writer.lock'
        lease.write_text('held')
        old = b'{"schemaVersion":1,"stockNumbers":{"old":"TEST-OLD"}}'
        (target / 'annotations.json').write_bytes(old)
        inode = lease.stat().st_ino
        replace = storage.os.replace
        def injected(source, destination):
            if Path(destination) == target / 'library.sqlite' and '.restore-staging-' in str(source):
                raise OSError('synthetic swap failure')
            return replace(source, destination)
        with patch.object(storage.os, 'replace', injected), self.assertRaises(OSError):
            storage.restore(self.destination, target)
        self.assertEqual((target / 'annotations.json').read_bytes(), old)
        self.assertEqual(lease.stat().st_ino, inode)
        self.assertFalse((target / '.restore-journal.json').exists())

    def test_interrupted_swap_recovery_retains_replaced_files(self):
        token = 'a' * 32
        recovery = self.library / ('recovery-' + token)
        original = recovery / 'original-files'
        original.mkdir(parents=True)
        (original / 'annotations.json').write_text('{"schemaVersion":1,"marker":"before"}')
        (self.library / 'annotations.json').write_text('{"schemaVersion":1,"marker":"partially-restored"}')
        storage.atomic_json(self.library / '.restore-journal.json', {'restoreVersion': 1, 'phase': 'prepared', 'recoveryDirectory': recovery.name, 'archiveDirectory': 'restored-ulogs-' + token, 'moved': ['annotations.json'], 'installed': ['annotations.json']})
        result = storage.recover_restore(self.library)
        self.assertTrue(result['recovered'])
        self.assertEqual(json.loads((self.library / 'annotations.json').read_text())['marker'], 'before')
        self.assertEqual(json.loads((recovery / 'interrupted-restored-files' / 'annotations.json').read_text())['marker'], 'partially-restored')


if __name__ == '__main__':
    unittest.main()
