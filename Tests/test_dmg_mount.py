"""Fault injection for owned temporary mounts; no disk image is mounted."""
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

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

    def entities(self):
        return [{'dev-entry': '/dev/disk99'},
                {'dev-entry': '/dev/disk99s1', 'mount-point': str(self.mount)}]

    def attached_inventory(self, entities=None):
        return plistlib.dumps({'images': [{'image-path': str(Path('synthetic.dmg').resolve()),
                                           'system-entities': self.entities() if entities is None else entities}]})

    def command(self, detach_statuses, *, attach_status=0, inventory=None, attach_data=None):
        statuses = iter(detach_statuses)
        detached = False
        inventories = iter(inventory) if isinstance(inventory, list) else None
        current_inventory = inventory

        def run(arguments, **options):
            nonlocal detached, current_inventory
            self.calls.append((list(arguments), options))
            if arguments[1] == "info":
                if inventories is not None:
                    current_inventory = next(inventories, current_inventory)
                if isinstance(current_inventory, Exception):
                    raise current_inventory
                data = current_inventory if current_inventory is not None else (
                    plistlib.dumps({'images': []}) if detached else self.attached_inventory())
                return subprocess.CompletedProcess(arguments, 0, stdout=data)
            status = attach_status if arguments[1] == "attach" else next(statuses)
            if isinstance(status, Exception):
                raise status
            if status:
                raise subprocess.CalledProcessError(status, arguments, stderr=b"Resource busy")
            if arguments[1] == 'attach':
                return subprocess.CompletedProcess(arguments, 0, stdout=(
                    plistlib.dumps({'system-entities': self.entities()}) if attach_data is None else attach_data))
            detached = True
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
                self.assertEqual(detaches, [["/usr/bin/hdiutil", "detach", '/dev/disk99']] * len(statuses))
                self.assertEqual(sleep.call_count, len(statuses) - 1)
                attach = self.calls[0][0]
                self.assertIn("-readonly", attach)
                self.assertIn('-plist', attach)
                self.assertEqual(Path(attach[attach.index("-mountpoint") + 1]), self.mount)

    def test_force_is_one_last_attempt_on_the_same_successfully_attached_mount(self):
        with patch.object(mounts.tempfile, "mkdtemp", return_value=str(self.mount)), \
             patch.object(mounts.subprocess, "run", side_effect=self.command([16, 16, 16, 0])), \
             patch.object(mounts.time, "sleep"):
            with self.context():
                pass
        detaches = [arguments for arguments, _ in self.calls if arguments[1] == "detach"]
        self.assertEqual(len(detaches), 4)
        self.assertEqual(detaches[-1], ["/usr/bin/hdiutil", "detach", '/dev/disk99', "-force"])
        self.assertEqual(sum("-force" in arguments for arguments in detaches), 1)
        self.assertTrue(all(arguments[2] == '/dev/disk99' for arguments in detaches))
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
        self.assertEqual(len([c for c, _ in self.calls if c[1] == 'detach']), 4)
        self.assertEqual(self.calls[-1][0], ['/usr/bin/hdiutil', 'info', '-plist'])

    def test_late_detach_requires_absent_image_and_safe_empty_or_missing_mountpoint(self):
        # hdiutil can report a timeout, then ENOENT, after actually detaching.
        # The error text alone is deliberately identical in every case.
        for missing in (False, True):
            with self.subTest(missing=missing):
                self.mount.mkdir(exist_ok=True)
                if missing:
                    self.mount.rmdir()
                self.calls.clear()
                statuses = [subprocess.TimeoutExpired(['hdiutil', 'detach'], 10)]
                inventory = [self.attached_inventory(), plistlib.dumps({'images': [{'image-path': '/tmp/unrelated.dmg',
                    'system-entities': [{'dev-entry': '/dev/disk88', 'mount-point': '/Volumes/Unrelated'}]}]})]
                stderr = io.StringIO()
                with patch.object(mounts.tempfile, 'mkdtemp', return_value=str(self.mount)), \
                     patch.object(mounts.subprocess, 'run', side_effect=self.command(statuses, inventory=inventory)), \
                     patch.object(mounts.time, 'sleep'), \
                     patch.object(mounts.sys, 'stderr', stderr), \
                     patch.object(shutil, 'rmtree') as rmtree:
                    with self.context():
                        pass
                    rmtree.assert_not_called()
                self.assertFalse(self.mount.exists())
                state = json.loads([line.split('DMG detach state: ', 1)[1] for line in stderr.getvalue().splitlines()
                                    if line.startswith('DMG detach state: ')][-1])
                self.assertTrue(state['confirmedDetached'])
                self.assertFalse(state['imagePresent'])
                self.assertFalse(state['mountPresent'])
                self.assertEqual(state['mountPointState'], 'absent' if missing else 'empty-parent-filesystem-directory')
                self.assertEqual(len([c for c, _ in self.calls if c[1] == 'detach']), 1)

    def test_image_or_mount_still_in_inventory_must_fail_even_when_local_directory_empty(self):
        entries = [
            {'image-path': str(Path('synthetic.dmg').resolve()), 'system-entities': []},
            {'image-path': '/tmp/another.dmg', 'system-entities': [{'dev-entry': '/dev/disk88', 'mount-point': str(self.mount)}]},
        ]
        for entry in entries:
            with self.subTest(entry=entry), \
                 patch.object(mounts.tempfile, 'mkdtemp', return_value=str(self.mount)), \
                 patch.object(mounts.subprocess, 'run', side_effect=self.command([1] * 4, inventory=plistlib.dumps({'images': [entry]}))), \
                 patch.object(mounts.time, 'sleep'), \
                 patch.object(Path, 'rmdir') as rmdir:
                with self.assertRaises(mounts.TemporaryMountError):
                    with self.context():
                        pass
                rmdir.assert_not_called()

    def test_detaches_captured_device_when_image_remains_attached_without_mountpoint(self):
        inventory = [self.attached_inventory([{'dev-entry': '/dev/disk99'}, {'dev-entry': '/dev/disk99s1'}]),
                     plistlib.dumps({'images': []})]
        with patch.object(mounts.tempfile, 'mkdtemp', return_value=str(self.mount)), \
             patch.object(mounts.subprocess, 'run', side_effect=self.command([0], inventory=inventory)):
            with self.context():
                pass
        detaches = [c for c, _ in self.calls if c[1] == 'detach']
        self.assertEqual(detaches, [['/usr/bin/hdiutil', 'detach', '/dev/disk99']])
        self.assertFalse(self.mount.exists())

    def test_reversed_attach_entities_still_detach_the_owned_root_device(self):
        # A fresh macOS attach emits the mounted partition before its root;
        # attaching an already attached image can emit the opposite order.
        data = plistlib.dumps({'system-entities': list(reversed(self.entities()))})
        with patch.object(mounts.tempfile, 'mkdtemp', return_value=str(self.mount)), \
             patch.object(mounts.subprocess, 'run', side_effect=self.command([0], attach_data=data)):
            with self.context():
                pass
        self.assertEqual([c for c, _ in self.calls if c[1] == 'detach'],
                         [['/usr/bin/hdiutil', 'detach', '/dev/disk99']])
        self.assertFalse(self.mount.exists())

    def test_reassigned_device_is_never_detached_even_if_image_is_still_attached(self):
        reassigned = plistlib.dumps({'images': [
            {'image-path': '/tmp/another-owner.dmg', 'system-entities': [{'dev-entry': '/dev/disk99'}]},
            {'image-path': str(Path('synthetic.dmg').resolve()), 'system-entities': [{'dev-entry': '/dev/disk100'}]}]})
        for after_busy in (False, True):
            self.calls.clear()
            inventory = [self.attached_inventory(), reassigned] if after_busy else reassigned
            with self.subTest(after_busy=after_busy), \
                 patch.object(mounts.tempfile, 'mkdtemp', return_value=str(self.mount)), \
                 patch.object(mounts.subprocess, 'run', side_effect=self.command([16], inventory=inventory)), \
                 patch.object(mounts.time, 'sleep'):
                with self.assertRaisesRegex(mounts.TemporaryMountError, 'cannot be safely detached'):
                    with self.context():
                        pass
            detaches = [c for c, _ in self.calls if c[1] == 'detach']
            self.assertEqual(len(detaches), 1 if after_busy else 0)
            self.assertFalse(any('/dev/disk100' in c for c in detaches))
            self.assertTrue(self.mount.exists())

    def test_successful_detach_exit_does_not_hide_image_still_attached(self):
        with patch.object(mounts.tempfile, 'mkdtemp', return_value=str(self.mount)), \
             patch.object(mounts.subprocess, 'run', side_effect=self.command([0] * 4, inventory=self.attached_inventory())), \
             patch.object(mounts.time, 'sleep'):
            with self.assertRaisesRegex(mounts.TemporaryMountError, 'still attached after successful hdiutil'):
                with self.context():
                    pass
        self.assertTrue(self.mount.exists())

    def test_invalid_attach_plist_never_yields_or_detaches_an_unproven_device(self):
        payloads = [b'not plist', plistlib.dumps({}),
                    plistlib.dumps({'system-entities': [{'dev-entry': '/dev/disk99'}]}),
                    plistlib.dumps({'system-entities': self.entities() + [{'dev-entry': '/dev/disk100'}]}),
                    plistlib.dumps({'system-entities': [{'dev-entry': '/dev/disk99'},
                        {'dev-entry': '/dev/disk100s1', 'mount-point': str(self.mount)}]}),
                    plistlib.dumps({'system-entities': [{'dev-entry': '/dev/disk99s1', 'mount-point': str(self.mount)}]}),
                    plistlib.dumps({'system-entities': [{'dev-entry': '/dev/disk99', 'mount-point': '/Volumes/SomeoneElse'}]})]
        for data in payloads:
            self.calls.clear()
            with self.subTest(data=data), \
                 patch.object(mounts.tempfile, 'mkdtemp', return_value=str(self.mount)), \
                 patch.object(mounts.subprocess, 'run', side_effect=self.command([], attach_data=data)), \
                 patch.object(Path, 'rmdir') as rmdir:
                with self.assertRaisesRegex(mounts.TemporaryMountError, 'Cannot establish owned device'):
                    with self.context():
                        self.fail('Invalid attach must not yield')
                rmdir.assert_not_called()
            self.assertEqual(len(self.calls), 1)
            self.assertTrue(self.mount.exists())

    def test_unreadable_or_incomplete_inventory_never_confirms_detach(self):
        inventories = [b'not a plist', plistlib.dumps({}), plistlib.dumps({'images': [{}]}),
                       plistlib.dumps({'images': [{'image-path': 'relative.dmg', 'system-entities': []}]}),
                       plistlib.dumps({'images': [{'image-path': '/tmp/other.dmg', 'system-entities': ['invalid-entity']}]}),
                       plistlib.dumps({'images': [{'image-path': '/tmp/other.dmg', 'system-entities': [{}]}]}),
                       subprocess.CalledProcessError(1, ['hdiutil', 'info']),
                       subprocess.TimeoutExpired(['hdiutil', 'info'], 10)]
        for inventory in inventories:
            with self.subTest(inventory=inventory), \
                 patch.object(mounts.tempfile, 'mkdtemp', return_value=str(self.mount)), \
                 patch.object(mounts.subprocess, 'run', side_effect=self.command([1] * 4, inventory=inventory)), \
                 patch.object(mounts.time, 'sleep'), \
                 patch.object(Path, 'rmdir') as rmdir:
                with self.assertRaisesRegex(mounts.TemporaryMountError, 'inspectionError'):
                    with self.context():
                        pass
                rmdir.assert_not_called()

    def test_absent_inventory_does_not_override_mounted_nonempty_or_symlink_state(self):
        inventory = plistlib.dumps({'images': []})
        with patch.object(mounts.subprocess, 'run', side_effect=self.command([], inventory=inventory)):
            (self.mount / 'remaining-file').write_text('preserve')
            self.assertFalse(mounts._detached_state(self.mount, Path('synthetic.dmg'))['confirmedDetached'])
            (self.mount / 'remaining-file').unlink()
            parent = self.mount.parent.stat()
            mounted = SimpleNamespace(st_mode=stat.S_IFDIR, st_dev=parent.st_dev + 1, st_ino=parent.st_ino + 1)
            with patch.object(Path, 'lstat', return_value=mounted):
                self.assertEqual(mounts._detached_state(self.mount, Path('synthetic.dmg'))['mountPointState'], 'mounted-filesystem')
            self.mount.rmdir()
            self.mount.symlink_to(self.mount.parent, target_is_directory=True)
            self.assertFalse(mounts._detached_state(self.mount, Path('synthetic.dmg'))['confirmedDetached'])

    def test_filesystem_inspection_error_never_confirms_detach(self):
        with patch.object(mounts.subprocess, 'run', side_effect=self.command([], inventory=plistlib.dumps({'images': []}))), \
             patch.object(Path, 'lstat', side_effect=PermissionError('Unreadable owned mountpoint')):
            state = mounts._detached_state(self.mount, Path('synthetic.dmg'))
        self.assertFalse(state['confirmedDetached'])
        self.assertIn('Unreadable owned mountpoint', state['inspectionError'])

    def test_original_validation_failure_is_preserved_after_confirmed_late_detach(self):
        original = ValueError('Bundle mismatch must never be hidden by recovered cleanup')
        with patch.object(mounts.tempfile, 'mkdtemp', return_value=str(self.mount)), \
             patch.object(mounts.subprocess, 'run', side_effect=self.command([1] * 4, inventory=plistlib.dumps({'images': []}))), \
             patch.object(mounts.time, 'sleep'):
            with self.assertRaises(ValueError) as caught:
                with self.context():
                    raise original
        self.assertIs(caught.exception, original)
        self.assertFalse(self.mount.exists())

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
