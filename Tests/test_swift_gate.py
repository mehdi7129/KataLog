import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('swift_gate', Path(__file__).resolve().parents[1] / 'tools' / 'run-swift-tests.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

class SwiftGateTests(unittest.TestCase):
    def test_multiple_bundles_do_not_hide_failure_or_skip_in_first_bundle(self):
        output = """Test Suite 'Inner' failed at time.
 Executed 3 tests, with 1 test skipped and 1 failure (0 unexpected)
Test Suite 'Core.xctest' failed at time.
 Executed 13 tests, with 1 test skipped and 1 failure (0 unexpected)
Test Suite 'Selected tests' failed at time.
 Executed 13 tests, with 1 test skipped and 1 failure (0 unexpected)
Test Suite 'App.xctest' passed at time.
 Executed 10 tests, with 0 failures (0 unexpected)
Test Suite 'Selected tests' passed at time.
 Executed 10 tests, with 0 failures (0 unexpected)
"""
        self.assertEqual(gate.test_counts(output), ((23, 1, 1), True))

    def test_single_merged_bundle_and_missing_results(self):
        self.assertEqual(gate.test_counts("Test Suite 'PackageTests.xctest' passed at time.\n Executed 152 tests, with 0 failures (0 unexpected)\n Executed 152 tests, with 0 failures (0 unexpected)"), ((152, 0, 0), True))
        self.assertEqual(gate.test_counts('Build failed'), ((0, 0, 0), False))
