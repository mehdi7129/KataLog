"""Dispatch contract: embedded modules only, never arbitrary Python scripts."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import types
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("engine_entry", Path(__file__).parents[1] / "tools" / "engine-entry.py")
engine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine)


class EngineEntryTests(unittest.TestCase):
    def test_script_path_dispatches_bundled_module_without_reading_source(self):
        for selector, expected in (("/missing/resources/analyzer.py", "analyzer"),
                                   ("/missing/resources/gcs_collect.py", "gcs_collect"),
                                   ("analyzer", "analyzer"), ("gcs", "gcs_collect")):
            seen = []
            module = types.SimpleNamespace(main=lambda args: seen.append(args) or 23)
            with patch.object(engine.importlib, "import_module", return_value=module) as importer:
                self.assertEqual(engine.main(["-u", "-B", selector, "--help"]), 23)
            importer.assert_called_once_with(expected)
            self.assertEqual(seen, [["--help"]])

    def test_arbitrary_script_and_python_eval_are_rejected(self):
        for args in (("/tmp/untrusted.py",), ("-c", "print('not executed')"), ("-m", "http.server"), ()):
            with patch.object(engine.importlib, "import_module") as importer, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(engine.main(args), 2)
                importer.assert_not_called()

    def test_handshake_prints_one_json_object(self):
        expected = {"protocol": 1, "parserVersion": "1.3.0", "python": "3.13.3", "numpy": "2.5.3", "pyulog": "1.2.4"}
        output = io.StringIO()
        with patch.object(engine, "runtime_info", return_value=expected), contextlib.redirect_stdout(output):
            self.assertEqual(engine.main(["--katalog-runtime-info"]), 0)
        self.assertEqual(json.loads(output.getvalue()), expected)

    def test_dependency_failure_is_nonzero_without_leaking_import_path(self):
        output = io.StringIO()
        with patch.object(engine, "runtime_info", side_effect=ImportError("private path")), contextlib.redirect_stderr(output):
            self.assertEqual(engine.main(["--katalog-runtime-info"]), 1)
        self.assertNotIn("private path", output.getvalue())
        self.assertIn("ImportError", output.getvalue())


if __name__ == "__main__":
    unittest.main()
