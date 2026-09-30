#!/usr/bin/env python3
"""Configure and prepare Sparkle updates locally. Never uploads or publishes anything.

Only public update metadata enters Info.plist. Signing uses Sparkle's official
sign_update and a dedicated Keychain account. Private keys never enter argv.
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET
import zipfile

SPARKLE_VERSION = "2.10.0"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ROOT = Path(__file__).resolve().parents[1]


def https_url(value):
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or ":" in parsed.hostname or parsed.username is not None or
            parsed.password is not None or parsed.query or parsed.fragment or parsed.port not in (None, 443) or
            any(ord(c) < 32 for c in value)):
        raise ValueError("Une adresse HTTPS sans identifiants ni paramètres est requise.")
    return value


def public_key(value):
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("Clé publique EdDSA invalide.") from error
    if len(raw) != 32 or not any(raw) or base64.b64encode(raw).decode() != value:
        raise ValueError("La clé publique EdDSA doit contenir 32 octets.")
    return value


def configured_info(info, channel="disabled", feed_url=None, key=None):
    if channel not in ("disabled", "stable", "staging"):
        raise ValueError("Canal de mise à jour invalide.")
    if info.get("KataLogUIReviewPreview") is True and channel != "disabled":
        raise ValueError("Une candidate de review UI ne peut pas activer le feed de mise à jour.")
    result = dict(info)
    result.update(KatalogSparkleVersion=SPARKLE_VERSION, KatalogUpdateChannel=channel,
                  KatalogUpdatesEnabled=channel != "disabled", SUEnableAutomaticChecks=False,
                  SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                  SUEnableSystemProfiling=False, SUEnableJavaScript=False,
                  SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                  SUSignedFeedFailureExpirationInterval=0)
    if channel == "disabled":
        if feed_url or key:
            raise ValueError("Le canal désactivé ne doit pas contenir de flux ni de clé.")
        result.pop("SUFeedURL", None); result.pop("SUPublicEDKey", None)
    else:
        if not feed_url or not key or not urlsplit(https_url(feed_url)).path.lower().endswith(".xml"):
            raise ValueError("Un flux XML HTTPS et une clé publique sont requis pour activer les mises à jour.")
        result["SUFeedURL"] = feed_url; result["SUPublicEDKey"] = public_key(key)
    return result


def atomic_bytes(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".katalog-update-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def tool(arguments):
    # Diagnostics can contain Keychain errors and local paths; do not copy them into logs.
    result = subprocess.run([str(item) for item in arguments], capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError("L’outil Sparkle ou la vérification de distribution a échoué.")
    return result.stdout.decode("utf8").strip()


def private_file_public_key(path):
    try:
        raw = base64.b64decode(path.read_bytes().strip(), validate=True)
    except (ValueError, OSError) as error:
        raise ValueError("Le fichier de clé privé ne contient pas une seed Sparkle valide.") from error
    if len(raw) != 32:
        raise ValueError("Utilisez une seed exportée par Sparkle 2.10, ou le compte Keychain dédié.")
    # CryptoKit only prints the public key. The private seed is passed through stdin, never argv.
    script = 'import Foundation; import CryptoKit; let text = readLine()!; let data = Data(base64Encoded: text)!; let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data); print(key.publicKey.rawRepresentation.base64EncodedString())'
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH="/private/tmp/katalog-update-crypto-cache",
                       XDG_CACHE_HOME="/private/tmp/katalog-update-crypto-xdg-cache")
    result = subprocess.run(["/usr/bin/swift", "-module-cache-path", "/private/tmp/katalog-update-crypto-cache", "-e", script],
                            input=base64.b64encode(raw) + b"\n", capture_output=True, timeout=120, env=environment)
    if result.returncode:
        raise ValueError("La clé publique du fichier privé n’a pas pu être vérifiée.")
    return public_key(result.stdout.decode().strip())


def archive_info(archive):
    if archive.suffix.lower() != ".zip" or not archive.is_file():
        raise ValueError("Une archive ZIP KataLog finale est requise pour la mise à jour.")
    with zipfile.ZipFile(archive) as source:
        if "KataLog Preview.app/Contents/Info.plist" in source.namelist():
            raise ValueError("La preview UI ne peut pas devenir une archive de mise à jour publique.")
        entry = source.getinfo("KataLog.app/Contents/Info.plist")
        if entry.file_size > 64 * 1024:
            raise ValueError("Métadonnées de l’archive trop grandes.")
        info = plistlib.loads(source.read(entry))
    if (info.get("KataLogUIReviewPreview") is True or info.get("CFBundleIdentifier") != "com.mehdiguiard.katalog" or
            not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(info.get("CFBundleShortVersionString", ""))) or
            not re.fullmatch(r"[0-9]+", str(info.get("CFBundleVersion", "")))):
        raise ValueError("Identifiant ou version de l’archive KataLog invalide.")
    return info


def feed_xml(info, archive_url, archive_size, notes, channel, signature=None):
    if channel not in ("stable", "staging"):
        raise ValueError("Un canal stable ou staging est requis.")
    https_url(archive_url)
    if not urlsplit(archive_url).path.lower().endswith(".zip"):
        raise ValueError("L’adresse de l’archive doit désigner un ZIP final.")
    if len(notes.encode("utf8")) > 128 * 1024 or ("/" + "Users/") in notes:
        raise ValueError("Les notes de version sont trop grandes ou contiennent un chemin personnel.")
    rss = ET.Element("rss", version="2.0")
    channel_node = ET.SubElement(rss, "channel")
    ET.SubElement(channel_node, "title").text = "KataLog · " + channel
    item = ET.SubElement(channel_node, "item")
    ET.SubElement(item, "title").text = "KataLog " + info["CFBundleShortVersionString"]
    ET.SubElement(item, "{" + SPARKLE + "}version").text = str(info["CFBundleVersion"])
    ET.SubElement(item, "{" + SPARKLE + "}shortVersionString").text = info["CFBundleShortVersionString"]
    ET.SubElement(item, "{" + SPARKLE + "}minimumSystemVersion").text = "15.0.0"
    ET.SubElement(item, "{" + SPARKLE + "}hardwareRequirements").text = "arm64"
    if channel == "staging":
        ET.SubElement(item, "{" + SPARKLE + "}channel").text = "staging"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, "description").text = "<p>" + html.escape(notes).replace("\n", "<br>") + "</p>"
    attributes = dict(url=archive_url, length=str(archive_size), type="application/octet-stream")
    if signature:
        raw = base64.b64decode(signature, validate=True)
        if len(raw) != 64:
            raise ValueError("Signature EdDSA de l’archive invalide.")
        attributes["{" + SPARKLE + "}edSignature"] = signature
    ET.SubElement(item, "enclosure", attributes)
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


def prepare(archive, archive_url, output, notes, channel, *, draft=False, sign_update=None,
            private_key_file=None, previous_build=None):
    info = archive_info(archive)
    https_url(archive_url)
    if unquote(urlsplit(archive_url).path.rsplit("/", 1)[-1]) != archive.name:
        raise ValueError("L’adresse publique doit utiliser le nom exact de l’archive finale.")
    if not draft and previous_build is None:
        raise ValueError("Le build précédent est requis pour préparer un flux signé ; utilisez 0 pour le premier flux.")
    if previous_build is not None and previous_build < 0:
        raise ValueError("Le build précédent ne peut pas être négatif.")
    if previous_build is not None and int(info["CFBundleVersion"]) <= previous_build:
        raise ValueError("Le numéro de build doit augmenter ; un downgrade ne doit pas entrer dans le flux.")
    if not draft and (info.get("KatalogUpdatesEnabled") is not True or info.get("KatalogUpdateChannel") != channel):
        raise ValueError("L’archive doit activer le même canal que son flux.")
    if not draft:
        expected = configured_info(info, channel, info.get("SUFeedURL"), info.get("SUPublicEDKey"))
        if any(info.get(key) != value for key, value in expected.items()):
            raise ValueError("La configuration signée de l’archive n’est pas valide.")
        if sign_update is None or not sign_update.is_file():
            raise ValueError("L’outil officiel sign_update de Sparkle 2.10.0 est requis.")
    signing = [sign_update, "--account", "katalog-sparkle-" + channel] if sign_update else []
    if private_key_file is not None:
        key_path = private_key_file.resolve()
        if key_path.is_relative_to(ROOT) or key_path.is_relative_to(output.resolve()):
            raise ValueError("Une clé privée ne doit jamais être placée dans le dépôt ou le dossier de flux.")
        signing = [sign_update, "--ed-key-file", key_path]
    if not draft:
        if private_key_file is None:
            generate_keys = sign_update.parent / "generate_keys"
            actual_public = tool([generate_keys, "--account", "katalog-sparkle-" + channel, "-p"])
            if public_key(actual_public) != info["SUPublicEDKey"]:
                raise ValueError("La clé de signature ne correspond pas à la clé publique embarquée.")
        elif private_file_public_key(private_key_file) != info["SUPublicEDKey"]:
            raise ValueError("La clé du fichier privé ne correspond pas à la clé publique embarquée.")
    output.mkdir(parents=True, exist_ok=True)
    destination = output / ("appcast.draft.xml" if draft else "appcast.xml")
    staged_destination = output / archive.name
    if destination.exists() or staged_destination.exists() or (output / "update-manifest.json").exists():
        raise ValueError("Le flux existe déjà. Choisissez un nouveau dossier de préparation.")
    with tempfile.TemporaryDirectory(prefix="katalog-appcast-", dir=output) as temporary:
        staged_archive = Path(temporary) / archive.name
        shutil.copyfile(archive, staged_archive)
        if archive_info(staged_archive) != info:
            raise ValueError("L’archive a changé pendant la préparation.")
        signature = None
        if not draft:
            signature = tool([*signing, "-p", staged_archive])
            tool([*signing, "--verify", staged_archive, signature])
        candidate = Path(temporary) / "appcast.xml"
        candidate.write_bytes(feed_xml(info, archive_url, staged_archive.stat().st_size, notes, channel, signature))
        if not draft:
            tool([*signing, "-p", candidate])
            tool([*signing, "--verify", candidate])
        os.replace(staged_archive, staged_destination)
        atomic_bytes(destination, candidate.read_bytes())
    digest = hashlib.sha256()
    with staged_destination.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    manifest = dict(schemaVersion=1, status="draft" if draft else "signed-local", channel=channel,
                    sparkleVersion=SPARKLE_VERSION, version=info["CFBundleShortVersionString"],
                    build=str(info["CFBundleVersion"]), archiveName=archive.name, archiveSHA256=digest.hexdigest(),
                    archiveBytes=staged_destination.stat().st_size, archiveURL=archive_url,
                    minimumSystemVersion="15.0.0", architecture="arm64", uploaded=False)
    atomic_bytes(output / "update-manifest.json", json.dumps(manifest, ensure_ascii=False, indent=2).encode())
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    configure = commands.add_parser("configure")
    configure.add_argument("--app", type=Path, required=True)
    configure.add_argument("--channel", choices=("disabled", "stable", "staging"), default="disabled")
    configure.add_argument("--feed-url")
    configure.add_argument("--public-key")
    release = commands.add_parser("prepare")
    release.add_argument("--archive", type=Path, required=True)
    release.add_argument("--archive-url", required=True)
    release.add_argument("--output", type=Path, required=True)
    release.add_argument("--release-notes", type=Path, required=True)
    release.add_argument("--channel", choices=("stable", "staging"), required=True)
    release.add_argument("--draft", action="store_true")
    release.add_argument("--sign-update", type=Path)
    release.add_argument("--ed-key-file", type=Path)
    release.add_argument("--previous-build", type=int)
    args = parser.parse_args(argv)
    try:
        if args.command == "configure":
            path = args.app / "Contents/Info.plist"
            info = configured_info(plistlib.loads(path.read_bytes()), args.channel, args.feed_url, args.public_key)
            atomic_bytes(path, plistlib.dumps(info))
            print("Configuration Sparkle : " + args.channel)
        else:
            result = prepare(args.archive, args.archive_url, args.output, args.release_notes.read_text(), args.channel,
                             draft=args.draft, sign_update=args.sign_update, private_key_file=args.ed_key_file,
                             previous_build=args.previous_build)
            print("Flux préparé localement : " + result["status"] + ". Rien n’a été publié.")
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.TimeoutExpired) as error:
        parser.exit(1, "Préparation refusée : " + (str(error) if isinstance(error, ValueError) else type(error).__name__) + "\n")


if __name__ == "__main__":
    main()
