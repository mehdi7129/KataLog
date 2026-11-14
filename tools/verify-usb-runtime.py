#!/usr/bin/env python3
"""Exercise the shipped USB helper over a real OS PTY, without physical hardware."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def wait_for(read, predicate, *, timeout=15):
    deadline = time.monotonic() + timeout
    while True:
        try:
            value = read()
            if predicate(value):
                return value
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError('Synthetic USB condition did not become ready')
        time.sleep(.02)


def update_control(root, **changes):
    path = root / 'control.json'
    control = json.loads(path.read_text())
    control.update(changes)
    temporary = root / 'control.next'
    temporary.write_text(json.dumps(control))
    temporary.replace(path)
    wait_for(lambda: json.loads((root/'metrics.json').read_text()),
             lambda value: all(value['control'].get(key) == val for key, val in changes.items()))


def check_version(helper, bench_python, root, version):
    bench = subprocess.Popen([bench_python, str(ROOT/'tools/bench-usb-serial.py'),
        '--output', str(root/'vehicle'), '--mavlink-version', str(version),
        '--log-mib', '.25', '--rate-kib', '1024', '--drop-every', '257', '--noise-hz', '2'],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        connection = wait_for(lambda: json.loads((root/'vehicle/connection.json').read_text()), lambda data: bool(data.get('port')))
        destination = root/'downloads'; destination.mkdir()
        home = root/'home'; home.mkdir()
        env = {key: value for key, value in os.environ.items() if not key.startswith(('PYTHON', 'DYLD_', 'KATALOG_'))}
        env.update(HOME=str(home), PATH='/usr/bin:/bin', PYTHONHOME='/nonexistent/katalog-python',
                   PYTHONPATH='/nonexistent/katalog-modules', KATALOG_USB_BENCH_PORT=connection['port'])

        def run(arguments, *, success=True):
            result = subprocess.run([str(helper), 'usb', *arguments], env=env,
                                    text=True, capture_output=True, timeout=90)
            events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
            if success:
                if result.returncode != 0 or any(item.get('event') == 'error' for item in events):
                    raise RuntimeError('Bundled USB operation failed: ' + result.stderr + result.stdout)
            elif result.returncode == 0 or not any(item.get('event') == 'error' for item in events):
                raise RuntimeError('Bundled USB operation accepted an invalid request')
            return events

        ports = run(['ports'])
        assert any(p['path'] == connection['port'] for event in ports for p in event.get('ports', []))
        inventory = run(['inventory', '--device', connection['port']])
        listing = next(event for event in inventory if event['event'] == 'usb_inventory')
        assert listing['device']['identity'] == connection['identity']
        assert len(listing['logs']) == 2
        log = connection['logs'][0]
        arguments = ['download', '--device', connection['port'], '--identity', connection['identity'],
                     '--log-id', str(log['id']), '--time-utc', str(log['timeUTC']),
                     '--size', str(log['size']), '--destination', str(destination)]
        started = time.monotonic()
        downloaded = next(event for event in run(arguments) if event['event'] == 'downloaded')
        elapsed = time.monotonic() - started
        copied = Path(downloaded['localPath'])
        assert copied.read_bytes() == Path(log['path']).read_bytes()
        assert hashlib.sha256(copied.read_bytes()).hexdigest() == log['sha256'] == downloaded['sha256']
        cached = next(event for event in run(arguments) if event['event'] == 'downloaded')
        assert cached['cached'] is True

        # Same system/component and log metadata on a different physical UID.
        update_control(root/'vehicle', identityIndex=2)
        run(arguments, success=False)
        assert len(list(destination.rglob('*.ulg'))) == 1
        assert hashlib.sha256(copied.read_bytes()).hexdigest() == log['sha256']
        update_control(root/'vehicle', identityIndex=1, armed=True)
        run(['inventory', '--device', connection['port']], success=False)
        update_control(root/'vehicle', armed=False)

        # Cancellation reaches the actual packaged process while it owns the port.
        other = connection['logs'][1]
        second = ['download', '--device', connection['port'], '--identity', connection['identity'],
                  '--log-id', str(other['id']), '--time-utc', str(other['timeUTC']),
                  '--size', str(other['size']), '--destination', str(destination)]
        update_control(root/'vehicle', pauseData=True)
        prior = json.loads((root/'vehicle/metrics.json').read_text())['receivedMessages'].get('LOG_REQUEST_DATA', 0)
        active = subprocess.Popen([str(helper), 'usb', *second], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for(lambda: json.loads((root/'vehicle/metrics.json').read_text()),
                     lambda metrics: metrics['receivedMessages'].get('LOG_REQUEST_DATA', 0) > prior)
            active.terminate()
            output, errors = active.communicate(timeout=10)
            assert active.returncode == 130, (active.returncode, errors)
            assert any(json.loads(line).get('cancelled') for line in output.splitlines())
        finally:
            if active.poll() is None:
                active.kill(); active.communicate()
        assert len(list(destination.rglob('*.ulg'))) == 1
        assert not list(destination.rglob('*.part'))
        update_control(root/'vehicle', pauseData=False)
        run(['inventory', '--device', connection['port']])  # Descriptor really released.
        metrics = wait_for(lambda: json.loads((root/'vehicle/metrics.json').read_text()),
                           lambda data: data.get('endRequests', 0) >= 5)
        return dict(mavlinkVersion=version, payloadBytes=log['size'], sha256=log['sha256'],
                    downloadSeconds=round(elapsed, 3), droppedBlocks=metrics.get('blocksDroppedOnce', 0),
                    dataRequests=metrics['receivedMessages'].get('LOG_REQUEST_DATA', 0),
                    exactBytes=True, cacheVerified=True, wrongUIDRejected=True, armedRejected=True,
                    cancellationAndPortRelease=True, externalPythonUnavailable=True)
    finally:
        if bench.poll() is None:
            bench.terminate()
        try:
            bench.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            bench.kill(); bench.communicate()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--bench-python', default=sys.executable)
    args = parser.parse_args()
    info = plistlib.loads((args.app/'Contents/Info.plist').read_bytes())
    architecture = info.get('KatalogArchitecture')
    if architecture != platform.machine():
        raise RuntimeError('USB runtime must execute on the native architecture of the app')
    subprocess.run([sys.executable, str(ROOT/'tools/check-native-host.py'), '--architecture', architecture], check=True)
    helper = args.app/'Contents/Helpers/KataLogEngine.app/Contents/MacOS/KataLogEngine'
    for executable in (helper, args.app/'Contents/MacOS/KataLog'):
        actual = subprocess.check_output(['/usr/bin/lipo', '-archs', str(executable)], text=True).split()
        if actual != [architecture]:
            raise RuntimeError('USB runtime received an executable from a different architecture')
    runs = []
    with tempfile.TemporaryDirectory(prefix='katalog-usb-runtime-') as temporary:
        for version in (1, 2):
            root = Path(temporary)/str(version); root.mkdir()
            runs.append(check_version(helper, args.bench_python, root, version))
    report = dict(status='passed', syntheticOnly=True, physicalHardwareTested=False,
                  version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                  architecture=architecture, macOS=platform.mac_ver()[0], runs=runs)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, sort_keys=True))


if __name__ == '__main__':
    main()
