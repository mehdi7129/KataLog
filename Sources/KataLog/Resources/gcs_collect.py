#!/usr/bin/env python3
"""Read-only Drotek 3.7.2 log collection. Python stdlib, JSONL on stdout.

The only permitted MQTT publications list or copy logs; no flight commands.
The GCS protocol has no request ID: callers must serialize operations per drone
and avoid running another FTP client for that drone during collection.
"""

import argparse
import contextlib
import errno
import hashlib
import http.client
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import select
import signal
import socket
import stat
import struct
import sys
import time
from urllib.parse import quote
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
import uuid as uuid_module


PREFIX = "swarm_manager/"
LOG_ROOT = "/fs/microsd/log"
MAGIC = b"ULog\x01\x12\x35"
MAX_PACKET = 8 * 1024 * 1024
MAX_LOG_BYTES = 8 * 1024 * 1024 * 1024
MAX_FILES = 100_000
MAX_DIRECTORIES = 4096
MAX_DEPTH = 8
MAX_INVENTORY_FRAME_BYTES = 256 * 1024
# Keep the existing maximum entry counts and 1,024-character paths, including
# four-byte UTF-8, plus record markers, size and separators for every entry.
MAX_LISTING_BYTES = (MAX_FILES + MAX_DIRECTORIES) * (4 * 1024 + 32)
HTTP_COPY_MIN_SECONDS = 60
# Darwin's UF_DATALESS is absent from some bundled Python stat modules. Other
# platforms have no st_flags and therefore never take the cloud-only branch.
UF_DATALESS = getattr(stat, "UF_DATALESS", 0x40000000)
MQTT_TOPICS = (
    "send_mqtt_drone_status_list", "send_mqtt_ftp_list", "ftp_list_dir",
    "download_path", "send_mqtt_ftp_end_session", "send_mqtt_ftp_transfer_status",
)
PUBLISH_TOPICS = frozenset((
    "recv_mqtt_ftp_list_request", "get_downlad_path", "recv_mqtt_ftp_download_request",
))


class CollectionError(Exception):
    def __init__(self, message, *, retryable=False):
        super().__init__(message)
        self.retryable = retryable


class Cancelled(CollectionError):
    pass


class CloudFileUnavailable(CollectionError):
    """An existing cloud placeholder is neither a cache miss nor a retryable transfer."""


class StagingChanged(CollectionError):
    """A prior HTTP representation is no longer available; request a fresh FTP copy."""


class LocalResumeConflict(CollectionError):
    """A file changed outside the collector; preserve it for explicit resolution."""


def require_local_data(path, metadata=None, *, missing_ok=False):
    try:
        metadata = path.stat(follow_symlinks=False) if metadata is None else metadata
    except FileNotFoundError:
        if missing_ok:
            return None
        raise
    if getattr(metadata, "st_flags", 0) & UF_DATALESS:
        raise CloudFileUnavailable(
            f"Ce fichier est conservé dans le cloud et n’est pas téléchargé sur ce Mac : {path}. "
            "Téléchargez le dossier de collecte dans le Finder, attendez la fin du téléchargement, "
            "puis relancez la collecte. Les fichiers existants sont conservés.")
    return metadata


@contextlib.contextmanager
def local_reader(path, *, text=False):
    """Check metadata immediately before opening; reject a replaced path too.

    Opening a dataless file can block inside File Provider before Python reads
    any bytes, so checking only the opened descriptor would be too late.
    """
    before = require_local_data(path)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    try:
        current = require_local_data(path, os.fstat(descriptor))
        if (before.st_dev, before.st_ino) != (current.st_dev, current.st_ino):
            raise CollectionError("Le fichier local a changé pendant sa vérification ; relancez la collecte. Fichiers conservés.")
        stream = os.fdopen(descriptor, "r" if text else "rb", **({"encoding": "utf-8"} if text else {}))
        descriptor = None
        with stream:
            yield stream
    finally:
        if descriptor is not None:
            os.close(descriptor)


def read_local_manifest(path):
    with local_reader(path, text=True) as stream:
        data = stream.read(16385)
    if len(data) > 16384:
        raise CollectionError("Le manifeste de collecte dépasse la taille autorisée ; fichiers conservés.")
    return json.loads(data)


def retryable_error(error):
    """Retry transient transport failures, never bad input or local disk failures."""
    if isinstance(error, CollectionError):
        return error.retryable
    if isinstance(error, HTTPError):
        return error.code in (408, 425, 429) or 500 <= error.code <= 599
    if isinstance(error, URLError):
        return retryable_error(error.reason) if isinstance(error.reason, BaseException) else False
    if isinstance(error, socket.gaierror):
        return error.errno == socket.EAI_AGAIN
    if isinstance(error, (TimeoutError, ConnectionError, EOFError, http.client.HTTPException)):
        return True
    if isinstance(error, OSError):
        return error.errno in {
            errno.ECONNABORTED, errno.ECONNREFUSED, errno.ECONNRESET,
            errno.EHOSTUNREACH, errno.ENETUNREACH, errno.ENETDOWN,
            errno.ETIMEDOUT, errno.EPIPE,
        }
    return False


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=False, allow_nan=False), flush=True)


def valid_uuid(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9A-Fa-f]{24}", value):
        raise CollectionError("UUID attendu : 24 caractères hexadécimaux.")
    value = value.upper()
    if value in ("0" * 24, "F" * 24):
        raise CollectionError("Le ciblage vide ou broadcast est interdit.")
    return value


def valid_host(value):
    value = value.strip()
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    if not value or len(value) > 253 or not re.fullmatch(r"[A-Za-z0-9_.:%-]+", value):
        raise CollectionError("Indiquer un hostname ou une adresse IP, sans URL ni chemin.")
    return value


def valid_port(value):
    if not 1 <= value <= 65535:
        raise CollectionError("Port hors de l’intervalle 1–65535.")
    return value


