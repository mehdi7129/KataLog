"""Adversarial MAVLink byte-stream scenarios, independent of WireVehicle.

No device is opened. Faults are applied to encoded packets and byte delivery,
not to the collector's decoded message objects or missing-block bookkeeping.
"""
import contextlib
import hashlib
import io
import json
import os
import random
import signal
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import usb_collect as usb
from pymavlink.dialects.v20 import common as mav


class SimulatedClock:
    def __init__(self):
        self.now = 100.0

    def monotonic(self):
        return self.now


class FragmentedCable:
    """A serial-shaped byte pipe with a separately encoded flight-controller peer."""
    def __init__(self, clock, responder=None):
        self.clock, self.responder = clock, responder
        self.buffer = bytearray()
        self.closed = False
        self.requests = []
        self.decoder = mav.MAVLink(None)
        self.encoders = {}
        self.read_count = 0
        self.fragment_sizes = (1, 2, 7, 31, 257, 1024)
        self.cancel_on_empty = False

    @property
    def in_waiting(self):
        return len(self.buffer)

    def packet(self, message, source=(73, 1), version=2):
        encoder = self.encoders.setdefault(source, mav.MAVLink(None, srcSystem=source[0], srcComponent=source[1]))
        value = message.pack(encoder, force_mavlink1=version == 1)
        encoder.seq = (encoder.seq + 1) & 255
        return value

    def send(self, message, **options):
        self.buffer.extend(self.packet(message, **options))

    def write(self, data):
        for request in self.decoder.parse_buffer(data) or []:
            self.requests.append(request)
            if self.responder:
                self.responder(request)
        return len(data)

    def read(self, maximum):
        if not self.buffer:
            if self.cancel_on_empty:
                # main() must have installed its real SIGTERM handler. This
                # exercises delivery and restoration, not a direct callback.
                os.kill(os.getpid(), signal.SIGTERM)
            self.clock.now += 0.005
            return b''
        self.clock.now += 0.00001
        count = min(maximum, self.fragment_sizes[self.read_count % len(self.fragment_sizes)])
        self.read_count += 1
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        return result

    def flush(self):
        pass  # This synthetic stream has no operating-system transmit queue.

    def close(self):
        self.closed = True


def heartbeat(armed=False):
    return mav.MAVLink_heartbeat_message(mav.MAV_TYPE_SURFACE_BOAT, mav.MAV_AUTOPILOT_PX4,
        mav.MAV_MODE_FLAG_SAFETY_ARMED if armed else 0, 0, mav.MAV_STATE_STANDBY, 3)


def version(uid=0x1020304050607080):
    return mav.MAVLink_autopilot_version_message(0, 0, 0, 0, 0,
        [0] * 8, [0] * 8, [0] * 8, 0, 0, uid, [0] * 18)


