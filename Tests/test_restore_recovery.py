"""Interrupted recovery must preserve both generations and the writer lease."""
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import library_storage as storage


class RestoreRecoveryTests(unittest.TestCase):
    def fixture(self):
        temporary = tempfile.TemporaryDirectory(prefix='katalog-recovery-retry-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        recovery = root / ('recovery-' + 'a' * 32)
        original = recovery / 'original-files'
        original.mkdir(parents=True)
        database = original / 'library.sqlite'
        with closing(sqlite3.connect(database)) as db, db:
            db.execute('CREATE TABLE logs(id TEXT)')
            db.execute("INSERT INTO logs VALUES('original-log')")
        (original / 'annotations.json').write_text('{"schemaVersion":1,"marker":"original"}')
        for name in ('library.sqlite', 'annotations.json'):
            (root / name).write_bytes(b'incoming-' + name.encode())
        (root / '.library-writer.lock').write_bytes(b'held')
        record = {'restoreVersion': 1, 'phase': 'prepared', 'recoveryDirectory': recovery.name,
                  'archiveDirectory': 'restored-ulogs-' + 'a' * 32,
                  'moved': ['annotations.json', 'library.sqlite'],
                  'installed': ['annotations.json', 'library.sqlite']}
        storage.atomic_json(root / '.restore-journal.json', record)
        return root, recovery, record

    def rich_fixture(self):
        root, recovery, record = self.fixture()
        original = recovery / 'original-files'
        for name in ('cache.sqlite', 'cache.sqlite-wal', 'cache.sqlite-shm'):
            (original / name).write_bytes(b'original-' + name.encode())
            record['moved'].append(name)
        (original / 'event-dictionaries').mkdir()
        (original / 'event-dictionaries' / 'old.json.xz').write_bytes(b'original-dictionary')
        record['moved'].append('event-dictionaries')
        for name in ('cache.sqlite', 'views.json'):
            (root / name).write_bytes(b'incoming-' + name.encode())
            record['installed'].append(name)
        for name in ('event-dictionaries', record['archiveDirectory']):
            (root / name).mkdir()
            (root / name / 'fixture').write_bytes(b'incoming-' + name.encode())
            record['installed'].append(name)
        storage.atomic_json(root / '.restore-journal.json', record)
        return root, recovery, record

    @staticmethod
    def contents(directory, names):
        result = {}
        for name in names:
            path = directory / name
            if path.is_dir():
                result[name] = {str(child.relative_to(path)): child.read_bytes()
                                for child in path.rglob('*') if child.is_file()}
            elif path.exists():
                result[name] = path.read_bytes()
        return result

    def assert_recovered(self, root, recovery, record, old, incoming, inode):
        result = storage.recover_restore(root)
        self.assertTrue(result['recovered'])
        self.assertFalse(result['completedRestore'])
        self.assertEqual(self.contents(root, record['moved']), old)
        self.assertEqual(self.contents(recovery / 'interrupted-restored-files', record['installed']), incoming)
        self.assertFalse(any((root / name).exists() for name in set(record['installed']) - set(record['moved'])))
        self.assertEqual((root / '.library-writer.lock').stat().st_ino, inode)
        self.assertFalse((root / '.restore-journal.json').exists())
        self.assertFalse(storage.recover_restore(root)['recovered'])
        self.assertEqual(self.contents(root, record['moved']), old)

    def test_retry_after_original_database_was_reinstalled_keeps_it_active(self):
        root, recovery, _ = self.fixture()
        before = (recovery / 'original-files' / 'library.sqlite').read_bytes()
        lease_inode = (root / '.library-writer.lock').stat().st_ino
        replace = storage.os.replace

        def interrupt(source, destination):
            if Path(source) == recovery / 'original-files' / 'annotations.json':
                raise OSError('injected interruption after original database recovery')
            return replace(source, destination)

        with patch.object(storage.os, 'replace', interrupt), self.assertRaises(OSError):
            storage.recover_restore(root)
        self.assertTrue((root / '.restore-journal.json').exists())
        self.assertTrue(storage.recover_restore(root)['recovered'])
        self.assertTrue((root / 'library.sqlite').exists(), 'Recovered database must stay active')
        self.assertEqual((root / 'library.sqlite').read_bytes(), before)
        self.assertEqual(json.loads((root / 'annotations.json').read_bytes())['marker'], 'original')
        with closing(sqlite3.connect(root / 'library.sqlite')) as db:
            self.assertEqual(db.execute('SELECT id FROM logs').fetchall(), [('original-log',)])
        self.assertEqual((recovery / 'interrupted-restored-files' / 'library.sqlite').read_bytes(), b'incoming-library.sqlite')
        self.assertEqual((root / '.library-writer.lock').stat().st_ino, lease_inode)
        self.assertFalse(storage.recover_restore(root)['recovered'])

    def test_interruption_before_and_after_each_recovery_move_preserves_both_generations(self):
        _, _, template = self.rich_fixture()
        checkpoints = [('entrant', name) for name in template['installed']]
        checkpoints += [('original', name) for name in template['moved']]
        for kind, name in checkpoints:
            for moment in ('before', 'after'):
                with self.subTest(kind=kind, name=name, moment=moment):
                    root, recovery, record = self.rich_fixture()
                    old = self.contents(recovery / 'original-files', record['moved'])
                    incoming = self.contents(root, record['installed'])
                    inode = (root / '.library-writer.lock').stat().st_ino
                    replace = storage.os.replace
                    selected = (root if kind == 'entrant' else recovery / 'original-files') / name

                    def interrupt(source, destination):
                        if Path(source) == selected and moment == 'before':
                            raise OSError('injected before recovery move')
                        result = replace(source, destination)
                        if Path(source) == selected and moment == 'after':
                            raise OSError('injected after recovery move')
                        return result

                    with patch.object(storage.os, 'replace', interrupt), self.assertRaises(OSError):
                        storage.recover_restore(root)
                    self.assertTrue((root / '.restore-journal.json').exists())
                    self.assert_recovered(root, recovery, record, old, incoming, inode)

    def test_interruption_before_and_after_recovery_phase_publication_is_retryable(self):
        for phase in ('recovering-entrants', 'recovering-originals'):
            for moment in ('before', 'after'):
                with self.subTest(phase=phase, moment=moment):
                    root, recovery, record = self.rich_fixture()
                    old = self.contents(recovery / 'original-files', record['moved'])
                    incoming = self.contents(root, record['installed'])
                    inode = (root / '.library-writer.lock').stat().st_ino
                    atomic = storage.atomic_json

                    def interrupt(path, value):
                        selected = Path(path) == root / '.restore-journal.json' and value['phase'] == phase
                        if selected and moment == 'before':
                            raise OSError('injected before recovery journal publication')
                        result = atomic(path, value)
                        if selected and moment == 'after':
                            raise OSError('injected after recovery journal publication')
                        return result

                    with patch.object(storage, 'atomic_json', interrupt), self.assertRaises(OSError):
                        storage.recover_restore(root)
                    self.assert_recovered(root, recovery, record, old, incoming, inode)

    def test_legacy_partially_recovered_journal_keeps_original_already_active(self):
        root, recovery, record = self.fixture()
        old = self.contents(recovery / 'original-files', record['moved'])
        incoming = self.contents(root, record['installed'])
        inode = (root / '.library-writer.lock').stat().st_ino
        leftovers = recovery / 'interrupted-restored-files'
        leftovers.mkdir()
        for name in record['installed']:
            storage.os.replace(root / name, leftovers / name)
        storage.os.replace(recovery / 'original-files' / 'library.sqlite', root / 'library.sqlite')
        self.assert_recovered(root, recovery, record, old, incoming, inode)

    def test_original_move_intent_without_move_keeps_active_original(self):
        root, recovery, record = self.fixture()
        old = (recovery / 'original-files' / 'library.sqlite').read_bytes()
        (root / 'library.sqlite').write_bytes(old)
        (recovery / 'original-files' / 'library.sqlite').unlink()
        record['installed'] = []
        (root / 'annotations.json').unlink()
        storage.atomic_json(root / '.restore-journal.json', record)
        self.assertTrue(storage.recover_restore(root)['recovered'])
        self.assertEqual((root / 'library.sqlite').read_bytes(), old)

    def test_missing_original_refuses_success_and_keeps_journal(self):
        root, recovery, _ = self.fixture()
        (root / 'library.sqlite').unlink()
        (recovery / 'original-files' / 'library.sqlite').unlink()
        with self.assertRaisesRegex(ValueError, 'original manquant'):
            storage.recover_restore(root)
        self.assertTrue((root / '.restore-journal.json').exists())

    def test_completed_restore_is_verified_before_journal_removal(self):
        for missing in (None, 'incoming', 'original'):
            with self.subTest(missing=missing):
                root, recovery, record = self.fixture()
                record['phase'] = 'complete'
                storage.atomic_json(root / '.restore-journal.json', record)
                if missing:
                    directory = root if missing == 'incoming' else recovery / 'original-files'
                    (directory / 'library.sqlite').unlink()
                    with self.assertRaisesRegex(ValueError, 'non vérifiable'):
                        storage.recover_restore(root)
                    self.assertTrue((root / '.restore-journal.json').exists())
                else:
                    self.assertTrue(storage.recover_restore(root)['completedRestore'])
                    self.assertEqual((root / 'library.sqlite').read_bytes(), b'incoming-library.sqlite')
                    self.assertFalse(storage.recover_restore(root)['recovered'])

    def test_interrupted_automatic_rollback_uses_the_same_retryable_recovery(self):
        for moment in ('before', 'after'):
            with self.subTest(moment=moment):
                root, recovery, record = self.fixture()
                # Start with the old state and a valid, distinct incoming ZIP.
                old = self.contents(recovery / 'original-files', record['moved'])
                for name in record['moved']:
                    storage.os.replace(recovery / 'original-files' / name, root / name)
                (root / '.restore-journal.json').unlink()
                incoming_root = root / 'incoming'
                incoming_root.mkdir()
                with closing(sqlite3.connect(incoming_root / 'library.sqlite')) as db, db:
                    db.execute('CREATE TABLE fixture(value TEXT)')
                    db.execute("INSERT INTO fixture VALUES('incoming')")
                (incoming_root / 'annotations.json').write_text('{"schemaVersion":1,"marker":"incoming"}')
                archive = root / 'incoming.zip'
                storage.backup(incoming_root, archive)
                replace = storage.os.replace

                def interrupt(source, destination):
                    source, destination = Path(source), Path(destination)
                    if source.parent.name == 'state' and destination == root / 'library.sqlite':
                        raise OSError('injected initial swap failure')
                    selected = source.parent.name == 'original-files' and source.name == 'annotations.json'
                    if selected and moment == 'before':
                        raise OSError('injected before automatic rollback move')
                    result = replace(source, destination)
                    if selected and moment == 'after':
                        raise OSError('injected after automatic rollback move')
                    return result

                with patch.object(storage.os, 'replace', interrupt), self.assertRaises(OSError):
                    storage.restore(archive, root)
                self.assertTrue((root / '.restore-journal.json').exists())
                self.assertTrue(storage.recover_restore(root)['recovered'])
                self.assertEqual(self.contents(root, record['moved']), old)
                self.assertFalse(storage.recover_restore(root)['recovered'])

    def test_each_forward_move_and_journal_publication_leaves_one_complete_generation(self):
        # Two original moves, then three incoming files. The first journal is
        # prepared; five move intents follow; the seventh publication commits.
        for operation, count in (('move', 5), ('journal', 7)):
            for checkpoint in range(1, count + 1):
                for moment in ('before', 'after'):
                    with self.subTest(operation=operation, checkpoint=checkpoint, moment=moment):
                        root, recovery, record = self.fixture()
                        old = self.contents(recovery / 'original-files', record['moved'])
                        for name in record['moved']:
                            storage.os.replace(recovery / 'original-files' / name, root / name)
                        (root / '.restore-journal.json').unlink()
                        incoming = root / 'incoming'
                        incoming.mkdir()
                        with closing(sqlite3.connect(incoming / 'library.sqlite')) as db, db:
                            db.execute('CREATE TABLE fixture(value TEXT)')
                            db.execute("INSERT INTO fixture VALUES('incoming')")
                        for name in ('annotations.json', 'views.json'):
                            (incoming / name).write_text('{"schemaVersion":1,"marker":"incoming"}')
                        archive = root / 'incoming.zip'
                        storage.backup(incoming, archive)
                        replace, atomic = storage.os.replace, storage.atomic_json
                        calls = 0

                        def selected_fault(selected, action):
                            nonlocal calls
                            if selected:
                                calls += 1
                            if selected and calls == checkpoint and moment == 'before':
                                raise OSError('injected before forward operation')
                            result = action()
                            if selected and calls == checkpoint and moment == 'after':
                                raise OSError('injected after forward operation')
                            return result

                        def interrupt_move(source, destination):
                            # Count only forward managed-file moves; recovery
                            # and tempfile-to-journal publication remain usable.
                            selected = operation == 'move' and (
                                Path(destination).parent.name == 'original-files' or
                                Path(source).parent.name == 'state')
                            return selected_fault(selected, lambda: replace(source, destination))

                        def interrupt_journal(path, value):
                            selected = operation == 'journal' and value.get('phase') in ('prepared', 'complete')
                            return selected_fault(selected, lambda: atomic(path, value))

                        with patch.object(storage.os, 'replace', interrupt_move), patch.object(storage, 'atomic_json', interrupt_journal), self.assertRaises(OSError):
                            storage.restore(archive, root)
                        self.assertGreaterEqual(calls, checkpoint)
                        storage.recover_restore(root)
                        committed = operation == 'journal' and checkpoint == 7 and moment == 'after'
                        if committed:
                            self.assertEqual(json.loads((root / 'views.json').read_bytes())['marker'], 'incoming')
                            with closing(sqlite3.connect(root / 'library.sqlite')) as db:
                                self.assertEqual(db.execute('SELECT value FROM fixture').fetchall(), [('incoming',)])
                        else:
                            self.assertEqual(self.contents(root, record['moved']), old)
                            self.assertFalse((root / 'views.json').exists())
                        self.assertFalse((root / '.restore-journal.json').exists())
                        self.assertFalse(storage.recover_restore(root)['recovered'])


if __name__ == '__main__':
    unittest.main()
