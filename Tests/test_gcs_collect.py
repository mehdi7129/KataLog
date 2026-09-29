"""Local MQTT/HTTP simulator tests. No drone or external broker is contacted."""

import contextlib
from concurrent.futures import ThreadPoolExecutor
import errno
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
from pathlib import Path
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError


SCRIPT = Path(__file__).resolve().parents[1] / "Sources/KataLog/Resources/gcs_collect.py"
SPEC = importlib.util.spec_from_file_location("gcs_collect", SCRIPT)
gcs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gcs)
UUID = "0102030405060708090A0B0C"
OTHER = "1112131415161718191A1B1C"
REMOTE = "/fs/microsd/log/2026-09-01/12_00_00.ulg"
BODY = gcs.MAGIC + b"\x01" + b"\x00" * 8 + b"ulog test data" * 100
STAGING = "/home/root/backend_pyc/../public/downloads/" + UUID + "_12_00_00.ulg"


def recv_exact(sock, length):
    result = b""
    while len(result) < length:
        chunk = sock.recv(length - len(result))
        if not chunk:
            raise EOFError
        result += chunk
    return result


def read_packet(sock):
    kind = recv_exact(sock, 1)[0]
    size, multiplier = 0, 1
    for _ in range(4):
        value = recv_exact(sock, 1)[0]
        size += (value & 127) * multiplier
        if not value & 128:
            return kind, recv_exact(sock, size)
        multiplier *= 128
    raise ValueError("length")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class BrokerHandler(socketserver.BaseRequestHandler):
    def handle(self):
        sim = self.server.sim
        self.request.settimeout(5)

        def send(kind, payload):
            packet = gcs.mqtt_packet(kind, payload)
            if sim.fragment:
                for i in range(0, len(packet), 3):
                    self.request.sendall(packet[i:i + 3])
            else:
                self.request.sendall(packet)

        def publish(topic, value, retained=False):
            send(0x31 if retained else 0x30, gcs.mqtt_string(gcs.PREFIX + topic) + json.dumps(value).encode())

        try:
            kind, body = read_packet(self.request)
            if kind != 0x10:
                return
            sim.client_ids.append(body[-28:])
            send(0x20, b"\x00\x00")
            while True:
                kind, body = read_packet(self.request)
                if kind == 0x82:
                    topics, offset = [], 2
                    while offset < len(body):
                        count = struct.unpack("!H", body[offset:offset + 2])[0]
                        topics.append(body[offset + 2:offset + 2 + count].decode())
                        offset += count + 3
                    send(0x90, body[:2] + bytes([0x80 if sim.reject_subscription else 0] * len(topics)))
                    sim.subscribed.set()
                    if sim.reject_subscription:
                        return
                    publish("send_mqtt_drone_status_list", {"drone_status_list": [{"uuid": OTHER}]}, retained=True)
                    if gcs.PREFIX + "send_mqtt_drone_status_list" in topics and sim.discovery:
                        publish("send_mqtt_drone_status_list", {"drone_status_list": [
                            {"uuid": UUID, "battery_status": 0.98, "rssi_wifi": -43, "arming_state": 1},
                            {"uuid": "0" * 24}, {"uuid": "not-a-drone"}]})
                    if sim.discovery_end and gcs.PREFIX + "send_mqtt_ftp_end_session" in topics:
                        publish("send_mqtt_ftp_end_session", {"uuid": OTHER, "opcode": 2, "filename": "stale.ulg", "ret_code": 0}, retained=True)
                        publish("send_mqtt_ftp_end_session", {"uuid": UUID, "opcode": 1, "filename": STAGING, "ret_code": 0})
                        publish("send_mqtt_ftp_end_session", {"uuid": UUID, "opcode": 2, "filename": STAGING, "ret_code": 0})
                elif kind == 0x30:
                    count = struct.unpack("!H", body[:2])[0]
                    topic = body[2:2 + count].decode().removeprefix(gcs.PREFIX)
                    data = json.loads(body[2 + count:])
                    identity = data["uuid"]
                    wrong_identity = OTHER if identity == UUID else UUID
                    staging = STAGING.replace(UUID, identity)
                    sim.requests.append((topic, data))
                    if sim.silent:
                        continue
                    if topic == "recv_mqtt_ftp_list_request":
                        parent = data["path"]
                        sim.listings += 1
                        if parent == gcs.LOG_ROOT:
                            listing = {"uuid": identity, "directories": ["2026-09-01"], "files": []}
                        else:
                            size = len(BODY) + (1 if sim.grow and sim.listings > 1 else 0)
                            listing = {"uuid": identity, "directories": [], "files": [["12_00_00.ulg", size], ["ignore.txt", 42]]}
                        if sim.traversal:
                            listing["directories"] = ["../escape"]
                        if sim.raw:
                            entries = ["D" + d for d in listing["directories"]]
                            entries += ["F%s\t%s" % tuple(f) for f in listing["files"]]
                            publish("send_mqtt_ftp_list", {"uuid": identity, "payload": "\n".join(entries)})
                            publish("send_mqtt_ftp_end_session", {"uuid": identity, "opcode": 0, "filename": parent, "ret_code": 0})
                        else:
                            publish("ftp_list_dir", {"uuid": wrong_identity, "directories": ["wrong-drone"], "files": []})
                            publish("ftp_list_dir", listing, retained=True)
                            publish("ftp_list_dir", listing)
                    elif topic == "get_downlad_path":
                        publish("download_path", {"uuid": identity, "dist_file": "/fs/microsd/log/wrong.ulg", "local_file": "bad"})
                        publish("download_path", {"uuid": identity, "dist_file": REMOTE, "local_file": staging})
                    elif topic == "recv_mqtt_ftp_download_request":
                        publish("send_mqtt_ftp_end_session", {"uuid": identity, "opcode": 1, "filename": staging, "ret_code": 3})
                        publish("send_mqtt_ftp_end_session", {"uuid": wrong_identity, "opcode": 2, "filename": staging, "ret_code": 3})
                        publish("send_mqtt_ftp_end_session", {"uuid": identity, "opcode": 2, "filename": "wrong", "ret_code": 3})
                        publish("send_mqtt_ftp_end_session", {"uuid": identity, "opcode": 2, "filename": staging, "ret_code": 0}, retained=True)
                        publish("send_mqtt_ftp_transfer_status", {"uuid": identity, "opcode": 2, "filename": REMOTE, "bytes_xfer": len(BODY), "bytes_total": len(BODY)})
                        publish("send_mqtt_ftp_end_session", {"uuid": identity, "opcode": 2, "filename": staging, "ret_code": sim.transfer_error})
                elif kind == 0xC0:
                    send(0xD0, b"")
                elif kind == 0xE0:
                    return
        except (EOFError, OSError):
            pass


class HTTPHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        sim = self.server.sim
        sim.http_requests.append(self.path)
        if sim.redirect:
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.1:1/unrelated")
            self.end_headers()
            return
        self.send_response(200)
        if sim.content_length:
            self.send_header("Content-Length", str(len(sim.http_body)))
        self.end_headers()
        try:
            self.wfile.write(sim.http_body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *unused):
        pass


class Simulator:
    def __init__(self):
        self.fragment = True
        self.reject_subscription = self.traversal = self.raw = False
        self.grow = self.silent = self.redirect = False
        self.discovery = self.content_length = True
        self.discovery_end = False
        self.transfer_error = self.listings = 0
        self.http_body = BODY
        self.requests, self.http_requests, self.client_ids = [], [], []
        self.subscribed = threading.Event()

    def __enter__(self):
        self.mqtt = Server(("127.0.0.1", 0), BrokerHandler)
        self.http = ThreadingHTTPServer(("127.0.0.1", 0), HTTPHandler)
        for server in (self.mqtt, self.http):
            server.sim = self
            threading.Thread(target=server.serve_forever, daemon=True).start()
        self.port, self.http_port = self.mqtt.server_address[1], self.http.server_address[1]
        return self

    def __exit__(self, *unused):
        for server in (self.mqtt, self.http):
            server.shutdown()
            server.server_close()