def remote_path(value, *, file=False):
    if not isinstance(value, str) or len(value) > 1024 or any(ord(c) < 32 for c in value):
        raise CollectionError("Chemin distant invalide.")
    if "\\" in value or "%" in value or "\x7f" in value or "//" in value:
        raise CollectionError("Chemin distant invalide.")
    parts = value.split("/")
    if any(p in (".", "..") for p in parts) or value.endswith("/"):
        raise CollectionError("Chemin distant non canonique.")
    if value != LOG_ROOT and not value.startswith(LOG_ROOT + "/"):
        raise CollectionError("Seuls les logs de /fs/microsd/log sont autorisés.")
    if file and (value == LOG_ROOT or not value.lower().endswith(".ulg")):
        raise CollectionError("La sélection doit être un fichier .ulg.")
    return value


def child_path(parent, name):
    if not isinstance(name, str) or not name or "/" in name or name in (".", ".."):
        raise CollectionError("Entrée de listing non sûre.")
    return remote_path(parent + "/" + name)


def file_size(value):
    if isinstance(value, bool):
        raise CollectionError("Taille de log invalide.")
    if isinstance(value, str) and re.fullmatch(r"[0-9]+", value):
        value = int(value)
    if not isinstance(value, int) or not 0 <= value <= MAX_LOG_BYTES:
        raise CollectionError("Taille de log invalide ou supérieure à 8 Gio.")
    return value


def mqtt_string(value):
    encoded = value.encode("utf-8")
    return struct.pack("!H", len(encoded)) + encoded


def mqtt_packet(kind, body):
    size = len(body)
    header = bytearray((kind,))
    while True:
        digit = size % 128
        size //= 128
        header.append(digit | (128 if size else 0))
        if not size:
            return bytes(header) + body


