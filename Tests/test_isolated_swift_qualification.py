import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('isolated_swift', Path(__file__).resolve().parents[1] / 'tools/qualify-isolated-swift-tests.py')
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


def event(identifier, action):
    cls, method = identifier.split('/')
    return "Test Case '-[%s %s]' %s.\n" % (cls, method, action)


class IsolatedSwiftQualificationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.args = argparse.Namespace(source_root=self.root, source_commit='a' * 40,
            scratch_path=self.root / 'build', output=self.root / 'reports', skip_build=True,
            test_class=None, build_timeout=30, class_timeout=30, test_timeout=30, budget_seconds=120)
        self.ids = ['ExampleTests.RenderTests/testA', 'ExampleTests.RenderTests/testB']

    def qualify(self, outputs):
        calls = []
        def fake(command, cwd, environment, log, timeout):
            calls.append(command)
            output, code, timed = outputs[len(calls) - 1]
            log.parent.mkdir(parents=True, exist_ok=True); log.write_text(output)
            return {'output': output, 'exitCode': code, 'timedOut': timed, 'durationSeconds': .1}
        with patch.object(runner, 'source_state'), patch.object(runner, 'crash_files', return_value={}):
            qualification = runner.Qualification(self.args, fake)
            result = qualification.qualify()
        return result, json.loads((self.args.output / 'summary.json').read_text()), calls

    def test_crashed_test_is_never_retried_and_unreached_test_runs(self):
        first, second = self.ids
        result, report, calls = self.qualify([
            ('\n'.join(self.ids), 0, False),
            (event(first, 'started') + runner.METAL_ASSERTION, -6, False),
            (event(second, 'started') + event(second, 'passed'), 0, False),
        ])
        self.assertEqual(result, 1)
        self.assertFalse(report['rawFullSuitePassed'])
        self.assertTrue(report['partitionComplete'])
        self.assertEqual(report['counts']['crashed'], 1)
        self.assertEqual(report['counts']['passed'], 1)
        self.assertEqual(report['counts']['notRun'], 0)
        self.assertEqual(len(calls), 3)
        self.assertEqual(report['executions'][1]['requestedIDs'], [second])
        self.assertTrue(report['executions'][0]['metalArchitectureAssertionObserved'])

    def test_complete_passing_scope_has_every_identifier(self):
        self.args.skip_build = False
        output = ''.join(event(test, 'started') + event(test, 'passed') for test in self.ids)
        result, report, calls = self.qualify([('Build complete!', 0, False), ('\n'.join(self.ids), 0, False), (output, 0, False)])
        self.assertEqual(result, 0)
        self.assertTrue(report['rawFullSuitePassed'])
        self.assertEqual(set(report['tests']), set(self.ids))
        self.assertEqual(len(calls), 3)

    def test_reused_build_cannot_claim_full_qualification(self):
        output = ''.join(event(test, 'started') + event(test, 'passed') for test in self.ids)
        result, report, _ = self.qualify([('\n'.join(self.ids), 0, False), (output, 0, False)])
        self.assertEqual(result, 0)
        self.assertTrue(report['selectedScopePassed'])
        self.assertFalse(report['rawFullSuitePassed'])

    def test_limited_local_scope_cannot_claim_full_suite_passed(self):
        second_class = 'ExampleTests.OtherTests/testC'
        self.args.test_class = ['ExampleTests.RenderTests']
        output = ''.join(event(test, 'started') + event(test, 'passed') for test in self.ids)
        result, report, _ = self.qualify([('\n'.join(self.ids + [second_class]), 0, False), (output, 0, False)])
        self.assertEqual(result, 0)
        self.assertTrue(report['selectedScopePassed'])
        self.assertFalse(report['rawFullSuitePassed'])
        self.assertEqual(report['counts']['notRun'], 1)
        self.assertTrue(report['partitionComplete'])

    def test_timeout_records_active_test_and_continues_unreached(self):
        first, second = self.ids
        result, report, _ = self.qualify([
            ('\n'.join(self.ids), 0, False), (event(first, 'started'), -15, True),
            (event(second, 'started') + event(second, 'passed'), 0, False)])
        self.assertEqual(result, 1)
        self.assertEqual(report['tests'][first]['status'], 'timedOut')
        self.assertFalse(report['nativeGatePassed'])

    def test_skip_and_assertion_failure_are_not_retried(self):
        first, second = self.ids
        output = event(first, 'started') + event(first, 'skipped') + event(second, 'started') + event(second, 'failed')
        result, report, calls = self.qualify([('\n'.join(self.ids), 0, False), (output, 1, False)])
        self.assertEqual(result, 1)
        self.assertEqual(report['counts']['skipped'], 1)
        self.assertEqual(report['counts']['assertionFailed'], 1)
        self.assertEqual(len(calls), 2)

    def test_unexpected_test_event_prevents_passing_gate(self):
        output = ''.join(event(test, 'started') + event(test, 'passed') for test in self.ids)
        output += event('ExampleTests.Other/testUnexpected', 'started')
        result, report, _ = self.qualify([('\n'.join(self.ids), 0, False), (output, 0, False)])
        self.assertEqual(result, 1)
        self.assertTrue(any('Unexpected test event' in error for error in report['errors']))

    def test_silent_success_cannot_be_repaired_into_a_false_pass(self):
        outputs = [('\n'.join(self.ids), 0, False), ('', 0, False)]
        outputs.extend((event(test, 'started') + event(test, 'passed'), 0, False) for test in self.ids)
        result, report, _ = self.qualify(outputs)
        self.assertEqual(result, 1)
        self.assertEqual(report['counts']['passed'], 2)
        self.assertTrue(any('omitted' in error for error in report['errors']))

    def test_terminal_event_without_start_is_not_retried(self):
        parsed = runner.parse_execution(event(self.ids[0], 'failed'), self.ids, 1)
        self.assertEqual(parsed['neverStarted'], [self.ids[1]])
        self.assertTrue(parsed['anomalies'])

    def test_discovery_rejects_empty_and_duplicate_manifests(self):
        for output in ('Build complete!', self.ids[0] + '\n' + self.ids[0]):
            with self.subTest(output=output), self.assertRaises(ValueError):
                runner.discover_ids(output)

    def test_duplicate_start_cannot_silently_pass(self):
        identifier = self.ids[0]
        parsed = runner.parse_execution(event(identifier, 'started') * 2 + event(identifier, 'passed'), [identifier], 0)
        self.assertTrue(parsed['anomalies'])

    def test_controller_interruption_is_not_misreported_as_application_crash(self):
        parsed = runner.parse_execution(event(self.ids[0], 'started'), self.ids, -15, interrupted=True)
        self.assertEqual(parsed['results'][self.ids[0]]['status'], 'interrupted')
        self.assertEqual(parsed['neverStarted'], [self.ids[1]])

    def test_interruption_persists_exhaustive_partial_report(self):
        self.args.budget_seconds = .000001
        result, report, calls = self.qualify([])
        self.assertEqual(result, 1)
        self.assertEqual(report['status'], 'incomplete')
        self.assertFalse(report['rawFullSuitePassed'])
        self.assertEqual(calls, [])

    def test_streaming_timeout_keeps_partial_output_and_exit_status(self):
        log = self.root / 'timeout.log'
        result = runner.run_streamed([sys.executable, '-u', '-c', 'import time; print("partial evidence"); time.sleep(20)'],
                                     self.root, os.environ.copy(), log, .15)
        self.assertTrue(result['timedOut'])
        self.assertNotEqual(result['exitCode'], 0)
        self.assertIn('partial evidence', log.read_text())
        self.assertLess(result['durationSeconds'], 5)

    def test_closed_stdout_does_not_impose_an_unrelated_three_second_timeout(self):
        result = runner.run_streamed([sys.executable, '-c', 'import os,time; os.close(1); os.close(2); time.sleep(3.2)'],
                                     self.root, os.environ.copy(), self.root/'closed-pipe.log', 5)
        self.assertEqual(result['exitCode'], 0)
        self.assertFalse(result['timedOut'])
        self.assertGreaterEqual(result['durationSeconds'], 3.2)

    def test_source_commit_check_rejects_wrong_head_and_tracked_edits(self):
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        source = self.root / 'source.swift'; source.write_text('frozen\n')
        subprocess.run(['git', 'add', '.'], cwd=self.root, check=True)
        subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture'], cwd=self.root, check=True)
        commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.root, text=True).strip()
        self.assertEqual(runner.source_state(self.root, commit), commit)
        with self.assertRaises(ValueError): runner.source_state(self.root, 'f' * 40)
        extra = self.root / 'untracked.swift'; extra.write_text('untracked input\n')
        with self.assertRaises(ValueError): runner.source_state(self.root, commit)
        extra.unlink()
        source.write_text('changed\n')
        with self.assertRaises(ValueError): runner.source_state(self.root, commit)


if __name__ == '__main__':
    unittest.main()
