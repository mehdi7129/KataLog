"""Verified backup receipts and identity-based coverage, on synthetic libraries."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import backup_history
import library_archives
import library_storage


class BackupHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='katalog-backup-history-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.library = self.root / 'library'
        self.library.mkdir()
        self.database = self.library / 'library.sqlite'
        self.db = analyzer.open_database(self.database)
        self.addCleanup(self.db.close)
        self.archive = self.root / 'verified.zip'
        self.original = self.add_log('first')

    def add_log(self, name):
        source = self.root / (name + '.ulg')
        source.write_bytes(name.encode())
        identity = hashlib.sha256(source.read_bytes()).hexdigest()
        log = analyzer.base_log(source, self.root, identity, source.stat().st_size)
        analyzer.remember_log(self.db, log)
        self.db.execute('INSERT INTO sources VALUES(?,?)', (identity, str(source)))
        self.db.commit()
        return identity

    def status(self):
        return library_archives.storage_info(self.database, self.library)

    def test_success_survives_reopen_and_counts_new_identities_not_totals(self):
        self.assertIsNone(self.status()['lastVerifiedBackup'])
        result = library_storage.backup(self.library, self.archive, include_ulog=True)
        self.assertIsNone(result['historyWarning'])
        first = self.status()['lastVerifiedBackup']
        self.assertEqual((first['logCount'], first['archivedLogCount'], first['newLogCount']), (1, 1, 0))
        self.add_log('second')
        self.db.execute('DELETE FROM logs WHERE id=?', (self.original,))
        self.db.commit()
        self.assertEqual(self.status()['lastVerifiedBackup']['newLogCount'], 1)
        # Receipt remains a historical fact even if its archive is offline.
        self.archive.unlink()
        self.assertEqual(self.status()['lastVerifiedBackup']['verifiedAt'], first['verifiedAt'])

    def test_failed_backup_does_not_advance_receipt(self):
        library_storage.backup(self.library, self.archive)
        receipt = self.library / backup_history.RECEIPT_NAME
        previous = receipt.read_bytes()
        with patch.object(library_storage, 'inspect_backup', side_effect=ValueError('fixture failure')):
            with self.assertRaises(ValueError):
                library_storage.backup(self.library, self.root / 'failed.zip')
        self.assertEqual(receipt.read_bytes(), previous)

    def test_receipt_failure_preserves_successfully_published_backup(self):
        with patch.object(backup_history, 'atomic_json', side_effect=OSError('fixture full disk')):
            result = library_storage.backup(self.library, self.archive)
        self.assertIn('date', result['historyWarning'])
        self.assertEqual(library_storage.inspect_backup(self.archive)['logCount'], 1)

    def test_restore_replaces_receipt_with_archive_actually_restored(self):
        library_storage.backup(self.library, self.archive, include_ulog=True)
        self.add_log('second')
        other = self.root / 'newer.zip'
        library_storage.backup(self.library, other)
        target = self.root / 'restored'
        result = library_storage.restore(self.archive, target)
        self.assertIsNone(result['historyWarning'])
        info = library_archives.storage_info(target / 'library.sqlite', target)['lastVerifiedBackup']
        self.assertEqual(info['archivePath'], str(self.archive.resolve()))
        self.assertEqual((info['logCount'], info['newLogCount']), (1, 0))

    def test_invalid_or_symlink_receipt_does_not_hide_storage(self):
        receipt = self.library / backup_history.RECEIPT_NAME
        receipt.write_text('{broken')
        info = self.status()
        self.assertEqual(info['logCount'], 1)
        self.assertIsNone(info['lastVerifiedBackup'])
        self.assertTrue(info['backupHistoryError'])
        receipt.unlink()
        protected = self.root / 'unrelated.json'
        protected.write_text('{}')
        receipt.symlink_to(protected)
        self.assertTrue(self.status()['backupHistoryError'])
        self.assertEqual(protected.read_text(), '{}')


if __name__ == '__main__':
    unittest.main()
