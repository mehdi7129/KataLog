#!/usr/bin/env python3
"""Exercise Sparkle installation/relaunch on two disposable synthetic apps.

The signed local HTTP feed qualifies SDK mechanics only. Production KataLog
continues to require HTTPS; no public feed, real library, installed app, or
Keychain item is changed. Run on a logged-in macOS session, with the official
Sparkle SDK previously resolved by SwiftPM. No windows are presented.
"""
import argparse
import functools
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET
from contextlib import contextmanager

PROJECT = Path(__file__).resolve().parent.parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def command(args, **kwargs):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, timeout=120, **kwargs)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf8", "replace")[-4000:])
    return result.stdout.decode("utf8", "replace").strip()


def hashes(root):
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(root.rglob("*")) if path.is_file() and not path.is_symlink()}


def events(root):
    try:
        return [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines() if line.strip()]
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def owned_process_ids(root):
    # Only fixture executables or helpers with this exact generated directory
    # in their command line. No user app, global process name, or unrelated PID.
    table = command(["/bin/ps", "-axo", "pid=,command="])
    result = []
    for line in table.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and str(root) in fields[1]:
            pid = int(fields[0])
            if pid != os.getpid():
                result.append(pid)
    return result


def terminate_owned(root):
    for termination in (signal.SIGTERM, signal.SIGKILL):
        for pid in owned_process_ids(root):
            try:
                os.kill(pid, termination)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 3
        while owned_process_ids(root) and time.monotonic() < deadline:
            time.sleep(0.1)
        if not owned_process_ids(root):
            return
    raise RuntimeError("A fixture-owned updater helper remained running after cleanup.")