class ValidationTests(unittest.TestCase):
    def test_uuid_and_commands_are_strict(self):
        for value in (None, "", "*", "0" * 24, "F" * 24, UUID + "00"):
            with self.subTest(value=value), self.assertRaises(gcs.CollectionError):
                gcs.valid_uuid(value)
        client = object.__new__(gcs.MQTT)
        client.send = lambda *args: self.fail("No forbidden command should be sent")
        for topic in ("recv_mqtt_ftp_upload_request", "arm", "recv_mqtt_ftp_delete_request"):
            with self.assertRaises(gcs.CollectionError):
                client.publish(topic, {"uuid": UUID})
        with self.assertRaises(gcs.CollectionError):
            client.publish("recv_mqtt_ftp_list_request", {"uuid": UUID, "path": "/etc"})
        with self.assertRaises(gcs.CollectionError):
            client.publish("recv_mqtt_ftp_list_request", {"uuid": UUID, "path": gcs.LOG_ROOT, "command": "arm"})

    def test_path_traversal_rejected(self):
        for path in ("/fs/microsd/log/../keys.ulg", "/fs/microsd/logs/a.ulg", "/fs/microsd/log//a.ulg",
                     "/fs/microsd/log/a\\b.ulg", "/fs/microsd/log/%2e%2e/a.ulg", "/fs/microsd/log/./a.ulg"):
            with self.subTest(path=path), self.assertRaises(gcs.CollectionError):
                gcs.remote_path(path, file=True)
        self.assertEqual(gcs.remote_path(REMOTE, file=True), REMOTE)

    def test_dns_ipv6_and_ports(self):
        for host in ("gcs.local", "192.0.2.10", "::1", "2001:db8::1%en0"):
            self.assertEqual(gcs.valid_host(host), host)
        self.assertEqual(gcs.valid_host("[::1]"), "::1")
        for host in ("http://localhost", "gcs.local/path", "user@host", ""):
            with self.assertRaises(gcs.CollectionError):
                gcs.valid_host(host)
        for port in (0, -1, 65536):
            with self.assertRaises(gcs.CollectionError):
                gcs.valid_port(port)

    def test_bounded_packet_framing(self):
        client = object.__new__(gcs.MQTT)
        packet = gcs.mqtt_packet(0x30, b"x" * 200)
        client.buffer = bytearray()
        for byte in packet[:-1]:
            client.buffer.append(byte)
            self.assertIsNone(client._pop_packet())
        client.buffer.append(packet[-1])
        self.assertEqual(client._pop_packet(), (0x30, b"x" * 200))
        client.buffer = bytearray(b"\x30\xff\xff\xff\xff")
        with self.assertRaises(gcs.CollectionError):
            client._pop_packet()

    def test_symlink_destination_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / UUID).symlink_to(root, target_is_directory=True)
            with self.assertRaises(gcs.CollectionError):
                gcs.local_target(root, UUID, REMOTE)

    def test_retry_policy_separates_network_and_permanent_failures(self):
        transient = [TimeoutError("timeout"), ConnectionResetError(), EOFError(),
                     OSError(errno.ENETUNREACH, "network"), URLError(ConnectionRefusedError()),
                     HTTPError("http://local", 503, "busy", {}, None),
                     gcs.CollectionError("CRC", retryable=True)]
        permanent = [PermissionError("disk"), OSError(errno.ENOSPC, "full"), ValueError("invalid"),
                     HTTPError("http://local", 404, "missing", {}, None), gcs.CollectionError("wrong path"),
                     gcs.Cancelled("cancelled")]
        for error in transient:
            with self.subTest(error=repr(error)):
                self.assertTrue(gcs.retryable_error(error))
            if isinstance(error, HTTPError):
                error.close()
        for error in permanent:
            with self.subTest(error=repr(error)):
                self.assertFalse(gcs.retryable_error(error))
            if isinstance(error, HTTPError):
                error.close()


