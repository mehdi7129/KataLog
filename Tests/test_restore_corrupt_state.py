"""A verified incoming backup can replace corrupt state without losing its bytes."""
from contextlib import closing
import errno
import hashlib
import json
from pathlib import Path
import sqlite3
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_repository
import library_storage as storage


class CorruptStateRestoreTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='katalog-corrupt-restore-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.incoming = self.library('incoming', b'incoming source')
        self.target = self.library('target', b'original source')
        self.archive = self.root / 'incoming.zip'
        storage.backup(self.incoming, self.archive)

    def library(self, name, contents):
        library = self.root / name
        library.mkdir()
        source = self.root / (name + '.ulg')
        source.write_bytes(contents)
        identity = hashlib.sha256(contents).hexdigest()
        with closing(analyzer.open_database(library / 'library.sqlite')) as db:
            log = analyzer.base_log(source, self.root, identity, source.stat().st_size)
            analyzer.remember_log(db, log)
            db.execute('INSERT INTO sources(log_id,path) VALUES(?,?)', (identity, str(source)))
            db.commit()
            library_repository.initialize(db)
        (library / 'annotations.json').write_text(json.dumps({'schemaVersion': 1, 'marker': name}))
        (library / '.library-writer.lock').write_bytes(b'held')
        return library

    @staticmethod
    def active_bytes(library):
        return {path.name: path.read_bytes() for path in library.iterdir() if path.is_file()}

    def assert_incoming_installed(self):
        with closing(sqlite3.connect(self.target / 'library.sqlite')) as db:
            self.assertEqual(db.execute('SELECT id FROM logs').fetchall(),
                             [(hashlib.sha256(b'incoming source').hexdigest(),)])
        self.assertEqual(json.loads((self.target / 'annotations.json').read_bytes())['marker'], 'incoming')

    def test_corrupt_database_config_and_cache_preserve_exact_raw_bytes(self):
        for kind in ('database', 'json', 'utf8', 'cache'):
            with self.subTest(kind=kind):
                target = self.library('corrupt-' + kind, ('original-' + kind).encode())
                if kind in ('database', 'cache'):
                    name = 'library.sqlite' if kind == 'database' else 'detail-cache.sqlite'
                    (target / name).write_bytes(b'not a database\x00' * 256)
                    (target / (name + '-wal')).write_bytes(b'original invalid WAL')
                    (target / (name + '-shm')).write_bytes(b'original invalid SHM')
                    (target / (name + '-journal')).write_bytes(b'original invalid DELETE journal')
                else:
                    (target / 'annotations.json').write_bytes(b'{"schemaVersion":' if kind == 'json' else b'\xff\xfe\x00')
                before = self.active_bytes(target)
                inode = (target / '.library-writer.lock').stat().st_ino
                result = storage.restore(self.archive, target)
                recovery = Path(result['recoveryDirectory'])
                self.assertFalse((recovery / 'before.zip').exists())
                manifest = json.loads((recovery / 'raw-manifest.json').read_bytes())
                self.assertEqual(manifest['kind'], 'raw-unvalidated-state')
                self.assertTrue(manifest['validationError']['type'])
                entries = {entry['name']: entry for entry in manifest['files']}
                for name, contents in before.items():
                    if name == '.library-writer.lock':
                        continue
                    self.assertEqual((recovery / 'raw-files' / name).read_bytes(), contents)
                    self.assertEqual((recovery / 'original-files' / name).read_bytes(), contents)
                    self.assertEqual(entries[name]['sha256'], hashlib.sha256(contents).hexdigest())
                    self.assertEqual(entries[name]['sizeBytes'], len(contents))
                self.assertEqual((target / '.library-writer.lock').stat().st_ino, inode)
                with closing(sqlite3.connect(target / 'library.sqlite')) as db:
                    self.assertEqual(db.execute('SELECT id FROM logs').fetchall(),
                                     [(hashlib.sha256(b'incoming source').hexdigest(),)])
                self.assertFalse((target / '.restore-journal.json').exists())

    def test_real_restore_cli_preserves_corrupt_database_and_sidecars_before_any_open(self):
        for suffix in ('', '-wal', '-shm', '-journal'):
            (self.target / ('library.sqlite' + suffix)).write_bytes(('corrupt original ' + suffix).encode())
        before = self.active_bytes(self.target)
        output = self.root / 'result.json'
        self.assertEqual(analyzer.main(['restore', '--archive', str(self.archive), '--library', str(self.target),
                                        '--output', str(output)]), 0)
        recovery = Path(json.loads(output.read_bytes())['recoveryDirectory'])
        for name, contents in before.items():
            if name != '.library-writer.lock':
                self.assertEqual((recovery / 'raw-files' / name).read_bytes(), contents)
                self.assertEqual((recovery / 'original-files' / name).read_bytes(), contents)
        self.assert_incoming_installed()

    def test_healthy_state_keeps_coherent_before_zip_without_raw_manifest(self):
        result = storage.restore(self.archive, self.target)
        recovery = Path(result['recoveryDirectory'])
        self.assertEqual(storage.inspect_backup(recovery / 'before.zip')['logCount'], 1)
        self.assertFalse((recovery / 'raw-files').exists())
        self.assertFalse((recovery / 'raw-manifest.json').exists())
        self.assert_incoming_installed()

    def test_hot_delete_journal_is_recovered_only_on_copy_and_cannot_roll_back_incoming(self):
        database = self.target / 'cache.sqlite'
        with closing(sqlite3.connect(database)) as db, db:
            db.execute('PRAGMA journal_mode=DELETE')
            db.execute('CREATE TABLE state(id INTEGER PRIMARY KEY, value BLOB)')
            db.executemany('INSERT INTO state VALUES(?,?)', [(index, b'original' * 600) for index in range(100)])
        script = '''import os,signal,sqlite3,sys
db=sqlite3.connect(sys.argv[1]); db.execute('PRAGMA cache_size=5')
db.execute('PRAGMA synchronous=FULL'); db.execute('BEGIN IMMEDIATE')
db.execute('UPDATE state SET value=?',(b'uncommitted'*600,))
os.kill(os.getpid(),signal.SIGKILL)
'''
        killed = subprocess.run([sys.executable, '-B', '-c', script, str(database)], capture_output=True, timeout=10)
        self.assertEqual(killed.returncode, -signal.SIGKILL, killed.stderr.decode(errors='replace'))
        journal = self.target / 'cache.sqlite-journal'
        self.assertTrue(journal.is_file())
        before = {path.name: path.read_bytes() for path in (database, journal)}
        with closing(sqlite3.connect(self.incoming / 'cache.sqlite')) as db, db:
            db.execute('CREATE TABLE incoming(value TEXT)')
            db.execute("INSERT INTO incoming VALUES('replacement')")
        storage.backup(self.incoming, self.archive)
        result = storage.restore(self.archive, self.target)
        recovery = Path(result['recoveryDirectory'])
        self.assertEqual({name: (recovery / 'original-files' / name).read_bytes() for name in before}, before)
        self.assertFalse((recovery / 'raw-manifest.json').exists())
        self.assertFalse(journal.exists())
        with closing(sqlite3.connect(database)) as db:
            self.assertEqual(db.execute('SELECT value FROM incoming').fetchall(), [('replacement',)])
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
        captured = self.root / 'captured-cache.sqlite'
        with zipfile.ZipFile(recovery / 'before.zip') as archive:
            captured.write_bytes(archive.read('state/cache.sqlite'))
        with closing(sqlite3.connect(captured)) as db:
            self.assertEqual(db.execute('SELECT DISTINCT value FROM state').fetchall(), [(b'original' * 600,)])
            self.assertEqual(db.execute('SELECT COUNT(*) FROM state').fetchone()[0], 100)

    def test_healthy_committed_wal_is_captured_without_changing_active_sidecars(self):
        with closing(sqlite3.connect(self.target / 'library.sqlite')) as db:
            db.execute('PRAGMA journal_mode=WAL')
            db.execute("INSERT INTO settings(key,value) VALUES('wal-fixture','committed')")
            db.commit()
            before = self.active_bytes(self.target)
            with patch.object(storage, 'move_restore_entry', side_effect=OSError('stop before first move')):
                with self.assertRaises(OSError):
                    storage.restore(self.archive, self.target)
            self.assertEqual(self.active_bytes(self.target), before)
            recovery = next(path for path in self.target.glob('recovery-*') if not path.name.startswith('recovery-index-'))
            captured = self.root / 'captured.sqlite'
            with zipfile.ZipFile(recovery / 'before.zip') as archive:
                captured.write_bytes(archive.read('state/library.sqlite'))
            with closing(sqlite3.connect(captured)) as reader:
                self.assertEqual(reader.execute("SELECT value FROM settings WHERE key='wal-fixture'").fetchone(), ('committed',))

    def test_invalid_incoming_archive_precedes_preservation_or_mutation(self):
        (self.target / 'library.sqlite').write_bytes(b'corrupt active bytes')
        before = self.active_bytes(self.target)
        with zipfile.ZipFile(self.archive) as archive:
            entries = {name: archive.read(name) for name in archive.namelist()}
        entries['state/annotations.json'] = b'corrupt incoming bytes'
        with zipfile.ZipFile(self.archive, 'w') as archive:
            for name, contents in entries.items():
                archive.writestr(name, contents)
        with self.assertRaises(ValueError), patch.object(storage, 'capture_state_files', side_effect=AssertionError('No capture for invalid archive')):
            storage.restore(self.archive, self.target)
        self.assertEqual(self.active_bytes(self.target), before)
        self.assertEqual([path for path in self.target.glob('recovery-*') if not path.name.startswith('recovery-index-')], [])

    def test_io_permission_busy_and_space_errors_do_not_trigger_raw_fallback(self):
        io_error = sqlite3.OperationalError('synthetic SQLite I/O error')
        io_error.sqlite_errorcode = sqlite3.SQLITE_IOERR
        busy = sqlite3.OperationalError('synthetic SQLite busy')
        busy.sqlite_errorcode = sqlite3.SQLITE_BUSY
        for error in (PermissionError('synthetic denied'), OSError(errno.ENOSPC, 'synthetic full disk'), io_error, busy):
            with self.subTest(error=error):
                before = self.active_bytes(self.target)
                with patch.object(storage, 'backup', side_effect=error), patch.object(storage, 'preserve_raw_state', side_effect=AssertionError('No fallback for I/O')):
                    with self.assertRaises(type(error)):
                        storage.restore(self.archive, self.target)
                self.assertEqual(self.active_bytes(self.target), before)

    def test_future_config_or_database_version_is_not_treated_as_corruption(self):
        for kind in ('config', 'database'):
            with self.subTest(kind=kind):
                target = self.library('future-' + kind, b'original future bytes')
                if kind == 'config':
                    (target / 'annotations.json').write_text('{"schemaVersion":99}')
                else:
                    with closing(sqlite3.connect(target / 'library.sqlite')) as db:
                        db.execute('PRAGMA user_version=99')
                before = self.active_bytes(target)
                with patch.object(storage, 'preserve_raw_state', side_effect=AssertionError('No fallback for future schema')):
                    with self.assertRaises(ValueError):
                        storage.restore(self.archive, target)
                self.assertEqual(self.active_bytes(target), before)

    def test_preservation_copy_hash_or_manifest_failure_prevents_any_swap(self):
        for fault in ('copy', 'hash', 'manifest'):
            with self.subTest(fault=fault):
                target = self.library('preservation-failure-' + fault, b'original unreadable')
                (target / 'annotations.json').write_bytes(b'{')
                before = self.active_bytes(target)
                copy, digest, atomic = storage.shutil.copyfileobj, storage.digest, storage.atomic_json

                def copy_file(reader, writer, *args, **kwargs):
                    if fault == 'copy' and 'raw-files' in Path(str(getattr(writer, 'name', ''))).parts:
                        raise OSError(errno.ENOSPC, 'synthetic full disk during raw preservation')
                    return copy(reader, writer, *args, **kwargs)

                def checksum(path):
                    if fault == 'hash' and 'raw-files' in Path(path).parts:
                        return '0' * 64
                    return digest(path)

                def publish(path, value):
                    if fault == 'manifest' and Path(path).name == 'raw-manifest.json':
                        raise PermissionError('synthetic raw manifest publication failure')
                    return atomic(path, value)

                with patch.object(storage.shutil, 'copyfileobj', copy_file), patch.object(storage, 'digest', checksum), patch.object(storage, 'atomic_json', publish):
                    with self.assertRaises((OSError, ValueError)):
                        storage.restore(self.archive, target)
                self.assertEqual(self.active_bytes(target), before)
                self.assertFalse((target / '.restore-journal.json').exists())

    def test_admission_counts_working_copy_plus_backup_peak_before_copying(self):
        total = sum(len(contents) for name, contents in self.active_bytes(self.target).items() if name != '.library-writer.lock')
        # Enough for the raw copy alone, insufficient for copy + backup peak.
        free = total + storage.SPACE_RESERVE + 1
        before = self.active_bytes(self.target)
        with patch.object(storage.shutil, 'disk_usage', return_value=type('Disk', (), {'free': free})()):
            with self.assertRaisesRegex(ValueError, 'budget insuffisant'):
                storage.restore(self.archive, self.target)
        self.assertEqual(self.active_bytes(self.target), before)
        self.assertFalse((self.target / '.restore-journal.json').exists())

    def test_failed_swap_and_interrupted_rollback_preserve_corrupt_originals(self):
        for interrupt_rollback in (False, True):
            with self.subTest(interrupt_rollback=interrupt_rollback):
                target = self.library('swap-failure-' + str(interrupt_rollback), b'original source')
                (target / 'annotations.json').write_bytes(b'{')
                before = self.active_bytes(target)
                replace = storage.os.replace

                def interrupt(source, destination):
                    source, destination = Path(source), Path(destination)
                    if source.parent.name == 'state' and destination == target / 'library.sqlite':
                        raise OSError('synthetic swap failure')
                    if interrupt_rollback and source.parent.name == 'original-files' and source.name == 'annotations.json':
                        raise OSError('synthetic interrupted rollback')
                    return replace(source, destination)

                with patch.object(storage.os, 'replace', interrupt), self.assertRaises(OSError):
                    storage.restore(self.archive, target)
                self.assertEqual((target / '.restore-journal.json').exists(), interrupt_rollback)
                storage.recover_restore(target)
                self.assertEqual(self.active_bytes(target), before)
                self.assertFalse(storage.recover_restore(target)['recovered'])
                recovery = next(path for path in target.glob('recovery-*') if not path.name.startswith('recovery-index-'))
                self.assertEqual((recovery / 'raw-files' / 'annotations.json').read_bytes(), b'{')
                self.assertTrue((recovery / 'raw-manifest.json').exists())


if __name__ == '__main__':
    unittest.main()
