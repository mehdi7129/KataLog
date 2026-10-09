"""The public file-loaded facade keeps its command results and error contract."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).parents[1] / 'Sources/KataLog/Resources/analyzer.py'


class AnalyzerCLIContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='katalog-cli-contract-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # Deliberately neither register the module nor import it as "analyzer".
        spec = importlib.util.spec_from_file_location('katalog_file_loaded_analyzer', SCRIPT)
        self.engine = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.engine)
        self.database = self.root / 'library.sqlite'
        self.output = self.root / 'snapshot.json'

    def run_snapshot(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = self.engine.main(['snapshot', '--database', str(self.database),
                                       '--output', str(self.output), '--read-only'])
        return status, stdout.getvalue(), stderr.getvalue()

    def test_file_loaded_facade_publishes_same_json_and_closes_its_connection(self):
        expected = {'logs': [], 'importStats': {'imported': 0}, 'name': 'Fixture été'}
        db = Mock()
        with patch.object(self.engine, 'open_database', return_value=db) as opened, \
             patch.object(self.engine, 'snapshot', return_value=expected) as snapshot:
            status, stdout, stderr = self.run_snapshot()
        self.assertEqual((status, stderr), (0, ''))
        opened.assert_called_once_with(str(self.database), read_only=True)
        snapshot.assert_called_once_with(db)
        db.close.assert_called_once_with()
        self.assertEqual(self.output.read_bytes(), json.dumps(expected, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode())
        self.assertEqual(json.loads(stdout), {'logs': 0, 'importStats': {'imported': 0}})
        self.assertFalse(self.database.exists())

    def test_command_error_keeps_existing_output_and_closes_its_connection(self):
        self.output.write_bytes(b'previous complete result')
        db = Mock()
        with patch.object(self.engine, 'open_database', return_value=db), \
             patch.object(self.engine, 'snapshot', side_effect=ValueError('synthetic snapshot refusal')):
            status, stdout, stderr = self.run_snapshot()
        self.assertEqual((status, stdout, stderr), (1, '', 'ValueError: synthetic snapshot refusal\n'))
        db.close.assert_called_once_with()
        self.assertEqual(self.output.read_bytes(), b'previous complete result')
        self.assertFalse(self.database.exists())


if __name__ == '__main__':
    unittest.main()
