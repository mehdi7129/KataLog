"""Real loopback HTTP reads; the minimum copy budget is shortened for tests."""

import contextlib
import hashlib
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from test_gcs_collect import BODY, REMOTE, SCRIPT, UUID, Simulator, gcs


class HTTPDeadlineTests(unittest.TestCase):
    budget = 0.35

    @staticmethod
    def headers(handler, *, length=None, chunked=False):
        handler.send_response(200)
        if length is not None:
            handler.send_header("Content-Length", str(length))
        if chunked:
            handler.send_header("Transfer-Encoding", "chunked")
        handler.end_headers()

    def assert_deadline_cleans_download(self, writer):
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = writer
            reports = []
            with patch.object(gcs, "HTTP_COPY_MIN_SECONDS", self.budget), \
                 patch.object(gcs, "emit", side_effect=lambda event, **fields: reports.append((event, fields))):
                started = time.monotonic()
                with self.assertRaises((gcs.CollectionError, TimeoutError)) as caught:
                    gcs.download("127.0.0.1", sim.port, sim.http_port, UUID, REMOTE, len(BODY), directory)
                elapsed = time.monotonic() - started
            self.assertTrue(gcs.retryable_error(caught.exception))
            self.assertLess(elapsed, 1.2, "A continuously active peer must not extend the copy deadline.")
            self.assertFalse(any(event == "downloaded" for event, _ in reports))
            self.assertEqual(list(Path(directory).rglob("*.part")), [])
            self.assertEqual(list(Path(directory).rglob("*.ulg")), [])
            self.assertEqual(list(Path(directory).rglob("*.katalog*.json")), [])
            return reports

    def test_slow_continuous_body_reports_progress_and_obeys_deadline(self):
        def writer(handler):
            self.headers(handler, length=len(BODY))
            try:
                for offset in range(0, len(BODY), 64):
                    handler.wfile.write(BODY[offset:offset + 64]); handler.wfile.flush()
                    time.sleep(0.08)
            except (BrokenPipeError, ConnectionResetError):
                pass
        reports = self.assert_deadline_cleans_download(writer)
        progress = [fields["bytes"] for event, fields in reports
                    if event == "progress" and fields.get("phase") == "http"]
        self.assertTrue(progress, "Available bytes must be reported before the peer finishes its block.")
        self.assertLess(progress[-1], len(BODY))

    def test_stalled_body_obeys_remaining_deadline(self):
        def writer(handler):
            self.headers(handler, length=len(BODY))
            handler.wfile.write(BODY[:16]); handler.wfile.flush()
            time.sleep(1.4)
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                handler.wfile.write(BODY[16:])
        self.assert_deadline_cleans_download(writer)

    def test_slow_chunk_framing_obeys_deadline(self):
        def writer(handler):
            self.headers(handler, chunked=True)
            try:
                # A read1() still reads complete chunk headers internally.
                for byte in (f"{len(BODY):x};" + "x" * 35 + "\r\n").encode():
                    handler.wfile.write(bytes([byte])); handler.wfile.flush(); time.sleep(0.04)
                handler.wfile.write(BODY + b"\r\n0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
        self.assert_deadline_cleans_download(writer)

    def test_unbounded_and_chunked_valid_bodies_preserve_hash_and_publication(self):
        for chunked in (False, True):
            with self.subTest(chunked=chunked), Simulator() as sim, tempfile.TemporaryDirectory() as directory:
                def writer(handler):
                    self.headers(handler, chunked=chunked)
                    if chunked:
                        for offset in range(0, len(BODY), 41):
                            chunk = BODY[offset:offset + 41]
                            handler.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                        handler.wfile.write(b"0\r\nX-Final: yes\r\n\r\n")
                    else:
                        handler.wfile.write(BODY)
                sim.http_writer = writer
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    gcs.download("127.0.0.1", sim.port, sim.http_port, UUID, REMOTE, len(BODY), directory)
                final = json.loads(output.getvalue().splitlines()[-1])
                self.assertEqual(final["event"], "downloaded")
                self.assertEqual(final["sha256"], hashlib.sha256(BODY).hexdigest())
                self.assertEqual(Path(final["localPath"]).read_bytes(), BODY)
                self.assertEqual(list(Path(directory).rglob("*.part")), [])

    def test_sigterm_during_real_stalled_http_removes_part_without_publication(self):
        sent = threading.Event()
        release = threading.Event()
        def writer(handler):
            self.headers(handler, length=len(BODY))
            handler.wfile.write(BODY[:16]); handler.wfile.flush(); sent.set()
            release.wait(4)
        with Simulator() as sim, tempfile.TemporaryDirectory() as directory:
            sim.http_writer = writer
            process = subprocess.Popen([sys.executable, str(SCRIPT), "download", "--host", "127.0.0.1",
                "--port", str(sim.port), "--http-port", str(sim.http_port), "--uuid", UUID,
                "--remote", REMOTE, "--size", str(len(BODY)), "--destination", directory],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertTrue(sent.wait(3))
                started = time.monotonic(); process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=3)
                self.assertLess(time.monotonic() - started, 2)
                self.assertEqual(process.returncode, 130, stderr)
                events = [json.loads(line) for line in stdout.splitlines()]
                self.assertTrue(events[-1]["cancelled"])
                self.assertFalse(any(event["event"] == "downloaded" for event in events))
                self.assertEqual(list(Path(directory).rglob("*.part")), [])
                self.assertEqual(list(Path(directory).rglob("*.ulg")), [])
            finally:
                release.set()
                if process.poll() is None:
                    process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()
