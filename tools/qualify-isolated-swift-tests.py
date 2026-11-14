#!/usr/bin/env python3
"""Collect exhaustive XCTest evidence without retrying a test that crashed.

This diagnostic runner never turns a platform crash into a passing native gate.
It runs a class first, then only its never-started tests in separate processes.
The application checkout is verified independently of this harness's checkout.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import time


STATUSES = ('passed', 'assertionFailed', 'crashed', 'timedOut', 'interrupted', 'skipped', 'notRun')
TEST_ID = re.compile(r'^[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+/[A-Za-z_]\w*$')
CASE = re.compile(r"Test Case '([^']+)' (started|passed|failed|skipped)(?:[ .(]|$)")
METAL_ASSERTION = "Target device architecture is nil"


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def discover_ids(output):
    ids = [line.strip() for line in output.splitlines() if TEST_ID.fullmatch(line.strip())]
    if not ids or len(ids) != len(set(ids)):
        raise ValueError('Discovery returned no XCTest identifiers or duplicate identifiers.')
    return sorted(ids)


def event_id(name):
    objc = re.fullmatch(r'-\[([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+) ([A-Za-z_]\w*)\]', name)
    if objc:
        return objc[1] + '/' + objc[2]
    if TEST_ID.fullmatch(name):
        return name
    if '.' in name:
        cls, method = name.rsplit('.', 1)
        candidate = cls + '/' + method
        if TEST_ID.fullmatch(candidate):
            return candidate
    return None


def parse_execution(output, expected, returncode, timed_out=False, interrupted=False):
    """Only a matched terminal XCTest event is evidence that a test passed."""
    expected = set(expected)
    results, started, active, anomalies = {}, set(), set(), []
    for line in output.splitlines():
        match = CASE.search(line)
        if not match:
            continue
        identifier = event_id(match[1])
        if identifier not in expected:
            anomalies.append('Unexpected test event: ' + match[1])
            continue
        action = match[2]
        if action == 'started':
            if identifier in started:
                anomalies.append('Duplicate test start: ' + identifier)
            started.add(identifier)
            active.add(identifier)
        else:
            if identifier not in active:
                anomalies.append('Terminal event without active test: ' + identifier)
            # A terminal event is still evidence that this ID was reached.
            # Never retry it merely because its start line was missing.
            started.add(identifier)
            active.discard(identifier)
            if identifier in results:
                anomalies.append('Duplicate terminal event: ' + identifier)
            results[identifier] = {'status': {'passed': 'passed', 'failed': 'assertionFailed', 'skipped': 'skipped'}[action]}
    for identifier in active:
        results[identifier] = {'status': 'interrupted' if interrupted else 'timedOut' if timed_out else 'crashed'}
    if active and not timed_out and returncode == 0:
        anomalies.append('Process exited successfully with unterminated test events.')
    if 'Test skipped -' in output and not any(x['status'] == 'skipped' for x in results.values()):
        anomalies.append('Unattributed skipped test in process output.')
    return {'results': results, 'started': sorted(started), 'neverStarted': sorted(expected - started),
            'anomalies': anomalies, 'metalArchitectureAssertionObserved': METAL_ASSERTION in output}


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    # Reaping the immediate child does not prove that its descendants exited.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=3)


def run_streamed(command, cwd, environment, log, timeout):
    """Stream bytes immediately, bound the entire process group, retain partial logs."""
    log.parent.mkdir(parents=True, exist_ok=True)
    begin = time.monotonic()
    timed_out = False
    interrupted = False
    chunks = []
    with log.open('wb') as target:
        process = subprocess.Popen(command, cwd=cwd, env=environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            # EOF is not process completion: some processes close their pipes
            # before finishing. Keep the same deadline until both are complete.
            while selector.get_map() or process.poll() is None:
                if time.monotonic() - begin >= timeout:
                    timed_out = True
                    stop_group(process)
                    # A descendant can keep stdout open after the parent exits.
                    # The process group is killed before a final bounded drain.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                events = selector.select(.2)
                for key, _ in events:
                    data = os.read(key.fd, 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    target.write(data)
                    target.flush()
                    chunks.append(data)
                    print(data.decode('utf-8', errors='replace'), end='', flush=True)
                if timed_out and not events:
                    break
            process.wait(timeout=3)
        except KeyboardInterrupt:
            interrupted = True
        finally:
            stop_group(process)
            selector.close()
            process.stdout.close()
    return {'exitCode': process.returncode, 'timedOut': timed_out, 'interrupted': interrupted,
            'durationSeconds': round(time.monotonic() - begin, 3),
            'output': b''.join(chunks).decode('utf-8', errors='replace')}


def source_state(root, expected):
    if not re.fullmatch(r'[0-9a-f]{40}', expected):
        raise ValueError('source_commit must be a full lower-case Git commit SHA.')
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    dirty = subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True)
    if actual != expected or dirty.strip():
        raise ValueError('Qualified source checkout must match source_commit and have no tracked edits or untracked inputs.')
    return actual


def crash_files(directory):
    if not directory.is_dir():
        return {}
    prefixes = ('KataLog', 'xctest', 'swift-', 'native-graphics-probe')
    return {path: (path.stat().st_mtime_ns, path.stat().st_size)
            for path in directory.rglob('*') if path.is_file() and path.name.startswith(prefixes)}


def report_summary(report):
    counts = Counter(value['status'] for value in report['tests'].values())
    report['counts'] = {status: counts[status] for status in STATUSES}
    report['discoveredCount'] = len(report['expectedIDs'])
    report['partitionComplete'] = (set(report['tests']) == set(report['expectedIDs'])
                                   and sum(counts.values()) == report['discoveredCount'])
    selected = set(report['selectedIDs'])
    all_selected_passed = bool(selected) and all(report['tests'][test]['status'] == 'passed' for test in selected)
    process_failures = any(item['exitCode'] != 0 or item['timedOut'] for item in report['executions'])
    report['selectedScopePassed'] = (all_selected_passed and report['partitionComplete']
                                     and not report['errors'] and not process_failures)
    report['rawFullSuitePassed'] = (report['selectedScopePassed'] and selected == set(report['expectedIDs'])
                                    and not report.get('buildReuseRequested', False))
    report['nativeGatePassed'] = report['rawFullSuitePassed']
    return report


class Qualification:
    def __init__(self, args, runner=run_streamed):
        self.args, self.runner = args, runner
        self.begin = time.monotonic()
        self.output = args.output.resolve()
        self.environment = dict(os.environ)
        self.environment.update(KATALOG_TEST_PYTHON=sys.executable, KATALOG_PYTHON=sys.executable,
                                KATALOG_TEST_NATIVE_WINDOWS='1', NSUnbufferedIO='YES')
        self.report = {'schemaVersion': 1, 'executionMode': 'class-then-never-started-tests',
                       'sourceCommit': args.source_commit, 'expectedIDs': [], 'selectedIDs': [], 'tests': {},
                       'executions': [], 'errors': [], 'status': 'initializing', 'crashReports': [],
                       'buildReuseRequested': args.skip_build,
                       'renderEnvironment': {'KATALOG_TEST_NATIVE_WINDOWS': '1',
                           'KATALOG_UI_ARTIFACTS': 'set' if self.environment.get('KATALOG_UI_ARTIFACTS') else 'unset'},
                       'harnessSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}

    def save(self):
        write_json(self.output / 'summary.json', report_summary(self.report))

    def run(self, command, name, timeout):
        remaining = self.args.budget_seconds - (time.monotonic() - self.begin)
        if remaining <= 0:
            raise TimeoutError('Diagnostic time budget exhausted; pending IDs remain notRun.')
        self.report['activeExecution'] = name
        self.save()
        result = self.runner(command, self.args.source_root, self.environment,
                             self.output / 'logs' / (name + '.log'), min(timeout, remaining))
        return result

    def execute_tests(self, identifiers, name, timeout):
        # Identifiers are selected from discovery, never from a shell expansion.
        expression = '^(?:' + '|'.join(re.escape(test) for test in identifiers) + ')$'
        command = ['swift', 'test', '--disable-sandbox', '--scratch-path', str(self.args.scratch_path),
                   '--skip-build', '--filter', expression]
        result = self.run(command, name, timeout)
        parsed = parse_execution(result['output'], identifiers, result['exitCode'], result['timedOut'], result.get('interrupted', False))
        if result['exitCode'] == 0 and not result['timedOut'] and parsed['neverStarted']:
            parsed['anomalies'].append('Successful process omitted requested test identifiers: ' + name)
        execution = {key: value for key, value in result.items() if key != 'output'}
        execution.update(name=name, requestedIDs=identifiers, startedIDs=parsed['started'],
                         neverStartedIDs=parsed['neverStarted'], log='logs/' + name + '.log',
                         metalArchitectureAssertionObserved=parsed['metalArchitectureAssertionObserved'])
        self.report['executions'].append(execution)
        self.report['errors'].extend(parsed['anomalies'])
        for identifier, value in parsed['results'].items():
            if self.report['tests'][identifier]['status'] != 'notRun':
                self.report['errors'].append('Attempt to overwrite a prior test result: ' + identifier)
            else:
                self.report['tests'][identifier] = dict(value, execution=name)
        self.save()
        if result.get('interrupted'):
            raise KeyboardInterrupt()
        return parsed['neverStarted']

    def qualify(self):
        crashes = Path.home() / 'Library/Logs/DiagnosticReports'
        before = crash_files(crashes)
        self.save()
        try:
            source_state(self.args.source_root, self.args.source_commit)
            if not self.args.skip_build:
                result = self.run(['swift', 'build', '--build-tests', '--disable-sandbox', '--force-resolved-versions',
                                   '--scratch-path', str(self.args.scratch_path)], 'build', self.args.build_timeout)
                if result['exitCode'] != 0 or result['timedOut']:
                    raise RuntimeError('Build failed or timed out; see logs/build.log.')
            result = self.run(['swift', 'test', '--disable-sandbox', '--scratch-path', str(self.args.scratch_path),
                               'list', '--skip-build'], 'discovery', 120)
            if result['exitCode'] != 0 or result['timedOut']:
                raise RuntimeError('Test discovery failed or timed out; see logs/discovery.log.')
            ids = discover_ids(result['output'])
            self.report['expectedIDs'] = ids
            self.report['tests'] = {test: {'status': 'notRun'} for test in ids}
            groups = defaultdict(list)
            for test in ids:
                groups[test.split('/')[0]].append(test)
            requested = set(self.args.test_class or groups)
            if not requested <= set(groups):
                raise ValueError('Unknown requested test classes: ' + ', '.join(sorted(requested - set(groups))))
            self.report['selectedIDs'] = [test for test in ids if test.split('/')[0] in requested]
            self.report['scope'] = 'full' if requested == set(groups) else 'selected-classes'
            self.report['status'] = 'running'
            write_json(self.output / 'expected-tests.json', ids)
            self.save()
            for index, cls in enumerate(sorted(requested)):
                name = '%03d-%s' % (index, cls)
                pending = self.execute_tests(groups[cls], name, self.args.class_timeout)
                for child, identifier in enumerate(pending):
                    # A failed/crashed/started test is never included here.
                    self.execute_tests([identifier], name + '-unreached-%03d' % child, self.args.test_timeout)
            source_state(self.args.source_root, self.args.source_commit)
            self.report['status'] = 'complete'
        except (Exception, KeyboardInterrupt) as error:
            self.report['status'] = 'interrupted' if isinstance(error, KeyboardInterrupt) else 'incomplete'
            self.report['errors'].append(type(error).__name__ + ': ' + str(error))
        finally:
            for path, fingerprint in crash_files(crashes).items():
                if before.get(path) != fingerprint:
                    destination = self.output / 'crashes' / path.name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, destination)
                    self.report['crashReports'].append('crashes/' + path.name)
            self.report.pop('activeExecution', None)
            self.report['durationSeconds'] = round(time.monotonic() - self.begin, 3)
            self.save()
        return 0 if self.report['selectedScopePassed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--scratch-path', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--test-class', action='append', help='Local bounded check only; full-suite gate stays false.')
    parser.add_argument('--skip-build', action='store_true', help='Local selected-class check only; reuse an existing matching build.')
    parser.add_argument('--build-timeout', type=float, default=1200)
    parser.add_argument('--class-timeout', type=float, default=600)
    parser.add_argument('--test-timeout', type=float, default=120)
    parser.add_argument('--budget-seconds', type=float, default=2100)
    args = parser.parse_args()
    args.source_root = args.source_root.resolve()
    args.scratch_path = args.scratch_path.resolve()
    if any(value <= 0 for value in (args.build_timeout, args.class_timeout, args.test_timeout, args.budget_seconds)):
        parser.error('All timeouts must be positive.')
    if args.skip_build and not args.test_class:
        parser.error('--skip-build is reserved for a local --test-class check; full qualification builds the frozen source.')
    # Same required fixtures as the frozen native gate; missing dependencies fail.
    import numpy  # noqa: F401
    import pyulog  # noqa: F401
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt()
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        return Qualification(args).qualify()
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == '__main__':
    sys.exit(main())
