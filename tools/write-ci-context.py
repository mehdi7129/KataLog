#!/usr/bin/env python3
"""Record reproducible synthetic validation conditions, without dumping env."""
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import subprocess
import sys


def command(*args):
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, timeout=30).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--fixture', required=True)
    args = parser.parse_args()
    packages = {}
    for name in ('numpy', 'pyulog'):
        try:
            packages[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            packages[name] = None
    result = {'contextVersion': 1, 'syntheticOnly': True, 'fixture': args.fixture,
              'commit': command('git', 'rev-parse', 'HEAD'), 'python': sys.version,
              'packages': packages, 'swift': command('swift', '--version'),
              'node': command('node', '--version'), 'system': platform.system(),
              'macOS': platform.mac_ver()[0], 'architecture': platform.machine(),
              'runner': {name: os.environ.get(name) for name in
                         ('RUNNER_OS', 'RUNNER_ARCH', 'ImageOS', 'ImageVersion', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
