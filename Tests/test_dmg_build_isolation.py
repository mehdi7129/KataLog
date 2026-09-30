"""DMG publication stays local until verified; no app, volume or identity needed."""
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("katalog_dmg_build", ROOT / "tools/build-dmg.py")
builder = importlib.util.module_from_spec(SPEC)
with patch.dict(sys.modules, {"dmgbuild": types.ModuleType("dmgbuild")}):
    SPEC.loader.exec_module(builder)


class DMGBuildIsolationTests(unittest.TestCase):
    def test_local_build_retries_busy_mount_after_running_its_copied_helper(self):
        with tempfile.TemporaryDirectory(prefix="katalog-build-mount-fixture-") as temporary:
            app = Path(temporary) / "KataLog.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
                KatalogBundledEngineRequired=True, CFBundleShortVersionString="0.6.0", CFBundleVersion="8")))
            output = Path(temporary) / "candidate.dmg"
            mountpoints, detaches, helper_calls = [], [], []

            def command(arguments, **options):
                if arguments[:2] == ["/usr/bin/hdiutil", "attach"]:
                    mount = Path(arguments[arguments.index("-mountpoint") + 1])
                    mountpoints.append(mount)
                    shutil.copytree(app, mount / app.name)
                    (mount / "Applications").symlink_to("/Applications")
                elif arguments[:2] == ["/usr/bin/hdiutil", "detach"]:
                    detaches.append(arguments)
                    self.assertEqual(len(helper_calls), 1)
                    if len(detaches) == 1:
                        raise subprocess.CalledProcessError(16, arguments, stderr=b"Resource busy")
                    shutil.rmtree(mountpoints[0] / app.name)
                    (mountpoints[0] / "Applications").unlink()
                elif arguments[-1] == "--katalog-runtime-info":
                    helper_calls.append(arguments)
                    self.assertEqual(Path(arguments[0]), mountpoints[0] / app.name / "Contents/Helpers/KataLogEngine.app/Contents/MacOS/KataLogEngine")
                return subprocess.CompletedProcess(arguments, 0, stdout=b"")

            def image(destination, name, settings):
                Path(destination).write_bytes(b"Synthetic DMG image")

            with patch.object(builder.dmgbuild, "build_dmg", create=True, side_effect=image), \
                 patch.object(builder.subprocess, "run", side_effect=command), \
                 patch.object(builder.dmg_mount.time, "sleep"):
                result = builder._build_local(app, output, "-")
            self.assertEqual(result["version"], "0.6.0")
            self.assertEqual(len(detaches), 2)
            self.assertNotIn("-force", detaches[-1])
            self.assertFalse(mountpoints[0].exists())

    def test_only_verified_local_image_is_published_and_staging_is_cleaned(self):
        with tempfile.TemporaryDirectory(prefix="katalog-dmg-publication-") as temporary:
            output = Path(temporary) / "file-provider-destination/candidate.dmg"
            staged = []
            payload = b"Invented signed DMG bytes"
            def local(app, path, identity, profile):
                staged.append(path)
                self.assertTrue(path.is_relative_to(Path("/private/tmp")))
                self.assertNotEqual(path.parent, output.parent)
                path.write_bytes(payload)
                return {"sha256": hashlib.sha256(payload).hexdigest(), "bytes": len(payload)}
            with patch.object(builder, "_build_local", side_effect=local):
                result = builder.build(Path("invented.app"), output, "-")
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(result["sha256"], hashlib.sha256(payload).hexdigest())
            self.assertFalse(staged[0].parent.exists())

    def test_existing_destination_and_partial_publication_are_preserved_safely(self):
        with tempfile.TemporaryDirectory(prefix="katalog-dmg-publication-") as temporary:
            output = Path(temporary) / "candidate.dmg"
            output.write_bytes(b"Previous package")
            with patch.object(builder, "_build_local") as local:
                with self.assertRaises(ValueError):
                    builder.build(Path("invented.app"), output, "-")
                local.assert_not_called()
            self.assertEqual(output.read_bytes(), b"Previous package")
            output.unlink()
            staged = []
            def local(app, path, identity, profile):
                staged.append(path); path.write_bytes(b"New package")
                return {"sha256": hashlib.sha256(b"New package").hexdigest()}
            def failed_copy(source, destination, length):
                destination.write(b"Partial"); raise OSError("Invented write interruption")
            with patch.object(builder, "_build_local", side_effect=local), \
                 patch.object(builder.shutil, "copyfileobj", side_effect=failed_copy):
                with self.assertRaises(OSError):
                    builder.build(Path("invented.app"), output, "-")
            self.assertFalse(output.exists())
            self.assertFalse(staged[0].parent.exists())


if __name__ == "__main__":
    unittest.main()