class USBCollectorStressTests(unittest.TestCase):
    def setUp(self):
        self.clock = SimulatedClock()
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(usb.time, 'monotonic', self.clock.monotonic))
        self.stack.enter_context(patch.multiple(usb, RESPONSE_TIMEOUT=0.04, INVENTORY_TIMEOUT=0.04))
        self.output = io.StringIO()
        self.stack.enter_context(contextlib.redirect_stdout(self.output))

    def test_fragmented_v1_v2_frames_reject_bad_crc_and_wrong_system_or_component(self):
        for framing in (1, 2):
            with self.subTest(framing=framing):
                cable = FragmentedCable(self.clock)
                # Bytes preceding a frame and a corrupt frame must not become
                # an accepted identity or inventory entry.
                cable.buffer.extend(b'noise\x00\x7f')
                damaged = bytearray(cable.packet(heartbeat(), version=framing))
                damaged[-1] ^= 0x40
                cable.buffer.extend(damaged)
                cable.send(heartbeat(), version=framing)

                def respond(request):
                    if request.get_type() == 'COMMAND_LONG':
                        cable.send(version(3), source=(74, 1), version=framing)
                        cable.send(version(4), source=(73, 2), version=framing)
                        broken = bytearray(cable.packet(version(5), version=framing))
                        broken[-2] ^= 0x80
                        cable.buffer.extend(broken)
                        cable.send(version(), version=framing)
                    elif request.get_type() == 'LOG_REQUEST_LIST':
                        # False sources claim there are 99 logs, or report the
                        # selected device armed. None may alter this session.
                        cable.send(heartbeat(armed=True), source=(73, 2))
                        cable.send(mav.MAVLink_log_entry_message(6, 99, 100, 2, 200), source=(74, 1))
                        cable.send(mav.MAVLink_log_entry_message(6, 99, 100, 2, 200), source=(73, 2))
                        cable.send(mav.MAVLink_log_entry_message(19, 1, 19, 1700000000, 451), version=framing)

                cable.responder = respond
                with usb.USBSession(cable) as session:
                    self.assertEqual(session.identity, 'uid:1020304050607080')
                    self.assertEqual(session.inventory(), [{'id': 19, 'timeUTC': 1700000000, 'size': 451}])
                    self.assertFalse(session.armed)
                self.assertTrue(cable.closed)
                self.assertGreater(cable.read_count, 10, 'Packets must actually cross read boundaries.')
                self.assertEqual(cable.requests[-1].get_type(), 'LOG_REQUEST_END')

    def test_stale_heartbeat_is_not_kept_alive_by_noise_other_sources_or_buffered_data(self):
        cable = FragmentedCable(self.clock)
        cable.send(heartbeat())
        cable.responder = lambda request: cable.send(version()) if request.get_type() == 'COMMAND_LONG' else None
        with usb.USBSession(cable) as session:
            # A byte buffer full of telemetry is not evidence of a fresh
            # heartbeat from the selected autopilot endpoint.
            for index in range(80):
                cable.send(heartbeat(), source=(73, 2))
                cable.send(heartbeat(), source=(74, 1))
                cable.send(mav.MAVLink_log_data_message(19, index * 90, 90, b'x' * 90))
            self.clock.now += usb.HEARTBEAT_TIMEOUT - 0.001
            # Consume some valid LOG_DATA while still inside the deadline.
            self.assertIsNotNone(session.receive(self.clock.now + 0.01))
            self.clock.now += 0.01
            before = len(cable.buffer)
            with self.assertRaisesRegex(usb.CollectionError, 'heartbeat'):
                session.receive(self.clock.now + 1)
            self.assertEqual(len(cable.buffer), before, 'Stale heartbeat must reject before draining queued noise.')
        self.assertTrue(cable.closed)

    def test_three_megabyte_download_recovers_burst_loss_duplicates_and_disorder(self):
        randomizer = random.Random(0xA011A)
        payload = usb.MAGIC + randomizer.randbytes(3 * 1024 * 1024 + 37)
        expected_hash = hashlib.sha256(payload).hexdigest()
        entry = {'id': 65520, 'timeUTC': 1700000123, 'size': len(payload)}
        cable = FragmentedCable(self.clock)
        cable.send(heartbeat())
        attempts = Counter()
        data_requests = []
        lost = set()

        def respond(request):
            kind = request.get_type()
            if kind == 'COMMAND_LONG':
                cable.send(version())
            elif kind == 'LOG_REQUEST_LIST':
                cable.send(heartbeat())
                cable.send(mav.MAVLink_log_entry_message(entry['id'], 1, entry['id'], entry['timeUTC'], len(payload)))
            elif kind == 'LOG_REQUEST_DATA':
                self.assertEqual((request.target_system, request.target_component, request.id), (73, 1, entry['id']))
                data_requests.append((request.ofs, request.count))
                cable.send(heartbeat())
                packets = []
                for offset in range(request.ofs, min(len(payload), request.ofs + request.count), 90):
                    attempts[offset] += 1
                    block = offset // 90
                    # Independent loss schedule: bursts of 11 packets in every
                    # 157 packets, with three burst positions lost twice.
                    if 61 <= block % 157 < 72 and attempts[offset] <= (2 if block % 157 < 64 else 1):
                        lost.add(offset)
                        continue
                    chunk = payload[offset:offset + 90]
                    packet = cable.packet(mav.MAVLink_log_data_message(entry['id'], offset, len(chunk), chunk.ljust(90, b'\0')))
                    packets.append(packet)
                    if block % 13 == 0:
                        packets.append(packet)
                randomizer.shuffle(packets)
                cable.buffer.extend(b''.join(packets))

        cable.responder = respond
        with tempfile.TemporaryDirectory(prefix='katalog-usb-stress-') as directory:
            with usb.USBSession(cable) as session:
                usb.download(session, 'uid:1020304050607080', entry, directory)
            files = list(Path(directory).rglob('*.ulg'))
            self.assertEqual(len(files), 1)
            actual = files[0].read_bytes()
            self.assertEqual(len(actual), len(payload))
            self.assertEqual(hashlib.sha256(actual).hexdigest(), expected_hash)
            receipt = json.loads(files[0].with_name(files[0].name + '.katalog.json').read_text())
            self.assertEqual(receipt['sha256'], expected_hash)
            self.assertFalse(list(Path(directory).rglob('*.part')))
        self.assertGreater(len(lost), 1000)
        self.assertTrue(all(attempts[offset] >= 2 for offset in lost))
        self.assertGreater(sum(count >= 3 for count in attempts.values()), 100)
        self.assertGreater(len(data_requests), 60)
        self.assertTrue(any(count <= 11 * 90 for _, count in data_requests[1:]), 'Lost runs should be requested again, not the whole file.')
        progress = [json.loads(line)['bytes'] for line in self.output.getvalue().splitlines() if json.loads(line)['event'] == 'progress']
        self.assertEqual(progress[-1], len(payload))
        self.assertEqual(progress, sorted(set(progress)), 'Duplicates must never increase reported byte coverage.')
        self.assertEqual(cable.requests[-1].get_type(), 'LOG_REQUEST_END')
        self.assertTrue(cable.closed)
        self.transfer_metrics = {
            'bytes': len(payload), 'sha256': expected_hash,
            'dataRequests': len(data_requests), 'lostBlockOffsets': len(lost),
            'offsetsRequestedAtLeastThreeTimes': sum(count >= 3 for count in attempts.values()),
            'maximumRequestsForOneOffset': max(attempts.values()),
            'serialReadFragments': cable.read_count,
        }

    def test_permanent_missing_burst_is_bounded_and_never_published(self):
        payload = usb.MAGIC + b'z' * 20000
        cable = FragmentedCable(self.clock)
        cable.send(heartbeat())
        requested_hole = 0

        def respond(request):
            nonlocal requested_hole
            if request.get_type() == 'COMMAND_LONG':
                cable.send(version())
            elif request.get_type() == 'LOG_REQUEST_LIST':
                cable.send(mav.MAVLink_log_entry_message(2, 1, 2, 1700000000, len(payload)))
            elif request.get_type() == 'LOG_REQUEST_DATA':
                cable.send(heartbeat())
                if request.ofs <= 900 < request.ofs + request.count:
                    requested_hole += 1
                for offset in range(request.ofs, min(len(payload), request.ofs + request.count), 90):
                    if 900 <= offset < 1800:
                        continue
                    chunk = payload[offset:offset + 90]
                    cable.send(mav.MAVLink_log_data_message(2, offset, len(chunk), chunk.ljust(90, b'\0')))

        cable.responder = respond
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(usb.CollectionError, 'incomplet'), usb.USBSession(cable) as session:
                usb.download(session, 'uid:1020304050607080', {'id': 2, 'timeUTC': 1700000000, 'size': len(payload)}, directory)
            self.assertFalse(list(Path(directory).rglob('*.ulg')))
            self.assertFalse(list(Path(directory).rglob('*.part')))
        self.assertGreaterEqual(requested_hole, 2)
        self.assertLessEqual(requested_hole, usb.MAX_ATTEMPTS + 1)
        self.assertEqual(cable.requests[-1].get_type(), 'LOG_REQUEST_END')
        self.assertTrue(cable.closed)

    def test_cli_cancellation_in_identity_inventory_and_download_always_closes(self):
        for phase in ('identity', 'inventory', 'download'):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                cable = FragmentedCable(self.clock)
                cable.send(heartbeat())

                def respond(request):
                    kind = request.get_type()
                    if kind == 'COMMAND_LONG':
                        if phase == 'identity':
                            cable.cancel_on_empty = True
                        else:
                            cable.send(version())
                    elif kind == 'LOG_REQUEST_LIST':
                        if phase == 'inventory':
                            cable.cancel_on_empty = True
                        else:
                            cable.send(mav.MAVLink_log_entry_message(7, 1, 7, 1700000000, 128))
                    elif kind == 'LOG_REQUEST_DATA':
                        cable.cancel_on_empty = True

                cable.responder = respond
                arguments = ['download', '--device', '/dev/cu.synthetic', '--identity', 'uid:1020304050607080',
                             '--log-id', '7', '--time-utc', '1700000000', '--size', '128', '--destination', directory]
                with patch.object(usb, 'open_serial', return_value=cable):
                    previous_handler = signal.getsignal(signal.SIGTERM)
                    self.assertEqual(usb.main(arguments), 130)
                    self.assertIs(signal.getsignal(signal.SIGTERM), previous_handler)
                self.assertTrue(cable.closed)
                requests = [request.get_type() for request in cable.requests]
                if phase == 'identity':
                    self.assertNotIn('LOG_REQUEST_LIST', requests)
                    self.assertNotIn('LOG_REQUEST_END', requests, 'No LOG session was started during identity lookup.')
                else:
                    self.assertEqual(requests[-1], 'LOG_REQUEST_END')
                self.assertFalse(list(Path(directory).rglob('*.ulg')))
                self.assertFalse(list(Path(directory).rglob('*.part')))
                event = json.loads(self.output.getvalue().splitlines()[-1])
                self.assertEqual(event['event'], 'error')
                self.assertTrue(event['cancelled'])
                self.assertFalse(event['retryable'])


if __name__ == '__main__':
    unittest.main()
