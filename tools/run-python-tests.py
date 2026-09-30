#!/usr/bin/env python3
"""Autonomous gate: private corpus skips are separate, all other skips fail."""
import argparse
import json
from pathlib import Path
import sys
import unittest

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--summary', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    tests = unittest.defaultTestLoader.discover(str(root / 'Tests'))
    result = unittest.TextTestRunner(verbosity=2).run(tests)
    expected_reason = 'Set KATALOG_PRIVATE_FIXTURES to the external reference corpus'
    private_skips = [(test.id(), reason) for test, reason in result.skipped if reason == expected_reason]
    unexpected = [(test.id(), reason) for test, reason in result.skipped if reason != expected_reason]
    summary = {'run': result.testsRun, 'passed': result.testsRun - len(result.failures) - len(result.errors) - len(result.skipped),
               'failures': len(result.failures), 'errors': len(result.errors),
               'privateCorpusNotRun': [name for name, _ in private_skips], 'unexpectedSkips': unexpected,
               'autonomousGatePassed': result.wasSuccessful() and not unexpected}
    if args.summary:
        args.summary.parent.mkdir(parents=True, exist_ok=True)
        args.summary.write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, sort_keys=True))
    return 0 if summary['autonomousGatePassed'] else 1

if __name__ == '__main__':
    sys.exit(main())
