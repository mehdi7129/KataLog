"""Packaging regressions using fake binaries; no signing identity, installation or network."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("katalog_sign_bundle", ROOT / "tools/sign-bundle.py")
signer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signer)


class UpdatePackagingTests(unittest.TestCase):
    def test_ui_review_build_refuses_production_output_and_active_feed(self):
        with tempfile.TemporaryDirectory(prefix="katalog-preview-guard-", dir="/private/tmp") as directory:
            work = Path(directory)
            for output, channel in ((work / "dist", "disabled"), (work / "0.6-staging", "stable"), (work / "preview-staging", "stable")):
                env = dict(os.environ, KATALOG_UI_PREVIEW_BUILD="1", KATALOG_VERSION="0.6.0",
                           KATALOG_DIST_DIR=str(output), KATALOG_UPDATE_CHANNEL=channel)
                result = subprocess.run(["/bin/bash", str(ROOT / "tools/build-app.sh")], env=env, capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("preview UI est réservée", result.stderr.decode())
                self.assertFalse(output.exists())

    def test_build_rejects_an_extra_obsolete_compiled_module_before_compilation(self):
        with tempfile.TemporaryDirectory(prefix="katalog-build-stale-module-", dir="/private/tmp") as directory:
            work = Path(directory)
            helper = work / "KataLogEngine.app/Contents"
            (helper / "MacOS").mkdir(parents=True); (helper / "Resources").mkdir()
            executable = helper / "MacOS/KataLogEngine"
            executable.write_text('#!/bin/sh\nprintf \'{"protocol":1}\\n\'\n'); executable.chmod(0o755)
            hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in (ROOT / "Sources/KataLog/Resources").glob("*.py")}
            hashes["obsolete_invented_module.py"] = "0" * 64
            (helper / "Resources/runtime-manifest.json").write_text(json.dumps(dict(sourceHashes=hashes)))
            env = dict(os.environ, KATALOG_ENGINE_PATH=str(helper.parent),
                       KATALOG_BUILD_DIR=str(work / "build"), KATALOG_DIST_DIR=str(work / "dist"))
            result = subprocess.run(["/bin/bash", str(ROOT / "tools/build-app.sh")], env=env, capture_output=True, timeout=90)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("ne correspond pas exactement", result.stderr.decode())
            self.assertFalse((work / "build").exists(), "A mismatched helper must be rejected before compiling")
            self.assertFalse((work / "dist").exists(), "A mismatched helper must never be distributed")

    def test_build_rejects_stale_dependencies_or_dispatcher_before_compilation(self):
        for section, entry in (("requirementsHashes", "requirements-runtime.txt"), ("buildInputHashes", "engine-entry.py")):
            with self.subTest(section=section), tempfile.TemporaryDirectory(prefix="katalog-build-stale-input-", dir="/private/tmp") as directory:
                work = Path(directory)
                helper = work / "KataLogEngine.app/Contents"
                (helper / "MacOS").mkdir(parents=True); (helper / "Resources").mkdir()
                executable = helper / "MacOS/KataLogEngine"
                executable.write_text('#!/bin/sh\nprintf \'{"protocol":1}\\n\'\n'); executable.chmod(0o755)
                manifest = {
                    "sourceHashes": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                     for path in (ROOT / "Sources/KataLog/Resources").glob("*.py")},
                    "requirementsHashes": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                                           for name in ("requirements-runtime.txt", "requirements-runtime-build.txt")},
                    "buildInputHashes": {name: hashlib.sha256((ROOT / "tools" / name).read_bytes()).hexdigest()
                                         for name in ("engine-entry.py", "KataLogEngine.spec")},
                }
                manifest[section][entry] = "0" * 64
                (helper / "Resources/runtime-manifest.json").write_text(json.dumps(manifest))
                env = dict(os.environ, KATALOG_ENGINE_PATH=str(helper.parent),
                           KATALOG_BUILD_DIR=str(work / "build"), KATALOG_DIST_DIR=str(work / "dist"))
                result = subprocess.run(["/bin/bash", str(ROOT / "tools/build-app.sh")], env=env, capture_output=True, timeout=90)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("dépendances ou la configuration", result.stderr.decode())
                self.assertFalse((work / "build").exists())
                self.assertFalse((work / "dist").exists())

    def test_xpc_and_updater_are_signed_before_framework_and_host_app(self):
        with tempfile.TemporaryDirectory(prefix="katalog-sign-order-") as directory:
            app = Path(directory) / "KataLog.app"
            framework = app / "Contents/Frameworks/Sparkle.framework"
            updater = framework / "Updater.app"
            installer = framework / "XPCServices/Installer.xpc"
            for bundle, executable in ((app, "KataLog"), (updater, "Updater"), (installer, "Installer")):
                (bundle / "Contents/MacOS").mkdir(parents=True)
                (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(CFBundleExecutable=executable)))
                (bundle / "Contents/MacOS" / executable).write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")
            (framework / "Sparkle").write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")
            commands = []
            with patch.object(signer.subprocess, "check_output", return_value=""), \
                 patch.object(signer.subprocess, "run", side_effect=lambda args, **kwargs: commands.append(args)):
                signer.sign_bundle(app, "-")
            signed = [Path(command[-1]) for command in commands if "--sign" in command]
            self.assertLess(signed.index(installer), signed.index(framework))
            self.assertLess(signed.index(updater), signed.index(framework))
            self.assertLess(signed.index(framework), signed.index(app))
            self.assertEqual(signed.count(installer), 1)
            self.assertEqual(signed.count(updater), 1)
            self.assertEqual(commands[-1], ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])

    def test_build_compiles_public_source_snapshot_outside_desktop_and_cleans_it_on_failure(self):
        with tempfile.TemporaryDirectory(prefix="katalog-build-isolation-", dir="/private/tmp") as directory:
            work = Path(directory)
            helper = work / "KataLogEngine.app/Contents"
            (helper / "MacOS").mkdir(parents=True)
            (helper / "Resources").mkdir()
            executable = helper / "MacOS/KataLogEngine"
            executable.write_text('#!/bin/sh\nprintf \'{"protocol":1}\\n\'\n')
            executable.chmod(0o755)
            hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in (ROOT / "Sources/KataLog/Resources").glob("*.py")}
            requirements = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                            for name in ("requirements-runtime.txt", "requirements-runtime-build.txt")}
            build_inputs = {name: hashlib.sha256((ROOT / "tools" / name).read_bytes()).hexdigest()
                            for name in ("engine-entry.py", "KataLogEngine.spec")}
            (helper / "Resources/runtime-manifest.json").write_text(json.dumps(dict(sourceHashes=hashes,
                requirementsHashes=requirements, buildInputHashes=build_inputs)))
            binary = work / "bin"; binary.mkdir()
            swift = binary / "swift"
            swift.write_text('#!/bin/sh\nprintf \'%s\\n\' "$PWD" > "$KATALOG_TEST_TRACE"\n'
                             'if [ -e .git ] || [ -e dist ] || [ -e reports ] || [ -e "CARTE SD DRONE" ]; then exit 74; fi\n'
                             'if [ ! -f Package.swift ] || [ ! -f Sources/KataLog/UpdateStore.swift ]; then exit 75; fi\nexit 73\n')
            swift.chmod(0o755)
            trace = work / "trace.txt"
            env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
                       KATALOG_ENGINE_PATH=str(helper.parent), KATALOG_TEST_TRACE=str(trace),
                       KATALOG_BUILD_DIR=str(work / "build"), KATALOG_DIST_DIR=str(work / "dist"))
            result = subprocess.run(["/bin/bash", str(ROOT / "tools/build-app.sh")], env=env, capture_output=True, timeout=90)
            self.assertEqual(result.returncode, 73, "Build should stop only at the synthetic compiler")
            source = Path(trace.read_text().strip())
            self.assertTrue(str(source).startswith("/private/tmp/katalog-source."))
            self.assertFalse(source.exists(), "The temporary source snapshot must be removed after failure")
            self.assertFalse((work / "dist").exists(), "No archive should be created by a failed compilation")


if __name__ == "__main__":
    unittest.main()