class SimulatorTests(unittest.TestCase):
    def collect(self, sim, directory):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            gcs.download("127.0.0.1", sim.port, sim.http_port, UUID, REMOTE, len(BODY), directory)
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_inventory_fragments_wrong_uuid_and_retained(self):
        with Simulator() as sim:
            result = gcs.inventory("127.0.0.1", sim.port, UUID)
            self.assertEqual(result, [{"path": REMOTE, "size": len(BODY)}])
            self.assertEqual(len(sim.requests), 2)
            self.assertEqual(len(set(sim.client_ids)), len(sim.client_ids))

    def test_inventory_raw_fallback(self):
        with Simulator() as sim:
            sim.raw = True
            self.assertEqual(gcs.inventory("127.0.0.1", sim.port, UUID), [{"path": REMOTE, "size": len(BODY)}])

    def test_inventory_rejects_traversal_and_suback_failure(self):
        with Simulator() as sim:
            sim.traversal = True
            with self.assertRaises(gcs.CollectionError):
                gcs.inventory("127.0.0.1", sim.port, UUID)
        with Simulator() as sim:
            sim.reject_subscription = True
            with self.assertRaises(gcs.CollectionError):
                gcs.MQTT("127.0.0.1", sim.port)
            self.assertEqual(sim.requests, [])

    def test_download_validates_provenance_and_cache(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            events = self.collect(sim, directory)
            end = events[-1]
            self.assertEqual(end["event"], "downloaded")
            self.assertFalse(end["cached"])
            target = Path(end["localPath"])
            self.assertEqual(target.read_bytes(), BODY)
            self.assertEqual(end["sha256"], hashlib.sha256(BODY).hexdigest())
            transfer_events = [event for event in events if event["event"].startswith("transfer_")]
            self.assertEqual([event["event"] for event in transfer_events], ["transfer_started", "transfer_finished"])
            self.assertEqual(transfer_events[0]["timeoutSeconds"], 300)
            self.assertEqual(transfer_events[1]["retCode"], 0)
            self.assertEqual(target.relative_to(Path(directory).resolve()).as_posix(), UUID + "/2026-09-01/12_00_00.ulg")
            self.assertEqual(sim.http_requests, ["/downloadFile/" + UUID + "_12_00_00.ulg"])
            before = len(sim.requests)
            cached = self.collect(sim, directory)
            self.assertTrue(cached[-1]["cached"])
            self.assertEqual(len(sim.requests), before)
            target.write_bytes(BODY[:-1] + b"X")
            with self.assertRaises(gcs.CollectionError):
                self.collect(sim, directory)
            self.assertEqual(target.read_bytes(), BODY[:-1] + b"X")

    def test_inventory_recovers_durable_cache_after_gcs_address_change(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            end = self.collect(sim, directory)[-1]
            target = Path(end["localPath"])
            record = json.loads(target.with_name(target.name + ".katalog.json").read_text())
            self.assertEqual(record["source"]["host"], "127.0.0.1")
            result = gcs.inventory("localhost", sim.port, UUID, directory)
            self.assertEqual(result, [{"path": REMOTE, "size": len(BODY), "isDownloaded": True,
                                      "localPath": str(target), "sha256": hashlib.sha256(BODY).hexdigest()}])
            # All network details may change: the local source identity and hash
            # suffice, without a queue or access to the original GCS endpoint.
            output = io.StringIO()
            before = len(sim.requests)
            with contextlib.redirect_stdout(output):
                gcs.download("new-gcs.local", 1777, 8888, UUID, REMOTE, len(BODY), directory)
            self.assertTrue(json.loads(output.getvalue())["cached"])
            self.assertEqual(before, len(sim.requests))
            self.assertEqual(json.loads(target.with_name(target.name + ".katalog.json").read_text()), record)
            target.write_bytes(BODY[:-1] + b"X")
            result = gcs.inventory("127.0.0.1", sim.port, UUID, directory)
            self.assertFalse(result[0]["isDownloaded"])
            self.assertNotIn("localPath", result[0])

    def test_parallel_distinct_uuids_keep_files_and_manifests_separate(self):
        events = []
        def capture(event, **fields):
            events.append({"event": event, **fields})
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            with patch.object(gcs, "emit", capture), ThreadPoolExecutor(max_workers=2) as workers:
                jobs = [workers.submit(gcs.download, "127.0.0.1", sim.port, sim.http_port,
                                       identity, REMOTE, len(BODY), directory) for identity in (UUID, OTHER)]
                for job in jobs:
                    job.result(timeout=5)
            completed = [event for event in events if event["event"] == "downloaded"]
            self.assertEqual({event["uuid"] for event in completed}, {UUID, OTHER})
            self.assertEqual(len({event["localPath"] for event in completed}), 2)
            for event in completed:
                target = Path(event["localPath"])
                self.assertEqual(target.read_bytes(), BODY)
                record = json.loads(target.with_name(target.name + ".katalog.json").read_text())
                self.assertEqual(record["source"]["uuid"], event["uuid"])

    def test_manifest_commit_failure_recovers_without_another_transfer(self):
        for failure in (OSError(errno.EIO, "manifest rename failed"), gcs.Cancelled("commit interrupted")):
            with self.subTest(failure=type(failure).__name__), Simulator() as sim, tempfile.TemporaryDirectory() as directory:
                with patch.object(gcs.os, "replace", side_effect=failure), self.assertRaises(type(failure)):
                    self.collect(sim, directory)
                target = Path(directory).resolve() / UUID / "2026-09-01/12_00_00.ulg"
                pending = target.with_name(target.name + ".katalog.pending.json")
                manifest = target.with_name(target.name + ".katalog.json")
                self.assertEqual(target.read_bytes(), BODY)
                self.assertTrue(pending.exists())
                self.assertFalse(manifest.exists())
                before = len(sim.requests)
                recovered = self.collect(sim, directory)[-1]
                self.assertTrue(recovered["cached"])
                self.assertEqual(before, len(sim.requests), "Recovery must not contact the drone again")
                self.assertFalse(pending.exists())
                self.assertTrue(manifest.exists())
                self.assertEqual(json.loads(manifest.read_text())["sha256"], hashlib.sha256(BODY).hexdigest())

    def test_recovery_preserves_manual_replacement_even_when_bytes_match(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            with patch.object(gcs.os, "replace", side_effect=OSError(errno.EIO, "manifest rename failed")), self.assertRaises(OSError):
                self.collect(sim, directory)
            target = Path(directory).resolve() / UUID / "2026-09-01/12_00_00.ulg"
            pending = target.with_name(target.name + ".katalog.pending.json")
            record = json.loads(pending.read_text())
            replacement = target.with_name("manual-file.ulg")
            replacement.write_bytes(BODY)
            gcs.os.replace(replacement, target)
            self.assertNotEqual(target.stat().st_ino, record["transaction"]["inode"])
            before = len(sim.requests)
            with self.assertRaisesRegex(gcs.CollectionError, "finalisation interrompue"):
                self.collect(sim, directory)
            self.assertEqual(target.read_bytes(), BODY)
            self.assertTrue(pending.exists())
            self.assertFalse(target.with_name(target.name + ".katalog.json").exists())
            self.assertEqual(before, len(sim.requests))

    def test_recovery_resumes_owned_part_before_final_link(self):
        with tempfile.TemporaryDirectory() as directory:
            target = gcs.local_target(directory, UUID, REMOTE)
            part = target.with_name(target.name + "." + "a" * 32 + ".part")
            part.write_bytes(BODY)
            stat = part.stat()
            record = {"source": {"uuid": UUID, "path": REMOTE, "size": len(BODY), "host": "old-gcs.local"},
                      "sha256": hashlib.sha256(BODY).hexdigest(),
                      "transaction": {"part": part.name, "device": stat.st_dev, "inode": stat.st_ino}}
            pending = target.with_name(target.name + ".katalog.pending.json")
            pending.write_text(json.dumps(record))
            output = io.StringIO()
            with contextlib.redirect_stdout(output), patch.object(gcs, "MQTT", side_effect=AssertionError("No network on recovery")):
                gcs.download("new-gcs.local", 1999, 8080, UUID, REMOTE, len(BODY), directory)
            self.assertTrue(json.loads(output.getvalue())["cached"])
            self.assertEqual(target.read_bytes(), BODY)
            self.assertFalse(pending.exists())
            self.assertFalse(part.exists())

    def test_existing_manual_file_without_transaction_is_never_adopted(self):
        with tempfile.TemporaryDirectory() as directory:
            target = gcs.local_target(directory, UUID, REMOTE)
            target.write_bytes(BODY)
            original_stat = target.stat()
            with patch.object(gcs, "MQTT", side_effect=AssertionError("No network for local conflict")):
                with self.assertRaisesRegex(gcs.CollectionError, "non vérifié"):
                    gcs.download("gcs.local", 1999, 8080, UUID, REMOTE, len(BODY), directory)
            self.assertEqual(target.read_bytes(), BODY)
            self.assertEqual(target.stat().st_mtime_ns, original_stat.st_mtime_ns)
            self.assertFalse(target.with_name(target.name + ".katalog.json").exists())

    def test_inventory_does_not_create_missing_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "not-created"
            with patch.object(gcs, "MQTT", side_effect=AssertionError("No network for unavailable destination")):
                with self.assertRaisesRegex(gcs.CollectionError, "Dossier de collecte indisponible"):
                    gcs.inventory("gcs.local", 1999, UUID, destination)
            self.assertFalse(destination.exists())

    def test_download_refuses_missing_or_inaccessible_destination_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "disconnected-volume" / "logs"
            with patch.object(gcs, "MQTT", side_effect=AssertionError("No network for unavailable destination")):
                with self.assertRaisesRegex(gcs.CollectionError, "Dossier de collecte indisponible") as raised:
                    gcs.download("gcs.local", 1999, 8080, UUID, REMOTE, len(BODY), missing)
                self.assertFalse(gcs.retryable_error(raised.exception))
                with patch.object(gcs.os, "access", return_value=False):
                    with self.assertRaisesRegex(gcs.CollectionError, "Accès au dossier"):
                        gcs.download("gcs.local", 1999, 8080, UUID, REMOTE, len(BODY), directory)
            self.assertFalse(missing.parent.exists())

    def test_root_disappearing_after_validation_is_not_recreated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "custom"
            root.mkdir()
            validate = gcs.validate_destination

            def disconnect(destination):
                result = validate(destination)
                root.rmdir()
                return result

            with patch.object(gcs, "validate_destination", side_effect=disconnect):
                with self.assertRaises(FileNotFoundError):
                    gcs.local_target(root, UUID, REMOTE)
            self.assertFalse(root.exists())

    def test_cache_requires_manifest_identity_and_well_formed_json(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            target = Path(self.collect(sim, directory)[-1]["localPath"])
            manifest = target.with_name(target.name + ".katalog.json")
            record = json.loads(manifest.read_text())
            source = {"uuid": UUID, "path": REMOTE, "size": len(BODY)}
            for key, wrong in (("uuid", OTHER), ("path", "/fs/microsd/log/other.ulg"), ("size", len(BODY) + 1)):
                invalid = json.loads(json.dumps(record))
                invalid["source"][key] = wrong
                manifest.write_text(json.dumps(invalid))
                self.assertIsNone(gcs.cache_record(target, source))
            for invalid in ([], {}, {"source": []}, {"source": source, "sha256": None}):
                manifest.write_text(json.dumps(invalid))
                self.assertIsNone(gcs.cache_record(target, source))

    def test_remote_growth_discards_copy(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.grow = True
            with self.assertRaisesRegex(gcs.CollectionError, "taille du log"):
                self.collect(sim, directory)
            self.assertEqual(list(Path(directory).rglob("*.ulg")), [])
            self.assertEqual(list(Path(directory).rglob("*.part")), [])

    def test_cancel_after_partial_http_cleans_temporary_file(self):
        def interrupted(host, port, staging, part, size, callback):
            part.write_bytes(BODY[:20])
            raise gcs.Cancelled("annulé")
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            with patch.object(gcs, "copy_http", interrupted), self.assertRaises(gcs.Cancelled):
                self.collect(sim, directory)
            self.assertEqual(list(Path(directory).rglob("*.part")), [])
            self.assertEqual(list(Path(directory).rglob("*.ulg")), [])

    def test_packet_survives_deadline_between_fragments(self):
        left, right = socket.socketpair()
        client = object.__new__(gcs.MQTT)
        client.sock = left
        client.buffer = bytearray()
        client.last_sent = time.monotonic()
        client.ping_sent = None
        packet = gcs.mqtt_packet(0x30, b"large fragmented payload")
        try:
            right.sendall(packet[:5])
            with self.assertRaises(TimeoutError):
                client.receive(time.monotonic() + 0.03)
            right.sendall(packet[5:])
            self.assertEqual(client.receive(time.monotonic() + 1), (0x30, b"large fragmented payload"))
        finally:
            left.close()
            right.close()

    def test_crc_failure_does_not_start_http(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.transfer_error = 1
            output = io.StringIO()
            with contextlib.redirect_stdout(output), self.assertRaisesRegex(gcs.CollectionError, "code 1") as caught:
                gcs.download("127.0.0.1", sim.port, sim.http_port, UUID, REMOTE, len(BODY), directory)
            self.assertTrue(caught.exception.retryable)
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(events[0]["event"], "transfer_started")
            self.assertEqual(events[-1]["event"], "transfer_finished")
            self.assertEqual(events[-1]["retCode"], 1)
            self.assertEqual(sim.http_requests, [])
            self.assertEqual(list(Path(directory).rglob("*.ulg")), [])

    def test_http_wrong_size_oversize_magic_and_redirect(self):
        cases = ((BODY + b"x", True, False), (BODY + b"x", False, False),
                 (BODY[:-1], False, False), (b"wrong!!" + BODY[7:], True, False), (BODY, True, True))
        for body, content_length, redirect in cases:
            with self.subTest(length=len(body), headers=content_length, redirect=redirect):
                with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
                    sim.http_body, sim.content_length, sim.redirect = body, content_length, redirect
                    with self.assertRaises(gcs.CollectionError):
                        self.collect(sim, directory)
                    self.assertEqual(list(Path(directory).rglob("*.ulg")), [])
                    self.assertEqual(list(Path(directory).rglob("*.part")), [])

    def test_discovery_and_sigterm_are_bounded(self):
        with Simulator() as sim:
            proc = subprocess.Popen([sys.executable, str(SCRIPT), "discover", "--host", "127.0.0.1", "--port", str(sim.port)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(sim.subscribed.wait(3))
                connection = json.loads(proc.stdout.readline())
                drones = json.loads(proc.stdout.readline())
                self.assertEqual(connection, {"event": "connection", "connected": True})
                self.assertEqual([d["uuid"] for d in drones["drones"]], [UUID])
                start = time.monotonic()
                proc.send_signal(signal.SIGTERM)
                stdout, stderr = proc.communicate(timeout=3)
                self.assertEqual(proc.returncode, 130)
                self.assertLess(time.monotonic() - start, 3)
                self.assertEqual(stderr, "")
                self.assertIn('"cancelled": true', stdout)
                self.assertIn('"retryable": false', stdout)
                self.assertIn('"cancellationRemoteStopped": false', stdout)
                self.assertIn('"connected": false', stdout)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()

    def test_cli_error_is_json(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "inventory", "--host", "localhost", "--uuid", ""],
                                capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["event"], "error")
        self.assertFalse(json.loads(result.stdout)["retryable"])
        self.assertEqual(result.stderr, "")

    def test_discovery_reports_only_fresh_download_terminals(self):
        events = []
        def capture(event, **fields):
            events.append({"event": event, **fields})
            if event == "transfer_end":
                raise gcs.Cancelled("test complete")
        with Simulator() as sim:
            sim.discovery_end = True
            with patch.object(gcs, "emit", capture), self.assertRaises(gcs.Cancelled):
                gcs.discover("127.0.0.1", sim.port)
        terminals = [event for event in events if event["event"] == "transfer_end"]
        self.assertEqual(terminals, [{"event": "transfer_end", "uuid": UUID, "path": STAGING, "retCode": 0}])


if __name__ == "__main__":
    unittest.main()
