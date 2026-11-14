#!/usr/bin/env python3
"""Assert the actual host/process architecture before a native qualification."""
import argparse
import json
import platform
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--architecture', choices=('arm64', 'x86_64'), required=True)
    parser.add_argument('--major')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    translated = subprocess.run(['/usr/sbin/sysctl', '-in', 'sysctl.proc_translated'], capture_output=True, text=True)
    architecture = subprocess.check_output(['/usr/bin/uname', '-m'], text=True).strip()
    version = subprocess.check_output(['/usr/bin/sw_vers', '-productVersion'], text=True).strip()
    if (platform.system() != 'Darwin' or architecture != args.architecture or platform.machine() != args.architecture
            or translated.stdout.strip() == '1' or (args.major and version.split('.')[0] != args.major)):
        raise SystemExit('Runner natif / architecture / version macOS incorrects ; Rosetta ne qualifie pas cette recette.')
    result = dict(architecture=architecture, macOS=version, pythonArchitecture=platform.machine(), rosetta=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
