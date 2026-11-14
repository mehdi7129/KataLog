"""USB collector protocol tests: real MAVLink bytes, no physical serial devices."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import usb_collect as usb
from pymavlink.dialects.v20 import common as mav
from pymavlink.dialects.v10 import common as legacy_mav

PAYLOAD = usb.MAGIC + bytes(range(256)) * 8
UID = 'uid2:' + bytes(range(1, 19)).hex().upper()


class WireVehicle:
    """Serial-shaped stream that interprets requests and returns encoded frames."""
    def __init__(self, payload=PAYLOAD, log_id=1, fault=None, armed=False):
        self.incoming = bytearray()
        self.parser = mav.MAVLink(None)
        self.encoder = mav.MAVLink(None, srcSystem=42, srcComponent=1)
        self.commands = []
        self.closed = False
        self.payload, self.log_id, self.fault = payload, log_id, fault
        self.request_count = 0
        self.armed = armed
        self.emit_heartbeat()

    @property
    def in_waiting(self):
        return len(self.incoming)

    def emit(self, message, *, force_v1=False):
        self.incoming.extend(message.pack(self.encoder, force_mavlink1=force_v1))

    def emit_heartbeat(self):
        self.emit(mav.MAVLink_heartbeat_message(mav.MAV_TYPE_SURFACE_BOAT, mav.MAV_AUTOPILOT_PX4,
                  mav.MAV_MODE_FLAG_SAFETY_ARMED if self.armed else 0, 0, 3, 3), force_v1=True)

    def version(self):
        identity = [0] * 18 if self.fault == 'no_uid' else list(range(1, 19))
        if self.fault == 'switched_after_data' and self.request_count:
            identity = list(range(2, 20))
        self.emit(mav.MAVLink_autopilot_version_message(0, 0, 0, 0, 0, [0]*8, [0]*8, [0]*8, 0, 0, 0, identity))

    def write(self, data):
        for message in self.parser.parse_buffer(data) or []:
            self.commands.append(message)
            kind = message.get_type()
            if kind == 'HEARTBEAT':
                self.emit_heartbeat()
            elif kind == 'COMMAND_LONG':
                self.version()
            elif kind == 'LOG_REQUEST_LIST':
                if self.fault == 'empty':
                    self.emit(mav.MAVLink_log_entry_message(0, 0, 0, 0, 0))
                elif self.fault != 'inventory_timeout':
                    size = len(self.payload) + (1 if self.fault == 'growing' and self.request_count else 0)
                    self.emit(mav.MAVLink_log_entry_message(self.log_id, 1, self.log_id, 1700000000, size))
            elif kind == 'LOG_REQUEST_DATA':
                self.request_count += 1
                if self.fault == 'armed_during':
                    self.armed = True
                    self.emit_heartbeat()
                    continue
                if self.fault == 'disconnect':
                    raise usb.serial.SerialException('Disconnected fixture')
                if self.fault == 'timeout':
                    continue
                frames = []
                for offset in range(message.ofs, min(len(self.payload), message.ofs + message.count), 90):
                    count = min(90, len(self.payload) - offset)
                    chunk = self.payload[offset:offset + count]
                    if self.fault == 'loss' and self.request_count == 1 and offset == 90:
                        continue
                    if self.fault == 'short':
                        count = 0
                    frames.append(mav.MAVLink_log_data_message(self.log_id, offset, count, chunk.ljust(90, b'\0')))
                if self.fault == 'noise':
                    other = mav.MAVLink(None, srcSystem=43, srcComponent=1)
                    noise = mav.MAVLink_log_data_message(self.log_id, message.ofs, 90, b'x' * 90)
                    self.incoming.extend(noise.pack(other))
                    self.emit(mav.MAVLink_log_data_message(self.log_id + 1, message.ofs, 90, b'y' * 90))
                    self.emit(mav.MAVLink_log_data_message(self.log_id, message.ofs + 1, 90, b'z' * 90))
                for frame in reversed(frames):
                    self.emit(frame)
                    self.emit(frame)  # Every valid packet deliberately duplicated.
        return len(data)

    def read(self, size):
        result = bytes(self.incoming[:size])
        del self.incoming[:size]
        if not result:
            time.sleep(0.001)
        return result

    def flush(self):
        pass  # Writes synchronously deliver every byte to this in-memory peer.

    def close(self):
        self.closed = True


class USBCollectorTests(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.output)
        self.redirect.__enter__()
        self.timeout = patch.multiple(usb, RESPONSE_TIMEOUT=0.025, INVENTORY_TIMEOUT=0.025)
        self.timeout.start()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.timeout.stop)
        self.addCleanup(self.redirect.__exit__, None, None, None)

    def entry(self, vehicle):
        return {'id': vehicle.log_id, 'timeUTC': 1700000000, 'size': len(vehicle.payload)}

    def events(self):
        return [json.loads(line) for line in self.output.getvalue().splitlines()]

    def collect(self, vehicle, identity=UID):
        with usb.USBSession(vehicle) as session:
            usb.download(session, identity, self.entry(vehicle), self.temp.name)
        return next(Path(self.temp.name).rglob('*.ulg'))

    def test_mavlink1_heartbeat_mavlink2_identity_and_nonzero_log_id(self):
        vehicle = WireVehicle(log_id=7)
        with usb.USBSession(vehicle) as session:
            self.assertEqual(session.identity, UID)
            self.assertEqual(session.inventory(), [self.entry(vehicle)])
            self.assertEqual(session.device_info()['systemID'], 42)
        self.assertTrue(vehicle.closed)
        self.assertEqual(vehicle.commands[-1].get_type(), 'LOG_REQUEST_END')

    def test_inventory_empty_and_timeout_always_end_session(self):
        empty = WireVehicle(fault='empty')
        with usb.USBSession(empty) as session:
            self.assertEqual(session.inventory(), [])
        failed = WireVehicle(fault='inventory_timeout')
        with self.assertRaisesRegex(usb.CollectionError, 'incomplet'), usb.USBSession(failed) as session:
            session.inventory()
        self.assertEqual(failed.commands[-1].get_type(), 'LOG_REQUEST_END')
        self.assertTrue(failed.closed)

    def test_loss_duplicates_reverse_order_and_other_sources_are_handled(self):
        for fault in ('loss', 'noise'):
            with self.subTest(fault=fault):
                # A new destination for each scenario prevents cache from hiding transfer.
                with tempfile.TemporaryDirectory() as directory:
                    vehicle = WireVehicle(fault=fault)
                    with usb.USBSession(vehicle) as session:
                        usb.download(session, UID, self.entry(vehicle), directory)
                    target = next(Path(directory).rglob('*.ulg'))
                    self.assertEqual(target.read_bytes(), PAYLOAD)
                    record = json.loads(target.with_name(target.name + '.katalog.json').read_text())
                    self.assertEqual(record['sha256'], hashlib.sha256(PAYLOAD).hexdigest())
                    self.assertEqual(record['source']['uuid'], UID)
                    if fault == 'loss':
                        self.assertGreater(vehicle.request_count, 1)

    def test_multiple_windows_and_short_final_block(self):
        vehicle = WireVehicle(payload=usb.MAGIC + b'a' * (90 * 600 + 23))
        self.assertEqual(self.collect(vehicle).read_bytes(), vehicle.payload)
        self.assertGreater(vehicle.request_count, 1)
        self.assertEqual(self.events()[-1]['bytes'], len(vehicle.payload))

    def test_changed_identity_same_port_never_requests_logs(self):
        vehicle = WireVehicle()
        with self.assertRaisesRegex(usb.CollectionError, 'autre contrôleur'):
            self.collect(vehicle, 'uid:' + '1' * 16)
        self.assertFalse(any(m.get_type().startswith('LOG_REQUEST') for m in vehicle.commands))
        self.assertFalse(list(Path(self.temp.name).rglob('*.ulg')))

    def test_missing_identity_fails_closed(self):
        vehicle = WireVehicle(fault='no_uid')
        with self.assertRaisesRegex(usb.CollectionError, 'identité matérielle'), usb.USBSession(vehicle):
            self.fail('No identity must reject the connection')
        self.assertTrue(vehicle.closed)

    def test_uid_fallback(self):
        message = mav.MAVLink_autopilot_version_message(0, 0, 0, 0, 0, [0]*8, [0]*8, [0]*8, 0, 0, 123, [0]*18)
        self.assertEqual(usb.hardware_identity(message), 'uid:000000000000007B')

    def test_px4_auto_protocol_uses_same_identity_after_cold_or_warm_connection(self):
        for initially_v1 in (True, False):
            with self.subTest(initially_v1=initially_v1):
                vehicle = PX4ProtocolVehicle(initially_v1=initially_v1)
                with usb.USBSession(vehicle) as session:
                    self.assertEqual(session.identity, UID)
                    self.assertFalse(session.force_mavlink1)
                if initially_v1:
                    requests = [m for m in vehicle.commands if m.get_type() == 'COMMAND_LONG']
                    self.assertEqual([m.get_msgbuf()[0] for m in requests], [0xfe, 0xfd])

    def test_true_legacy_version_frame_has_no_uid2_and_falls_back_to_uid(self):
        vehicle = PX4ProtocolVehicle(advertise_v2=False, accept_v2=False)
        with usb.USBSession(vehicle) as session:
            self.assertEqual(session.identity, 'uid:000000000000007B')
            self.assertTrue(session.force_mavlink1)

    def test_advertised_v2_without_v2_response_does_not_downgrade_identity(self):
        vehicle = PX4ProtocolVehicle(accept_v2=False)
        with self.assertRaisesRegex(usb.CollectionError, 'annonce MAVLink 2'), usb.USBSession(vehicle):
            self.fail('A silently downgraded identity cannot be queued')
        self.assertTrue(vehicle.closed)

    def test_hardware_switch_during_protocol_negotiation_is_rejected(self):
        vehicle = PX4ProtocolVehicle(change_uid=True)
        with self.assertRaisesRegex(usb.CollectionError, 'changé pendant la connexion'), usb.USBSession(vehicle):
            self.fail('The negotiation must remain tied to one board')

    def test_armed_initial_and_during_transfer_fail_closed(self):
        for vehicle in (WireVehicle(armed=True), WireVehicle(fault='armed_during')):
            with self.assertRaisesRegex(usb.CollectionError, 'armé'):
                self.collect(vehicle)
            self.assertTrue(vehicle.closed)
            self.assertFalse(list(Path(self.temp.name).rglob('*.ulg')))

    def test_changed_inventory_refuses_download(self):
        vehicle = WireVehicle()
        with self.assertRaisesRegex(usb.CollectionError, 'disparu ou changé'), usb.USBSession(vehicle) as session:
            entry = self.entry(vehicle)
            entry['timeUTC'] += 1
            usb.download(session, UID, entry, self.temp.name)
        self.assertEqual(vehicle.request_count, 0)

    def test_growing_log_is_rejected_before_publication(self):
        with self.assertRaisesRegex(usb.CollectionError, 'changé pendant le transfert'):
            self.collect(WireVehicle(fault='growing'))
        self.assertFalse(list(Path(self.temp.name).rglob('*.ulg')))
        self.assertFalse(list(Path(self.temp.name).rglob('*.part')))

    def test_legacy_vehicle_receives_v1_requests_and_only_read_commands(self):
        vehicle = WireVehicle()
        self.collect(vehicle)
        for message in vehicle.commands:
            self.assertEqual(message.get_msgbuf()[0], 0xfe)
            self.assertIn(message.get_type(), ('HEARTBEAT', 'COMMAND_LONG', 'LOG_REQUEST_LIST', 'LOG_REQUEST_DATA', 'LOG_REQUEST_END'))
            if message.get_type() == 'COMMAND_LONG':
                self.assertIn(message.command, (mav.MAV_CMD_REQUEST_MESSAGE, mav.MAV_CMD_REQUEST_AUTOPILOT_CAPABILITIES))

    def test_invalid_signature_short_log_disconnect_and_timeout_do_not_publish(self):
        for fault in ('invalid_signature', 'short', 'disconnect', 'timeout'):
            with self.subTest(fault=fault):
                vehicle = WireVehicle(payload=b'Not ULog' + b'x'*200 if fault == 'invalid_signature' else PAYLOAD, fault=fault)
                with self.assertRaises((usb.CollectionError, usb.serial.SerialException)):
                    self.collect(vehicle)
                self.assertFalse(list(Path(self.temp.name).rglob('*.ulg')))
                self.assertFalse(list(Path(self.temp.name).rglob('*.part')))
                self.assertTrue(vehicle.closed)
                self.assertEqual(vehicle.commands[-1].get_type(), 'LOG_REQUEST_END')

    def test_existing_unverified_file_and_symlink_are_preserved(self):
        vehicle = WireVehicle()
        target = usb.target_for(self.temp.name, UID, self.entry(vehicle))
        target.write_bytes(b'keep me')
        with self.assertRaisesRegex(usb.CollectionError, 'conservé'):
            self.collect(vehicle)
        self.assertEqual(target.read_bytes(), b'keep me')
        target.unlink()
        target.symlink_to(Path(self.temp.name) / 'elsewhere')
        with self.assertRaisesRegex(usb.CollectionError, 'lien symbolique'):
            self.collect(WireVehicle())
        self.assertTrue(target.is_symlink())

    def test_cache_requires_matching_hash_and_revalidates_vehicle(self):
        target = self.collect(WireVehicle())
        cached = WireVehicle()
        self.collect(cached)
        self.assertEqual(cached.request_count, 0)
        self.assertTrue(self.events()[-1]['cached'])
        target.write_bytes(usb.MAGIC + b'x' * (len(PAYLOAD)-7))
        with self.assertRaisesRegex(usb.CollectionError, 'conservé'):
            self.collect(WireVehicle())

    def test_identity_changed_after_data_with_same_system_and_log_is_not_published(self):
        vehicle = WireVehicle(fault='switched_after_data')
        with self.assertRaisesRegex(usb.CollectionError, 'identité USB a changé'):
            self.collect(vehicle)
        self.assertGreater(vehicle.request_count, 0)
        self.assertFalse(list(Path(self.temp.name).rglob('*.ulg')))
        self.assertFalse(list(Path(self.temp.name).rglob('*.part')))
        self.assertFalse(any(item['event'] == 'downloaded' for item in self.events()))
        self.assertTrue(vehicle.closed)
        self.assertEqual(vehicle.commands[-1].get_type(), 'LOG_REQUEST_END')

    def test_insufficient_disk_space_fails_before_data_requests(self):
        vehicle = WireVehicle()
        with patch.object(usb, 'require_download_space', side_effect=usb.CollectionError('Espace disque insuffisant')):
            with self.assertRaisesRegex(usb.CollectionError, 'Espace disque'):
                self.collect(vehicle)
        self.assertEqual(vehicle.request_count, 0)
        self.assertFalse(list(Path(self.temp.name).rglob('*.part')))

    def test_cancel_closes_port_and_ends_log_session(self):
        vehicle = WireVehicle()
        with self.assertRaises(usb.Cancelled), usb.USBSession(vehicle) as session:
            session.inventory()
            usb.cancelled(signal.SIGTERM, None)
        self.assertEqual(vehicle.commands[-1].get_type(), 'LOG_REQUEST_END')
        self.assertTrue(vehicle.closed)

    def test_stale_heartbeat_blocks_requests(self):
        vehicle = WireVehicle()
        with usb.USBSession(vehicle) as session:
            session.last_heartbeat -= usb.HEARTBEAT_TIMEOUT + 1
            with self.assertRaisesRegex(usb.CollectionError, 'désarmé récent'):
                session.inventory()
        self.assertFalse(any(m.get_type() == 'LOG_REQUEST_LIST' for m in vehicle.commands))

    def test_cli_json_contract_and_port_listing_does_not_open_devices(self):
        with patch.object(usb, 'ports', return_value=[{'path': '/dev/cu.usbmodem1', 'label': 'Fixture'}]), patch.object(usb, 'open_serial') as opener:
            self.assertEqual(usb.main(['ports']), 0)
            opener.assert_not_called()
        with patch.object(usb, 'open_serial', return_value=WireVehicle()):
            self.assertEqual(usb.main(['inventory', '--device', '/dev/cu.usbmodem1']), 0)
        self.assertEqual(self.events()[0]['event'], 'ports')
        self.assertEqual(self.events()[1]['event'], 'usb_inventory')
        self.assertEqual(self.events()[1]['device']['identity'], UID)

    def test_actual_pyserial_roundtrip_on_pseudo_terminal(self):
        import pty
        import select
        master, slave = pty.openpty()
        link = usb.serial.Serial(os.ttyname(slave), 115200, timeout=0.01, write_timeout=1)
        vehicle = WireVehicle()
        stop = threading.Event()
        errors = []

        def autopilot():
            try:
                while not stop.is_set():
                    if select.select([master], [], [], 0.01)[0]:
                        vehicle.write(os.read(master, 4096))
                    if vehicle.in_waiting:
                        os.write(master, vehicle.read(vehicle.in_waiting))
            except OSError as error:
                if not stop.is_set():
                    errors.append(error)

        thread = threading.Thread(target=autopilot, daemon=True)
        thread.start()
        try:
            with usb.USBSession(link) as session:
                usb.download(session, UID, self.entry(vehicle), self.temp.name)
            self.assertEqual(next(Path(self.temp.name).rglob('*.ulg')).read_bytes(), PAYLOAD)
            self.assertFalse(errors)
        finally:
            stop.set()
            thread.join(timeout=2)
            link.close()
            os.close(master)
            os.close(slave)

    def test_bench_port_is_opt_in_and_only_accepts_exact_local_character_device(self):
        import pty
        master, slave = pty.openpty()
        name = os.ttyname(slave)
        try:
            with patch.dict(os.environ, {'KATALOG_USB_BENCH_PORT': ''}):
                self.assertIsNone(usb.bench_port())
                with self.assertRaises(usb.CollectionError):
                    usb.open_serial(name, 115200)
            with patch.dict(os.environ, {'KATALOG_USB_BENCH_PORT': name}):
                self.assertEqual(usb.bench_port(), name)
                link = usb.open_serial(name, 115200)
                link.close()
                self.assertTrue(any(p['path'] == name and 'simulé' in p['label'] for p in usb.ports()))
            for value in ('/tmp/fake-port', '/dev/null', '/dev/../dev/ttys000', 'tcp:127.0.0.1:5760'):
                with patch.dict(os.environ, {'KATALOG_USB_BENCH_PORT': value}):
                    self.assertIsNone(usb.bench_port())
        finally:
            os.close(master); os.close(slave)


class PX4ProtocolVehicle(WireVehicle):
    """PX4 AUTO framing: v1 boot; v2 only after a v2 packet is received.

    A real v10 dialect is necessary: v20.pack(force_mavlink1=True) still emits
    extension bytes, incorrectly hiding the uid -> uid2 transition in tests.
    """
    def __init__(self, initially_v1=True, advertise_v2=True, accept_v2=True, change_uid=False):
        self.v1 = initially_v1
        self.advertise_v2 = advertise_v2
        self.accept_v2 = accept_v2
        self.change_uid = change_uid
        super().__init__()

    def emit_heartbeat(self):
        self.emit(mav.MAVLink_heartbeat_message(mav.MAV_TYPE_SURFACE_BOAT, mav.MAV_AUTOPILOT_PX4,
                  0, 0, 3, 3), force_v1=self.v1)

    def write(self, data):
        if data[0] == 0xfd and self.accept_v2:
            self.v1 = False
        return super().write(data)

    def version(self):
        capabilities = mav.MAV_PROTOCOL_CAPABILITY_MAVLINK2 if self.advertise_v2 else 0
        uid = 456 if self.change_uid and not self.v1 else 123
        args = (capabilities, 0, 0, 0, 0, [0]*8, [0]*8, [0]*8, 0, 0, uid)
        if self.v1:
            message = legacy_mav.MAVLink_autopilot_version_message(*args)
            self.incoming.extend(message.pack(legacy_mav.MAVLink(None, srcSystem=42, srcComponent=1)))
        else:
            self.emit(mav.MAVLink_autopilot_version_message(*args, list(range(1, 19))))


if __name__ == '__main__':
    unittest.main()