@contextmanager
def isolated_install_volume(root, enabled):
    """Bound ENOSPC to one owned 128 MiB image, never the system volume."""
    if not enabled:
        yield None
        return
    image, mount = root / "install-volume.dmg", root / "install-volume"
    mount.mkdir()
    command(["/usr/bin/hdiutil", "create", "-quiet", "-size", "128m", "-fs", "HFS+",
             "-volname", "KataLog updater fixture", image])
    command(["/usr/bin/hdiutil", "attach", "-nobrowse", "-noautoopen", "-mountpoint", mount, image])
    try:
        # Prevent indexing of this generated fixture volume.
        (mount / ".metadata_never_index").touch()
        yield mount
    finally:
        terminate_owned(root)
        command(["/usr/bin/hdiutil", "detach", mount])


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, failure=None, **kwargs):
        self.failure = failure
        super().__init__(*args, **kwargs)

    def do_GET(self):
        self.server.recorded_paths.append(self.path)
        if self.failure == "interrupted-download" and self.path.split("?", 1)[0] == "/update.zip":
            payload = Path(self.translate_path(self.path)).read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload[:max(1, len(payload) // 4)]); self.wfile.flush()
            # A deterministic truncated network response, never a real drone,
            # interface, route, download or user's active connection.
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        super().do_GET()

    def log_message(self, format, *args):
        pass


def recipe(sdk, timeout, tamper=None, failure=None, space_phase="download"):
    framework = sdk / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    signer = sdk / "bin/sign_update"
    license = sdk / "LICENSE"
    if not license.is_file() and len(sdk.parents) > 2:
        license = sdk.parents[2] / "checkouts/Sparkle/LICENSE"
    if not framework.is_dir() or not signer.is_file():
        raise ValueError("Official Sparkle SDK framework and sign_update are required.")
    if not license.is_file():
        raise ValueError("Official SDK licence or pinned SwiftPM checkout licence is required.")
    if plistlib.loads((framework / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"] != "2.10.0":
        raise ValueError("This recipe requires the pinned Sparkle 2.10.0 SDK.")
    with tempfile.TemporaryDirectory(prefix="katalog-update-install-") as temporary, \
         isolated_install_volume(Path(temporary).resolve(), failure == "insufficient-space") as install_volume:
        root = Path(temporary).resolve()
        server_root = root / "feed"; server_root.mkdir()
        home = root / "home"; home.mkdir()
        data = root / "synthetic-user-data"; data.mkdir()
        database = sqlite3.connect(data / "library.sqlite")
        database.execute("CREATE TABLE synthetic_logs(id TEXT PRIMARY KEY, stock TEXT)")
        database.execute("INSERT INTO synthetic_logs VALUES('invented-controller', 'TEST-001')")
        database.commit(); database.close()
        for name, content in {
            "annotations.json": {"invented-controller": {"label": "Invented test drone", "note": "Keep this note"}},
            "saved-views.json": {"views": [{"name": "Test view", "families": ["battery"]}]},
            "gcs-queue.json": {"version": 1, "tasks": [{"key": "invented-log", "status": "completed"}]},
            "preferences.json": {"collectionFolder": str(data / "collection"), "appearance": "dark"},
        }.items():
            (data / name).write_text(json.dumps(content))
        collection = data / "collection"; collection.mkdir()
        fixture_spec = importlib.util.spec_from_file_location("katalog_update_fixture", PROJECT / "Tests/fixture_ulog.py")
        fixture = importlib.util.module_from_spec(fixture_spec); fixture_spec.loader.exec_module(fixture)
        (collection / "synthetic.ulg").write_bytes(fixture.synthetic_ulog(drone_name="Invented update fixture", samples=8))
        before = hashes(data)
        installed = Path("/Applications/KataLog.app")
        protected = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                     for path in [installed / "Contents/Info.plist", installed / "Contents/MacOS/KataLog"] if path.is_file()}
        key_script = root / "key.swift"
        key_script.write_text('import Foundation\nimport CryptoKit\nlet key = Curve25519.Signing.PrivateKey()\ntry key.rawRepresentation.base64EncodedString().write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)\nprint(key.publicKey.rawRepresentation.base64EncodedString())\n')
        key = root / "ephemeral.seed"
        public = command(["/usr/bin/swift", key_script, key]); key.chmod(0o600)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(server_root), failure=failure))
        server.recorded_paths = []
        feed_url = f"http://127.0.0.1:{server.server_port}/appcast.xml"
        bundle_id = "org.example.KataLogUpdateFixture." + uuid.uuid4().hex
        binary = root / "UpdateFixture"
        command(["/usr/bin/clang", "-fobjc-arc", "-fblocks", "-mmacosx-version-min=15.0", "-F", framework.parent,
                 "-framework", "Sparkle", "-framework", "Foundation", "-framework", "AppKit",
                 "-Wl,-rpath,@executable_path/../Frameworks", PROJECT / "Tests/fixtures/sparkle-update-driver.m", "-o", binary])
        apps = []
        for version, destination in [("1", root / "installed"), ("2", root / "new")]:
            app = destination / "UpdateFixture.app"
            contents = app / "Contents"; (contents / "MacOS").mkdir(parents=True)
            (contents / "Frameworks").mkdir(); (contents / "Resources").mkdir()
            shutil.copy2(binary, contents / "MacOS/UpdateFixture")
            command(["/usr/bin/ditto", "--norsrc", framework, contents / "Frameworks/Sparkle.framework"])
            shutil.copy2(license, contents / "Resources/Sparkle-LICENSE.txt")
            (contents / "Resources/version.txt").write_text(version)
            if version == "2" and install_volume is not None:
                (contents / "Resources/synthetic-space-payload.bin").write_bytes(os.urandom(8 * 1024 * 1024))
            info = {"CFBundleIdentifier": bundle_id, "CFBundleName": "UpdateFixture", "CFBundleExecutable": "UpdateFixture",
                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": f"0.0.{version}", "CFBundleVersion": version,
                    "LSMinimumSystemVersion": "15.0", "LSBackgroundOnly": True, "KataLogUpdateTestRoot": str(root),
                    "SUFeedURL": feed_url, "SUPublicEDKey": public, "SURequireSignedFeed": True,
                    "SUSignedFeedFailureExpirationInterval": 0, "SUVerifyUpdateBeforeExtraction": True,
                    "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False, "SUAllowsAutomaticUpdates": False,
                    "SUEnableSystemProfiling": False, "SUEnableJavaScript": False,
                    "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            command(["/usr/bin/python3", PROJECT / "tools/sign-bundle.py", "--app", app, "--identity", "-"])
            apps.append(app)
        volume_before = None
        if install_volume is not None:
            mounted_app = install_volume / "UpdateFixture.app"
            command(["/usr/bin/ditto", "--norsrc", apps[0], mounted_app])
            apps[0] = mounted_app
            # The SDK download cache and temporary extraction path belong to
            # the same small image. This makes the space error observable by
            # the still-running host, before application termination.
            if space_phase == "download":
                home = install_volume / "home"; home.mkdir()
                (home / "Library/Caches").mkdir(parents=True)
                (install_volume / "tmp").mkdir()
            usage = shutil.disk_usage(install_volume)
            if not 100 * 1024 * 1024 <= usage.total <= 129 * 1024 * 1024:
                raise AssertionError("The owned fixture volume is not bounded to 128 MiB.")
            reserve = 1024 * 1024
            remaining = max(0, usage.free - reserve)
            with (install_volume / "owned-filler.bin").open("wb") as filler:
                block = bytes(1024 * 1024)
                while remaining:
                    chunk = block[:min(len(block), remaining)]
                    filler.write(chunk); remaining -= len(chunk)
                filler.flush(); os.fsync(filler.fileno())
            volume_before = shutil.disk_usage(install_volume)
            if volume_before.free >= 8 * 1024 * 1024:
                raise AssertionError("The fixture did not reach the injected space shortage.")
        before_old_app = hashes(apps[0])
        archive = server_root / "update.zip"
        command(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--keepParent", apps[1], archive])
        signature = command([signer, "--ed-key-file", key, "-p", archive])
        rss = ET.Element("rss", version="2.0"); channel = ET.SubElement(rss, "channel")
        ET.SubElement(channel, "title").text = "Disposable installation recipe"
        item = ET.SubElement(channel, "item"); ET.SubElement(item, "title").text = "Synthetic version 2"
        ET.SubElement(item, "{" + SPARKLE + "}version").text = "2"
        ET.SubElement(item, "{" + SPARKLE + "}shortVersionString").text = "0.0.2"
        ET.SubElement(item, "{" + SPARKLE + "}minimumSystemVersion").text = "15.0"
        ET.SubElement(item, "enclosure", {"url": feed_url.replace("appcast.xml", "update.zip"), "length": str(archive.stat().st_size),
                                         "type": "application/octet-stream", "{" + SPARKLE + "}edSignature": signature})
        feed = server_root / "appcast.xml"; feed.write_bytes(ET.tostring(rss, encoding="utf8", xml_declaration=True))
        command([signer, "--ed-key-file", key, "--disable-signing-warning", feed])
        command([signer, "--ed-key-file", key, "--verify", feed])
        if tamper == "archive":
            payload = bytearray(archive.read_bytes()); payload[-1] ^= 1; archive.write_bytes(payload)
        elif tamper == "feed":
            feed.write_bytes(feed.read_bytes().replace(b"Synthetic version 2", b"Synthetic version X"))
        if failure == "missing-asset":
            archive.unlink()
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        env = {key: value for key, value in os.environ.items() if not key.startswith(("PYTHON", "DYLD_"))}
        env.update(HOME=str(home), CFFIXED_USER_HOME=str(home),
                   TMPDIR=str(install_volume / "tmp") if install_volume is not None and space_phase == "download" else str(root),
                   PATH="/usr/bin:/bin:/usr/sbin:/sbin")
        process = None
        diagnostics = None
        post_quit_attestation = False
        try:
            with (root / "process.log").open("wb") as log:
                process = subprocess.Popen([str(apps[0] / "Contents/MacOS/UpdateFixture")], cwd=root, env=env, stdout=log, stderr=log)
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    current = events(root)
                    if any(item["event"] == "relaunchVerified" for item in current):
                        break
                    errors = [item for item in current if item["event"] in ("error", "startError", "notFound", "timeout")]
                    if errors:
                        if (tamper or failure) and any(item["event"] == "error" for item in errors):
                            break
                        raise RuntimeError(json.dumps(errors))
                    if process.poll() is not None and not any(item["event"] == "willRelaunch" for item in current):
                        raise RuntimeError("Fixture exited before installation: " + (root / "process.log").read_text(errors="replace")[-4000:])
                    time.sleep(0.2)
                else:
                    # Keep transaction evidence even when the host has quit
                    # and the installer's error cannot reach its user driver.
                    diagnostics = {"phase": [item["event"] for item in events(root)],
                                   "hostExitCode": process.poll(),
                                   "previousBundlePresent": apps[0].is_dir(),
                                   "previousBundlePreserved": apps[0].is_dir() and hashes(apps[0]) == before_old_app,
                                   "syntheticDataFilesPreserved": len(before) if hashes(data) == before else 0,
                                   "helpersBeforeCleanup": len(owned_process_ids(root)),
                                   "installerLogTail": (root / "process.log").read_text(errors="replace")[-6000:]}
                    if failure == "insufficient-space" and space_phase == "install":
                        if (diagnostics["hostExitCode"] != 0 or not diagnostics["previousBundlePreserved"]
                                or diagnostics["syntheticDataFilesPreserved"] != 6
                                or diagnostics["helpersBeforeCleanup"] != 0
                                or "terminate" not in diagnostics["phase"]
                                or "willRelaunch" not in diagnostics["phase"]
                                or "relaunchVerified" in diagnostics["phase"]):
                            error = AssertionError("Installation space probe did not preserve an integral usable prior version")
                            error.diagnostics = diagnostics; raise error
                        command([apps[0] / "Contents/MacOS/UpdateFixture", "--verify-preserved-app"], env=env)
                        diagnostics["previousVersionLaunchVerified"] = any(item["event"] == "preservedAppUsable" for item in events(root))
                        if not diagnostics["previousVersionLaunchVerified"]:
                            raise AssertionError("The preserved version could not start")
                        post_quit_attestation = True
                    else:
                        error = TimeoutError("SDK installation/relaunch timeout")
                        error.diagnostics = diagnostics; raise error
            current = events(root)
            installed_version = plistlib.loads((apps[0] / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
            rejected = tamper or failure
            if rejected:
                if installed_version != "1" or any(item["event"] == "relaunchVerified" or
                                                     (item["event"] == "ready" and not post_quit_attestation) for item in current):
                    raise AssertionError("Failed update reached installation.")
                if not post_quit_attestation and not any(item["event"] == "error" for item in current):
                    raise AssertionError("Failed update was not rejected by the running SDK.")
                if hashes(apps[0]) != before_old_app:
                    raise AssertionError("A failed update changed the previous app bundle.")
                if failure in ("interrupted-download", "missing-asset") and ("download" not in [item["event"] for item in current] or "/update.zip" not in server.recorded_paths):
                    raise AssertionError("The fixture did not reach the injected asset failure.")
                if failure == "insufficient-space" and space_phase == "download":
                    space_errors = [item for item in current if item["event"] == "error"]
                    if not any("space" in item.get("description", "").lower() or
                               any(error.get("code") in (28, 640) for error in item.get("underlying", []))
                               for item in space_errors):
                        raise AssertionError("The SDK rejection did not report the injected space shortage.")
            elif installed_version != "2":
                raise AssertionError("Installed fixture version did not advance.")
            if not rejected and hashes(apps[0]) != hashes(apps[1]):
                raise AssertionError("Installed fixture differs from the signed update bundle.")
            if hashes(data) != before:
                raise AssertionError("Synthetic library/settings/log data changed during update.")
            if any(hashlib.sha256(Path(path).read_bytes()).hexdigest() != value for path, value in protected.items()):
                raise AssertionError("Protected installed KataLog app changed.")
            command(["/usr/bin/codesign", "--verify", "--deep", "--strict", apps[0]])
            result = {"passed": True, "sdkVersion": "2.10.0", "transport": "signed-loopback-http-test-only",
                    "productionHTTPSQualified": False, "fromBuild": "1", "toBuild": installed_version,
                    "versionReplaced": not rejected, "relaunchedNewVersion": not rejected,
                    "installedBundleMatchesSignedArchive": not rejected, "signatureStrict": True,
                    "tamperedPayloadRejected": tamper,
                    "injectedDownloadFailure": failure, "previousBundlePreserved": bool(rejected),
                    "assetRequested": "/update.zip" in server.recorded_paths,
                    "syntheticDataFilesPreserved": len(before), "installedKataLogUnchanged": True,
                    "keychainWrites": False, "events": [item["event"] for item in current]}
            if post_quit_attestation:
                result["postQuitTransaction"] = {**diagnostics, "errorCallbackObserved": False,
                                                 "strictSignatureVerified": True,
                                                 "installerErrorCauseObserved": False}
            if volume_before is not None:
                result["spaceFailure"] = {"volumeBytes": volume_before.total, "freeBytesAtStart": volume_before.free,
                          "syntheticAdditionalBytes": 8 * 1024 * 1024,
                          "phase": [item["event"] for item in current], "systemVolumeFilled": False,
                          "sdkErrors": [item for item in current if item["event"] == "error"]}
            return result
        finally:
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait(timeout=5)
            terminate_owned(root)
            if diagnostics is not None:
                diagnostics["helpersAfterCleanup"] = len(owned_process_ids(root))
                diagnostics["previousBundlePreservedAfterCleanup"] = apps[0].is_dir() and hashes(apps[0]) == before_old_app
            if "result" in locals():
                result["ownedHelpersAfterCleanup"] = len(owned_process_ids(root))
                if volume_before is not None:
                    result["spaceFailure"]["volumeDetached"] = True
            server.shutdown(); server.server_close(); thread.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=180)
    errors = parser.add_mutually_exclusive_group()
    errors.add_argument("--tamper", choices=("archive", "feed"), help="Require the running SDK to reject a modified signed payload.")
    errors.add_argument("--failure", choices=("interrupted-download", "missing-asset", "insufficient-space"), help="Preserve the previous app/data after a bounded local update failure.")
    parser.add_argument("--space-phase", choices=("download", "install"), default="download",
                        help="Put the bounded volume under the download cache or only the installation target.")
    args = parser.parse_args()
    try:
        if args.space_phase != "download" and args.failure != "insufficient-space":
            parser.error("--space-phase install requires --failure insufficient-space")
        result = recipe(args.sdk.resolve(), args.timeout, args.tamper, args.failure, args.space_phase)
    except Exception as error:
        result = {"passed": False, "error": str(error), "productionHTTPSQualified": False}
        if hasattr(error, "diagnostics"):
            result["diagnostics"] = error.diagnostics
    args.summary.parent.mkdir(parents=True, exist_ok=True)
    args.summary.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
