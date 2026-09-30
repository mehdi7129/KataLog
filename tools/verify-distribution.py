#!/usr/bin/env python3
"""Verify a built KataLog app/DMG without installing it or using fleet data.

Only temporary synthetic ULogs and loopback MQTT/HTTP traffic are generated.
Run from the source checkout with Python 3; the app being checked must work
without that Python interpreter, Homebrew, or workstation preferences.
The JSON report contains check categories and counts, never captured log data.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import importlib.util
import json
import marshal
import os
from pathlib import Path
import plistlib
import re
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
import zipfile
from urllib.parse import urlsplit

_mount_spec = importlib.util.spec_from_file_location("katalog_dmg_mount", Path(__file__).with_name("dmg_mount.py"))
dmg_mount = importlib.util.module_from_spec(_mount_spec)
_mount_spec.loader.exec_module(dmg_mount)

PARSER_VERSION = "1.4.0"
SPARKLE_VERSION = "2.10.0"
HELPER_BUNDLE = Path("Contents/Helpers/KataLogEngine.app")
HELPER_EXECUTABLE = HELPER_BUNDLE / "Contents/MacOS/KataLogEngine"
HELPER_MANIFEST = HELPER_BUNDLE / "Contents/Resources/runtime-manifest.json"
PROJECT_LICENSE_DIRECTORY = Path("Contents/Resources/Licenses/KataLog")
PROJECT_LICENSE_SPDX = "GPL-3.0-only"
PROJECT_COPYRIGHT = "Copyright (C) 2026 mehdi7129"
PROJECT_SOURCE_REPOSITORY = "https://github.com/mehdi7129/KataLog"
# Exact bytes of the official GNU text, reviewed when GPL-3.0-only was chosen.
PROJECT_GPL_SHA256 = "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
PROJECT_LICENSE_NOTICE = ("KataLog\n"
    "Copyright (C) 2026 mehdi7129\n"
    "SPDX-License-Identifier: GPL-3.0-only\n\n"
    "KataLog is free software: you can redistribute it and/or modify it under\n"
    "the GNU General Public License, version 3 only. No permission to use a\n"
    "later version is granted by this notice.\n\n"
    "KataLog is distributed WITHOUT ANY WARRANTY; without even the implied\n"
    "warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.\n"
    "See GPL-3.0.txt for the complete license.\n\n"
    "Official source repository:\n"
    "https://github.com/mehdi7129/KataLog\n"
    "Each published binary must provide its matching release tag, source\n"
    "archive and build instructions. A preview is not a published release.\n\n"
    "Official GNU license text:\n"
    "https://www.gnu.org/licenses/gpl-3.0.txt\n\n"
    "Third-party components retain their respective licenses and notices.\n"
    "Sparkle notices are in ../Sparkle-LICENSE.txt; Python runtime notices\n"
    "are in Contents/Helpers/KataLogEngine.app/Contents/Resources/Licenses\n"
    "relative to the application bundle. User data is not program source.\n").encode("utf-8")
MAGIC = b"ULog\x01\x12\x35"
UUID = "0102030405060708090A0B0C"
REMOTE = "/fs/microsd/log/2030-01-01/00_00_00.ulg"
STAGING = "/public/downloads/" + UUID + "_00_00_00.ulg"
USER_PATH_MARKER = b"/" + b"Users/"
MACHO_MAGIC = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
               b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_project_license_source(project: Path) -> bytes:
    """Reject a missing or edited GPL before compiling or signing an app."""
    path = project / "LICENSE"
    if not path.is_file() or path.is_symlink():
        raise CheckError("KataLog source license is absent or not a regular file")
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != PROJECT_GPL_SHA256:
        raise CheckError("KataLog source license differs from the official GNU GPL v3 text")
    return data


def project_license_manifest(info):
    return {
        "schemaVersion": 1,
        "license": PROJECT_LICENSE_SPDX,
        "copyright": PROJECT_COPYRIGHT,
        "sourceRepository": PROJECT_SOURCE_REPOSITORY,
        "appVersion": info.get("CFBundleShortVersionString"),
        "buildNumber": info.get("CFBundleVersion"),
        "files": {
            "GPL-3.0.txt": PROJECT_GPL_SHA256,
            "NOTICE.txt": hashlib.sha256(PROJECT_LICENSE_NOTICE).hexdigest(),
        },
    }


def write_project_license(project: Path, app: Path):
    """Package only public license material; upstream notices stay untouched."""
    data = validate_project_license_source(project)
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["NSHumanReadableCopyright"] = PROJECT_COPYRIGHT + "; " + PROJECT_LICENSE_SPDX
    directory = app / PROJECT_LICENSE_DIRECTORY
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "GPL-3.0.txt").write_bytes(data)
    (directory / "NOTICE.txt").write_bytes(PROJECT_LICENSE_NOTICE)
    (directory / "manifest.json").write_text(
        json.dumps(project_license_manifest(info), indent=2, sort_keys=True) + "\n", encoding="utf-8")
    info_path.write_bytes(plistlib.dumps(info))


def validate_project_license(app: Path, info):
    version = info.get("CFBundleShortVersionString", "")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.]+)?", version):
        raise CheckError("App version is invalid for license verification")
    required = tuple(map(int, re.split(r"[-+]", version, maxsplit=1)[0].split("."))) >= (0, 6, 0)
    directory = app / PROJECT_LICENSE_DIRECTORY
    # Already-built historical packages predate this notice. Rebuilt older
    # versions containing license material must still pass its integrity check.
    if not required and not directory.exists():
        return {"required": False, "included": False, "historicalPackage": True}
    if not directory.is_dir() or directory.is_symlink():
        raise CheckError("Bundled KataLog license directory is absent or invalid")
    for name, expected in project_license_manifest(info)["files"].items():
        path = directory / name
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(app.resolve()):
            raise CheckError("Bundled KataLog license or notice is absent or invalid")
        if sha256(path) != expected:
            raise CheckError("Bundled KataLog license or notice differs from its reviewed text")
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise CheckError("Bundled KataLog license manifest is absent or invalid")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise CheckError("Bundled KataLog license manifest is absent or invalid") from error
    if manifest != project_license_manifest(info):
        raise CheckError("Bundled KataLog license manifest does not match the app or reviewed notices")
    if info.get("NSHumanReadableCopyright") != PROJECT_COPYRIGHT + "; " + PROJECT_LICENSE_SPDX:
        raise CheckError("KataLog copyright metadata is absent or inconsistent")
    return {"required": required, "included": True, "license": PROJECT_LICENSE_SPDX,
            "licenseSHA256": PROJECT_GPL_SHA256, "noticeSHA256": manifest["files"]["NOTICE.txt"]}


SOURCE_UNAVAILABLE_NOTICE = "Source originale actuellement indisponible : résumé et analyses en cache conservés ; consultez l’état des chemins source."


def stable_snapshot_logs(logs):
    """Source states stay meaningful; their observation clock is ephemeral."""
    values = json.loads(json.dumps(logs))
    for log in values:
        for source in log.get("sourceAvailability", []):
            source.pop("checkedAt", None)
    return values


def retained_analysis(detail):
    """Remove only the live source observation, keeping all cached analysis."""
    value = json.loads(json.dumps(detail))
    value.pop("sourceAvailability", None)
    if "coverage" in value:
        value["coverage"] = [notice for notice in value["coverage"] if notice != SOURCE_UNAVAILABLE_NOTICE]
    return value


def synthetic_ulog() -> bytes:
    """A deterministic valid ULog with fabricated GNSS, identity and messages."""
    def record(kind, payload):
        return struct.pack("<HB", len(payload), ord(kind)) + payload

    def info(name, value):
        key = ("char[%d] %s" % (len(value), name)).encode("ascii")
        return record("I", bytes([len(key)]) + key + value)

    data = MAGIC + bytes([1]) + struct.pack("<Q", 1_000_000)
    data += record("F", b"sensor_gps:uint64_t timestamp;uint64_t time_utc_usec;int32_t lat;int32_t lon;int32_t alt;uint8_t fix_type;uint8_t satellites_used;float eph;float epv;")
    data += info("sys_uuid", UUID.encode("ascii"))
    data += info("drone_name", b"Synthetic smoke drone")
    data += info("ver_hw", b"Synthetic hardware")
    key = b"float TEST_PARAM"
    data += record("P", bytes([len(key)]) + key + struct.pack("<f", 1.25))
    data += record("A", struct.pack("<BH", 0, 1) + b"sensor_gps")
    for index in range(3):
        stamp = (index + 1) * 1_000_000
        # Invented coordinates, unrelated to any drone, customer or event.
        values = struct.pack("<HQQiiiBBff", 1, stamp, 1_893_456_000_000_000 + index * 1_000_000,
                             10_000_000 + index, 20_000_000 + index, 100_000, 6, 20, .1, .2)
        data += record("D", values)
    data += record("L", struct.pack("<BQ", 52, 2_000_000) + b"Synthetic GPS warning")
    data += record("L", struct.pack("<BQ", 54, 3_000_000) + b"Synthetic informational message")
    return data


def embedded_payloads(data: bytes):
    """Yield decompressed PyInstaller payloads for privacy inspection.

    Inspecting only executable bytes misses compressed Python co_filename
    strings. Both the executable CArchive and its embedded PYZ are checked.
    Only primitive TOC objects are deserialized; no code is imported/executed.
    """
    cookie_magic = b"MEI\x0c\x0b\x0a\x0b\x0e"
    cookie_position = data.rfind(cookie_magic)
    if cookie_position < 0:
        return
    cookie_size = struct.calcsize("!8sIIII64s")
    if cookie_position + cookie_size > len(data):
        raise ValueError("Incomplete embedded runtime archive")
    _, archive_size, toc_offset, toc_size, _, _ = struct.unpack_from("!8sIIII64s", data, cookie_position)
    start = cookie_position + cookie_size - archive_size
    if start < 0 or toc_offset + toc_size > archive_size:
        raise ValueError("Invalid embedded runtime archive bounds")
    position, end = start + toc_offset, start + toc_offset + toc_size
    while position < end:
        if position + 18 > end:
            raise ValueError("Invalid embedded runtime table")
        length, offset, size, unpacked_size, compressed, kind = struct.unpack_from("!iIIIBc", data, position)
        if length < 18 or position + length > end or start + offset + size > start + toc_offset:
            raise ValueError("Invalid embedded runtime entry")
        name = data[position + 18:position + length].split(b"\x00", 1)[0].decode("utf-8", errors="replace")
        payload = data[start + offset:start + offset + size]
        if compressed:
            payload = zlib.decompress(payload)
        if len(payload) != unpacked_size:
            raise ValueError("Embedded runtime size mismatch")
        yield name, payload
        if payload.startswith(b"PYZ\x00"):
            yield from pyz_payloads(payload, name)
        position += length
    if position != end:
        raise ValueError("Invalid embedded runtime table end")


def pyz_payloads(data: bytes, prefix: str):
    if len(data) < 12:
        raise ValueError("Incomplete Python runtime archive")
    offset = struct.unpack_from("!I", data, 8)[0]
    if not 12 <= offset < len(data):
        raise ValueError("Invalid Python runtime archive table")
    toc = marshal.loads(data[offset:])
    entries = toc.items() if isinstance(toc, dict) else toc
    for name, entry in entries:
        if not isinstance(name, str) or not isinstance(entry, tuple) or len(entry) != 3:
            raise ValueError("Unsupported Python runtime archive table")
        _, position, length = entry
        if not isinstance(position, int) or not isinstance(length, int) or not 12 <= position <= position + length <= offset:
            raise ValueError("Invalid Python runtime module bounds")
        yield prefix + ":" + name, zlib.decompress(data[position:position + length])


class CheckError(Exception):
    pass


def validate_update_info(info):
    """Security flags are checked even for a disabled feed; activation must be explicit."""
    if info.get("KatalogSparkleVersion") != SPARKLE_VERSION:
        raise CheckError("Sparkle version is absent or inconsistent")
    for key in ("SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"):
        if info.get(key) is not True:
            raise CheckError("Signed update security setting is absent: " + key)
    for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling", "SUEnableJavaScript"):
        if info.get(key) is not False:
            raise CheckError("Automatic update or profiling setting is enabled: " + key)
    if type(info.get("SUSignedFeedFailureExpirationInterval")) is not int or info["SUSignedFeedFailureExpirationInterval"] != 0:
        raise CheckError("Signed feed verification allows an unsigned fallback")
    enabled, channel = info.get("KatalogUpdatesEnabled"), info.get("KatalogUpdateChannel")
    if enabled is False:
        if channel != "disabled" or "SUFeedURL" in info or "SUPublicEDKey" in info:
            raise CheckError("Disabled updates contain an active feed or key")
    elif enabled is True and channel in ("stable", "staging"):
        value = info.get("SUFeedURL")
        if not isinstance(value, str):
            raise CheckError("Active updates have no HTTPS feed")
        url = urlsplit(value)
        if (url.scheme != "https" or not url.hostname or ":" in url.hostname or url.username is not None or
                url.password is not None or url.query or url.fragment or url.port not in (None, 443) or
                not url.path.lower().endswith(".xml") or any(ord(c) < 32 for c in value)):
            raise CheckError("Active update feed URL is invalid")
        key = info.get("SUPublicEDKey")
        try:
            data = base64.b64decode(key, validate=True)
        except (ValueError, TypeError) as error:
            raise CheckError("Active update public key is invalid") from error
        if len(data) != 32 or not any(data) or base64.b64encode(data).decode() != key:
            raise CheckError("Active update public key is invalid")
    else:
        raise CheckError("Update activation or channel metadata is invalid")
    return {"sparkleVersion": SPARKLE_VERSION, "updatesEnabled": enabled, "channel": channel,
            "signedFeedRequired": True, "verificationBeforeExtraction": True, "unsignedFallbackAllowed": False}


def inventory_files(output: bytes):
    """Accept legacy output or a complete ordered inventory, never a partial page set."""
    token, expected, next_page, files, complete = None, None, 0, [], False
    for line in output.splitlines():
        if not line.strip():
            continue
        if len(line) > 4 * 1024 * 1024:
            raise CheckError("Inventory frame exceeds local protocol limit")
        event = json.loads(line)
        kind = event.get("event")
        if kind == "inventory":
            if token is not None or complete or not isinstance(event.get("files"), list):
                raise CheckError("Invalid legacy inventory")
            files = event["files"]; complete = True
        elif kind in ("inventory_started", "inventory_page", "inventory_finished"):
            if len(line) + 1 > 256 * 1024 or event.get("uuid") != UUID or complete:
                raise CheckError("Invalid inventory page frame")
            if kind == "inventory_started":
                if token is not None or not isinstance(event.get("inventoryID"), str) or not event["inventoryID"]:
                    raise CheckError("Invalid inventory start")
                token, expected = event["inventoryID"], event.get("totalFiles")
                if type(expected) is not int or not 0 <= expected <= 100_000:
                    raise CheckError("Invalid inventory total")
            elif kind == "inventory_page":
                page = event.get("files")
                if token is None or event.get("inventoryID") != token or event.get("pageIndex") != next_page or not isinstance(page, list) or not 0 < len(page) <= 256:
                    raise CheckError("Invalid or missing inventory page")
                files.extend(page); next_page += 1
                if len(files) > expected:
                    raise CheckError("Inventory page exceeds advertised total")
            else:
                if token is None or event.get("inventoryID") != token or event.get("pageCount") != next_page or event.get("totalFiles") != expected or len(files) != expected:
                    raise CheckError("Incomplete inventory terminal")
                complete = True
    if not complete or len(files) > 100_000 or len({item["path"] for item in files}) != len(files):
        raise CheckError("No complete inventory received")
    return files


class Verification:
    def __init__(self, app: Path, require_notarized=False):
        self.app = app
        self.require_notarized = require_notarized
        self.report = {"schemaVersion": 1, "checks": [], "syntheticDataOnly": True, "externalNetworkUsed": False}

    def check(self, category, function):
        try:
            detail = function()
            self.report["checks"].append({"category": category, "status": "passed", "detail": detail or {}})
            print("OK   " + category)
        except Exception as error:
            # External command diagnostics and fixture data may contain local
            # paths. Keep the saved and printed report deliberately bounded.
            message = str(error) if isinstance(error, CheckError) else type(error).__name__
            self.report["checks"].append({"category": category, "status": "failed", "reason": message})
            print("FAIL " + category + ": " + message)

    @staticmethod
    def command(arguments, *, env=None, timeout=120, cwd=None):
        try:
            result = subprocess.run([str(value) for value in arguments], capture_output=True, env=env,
                                    timeout=timeout, cwd=cwd)
        except subprocess.TimeoutExpired as error:
            raise CheckError("Command timed out") from error
        if result.returncode:
            raise CheckError("Command failed with exit status %d" % result.returncode)
        return result.stdout

    def inspect_bundle(self):
        if not self.app.is_dir() or self.app.suffix != ".app":
            raise CheckError("Expected a macOS app bundle")
        try:
            info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        except (OSError, ValueError) as error:
            raise CheckError("App Info.plist is absent or invalid") from error
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"):
            if not isinstance(info.get(key), str) or not info[key].strip():
                raise CheckError("Missing app metadata: " + key)
        if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.]+)?", info["CFBundleShortVersionString"]) or not info["CFBundleVersion"].isdigit():
            raise CheckError("App version or build number is invalid")
        project_license = validate_project_license(self.app, info)
        if info.get("KatalogBundledEngineRequired") is not True:
            raise CheckError("The app does not require its bundled runtime")
        preview = info.get("KataLogUIReviewPreview", False)
        if not isinstance(preview, bool):
            raise CheckError("The UI preview flag is invalid")
        if preview and (info.get("CFBundleIdentifier") != "com.mehdiguiard.katalog.preview06"
                        or info.get("CFBundleDisplayName") != "KataLog Preview" or self.app.name != "KataLog Preview.app"):
            raise CheckError("The review preview does not have its separate bundle identity and filename")
        helper = self.app / HELPER_EXECUTABLE
        executable = self.app / "Contents/MacOS" / info.get("CFBundleExecutable", "")
        for path in (helper, executable):
            if not path.is_file() or not os.access(path, os.X_OK):
                raise CheckError("A required executable is absent")
        try:
            helper_info = plistlib.loads((self.app / HELPER_BUNDLE / "Contents/Info.plist").read_bytes())
            manifest = json.loads((self.app / HELPER_MANIFEST).read_text())
        except (OSError, ValueError) as error:
            raise CheckError("Embedded helper bundle metadata is absent or invalid") from error
        if helper_info.get("CFBundleExecutable") != "KataLogEngine" or helper_info.get("CFBundlePackageType") != "APPL":
            raise CheckError("Embedded helper is not a proper macOS application bundle")
        if not isinstance(helper_info.get("CFBundleIdentifier"), str) or not helper_info["CFBundleIdentifier"]:
            raise CheckError("Embedded helper bundle identifier is absent")
        if helper_info.get("CFBundleShortVersionString") != PARSER_VERSION or not str(helper_info.get("CFBundleVersion", "")).isdigit():
            raise CheckError("Embedded helper bundle version is inconsistent")
        if helper_info.get("LSBackgroundOnly") is not True or helper_info.get("LSMinimumSystemVersion") != info["LSMinimumSystemVersion"]:
            raise CheckError("Embedded helper launch behavior or macOS minimum is inconsistent")
        if manifest.get("protocol") != 1 or manifest.get("parserVersion") != PARSER_VERSION or manifest.get("architecture") != "arm64":
            raise CheckError("Embedded helper runtime manifest is inconsistent")
        resource_sources = {path.name: sha256(path) for path in (self.app / "Contents/Resources").glob("*.py") if path.is_file()}
        if not resource_sources or manifest.get("sourceHashes") != resource_sources:
            raise CheckError("Embedded compiled modules do not match the packaged Python sources")
        project = Path(__file__).resolve().parents[1]
        requirements = {name: sha256(project / name) for name in ("requirements-runtime.txt", "requirements-runtime-build.txt")}
        build_inputs = {name: sha256(project / "tools" / name) for name in ("engine-entry.py", "KataLogEngine.spec")}
        if manifest.get("requirementsHashes") != requirements or manifest.get("buildInputHashes") != build_inputs:
            raise CheckError("Embedded runtime requirements or build inputs do not match the source snapshot")
        for name in ("THIRD-PARTY-NOTICES.txt", "Licenses"):
            if not (self.app / HELPER_BUNDLE / "Contents/Resources" / name).exists():
                raise CheckError("Embedded helper license information is absent")
        icon = self.app / "Contents/Resources/KataLog.icns"
        if not icon.is_file() or icon.read_bytes()[:4] != b"icns":
            raise CheckError("The app icon is absent or invalid")
        self.report.update(appVersion=info["CFBundleShortVersionString"], buildNumber=info["CFBundleVersion"],
                           minimumMacOS=info["LSMinimumSystemVersion"], appExecutableSHA256=sha256(executable), uiReviewPreview=preview)
        return {"bundleIdentifier": info["CFBundleIdentifier"], "bundledRuntimeRequired": True,
                "helperBundleIdentifier": helper_info["CFBundleIdentifier"], "properHelperAppBundle": True,
                "runtimeManifestProtocol": manifest["protocol"], "sourceModulesVerified": len(resource_sources),
                "projectLicense": project_license}

    def privacy(self):
        bad, files, payloads = [], 0, 0
        root = self.app.resolve()
        denied_extensions = {".ulg", ".ulog", ".tlog", ".csv", ".db", ".sqlite", ".sqlite3", ".sqlite-wal", ".sqlite-shm",
                             ".db-wal", ".db-shm", ".p12", ".pfx", ".key", ".mobileprovision"}
        denied_names = {".ds_store", "library.json", "snapshot.json", "settings.json", "preferences.json", "annotations.json",
                        "views.json", "progress.json", "gcs-settings.json", "gcs-collection.json", "collection-queue.json", "queue.json", "credentials.json"}
        denied_components = {".git", ".ssh", ".aws", "private-notes", "private_notes", "datasets", "local-data", "reports"}
        for path in self.app.rglob("*"):
            relative = str(path.relative_to(self.app))
            if path.is_symlink():
                issue = symlink_issue(path, root)
                if issue:
                    bad.append((relative, issue))
                continue
            if not path.is_file():
                continue
            files += 1
            if (path.suffix.lower() in denied_extensions or path.name.lower() in denied_names
                    or any(part.lower() in denied_components for part in path.relative_to(self.app).parts)):
                bad.append((relative, "private-data-or-key"))
            content = path.read_bytes()
            if USER_PATH_MARKER in content:
                bad.append((relative, "absolute-user-path"))
            if b"-----BEGIN " + b"PRIVATE KEY-----" in content or b"-----BEGIN RSA " + b"PRIVATE KEY-----" in content:
                bad.append((relative, "private-key"))
            if content[:7] == MAGIC:
                bad.append((relative, "raw-ulog"))
            for _, payload in embedded_payloads(content):
                payloads += 1
                if USER_PATH_MARKER in payload:
                    bad.append((relative, "embedded-absolute-user-path"))
            if zipfile.is_zipfile(io.BytesIO(content)):
                with zipfile.ZipFile(io.BytesIO(content)) as archive:
                    for item in archive.infolist():
                        if item.is_dir():
                            continue
                        payloads += 1
                        nested = Path(item.filename)
                        if (nested.suffix.lower() in denied_extensions or nested.name.lower() in denied_names or
                                any(part.lower() in denied_components for part in nested.parts)):
                            bad.append((relative, "zipped-private-data-or-key"))
                        if USER_PATH_MARKER in item.filename.encode("utf-8") or USER_PATH_MARKER in archive.read(item):
                            bad.append((relative, "zipped-absolute-user-path"))
        self.report["privacyFindings"] = [{"path": path, "category": category} for path, category in sorted(set(bad))]
        if bad:
            raise CheckError("%d private artifact or path findings" % len(set(bad)))
        return {"filesInspected": files, "embeddedPayloadsInspected": payloads, "findings": 0}

    def updates(self):
        info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        detail = validate_update_info(info)
        framework = self.app / "Contents/Frameworks/Sparkle.framework"
        framework_info = plistlib.loads((framework / "Resources/Info.plist").read_bytes())
        if framework_info.get("CFBundleShortVersionString") != SPARKLE_VERSION or framework_info.get("CFBundleIdentifier") != "org.sparkle-project.Sparkle":
            raise CheckError("Bundled Sparkle framework version or identifier is inconsistent")
        license_path = self.app / "Contents/Resources/Licenses/Sparkle-LICENSE.txt"
        if not license_path.is_file() or not license_path.read_bytes().strip():
            raise CheckError("Bundled Sparkle license text is absent")
        for relative in ("Sparkle", "Autoupdate", "Updater.app/Contents/MacOS/Updater",
                         "XPCServices/Installer.xpc/Contents/MacOS/Installer", "XPCServices/Downloader.xpc/Contents/MacOS/Downloader"):
            path = framework / relative
            if not path.is_file() or not os.access(path, os.X_OK) or not path.resolve().is_relative_to(self.app.resolve()):
                raise CheckError("A nested Sparkle executable is absent or external")
        executable = self.app / "Contents/MacOS" / info["CFBundleExecutable"]
        dependencies = self.command(["/usr/bin/otool", "-L", executable]).decode()
        load_commands = self.command(["/usr/bin/otool", "-l", executable]).decode()
        if "@rpath/Sparkle.framework/Versions/B/Sparkle" not in dependencies or "@executable_path/../Frameworks" not in load_commands:
            raise CheckError("The app does not resolve its bundled Sparkle framework")
        return dict(detail, nestedExecutables=5, licenseIncluded=True)

    def portable_macho(self):
        binaries, bad = 0, []
        for path in self.app.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            with path.open("rb") as stream:
                if stream.read(4) not in MACHO_MAGIC:
                    continue
            binaries += 1
            text = self.command(["/usr/bin/otool", "-L", path]).decode("utf-8", errors="replace")
            for line in text.splitlines():
                if not line.startswith("\t"):
                    continue
                dependency = line.strip().split(" (", 1)[0]
                if not dependency.startswith(("/System/Library/", "/usr/lib/", "@rpath/", "@loader_path/", "@executable_path/")):
                    bad.append((str(path.relative_to(self.app)), "external-native-dependency"))
            load_commands = self.command(["/usr/bin/otool", "-l", path]).decode("utf-8", errors="replace")
            for rpath in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", load_commands):
                if not rpath.startswith(("@loader_path", "@executable_path", "/System/Library/", "/usr/lib/")):
                    bad.append((str(path.relative_to(self.app)), "nonportable-rpath"))
            advertised = self.report.get("minimumMacOS", "15.0").split(".")
            minimum_supported = tuple(int(value) for value in advertised[:2])
            for block in re.split(r"Load command \d+", load_commands):
                if "cmd LC_BUILD_VERSION" in block:
                    minimum = re.search(r"^\s+minos (\d+)\.(\d+)", block, re.MULTILINE)
                elif "cmd LC_VERSION_MIN_MACOSX" in block:
                    minimum = re.search(r"^\s+version (\d+)\.(\d+)", block, re.MULTILINE)
                else:
                    continue
                if minimum is None or tuple(map(int, minimum.groups())) > minimum_supported:
                    bad.append((str(path.relative_to(self.app)), "inconsistent-macos-minimum"))
            architecture = self.command(["/usr/bin/lipo", "-archs", path]).decode("ascii", errors="replace").split()
            if "arm64" not in architecture:
                bad.append((str(path.relative_to(self.app)), "missing-arm64"))
        self.report["nativeFindings"] = [{"path": path, "category": category} for path, category in sorted(set(bad))]
        if not binaries:
            raise CheckError("No native executable found")
        if bad:
            raise CheckError("%d native portability findings" % len(set(bad)))
        return {"nativeFilesInspected": binaries, "requiredArchitecture": "arm64", "externalDependencies": 0}

    def signature(self):
        self.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", self.app])
        return {"strict": True, "deep": True}

    def notarization(self, path, kind):
        self.command(["/usr/bin/xcrun", "stapler", "validate", path])
        command = ["/usr/sbin/spctl", "--assess", "--type", "execute" if kind == "app" else "open", "--verbose=2"]
        if kind == "dmg":
            command += ["--context", "context:primary-signature"]
        self.command(command + [path])
        return {"ticketAttached": True, "gatekeeperAccepted": True}

    def runtime(self):
        helper = self.app / HELPER_EXECUTABLE
        before = bundle_manifest(self.app)
        with tempfile.TemporaryDirectory(prefix="katalog-runtime-recipe-", dir="/private/tmp") as temporary:
            work = Path(temporary)
            home = work / "home"
            home.mkdir()
            env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "TMPDIR": str(work), "LANG": "en_US.UTF-8"}

            def run(*arguments, timeout=120, environment=env):
                return self.command([helper, *arguments], env=environment, timeout=timeout, cwd=work)

            runtime_info = json.loads(run("--katalog-runtime-info"))
            if runtime_info.get("protocol") != 1 or runtime_info.get("parserVersion") != PARSER_VERSION:
                raise CheckError("Runtime protocol or parser version mismatch")
            if runtime_info.get("frozen") is not True:
                raise CheckError("Runtime is not a frozen autonomous executable")
            manifest = json.loads((self.app / HELPER_MANIFEST).read_text())
            if runtime_info.get("python") != manifest.get("python"):
                raise CheckError("Bundled Python version differs from its runtime manifest")
            for dependency in ("python", "numpy", "pyulog"):
                if not runtime_info.get(dependency):
                    raise CheckError("Missing bundled dependency: " + dependency)
                if dependency != "python" and runtime_info[dependency] != manifest.get("packages", {}).get(dependency):
                    raise CheckError("Bundled dependency differs from its runtime manifest: " + dependency)
            # A frozen app must not be redirected to a workstation Python by
            # inherited shell variables, even when those variables are invalid.
            hostile = dict(env, PYTHONHOME="/nonexistent/katalog-python", PYTHONPATH="/nonexistent/katalog-modules")
            if json.loads(run("--katalog-runtime-info", environment=hostile)) != runtime_info:
                raise CheckError("Inherited Python configuration changes the runtime")
            run("analyzer", "--help")
            run("gcs", "--help")
            source = work / "source"
            source.mkdir()
            payload = synthetic_ulog()
            original = source / "synthetic.ulg"
            original.write_bytes(payload)
            expected_id = hashlib.sha256(payload).hexdigest()
            database, output = work / "library.sqlite", work / "library.json"
            arguments = ["analyzer", "scan", "--folder", str(source), "--database", str(database), "--output", str(output)]
            run(*arguments)
            first = json.loads(output.read_text())
            if len(first.get("logs", [])) != 1:
                raise CheckError("Synthetic import did not produce exactly one log")
            log = first["logs"][0]
            if log["status"] != "ok" or log["id"] != expected_id or log["droneID"] != UUID:
                raise CheckError("Synthetic import identity or parsing failed")
            if len(log.get("messages", [])) != 2 or not any(message["isAlert"] for message in log["messages"]):
                raise CheckError("Synthetic messages or alert were lost")
            if log.get("dateSource") != "gps" or len((log.get("track") or {}).get("points", [])) != 3:
                raise CheckError("Synthetic date or GNSS track was lost")
            if first["importStats"]["imported"] != 1 or first["importStats"]["failed"]:
                raise CheckError("First import statistics are inconsistent")
            (source / "duplicate.ulg").write_bytes(payload)
            run(*arguments)
            second = json.loads(output.read_text())
            if len(second["logs"]) != 1 or second["logs"][0]["id"] != expected_id:
                raise CheckError("Duplicate content was imported twice")
            if second["importStats"]["imported"] != 0 or second["importStats"]["duplicates"] != 1 or second["importStats"]["unchanged"] != 1:
                raise CheckError("Repeat import statistics are inconsistent")
            run("analyzer", "snapshot", "--database", str(database), "--output", str(output))
            if stable_snapshot_logs(json.loads(output.read_text())["logs"]) != stable_snapshot_logs(second["logs"]):
                raise CheckError("Snapshot does not preserve the library")
            run("analyzer", "detail", "--log-id", expected_id, "--database", str(database), "--output", str(output))
            detail = json.loads(output.read_text())
            if detail["metadata"].get("detailParserVersion") != PARSER_VERSION or "TEST_PARAM" not in detail.get("parameters", {}):
                raise CheckError("On-demand details or parameter decoding failed")
            if len(detail.get("topicDetails", [])) != 1 or detail["topicDetails"][0]["sampleCount"] != 3:
                raise CheckError("On-demand topic details failed")
            # Exercise the new source commands in the frozen engine, across
            # separate processes; Python module discovery in development alone
            # would not establish that they are shipped in the helper.
            run("analyzer", "source-folders", "--database", str(database), "--output", str(output))
            folders = json.loads(output.read_text())
            if folders.get("activeCount") != 1 or folders["folders"][0].get("logCount") != 1:
                raise CheckError("Source listing is not global or content-deduplicated")
            run("analyzer", "retire-source", "--folder", str(source), "--database", str(database), "--output", str(output))
            retired = json.loads(output.read_text())
            if retired.get("removed") is not True or retired.get("logsDeleted") is not False or retired.get("originalsDeleted") is not False:
                raise CheckError("Source retirement did not confirm preservation")
            run("analyzer", "snapshot", "--database", str(database), "--output", str(output))
            retired_snapshot = json.loads(output.read_text())
            if retired_snapshot.get("sourceFolders") or [item["id"] for item in retired_snapshot["logs"]] != [expected_id]:
                raise CheckError("Source retirement removed history or retained an active root")
            if original.read_bytes() != payload or (source / "duplicate.ulg").read_bytes() != payload:
                raise CheckError("Source retirement modified original ULogs")
            run("analyzer", "restore-source", "--folder", str(source), "--database", str(database), "--output", str(output))
            run("analyzer", "snapshot", "--database", str(database), "--output", str(output))
            restored = json.loads(output.read_text())
            if restored.get("sourceFolders") != [str(source)] or restored["logs"][0].get("signalAssessment", {}).get("state") not in ("warning", "error", "critical"):
                raise CheckError("Source restoration or packaged signal assessment failed")
            cli_root = work / "native-cli"
            cli_root.mkdir()
            cli_database, cli_output, cli_html = cli_root / "library.sqlite", cli_root / "library.json", cli_root / "report.html"
            cli = self.app / "Contents/MacOS/katalog-cli"
            cli_archive = cli_root / "import-archive"
            cli_arguments = [cli, "--folder", source, "--database", cli_database, "--output", cli_output, "--html", cli_html,
                             "--archive-destination", cli_archive]
            self.command(cli_arguments, env=hostile, timeout=120, cwd=work)
            cli_first = json.loads(cli_output.read_text())
            if len(cli_first.get("logs", [])) != 1 or cli_first["logs"][0]["id"] != expected_id or not cli_html.is_file():
                raise CheckError("Installed CLI fails outside its source checkout")
            cli_archive_result = cli_first.get("archiveResult", {})
            if ((cli_archive / (expected_id + ".ulg")).read_bytes() != payload
                    or cli_archive_result.get("completed") != 2 or cli_archive_result.get("reused") != 1
                    or cli_archive_result.get("failed") != 0 or len(list(cli_archive.glob("*.ulg"))) != 1):
                raise CheckError("Installed CLI did not forward its optional import archive destination")
            self.command(cli_arguments, env=hostile, timeout=120, cwd=work)
            if json.loads(cli_output.read_text())["importStats"]["imported"] != 0:
                raise CheckError("Installed CLI repeat import is not deduplicated")
            original.unlink()
            (source / "duplicate.ulg").unlink()
            run("analyzer", "detail", "--log-id", expected_id, "--database", str(database), "--output", str(output))
            offline = json.loads(output.read_text())
            if (not offline.get("sourceAvailability") or
                    any(source["state"] != "missing" for source in offline["sourceAvailability"]) or
                    SOURCE_UNAVAILABLE_NOTICE not in offline.get("coverage", [])):
                raise CheckError("Disconnected original sources are not explicitly reported missing")
            if retained_analysis(offline) != retained_analysis(detail):
                raise CheckError("Cached details disappear when sources are disconnected")
            advanced = self.advanced_library_recipe(run, work)
            gcs = self.gcs_recipe(run, work, payload)
            if bundle_manifest(self.app) != before:
                raise CheckError("Running the bundled engine modifies its app bundle")
            return {"protocol": 1, "parserVersion": PARSER_VERSION, "dependencies": {name: runtime_info[name] for name in ("python", "numpy", "pyulog")},
                    "systemPATHOnly": True, "isolatedHOME": True, "hostilePythonEnvironmentIgnored": True,
                    "syntheticImport": True, "repeatImportDeduplicated": True, "snapshot": True, "cachedDetails": True,
                    "appBundleUnmodified": True, "installedCLIOutsideCheckout": True,
                    "sourceRetirementAndRestoration": True, "originalULogsPreserved": True,
                    "signalAssessment": True, **advanced, **gcs}

    @staticmethod
    def advanced_library_recipe(run, work):
        """Exercise newly frozen modules through the actual packaged command dispatcher."""
        fixture_path = Path(__file__).resolve().parents[1] / "Tests/fixture_ulog.py"
        spec = importlib.util.spec_from_file_location("katalog_public_ulog_fixture", fixture_path)
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        full = fixture.synthetic_ulog(samples=129)
        # Keep the exact hash metadata and raw event, while requiring the local
        # dictionary import to supply its matching compressed definitions.
        raw, artifact, offset = full[:16], None, 16
        while offset < len(full):
            length, kind = struct.unpack("<HB", full[offset:offset + 3])
            frame = full[offset:offset + 3 + length]
            if kind == ord("M"):
                payload = frame[3:]
                artifact = payload[2 + payload[1]:]
            else:
                raw += frame
            offset += 3 + length
        if artifact is None:
            raise CheckError("Public event fixture has no compressed dictionary")
        root = work / "advanced-library"
        library, source = root / "library", root / "source"
        library.mkdir(parents=True); source.mkdir()
        original = source / "public-event.ulg"
        original.write_bytes(raw)
        identity = hashlib.sha256(raw).hexdigest()
        database = library / "library.sqlite"
        dictionary = root / "all_events.json.xz"
        dictionary.write_bytes(artifact)
        counter = 0

        def invoke(*arguments, request=None):
            nonlocal counter
            counter += 1
            output = root / ("reply-%d.json" % counter)
            options = list(arguments)
            if request is not None:
                input_path = root / ("request-%d.json" % counter)
                input_path.write_text(json.dumps(request))
                options += ["--request", str(input_path)]
            run("analyzer", *options, "--output", str(output))
            return json.loads(output.read_text())

        import_archive = root / "import-archive"
        imported = invoke("scan", "--folder", str(original), "--database", str(database), "--skip-snapshot",
                          "--archive-destination", str(import_archive))
        if imported.get("archiveResult", {}).get("completed") != 1 or (import_archive / (identity + ".ulg")).read_bytes() != raw:
            raise CheckError("Optional archive copy during import failed")
        invoke("ensure-index", "--database", str(database))
        indexed = invoke("indexed-status", "--database", str(database),
                         request={"logIDs": [identity], "parserVersion": PARSER_VERSION})
        if indexed.get("indexVersion") != 1 or len(indexed.get("logs", [])) != 1 or indexed["missing"]:
            raise CheckError("Global SHA preflight failed in the embedded runtime")
        before = invoke("detail", "--log-id", identity, "--database", str(database))
        if before.get("eventDictionary", {}).get("status") != "missing" or before["events"][0]["translationStatus"] != "missing":
            raise CheckError("Raw event was not preserved without its exact dictionary")
        installed = invoke("event-dictionary", "--database", str(database), "--file", str(dictionary))
        if installed.get("dictionaryVersion") != 1 or installed.get("sha256") != hashlib.sha256(artifact).hexdigest():
            raise CheckError("Local exact dictionary installation failed")
        detail = invoke("detail", "--log-id", identity, "--database", str(database))
        if detail["eventDictionary"]["status"] != "ready" or detail["events"][0]["translationStatus"] != "translated":
            raise CheckError("Imported dictionary did not translate its matching event")
        events = invoke("query", "--database", str(database), "--read-only",
                        request={"queryVersion": 1, "kind": "events"})
        if events.get("total") != 1 or events.get("coverage", {}).get("translatedLogs") != 1:
            raise CheckError("Fleet event query or cached coverage failed")
        catalogue = invoke("query", "--database", str(database), "--read-only",
                           request={"queryVersion": 1, "kind": "catalogue"})
        if "INFO" not in catalogue.get("levels", []) or not catalogue.get("families"):
            raise CheckError("Global level/family catalogue failed")
        registry_uuid = "112233445566778899AABBCC"
        (library / "fleet.json").write_text(json.dumps({"schemaVersion": 1, "revision": 1, "drones": [
            {"uuid": registry_uuid, "authorized": True, "name": "Invented no-log drone",
             "lastSeenAtUTC": "2026-02-01T12:03:04Z", "lastSeenSource": "gcs-telemetry"}]}))
        registry = invoke("query", "--database", str(database), "--read-only",
                          request={"queryVersion": 1, "kind": "drones"})
        observed = next((row for row in registry.get("drones", []) if row["id"] == "gcs:" + registry_uuid), None)
        analyzed = next((row for row in registry.get("drones", []) if row["logCount"] == 1), None)
        if (not observed or observed["logCount"] != 0 or observed.get("lastGCSDate") != "2026-02-01T12:03:04Z"
                or observed.get("lastGCSSource") != "gcs-telemetry" or observed.get("sourceStatus") != "none"
                or not analyzed or analyzed.get("sourceStatus") != "present-at-check" or not analyzed.get("sourceCheckedAt")):
            raise CheckError("Dated fleet/source observations failed in the embedded runtime")
        series = invoke("series", "--database", str(database), "--log-id", identity,
                        request={"seriesVersion": 1, "recipe": "battery", "budget": 128})
        if not 0 < series.get("displayedPointCount", 0) <= 128 or not series.get("series"):
            raise CheckError("Bounded battery series extraction failed")
        capture = root / "capture"
        captured = invoke("capture-report", "--database", str(database), "--capture", str(capture),
                          request={"reportVersion": 1, "query": {"queryVersion": 1, "scope": {}},
                                   "mode": "full", "scopeDescription": "Public fixture", "options": {"format": "html", "includeCachedDetails": True}})
        destination = root / "report"
        exported = invoke("export-captured", "--capture", str(capture), "--destination", str(destination))
        if exported.get("logCount") != 1 or captured.get("revision") != exported.get("revision") or not (destination / "manifest.json").is_file():
            raise CheckError("Immutable streaming report preparation failed")
        report_data = json.loads((destination / "rapport.json").read_text())
        if len(report_data.get("logs", [])) != 1 or not report_data["logs"][0].get("events"):
            raise CheckError("Streaming report lost cached event details")
        backup = root / "backup.zip"
        backed_up = invoke("backup", "--library", str(library), "--destination", str(backup), "--include-ulog")
        inspected = invoke("inspect-backup", "--archive", str(backup))
        if backed_up.get("archivedLogCount") != 1 or inspected.get("missingSourceCount") != 0:
            raise CheckError("Complete verified backup lost its original source")
        preflight = backed_up.get("preflight", {})
        if preflight.get("sourceCount") != 1 or preflight.get("sourceBytes") != len(raw) or preflight.get("estimate") != "conservative-peak":
            raise CheckError("Complete backup capacity preflight failed")
        cleaned = invoke("clean-cache", "--database", str(database), "--library", str(library), request={"logIDs": [identity]})
        if cleaned.get("removedCount") != 1 or cleaned.get("originalsDeleted") is not False:
            raise CheckError("Reversible detail-cache cleanup failed")
        restored_cache = invoke("restore-cache", "--database", str(database), "--recovery", cleaned["recoveryDirectory"])
        if restored_cache.get("restoredCount") != 1:
            raise CheckError("Detail-cache recovery failed")
        archive = root / "archive"
        archived = invoke("archive", "--database", str(database), "--library", str(library), "--destination", str(archive), request={"logIDs": [identity]})
        if archived.get("completed") != 1 or (archive / (identity + ".ulg")).read_bytes() != raw or original.read_bytes() != raw:
            raise CheckError("Verified archive changed or lost the original log")
        reassociated = invoke("reassociate", "--database", str(database), "--folder", str(archive))
        if reassociated.get("matched") != 1 or reassociated.get("originalsDeleted") is not False:
            raise CheckError("Source reassociation failed")
        lease = library / ".library-writer.lock"
        lease.write_bytes(b"public stable inode fixture")
        inode = lease.stat().st_ino
        invoke("restore", "--archive", str(backup), "--library", str(library))
        if lease.stat().st_ino != inode or not Path(installed["path"]).is_file():
            raise CheckError("Restore replaced the stable lease inode or lost its dictionary")
        after = invoke("detail", "--log-id", identity, "--database", str(database))
        if after["events"] != detail["events"]:
            raise CheckError("Restore lost exact cached event translation")
        storage = invoke("storage-info", "--database", str(database), "--library", str(library))
        if storage.get("logCount") != 1 or storage.get("originalsDeleted") is not False:
            raise CheckError("Storage catalogue failed after restore")
        versions = invoke("analysis-revisions", "--log-id", identity, "--database", str(database), "--read-only")
        historical = next((row for row in versions.get("revisions", []) if row["kind"] == "detail"), None)
        if versions.get("revisionVersion") != 1 or not historical or not historical.get("createdAt"):
            raise CheckError("Retained analysis revision catalogue failed")
        # Restore creates its own verified ULog copy inside the test library.
        # Remove all copies of this invented fixture, including that restored
        # copy, before proving the retained analysis works without any source.
        for path in root.rglob("*.ulg"):
            if not path.is_symlink() and path.read_bytes() == raw:
                path.unlink()
        database_sha = sha256(database)
        history = invoke("detail", "--log-id", identity, "--revision", historical["id"], "--database", str(database), "--read-only")
        if (history.get("analysisRevision", {}).get("id") != historical["id"]
                or history.get("metadata", {}).get("detailCacheStatus") != "historical"
                or not history.get("sourceAvailability") or any(row["state"] != "missing" for row in history["sourceAvailability"])
                or sha256(database) != database_sha):
            raise CheckError("Source-free historical analysis read mutated or lost its retained revision")
        return {"exactEventDictionary": True, "fleetEventCoverage": True, "globalCatalogue": True,
                "boundedTelemetry": True, "streamingReportData": True, "verifiedCompleteBackup": True,
                "reversibleCacheCleanup": True, "verifiedArchive": True, "sourceReassociation": True,
                "stableLeaseRestore": True, "optionalArchiveAtImport": True, "backupCapacityPreflight": True,
                "datedFleetRegistry": True, "sourceFreeHistoricalRevision": True}

    @staticmethod
    def gcs_recipe(run, work, payload):
        destination = work / "collected"
        destination.mkdir()
        with LoopbackGCS(payload) as server:
            base = ["gcs", "--host", "127.0.0.1", "--port", str(server.port), "--http-port", str(server.http_port),
                    "--uuid", UUID, "--destination", str(destination)]
            files = inventory_files(run(*base, "inventory"))
            if len(files) != 1 or files[0]["isDownloaded"]:
                raise CheckError("Loopback GCS inventory failed")
            arguments = [*base, "download", "--remote", REMOTE, "--size", str(len(payload))]
            events = [json.loads(line) for line in run(*arguments).splitlines()]
            downloaded = next((item for item in events if item.get("event") == "downloaded"), None)
            if downloaded is None or downloaded["cached"] or downloaded["sha256"] != hashlib.sha256(payload).hexdigest():
                raise CheckError("Loopback GCS download failed")
            http_count = server.http_requests
            second = [json.loads(line) for line in run(*arguments).splitlines()]
            cached = next((item for item in second if item.get("event") == "downloaded"), None)
            if cached is None or not cached["cached"] or server.http_requests != http_count:
                raise CheckError("Cached GCS file was downloaded again")
            files = inventory_files(run(*base, "inventory"))
            if not files[0]["isDownloaded"]:
                raise CheckError("Collected file is absent from the cached inventory")
            collected = list(destination.rglob("*.ulg"))
            if len(collected) != 1 or collected[0].read_bytes() != payload or list(destination.rglob("*.part")):
                raise CheckError("Collection destination or finalization is inconsistent")
            return {"loopbackInventory": True, "loopbackDownload": True, "cachedDownloadAvoided": True, "singleDestination": True}

    def dmg(self, path: Path):
        self.command(["/usr/bin/hdiutil", "verify", path])
        self.report["dmgSHA256"] = sha256(path)
        try:
            with dmg_mount.readonly_mount(path, prefix="katalog-dmg-recipe-", command=self.command) as mount:
                layout = validate_dmg_layout(mount, app_name=self.app.name)
                if bundle_manifest(mount / self.app.name) != bundle_manifest(self.app):
                    raise CheckError("DMG app differs from the verified app")
                self.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", mount / self.app.name])
                tickets = {}
                if self.require_notarized:
                    for bundle in (mount / self.app.name, mount / self.app.name / HELPER_BUNDLE):
                        self.command(["/usr/bin/xcrun", "stapler", "validate", bundle])
                    tickets = {"mountedAppTicketAttached": True, "mountedHelperTicketAttached": True}
                return {"imageIntegrity": True, "readOnlyMount": True, "dragToApplications": True,
                        "appMatches": True, **layout, **tickets}
        except dmg_mount.TemporaryMountError as error:
            raise CheckError(str(error)) from error


def bundle_manifest(root: Path):
    result = {}
    for path in root.rglob("*"):
        relative = str(path.relative_to(root))
        if path.is_symlink():
            result[relative] = {"link": os.readlink(path)}
        elif path.is_file():
            result[relative] = {"sha256": sha256(path), "executable": bool(path.stat().st_mode & 0o111)}
    return result


def validate_dmg_layout(mount: Path, app_name="KataLog.app"):
    if app_name not in {"KataLog.app", "KataLog Preview.app"}:
        raise CheckError("Unexpected application filename")
    entries = {item.name for item in mount.iterdir()}
    allowed = {app_name, "Applications", ".background", ".background.png", ".DS_Store", ".VolumeIcon.icns", ".fseventsd", ".Trashes"}
    if entries - allowed or not {app_name, "Applications"} <= entries:
        raise CheckError("Unexpected or missing DMG contents")
    if not (mount / app_name).is_dir() or (mount / app_name).is_symlink():
        raise CheckError("DMG app must be a real application bundle")
    link = mount / "Applications"
    if not link.is_symlink() or os.readlink(link) != "/Applications":
        raise CheckError("DMG Applications link is invalid")
    background = mount / ".background.png"
    if background.exists() or background.is_symlink():
        if background.is_symlink() or not background.is_file() or background.stat().st_size > 16 * 1024 * 1024:
            raise CheckError("DMG background artwork is invalid")
        with background.open("rb") as stream:
            header = stream.read(33)
        if len(header) != 33 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[8:16] != b"\x00\x00\x00\x0dIHDR":
            raise CheckError("DMG background artwork is not a PNG image")
        width, height = struct.unpack_from("!II", header, 16)
        if not 0 < width <= 8192 or not 0 < height <= 8192:
            raise CheckError("DMG background artwork dimensions are invalid")
    return {"backgroundArtwork": ".background.png" in entries or ".background" in entries}


def symlink_issue(path: Path, root: Path):
    """Framework and PyInstaller Resources cross-links must remain portable."""
    target = os.readlink(path)
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError):
        return "broken-or-cyclic-symlink"
    if resolved.is_relative_to(root):
        return None if not os.path.isabs(target) else "absolute-internal-symlink"
    # An explicit system framework reference is the only allowed external
    # framework link. Runtime data and native package links cannot escape.
    if "Frameworks" in path.relative_to(root).parts and str(resolved).startswith("/System/Library/Frameworks/"):
        return None
    return "external-symlink"


def mqtt_packet(kind, payload):
    count, prefix = len(payload), bytes([kind])
    while True:
        value = count % 128
        count //= 128
        prefix += bytes([value | (128 if count else 0)])
        if not count:
            return prefix + payload


def mqtt_string(value):
    data = value.encode("utf-8")
    return struct.pack("!H", len(data)) + data


def mqtt_read(stream):
    def exact(length):
        data = bytearray()
        while len(data) < length:
            chunk = stream.recv(length - len(data))
            if not chunk:
                raise EOFError
            data.extend(chunk)
        return bytes(data)
    kind, length, multiplier = exact(1)[0], 0, 1
    for _ in range(4):
        digit = exact(1)[0]
        length += (digit & 127) * multiplier
        if not digit & 128:
            return kind, exact(length)
        multiplier *= 128
    raise ValueError("Invalid loopback MQTT packet")


class LoopbackGCS:
    """Minimal read-only GCS simulator; sockets bind to localhost only."""
    def __init__(self, payload):
        self.payload = payload
        self.http_requests = 0
        self.forbidden_requests = []

    def __enter__(self):
        simulation = self

        class MQTTServer(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        class MQTTHandler(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.settimeout(5)

                def send(kind, payload):
                    self.request.sendall(mqtt_packet(kind, payload))

                def publish(topic, value):
                    send(0x30, mqtt_string("swarm_manager/" + topic) + json.dumps(value).encode("utf-8"))

                try:
                    kind, _ = mqtt_read(self.request)
                    if kind != 0x10:
                        return
                    send(0x20, b"\x00\x00")
                    while True:
                        kind, payload = mqtt_read(self.request)
                        if kind == 0x82:
                            count, offset = 0, 2
                            while offset < len(payload):
                                length = struct.unpack_from("!H", payload, offset)[0]
                                offset += length + 3
                                count += 1
                            send(0x90, payload[:2] + bytes(count))
                        elif kind == 0x30:
                            length = struct.unpack_from("!H", payload)[0]
                            topic = payload[2:2 + length].decode("utf-8").removeprefix("swarm_manager/")
                            value = json.loads(payload[2 + length:])
                            if value.get("uuid") != UUID:
                                simulation.forbidden_requests.append("unexpected-identity")
                                return
                            if topic == "recv_mqtt_ftp_list_request":
                                root = value.get("path") == "/fs/microsd/log"
                                publish("ftp_list_dir", {"uuid": UUID, "directories": ["2030-01-01"] if root else [],
                                                         "files": [] if root else [["00_00_00.ulg", len(simulation.payload)]]})
                            elif topic == "get_downlad_path":
                                publish("download_path", {"uuid": UUID, "dist_file": REMOTE, "local_file": STAGING})
                            elif topic == "recv_mqtt_ftp_download_request":
                                publish("send_mqtt_ftp_transfer_status", {"uuid": UUID, "opcode": 2, "filename": REMOTE,
                                                                         "bytes_xfer": len(simulation.payload), "bytes_total": len(simulation.payload)})
                                publish("send_mqtt_ftp_end_session", {"uuid": UUID, "opcode": 2, "filename": STAGING, "ret_code": 0})
                            else:
                                simulation.forbidden_requests.append("outside-collection-scope")
                                return
                        elif kind == 0xC0:
                            send(0xD0, b"")
                        elif kind == 0xE0:
                            return
                except (EOFError, OSError):
                    return

        class HTTPHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                simulation.http_requests += 1
                if self.path != "/downloadFile/" + UUID + "_00_00_00.ulg":
                    simulation.forbidden_requests.append("unexpected-http-path")
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(simulation.payload)))
                self.end_headers()
                self.wfile.write(simulation.payload)

            def log_message(self, *args):
                pass

        self.mqtt = MQTTServer(("127.0.0.1", 0), MQTTHandler)
        self.http = ThreadingHTTPServer(("127.0.0.1", 0), HTTPHandler)
        self.port, self.http_port = self.mqtt.server_address[1], self.http.server_address[1]
        for server in (self.mqtt, self.http):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *unused):
        for server in (self.mqtt, self.http):
            server.shutdown()
            server.server_close()
        if self.forbidden_requests:
            raise CheckError("Loopback collector issued a request outside its permitted scope")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--require-notarized", action="store_true")
    args = parser.parse_args(argv)
    verifier = Verification(args.app.resolve(), args.require_notarized)
    verifier.check("bundle-metadata", verifier.inspect_bundle)
    verifier.check("bundle-privacy", verifier.privacy)
    verifier.check("portable-native-runtime", verifier.portable_macho)
    verifier.check("signed-update-infrastructure", verifier.updates)
    verifier.check("strict-code-signature", verifier.signature)
    verifier.check("autonomous-runtime-and-synthetic-import", verifier.runtime)
    if args.require_notarized:
        verifier.check("app-notarization-and-gatekeeper", lambda: verifier.notarization(verifier.app, "app"))
    if args.dmg:
        verifier.check("dmg-integrity-and-installation-layout", lambda: verifier.dmg(args.dmg.resolve()))
        if args.require_notarized:
            verifier.check("dmg-notarization-and-gatekeeper", lambda: verifier.notarization(args.dmg.resolve(), "dmg"))
    success = all(item["status"] == "passed" for item in verifier.report["checks"])
    verifier.report["status"] = "passed" if success else "failed"
    verifier.report["finishedAtUTC"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(verifier.report, indent=2, ensure_ascii=False) + "\n")
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
