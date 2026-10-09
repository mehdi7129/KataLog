"""A pending restore is never interpreted as a new or healthy library."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer


class RestoreStartupGuardTests(unittest.TestCase):
    def test_missing_and_existing_database_are_refused_without_changes(self):
        for existing in (False, True):
            for read_only in (False, True):
                with self.subTest(existing=existing, read_only=read_only), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    database = root / 'library.sqlite'
                    if existing:
                        db = analyzer.open_database(database)
                        db.close()
                    journal = root / '.restore-journal.json'
                    journal.write_text('{}')
                    before = {path.name: path.read_bytes() for path in root.iterdir()}
                    with self.assertRaisesRegex(ValueError, 'restauration'):
                        analyzer.open_database(database, read_only=read_only).close()
                    self.assertEqual({path.name: path.read_bytes() for path in root.iterdir()}, before)

    def test_dangling_journal_and_database_alias_do_not_bypass_guard(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / 'library.sqlite'
            db = analyzer.open_database(database)
            db.close()
            (root / '.restore-journal.json').symlink_to(root / 'missing.json')
            alias_root = root / 'alias'
            alias_root.mkdir()
            alias = alias_root / 'database.sqlite'
            alias.symlink_to(database)
            for path in (database, alias):
                with self.subTest(path=path), self.assertRaisesRegex(ValueError, 'restauration'):
                    analyzer.open_database(path).close()

    def test_cli_index_preparation_does_not_create_missing_database(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            journal = root / '.restore-journal.json'
            journal.write_text('{}')
            result = subprocess.run([sys.executable, '-B', analyzer.__file__, 'ensure-index',
                                     '--database', str(root / 'library.sqlite'),
                                     '--output', str(root / 'output.json')],
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('restauration', result.stderr)
            self.assertFalse((root / 'library.sqlite').exists())
            self.assertFalse((root / 'output.json').exists())
            self.assertEqual(journal.read_text(), '{}')


if __name__ == '__main__':
    unittest.main()
