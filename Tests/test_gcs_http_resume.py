"""Interrupted HTTP copies resume only with a strong, unchanged representation."""

import contextlib
import hashlib
import io
import json
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import test_gcs_collect as fixtures
from test_gcs_collect import BODY, REMOTE, SCRIPT, UUID, Simulator, gcs


class HTTPResumeTests(unittest.TestCase):
    etag = '"synthetic-log-v1"'
    prefix_size = 137

    def collect(self, sim, directory):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            gcs.download("127.0.0.1", sim.port, sim.http_port, UUID, REMOTE, len(BODY), directory)
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def paths(self, directory):
        target = Path(directory).resolve() / UUID / "2026-09-01/12_00_00.ulg"
        return target, target.with_name(target.name + ".katalog.resume.json")

    @staticmethod
    def respond(handler, *, status=200, etag=None, body=BODY, content_range=None, length=None):
        handler.send_response(status)
        if etag is not None:
            handler.send_header("ETag", etag)
        handler.send_header("Content-Length", str(len(body) if length is None else length))
        if content_range is not None:
            handler.send_header("Content-Range", content_range)
        handler.end_headers()
        handler.wfile.write(body)
        handler.wfile.flush()

    def interrupt(self, sim, directory, *, etag=None):
        def writer(handler):
            self.respond(handler, etag=self.etag if etag is None else etag,
                         body=BODY[:self.prefix_size], length=len(BODY))
            handler.connection.shutdown(socket.SHUT_RDWR)
        sim.http_writer = writer
        with self.assertRaises((gcs.CollectionError, OSError)) as caught:
            self.collect(sim, directory)
        self.assertTrue(gcs.retryable_error(caught.exception))
        target, journal = self.paths(directory)
        self.assertFalse(target.exists())
        return target, journal

    @staticmethod
    def ftp_count(sim):
        return sum(topic == "recv_mqtt_ftp_download_request" for topic, _ in sim.requests)

    def range_writer(self, calls, *, mode="range"):
        def writer(handler):
            calls.append(dict(handler.headers))
            offset = int(handler.headers["Range"].removeprefix("bytes=").removesuffix("-"))
            if mode == "ignored":
                self.respond(handler, etag=self.etag)
            else:
                self.respond(handler, status=206, etag=self.etag, body=BODY[offset:],
                             content_range=f"bytes {offset}-{len(BODY) - 1}/{len(BODY)}")
        return writer

    def assert_published(self, directory):
        target, journal = self.paths(directory)
        self.assertEqual(target.read_bytes(), BODY)
        manifest = json.loads(target.with_name(target.name + ".katalog.json").read_text())
        self.assertEqual(manifest["sha256"], hashlib.sha256(BODY).hexdigest())
        self.assertFalse(journal.exists())
        self.assertEqual(list(Path(directory).rglob("*.part")), [])

    def test_connection_drop_reuses_exact_prefix_without_second_ftp(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            _, journal = self.interrupt(sim, directory)
            record = json.loads(journal.read_text())
            self.assertEqual(record["bytes"], self.prefix_size)
            self.assertEqual(record["sha256"], hashlib.sha256(BODY[:self.prefix_size]).hexdigest())
            calls = []
            sim.http_writer = self.range_writer(calls)
            self.collect(sim, directory)
            self.assertEqual(self.ftp_count(sim), 1)
            self.assertEqual(calls[0]["Range"], f"bytes={self.prefix_size}-")
            self.assertEqual(calls[0]["If-Range"], self.etag)
            self.assert_published(directory)

    def test_server_ignoring_range_rewrites_same_representation_without_appending(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            self.interrupt(sim, directory)
            calls = []
            sim.http_writer = self.range_writer(calls, mode="ignored")
            events = self.collect(sim, directory)
            self.assertEqual(self.ftp_count(sim), 1)
            starts = [event["bytes"] for event in events if event["event"] == "phase" and event["phase"] == "http"]
            self.assertEqual(starts, [self.prefix_size, 0], "Publish the restart before HTTP progress grows again.")
            self.assert_published(directory)

    def test_five_second_http_stall_keeps_existing_connection_and_bytes(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            def writer(handler):
                self.respond(handler, etag=self.etag, body=BODY[:self.prefix_size], length=len(BODY))
                time.sleep(5)
                handler.wfile.write(BODY[self.prefix_size:])
            sim.http_writer = writer
            self.collect(sim, directory)
            self.assertEqual(self.ftp_count(sim), 1)
            self.assertEqual(len(sim.http_requests), 1)
            self.assert_published(directory)

    def test_changed_or_missing_staging_requires_fresh_ftp_before_consuming_body(self):
        for response_kind in ("changed", "weak", "missing"):
            with self.subTest(response_kind=response_kind), Simulator() as sim, tempfile.TemporaryDirectory() as directory:
                self.interrupt(sim, directory)
                requests = []
                def writer(handler):
                    requests.append(dict(handler.headers))
                    if handler.headers.get("Range"):
                        if response_kind == "missing":
                            self.respond(handler, status=404, body=b"")
                        else:
                            # A homonymous staging file must not be attributed to this log.
                            self.respond(handler, etag='W/"v1"' if response_kind == "weak" else '"v2"',
                                         body=gcs.MAGIC + b"x" * (len(BODY) - len(gcs.MAGIC)))
                    else:
                        self.assertEqual(self.ftp_count(sim), 2)
                        self.respond(handler, etag=self.etag)
                sim.http_writer = writer
                self.collect(sim, directory)
                self.assertEqual(self.ftp_count(sim), 2)
                self.assertEqual(len(requests), 2)
                self.assertNotIn("Range", requests[1])
                self.assert_published(directory)

    def test_weak_validator_never_creates_resume_proof_or_if_range(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            _, journal = self.interrupt(sim, directory, etag='W/"synthetic-log-v1"')
            self.assertFalse(journal.exists())
            self.assertEqual(list(Path(directory).rglob("*.part")), [])
            calls = []
            def writer(handler):
                calls.append(dict(handler.headers))
                self.respond(handler, etag='W/"synthetic-log-v1"')
            sim.http_writer = writer
            self.collect(sim, directory)
            self.assertEqual(self.ftp_count(sim), 2)
            self.assertNotIn("If-Range", calls[0])
            self.assert_published(directory)

    def test_wrong_content_range_never_publishes_a_combined_file(self):
        for content_range in (f"bytes 0-{len(BODY) - 1}/{len(BODY)}", "bytes 137-999/1000", None):
            with self.subTest(content_range=content_range), Simulator() as sim, tempfile.TemporaryDirectory() as directory:
                self.interrupt(sim, directory)
                sim.http_writer = lambda handler: self.respond(handler, status=206, etag=self.etag,
                    body=BODY[self.prefix_size:], content_range=content_range)
                with self.assertRaisesRegex(gcs.CollectionError, "plage HTTP"):
                    self.collect(sim, directory)
                target, journal = self.paths(directory)
                self.assertFalse(target.exists())
                self.assertFalse(journal.exists())
                self.assertEqual(self.ftp_count(sim), 1)

    def test_corrupt_proof_or_replaced_partial_is_preserved_without_network(self):
        for corruption in ("json", "contents", "inode", "symlink"):
            with self.subTest(corruption=corruption), Simulator() as sim, tempfile.TemporaryDirectory() as directory:
                _, journal = self.interrupt(sim, directory)
                record = json.loads(journal.read_text())
                part = journal.with_name(record["part"])
                if corruption == "json":
                    journal.write_text("{")
                elif corruption == "contents":
                    part.write_bytes(b"X" * self.prefix_size)
                else:
                    replacement = part.with_name("manual-file")
                    replacement.write_bytes(part.read_bytes())
                    if corruption == "inode":
                        replacement.replace(part)
                    else:
                        part.unlink()
                        part.symlink_to(replacement)
                proof_before = journal.read_bytes()
                with patch.object(gcs, "MQTT", side_effect=AssertionError("Invalid proof must not contact GCS")):
                    with self.assertRaisesRegex(gcs.CollectionError, "Preuve de reprise invalide"):
                        self.collect(sim, directory)
                self.assertEqual(journal.read_bytes(), proof_before)
                self.assertTrue(part.exists())

    def test_endpoint_change_never_reuses_other_servers_partial(self):
        with Simulator() as old, Simulator() as new, tempfile.TemporaryDirectory() as directory:
            self.interrupt(old, directory)
            headers = []
            def writer(handler):
                headers.append(dict(handler.headers))
                self.respond(handler, etag=self.etag)
            new.http_writer = writer
            self.collect(new, directory)
            self.assertEqual(self.ftp_count(new), 1)
            self.assertNotIn("Range", headers[0])
            self.assert_published(directory)

    def test_cloud_only_partial_or_journal_stops_without_hydration_or_network(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            _, journal = self.interrupt(sim, directory)
            part = journal.with_name(json.loads(journal.read_text())["part"])
            for cloud in (part, journal):
                with self.subTest(cloud=cloud.name), fixtures.LocalCloudCacheTests.dataless({cloud}), \
                     patch.object(gcs, "MQTT", side_effect=AssertionError("No network before local proof")):
                    with self.assertRaises(gcs.CloudFileUnavailable):
                        self.collect(sim, directory)
                self.assertTrue(journal.exists())
                self.assertTrue(part.exists())

    def test_replaced_broken_journal_symlink_is_never_removed(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            target, journal = self.interrupt(sim, directory)
            record = json.loads(journal.read_text())
            part = journal.with_name(record["part"])
            journal.unlink()
            journal.symlink_to(journal.with_name("unrelated-missing-file"))
            with self.assertRaises(gcs.LocalResumeConflict):
                gcs.discard_http_resume(target, record)
            self.assertTrue(journal.is_symlink())
            self.assertTrue(part.exists())

    def test_prefix_modified_after_load_is_not_adopted_by_next_checkpoint(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            _, journal = self.interrupt(sim, directory)
            load = gcs.load_http_resume
            def replaced_after_read(target, source):
                record = load(target, source)
                with target.with_name(record["part"]).open("r+b") as stream:
                    stream.seek(20)
                    stream.write(b"Z")
                return record
            sim.http_writer = self.range_writer([])
            with patch.object(gcs, "load_http_resume", replaced_after_read):
                with self.assertRaisesRegex(gcs.CollectionError, "copie partielle a changé"):
                    self.collect(sim, directory)
            self.assertFalse(self.paths(directory)[0].exists())
            self.assertTrue(journal.exists())
            self.assertTrue(journal.with_name(json.loads(journal.read_text())["part"]).exists())
            self.assertEqual(self.ftp_count(sim), 1)

    def test_cancel_around_restart_checkpoint_never_leaves_proof_longer_than_partial(self):
        for after_checkpoint in (False, True):
            with self.subTest(after_checkpoint=after_checkpoint), Simulator() as sim, tempfile.TemporaryDirectory() as directory:
                _, journal = self.interrupt(sim, directory)
                sim.http_writer = self.range_writer([], mode="ignored")
                checkpoint = gcs.checkpoint_http_resume
                def stop_at_restart(target, record, output, digest, total):
                    self.assertEqual(total, 0)
                    if after_checkpoint:
                        checkpoint(target, record, output, digest, total)
                    raise gcs.Cancelled("cancel at restart")
                with patch.object(gcs, "checkpoint_http_resume", stop_at_restart):
                    with self.assertRaises(gcs.Cancelled):
                        self.collect(sim, directory)
                record = json.loads(journal.read_text())
                part = journal.with_name(record["part"])
                self.assertLessEqual(record["bytes"], part.stat().st_size)
                calls = []
                sim.http_writer = self.range_writer(calls)
                self.collect(sim, directory)
                self.assertEqual(calls[0]["Range"], f'bytes={record["bytes"]}-')
                self.assertEqual(self.ftp_count(sim), 1)
                self.assert_published(directory)

    def test_uncheckpointed_tail_is_discarded_before_resuming_verified_prefix(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            _, journal = self.interrupt(sim, directory)
            record = json.loads(journal.read_text())
            with journal.with_name(record["part"]).open("ab") as stream:
                stream.write(b"uncommitted tail after crash")
            calls = []
            sim.http_writer = self.range_writer(calls)
            self.collect(sim, directory)
            self.assertEqual(calls[0]["Range"], f"bytes={self.prefix_size}-")
            self.assert_published(directory)

    def test_complete_partial_revalidates_last_byte_without_repeating_ftp(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = lambda handler: self.respond(handler, etag=self.etag)
            verify = gcs.verify_remote_size
            verification_count = 0
            def lost_after_copy(*args):
                nonlocal verification_count
                verification_count += 1
                if verification_count == 2:
                    raise TimeoutError("listing unavailable after HTTP copy")
                return verify(*args)
            with patch.object(gcs, "verify_remote_size", lost_after_copy):
                with self.assertRaises(TimeoutError):
                    self.collect(sim, directory)
            _, journal = self.paths(directory)
            self.assertEqual(json.loads(journal.read_text())["bytes"], len(BODY))
            calls = []
            sim.http_writer = self.range_writer(calls)
            self.collect(sim, directory)
            self.assertEqual(calls[0]["Range"], f"bytes={len(BODY) - 1}-")
            self.assertEqual(self.ftp_count(sim), 1)
            self.assert_published(directory)

    def test_final_commit_recovery_takes_over_from_http_journal(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = lambda handler: self.respond(handler, etag=self.etag)
            replace = gcs.os.replace
            def fail_manifest(source, destination):
                if str(destination).endswith(".katalog.json"):
                    raise OSError("manifest promotion interrupted")
                return replace(source, destination)
            with patch.object(gcs.os, "replace", fail_manifest):
                with self.assertRaises(OSError):
                    self.collect(sim, directory)
            target, journal = self.paths(directory)
            self.assertTrue(target.exists())
            self.assertFalse(journal.exists())
            self.assertTrue(target.with_name(target.name + ".katalog.pending.json").exists())
            events = self.collect(sim, directory)
            self.assertTrue(events[-1]["cached"])
            self.assertEqual(self.ftp_count(sim), 1)
            self.assert_published(directory)

    def test_cancel_during_pending_write_keeps_http_resume_usable(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = lambda handler: self.respond(handler, etag=self.etag)
            dump = gcs.json.dump
            def cancel_pending(record, stream, **kwargs):
                if ".katalog.pending.json." in Path(stream.name).name:
                    stream.write('{"source":')
                    raise gcs.Cancelled("stop during pending proof write")
                return dump(record, stream, **kwargs)
            with patch.object(gcs.json, "dump", cancel_pending):
                with self.assertRaises(gcs.Cancelled):
                    self.collect(sim, directory)
            target, journal = self.paths(directory)
            self.assertFalse(target.with_name(target.name + ".katalog.pending.json").exists())
            self.assertTrue(journal.exists())
            self.assertTrue(journal.with_name(json.loads(journal.read_text())["part"]).exists())
            sim.http_writer = self.range_writer([])
            self.collect(sim, directory)
            self.assertEqual(self.ftp_count(sim), 1)
            self.assert_published(directory)

    def test_interrupted_pending_open_never_exposes_an_incomplete_public_proof(self):
        for truncated in (b"", b'{"source":'):
            with self.subTest(truncated=truncated), Simulator() as sim, tempfile.TemporaryDirectory() as directory:
                sim.http_writer = lambda handler: self.respond(handler, etag=self.etag)
                original_open = Path.open
                interrupted_paths = []
                def interrupted_open(path, *args, **kwargs):
                    stream = original_open(path, *args, **kwargs)
                    if ".katalog.pending.json" in path.name and args and args[0] == "x":
                        stream.write(truncated.decode())
                        stream.close()
                        interrupted_paths.append(path)
                        # Simulate the files left by termination before the caller
                        # receives the newly opened descriptor or records its inode.
                        raise gcs.Cancelled("stop immediately after private proof creation")
                    return stream
                with patch.object(Path, "open", interrupted_open):
                    with self.assertRaises(gcs.Cancelled):
                        self.collect(sim, directory)
                target, journal = self.paths(directory)
                self.assertFalse(target.with_name(target.name + ".katalog.pending.json").exists())
                self.assertEqual(len(interrupted_paths), 1)
                self.assertEqual(interrupted_paths[0].read_bytes(), truncated)
                self.assertTrue(journal.exists())
                sim.http_writer = self.range_writer([])
                self.collect(sim, directory)
                self.assertEqual(self.ftp_count(sim), 1)
                self.assert_published(directory)

    def test_cancel_immediately_after_pending_publication_recovers_without_network(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = lambda handler: self.respond(handler, etag=self.etag)
            link = gcs.os.link
            def publish_then_cancel(source, destination):
                result = link(source, destination)
                if str(destination).endswith(".katalog.pending.json"):
                    raise gcs.Cancelled("stop immediately after complete pending publication")
                return result
            with patch.object(gcs.os, "link", publish_then_cancel):
                with self.assertRaises(gcs.Cancelled):
                    self.collect(sim, directory)
            target, journal = self.paths(directory)
            self.assertFalse(target.exists())
            self.assertTrue(journal.exists())
            pending = target.with_name(target.name + ".katalog.pending.json")
            record = json.loads(pending.read_text())
            self.assertEqual(record["sha256"], hashlib.sha256(BODY).hexdigest())
            self.assertTrue(target.with_name(record["transaction"]["part"]).exists())
            with patch.object(gcs, "MQTT", side_effect=AssertionError("No network after pending publication")):
                events = self.collect(sim, directory)
            self.assertTrue(events[-1]["cached"])
            self.assertFalse(pending.exists())
            self.assertEqual(self.ftp_count(sim), 1)
            self.assert_published(directory)

    def test_cancel_during_pending_write_preserves_foreign_public_proof(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = lambda handler: self.respond(handler, etag=self.etag)
            dump = gcs.json.dump
            replacement_contents = '{"manual": "preserve this proof"}'
            def replace_pending(record, stream, **kwargs):
                if ".katalog.pending.json." in Path(stream.name).name:
                    target, _ = self.paths(directory)
                    replacement = Path(stream.name).with_name("manual-proof.json")
                    replacement.write_text(replacement_contents)
                    replacement.replace(target.with_name(target.name + ".katalog.pending.json"))
                    raise gcs.Cancelled("stop after another writer publishes its proof")
                return dump(record, stream, **kwargs)
            with patch.object(gcs.json, "dump", replace_pending):
                with self.assertRaises(gcs.Cancelled):
                    self.collect(sim, directory)
            target, journal = self.paths(directory)
            self.assertEqual(target.with_name(target.name + ".katalog.pending.json").read_text(), replacement_contents)
            self.assertTrue(journal.exists())
            self.assertTrue(journal.with_name(json.loads(journal.read_text())["part"]).exists())

    def test_pending_publication_never_overwrites_a_foreign_proof(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = lambda handler: self.respond(handler, etag=self.etag)
            link = gcs.os.link
            foreign_contents = '{"manual": "keep this unrelated pending"}'
            def occupy_pending(source, destination):
                if str(destination).endswith(".katalog.pending.json"):
                    Path(destination).write_text(foreign_contents)
                return link(source, destination)
            with patch.object(gcs.os, "link", occupy_pending):
                with self.assertRaises(gcs.LocalResumeConflict):
                    self.collect(sim, directory)
            target, journal = self.paths(directory)
            self.assertFalse(target.exists())
            self.assertEqual(target.with_name(target.name + ".katalog.pending.json").read_text(), foreign_contents)
            self.assertTrue(journal.exists())
            self.assertTrue(journal.with_name(json.loads(journal.read_text())["part"]).exists())

    def test_commit_recovery_preserves_a_changed_http_resume_proof(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = lambda handler: self.respond(handler, etag=self.etag)
            link = gcs.os.link
            def publish_then_cancel(source, destination):
                result = link(source, destination)
                if str(destination).endswith(".katalog.pending.json"):
                    raise gcs.Cancelled("stop after pending publication")
                return result
            with patch.object(gcs.os, "link", publish_then_cancel):
                with self.assertRaises(gcs.Cancelled):
                    self.collect(sim, directory)
            target, journal = self.paths(directory)
            record = json.loads(journal.read_text())
            record["sha256"] = "0" * 64
            journal.write_text(json.dumps(record))
            before = journal.read_bytes()
            with patch.object(gcs, "MQTT", side_effect=AssertionError("No network for conflicting proof")):
                with self.assertRaises(gcs.LocalResumeConflict):
                    self.collect(sim, directory)
            self.assertEqual(journal.read_bytes(), before)
            self.assertFalse(target.exists())
            self.assertTrue(target.with_name(target.name + ".katalog.pending.json").exists())
            self.assertTrue(target.with_name(record["part"]).exists())

    def test_cancel_after_digest_update_keeps_checkpoint_hash_and_bytes_consistent(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = lambda handler: self.respond(handler, etag=self.etag)
            sha256 = hashlib.sha256
            interrupted = False
            class InterruptingDigest:
                def __init__(self, digest=None):
                    self.digest = sha256() if digest is None else digest
                def update(self, chunk):
                    nonlocal interrupted
                    self.digest.update(chunk)
                    if not interrupted:
                        interrupted = True
                        raise gcs.Cancelled("stop after digest update, before progress commit")
                def copy(self):
                    return InterruptingDigest(self.digest.copy())
                def hexdigest(self):
                    return self.digest.hexdigest()
            with patch.object(gcs.hashlib, "sha256", InterruptingDigest):
                with self.assertRaises(gcs.Cancelled):
                    self.collect(sim, directory)
            self.assertTrue(interrupted)
            _, journal = self.paths(directory)
            record = json.loads(journal.read_text())
            part = journal.with_name(record["part"])
            self.assertEqual(record["sha256"], sha256(part.read_bytes()[:record["bytes"]]).hexdigest())
            sim.http_writer = self.range_writer([])
            self.collect(sim, directory)
            self.assertEqual(self.ftp_count(sim), 1)
            self.assert_published(directory)

    def test_cancel_after_durable_commit_proof_recovers_without_any_network(self):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = lambda handler: self.respond(handler, etag=self.etag)
            link = gcs.os.link
            def cancel_promotion(source, destination):
                if str(destination).endswith(".ulg"):
                    raise gcs.Cancelled("stop just before publication")
                return link(source, destination)
            with patch.object(gcs.os, "link", cancel_promotion):
                with self.assertRaises(gcs.Cancelled):
                    self.collect(sim, directory)
            target, journal = self.paths(directory)
            self.assertFalse(target.exists())
            self.assertFalse(journal.exists())
            self.assertEqual(len(list(Path(directory).rglob("*.part"))), 1)
            self.assertTrue(target.with_name(target.name + ".katalog.pending.json").exists())
            with patch.object(gcs, "MQTT", side_effect=AssertionError("No network for final commit recovery")):
                events = self.collect(sim, directory)
            self.assertTrue(events[-1]["cached"])
            self.assertEqual(self.ftp_count(sim), 1)
            self.assert_published(directory)

    def test_sigterm_keeps_owned_partial_and_next_process_resumes(self):
        sent, release = threading.Event(), threading.Event()
        def stalled(handler):
            self.respond(handler, etag=self.etag, body=BODY[:self.prefix_size], length=len(BODY))
            sent.set()
            release.wait(4)
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = stalled
            process = subprocess.Popen([sys.executable, str(SCRIPT), "download", "--host", "127.0.0.1",
                "--port", str(sim.port), "--http-port", str(sim.http_port), "--uuid", UUID,
                "--remote", REMOTE, "--size", str(len(BODY)), "--destination", directory],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(sent.wait(3))
                # Wait for the actual progress event, not merely bytes in the socket.
                while True:
                    event = json.loads(process.stdout.readline())
                    if event.get("event") == "progress" and event.get("phase") == "http":
                        break
                process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 130, stderr)
                self.assertTrue(json.loads(stdout.splitlines()[-1])["cancelled"])
                _, journal = self.paths(directory)
                self.assertEqual(json.loads(journal.read_text())["bytes"], self.prefix_size)
                calls = []
                sim.http_writer = self.range_writer(calls)
                self.collect(sim, directory)
                self.assertEqual(self.ftp_count(sim), 1)
                self.assert_published(directory)
            finally:
                release.set()
                if process.poll() is None:
                    process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()
