"""The publication recipe uses only fabricated data and isolated destinations."""
import importlib.util
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
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
    def make_dmg_ticket_fixture(self, directory):
        work = Path(directory)
        app = work / "KataLog.app"
        helper = app / recipe.HELPER_BUNDLE
        helper.mkdir(parents=True)
        (helper / "synthetic-runtime").write_bytes(b"Synthetic helper")
        image = work / "synthetic.dmg"
        image.write_bytes(b"Synthetic disk image")
        mount = work / "owned-mount"
        mount.mkdir()
        return app, image, mount

    def test_mounted_app_and_helper_tickets_are_required_only_with_notarization_flag(self):
        for required in (False, True):
            with self.subTest(required=required), tempfile.TemporaryDirectory(prefix="katalog-ticket-fixture-") as directory:
                app, image, mount = self.make_dmg_ticket_fixture(directory)
                calls, detaches = [], []

                def command(arguments):
                    calls.append(arguments)
                    if arguments[:2] == ["/usr/bin/hdiutil", "attach"]:
                        self.assertEqual(arguments[arguments.index("-mountpoint") + 1], mount)
                        shutil.copytree(app, mount / app.name)
                        (mount / "Applications").symlink_to("/Applications")
                    elif arguments[1:3] == ["stapler", "validate"]:
                        self.assertTrue(Path(arguments[-1]).is_dir())
                    return b""

                def detach(arguments, **options):
                    detaches.append(arguments)
                    if len(detaches) == 1:
                        raise subprocess.CalledProcessError(16, arguments, stderr=b"Resource busy")
                    shutil.rmtree(mount / app.name)
                    (mount / "Applications").unlink()
                    return subprocess.CompletedProcess(arguments, 0, stdout=b"")

                verifier = recipe.Verification(app, require_notarized=required)
                with patch.object(verifier, "command", side_effect=command), \
                     patch.object(recipe.dmg_mount.tempfile, "mkdtemp", return_value=str(mount)), \
                     patch.object(recipe.dmg_mount.subprocess, "run", side_effect=detach), \
                     patch.object(recipe.dmg_mount.time, "sleep"):
                    result = verifier.dmg(image)
                tickets = [arguments[-1] for arguments in calls if arguments[1:3] == ["stapler", "validate"]]
                self.assertEqual(tickets, [mount / app.name, mount / app.name / recipe.HELPER_BUNDLE] if required else [])
                self.assertEqual(result.get("mountedHelperTicketAttached", False), required)
                self.assertEqual(result.get("mountedAppTicketAttached", False), required)
                self.assertEqual(len(detaches), 2)
                self.assertFalse(mount.exists())

    def test_missing_ticket_in_mounted_helper_fails_verification_and_still_detaches(self):
        with tempfile.TemporaryDirectory(prefix="katalog-ticket-fixture-") as directory:
            app, image, mount = self.make_dmg_ticket_fixture(directory)

            def command(arguments):
                if arguments[:2] == ["/usr/bin/hdiutil", "attach"]:
                    shutil.copytree(app, mount / app.name)
                    (mount / "Applications").symlink_to("/Applications")
                elif arguments[1:3] == ["stapler", "validate"] and arguments[-1] == mount / app.name / recipe.HELPER_BUNDLE:
                    raise recipe.CheckError("Mounted helper ticket is absent")
                return b""

            def detach(arguments, **options):
                self.assertEqual(arguments, ["/usr/bin/hdiutil", "detach", str(mount)])
                shutil.rmtree(mount / app.name)
                (mount / "Applications").unlink()
                return subprocess.CompletedProcess(arguments, 0, stdout=b"")

            verifier = recipe.Verification(app, require_notarized=True)
            with patch.object(verifier, "command", side_effect=command), \
                 patch.object(recipe.dmg_mount.tempfile, "mkdtemp", return_value=str(mount)), \
                 patch.object(recipe.dmg_mount.subprocess, "run", side_effect=detach):
                verifier.check("dmg-ticket-fixture", lambda: verifier.dmg(image))
            self.assertEqual(verifier.report["checks"][0]["status"], "failed")
            self.assertEqual(verifier.report["checks"][0]["reason"], "Mounted helper ticket is absent")
            self.assertFalse(mount.exists())

    def make_project_license_bundle(self, directory, version="0.6.0", build="8"):
        project = Path(directory) / "source"
        project.mkdir()
        (project / "LICENSE").write_bytes((ROOT / "LICENSE").read_bytes())
        app = Path(directory) / "KataLog.app"
        (app / "Contents").mkdir(parents=True)
        info = dict(CFBundleIdentifier="org.example.katalog", CFBundleShortVersionString=version,
                    CFBundleVersion=build, LSMinimumSystemVersion="15.0")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        recipe.write_project_license(project, app)
        return project, app, plistlib.loads((app / "Contents/Info.plist").read_bytes())

    def test_project_license_bundle_contains_exact_gnu_text_and_public_attribution(self):
        with tempfile.TemporaryDirectory(prefix="katalog-license-") as directory:
            _, app, info = self.make_project_license_bundle(directory)
            licenses = app / "Contents/Resources/Licenses"
            upstream = licenses / "Sparkle-LICENSE.txt"
            upstream.write_text("Synthetic upstream notice, retained unchanged")
            project = Path(directory) / "source"
            recipe.write_project_license(project, app)
            included = licenses / "KataLog"
            # Reviewed upstream bytes, rather than a license synthesized by the writer.
            self.assertEqual((included / "GPL-3.0.txt").read_bytes(), (ROOT / "LICENSE").read_bytes())
            self.assertEqual(hashlib.sha256((included / "GPL-3.0.txt").read_bytes()).hexdigest(),
                             "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986")
            notice = (included / "NOTICE.txt").read_text()
            self.assertIn("Copyright (C) 2026 mehdi7129", notice)
            self.assertIn("SPDX-License-Identifier: GPL-3.0-only", notice)
            self.assertIn("https://github.com/mehdi7129/KataLog", notice)
            self.assertEqual(upstream.read_text(), "Synthetic upstream notice, retained unchanged")
            manifest = json.loads((included / "manifest.json").read_text())
            self.assertEqual((manifest["appVersion"], manifest["buildNumber"]), ("0.6.0", "8"))
            self.assertNotIn(directory, json.dumps(manifest))
            self.assertTrue(recipe.validate_project_license(app, info)["required"])

    def test_current_and_future_packages_cannot_omit_project_license_material(self):
        with tempfile.TemporaryDirectory(prefix="katalog-missing-license-") as directory:
            _, app, info = self.make_project_license_bundle(directory)
            included = app / "Contents/Resources/Licenses/KataLog"
            for name in ("GPL-3.0.txt", "NOTICE.txt", "manifest.json"):
                path = included / name
                original = path.read_bytes()
                path.unlink()
                with self.subTest(missing=name), self.assertRaisesRegex(recipe.CheckError, "KataLog license"):
                    # The production bundle check must enforce this, not just a helper test.
                    recipe.Verification(app).inspect_bundle()
                path.write_bytes(original)
            absent_app = Path(directory) / "future.app"
            for version in ("0.6.0", "0.6.0-preview.1", "0.6.1", "0.10.0", "1.0.0"):
                with self.subTest(version=version), self.assertRaisesRegex(recipe.CheckError, "license directory"):
                    recipe.validate_project_license(absent_app, dict(info, CFBundleShortVersionString=version))

    def test_license_and_notice_tampering_cannot_be_hidden_by_rehashing_manifest(self):
        with tempfile.TemporaryDirectory(prefix="katalog-tampered-license-") as directory:
            _, app, info = self.make_project_license_bundle(directory)
            included = app / "Contents/Resources/Licenses/KataLog"
            manifest_path = included / "manifest.json"
            original_manifest = manifest_path.read_bytes()
            for name in ("GPL-3.0.txt", "NOTICE.txt"):
                path = included / name
                original = path.read_bytes()
                for payload in (b"", original + b"\nAltered distribution terms\n"):
                    path.write_bytes(payload)
                    manifest = json.loads(original_manifest)
                    manifest["files"][name] = hashlib.sha256(payload).hexdigest()
                    manifest_path.write_text(json.dumps(manifest))
                    with self.subTest(name=name, empty=not payload), self.assertRaisesRegex(recipe.CheckError, "reviewed text"):
                        recipe.validate_project_license(app, info)
                path.write_bytes(original)
                manifest_path.write_bytes(original_manifest)
            self.assertTrue(recipe.validate_project_license(app, info)["included"])

    def test_license_manifest_cannot_change_release_identity_or_license_scope(self):
        with tempfile.TemporaryDirectory(prefix="katalog-license-manifest-") as directory:
            _, app, info = self.make_project_license_bundle(directory)
            manifest_path = app / "Contents/Resources/Licenses/KataLog/manifest.json"
            original = json.loads(manifest_path.read_text())
            for change in (dict(appVersion="0.5.2"), dict(buildNumber="7"), dict(license="GPL-3.0-or-later"),
                           dict(sourceRepository="https://example.org/unrelated"), dict(copyright="Unknown author")):
                manifest_path.write_text(json.dumps(dict(original, **change)))
                with self.subTest(change=change), self.assertRaisesRegex(recipe.CheckError, "manifest does not match"):
                    recipe.validate_project_license(app, info)
            for payload in ("", "not JSON", "{}"):
                manifest_path.write_text(payload)
                with self.subTest(payload=payload), self.assertRaises(recipe.CheckError):
                    recipe.validate_project_license(app, info)
            manifest_path.write_text(json.dumps(original))
            with self.assertRaisesRegex(recipe.CheckError, "copyright metadata"):
                recipe.validate_project_license(app, dict(info, NSHumanReadableCopyright=""))

    def test_source_license_integrity_and_regular_files_are_required_before_packaging(self):
        with tempfile.TemporaryDirectory(prefix="katalog-license-source-") as directory:
            _, app, info = self.make_project_license_bundle(directory)
            project = Path(directory) / "source"
            source_license = project / "LICENSE"
            original = source_license.read_bytes()
            source_license.unlink()
            with self.assertRaisesRegex(recipe.CheckError, "source license is absent"):
                recipe.write_project_license(project, app)
            for payload in (b"", original + b"Modified GNU terms"):
                source_license.write_bytes(payload)
                with self.subTest(empty=not payload), self.assertRaisesRegex(recipe.CheckError, "official GNU"):
                    recipe.write_project_license(project, app)
            included = app / "Contents/Resources/Licenses/KataLog/GPL-3.0.txt"
            outside = Path(directory) / "external-license.txt"
            outside.write_bytes(original)
            included.unlink()
            included.symlink_to(outside)
            with self.assertRaisesRegex(recipe.CheckError, "absent or invalid"):
                recipe.validate_project_license(app, info)

    def test_historical_052_package_without_project_license_remains_accepted_on_this_gate(self):
        with tempfile.TemporaryDirectory(prefix="katalog-historical-license-") as directory:
            app = Path(directory) / "KataLog.app"
            detail = recipe.validate_project_license(app, dict(CFBundleShortVersionString="0.5.2", CFBundleVersion="7"))
            self.assertFalse(detail["required"])
            self.assertFalse(detail["included"])
            # A newly rebuilt older version includes the notice and cannot skip integrity.
            _, app, info = self.make_project_license_bundle(directory, version="0.5.2", build="7")
            self.assertTrue(recipe.validate_project_license(app, info)["included"])
            (app / "Contents/Resources/Licenses/KataLog/NOTICE.txt").write_bytes(b"")
            with self.assertRaisesRegex(recipe.CheckError, "reviewed text"):
                recipe.validate_project_license(app, info)

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