class MQTT:
    """A small MQTT 3.1.1 QoS 0 client with bounded, incremental framing."""

    def __init__(self, host, port=1999, topics=MQTT_TOPICS, timeout=6):
        self.sock = None
        self.buffer = bytearray()
        self.last_sent = time.monotonic()
        self.ping_sent = None
        self.topics = set(topics)
        try:
            self.sock = socket.create_connection((valid_host(host), valid_port(port)), timeout=timeout)
            self.sock.settimeout(3)
            self.send(0x10, mqtt_string("MQTT") + bytes((4, 2, 0, 20)) +
                      mqtt_string("katalog-" + uuid_module.uuid4().hex[:20]))
            kind, payload = self.receive(time.monotonic() + timeout)
            if kind != 0x20 or payload != b"\x00\x00":
                raise CollectionError("Connexion MQTT refusée.")
            self.send(0x82, b"\x00\x01" + b"".join(
                mqtt_string(PREFIX + t) + b"\x00" for t in topics))
            deadline = time.monotonic() + timeout
            while True:
                kind, payload = self.receive(deadline)
                if kind == 0x90:
                    if payload[:2] != b"\x00\x01" or len(payload) != len(topics) + 2 or any(payload[2:]):
                        raise CollectionError("Abonnement MQTT refusé.")
                    break
                # A retained publication can precede SUBACK: intentionally discard it.
        except BaseException:
            if self.sock:
                self.sock.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()

    def close(self):
        if self.sock:
            with contextlib.suppress(OSError, CollectionError):
                self.send(0xE0, b"")
            self.sock.close()
            self.sock = None

    def send(self, kind, body):
        if len(body) > MAX_PACKET:
            raise CollectionError("Message MQTT trop volumineux.")
        self.sock.sendall(mqtt_packet(kind, body))
        self.last_sent = time.monotonic()

    def _pop_packet(self):
        if len(self.buffer) < 2:
            return None
        size = 0
        for index in range(1, 5):
            if len(self.buffer) <= index:
                return None
            digit = self.buffer[index]
            size += (digit & 127) * (128 ** (index - 1))
            if size > MAX_PACKET:
                raise CollectionError("Message MQTT trop volumineux.")
            if not digit & 128:
                offset = index + 1
                if len(self.buffer) < offset + size:
                    return None
                kind = self.buffer[0]
                payload = bytes(self.buffer[offset:offset + size])
                del self.buffer[:offset + size]
                return kind, payload
        raise CollectionError("Longueur MQTT mal formée.")

    def receive(self, deadline):
        while True:
            packet = self._pop_packet()
            if packet is not None:
                if packet[0] == 0xD0:
                    if packet[1]:
                        raise CollectionError("PINGRESP MQTT mal formé.")
                    self.ping_sent = None
                else:
                    return packet
            now = time.monotonic()
            if now >= deadline:
                raise TimeoutError("Délai de réponse MQTT dépassé.")
            if self.ping_sent is not None and now - self.ping_sent > 10:
                raise CollectionError("La GCS ne répond plus au keepalive MQTT.", retryable=True)
            if now - self.last_sent >= 10 and self.ping_sent is None:
                self.send(0xC0, b"")
                self.ping_sent = now
            if select.select([self.sock], [], [], min(0.5, deadline - now))[0]:
                data = self.sock.recv(65536)
                if not data:
                    raise CollectionError("Connexion MQTT interrompue.", retryable=True)
                self.buffer.extend(data)

    def publish(self, topic, data):
        if topic not in PUBLISH_TOPICS or not isinstance(data, dict):
            raise CollectionError("Commande hors du périmètre de collecte.")
        identity = valid_uuid(data.get("uuid"))
        if identity != data["uuid"]:
            raise CollectionError("UUID non canonique.")
        if topic == "recv_mqtt_ftp_download_request":
            if set(data) != {"uuid", "dist_file", "local_file", "filesize"}:
                raise CollectionError("Schéma de téléchargement invalide.")
            remote_path(data["dist_file"], file=True)
            staging_path(data["local_file"], identity, data["dist_file"])
            file_size(data["filesize"])
        else:
            if set(data) != {"uuid", "path"}:
                raise CollectionError("Schéma de requête invalide.")
            remote_path(data["path"], file=(topic == "get_downlad_path"))
        self.send(0x30, mqtt_string(PREFIX + topic) + json.dumps(data, allow_nan=False).encode())

    def messages(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                kind, payload = self.receive(deadline)
            except TimeoutError:
                return
            if kind >> 4 != 3:
                continue
            qos = (kind >> 1) & 3
            if len(payload) < 2:
                raise CollectionError("Publication MQTT mal formée.")
            count = struct.unpack("!H", payload[:2])[0]
            offset = 2 + count
            if count == 0 or offset + (2 if qos else 0) > len(payload):
                raise CollectionError("Topic MQTT mal formé.")
            topic = payload[2:offset].decode("utf-8")
            if qos == 1:
                self.send(0x40, payload[offset:offset + 2])
                offset += 2
            elif qos != 0:
                raise CollectionError("QoS inattendu pour cet abonnement MQTT.")
            if kind & 1 or not topic.startswith(PREFIX) or topic[len(PREFIX):] not in self.topics:
                continue
            try:
                data = json.loads(payload[offset:], parse_constant=lambda _: None)
            except (UnicodeError, ValueError, RecursionError):
                continue
            if isinstance(data, dict):
                yield topic[len(PREFIX):], data


def staging_path(value, identity, remote):
    # The real GCS returns backend_pyc/../server-.../public/downloads/file.
    # Only its fixed basename is used in our HTTP URL, never its parent path.
    if not isinstance(value, str) or len(value) > 2048 or not value.startswith("/"):
        raise CollectionError("Chemin de staging GCS invalide.")
    if any(ord(c) < 32 for c in value) or "\\" in value or "%" in value:
        raise CollectionError("Chemin de staging GCS invalide.")
    expected = identity + "_" + PurePosixPath(remote).name
    if PurePosixPath(value).parent.name != "downloads" or PurePosixPath(value).name != expected:
        raise CollectionError("Chemin de staging GCS inattendu.")
    return value


def same_drone(data, identity):
    return isinstance(data.get("uuid"), str) and data["uuid"].upper() == identity


class DirectoryListing:
    """Retain only validated entries; duplicate records still consume the budget."""

    def __init__(self, parent):
        self.parent = parent
        self.directories = set()
        self.files = {}
        self.directory_count = self.file_count = self.line_count = self.byte_count = 0

    def add_directory(self, name):
        self.directory_count += 1
        if self.directory_count > MAX_DIRECTORIES:
            raise CollectionError("Listing GCS trop volumineux.")
        self.directories.add(child_path(self.parent, name))

    def add_file(self, entry):
        self.file_count += 1
        if self.file_count > MAX_FILES:
            raise CollectionError("Listing GCS trop volumineux.")
        if not isinstance(entry, list) or len(entry) != 2:
            raise CollectionError("Entrée fichier GCS invalide.")
        path = child_path(self.parent, entry[0])
        if path.lower().endswith(".ulg"):
            size = file_size(entry[1])
            if path in self.files and self.files[path] != size:
                raise CollectionError("Taille incohérente dans le listing GCS.")
            self.files[path] = size

    def add_raw(self, payload):
        self.byte_count += len(payload.encode("utf-8"))
        if self.byte_count > MAX_LISTING_BYTES:
            raise CollectionError("Le listing GCS dépasse le budget d’octets autorisé.")
        for line in payload.replace("\x00", "\n").splitlines():
            self.line_count += 1
            if self.line_count > MAX_FILES + MAX_DIRECTORIES:
                raise CollectionError("Listing GCS trop volumineux.")
            if line.startswith("D"):
                self.add_directory(line[1:])
            elif line.startswith("F"):
                pieces = line[1:].rsplit("\t", 1)
                if len(pieces) != 2:
                    raise CollectionError("Listing brut GCS invalide.")
                self.add_file(pieces)

    def result(self):
        return sorted(self.directories), [{"path": path, "size": size} for path, size in sorted(self.files.items())]


def parse_listing(data, parent):
    directories, files = data.get("directories"), data.get("files")
    if not isinstance(directories, list) or not isinstance(files, list):
        raise CollectionError("Listing GCS invalide.")
    if len(directories) > MAX_DIRECTORIES or len(files) > MAX_FILES:
        raise CollectionError("Listing GCS trop volumineux.")
    listing = DirectoryListing(parent)
    for name in directories:
        listing.add_directory(name)
    for entry in files:
        listing.add_file(entry)
    return listing.result()


def list_directory(host, port, identity, path, timeout=20):
    path = remote_path(path)
    # A new clean session per directory excludes old retained/session messages.
    with MQTT(host, port, topics=("ftp_list_dir", "send_mqtt_ftp_list", "send_mqtt_ftp_end_session")) as mqtt:
        mqtt.publish("recv_mqtt_ftp_list_request", {"uuid": identity, "path": path})
        listing = DirectoryListing(path)
        raw_received = False
        for topic, data in mqtt.messages(timeout):
            if not same_drone(data, identity):
                continue
            if "path" in data and data["path"] != path:
                continue
            if topic == "ftp_list_dir":
                return parse_listing(data, path)
            if topic == "send_mqtt_ftp_list" and isinstance(data.get("payload"), str):
                raw_received = True
                listing.add_raw(data["payload"])
            if topic == "send_mqtt_ftp_end_session" and data.get("opcode") == 0:
                if data.get("filename") not in (None, "", path):
                    continue
                if data.get("ret_code") != 0:
                    raise CollectionError("Échec du listing GCS (code %s)." % data.get("ret_code"),
                                          retryable=data.get("ret_code") in (1, 2, 3))
                if raw_received:
                    return listing.result()
                # Empty directory: wait for converted listing, whose order may differ.
    raise CollectionError("Aucun listing reçu pour %s." % path, retryable=True)


def inventory(host, port, identity, destination=None, report=None):
    if destination is not None:
        validate_destination(destination)
    pending, visited, discovered, result = [LOG_ROOT], set(), {LOG_ROOT}, []
    deadline = time.monotonic() + 900
    while pending:
        if len(visited) >= MAX_DIRECTORIES or time.monotonic() > deadline:
            raise CollectionError("Limite d’inventaire atteinte ; collecte interrompue.")
        path = pending.pop(0)
        if path in visited:
            continue
        visited.add(path)
        directories, files = list_directory(host, port, identity, path)
        result.extend(files)
        if report is not None:
            report("inventory", len(result), None)
        if len(result) > MAX_FILES:
            raise CollectionError("Plus de 100 000 logs pour ce drone.")
        for directory in directories:
            if len(PurePosixPath(directory).relative_to(LOG_ROOT).parts) > MAX_DEPTH:
                raise CollectionError("Arborescence des logs trop profonde.")
            if directory not in discovered:
                if len(discovered) >= MAX_DIRECTORIES:
                    raise CollectionError("Plus de 4096 répertoires de logs pour ce drone.")
                discovered.add(directory)
                pending.append(directory)
    result.sort(key=lambda item: item["path"])
    if destination is not None:
        last_report = 0
        for index, item in enumerate(result):
            target = local_target(destination, identity, item["path"], create=False)
            record = cache_record(target, {"uuid": identity, "path": item["path"], "size": item["size"]})
            item["isDownloaded"] = record is not None
            if record is not None:
                item["localPath"] = str(target)
                item["sha256"] = record["sha256"]
            if report is not None and (index + 1 == len(result) or time.monotonic() - last_report >= 1):
                report("cache", index + 1, len(result))
                last_report = time.monotonic()
    return result


def emit_inventory_pages(identity, files):
    """Bound every JSONL frame; the UI accepts both these pages and legacy inventory."""
    inventory_id = uuid_module.uuid4().hex
    emit("inventory_started", uuid=identity, inventoryID=inventory_id, totalFiles=len(files))
    page, page_index = [], 0
    def payload(items):
        return {"event": "inventory_page", "uuid": identity, "inventoryID": inventory_id,
                "pageIndex": page_index, "files": items}
    def frame_overhead():
        return len(json.dumps(payload([]), ensure_ascii=False, allow_nan=False).encode("utf-8")) + 1
    page_bytes = frame_overhead()
    for item in files:
        item_bytes = len(json.dumps(item, ensure_ascii=False, allow_nan=False).encode("utf-8"))
        if page and (len(page) >= 256 or page_bytes + 2 + item_bytes > MAX_INVENTORY_FRAME_BYTES):
            emit("inventory_page", uuid=identity, inventoryID=inventory_id, pageIndex=page_index, files=page)
            page_index += 1
            page = []
            page_bytes = frame_overhead()
        if page_bytes + item_bytes > MAX_INVENTORY_FRAME_BYTES:
            raise CollectionError("Une entrée d’inventaire dépasse la limite du protocole local.")
        page_bytes += item_bytes + (2 if page else 0)
        page.append(item)
    if page:
        emit("inventory_page", uuid=identity, inventoryID=inventory_id, pageIndex=page_index, files=page)
        page_index += 1
    emit("inventory_finished", uuid=identity, inventoryID=inventory_id, totalFiles=len(files), pageCount=page_index)


def verify_remote_size(host, port, identity, remote, expected):
    _, files = list_directory(host, port, identity, str(PurePosixPath(remote).parent))
    actual = next((item["size"] for item in files if item["path"] == remote), None)
    if actual != expected:
        raise CollectionError("La taille du log a changé ou le fichier a disparu ; actualiser l’inventaire.")


def validate_destination(destination):
    root = Path(destination).expanduser()
    if not root.is_dir():
        raise CollectionError(f"Dossier de collecte indisponible : {root}. Reconnectez le volume ou choisissez un dossier existant.")
    if not os.access(root, os.R_OK | os.W_OK | os.X_OK):
        raise CollectionError(f"Accès au dossier de collecte refusé : {root}.")
    return root.resolve(strict=True)


def local_target(destination, identity, remote, *, create=True):
    # Only the UI may create its initial app-owned folder. A disappeared custom
    # root must not be recreated, including after the Swift preflight check.
    root = validate_destination(destination)
    target = root / identity / PurePosixPath(remote).relative_to(LOG_ROOT)
    directory = root
    for part in target.relative_to(root).parts[:-1]:
        directory = directory / part
        if directory.is_symlink():
            raise CollectionError("Un lien symbolique bloque la destination de collecte.")
        if create:
            directory.mkdir(exist_ok=True)
    if target.is_symlink():
        raise CollectionError("Le fichier cible ne peut pas être un lien symbolique.")
    return target


def hash_file(path):
    digest = hashlib.sha256()
    with local_reader(path) as stream:
        if stream.read(7) != MAGIC:
            raise CollectionError("Signature ULog invalide.")
        stream.seek(0)
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cache_record(target, source):
    manifest = target.with_name(target.name + ".katalog.json")
    # Do not turn an unavailable original/proof into a cache miss: that would
    # schedule an unnecessary new copy or hide why the local verification stalls.
    require_local_data(target, missing_ok=True)
    require_local_data(manifest, missing_ok=True)
    if not target.exists() or not manifest.is_file() or manifest.is_symlink():
        return None
    try:
        if target.stat().st_size != source["size"] or manifest.stat().st_size > 16384:
            return None
        record = read_local_manifest(manifest)
        # UUID + remote path + listed size identify the collected log. A GCS can
        # move between networks/ports; its original address remains provenance.
        if not record_matches_source(record, source):
            return None
        if hash_file(target) != record["sha256"]:
            return None
        return record
    except CloudFileUnavailable:
        raise
    except (OSError, ValueError, CollectionError):
        return None


def record_matches_source(record, source):
    return (isinstance(record, dict) and isinstance(record.get("source"), dict)
            and all(record["source"].get(key) == source.get(key) for key in ("uuid", "path", "size"))
            and isinstance(record.get("sha256"), str)
            and re.fullmatch(r"[a-f0-9]{64}", record["sha256"]) is not None)


def same_file_identity(path, transaction):
    if path.is_symlink():
        return False
    try:
        stat = path.stat()
        return stat.st_dev == transaction.get("device") and stat.st_ino == transaction.get("inode")
    except OSError:
        return False


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def recover_pending_commit(target, source):
    """Complete only our own interrupted commit; never adopt an arbitrary ULog."""
    pending = target.with_name(target.name + ".katalog.pending.json")
    manifest = target.with_name(target.name + ".katalog.json")
    for path in (pending, target, manifest):
        require_local_data(path, missing_ok=True)
    if not pending.exists() and not pending.is_symlink():
        return
    try:
        if pending.is_symlink() or not pending.is_file() or pending.stat().st_size > 16384:
            raise CollectionError("Marqueur de finalisation invalide ; fichiers conservés.")
        record = read_local_manifest(pending)
        if not record_matches_source(record, source):
            raise CollectionError("Une finalisation précédente ne correspond pas à ce log ; fichiers conservés.")
        transaction = record.get("transaction")
        if (not isinstance(transaction, dict) or not isinstance(transaction.get("part"), str)
                or not re.fullmatch(re.escape(target.name) + r"\.[a-f0-9]{32}\.part", transaction["part"])
                or type(transaction.get("device")) is not int or type(transaction.get("inode")) is not int):
            raise CollectionError("Identité de finalisation invalide ; fichiers conservés.")
        part = target.with_name(transaction["part"])
        require_local_data(part, missing_ok=True)
        if not target.exists() and not target.is_symlink() and not part.exists() and not part.is_symlink():
            # No collected data remains to finish; the next attempt may start fresh.
            require_local_data(pending)
            pending.unlink()
            return
        candidate = target if target.exists() or target.is_symlink() else part
        if (not same_file_identity(candidate, transaction) or candidate.stat().st_size != source["size"]
                or hash_file(candidate) != record["sha256"]):
            raise CollectionError("Le fichier ne correspond pas à la finalisation interrompue ; il est conservé.")
        if candidate == part:
            require_local_data(part)
            require_local_data(pending)
            os.link(part, target)  # Exclusive: a manually added file is never overwritten.
            sync_directory(target.parent)
        if manifest.exists() or manifest.is_symlink():
            existing = cache_record(target, source)
            if existing is None or existing["sha256"] != record["sha256"]:
                raise CollectionError("Un autre manifeste occupe la destination ; il est conservé.")
            require_local_data(pending)
            pending.unlink()
        else:
            require_local_data(pending)
            os.replace(pending, manifest)
        if same_file_identity(part, transaction):
            require_local_data(part)
            part.unlink()
        sync_directory(target.parent)
    except (ValueError, TypeError) as error:
        raise CollectionError("Marqueur de finalisation illisible ; fichiers conservés.") from error


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise CollectionError("Redirection HTTP GCS refusée.")


def strong_etag(value):
    # Weak validators cannot prove byte identity for combining HTTP ranges.
    return (isinstance(value, str) and len(value) <= 1024
            and re.fullmatch(r'"[\x21\x23-\x7e\x80-\xff]*"', value) is not None)


def prefix_digest(stream, size):
    digest = hashlib.sha256()
    stream.seek(0)
    remaining = size
    while remaining:
        chunk = stream.read(min(1024 * 1024, remaining))
        if not chunk:
            raise CollectionError("La copie partielle est incomplète ; fichiers conservés.")
        digest.update(chunk)
        remaining -= len(chunk)
    return digest


def partial_digest(path, size):
    with local_reader(path) as stream:
        return prefix_digest(stream, size)


def remove_http_resume_proof(target, record):
    journal = target.with_name(target.name + ".katalog.resume.json")
    require_local_data(journal, missing_ok=True)
    if journal.is_symlink() or (journal.exists() and read_local_manifest(journal) != record):
        raise LocalResumeConflict("La preuve de reprise a changé ; fichiers conservés.")
    journal.unlink(missing_ok=True)
    sync_directory(target.parent)


def discard_http_resume(target, record):
    """Delete only the owned inode and its unchanged resume proof."""
    journal = target.with_name(target.name + ".katalog.resume.json")
    part = target.with_name(record["part"])
    require_local_data(part, missing_ok=True)
    require_local_data(journal, missing_ok=True)
    if journal.is_symlink() or (journal.exists() and read_local_manifest(journal) != record):
        raise LocalResumeConflict("La preuve de reprise a changé ; fichiers conservés.")
    if part.exists() or part.is_symlink():
        if not same_file_identity(part, record):
            raise CollectionError("La copie partielle a été remplacée ; fichiers conservés.")
        part.unlink()
    remove_http_resume_proof(target, record)


def load_http_resume(target, source):
    journal = target.with_name(target.name + ".katalog.resume.json")
    metadata = require_local_data(journal, missing_ok=True)
    if metadata is None:
        return None
    try:
        if journal.is_symlink() or not journal.is_file() or metadata.st_size > 16384:
            raise ValueError("journal")
        record = read_local_manifest(journal)
        if (not isinstance(record, dict) or record.get("version") != 1
                or not isinstance(record.get("source"), dict)
                or not isinstance(record.get("part"), str)
                or not re.fullmatch(re.escape(target.name) + r"\.[a-f0-9]{32}\.part", record["part"])
                or type(record.get("device")) is not int or type(record.get("inode")) is not int
                or type(record.get("bytes")) is not int or not 0 <= record["bytes"] <= MAX_LOG_BYTES
                or not strong_etag(record.get("etag"))
                or not isinstance(record.get("sha256"), str)
                or not re.fullmatch(r"[a-f0-9]{64}", record["sha256"])):
            raise ValueError("proof")
        old_source = record["source"]
        staging_path(record.get("staging"), valid_uuid(old_source.get("uuid")),
                     remote_path(old_source.get("path"), file=True))
        if record["bytes"] > file_size(old_source.get("size")):
            raise ValueError("size")
        part = target.with_name(record["part"])
        part_stat = require_local_data(part)
        if (not same_file_identity(part, record) or part_stat.st_size < record["bytes"]
                or partial_digest(part, record["bytes"]).hexdigest() != record["sha256"]):
            raise ValueError("partial")
        # Unlike completed cache entries, remote staging is bound to its endpoint.
        if old_source != source:
            discard_http_resume(target, record)
            return None
        return record
    except CloudFileUnavailable:
        raise
    except (ValueError, TypeError, KeyError, CollectionError, FileNotFoundError) as error:
        raise CollectionError("Preuve de reprise invalide ; copie partielle conservée.") from error


def checkpoint_http_resume(target, record, output, digest, total):
    output.flush()
    os.fsync(output.fileno())
    updated = dict(record, bytes=total, sha256=digest.hexdigest())
    journal = target.with_name(target.name + ".katalog.resume.json")
    require_local_data(journal, missing_ok=True)
    existing = journal.exists() or journal.is_symlink()
    if existing:
        if journal.is_symlink() or read_local_manifest(journal) != record:
            raise CollectionError("Une autre preuve occupe la destination ; fichiers conservés.")
    temporary = journal.with_name(journal.name + "." + uuid_module.uuid4().hex + ".tmp")
    try:
        with temporary.open("x") as stream:
            json.dump(updated, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        if existing:
            os.replace(temporary, journal)
        else:
            os.link(temporary, journal)
        record.update(updated)
        sync_directory(target.parent)
    finally:
        temporary.unlink(missing_ok=True)


class HTTPBodyReader:
    """Keep the buffered response, but bound even chunk framing by one deadline."""

    def __init__(self, stream, deadline):
        self.stream = stream
        # urllib's HTTPResponse owns this SocketIO; keep its existing buffer.
        self.socket = stream.raw._sock
        self.deadline = deadline

    def check_deadline(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise CollectionError("Copie HTTP trop longue.", retryable=True)
        return remaining

    def read1(self, size):
        self.socket.settimeout(min(15, self.check_deadline()))
        result = self.stream.read1(size)
        self.check_deadline()
        return result

    def read(self, size):
        result = bytearray()
        while len(result) < size:
            chunk = self.read1(size - len(result))
            if not chunk:
                break
            result.extend(chunk)
        return bytes(result)

    def readline(self, limit):
        # HTTPResponse uses this only for bounded chunk headers and trailers.
        result = bytearray()
        while len(result) < limit:
            byte = self.read1(1)
            if not byte:
                break
            result.extend(byte)
            if byte == b"\n":
                break
        return bytes(result)

    def close(self):
        self.stream.close()

    def flush(self):
        self.stream.flush()


def copy_http(host, http_port, staging, part, expected, report, *, target=None, source=None, resume=None):
    http_host = "[" + host.replace("%", "%25") + "]" if ":" in host else host
    url = "http://%s:%s/downloadFile/%s" % (http_host, http_port, quote(PurePosixPath(staging).name, safe=""))
    # Never inherit a workstation's HTTP proxy or follow a server redirect.
    opener = build_opener(ProxyHandler({}), NoRedirect())
    resuming = bool(resume)
    total = min(resume["bytes"], expected - 1) if resuming else 0
    headers = {"Accept-Encoding": "identity"}
    if resuming:
        headers.update({"Range": "bytes=%s-" % total, "If-Range": resume["etag"]})
    try:
        response = opener.open(Request(url, headers=headers), timeout=15)
    except HTTPError as error:
        if resuming and error.code in (404, 410, 412, 416):
            error.close()
            raise StagingChanged("La copie GCS précédente n’est plus disponible.") from error
        raise
    with response:
        if response.headers.get("Content-Encoding", "identity") != "identity":
            raise CollectionError("Réponse HTTP GCS inattendue.")
        etag = response.headers.get("ETag")
        if resuming and etag != resume["etag"]:
            raise StagingChanged("La copie GCS a changé depuis l’interruption.")
        if resuming and response.status == 206:
            if response.headers.get("Content-Range") != "bytes %s-%s/%s" % (total, expected - 1, expected):
                raise CollectionError("La plage HTTP ne correspond pas à la copie partielle.")
        elif response.status == 200:
            # A server may ignore Range. Rebuild this same validated representation.
            total = 0
            if resuming:
                emit("phase", uuid=source["uuid"], path=source["path"], phase="http", bytes=0, total=expected)
        else:
            raise CollectionError("Réponse HTTP GCS inattendue.")
        length = response.headers.get("Content-Length")
        if length is not None and (not length.isdigit() or int(length) != expected - total):
            raise CollectionError("La taille HTTP ne correspond pas au listing.")
        digest = hashlib.sha256()
        if resuming:
            require_local_data(part)
            if not same_file_identity(part, resume):
                raise LocalResumeConflict("La copie partielle a été remplacée ; fichiers conservés.")
        flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        if not resuming:
            flags |= os.O_CREAT | os.O_EXCL
        with os.fdopen(os.open(part, flags, 0o600), "r+b") as output:
            stat = os.fstat(output.fileno())
            if resuming and (stat.st_dev, stat.st_ino) != (resume["device"], resume["inode"]):
                raise LocalResumeConflict("La copie partielle a été remplacée ; fichiers conservés.")
            if resuming:
                saved_digest = prefix_digest(output, resume["bytes"])
                if saved_digest.hexdigest() != resume["sha256"]:
                    raise LocalResumeConflict("La copie partielle a changé ; fichiers conservés.")
                digest = saved_digest if total == resume["bytes"] else prefix_digest(output, total)
            if not resuming and resume is not None and strong_etag(etag):
                resume.update(version=1, source=source, staging=staging, part=part.name,
                              device=stat.st_dev, inode=stat.st_ino, bytes=0,
                              sha256=digest.hexdigest(), etag=etag)
            if resume:
                # Commit the smaller verified prefix before truncation. A crash
                # may leave extra bytes, never a journal longer than its file.
                checkpoint_http_resume(target, resume, output, digest, total)
            output.truncate(total)
            output.seek(total)
            deadline = time.monotonic() + max(HTTP_COPY_MIN_SECONDS, min(900, expected / (64 * 1024)))
            reader = HTTPBodyReader(response.fp, deadline)
            response.fp = reader
            checkpoint_at = time.monotonic()
            try:
                while True:
                    reader.check_deadline()
                    chunk = response.read1(min(256 * 1024, expected - total + 1))
                    if not chunk:
                        break
                    if total + len(chunk) > expected:
                        raise CollectionError("Le téléchargement dépasse la taille annoncée.")
                    output.write(chunk)
                    digest.update(chunk)
                    total += len(chunk)
                    report(total)
                    if resume and time.monotonic() - checkpoint_at >= 1:
                        checkpoint_http_resume(target, resume, output, digest, total)
                        checkpoint_at = time.monotonic()
            finally:
                output.flush()
                os.fsync(output.fileno())
                if resume:
                    checkpoint_http_resume(target, resume, output, digest, total)
    if total != expected:
        raise CollectionError("Téléchargement incomplet : %s / %s octets." % (total, expected), retryable=True)
    if hash_file(part) != digest.hexdigest():
        raise LocalResumeConflict("La copie locale a changé pendant le téléchargement ; fichiers conservés.")
    return digest.hexdigest()


def request_staging(host, port, identity, remote, expected):
    with MQTT(host, port) as mqtt:
        mqtt.publish("get_downlad_path", {"uuid": identity, "path": remote})
        staging = None
        for topic, data in mqtt.messages(10):
            if topic == "download_path" and same_drone(data, identity) and data.get("dist_file") == remote:
                staging = staging_path(data.get("local_file"), identity, remote)
                break
        if staging is None:
            raise CollectionError("La GCS n’a pas fourni de chemin de téléchargement.", retryable=True)
        transfer_timeout = math.ceil(max(300, min(3600, expected / 8192)))
        emit("transfer_started", uuid=identity, path=remote, timeoutSeconds=transfer_timeout)
        mqtt.publish("recv_mqtt_ftp_download_request", {
            "uuid": identity, "dist_file": remote, "local_file": staging, "filesize": expected})
        complete = False
        last_progress = -1
        for topic, data in mqtt.messages(transfer_timeout):
            if not same_drone(data, identity) or data.get("opcode") != 2:
                continue
            if data.get("filename") not in (remote, staging):
                continue
            if topic == "send_mqtt_ftp_end_session":
                if type(data.get("ret_code")) is not int:
                    continue
                emit("transfer_finished", uuid=identity, path=remote,
                     filename=data["filename"], retCode=data.get("ret_code"))
                if data.get("ret_code") != 0:
                    raise CollectionError("Échec du transfert drone → GCS (code %s)." % data.get("ret_code"),
                                          retryable=data.get("ret_code") in (1, 2, 3))
                complete = True
                break
            if topic == "send_mqtt_ftp_transfer_status":
                transferred = data.get("bytes_xfer")
                if (isinstance(transferred, (int, float)) and not isinstance(transferred, bool)
                        and (isinstance(transferred, int) or math.isfinite(transferred))):
                    transferred = max(0, min(expected, int(transferred)))
                    if transferred > last_progress:
                        emit("progress", uuid=identity, path=remote, bytes=transferred, total=expected, phase="drone")
                        last_progress = transferred
        if not complete:
            raise CollectionError("Le transfert drone → GCS n’a pas été confirmé.", retryable=True)
    return staging


def download(host, port, http_port, identity, remote, expected, destination):
    remote = remote_path(remote, file=True)
    expected = file_size(expected)
    if expected < 16:
        raise CollectionError("Fichier vide ou en-tête ULog incomplet.")
    target = local_target(destination, identity, remote)
    source = {"host": host.lower(), "port": port, "httpPort": http_port,
              "uuid": identity, "path": remote, "size": expected}
    recover_pending_commit(target, source)
    record = cache_record(target, source)
    if record:
        emit("downloaded", uuid=identity, path=remote, localPath=str(target), bytes=expected,
             sha256=record["sha256"], cached=True)
        return
    if target.exists():
        raise CollectionError("Un fichier non vérifié existe déjà à la destination ; il est conservé.")
    resume = load_http_resume(target, source) or {}
    part = target.with_name(resume["part"] if resume else target.name + "." + uuid_module.uuid4().hex + ".part")
    manifest = target.with_name(target.name + ".katalog.json")
    pending = target.with_name(target.name + ".katalog.pending.json")
    pending_created = False
    pending_durable = False
    preserve_cloud_files = False
    preserve_http_resume = False
    transaction = {}
    if manifest.exists() or manifest.is_symlink():
        raise CollectionError("Un manifeste sans fichier associé existe déjà ; il est conservé.")
    verify_remote_size(host, port, identity, remote, expected)
    try:
        while True:
            staging = resume["staging"] if resume else request_staging(host, port, identity, remote, expected)
            emit("phase", uuid=identity, path=remote, phase="http", bytes=resume.get("bytes", 0), total=expected)
            try:
                digest = copy_http(host, http_port, staging, part, expected, lambda transferred:
                    emit("progress", uuid=identity, path=remote, bytes=transferred, total=expected, phase="http"),
                    target=target, source=source, resume=resume)
                break
            except StagingChanged:
                # The previous path may now contain a different log with the same
                # basename. Only a fresh MQTT transfer can establish its source.
                discard_http_resume(target, resume)
                resume = {}
                part = target.with_name(target.name + "." + uuid_module.uuid4().hex + ".part")
        emit("phase", uuid=identity, path=remote, phase="verification", bytes=expected, total=expected)
        # An active file can grow after the first check. Never import that copy.
        verify_remote_size(host, port, identity, remote, expected)
        record = {"source": source, "sha256": digest, "staging": staging,
                  "collectedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        part_stat = require_local_data(part)
        transaction = {"part": part.name, "device": part_stat.st_dev, "inode": part_stat.st_ino}
        record["transaction"] = transaction
        # Persist proof of ownership before publishing the complete ULog. If the
        # manifest rename fails or the process dies, the next attempt can recover
        # this exact inode/content without claiming an unrelated manual file.
        with pending.open("x") as stream:
            pending_created = True
            json.dump(record, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        sync_directory(target.parent)
        pending_durable = True
        if resume:
            # The fully verified commit proof now owns recovery. Do not leave an
            # obsolete HTTP journal pointing at the part after it is promoted.
            remove_http_resume_proof(target, resume)
            resume = {}
        # Hard link creation refuses to overwrite a concurrently created target.
        require_local_data(part)
        require_local_data(pending)
        require_local_data(target, missing_ok=True)
        require_local_data(manifest, missing_ok=True)
        os.link(part, target)
        sync_directory(target.parent)
        require_local_data(part)
        part.unlink()
        require_local_data(pending)
        os.replace(pending, manifest)
        sync_directory(target.parent)
        emit("downloaded", uuid=identity, path=remote, localPath=str(target), bytes=expected,
             sha256=digest, cached=False)
    except CloudFileUnavailable:
        preserve_cloud_files = True
        raise
    except BaseException as error:
        preserve_http_resume = bool(resume) and (isinstance(error, (Cancelled, LocalResumeConflict)) or retryable_error(error))
        raise
    finally:
        if not preserve_cloud_files and not preserve_http_resume and not pending_durable:
            if resume:
                discard_http_resume(target, resume)
            else:
                part.unlink(missing_ok=True)
            if pending_created and not same_file_identity(target, transaction):
                pending.unlink(missing_ok=True)


def discover(host, port):
    with MQTT(host, port, topics=("send_mqtt_drone_status_list", "send_mqtt_ftp_end_session")) as mqtt:
        emit("connection", connected=True)
        last_data = time.monotonic()
        while True:
            for topic, data in mqtt.messages(2):
                if topic == "send_mqtt_ftp_end_session":
                    filename = data.get("filename")
                    if (data.get("opcode") == 2 and type(data.get("ret_code")) is int
                            and isinstance(filename, str) and len(filename) <= 2048
                            and filename.lower().endswith(".ulg") and not any(ord(c) < 32 for c in filename)):
                        try:
                            identity = valid_uuid(data.get("uuid"))
                        except CollectionError:
                            continue
                        emit("transfer_end", uuid=identity, path=filename, retCode=data["ret_code"])
                    continue
                entries = data.get("drone_status_list")
                if not isinstance(entries, list) or len(entries) > 10000:
                    continue
                drones, seen = [], set()
                for entry in entries:
                    if not isinstance(entry, dict):
                        continue
                    try:
                        identity = valid_uuid(entry.get("uuid"))
                    except CollectionError:
                        continue
                    if identity in seen:
                        continue
                    drone = {"uuid": identity}
                    for field in ("time_usec", "battery_status", "rssi_wifi", "fw_major", "fw_minor", "fw_patch", "arming_state"):
                        value = entry.get(field)
                        if (isinstance(value, (int, float)) and not isinstance(value, bool)
                                and abs(value) <= 2**63 - 1 and math.isfinite(value)):
                            drone[field] = value
                    drones.append(drone)
                    seen.add(identity)
                emit("drones", drones=drones)
                last_data = time.monotonic()
            if time.monotonic() - last_data > 15:
                raise CollectionError("Aucune liste de drones récente reçue depuis 15 secondes.", retryable=True)


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise CollectionError(message)


def main(argv=None):
    def stop(signum, frame):
        raise Cancelled("Collecte annulée. La copie déjà demandée à la GCS peut se poursuivre.")
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    args = None
    try:
        parser = ArgumentParser(description=__doc__)
        parser.add_argument("command", choices=("discover", "inventory", "download"))
        parser.add_argument("--host", required=True)
        parser.add_argument("--port", type=int, default=1999)
        parser.add_argument("--http-port", type=int, default=8080)
        parser.add_argument("--uuid")
        parser.add_argument("--remote")
        parser.add_argument("--size", type=int)
        parser.add_argument("--destination")
        args = parser.parse_args(argv)
        host, port = valid_host(args.host), valid_port(args.port)
        if args.command == "discover":
            discover(host, port)
        else:
            identity = valid_uuid(args.uuid)
            if args.command == "inventory":
                files = inventory(host, port, identity, args.destination,
                                  report=lambda phase, completed, total: emit("inventory_progress", uuid=identity,
                                                                            phase=phase, completedFiles=completed, totalFiles=total))
                emit_inventory_pages(identity, files)
            else:
                if args.remote is None or args.size is None or not args.destination:
                    raise CollectionError("Le téléchargement exige --remote, --size et --destination.")
                download(host, port, valid_port(args.http_port), identity, args.remote, args.size, args.destination)
        return 0
    except Cancelled as error:
        emit("error", message=str(error), cancelled=True, retryable=False, cancellationRemoteStopped=False)
        return 130
    except (CollectionError, OSError, ValueError, EOFError, http.client.HTTPException) as error:
        emit("error", message=str(error), retryable=retryable_error(error))
        if isinstance(error, HTTPError):
            error.close()
        return 1
    finally:
        if args is not None and args.command == "discover":
            emit("connection", connected=False)


if __name__ == "__main__":
    sys.exit(main())
