"""Real PTY integration with periodic MAVLink heartbeats; no hardware ports."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

import serial
from pyulog import ULog
from pymavlink.dialects.v20 import common as mav

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Sources/KataLog/Resources'))
import usb_collect as usb


class USBSerialBenchTests(unittest.TestCase):
    def start_vehicle(self, version=2, drop_every=0):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        process = subprocess.Popen([sys.executable, str(ROOT/'tools/bench-usb-serial.py'),
            '--output', str(root), '--mavlink-version', str(version), '--log-mib', '.025',
            '--drop-every', str(drop_every), '--noise-hz', '2'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def stop():
            if process.poll() is None:
                process.terminate()
            try: process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.communicate()
        self.addCleanup(stop)
        deadline = time.monotonic() + 15
        while not (root/'connection.json').exists():
            if process.poll() is not None:
                self.fail(process.stderr.read())
            if time.monotonic() >= deadline:
                self.fail('PTY simulator did not become ready')
            time.sleep(.02)
        return root, json.loads((root/'connection.json').read_text())

    def control(self, root, **changes):
        path = root/'control.json'
        settings = json.loads(path.read_text()); settings.update(changes)
        temporary = path.with_suffix('.next')
        temporary.write_text(json.dumps(settings)); temporary.replace(path)
        time.sleep(.2)

    def test_periodic_heartbeat_valid_logs_loss_noise_and_real_serial_transfer(self):
        root, connection = self.start_vehicle(drop_every=257)
        # Receive two heartbeats without ever transmitting a packet. This is
        # intentionally unlike the request-reactive unit-test WireVehicle.
        parser = mav.MAVLink(None); parser.robust_parsing = True
        count = 0
        with serial.Serial(connection['port'], 115200, timeout=.1, write_timeout=1) as port:
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and count < 2:
                for message in parser.parse_buffer(port.read(4096)) or []:
                    count += message.get_type() == 'HEARTBEAT'
            self.assertGreaterEqual(count, 2)
            with usb.USBSession(port) as session:
                self.assertEqual(session.identity, connection['identity'])
                entries = session.inventory()
                self.assertEqual(len(entries), 2)
                destination = root/'downloads'; destination.mkdir()
                with contextlib.redirect_stdout(io.StringIO()):
                    usb.download(session, session.identity, entries[0], destination)
        target = next(destination.rglob('*.ulg'))
        self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), connection['logs'][0]['sha256'])
        self.assertGreater(len(ULog(str(target)).data_list), 0)
        deadline = time.monotonic() + 3
        while True:
            metrics = json.loads((root/'metrics.json').read_text())
            if metrics.get('endRequests', 0) >= 1 or time.monotonic() >= deadline:
                break
            time.sleep(.02)
        self.assertGreater(metrics['blocksDroppedOnce'], 0)
        self.assertGreater(metrics['noiseFramesScheduled'], 0)
        self.assertGreaterEqual(metrics.get('endRequests', 0), 1)

    def test_mavlink1_uid_and_control_identity_and_reconnect(self):
        root, connection = self.start_vehicle(version=1)
        with usb.USBSession(serial.Serial(connection['port'], 115200, timeout=.1, write_timeout=1)) as session:
            self.assertEqual(session.identity, connection['identity'])
            self.assertTrue(session.identity.startswith('uid:'))
            self.assertEqual(len(session.inventory()), 2)
        self.control(root, identityIndex=2, reconnectToken=1)
        changed = json.loads((root/'connection.json').read_text())
        self.assertNotEqual(changed['identity'], connection['identity'])
        self.assertEqual(changed['generation'], 1)
        with usb.USBSession(serial.Serial(changed['port'], 115200, timeout=.1, write_timeout=1)) as session:
            self.assertEqual(session.identity, changed['identity'])
            self.assertEqual(len(session.inventory()), 2)
        self.control(root, armed=True)
        with self.assertRaisesRegex(usb.CollectionError, 'armé'):
            with usb.USBSession(serial.Serial(changed['port'], 115200, timeout=.1, write_timeout=1)):
                self.fail('Armed synthetic vehicle must be rejected')


if __name__ == '__main__':
    unittest.main()
