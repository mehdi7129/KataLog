"""Fault injection for owned temporary mounts; no disk image is mounted."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("katalog_dmg_mount_test", ROOT / "tools/dmg_mount.py")
mounts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mounts)


class TemporaryDMGMountTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="katalog-owned-mount-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.mount = Path(self.temporary.name) / "owned-mount"
        self.mount.mkdir()
        self.calls = []

    def command(self, detach_statuses, *, attach_status=0):
        statuses = iter(detach_statuses)

        def run(arguments, **options):
            self.calls.append((list(arguments), options))
            status = attach_status if arguments[1] == "attach" else next(statuses)
            if status:
                raise subprocess.CalledProcessError(status, arguments, stderr=b"Resource busy")
            return subprocess.CompletedProcess(arguments, 0, stdout=b"")
        return run

    def context(self):
        return mounts.readonly_mount(Path("synthetic.dmg"), prefix="katalog-owned-fixture-")

    def test_detach_success_and_busy_retries_remove_only_the_empty_owned_mount(self):
        for statuses in ([0], [16, 0], [16, 16, 0]):
            with self.subTest(statuses=statuses):
                self.calls.clear()
                self.mount.mkdir(exist_ok=True)
                with patch.object(mounts.tempfile, "mkdtemp", return_value=str(self.mount)), \
                     patch.object(mounts.subprocess, "run", side_effect=self.command(statuses)), \
                     patch.object(mounts.time, "sleep") as sleep, \
                     patch.object(shutil, "rmtree") as recursive_cleanup:
                    with self.context() as mounted:
                        self.assertEqual(mounted, self.mount)
                        self.assertTrue(mounted.exists())
                    recursive_cleanup.assert_not_called()
                self.assertFalse(self.mount.exists())
                detaches = [arguments for arguments, _ in self.calls if arguments[1] == "detach"]
                self.assertEqual(detaches, [["/usr/bin/hdiutil", "detach", str(self.mount)]] * len(statuses))
                self.assertEqual(sleep.call_count, len(statuses) - 1)
                attach = self.calls[0][0]
                self.assertIn("-readonly", attach)
                self.assertEqual(Path(attach[attach.index("-mountpoint") + 1]), self.mount)

    def test_force_is_one_last_attempt_on_the_same_successfully_attached_mount(self):
        with patch.object(mounts.tempfile, "mkdtemp", return_value=str(self.mount)), \
             patch.object(mounts.subprocess, "run", side_effect=self.command([16, 16, 16, 0])), \
             patch.object(mounts.time, "sleep"):
            with self.context():
                pass
        detaches = [arguments for arguments, _ in self.calls if arguments[1] == "detach"]
        self.assertEqual(len(detaches), 4)
        self.assertEqual(detaches[-1], ["/usr/bin/hdiutil", "detach", str(self.mount), "-force"])
        self.assertEqual(sum("-force" in arguments for arguments in detaches), 1)
        self.assertTrue(all(arguments[2] == str(self.mount) for arguments in detaches))
        self.assertTrue(all(options["timeout"] == 10 for arguments, options in self.calls if arguments[1] == "detach"))
        self.assertFalse(self.mount.exists())

    def test_permanent_detach_failure_keeps_mount_and_never_attempts_directory_cleanup(self):
        with patch.object(mounts.tempfile, "mkdtemp", return_value=str(self.mount)), \
             patch.object(mounts.subprocess, "run", side_effect=self.command([16] * 4)), \
             patch.object(mounts.time, "sleep"), \
             patch.object(Path, "rmdir") as rmdir, \
             patch.object(shutil, "rmtree") as rmtree:
            with self.assertRaisesRegex(mounts.TemporaryMountError, "exit status 16.*mount preserved") as caught:
                with self.context():
                    pass
            rmdir.assert_not_called()
            rmtree.assert_not_called()
        self.assertIn(str(self.mount), str(caught.exception))
        self.assertTrue(self.mount.exists())
        self.assertEqual(len(self.calls), 5)

    def test_validation_error_stays_primary_when_detach_permanently_fails(self):
        original = ValueError("Synthetic bundle mismatch")
        with patch.object(mounts.tempfile, "mkdtemp", return_value=str(self.mount)), \
             patch.object(mounts.subprocess, "run", side_effect=self.command([16] * 4)), \
             patch.object(mounts.time, "sleep"):
            with self.assertRaises(ValueError) as caught:
                with self.context():
                    raise original
        self.assertIs(caught.exception, original)
        self.assertIsInstance(original.__cause__, mounts.TemporaryMountError)
        self.assertTrue(self.mount.exists())

    def test_attach_failure_never_detaches_an_unconfirmed_mount(self):
        with patch.object(mounts.tempfile, "mkdtemp", return_value=str(self.mount)), \
             patch.object(mounts.subprocess, "run", side_effect=self.command([], attach_status=1)):
            with self.assertRaises(subprocess.CalledProcessError):
                with self.context():
                    self.fail("Failed attach must not yield a mount")
        self.assertEqual(len(self.calls), 1)
        self.assertFalse(self.mount.exists())

    def test_partial_attach_failure_keeps_leftovers_and_preserves_attach_error(self):
        (self.mount / "synthetic-readonly-content").write_bytes(b"synthetic")
        with patch.object(mounts.tempfile, "mkdtemp", return_value=str(self.mount)), \
             patch.object(mounts.subprocess, "run", side_effect=self.command([], attach_status=1)), \
             patch.object(shutil, "rmtree") as rmtree:
            with self.assertRaises(subprocess.CalledProcessError) as caught:
                with self.context():
                    pass
            rmtree.assert_not_called()
        self.assertIsInstance(caught.exception.__cause__, OSError)
        self.assertTrue((self.mount / "synthetic-readonly-content").exists())


if __name__ == "__main__":
    unittest.main()
