"""The publication recipe uses only fabricated data and isolated destinations."""
import importlib.util
import base64
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("distribution_validation", ROOT / "tools/verify-distribution.py")
recipe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(recipe)


class DistributionRecipeTests(unittest.TestCase):
    def test_updater_bundle_requires_framework_helpers_and_portable_app_link(self):
        with tempfile.TemporaryDirectory(prefix="katalog-sparkle-fixture-") as directory:
            app = Path(directory) / "KataLog.app"
            framework = app / "Contents/Frameworks/Sparkle.framework"
            (framework / "Resources").mkdir(parents=True)
            info = dict(CFBundleExecutable="KataLog", KatalogSparkleVersion="2.10.0", KatalogUpdatesEnabled=False,
                        KatalogUpdateChannel="disabled", SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                        SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                        SUEnableSystemProfiling=False, SUEnableJavaScript=False, SUSignedFeedFailureExpirationInterval=0)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            license_path = app / "Contents/Resources/Licenses/Sparkle-LICENSE.txt"
            license_path.parent.mkdir(parents=True); license_path.write_text("Synthetic license fixture")
            (framework / "Resources/Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier="org.sparkle-project.Sparkle", CFBundleShortVersionString="2.10.0")))
            for relative in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
                             "XPCServices/Installer.xpc/Contents/MacOS/Installer", "XPCServices/Downloader.xpc/Contents/MacOS/Downloader"):
                path = framework / relative; path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture"); path.chmod(0o755)
            check = recipe.Verification(app)
            def command(arguments):
                return b"@rpath/Sparkle.framework/Versions/B/Sparkle" if "-L" in arguments else b"@executable_path/../Frameworks"
            with patch.object(check, "command", side_effect=command):
                self.assertEqual(check.updates()["nestedExecutables"], 5)
                (framework / "XPCServices/Downloader.xpc/Contents/MacOS/Downloader").unlink()
                with self.assertRaisesRegex(recipe.CheckError, "nested Sparkle executable"):
                    check.updates()

    def test_update_configuration_rejects_unsigned_fallback_profiling_and_invalid_activation(self):
        info = dict(KatalogSparkleVersion="2.10.0", KatalogUpdatesEnabled=False, KatalogUpdateChannel="disabled",
                    SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                    SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                    SUEnableSystemProfiling=False, SUEnableJavaScript=False, SUSignedFeedFailureExpirationInterval=0)
        self.assertFalse(recipe.validate_update_info(info)["updatesEnabled"])
        active = dict(info, KatalogUpdatesEnabled=True, KatalogUpdateChannel="staging",
                      SUFeedURL="https://updates.example.org/staging/appcast.xml",
                      SUPublicEDKey=base64.b64encode(bytes(range(1, 33))).decode())
        self.assertTrue(recipe.validate_update_info(active)["updatesEnabled"])
        for change in (dict(SURequireSignedFeed=False), dict(SUVerifyUpdateBeforeExtraction=False),
                       dict(SUSignedFeedFailureExpirationInterval=1_728_000), dict(SUEnableSystemProfiling=True),
                       dict(SUEnableAutomaticChecks=True), dict(SUFeedURL="https://example.org/appcast.xml?key=private"),
                       dict(SUPublicEDKey=base64.b64encode(bytes(32)).decode()), dict(KatalogUpdateChannel="unknown")):
            with self.subTest(change=change), self.assertRaises(recipe.CheckError):
                recipe.validate_update_info(dict(active, **change))
        with self.assertRaises(recipe.CheckError):
            recipe.validate_update_info(dict(info, SUFeedURL="https://example.org/appcast.xml"))

    def test_private_collection_settings_and_database_sidecars_are_rejected_even_inside_zip(self):
        with tempfile.TemporaryDirectory(prefix="katalog-private-artifact-fixture-") as directory:
            app = Path(directory) / "KataLog.app"
            resources = app / "Contents/Resources"; resources.mkdir(parents=True)
            for name in ("gcs-settings.json", "views.json", "gcs-queue.sqlite-wal"):
                artifact = resources / name
                artifact.write_bytes(b"synthetic")
                with self.subTest(name=name), self.assertRaises(recipe.CheckError):
                    recipe.Verification(app).privacy()
                artifact.unlink()
            archive = resources / "accidental-backup.zip"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("gcs-settings.json", '{"host":"synthetic.local"}')
            with self.assertRaises(recipe.CheckError):
                recipe.Verification(app).privacy()

    def test_paged_inventory_requires_ordered_pages_and_explicit_complete_terminal(self):
        events = [dict(event='inventory_started', uuid=recipe.UUID, inventoryID='fixture', totalFiles=2),
                  dict(event='inventory_page', uuid=recipe.UUID, inventoryID='fixture', pageIndex=0,
                       files=[dict(path='/fs/microsd/log/a.ulg', size=64)]),
                  dict(event='inventory_page', uuid=recipe.UUID, inventoryID='fixture', pageIndex=1,
                       files=[dict(path='/fs/microsd/log/b.ulg', size=64)]),
                  dict(event='inventory_finished', uuid=recipe.UUID, inventoryID='fixture', pageCount=2, totalFiles=2)]
        def payload(items):
            return ('\n'.join(json.dumps(event) for event in items) + '\n').encode()
        self.assertEqual(len(recipe.inventory_files(payload(events))), 2)
        with self.assertRaises(recipe.CheckError):
            recipe.inventory_files(payload(events[:-1]))
        with self.assertRaises(recipe.CheckError):
            recipe.inventory_files(payload([events[0], events[2], events[1], events[3]]))
        legacy = [dict(event='inventory', uuid=recipe.UUID, files=events[1]['files'])]
        self.assertEqual(recipe.inventory_files(payload(legacy)), events[1]['files'])

    def test_generated_fixture_is_deterministic_and_fully_parseable(self):
        # Analyze through the actual public CLI, which is also frozen in the
        # shipping helper. This catches malformed ULog framing and wrong units.
        with tempfile.TemporaryDirectory(prefix="katalog-public-fixture-") as folder:
            work = Path(folder)
            source = work / "source"
            source.mkdir()
            payload = recipe.synthetic_ulog()
            self.assertEqual(payload, recipe.synthetic_ulog())
            (source / "synthetic.ulg").write_bytes(payload)
            output = work / "snapshot.json"
            result = subprocess.run([sys.executable, str(ROOT / "Sources/KataLog/Resources/analyzer.py"), "scan",
                                     "--folder", str(source), "--database", str(work / "test.sqlite"), "--output", str(output)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            snapshot = json.loads(output.read_text())
            log = snapshot["logs"][0]
            self.assertEqual(log["status"], "ok", log["issues"])
            self.assertEqual(log["droneID"], recipe.UUID)
            self.assertEqual(len(log["messages"]), 2)
            self.assertEqual(len(log["track"]["points"]), 3)
            self.assertEqual(log["dateSource"], "gps")
            self.assertEqual(log["date"], "2030-01-01T00:00:00Z")

    def test_advanced_library_recipe_runs_exact_dictionary_series_report_and_restore(self):
        with tempfile.TemporaryDirectory(prefix="katalog-advanced-public-fixture-") as folder:
            def run(*arguments):
                self.assertEqual(arguments[0], "analyzer")
                result = subprocess.run([sys.executable, str(ROOT / "Sources/KataLog/Resources/analyzer.py"), *arguments[1:]],
                                        capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                return result.stdout
            flags = recipe.Verification.advanced_library_recipe(run, Path(folder))
            self.assertEqual(len(flags), 14)
            self.assertTrue(all(flags.values()))

    def test_embedded_compressed_paths_cannot_escape_inspection(self):
        payload = b"prefix" + recipe.USER_PATH_MARKER + b"example/source.py"
        compressed = zlib.compress(payload)
        name = b"module\x00"
        entry = struct.pack("!iIIIBc", 18 + len(name), 0, len(compressed), len(payload), 1, b"m") + name
        cookie_size = struct.calcsize("!8sIIII64s")
        cookie = struct.pack("!8sIIII64s", b"MEI\x0c\x0b\x0a\x0b\x0e", len(compressed) + len(entry) + cookie_size,
                             len(compressed), len(entry), 312, b"libpython3.12.dylib")
        archive = b"pretend-executable" + compressed + entry + cookie
        self.assertNotIn(recipe.USER_PATH_MARKER, archive)
        self.assertEqual(list(recipe.embedded_payloads(archive)), [("module", payload)])

    def test_loopback_simulator_exercises_actual_collection_and_cache(self):
        with tempfile.TemporaryDirectory(prefix="katalog-loopback-recipe-") as folder:
            def run(*arguments):
                self.assertEqual(arguments[0], "gcs")
                result = subprocess.run([sys.executable, str(ROOT / "Sources/KataLog/Resources/gcs_collect.py"), *arguments[1:]],
                                        capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout.decode(errors="replace"))
                return result.stdout
            result = recipe.Verification.gcs_recipe(run, Path(folder), recipe.synthetic_ulog())
            self.assertTrue(result["loopbackDownload"])
            self.assertTrue(result["cachedDownloadAvoided"])
            self.assertTrue(result["singleDestination"])

    def test_nested_helper_framework_and_resource_links_are_portable(self):
        with tempfile.TemporaryDirectory(prefix="katalog-helper-links-") as folder:
            app = Path(folder).resolve() / "KataLog.app"
            contents = app / recipe.HELPER_BUNDLE / "Contents"
            resources = contents / "Resources"
            frameworks = contents / "Frameworks"
            resources.mkdir(parents=True)
            frameworks.mkdir()
            metadata = resources / "synthetic-package.dist-info"
            metadata.mkdir()
            link = frameworks / "synthetic-package.dist-info"
            link.symlink_to("../Resources/synthetic-package.dist-info", target_is_directory=True)
            self.assertIsNone(recipe.symlink_issue(link, app))
            link.unlink()
            link.symlink_to(metadata, target_is_directory=True)
            self.assertEqual(recipe.symlink_issue(link, app), "absolute-internal-symlink")
            link.unlink()
            link.symlink_to("../Resources/missing-package.dist-info", target_is_directory=True)
            self.assertEqual(recipe.symlink_issue(link, app), "broken-or-cyclic-symlink")
            link.unlink()
            outside = Path(folder).resolve() / "outside"
            outside.mkdir()
            link.symlink_to("../../../../../../outside", target_is_directory=True)
            self.assertEqual(recipe.symlink_issue(link, app), "external-symlink")

    def test_standard_dmg_background_is_allowed_without_allowing_other_files(self):
        with tempfile.TemporaryDirectory(prefix="katalog-dmg-layout-") as folder:
            mount = Path(folder)
            (mount / "KataLog.app").mkdir()
            (mount / "Applications").symlink_to("/Applications", target_is_directory=True)

            def chunk(kind, data):
                return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))

            png = b"\x89PNG\r\n\x1a\n"
            png += chunk(b"IHDR", struct.pack("!IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
            png += chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00\xff"))
            png += chunk(b"IEND", b"")
            background = mount / ".background.png"
            background.write_bytes(png)
            self.assertTrue(recipe.validate_dmg_layout(mount)["backgroundArtwork"])
            unexpected = mount / "unreviewed-data.json"
            unexpected.write_text("{}")
            with self.assertRaisesRegex(recipe.CheckError, "Unexpected or missing"):
                recipe.validate_dmg_layout(mount)
            unexpected.unlink()
            background.write_bytes(b"Not PNG artwork")
            with self.assertRaisesRegex(recipe.CheckError, "not a PNG"):
                recipe.validate_dmg_layout(mount)

    def test_review_dmg_uses_its_separate_application_filename(self):
        with tempfile.TemporaryDirectory(prefix="katalog-preview-layout-") as folder:
            mount = Path(folder)
            (mount / "KataLog Preview.app").mkdir()
            (mount / "Applications").symlink_to("/Applications", target_is_directory=True)
            self.assertTrue(recipe.validate_dmg_layout(mount, app_name="KataLog Preview.app") is not None)
            with self.assertRaisesRegex(recipe.CheckError, "Unexpected or missing"):
                recipe.validate_dmg_layout(mount)
            (mount / "KataLog.app").mkdir()
            with self.assertRaisesRegex(recipe.CheckError, "Unexpected or missing"):
                recipe.validate_dmg_layout(mount, app_name="KataLog Preview.app")


if __name__ == "__main__":
    unittest.main()
