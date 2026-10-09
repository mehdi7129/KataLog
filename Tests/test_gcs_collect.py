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
        if sim.http_writer is not None:
            sim.http_writer(self)
            return
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
        self.http_writer = None
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


class LocalCloudCacheTests(unittest.TestCase):
    @staticmethod
    @contextlib.contextmanager
    def dataless(paths):
        """Simulate filesystem metadata; bytes on disk remain available to prove preservation."""
        original = Path.stat

        def flagged(path, *args, **kwargs):
            result = original(path, *args, **kwargs)
            if path not in paths:
                return result

            class CloudStat:
                st_flags = 0x40000060

                def __getattr__(self, name):
                    return getattr(result, name)

            return CloudStat()

        with patch.object(Path, "stat", flagged):
            yield

    def cache(self, folder):
        target = gcs.local_target(folder, UUID, REMOTE)
        target.write_bytes(BODY)
        source = {"uuid": UUID, "path": REMOTE, "size": len(BODY)}
        manifest = target.with_name(target.name + ".katalog.json")
        manifest.write_text(json.dumps({"source": source, "sha256": hashlib.sha256(BODY).hexdigest()}))
        return target, manifest, source

    def test_cloud_original_or_manifest_blocks_download_before_open_and_network(self):
        for which in ("original", "manifest"):
            with self.subTest(which=which), tempfile.TemporaryDirectory() as folder:
                target, manifest, _ = self.cache(folder)
                before = {path: path.read_bytes() for path in (target, manifest)}
                cloud = target if which == "original" else manifest
                output = io.StringIO()
                with self.dataless({cloud}), contextlib.redirect_stdout(output), \
                     patch.object(gcs.os, "open", side_effect=AssertionError("Must not open cloud data")), \
                     patch.object(gcs, "MQTT") as mqtt, patch.object(gcs, "verify_remote_size") as listing:
                    with self.assertRaisesRegex(gcs.CollectionError, "Finder") as caught:
                        gcs.download("gcs.local", 1999, 8080, UUID, REMOTE, len(BODY), folder)
                    self.assertFalse(gcs.retryable_error(caught.exception))
                    self.assertIn(str(cloud), str(caught.exception))
                    mqtt.assert_not_called(); listing.assert_not_called()
                self.assertEqual(output.getvalue(), "")
                self.assertEqual({path: path.read_bytes() for path in before}, before)
                self.assertEqual(set(target.parent.iterdir()), set(before))

    def test_inventory_cloud_manifest_is_an_error_not_a_cache_miss(self):
        with tempfile.TemporaryDirectory() as folder:
            target, manifest, _ = self.cache(folder)
            before = manifest.read_bytes()
            with self.dataless({manifest}), \
                 patch.object(gcs.os, "open", side_effect=AssertionError("Must not read or hydrate the cache")), \
                 patch.object(gcs, "list_directory", return_value=([], [{"path": REMOTE, "size": len(BODY)}])), \
                 patch.object(gcs, "MQTT") as mqtt:
                with self.assertRaises(gcs.CloudFileUnavailable) as caught:
                    gcs.inventory("gcs.local", 1999, UUID, folder)
                self.assertFalse(caught.exception.retryable)
                mqtt.assert_not_called()
            self.assertEqual(manifest.read_bytes(), before)
            self.assertEqual(target.read_bytes(), BODY)

    def test_hash_rechecks_original_after_manifest_read(self):
        with tempfile.TemporaryDirectory() as folder:
            target, manifest, source = self.cache(folder)
            cloud = set()
            original_match = gcs.record_matches_source
            original_open = gcs.os.open

            def evict_after_proof(record, expected):
                cloud.add(target)
                return original_match(record, expected)

            def opening(path, *args, **kwargs):
                self.assertNotEqual(Path(path), target, "The newly evicted ULog must not be opened")
                return original_open(path, *args, **kwargs)

            with self.dataless(cloud), patch.object(gcs, "record_matches_source", evict_after_proof), \
                 patch.object(gcs.os, "open", opening):
                with self.assertRaises(gcs.CloudFileUnavailable):
                    gcs.cache_record(target, source)
            self.assertEqual(target.read_bytes(), BODY)
            self.assertIsNotNone(gcs.cache_record(target, source), "After hydration the same cache is reusable")

    def test_pending_recovery_preserves_cloud_marker_original_and_part_without_network(self):
        for which in ("pending", "part", "original", "manifest"):
            with self.subTest(which=which), tempfile.TemporaryDirectory() as folder:
                target = gcs.local_target(folder, UUID, REMOTE)
                part = target.with_name(target.name + "." + "a" * 32 + ".part")
                part.write_bytes(BODY)
                metadata = part.stat()
                source = {"uuid": UUID, "path": REMOTE, "size": len(BODY)}
                record = {"source": source, "sha256": hashlib.sha256(BODY).hexdigest(),
                          "transaction": {"part": part.name, "device": metadata.st_dev, "inode": metadata.st_ino}}
                pending = target.with_name(target.name + ".katalog.pending.json")
                pending.write_text(json.dumps(record))
                cloud = pending if which == "pending" else part
                if which == "original":
                    gcs.os.link(part, target); cloud = target
                if which == "manifest":
                    cloud = target.with_name(target.name + ".katalog.json")
                    cloud.write_text(json.dumps(record))
                before = {path: path.read_bytes() for path in target.parent.iterdir()}
                original_open = gcs.os.open

                def opening(path, *args, **kwargs):
                    self.assertNotEqual(Path(path), cloud, "Recovery must not hydrate a placeholder")
                    return original_open(path, *args, **kwargs)

                with self.dataless({cloud}), patch.object(gcs.os, "open", opening), \
                     patch.object(gcs.os, "link", side_effect=AssertionError("No promotion before verification")), \
                     patch.object(gcs, "MQTT") as mqtt:
                    with self.assertRaises(gcs.CloudFileUnavailable) as caught:
                        gcs.download("gcs.local", 1999, 8080, UUID, REMOTE, len(BODY), folder)
                    self.assertFalse(caught.exception.retryable)
                    mqtt.assert_not_called()
                self.assertEqual({path: path.read_bytes() for path in target.parent.iterdir()}, before)


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
            phases = [event["phase"] for event in events if event["event"] == "phase"]
            self.assertEqual(phases, ["http", "verification"])
            http_start = next(event for event in events if event["event"] == "phase" and event["phase"] == "http")
            self.assertEqual(http_start["bytes"], 0)
            self.assertEqual(http_start["total"], len(BODY))
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

    def test_cloud_eviction_before_promotion_keeps_part_and_proof_for_local_recovery(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            target = gcs.local_target(directory, UUID, REMOTE)
            pending = target.with_name(target.name + ".katalog.pending.json")
            # The newly written marker becomes cloud-only just before promotion.
            with LocalCloudCacheTests.dataless({pending}), self.assertRaises(gcs.CloudFileUnavailable) as caught:
                self.collect(sim, directory)
            self.assertFalse(gcs.retryable_error(caught.exception))
            self.assertFalse(target.exists())
            self.assertTrue(pending.exists(), "Keep ownership proof after a cloud availability error")
            proof = json.loads(pending.read_text())
            part = target.with_name(proof["transaction"]["part"])
            self.assertEqual(part.read_bytes(), BODY, "Keep the completed copy rather than downloading it again")
            before = len(sim.requests)
            # Hydration is represented by removing only the mocked dataless flag.
            recovered = self.collect(sim, directory)[-1]
            self.assertTrue(recovered["cached"])
            self.assertEqual(len(sim.requests), before)
            self.assertEqual(target.read_bytes(), BODY)
            self.assertFalse(pending.exists())
            self.assertFalse(part.exists())

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
        def interrupted(host, port, staging, part, size, callback, **unused):
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


class InventoryPaginationTests(unittest.TestCase):
    def capture(self, files):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            gcs.emit_inventory_pages(UUID, files)
        lines = output.getvalue().splitlines(keepends=True)
        return lines, [json.loads(line) for line in lines]

    def test_empty_inventory_has_explicit_start_and_finish(self):
        lines, events = self.capture([])
        self.assertEqual([event['event'] for event in events], ['inventory_started', 'inventory_finished'])
        self.assertEqual(events[-1]['totalFiles'], 0)
        self.assertEqual(events[-1]['pageCount'], 0)
        self.assertEqual(events[0]['inventoryID'], events[-1]['inventoryID'])

    def test_large_unicode_inventory_exceeds_old_monolithic_limit_but_frames_stay_bounded(self):
        files = [dict(path=f'{gcs.LOG_ROOT}/2026-09-01/{index:06d}_é.ulg', size=64,
                      localPath='/private/tmp/' + 'é' * 100, isDownloaded=True, sha256='a' * 64)
                 for index in range(20_000)]
        self.assertGreater(len(json.dumps(files, ensure_ascii=False).encode('utf8')), 4 * 1024 * 1024)
        lines, events = self.capture(files)
        self.assertTrue(all(len(line.encode('utf8')) <= gcs.MAX_INVENTORY_FRAME_BYTES for line in lines))
        pages = [event for event in events if event['event'] == 'inventory_page']
        self.assertEqual([event['pageIndex'] for event in pages], list(range(len(pages))))
        self.assertTrue(all(0 < len(page['files']) <= 256 for page in pages))
        self.assertEqual([item for page in pages for item in page['files']], files)
        self.assertEqual(events[-1]['totalFiles'], len(files))
        self.assertEqual(events[-1]['pageCount'], len(pages))
        self.assertEqual(len({event['inventoryID'] for event in events}), 1)

    def test_single_oversized_inventory_entry_fails_without_success_terminal(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(gcs.CollectionError):
            gcs.emit_inventory_pages(UUID, [dict(path='é' * gcs.MAX_INVENTORY_FRAME_BYTES, size=64)])
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertFalse(any(event['event'] == 'inventory_finished' for event in events))

    def test_page_byte_limit_applies_before_item_count_limit(self):
        files = [dict(path=f'{gcs.LOG_ROOT}/{index}.ulg', size=64, localPath='/private/tmp/' + 'é' * 2_000)
                 for index in range(180)]
        lines, events = self.capture(files)
        pages = [event for event in events if event['event'] == 'inventory_page']
        self.assertGreater(len(pages), 1)
        self.assertTrue(all(len(page['files']) < 256 for page in pages))
        self.assertTrue(all(len(line.encode('utf8')) <= gcs.MAX_INVENTORY_FRAME_BYTES for line in lines))
        self.assertEqual(sum(len(page['files']) for page in pages), len(files))

    def test_inventory_reports_cache_coverage_without_creating_destination_files(self):
        with tempfile.TemporaryDirectory() as folder:
            reports = []
            with patch.object(gcs, 'list_directory', return_value=([], [dict(path=REMOTE, size=len(BODY))])):
                files = gcs.inventory('gcs.local', 1999, UUID, folder,
                                      report=lambda phase, count, total: reports.append((phase, count, total)))
            self.assertFalse(files[0]['isDownloaded'])
            self.assertIn(('inventory', 1, None), reports)
            self.assertIn(('cache', 1, 1), reports)
            self.assertEqual(list(Path(folder).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
