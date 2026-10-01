#!/usr/bin/env python3
"""Run the native gate with its autonomous Python fixtures; reject skipped tests."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

def test_counts(output):
    # SwiftPM may launch one XCTest bundle per target. Sum the bundle totals,
    # not the final executable alone and not nested suite subtotals.
    pattern = r"Test Suite '[^'\n]+\.xctest' (?:passed|failed)[^\n]*\n\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?"
    bundles = re.findall(pattern, output)
    if not bundles:
        matches = re.findall(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?', output)
        bundles = matches[-1:]
    return tuple(sum(int(values[index] or 0) for values in bundles) for index in range(3)), bool(bundles)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--summary', type=Path)
    parser.add_argument('--log', type=Path)
    parser.add_argument('swift_arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    # Real CLI report fixtures are part of the gate, never an optional skip.
    import numpy  # noqa: F401
    import pyulog  # noqa: F401
    environment = dict(os.environ)
    environment['KATALOG_TEST_PYTHON'] = sys.executable
    environment['KATALOG_PYTHON'] = sys.executable
    # The native gate includes real AppKit window controls and independent
    # detail sessions. Hosted macOS runners provide the required GUI session.
    environment['KATALOG_TEST_NATIVE_WINDOWS'] = '1'
    arguments = args.swift_arguments
    if arguments[:1] == ['--']: arguments = arguments[1:]
    result = subprocess.run(['swift', 'test', *arguments], env=environment,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
    if args.log:
        args.log.parent.mkdir(parents=True, exist_ok=True); args.log.write_text(result.stdout)
    else: print(result.stdout, end='')
    (executed, skipped, failures), found = test_counts(result.stdout)
    summary = {'testsRun':int(executed), 'skipped':int(skipped or 0), 'failures':int(failures),
               'exitCode':result.returncode, 'nativeGatePassed': result.returncode == 0 and found
               and int(executed) > 0 and not int(skipped or 0) and not int(failures)
               and 'Test skipped -' not in result.stdout}
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True); args.summary.write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary, sort_keys=True))
    return 0 if summary['nativeGatePassed'] else 1

if __name__ == '__main__': sys.exit(main())
