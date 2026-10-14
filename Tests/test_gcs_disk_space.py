"""Disk admission uses the destination volume, without contacting real hardware."""

import contextlib
import errno
import hashlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from test_gcs_collect import BODY, REMOTE, STAGING, UUID, Simulator, gcs


class DiskSpaceTests(unittest.TestCase):
    @staticmethod
    def capacity(free):
        return patch.object(gcs.shutil, "disk_usage", return_value=SimpleNamespace(free=free))

    @staticmethod
    def collect(sim, directory, *, reserved_bytes=0):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            gcs.download("127.0.0.1", sim.port, sim.http_port, UUID, REMOTE, len(BODY), directory,
                         reserved_bytes=reserved_bytes)
        return [json.loads(line) for line in output.getvalue().splitlines()]

    @staticmethod
    def resume(directory, *, prefix=137, host="gcs.local", port=1999, http_port=8080):
        target = gcs.local_target(directory, UUID, REMOTE)
        part = target.with_name(target.name + "." + "a" * 32 + ".part")
        part.write_bytes(BODY[:prefix])
        metadata = part.stat()
        record = {"version": 1, "source": {"host": host, "port": port, "httpPort": http_port,
                  "uuid": UUID, "path": REMOTE, "size": len(BODY)}, "staging": STAGING,
                  "part": part.name, "device": metadata.st_dev, "inode": metadata.st_ino,
                  "bytes": prefix, "sha256": hashlib.sha256(BODY[:prefix]).hexdigest(),
                  "etag": '"synthetic-v1"'}
        journal = target.with_name(target.name + ".katalog.resume.json")
        journal.write_text(json.dumps(record))
        return target, part, journal, record

    def test_insufficient_space_refuses_before_any_network(self):
        with tempfile.TemporaryDirectory() as directory, self.capacity(1), \
                patch.object(gcs, "verify_remote_size") as verify, patch.object(gcs, "request_staging") as staging:
            with self.assertRaisesRegex(gcs.InsufficientDiskSpace, "Espace disque insuffisant") as caught:
                gcs.download("gcs.local", 1999, 8080, UUID, REMOTE, len(BODY), directory)
            self.assertFalse(gcs.retryable_error(caught.exception))
            verify.assert_not_called()
            staging.assert_not_called()
            self.assertEqual(list(Path(directory).rglob("*.part")), [])

    def test_capacity_boundary_includes_other_transfers_and_checks_target_volume(self):
        reserved = 5_000
        required = len(BODY) + reserved + gcs.DOWNLOAD_SPACE_RESERVE
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            with self.capacity(required - 1):
                with self.assertRaises(gcs.InsufficientDiskSpace):
                    self.collect(sim, directory, reserved_bytes=reserved)
            self.assertEqual(sim.requests, [])
            with self.capacity(required) as usage:
                events = self.collect(sim, directory, reserved_bytes=reserved)
            self.assertFalse(events[-1]["cached"])
            destination = Path(events[-1]["localPath"]).parent
            self.assertTrue(all(call.args == (destination,) for call in usage.call_args_list))

    def test_verified_cache_is_available_even_with_no_free_space(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            first = self.collect(sim, directory)
            requests = list(sim.requests)
            with patch.object(gcs.shutil, "disk_usage", side_effect=AssertionError("Cache needs no new copy")):
                cached = self.collect(sim, directory, reserved_bytes=10_000)
            self.assertTrue(cached[-1]["cached"])
            self.assertEqual(cached[-1]["sha256"], first[-1]["sha256"])
            self.assertEqual(sim.requests, requests)

    def test_verified_partial_credit_is_used_and_low_space_preserves_it(self):
        with tempfile.TemporaryDirectory() as directory:
            target, part, journal, record = self.resume(directory)
            before = (part.read_bytes(), journal.read_bytes())
            required = len(BODY) - record["bytes"] + gcs.DOWNLOAD_SPACE_RESERVE
            with self.capacity(required - 1), patch.object(gcs, "verify_remote_size") as verify:
                with self.assertRaises(gcs.InsufficientDiskSpace):
                    gcs.download("gcs.local", 1999, 8080, UUID, REMOTE, len(BODY), directory)
            verify.assert_not_called()
            self.assertEqual((part.read_bytes(), journal.read_bytes()), before)
            with self.capacity(required):
                gcs.require_download_space(target, len(BODY), part=part, resume=record)

    def test_sparse_prefix_does_not_reduce_required_disk_space(self):
        with tempfile.TemporaryDirectory() as directory:
            target, part, _, record = self.resume(directory)
            metadata = SimpleNamespace(st_size=record["bytes"], st_blocks=0)
            with patch.object(gcs, "require_local_data", return_value=metadata), \
                    patch.object(gcs, "same_file_identity", return_value=True), \
                    self.capacity(len(BODY) - record["bytes"] + gcs.DOWNLOAD_SPACE_RESERVE):
                with self.assertRaises(gcs.InsufficientDiskSpace):
                    gcs.require_download_space(target, len(BODY), part=part, resume=record)

    def test_verified_partial_finishes_with_capacity_for_remaining_bytes_only(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            target, _, journal, record = self.resume(directory, host="127.0.0.1", port=sim.port, http_port=sim.http_port)
            def writer(handler):
                offset = record["bytes"]
                self.assertEqual(handler.headers.get("Range"), f"bytes={offset}-")
                handler.send_response(206)
                handler.send_header("ETag", record["etag"])
                handler.send_header("Content-Length", str(len(BODY) - offset))
                handler.send_header("Content-Range", f"bytes {offset}-{len(BODY) - 1}/{len(BODY)}")
                handler.end_headers()
                handler.wfile.write(BODY[offset:])
            sim.http_writer = writer
            with self.capacity(len(BODY) - record["bytes"] + gcs.DOWNLOAD_SPACE_RESERVE):
                events = self.collect(sim, directory)
            self.assertEqual(events[-1]["event"], "downloaded")
            self.assertEqual(target.read_bytes(), BODY)
            self.assertFalse(journal.exists())
            self.assertFalse(any(topic == "recv_mqtt_ftp_download_request" for topic, _ in sim.requests))

    def test_space_lost_during_ftp_refuses_http(self):
        required = len(BODY) + gcs.DOWNLOAD_SPACE_RESERVE
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            def copy_requested(*args):
                sim.free = 0
                return STAGING
            sim.free = required
            with patch.object(gcs.shutil, "disk_usage", side_effect=lambda path: SimpleNamespace(free=sim.free)), \
                    patch.object(gcs, "request_staging", side_effect=copy_requested), \
                    patch.object(gcs, "copy_http") as copy:
                with self.assertRaises(gcs.InsufficientDiskSpace):
                    self.collect(sim, directory)
            copy.assert_not_called()
            self.assertEqual(sim.http_requests, [])

    def test_late_enospc_and_quota_errors_preserve_verified_resume_and_do_not_retry(self):
        for code in (errno.ENOSPC, errno.EDQUOT):
            with self.subTest(errno=code), tempfile.TemporaryDirectory() as directory:
                _, part, journal, _ = self.resume(directory)
                before = (part.read_bytes(), journal.read_bytes())
                with patch.object(gcs, "verify_remote_size"), patch.object(gcs, "copy_http", side_effect=OSError(code, "full")), \
                        contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(gcs.InsufficientDiskSpace, "plus assez d’espace") as caught:
                        gcs.download("gcs.local", 1999, 8080, UUID, REMOTE, len(BODY), directory)
                self.assertFalse(gcs.retryable_error(caught.exception))
                self.assertEqual((part.read_bytes(), journal.read_bytes()), before)

    def test_invalid_reserved_budget_is_rejected_before_network(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(gcs, "verify_remote_size") as verify:
            for value in (-1, True, "10", gcs.MAX_LOG_BYTES * gcs.MAX_FILES + 1):
                with self.subTest(value=value), self.assertRaisesRegex(gcs.CollectionError, "Budget"):
                    gcs.download("gcs.local", 1999, 8080, UUID, REMOTE, len(BODY), directory, reserved_bytes=value)
            verify.assert_not_called()

    def test_cli_disk_failure_is_permanent_and_readable(self):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory, self.capacity(0), contextlib.redirect_stdout(output):
            result = gcs.main(["download", "--host", "gcs.local", "--uuid", UUID, "--remote", REMOTE,
                               "--size", str(len(BODY)), "--destination", directory, "--reserved-bytes", "123"])
        self.assertEqual(result, 1)
        event = json.loads(output.getvalue())
        self.assertEqual(event["event"], "error")
        self.assertFalse(event["retryable"])
        self.assertIn("Espace disque insuffisant", event["message"])


if __name__ == "__main__":
    unittest.main()
