#!/usr/bin/env python3
"""Local, incremental PX4 ULog library. Sources are opened read-only.

Units and invalid values follow the logged PX4 field names (BatteryStatus,
SensorGps). No statistical warning is promoted to a hardware diagnosis.
https://docs.px4.io/main/en/dev_log/ulog_file_format
https://docs.px4.io/main/en/msg_docs/BatteryStatus
https://docs.px4.io/main/en/msg_docs/SensorGps
"""
from __future__ import annotations

import argparse
import contextlib
from datetime import datetime, timezone
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import stat as stat_module
import struct
import sys
import tempfile
import zlib

import numpy as np
from pyulog import ULog

# Works both as a bundled CLI and when loaded by file path in test tools.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from flight_data import enrich

SCHEMA_VERSION = 1
PARSER_VERSION = "1.4.0"
MESSAGE_FAMILIES = ("Batterie", "Communication", "GNSS", "Capteurs", "Propulsion", "Navigation", "Système", "Éclairage", "Température", "Autres")
LEVELS = ("EMERGENCY", "ALERT", "CRITICAL", "ERROR", "WARNING", "NOTICE", "INFO", "DEBUG")
GAP_SECONDS = 10.0
MIN_FLIGHT_COVERAGE_FRACTION = 0.99
ANALYSIS_REVISION_VERSION = 1
MAX_ANALYSIS_BYTES = 64 * 1024 * 1024
MAX_REVISION_STORAGE_BYTES = 512 * 1024 * 1024
CLOUD_SOURCE_DETAIL = ("Fichier présent dans le cloud, mais non téléchargé sur ce Mac. "
                       "Dans le Finder, utilisez « Télécharger » sur le fichier ou son dossier. "
                       "Le résumé et les analyses en cache restent disponibles.")


class RevisionBudgetError(ValueError):
    """Preserve the published analysis when revision retention cannot proceed."""


class ArchiveImportError(ValueError):
    """Refuse this import before any new analysis is published."""


class CloudSourceUnavailableError(OSError):
    """Reading a File Provider placeholder could block while macOS hydrates it."""


def require_local_source(path, metadata=None):
    metadata = metadata if metadata is not None else Path(path).stat()
    # Some bundled Python versions omit the Darwin constant even though stat
    # still exposes st_flags. Do not interpret this bit on other platforms.
    dataless = getattr(stat_module, 'UF_DATALESS', 0x40000000 if sys.platform == 'darwin' else 0)
    if getattr(metadata, 'st_flags', 0) & dataless:
        raise CloudSourceUnavailableError(CLOUD_SOURCE_DETAIL)
    return metadata


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def open_database(path, read_only=False):
    if read_only:
        db = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
        db.row_factory = sqlite3.Row
        version = db.execute("PRAGMA user_version").fetchone()[0]
        if version not in (0, SCHEMA_VERSION):
            db.close()
            raise RuntimeError(f"Base de version {version} non prise en charge (attendu {SCHEMA_VERSION}).")
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings'").fetchone():
            revision_version = db.execute("SELECT value FROM settings WHERE key='analysisRevisionSchema'").fetchone()
            if revision_version and revision_version[0] != str(ANALYSIS_REVISION_VERSION):
                db.close()
                raise ValueError('Version des révisions d’analyse non prise en charge.')
        return db
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(path), timeout=30)
    db.row_factory = sqlite3.Row
    version = db.execute("PRAGMA user_version").fetchone()[0]
    if version not in (0, SCHEMA_VERSION):
        db.close()
        raise RuntimeError(f"Base de version {version} non prise en charge (attendu {SCHEMA_VERSION}).")
    # Refuse a newer revision format before WAL or any additive DDL can change
    # the library. The database format and revision format evolve separately.
    revision_version = None
    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings'").fetchone():
        revision_version = db.execute("SELECT value FROM settings WHERE key='analysisRevisionSchema'").fetchone()
        if revision_version and revision_version[0] != str(ANALYSIS_REVISION_VERSION):
            db.close()
            raise ValueError('Version des révisions d’analyse non prise en charge.')
    db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS logs (
            id TEXT PRIMARY KEY, parser_version TEXT NOT NULL, summary TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS flight_details (
            log_id TEXT PRIMARY KEY, parser_version TEXT NOT NULL, summary TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS files (
            path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
            ctime_ns INTEGER NOT NULL, inode INTEGER NOT NULL, log_id TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sources (
            log_id TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY(log_id,path)
        );
        CREATE INDEX IF NOT EXISTS sources_path_log ON sources(path,log_id);
        CREATE TABLE IF NOT EXISTS folders (path TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS source_folder_retirements (path TEXT PRIMARY KEY,retired_at TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS source_observations (
            log_id TEXT NOT NULL,path TEXT NOT NULL,state TEXT NOT NULL,checked_at TEXT NOT NULL,
            PRIMARY KEY(log_id,path)
        );
        CREATE TABLE IF NOT EXISTS analysis_revisions (
            id TEXT PRIMARY KEY,log_id TEXT NOT NULL,kind TEXT NOT NULL,
            parser_version TEXT NOT NULL,analysis_sha256 TEXT NOT NULL,
            created_at TEXT NOT NULL,size_bytes INTEGER NOT NULL,payload BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS analysis_revisions_log ON analysis_revisions(log_id,created_at DESC,id DESC);
    """)
    db.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
    if not revision_version:
        try:
            db.execute("INSERT OR REPLACE INTO settings VALUES('analysisRevisionStorageBytes','0')")
            for table, kind, key in (('logs', 'summary', 'id'), ('flight_details', 'detail', 'log_id')):
                for row in db.execute('SELECT ' + key + ',parser_version,summary FROM ' + table):
                    archive_analysis(db, row[0], kind, row[1], row[2])
            db.execute("INSERT INTO settings VALUES('analysisRevisionSchema',?)", (str(ANALYSIS_REVISION_VERSION),))
        except Exception:
            db.rollback()
            db.close()
            raise
    db.commit()
    return db


def archive_analysis(db, log_id, kind, parser_version, summary, created_at=None):
    """Deduplicated immutable recorded JSON, with bounded compressed retention.

    The caller owns its transaction. No old revision is automatically removed.
    Capture time is explicitly separate from the flight or original parse date.
    """
    if not re.fullmatch(r'[a-f0-9]{64}', log_id):
        return None  # path-only import failures are not recorded ULog analyses
    if kind not in ('summary', 'detail') or not isinstance(parser_version, str) or not 1 <= len(parser_version.encode()) <= 256:
        raise ValueError('Type ou version de révision invalide.')
    raw = summary.encode('utf-8')
    if len(raw) > MAX_ANALYSIS_BYTES:
        raise RevisionBudgetError('Analyse au-delà de la limite de rétention de 64 Mio ; analyse publiée conservée.')
    try:
        value = json.loads(summary)
    except (ValueError, TypeError):
        return None  # an invalid legacy cache is not an exploitable revision
    if not isinstance(value, dict) or value.get('id') != log_id or value.get('status') == 'error':
        return None
    checksum = hashlib.sha256(raw).hexdigest()
    identity = hashlib.sha256(('\n'.join((log_id, kind, parser_version, checksum))).encode()).hexdigest()
    row = db.execute('SELECT id FROM analysis_revisions WHERE id=?', (identity,)).fetchone()
    if row:
        return identity
    payload = zlib.compress(raw, 6)
    stored = int(db.execute("SELECT COALESCE((SELECT value FROM settings WHERE key='analysisRevisionStorageBytes'),'0')").fetchone()[0])
    if stored + len(payload) > MAX_REVISION_STORAGE_BYTES:
        raise RevisionBudgetError('Historique des analyses plein (512 Mio). Exportez puis nettoyez des anciennes révisions ; aucune analyse publiée n’a été remplacée.')
    captured = created_at or datetime.now(timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')
    db.execute('INSERT INTO analysis_revisions VALUES(?,?,?,?,?,?,?,?)', (identity, log_id, kind, parser_version, checksum, captured, len(raw), payload))
    db.execute("INSERT OR REPLACE INTO settings VALUES('analysisRevisionStorageBytes',?)", (str(stored + len(payload)),))
    return identity


def decoded_revision(row):
    if not 0 <= row['size_bytes'] <= MAX_ANALYSIS_BYTES:
        raise ValueError('Révision d’analyse hors budget.')
    decoder = zlib.decompressobj()
    try:
        raw = decoder.decompress(row['payload'], row['size_bytes'] + 1)
    except zlib.error as error:
        raise ValueError('Révision d’analyse compressée invalide.') from error
    if len(raw) != row['size_bytes'] or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail or hashlib.sha256(raw).hexdigest() != row['analysis_sha256']:
        raise ValueError('Empreinte ou taille de révision d’analyse incorrecte.')
    value = json.loads(raw)
    identity = hashlib.sha256(('\n'.join((row['log_id'], row['kind'], row['parser_version'], row['analysis_sha256']))).encode()).hexdigest()
    if identity != row['id'] or not isinstance(value, dict) or value.get('id') != row['log_id'] or value.get('status') == 'error' or row['kind'] not in ('summary', 'detail'):
        raise ValueError('Identité de révision d’analyse incohérente.')
    return value


def validate_analysis_revisions(db):
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='analysis_revisions'").fetchone():
        return
    original_factory = db.row_factory
    db.row_factory = sqlite3.Row
    try:
        schema = db.execute("SELECT value FROM settings WHERE key='analysisRevisionSchema'").fetchone()
        if not schema or schema[0] != str(ANALYSIS_REVISION_VERSION):
            raise ValueError('Version des révisions d’analyse non prise en charge.')
        total = 0
        for row in db.execute('SELECT * FROM analysis_revisions'):
            total += len(row['payload'])
            if total > MAX_REVISION_STORAGE_BYTES:
                raise ValueError('Historique des analyses sauvegardé au-delà de 512 Mio.')
            decoded_revision(row)
    finally:
        db.row_factory = original_factory


def revision_metadata(db, row, current_hashes=None):
    if row['kind'] not in ('summary', 'detail') or not isinstance(row['parser_version'], str) or not 1 <= len(row['parser_version'].encode()) <= 256 or not isinstance(row['created_at'], str) or len(row['created_at']) > 64:
        raise ValueError('Métadonnées de révision invalides ou hors budget.')
    table, key = ('logs', 'id') if row['kind'] == 'summary' else ('flight_details', 'log_id')
    if current_hashes is None:
        current = db.execute('SELECT parser_version,summary FROM ' + table + ' WHERE ' + key + '=?', (row['log_id'],)).fetchone()
        current_hash = (current[0], hashlib.sha256(current[1].encode()).hexdigest()) if current else None
    else:
        current_hash = current_hashes.get(row['kind'])
    is_current = current_hash == (row['parser_version'], row['analysis_sha256'])
    return {'schemaVersion': ANALYSIS_REVISION_VERSION, 'id': row['id'], 'kind': row['kind'],
            'parserVersion': row['parser_version'], 'analysisSHA256': row['analysis_sha256'],
            'createdAt': row['created_at'], 'createdAtSource': 'captured', 'sizeBytes': row['size_bytes'], 'current': is_current}


def analysis_revisions(log_id, database, offset=0, limit=32, read_only=False):
    if not re.fullmatch(r'[a-f0-9]{64}', log_id) or type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 200:
        raise ValueError('Identité ou pagination des révisions invalide.')
    db = open_database(database, read_only=read_only)
    try:
        if not db.execute('SELECT 1 FROM logs WHERE id=?', (log_id,)).fetchone():
            raise ValueError('Ce log n’est pas dans la bibliothèque.')
        available = bool(db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='analysis_revisions'").fetchone())
        rows = db.execute('SELECT id,log_id,kind,parser_version,analysis_sha256,created_at,size_bytes FROM analysis_revisions WHERE log_id=? ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?', (log_id, limit, offset)).fetchall() if available else []
        total = db.execute('SELECT COUNT(*) FROM analysis_revisions WHERE log_id=?', (log_id,)).fetchone()[0] if available else 0
        current_hashes = {}
        for table, kind, key in (('logs', 'summary', 'id'), ('flight_details', 'detail', 'log_id')):
            current = db.execute('SELECT parser_version,summary FROM ' + table + ' WHERE ' + key + '=?', (log_id,)).fetchone()
            current_hashes[kind] = (current[0], hashlib.sha256(current[1].encode()).hexdigest()) if current else None
        values = [revision_metadata(db, row, current_hashes) for row in rows]
        return {'revisionVersion': ANALYSIS_REVISION_VERSION, 'logID': log_id, 'total': total, 'revisions': values,
                'nextOffset': offset + len(values) if offset + len(values) < total else None}
    finally:
        db.close()


def digest_file(path):
    require_local_source(path)
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stat_signature(stat):
    return (stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns, stat.st_ino)


def source_availability(path, log_id, known_file=None, checked_at=None):
    """Describe current access without removing historical provenance.

    A matching stat signature reuses the SHA verified at import. A changed
    signature requires a fresh digest, not an assumption that mtime means new
    content. Missing paths below an unmounted macOS /Volumes entry are offline;
    other missing paths remain missing. No inaccessible parent is deleted.
    """
    path = Path(path)
    result = {"path": str(path), "state": "unknown", "checkedAt": checked_at or utc_now(), "detail": ""}
    try:
        before = require_local_source(path)
        if re.fullmatch(r"[a-f0-9]{64}", log_id):
            if not stat_module.S_ISREG(before.st_mode):
                result.update(state="modified", detail="Le chemin ne désigne plus un fichier ULog original.")
                return result
            signature = stat_signature(before)
            cached_signature = (tuple(known_file[key] for key in ("size", "mtime_ns", "ctime_ns", "inode"))
                                if known_file else None)
            if cached_signature == signature:
                matches = known_file["log_id"] == log_id
            else:
                matches = digest_file(path) == log_id
                if stat_signature(path.stat()) != signature:
                    result["detail"] = "Le fichier change pendant la vérification ; réessayer après la copie."
                    return result
            if not matches:
                result.update(state="modified", detail="Le contenu présent ne correspond plus au SHA256 de cet enregistrement.")
                return result
        result.update(state="present", detail="Source accessible ; contenu correspondant à cet enregistrement.")
    except FileNotFoundError:
        volume = Path("/Volumes") / path.parts[2] if len(path.parts) > 2 and path.parts[:2] == ("/", "Volumes") else None
        if volume is not None:
            try:
                mounted = os.path.ismount(volume)
                volume.stat()
            except FileNotFoundError:
                mounted = False
            except PermissionError:
                result.update(state="inaccessible", detail="Accès au volume refusé ; la provenance reste conservée.")
                return result
            except OSError:
                mounted = None
            if mounted is False:
                result.update(state="offline", detail="Volume non monté ; reconnectez-le pour retrouver la source.")
                return result
        result.update(state="missing", detail="Fichier actuellement absent de ce chemin ; la provenance reste conservée.")
    except CloudSourceUnavailableError:
        result.update(state="inaccessible", detail=CLOUD_SOURCE_DETAIL)
    except PermissionError:
        result.update(state="inaccessible", detail="Accès au fichier refusé ; vérifiez les autorisations du dossier ou du volume.")
    except OSError:
        result.update(state="inaccessible", detail="La source ne peut pas être lue actuellement ; réessayez lorsque le dossier est accessible.")
    return result


def attach_source_availability(log, paths, known_files=None, checked_at=None):
    """Attach ephemeral availability; immutable cached analysis stays untouched."""
    known_files = known_files or {}
    checked_at = checked_at or utc_now()
    # The original imported path also matters after a later scan associates that
    # path with different content. sourcePaths keeps its existing current-link
    # contract, while the availability record retains this original provenance.
    historical = log.get("sourcePaths", [])
    all_paths = sorted(set(historical) | set(paths))
    log["sourceAvailability"] = [source_availability(path, log["id"], known_files.get(path), checked_at)
                                 for path in all_paths]
    if all_paths and not any(item["state"] == "present" for item in log["sourceAvailability"]):
        log["coverage"].append("Source originale actuellement indisponible : résumé et analyses en cache conservés ; consultez l’état des chemins source.")
    log["sourcePaths"] = list(paths)


def clean_name(value):
    return str(value).replace("\x00", "").strip()[:200] if value is not None else ""


def card_context(path, root):
    """Prefer nearest card metadata; no inferred common vehicle at fleet root."""
    root = Path(root).resolve()
    for ancestor in path.parents:
        candidate = ancestor / "data" / "name.txt"
        try:
            if candidate.is_file():
                require_local_source(candidate)
                with candidate.open("r", encoding="utf-8", errors="replace") as stream:
                    name = clean_name(stream.read(1024))
                return str(ancestor), name
        except OSError:
            pass
        if ancestor == root:
            break
    # A log/YYYY-MM-DD directory provides a card boundary, unlike an arbitrary
    # import directory containing loose files from several unknown vehicles.
    for ancestor in path.parents:
        if ancestor.name.lower() in ("log", "logs") and ancestor != root:
            return str(ancestor.parent), ""
        if ancestor == root:
            break
    return "", ""


def path_date(path):
    match = re.search(r"(\d{4}-\d{2}-\d{2})[/\\](\d{2})_(\d{2})_(\d{2})(?:[^/\\]*)\.ulg$", str(path), re.I)
    if match:
        try:
            # Filename dates do not supply a timezone. Do not invent UTC.
            return datetime.fromisoformat(f"{match[1]}T{match[2]}:{match[3]}:{match[4]}").isoformat(), "path"
        except ValueError:
            pass
    return "", "unknown"


def base_log(path, root, digest, size):
    card, name = card_context(path, root)
    fallback = "card:" + hashlib.sha256(card.encode()).hexdigest() if card else "unknown:" + digest
    date, source = path_date(path)
    return {
        "id": digest, "droneID": fallback, "droneName": name or "Drone non identifié",
        "date": date, "dateSource": source, "sourcePaths": [str(path)],
        "fileName": path.name, "sizeBytes": size, "durationSeconds": 0.0,
        "flightSeconds": None, "flightCoverageSeconds": None,
        "flightCoverageFraction": None, "flightObservedSeconds": None,
        "status": "ok", "issues": [], "metadata": {},
        "topics": [], "messages": [], "metrics": [], "coverage": [],
        "failsafeObserved": False,
    }


def preflight(path):
    """Validate ULog record framing, including potentially truncated final data.

    pyulog can accept a truncated last record without setting file_corruption.
    Append boundaries are handled independently, as specified by ULog flag B.
    A cut exactly on a message boundary is inherently indistinguishable from a
    completed file and is not claimed to be detectable.
    """
    issues = []
    size = path.stat().st_size
    with path.open("rb") as stream:
        header = stream.read(16)
        if len(header) < 16 or header[:7] != ULog.HEADER_BYTES:
            raise ValueError("En-tête ULog invalide ou incomplet.")
        if header[7] > 1:
            raise ValueError(f"Version de fichier ULog inconnue : {header[7]}.")
        boundaries = []
        first = stream.read(3)
        if len(first) == 3:
            count, kind = struct.unpack("<HB", first)
            if kind == ord("B") and count >= 40:
                flags = stream.read(40)
                if len(flags) == 40:
                    if flags[8] & 0xFE or any(flags[9:16]):
                        raise ValueError("ULog possède des flags incompatibles non pris en charge.")
                    if flags[8] & 1:
                        boundaries = sorted(set(offset for offset in struct.unpack("<QQQ", flags[16:40]) if offset))
                        if any(offset < 16 or offset > size for offset in boundaries):
                            issues.append("Offsets de données ajoutées hors du fichier.")
                        boundaries = [offset for offset in boundaries if 16 <= offset <= size]
        boundaries = sorted(set([16, *boundaries, size]))
        records = 0
        for start, end in zip(boundaries, boundaries[1:]):
            stream.seek(start)
            while stream.tell() < end:
                offset = stream.tell()
                if end - offset < 3:
                    issues.append(f"ULog tronqué : en-tête de message incomplet à l'octet {offset}.")
                    break
                count, kind = struct.unpack("<HB", stream.read(3))
                if count > end - stream.tell():
                    issues.append(f"ULog tronqué : message incomplet à l'octet {offset} ({count} octets attendus).")
                    break
                if not 65 <= kind <= 90:
                    issues.append(f"Type de message ULog invalide à l'octet {offset}.")
                    break
                stream.seek(count, os.SEEK_CUR)
                records += 1
        if records == 0:
            raise ValueError("ULog sans message exploitable.")
    return issues


def message_family(text):
    lower = text.lower()
    # Preserve the affected subsystem for thermal messages about the LEDs.
    # A whole-word match avoids confusing "failed" or the lightshow branch.
    if "rgbled" in lower or "led_control" in lower or re.search(r"\bleds?\b", lower):
        return "Éclairage"
    if any(word in lower for word in ("batt", "smbus", "voltage", "power supply")):
        return "Batterie"
    if any(word in lower for word in ("wifi", "xbee", "mavlink", "heartbeat", "ground station", "communication", "rtcm connection")):
        return "Communication"
    if any(word in lower for word in ("gps", "gnss", "rtk", "rtcm", "satellite", "spoof", "jamming")):
        return "GNSS"
    if any(word in lower for word in ("accel", "[vehicle_imu]", "gyro", "magnetometer", "compass", "baro", "sensor", "calibration")):
        return "Capteurs"
    if any(word in lower for word in ("[esc", "motor fail", "motor error", "propulsion", "actuator")):
        return "Propulsion"
    if any(word in lower for word in ("failsafe", "[navigator]", "[dance]", "[demosequencer", "takeoff", "landing", "geofence", "ekf", "position")):
        return "Navigation"
    if any(word in lower for word in ("temperature", "température", "overheat", "thermal")):
        return "Température"
    if any(word in lower for word in ("[logger]", "[commander]", "[maestro]", "[alarm]", "[land_detector]", "system", "cpu", "memory")):
        return "Système"
    return "Autres"


def gcs_uuid(datasets, info, coverage):
    """Read the recorded 12-byte Drotek identity; never infer it from a name.

    In the supplied IoStar3 logs for three controllers, sys_uuid consists of
    000200000000 followed by the reversed dance_status.uuid bytes. This known
    encoding is a cross-check only: sys_uuid alone never creates a GCS identity.
    Every instance/sample must agree, otherwise no automatic association is safe.
    """
    candidates = set()
    expected = {f"uuid[{index}]" for index in range(12)}
    for dataset in datasets:
        if dataset.name != "dance_status":
            continue
        data = dataset.data
        fields = {key for key in data if key.startswith("uuid[")}
        if fields != expected:
            coverage.append("Identité GCS non associée : dance_status.uuid doit contenir exactement 12 octets.")
            return None
        values = [np.asarray(data[f"uuid[{index}]"]) for index in range(12)]
        lengths = {len(value) for value in values if value.ndim == 1}
        timestamps = np.asarray(data.get("timestamp", []))
        if (any(value.ndim != 1 or value.dtype.kind not in "iu" for value in values)
                or len(lengths) != 1 or 0 in lengths
                or ("timestamp" in data and (timestamps.ndim != 1 or len(timestamps) not in lengths))
                or any(np.any(value < 0) or np.any(value > 255) for value in values)):
            coverage.append("Identité GCS non associée : octets ou échantillons dance_status.uuid invalides.")
            return None
        if any(np.any(value != value[0]) for value in values):
            coverage.append("Identité GCS non associée : UUID variable dans dance_status.")
            return None
        identity = bytes(int(value[0]) for value in values).hex().upper()
        if identity in ("0" * 24, "F" * 24):
            coverage.append("Identité GCS non associée : UUID nul ou broadcast dans dance_status.")
            return None
        candidates.add(identity)
    if not candidates:
        return None
    if len(candidates) != 1:
        coverage.append("Identité GCS non associée : instances dance_status contradictoires.")
        return None
    identity = next(iter(candidates))
    recorded = clean_name(info.get("sys_uuid")).upper()
    if (clean_name(info.get("ver_hw")) == "DROTEK_IO_STAR_TROIS"
            and re.fullmatch(r"000200000000[0-9A-F]{24}", recorded)):
        expected_sys_uuid = "000200000000" + bytes.fromhex(identity)[::-1].hex().upper()
        if recorded != expected_sys_uuid:
            coverage.append("Identité GCS non associée : contradiction entre dance_status.uuid et sys_uuid Drotek.")
            return None
    return identity


def is_alert(text, level):
    if level in LEVELS[:5]:
        return True
    return bool(re.search(r"\[ALARM\]|\b(?:connection|link)\b.*\blost\b|\bfailsafe activated\b", text, re.I))


def make_message(message, start, digest, index, source_index=None):
    raw = str(message.message)
    level_number = int(message.log_level)
    if 48 <= level_number <= 55:
        level_number -= 48
    level = LEVELS[level_number] if 0 <= level_number <= 7 else "UNKNOWN"
    family = message_family(raw)
    # Only whitespace is normalized. Error codes, sensor IDs, values and
    # polarity (lost/recovered) remain distinct; every original is retained.
    normalized = " ".join(raw.split())
    title = re.sub(r"^\[[^\]]+\]\s*", "", normalized)
    return {
        "id": f"{digest}-{index}", "timestampSeconds": round((int(message.timestamp) - start) / 1e6, 6),
        "level": level, "text": raw, "family": family,
        "groupKey": f"{family}|{level}|{normalized}", "title": title,
        "isAlert": is_alert(raw, level),
        "source": "ULog:logging_tagged" if hasattr(message, 'tag') else "ULog:logging",
        "tag": int(message.tag) if hasattr(message, 'tag') else None,
        "rawTimestamp": int(message.timestamp), "rawLogLevel": int(message.log_level),
        "sourceIndex": index if source_index is None else source_index,
    }


def add_metric(log, key, label, value, unit, detail):
    value = float(value)
    if math.isfinite(value):
        log["metrics"].append({"key": key, "label": label, "value": round(value, 6), "unit": unit, "detail": detail})


def intervals(data, start, end):
    timestamps = np.asarray(data.get("timestamp", []), dtype=np.float64) / 1e6
    if len(timestamps) < 2:
        return np.zeros(0), np.zeros(0, dtype=bool), timestamps
    raw = np.diff(timestamps)
    durations = np.maximum(0, np.minimum(timestamps[1:], end) - np.maximum(timestamps[:-1], start))
    valid = np.isfinite(raw) & (raw > 0) & (raw <= GAP_SECONDS) & (durations > 0)
    if np.any(raw < 0) or not np.all(np.isfinite(timestamps)):
        # An out-of-order stream can otherwise double-count overlapping spans.
        valid[:] = False
    return durations, valid, timestamps


def gps_metrics(log, dataset, start, end):
    data, instance = dataset.data, dataset.multi_id
    suffix = "" if instance == 0 else f".{instance}"
    detail = f"instance {instance}, pondéré par timestamps; intervalles > {GAP_SECONDS:g} s exclus"
    durations, valid, timestamps = intervals(data, start, end)
    if len(timestamps) < 2:
        log["coverage"].append(f"GNSS instance {instance} : timestamps insuffisants.")
        return
    invalid_count = int(np.count_nonzero(~valid))
    if invalid_count:
        log["coverage"].append(f"GNSS instance {instance} : {invalid_count} intervalles invalides/hors log ou > {GAP_SECONDS:g} s exclus.")
    fixes = data.get("fix_type")
    if fixes is not None and len(fixes) == len(timestamps):
        denominator = float(np.sum(durations[valid]))
        add_metric(log, "gps.observed_seconds" + suffix, "GNSS : durée exploitable", denominator, "s", detail)
        if denominator > 0:
            for key, label, condition in (
                ("rtk_fixed", "RTK fixé", fixes[:-1] == 6),
                ("rtk_float", "RTK flottant", fixes[:-1] == 5),
                ("other_fix", "Autres états GNSS", (fixes[:-1] != 5) & (fixes[:-1] != 6)),
            ):
                add_metric(log, "gps." + key + suffix, label, 100 * np.sum(durations[valid & condition]) / denominator, "%", detail)
    else:
        log["coverage"].append(f"GNSS instance {instance} : fix_type absent.")
    for field, key, label, unit, op in (
        ("satellites_used", "satellites_min", "Satellites minimum", "", np.min),
        ("eph", "eph_max", "Erreur horizontale GNSS estimée max.", "m", np.max),
        ("epv", "epv_max", "Erreur verticale GNSS estimée max.", "m", np.max),
        ("jamming_indicator", "jamming_indicator_max", "Jamming : indicateur brut max.", "", np.max),
        ("jamming_state", "jamming_state_max", "Jamming : état brut max.", "", np.max),
        ("spoofing_state", "spoofing_state_max", "Spoofing : état brut max.", "", np.max),
    ):
        if field in data:
            values = np.asarray(data[field], dtype=float)
            selected = values[np.isfinite(values) & (values >= 0) & (timestamps >= start) & (timestamps <= end)]
            if len(selected):
                add_metric(log, "gps." + key + suffix, label, op(selected), unit, f"instance {instance}, champ {field}; aucun seuil de panne déduit")
    if not any(field in data for field in ("rtcm_age", "rtcm_age_s", "rtcm_time_since_last_injection")):
        log["coverage"].append(f"GNSS instance {instance} : âge des corrections RTCM absent; statut RTK et eph/epv sont disponibles séparément.")


def battery_metrics(log, dataset):
    data, instance = dataset.data, dataset.multi_id
    suffix = "" if instance == 0 else f".{instance}"
    for field, key, label, unit, op in (
        ("voltage_v", "voltage_min", "Tension batterie minimum", "V", np.min),
        ("current_a", "current_max", "Courant batterie maximum", "A", np.max),
        ("temperature", "temperature_max", "Température batterie maximum", "°C", np.max),
        ("remaining", "remaining_min", "Charge restante minimum", "%", np.min),
    ):
        if field not in data:
            log["coverage"].append(f"Batterie instance {instance} : champ {field} absent.")
            continue
        values = np.asarray(data[field], dtype=float)
        valid = np.isfinite(values)
        if "connected" in data:
            valid &= data["connected"] != 0
        if field == "voltage_v":
            valid &= values > 0
        elif field == "current_a":
            valid &= values != -1
        elif field == "temperature":
            valid &= values > -273.15
        elif field == "remaining":
            valid &= (values >= 0) & (values <= 1)
        selected = values[valid]
        if len(selected):
            value = op(selected) * (100 if field == "remaining" else 1)
            add_metric(log, "battery." + key + suffix, label, value, unit,
                       f"instance {instance}; {len(selected)}/{len(values)} échantillons valides et connectés; {field}")
        else:
            log["coverage"].append(f"Batterie instance {instance} : aucune valeur valide pour {field}.")


def flight_duration(log, datasets, start, end):
    log.update(flightSeconds=None, flightCoverageSeconds=None,
               flightCoverageFraction=None, flightObservedSeconds=None)
    candidates = [d for d in datasets if d.name == "vehicle_land_detected" and "landed" in d.data]
    if not candidates:
        log["coverage"].append("Durée de vol inconnue : vehicle_land_detected.landed absent.")
        return
    data = min(candidates, key=lambda d: d.multi_id).data
    durations, valid, timestamps = intervals(data, start, end)
    landed = np.asarray(data["landed"])
    if len(timestamps) < 2 or len(landed) != len(timestamps):
        log["coverage"].append("Durée de vol inconnue : données landed insuffisantes.")
        return
    valid &= np.isin(landed[:-1], (0, 1))
    span = max(0, end - start)
    coverage = float(np.sum(durations[valid]))
    fraction = min(1.0, coverage / span) if span > 0 else None
    observed = float(np.sum(durations[valid & (landed[:-1] == 0)])) if np.any(valid) else None
    log["flightCoverageSeconds"] = round(coverage, 6)
    log["flightCoverageFraction"] = round(fraction, 6) if fraction is not None else None
    log["flightObservedSeconds"] = round(observed, 6) if observed is not None else None
    if not np.any(valid) or span <= 0 or coverage + 1e-6 < span * MIN_FLIGHT_COVERAGE_FRACTION:
        percent = f" ({fraction * 100:.1f} %)" if fraction is not None else ""
        log["coverage"].append(f"Durée de vol inconnue : couverture landed {coverage:.3f}/{span:.3f} s{percent}, minimum {MIN_FLIGHT_COVERAGE_FRACTION * 100:g} % ; lacunes non interpolées.")
        return
    log["flightSeconds"] = log["flightObservedSeconds"]
    log["coverage"].append(f"Durée de vol observée : landed=false, couverture {coverage:.3f}/{span:.3f} s ({fraction * 100:.1f} %) ; extrémités non extrapolées.")


def gps_date(datasets, start, coverage):
    offsets = []
    for dataset in datasets:
        if dataset.name not in ("sensor_gps", "vehicle_gps_position"):
            continue
        data = dataset.data
        if "time_utc_usec" not in data or "timestamp" not in data:
            continue
        utc = np.asarray(data["time_utc_usec"], dtype=np.float64) / 1e6
        mono = np.asarray(data["timestamp"], dtype=np.float64) / 1e6
        # UTC before 2000 or after 2100 is not trustworthy calendar metadata.
        good = np.isfinite(utc) & np.isfinite(mono) & (utc >= 946684800) & (utc < 4102444800)
        if np.count_nonzero(good) < 2:
            continue
        candidate = utc[good] - mono[good]
        # Receiver update/transport latency introduces small jitter. Reject
        # clock jumps rather than claiming an exact date from a single sample.
        if float(np.ptp(candidate)) > 2.0:
            coverage.append(f"Date GPS instance {dataset.multi_id} incohérente (> 2 s de dérive), ignorée.")
            continue
        offsets.append(float(np.median(candidate)))
    if offsets and max(offsets) - min(offsets) <= 2.0:
        return datetime.fromtimestamp(start + float(np.median(offsets)), timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    if len(offsets) > 1:
        coverage.append("Dates GPS contradictoires entre récepteurs, ignorées.")
    return None


def analyze_file(path, root, digest=None, detailed=False, event_dictionary_directory=None, origin_context=None):
    path = Path(path).resolve()
    require_local_source(path)
    digest = digest or digest_file(path)
    # The physical input may be a managed copy. Identity fallback, filename,
    # card name and calendar provenance still belong to the original source.
    log = json.loads(json.dumps(origin_context)) if origin_context is not None else base_log(path, root, digest, path.stat().st_size)
    if log['id'] != digest or log['sizeBytes'] != path.stat().st_size:
        raise ValueError('Le contexte d’origine ne correspond pas au fichier analysé.')
    try:
        log["issues"].extend(preflight(path))
        diagnostics = io.StringIO()
        with contextlib.redirect_stdout(diagnostics):
            # Do not filter topics: filtered pyulog.last_timestamp can shorten
            # the duration and hide corruption in discarded topics.
            ulog = ULog(str(path))
        if diagnostics.getvalue().strip():
            log["issues"].append("pyulog : " + diagnostics.getvalue().strip()[:2000])
        if ulog.file_corruption:
            log["issues"].append("pyulog signale une corruption; données récupérées partielles.")
        if not ulog.data_list and not ulog.logged_messages and not any(ulog.logged_messages_tagged.values()):
            raise ValueError("Aucun échantillon ni message texte exploitable.")
        info = ulog.msg_info_dict
        uuid = clean_name(info.get("sys_uuid"))
        if uuid and uuid.lower() not in ("0", "unknown", "none") and set(uuid.replace("-", "")) != {"0"}:
            log["droneID"] = uuid
        else:
            log["coverage"].append("UUID absent : identité provisoire par carte identifiable ou fichier, non fusionnée par nom.")
        name = clean_name(info.get("drone_name"))
        if name:
            log["droneName"] = name
        for key in ("sys_uuid", "drone_name", "ver_sw", "ver_sw_release", "ver_sw_branch", "ver_hw", "ver_hw_subtype", "sys_name", "ver_data_format"):
            if key in info:
                log["metadata"][key] = clean_name(info[key])
        log["metadata"]["firmware"] = " · ".join(filter(None, [clean_name(info.get("ver_sw_branch")), clean_name(info.get("ver_sw_release")), clean_name(info.get("ver_sw"))[:12]])) or "Inconnu"
        log["metadata"]["parserVersion"] = PARSER_VERSION
        identity = gcs_uuid(ulog.data_list, info, log["coverage"])
        if identity is not None:
            log["metadata"]["gcsUUID"] = identity
            log["metadata"]["gcsIdentityStatus"] = "verified"
        else:
            log["metadata"]["gcsIdentityStatus"] = (
                "rejected" if any(dataset.name == "dance_status" for dataset in ulog.data_list) else "unavailable"
            )
        start, end = int(ulog.start_timestamp), int(ulog.last_timestamp)
        messages = [(message, index) for index, message in enumerate(ulog.logged_messages)]
        for tagged in ulog.logged_messages_tagged.values():
            messages.extend((message, index) for index, message in enumerate(tagged))
        messages.sort(key=lambda item: item[0].timestamp)
        # pyulog.last_timestamp tracks data records but not text records.
        # A text-only log or messages after the last topic must count as well.
        if messages:
            end = max(end, int(messages[-1][0].timestamp))
        log["durationSeconds"] = round(max(0, end - start) / 1e6, 6)
        log["topics"] = sorted(set(dataset.name for dataset in ulog.data_list))
        log["messages"] = [make_message(message, start, digest, index, source_index) for index, (message, source_index) in enumerate(messages)]
        if any(message["level"] == "UNKNOWN" for message in log["messages"]):
            log["coverage"].append("Messages texte avec niveau ULog inconnu conservés sous UNKNOWN.")
        log["failsafeObserved"] = any(re.search(r"\bfailsafe activated\b", message["text"], re.I) for message in log["messages"])
        for dataset in ulog.data_list:
            if dataset.name in ("sensor_gps", "vehicle_gps_position"):
                # Prefer raw sensor_gps; vehicle_gps_position is a fallback,
                # never count both representations as separate receivers.
                if dataset.name == "sensor_gps" or "sensor_gps" not in log["topics"]:
                    gps_metrics(log, dataset, start / 1e6, end / 1e6)
            elif dataset.name == "battery_status":
                battery_metrics(log, dataset)
            elif dataset.name == "event":
                count = len(dataset.data.get("timestamp", []))
                log["coverage"].append(f"Événements binaires non décodés : {count} (instance {dataset.multi_id}); dictionnaire du firmware requis.")
            elif dataset.name == "vehicle_status" and "failsafe" in dataset.data:
                log["failsafeObserved"] |= bool(np.any(dataset.data["failsafe"] != 0))
        flight_duration(log, ulog.data_list, start / 1e6, end / 1e6)
        date = gps_date(ulog.data_list, start / 1e6, log["coverage"])
        if date:
            log["date"], log["dateSource"] = date, "gps"
        elif log["dateSource"] == "path":
            log["coverage"].append("Date issue du chemin, fuseau horaire inconnu.")
        else:
            log["coverage"].append("Date absolue inconnue; timestamps relatifs conservés.")
        if not any(topic.startswith("esc_") for topic in log["topics"]):
            log["coverage"].append("Topic ESC absent : aucune conclusion sur la santé des moteurs/ESC.")
        if not any(topic in log["topics"] for topic in ("sensor_gps", "vehicle_gps_position")):
            log["coverage"].append("Topic GNSS absent.")
        if "battery_status" not in log["topics"]:
            log["coverage"].append("Topic batterie absent.")
        if ulog.dropouts:
            add_metric(log, "recording.dropouts", "Coupures d'enregistrement", len(ulog.dropouts), "", "Messages ULog dropout; ce ne sont pas des coupures radio")
            add_metric(log, "recording.dropout_seconds", "Durée cumulée des coupures", sum(dropout.duration for dropout in ulog.dropouts) / 1000, "s", "Durées dropout ULog en millisecondes")
            log["coverage"].append(f"{len(ulog.dropouts)} coupures d'enregistrement ULog signalées.")
        dictionary_path = None
        if detailed and event_dictionary_directory is not None:
            from px4_events import _sha
            expected = _sha(info.get('metadata_events_sha256'))
            if expected:
                candidate = Path(event_dictionary_directory) / (expected + '.json.xz')
                if candidate.is_file() and not candidate.is_symlink():
                    dictionary_path = candidate
        enrich(log, ulog, detailed=detailed, dictionary_path=dictionary_path)
        log["status"] = "partial" if log["issues"] else "ok"
    except Exception as error:
        log["status"] = "error"
        log["issues"].append(f"{type(error).__name__}: {error}")
        log["messages"] = []
        log["metrics"] = []
        log["durationSeconds"] = 0.0
        log["flightSeconds"] = None
        log["flightCoverageSeconds"] = None
        log["flightCoverageFraction"] = None
        log["flightObservedSeconds"] = None
        log["coverage"].append("Fichier non analysable; aucune absence d'alerte ne peut en être déduite.")
    return log


def remember_log(db, log):
    encoded = json.dumps(log, ensure_ascii=False, allow_nan=False)
    db.execute('SAVEPOINT remember_analysis')
    try:
        old = db.execute('SELECT parser_version,summary FROM logs WHERE id=?', (log['id'],)).fetchone()
        if old:
            archive_analysis(db, log['id'], 'summary', old[0], old[1])
        archive_analysis(db, log['id'], 'summary', PARSER_VERSION, encoded)
        db.execute("INSERT OR REPLACE INTO logs(id,parser_version,summary) VALUES(?,?,?)", (log['id'], PARSER_VERSION, encoded))
        db.execute('RELEASE remember_analysis')
    except Exception:
        db.execute('ROLLBACK TO remember_analysis')
        db.execute('RELEASE remember_analysis')
        raise


def snapshot(db, stats=None):
    from library_sources import active_folders
    from signal_assessment import assessment
    if stats is None:
        stored = db.execute("SELECT value FROM settings WHERE key='lastImportStats'").fetchone()
        stats = json.loads(stored[0]) if stored else dict.fromkeys(("discovered", "imported", "unchanged", "duplicates", "failed"), 0)
    records = [(row[0], json.loads(row[1])) for row in db.execute('SELECT parser_version,summary FROM logs')]
    logs = [value for _, value in records]
    parsers = {value['id']: parser for parser, value in records}
    sources = {}
    for row in db.execute("SELECT log_id,path FROM sources ORDER BY path"):
        sources.setdefault(row[0], []).append(row[1])
    known_files = {row["path"]: row for row in db.execute("SELECT * FROM files")}
    checked_at = utc_now()
    # A name learned later for an existing UUID enriches earlier logs.
    names = {}
    for log in sorted(logs, key=lambda log: log["date"]):
        if log["droneName"] != "Drone non identifié":
            names[log["droneID"]] = log["droneName"]
    for log in logs:
        attach_source_availability(log, sources.get(log["id"], []), known_files, checked_at)
        if not log["sourcePaths"]:
            log["coverage"].append("Source originale indisponible : chemins remplacés par un autre contenu; résumé et messages historiques conservés.")
        log["droneName"] = names.get(log["droneID"], log["droneName"])
        log['identityProvisional'] = str(log['droneID']).startswith(('card:', 'unknown:'))
        current = parsers[log['id']] == PARSER_VERSION
        events, events_complete = [], current and 'topics' in log and 'event' not in log['topics']
        cached = db.execute('SELECT parser_version,summary FROM flight_details WHERE log_id=?', (log['id'],)).fetchone()
        if cached:
            events_complete = False
            try:
                detail_cache = json.loads(cached[1])
                if (isinstance(detail_cache, dict) and detail_cache.get('id') == log['id']
                        and detail_cache.get('status') != 'error' and isinstance(detail_cache.get('events'), list)
                        and all(isinstance(event, dict) for event in detail_cache['events'])):
                    events = detail_cache['events']
                    events_complete = current and cached[0] == PARSER_VERSION
            except (ValueError, TypeError):
                pass
        log['signalAssessment'] = assessment(log, events=events, events_complete=events_complete)
    logs.sort(key=lambda log: (log["date"], log["id"]), reverse=True)
    return {"schemaVersion": SCHEMA_VERSION, "generatedAt": utc_now(),
            "sourceFolders": active_folders(db),
            "importStats": stats, "logs": logs}


def scan(folder, database, output=None, progress=None, skip_snapshot=False, archive_destination=None):
    root = Path(folder).expanduser().resolve()
    exact_file = root if root.is_file() and root.suffix.lower() == '.ulg' else None
    if not root.is_dir() and exact_file is None:
        raise ValueError(f"Dossier introuvable : {root}")
    if exact_file is not None:
        root = exact_file.parent
    discovered = [exact_file] if exact_file else []
    walk_errors = []
    walked = []
    for current, dirs, files in (() if exact_file else os.walk(root, onerror=walk_errors.append, followlinks=False)):
        walked.append(str(Path(current).absolute()))
        dirs.sort()
        for filename in sorted(files):
            if Path(filename).suffix.lower() == ".ulg":
                discovered.append(Path(current) / filename)
    stats = dict.fromkeys(("discovered", "imported", "unchanged", "duplicates", "failed"), 0)
    stats["discovered"] = len(discovered)
    archive_result = None
    if archive_destination is not None:
        archive_result = {'destination': str(Path(archive_destination).expanduser().resolve()), 'completed': 0, 'reused': 0, 'failed': 0, 'skipped': 0, 'errors': [], 'errorsTruncated': False}
        stats.update(archiveRequested=len(discovered), archiveCompleted=0, archiveReused=0, archiveFailed=0, archiveSkipped=0)

    def archive_import(identity, completed, path, signature, origin_context):
        if archive_result is None:
            return path
        if progress:
            atomic_json(progress, {'completed': completed, 'total': len(discovered), 'current': path.name, 'phase': 'archiving',
                                  'archiveCompleted': archive_result['completed'], 'archiveFailed': archive_result['failed']})
        import library_archives
        try:
            result = library_archives.archive_copy_prepared(Path(database).resolve().parent, archive_result['destination'], path, identity, signature, origin_context)
            archive_result['completed'] += 1
            archive_result['reused'] += int(result['reused'])
        except (OSError, ValueError) as error:
            archive_result['failed'] += 1
            if len(archive_result['errors']) < 100:
                archive_result['errors'].append({'logID': identity, 'error': str(error)})
            else:
                archive_result['errorsTruncated'] = True
            raise ArchiveImportError(str(error)) from error
        finally:
            stats.update(archiveCompleted=archive_result['completed'], archiveReused=archive_result['reused'], archiveFailed=archive_result['failed'], archiveSkipped=archive_result['skipped'])
        return Path(result['path'])
    db = open_database(database)
    try:
        db.execute("INSERT OR IGNORE INTO folders(path) VALUES(?)", (str(root),))
        # An explicit import of this root makes a deliberately retired source
        # visible again; historical sources and analyses were never deleted.
        db.execute('DELETE FROM source_folder_retirements WHERE path=?', (str(root),))
        for directory in walked:
            error_id = "directory:" + hashlib.sha256(directory.encode()).hexdigest()
            db.execute("DELETE FROM logs WHERE id=?", (error_id,))
            db.execute("DELETE FROM sources WHERE log_id=?", (error_id,))
        for error in walk_errors:
            directory = Path(error.filename or root).absolute()
            error_id = "directory:" + hashlib.sha256(str(directory).encode()).hexdigest()
            log = base_log(directory, root, error_id, 0)
            log["fileName"] = "Dossier inaccessible : " + directory.name
            log["status"] = "error"
            log["issues"] = [str(error)]
            log["coverage"] = ["Contenu de ce dossier non parcouru; nombre de logs inconnu. Les autres dossiers sont importés."]
            remember_log(db, log)
            db.execute("INSERT OR IGNORE INTO sources(log_id,path) VALUES(?,?)", (error_id, str(directory)))
            stats["failed"] += 1
        db.commit()
        if progress:
            atomic_json(progress, {"completed": 0, "total": len(discovered), "current": ""})
        for index, path in enumerate(discovered):
            absolute = str(path.absolute())
            signature = None
            category = None
            try:
                before = path.stat()
                signature = stat_signature(before)
                cached = db.execute("SELECT files.*,logs.parser_version,logs.summary AS cached_summary FROM files JOIN logs ON logs.id=files.log_id WHERE path=?", (absolute,)).fetchone()
                if cached and tuple(cached[key] for key in ("size", "mtime_ns", "ctime_ns", "inode")) == signature and cached["parser_version"] == PARSER_VERSION and json.loads(cached["cached_summary"]).get("status") != "error":
                    origin_context = base_log(path, root, cached['log_id'], before.st_size)
                    managed = archive_import(cached['log_id'], index, path, signature, origin_context)
                    stats["unchanged"] += 1
                    # Card name metadata can appear after the first import.
                    _, name = card_context(path, root)
                    if name:
                        row = db.execute("SELECT summary FROM logs WHERE id=?", (cached["log_id"],)).fetchone()
                        saved = json.loads(row[0])
                        if saved["droneName"] == "Drone non identifié":
                            saved["droneName"] = name
                            remember_log(db, saved)
                    if archive_result is not None:
                        import library_archives
                        library_archives.link(db, cached['log_id'], managed)
                    observation = source_availability(path, cached['log_id'], cached)
                    db.execute('INSERT OR REPLACE INTO source_observations VALUES(?,?,?,?)', (cached['log_id'], absolute, observation['state'], observation['checkedAt']))
                    db.commit()
                    continue
                digest = digest_file(path)
                origin_context = base_log(path, root, digest, before.st_size)
                managed = archive_import(digest, index, path, signature, origin_context)
                analysis_signature = stat_signature(managed.stat()) if archive_result is not None else signature
                existing = db.execute("SELECT parser_version,summary FROM logs WHERE id=?", (digest,)).fetchone()
                if existing and existing["parser_version"] == PARSER_VERSION and json.loads(existing["summary"]).get("status") != "error":
                    saved = json.loads(existing["summary"])
                    _, name = card_context(path, root)
                    if name and saved["droneName"] == "Drone non identifié":
                        saved["droneName"] = name
                        remember_log(db, saved)
                    category = "duplicates"
                else:
                    saved = analyze_file(managed, root, digest, origin_context=origin_context) if archive_result is not None else analyze_file(path, root, digest)
                    remember_log(db, saved)
                    category = "failed" if saved["status"] == "error" else "imported"
                if stat_signature(managed.stat()) != analysis_signature:
                    raise OSError("Le fichier a changé pendant l'analyse; réimporter une fois la copie terminée.")
                db.execute("INSERT OR REPLACE INTO files(path,size,mtime_ns,ctime_ns,inode,log_id) VALUES(?,?,?,?,?,?)", (absolute, *signature, digest))
                db.execute("DELETE FROM sources WHERE path=? AND log_id<>?", (absolute, digest))
                db.execute("INSERT OR IGNORE INTO sources(log_id,path) VALUES(?,?)", (digest, absolute))
                if archive_result is not None:
                    import library_archives
                    library_archives.link(db, digest, managed)
                    observation = source_availability(path, digest, {'log_id': digest, **dict(zip(('size', 'mtime_ns', 'ctime_ns', 'inode'), signature))})
                    db.execute('INSERT OR REPLACE INTO source_observations VALUES(?,?,?,?)', (digest, absolute, observation['state'], observation['checkedAt']))
                else:
                    db.execute('INSERT OR REPLACE INTO source_observations VALUES(?,?,?,?)', (digest, absolute, 'present', utc_now()))
                # Remove a former transient read error after a successful retry.
                unreadable_id = "unreadable:" + hashlib.sha256(absolute.encode()).hexdigest()
                db.execute("DELETE FROM logs WHERE id=?", (unreadable_id,))
                db.execute("DELETE FROM sources WHERE log_id=?", (unreadable_id,))
                db.commit()
                stats[category] += 1
            except RevisionBudgetError:
                db.rollback()
                raise
            except ArchiveImportError:
                # A requested safe copy is a prerequisite. Keep all previous
                # analysis/cache rows intact and publish no fabricated error.
                db.rollback()
                stats['failed'] += 1
            except (OSError, ValueError) as error:
                db.rollback()
                # A read failure is path-based because its content is unavailable.
                digest = "unreadable:" + hashlib.sha256(absolute.encode()).hexdigest()
                saved = base_log(path, root, digest, signature[0] if signature else 0)
                saved["status"] = "error"
                saved["issues"] = [f"{type(error).__name__}: {error}"]
                saved["coverage"] = ["Fichier non analysable; réessayer l'import lorsque la source est disponible."]
                remember_log(db, saved)
                db.execute("INSERT OR IGNORE INTO sources(log_id,path) VALUES(?,?)", (digest, absolute))
                # Never cache a failed read: the next scan retries it.
                db.execute("DELETE FROM files WHERE path=?", (absolute,))
                db.commit()
                stats["failed"] += 1
                if archive_result is not None:
                    archive_result['skipped'] += 1
                    stats['archiveSkipped'] = archive_result['skipped']
            finally:
                if progress:
                    state = {"completed": index + 1, "total": len(discovered), "current": path.name}
                    if archive_result is not None:
                        state.update(phase='analyzing', archiveCompleted=archive_result['completed'], archiveFailed=archive_result['failed'], archiveSkipped=archive_result['skipped'])
                    atomic_json(progress, state)
        db.execute("INSERT OR REPLACE INTO settings(key,value) VALUES('lastImportStats',?)", (json.dumps(stats),))
        db.commit()
        if skip_snapshot:
            import library_repository
            library_repository.initialize(db)
            revision = int(db.execute("SELECT value FROM kl_meta WHERE key='revision'").fetchone()[0])
            result = {"schemaVersion": SCHEMA_VERSION, "generatedAt": utc_now(),
                      "sourceFolders": [row[0] for row in db.execute("SELECT path FROM folders ORDER BY path")],
                      "revision": revision, "importStats": stats, "logs": []}
        else:
            result = snapshot(db, stats)
        if archive_result is not None:
            result['archiveResult'] = archive_result
        if output:
            atomic_json(output, result)
        return result
    finally:
        db.close()


def detail(log_id, database, output=None, read_only=False, revision=None):
    if not re.fullmatch(r"[a-f0-9]{64}", log_id):
        raise ValueError("Identifiant de contenu ULog invalide.")
    db = open_database(database, read_only=read_only)
    try:
        summary = db.execute("SELECT summary FROM logs WHERE id=?", (log_id,)).fetchone()
        if not summary:
            raise ValueError("Ce log n’est pas dans la bibliothèque.")
        saved = json.loads(summary[0])
        sources = [row[0] for row in db.execute("SELECT path FROM sources WHERE log_id=? ORDER BY path", (log_id,))]
        if revision is not None:
            if not re.fullmatch(r'[a-f0-9]{64}', revision):
                raise ValueError('Identifiant de révision invalide.')
            if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='analysis_revisions'").fetchone():
                raise ValueError('Aucune révision historique conservée.')
            row = db.execute('SELECT * FROM analysis_revisions WHERE id=? AND log_id=?', (revision, log_id)).fetchone()
            if not row:
                raise ValueError('Cette révision n’appartient pas au log sélectionné.')
            result = decoded_revision(row)
            result['analysisRevision'] = revision_metadata(db, row)
            result['metadata']['analysisRevisionID'] = row['id']
            result['metadata']['analysisRevisionDate'] = row['created_at']
            result['metadata']['analysisRevisionSHA'] = row['analysis_sha256']
            result['metadata']['detailCacheStatus'] = 'historical'
            result['metadata']['detailParserVersion'] = row['parser_version']
            known_files = {row['path']: row for row in db.execute("SELECT * FROM files WHERE path IN (SELECT path FROM sources WHERE log_id=?)", (log_id,))}
            attach_source_availability(result, sources, known_files)
            if output:
                atomic_json(output, result)
            return result
        cached = db.execute("SELECT parser_version,summary FROM flight_details WHERE log_id=?", (log_id,)).fetchone()
        retained_revision = None
        if cached is None and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='analysis_revisions'").fetchone():
            retained_revision = db.execute("SELECT * FROM analysis_revisions WHERE log_id=? AND kind='detail' ORDER BY created_at DESC,id DESC LIMIT 1", (log_id,)).fetchone()
            if retained_revision:
                retained_value = decoded_revision(retained_revision)
                cached = {'parser_version': retained_revision['parser_version'], 'summary': json.dumps(retained_value, ensure_ascii=False, allow_nan=False)}
        previous = None
        if cached:
            try:
                value = json.loads(cached["summary"])
                if isinstance(value, dict) and value.get("id") == log_id and value.get("status") != "error":
                    previous = value
            except (ValueError, TypeError):
                pass
        expected_dictionary = (previous or {}).get('eventDictionary', {}).get('expectedSHA256')
        available_dictionary = Path(database).resolve().parent / 'event-dictionaries' / (str(expected_dictionary) + '.json.xz')
        dictionary_changed = (bool(re.fullmatch(r'[a-f0-9]{64}', str(expected_dictionary)))
                              and available_dictionary.is_file() and not available_dictionary.is_symlink()
                              and (previous.get('eventDictionary', {}).get('status') != 'ready'
                                   or previous.get('eventDictionary', {}).get('sha256') != expected_dictionary)) if previous else False
        if previous is not None and cached["parser_version"] == PARSER_VERSION and not dictionary_changed:
            result = previous
            cache_status = 'previous' if retained_revision else 'current'
            if retained_revision:
                result['coverage'].append('Dernière analyse historique conservée après nettoyage du cache ; aucune nouvelle analyse n’a été calculée.')
        else:
            result = None
            errors = []
            for source in sources:
                path = Path(source)
                try:
                    before = stat_signature(path.stat())
                    if digest_file(path) != log_id:
                        continue
                    candidate = analyze_file(path, path.parent, log_id, detailed=True, event_dictionary_directory=Path(database).resolve().parent / 'event-dictionaries')
                    if stat_signature(path.stat()) != before:
                        continue
                except CloudSourceUnavailableError as error:
                    errors.append(str(error))
                    continue
                except OSError:
                    continue
                if candidate['status'] == 'error':
                    errors.extend(candidate['issues'])
                    continue
                result = candidate
                break
            if result is None:
                if previous is None:
                    if errors:
                        raise ValueError('Lecture des détails impossible : ' + '; '.join(errors))
                    raise ValueError("Source ULog absente ou modifiée : les résumés restent conservés. Réimportez une copie originale pour ouvrir ses détails.")
                result = previous
                cache_status = "previous"
                reason = "recalcul impossible" if errors else "source absente ou modifiée"
                if dictionary_changed:
                    reason += ' ; dictionnaire exact disponible mais traduction non recalculée'
                result['coverage'].append(f"Analyse précédente conservée (parseur {cached['parser_version']}) : {reason}. Les données ne sont pas recalculées avec le parseur {PARSER_VERSION}.")
            else:
                # Reanalysis may run from a relocated copy whose path cannot
                # recover the original SD/card boundary. Content identity and
                # canonical controller/date provenance come from the library.
                for key in ('droneID', 'droneName', 'date', 'dateSource', 'fileName'):
                    result[key] = saved[key]
                if not read_only:
                    db.execute('SAVEPOINT publish_detail_analysis')
                    try:
                        if cached:
                            archive_analysis(db, log_id, 'detail', cached['parser_version'], cached['summary'])
                        encoded = json.dumps(result, ensure_ascii=False, allow_nan=False)
                        archive_analysis(db, log_id, 'detail', PARSER_VERSION, encoded)
                        db.execute("INSERT OR REPLACE INTO flight_details(log_id,parser_version,summary) VALUES(?,?,?)", (log_id, PARSER_VERSION, encoded))
                        db.execute('RELEASE publish_detail_analysis')
                    except Exception:
                        db.execute('ROLLBACK TO publish_detail_analysis')
                        db.execute('RELEASE publish_detail_analysis')
                        raise
                    db.commit()
                cache_status = "current"
        # Also repair legacy cached details produced before canonical identity
        # was preserved. The immutable recorded content remains unchanged.
        for key in ('droneID', 'droneName', 'date', 'dateSource', 'fileName'):
            result[key] = saved[key]
        result['metadata']['detailCacheStatus'] = cache_status
        result['metadata']['detailParserVersion'] = cached['parser_version'] if cache_status == 'previous' else PARSER_VERSION
        persisted = db.execute('SELECT parser_version,summary FROM flight_details WHERE log_id=?', (log_id,)).fetchone()
        revision_row = None
        if persisted and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='analysis_revisions'").fetchone():
            if not read_only:
                archive_analysis(db, log_id, 'detail', persisted[0], persisted[1])
                db.commit()
            checksum = hashlib.sha256(persisted[1].encode()).hexdigest()
            revision_row = db.execute("SELECT id,log_id,kind,parser_version,analysis_sha256,created_at,size_bytes FROM analysis_revisions WHERE log_id=? AND kind='detail' AND parser_version=? AND analysis_sha256=?", (log_id, persisted[0], checksum)).fetchone()
        if revision_row:
            result['analysisRevision'] = revision_metadata(db, revision_row)
        elif retained_revision:
            result['analysisRevision'] = revision_metadata(db, retained_revision)
        known_files = {row['path']: row for row in db.execute("SELECT * FROM files WHERE path IN (SELECT path FROM sources WHERE log_id=?)", (log_id,))}
        attach_source_availability(result, sources, known_files)
        if not read_only:
            for observation in result['sourceAvailability']:
                db.execute('INSERT OR REPLACE INTO source_observations VALUES(?,?,?,?)', (log_id, observation['path'], observation['state'], observation['checkedAt']))
            db.commit()
            # Detail writes enqueue event projections. Publish the derived
            # revision before handing back control to read-only fleet queries.
            import library_repository
            library_repository.initialize(db)
        if output:
            atomic_json(output, result)
        return result
    finally:
        db.close()


def refresh_analysis(database, output=None, progress=None):
    """Refresh stale summaries globally, preserving old analysis on failure."""
    db = open_database(database)
    stats = {'total': 0, 'reanalyzed': 0, 'unavailable': 0, 'failed': 0}
    try:
        stale_ids = [row[0] for row in db.execute('SELECT id FROM logs WHERE parser_version<>? ORDER BY id', (PARSER_VERSION,))]
        stats['total'] = len(stale_ids)
        for index, identity in enumerate(stale_ids):
            row = db.execute('SELECT summary FROM logs WHERE id=?', (identity,)).fetchone()
            saved = json.loads(row[0])
            available, refreshed = False, False
            for source in db.execute('SELECT path FROM sources WHERE log_id=? ORDER BY path', (identity,)):
                path = Path(source[0])
                try:
                    before = stat_signature(path.stat())
                    if digest_file(path) != identity:
                        continue
                    available = True
                    candidate = analyze_file(path, path.parent, identity)
                    if stat_signature(path.stat()) != before or candidate['status'] == 'error':
                        continue
                    candidate['droneID'], candidate['droneName'] = saved['droneID'], saved['droneName']
                    if not candidate.get('date') and saved.get('date'):
                        candidate['date'], candidate['dateSource'] = saved['date'], saved['dateSource']
                    remember_log(db, candidate)
                    db.commit()
                    refreshed = True
                    stats['reanalyzed'] += 1
                    break
                except OSError:
                    continue
            if not refreshed:
                stats['failed' if available else 'unavailable'] += 1
            if progress:
                atomic_json(progress, {'completed': index + 1, 'total': len(stale_ids), 'current': saved.get('fileName', '')})
        import library_repository
        library_repository.initialize(db)
        result = {'refreshVersion': 1, 'generatedAt': utc_now(), 'revision': int(db.execute("SELECT value FROM kl_meta WHERE key='revision'").fetchone()[0]), **stats}
        if output: atomic_json(output, result)
        return result
    finally:
        db.close()


def indexed_status(database, request):
    if not isinstance(request, dict) or not isinstance(request.get('logIDs'), list) or len(request['logIDs']) > 1000 or any(not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{64}', value) for value in request['logIDs']):
        raise ValueError('La requête d’index exige au plus 1000 identifiants SHA.')
    if request.get('parserVersion') is not None and not isinstance(request['parserVersion'], str):
        raise ValueError('Version de parseur invalide.')
    selected = list(dict.fromkeys(request['logIDs']))
    db = open_database(database, read_only=True)
    found = {}
    try:
        import library_repository
        db.execute('BEGIN')
        metadata = dict(db.execute('SELECT key,value FROM kl_meta'))
        if metadata.get('initialized') != '1' or metadata.get('projectionVersion') != str(library_repository.PROJECTION_VERSION) or db.execute('SELECT 1 FROM kl_dirty LIMIT 1').fetchone():
            raise ValueError('L’index doit être actualisé par l’instance disposant de l’accès en écriture.')
        for offset in range(0, len(selected), 900):
            page = selected[offset:offset+900]
            for row in db.execute('SELECT l.id,l.status,c.parser_version FROM kl_logs l JOIN logs c ON c.id=l.id WHERE l.id IN (' + ','.join('?' for _ in page) + ')', page):
                found[row[0]] = {'id': row[0], 'status': row[1], 'parserVersion': row[2]}
    except sqlite3.OperationalError as error:
        raise ValueError('L’index doit être préparé par l’instance disposant de l’accès en écriture.') from error
    finally:
        db.close()
    return {'indexVersion': 1, 'logs': [found[identity] for identity in selected if identity in found], 'missing': [identity for identity in selected if identity not in found]}


def import_event_dictionary(database, file):
    """Install only a bounded, valid, exact compressed libevents artifact."""
    from types import SimpleNamespace
    from px4_events import _dictionary, MAX_ARTIFACT_BYTES
    source = Path(file).resolve()
    before = stat_signature(source.stat())
    with source.open('rb') as handle:
        payload = handle.read(MAX_ARTIFACT_BYTES + 1)
    if len(payload) > MAX_ARTIFACT_BYTES or not payload.startswith(b'\xfd7zXZ\x00'):
        raise ValueError('Le dictionnaire PX4 doit être un artefact .json.xz valide de 4 Mio maximum.')
    if stat_signature(source.stat()) != before:
        raise ValueError('Le dictionnaire a changé pendant sa lecture.')
    checksum = hashlib.sha256(payload).hexdigest()
    _, inspection = _dictionary(SimpleNamespace(msg_info_dict={'metadata_events_sha256': checksum}), {}, source)
    if inspection['status'] != 'ready':
        raise ValueError('Dictionnaire PX4 rejeté : ' + inspection.get('reason', inspection['status']))
    db = open_database(database, read_only=True)
    try:
        # A damaged legacy detail cache must not prevent installing an exact
        # artifact for the other flights. Details are optional cached data.
        matching = db.execute("SELECT COUNT(*) FROM flight_details WHERE CASE WHEN json_valid(summary) THEN json_extract(summary,'$.eventDictionary.expectedSHA256') END=?", (checksum,)).fetchone()[0]
    finally:
        db.close()
    directory = Path(database).resolve().parent / 'event-dictionaries'
    if directory.is_symlink():
        raise ValueError('Le dossier des dictionnaires ne doit pas être un lien symbolique.')
    directory.mkdir(exist_ok=True)
    destination = directory / (checksum + '.json.xz')
    reused = destination.exists()
    if reused:
        if destination.is_symlink() or digest_file(destination) != checksum:
            raise ValueError('L’artefact déjà installé ne correspond pas à son empreinte.')
    else:
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(prefix='.dictionary-', suffix='.partial', dir=directory, delete=False) as handle:
                temporary = Path(handle.name)
                handle.write(payload); handle.flush(); os.fsync(handle.fileno())
            try:
                os.link(temporary, destination)
            except FileExistsError:
                if destination.is_symlink() or digest_file(destination) != checksum:
                    raise ValueError('L’artefact concurrent ne correspond pas à son empreinte.')
                reused = True
        finally:
            if temporary:
                temporary.unlink(missing_ok=True)
    return {'dictionaryVersion': 1, 'sha256': checksum, 'definitionVersion': inspection['definitionVersion'],
            'path': str(destination), 'sizeBytes': len(payload), 'reused': reused, 'matchingCachedLogs': matching}


def telemetry_series(log_id, database, request):
    """Extract a bounded recipe from one SHA-verified source, without writes."""
    if not re.fullmatch(r'[a-f0-9]{64}', log_id) or not isinstance(request, dict) or request.get('seriesVersion', 1) != 1:
        raise ValueError('Identifiant ou version de requête de télémétrie invalide.')
    db = open_database(database, read_only=True)
    try:
        if not db.execute('SELECT 1 FROM logs WHERE id=?', (log_id,)).fetchone():
            raise ValueError('Ce log n’est pas dans la bibliothèque.')
        paths = [row[0] for row in db.execute('SELECT path FROM sources WHERE log_id=? ORDER BY path', (log_id,))]
    finally:
        db.close()
    from telemetry_extractor import extract_recipe, extract_series, RECIPES
    for source in paths:
        path = Path(source)
        try:
            before = stat_signature(path.stat())
            if digest_file(path) != log_id:
                continue
            recipe = request.get('recipe')
            fields = RECIPES.get(recipe, []) if isinstance(recipe, str) else recipe or [(request.get('topic'), request.get('field'))]
            topics = sorted({item[0] for item in fields if isinstance(item, (list, tuple)) and len(item) == 2 and isinstance(item[0], str)})
            ulog = ULog(str(path), message_name_filter_list=topics)
            options = {key: request[key] for key in ('instance', 'timeFrom', 'timeTo', 'budget') if key in request}
            if request.get('recipe') is not None:
                value = extract_recipe(ulog, request['recipe'], **options)
            else:
                if not isinstance(request.get('topic'), str) or not isinstance(request.get('field'), str):
                    raise ValueError('Sélectionnez un topic et un champ, ou une recette de télémétrie.')
                series = extract_series(ulog, request['topic'], request['field'], **options)
                value = {'series': [series], 'missingFields': [], 'pointBudget': request.get('budget', 2048), 'displayedPointCount': series['displayedPointCount']}
            if stat_signature(path.stat()) != before:
                continue
            return {'seriesVersion': 1, 'logID': log_id, **value}
        except OSError:
            continue
    raise ValueError('Source ULog absente ou modifiée : une copie originale est nécessaire pour charger les séries.')


def main(argv=None):
    parser = argparse.ArgumentParser(description="Import local incrémental de logs PX4")
    commands = parser.add_subparsers(dest="command", required=True)
    scan_command = commands.add_parser("scan")
    scan_command.add_argument("--folder", required=True)
    scan_command.add_argument("--database", required=True)
    scan_command.add_argument("--output", required=True)
    scan_command.add_argument("--progress")
    scan_command.add_argument("--skip-snapshot", action="store_true")
    scan_command.add_argument('--archive-destination')
    snapshot_command = commands.add_parser("snapshot")
    snapshot_command.add_argument("--database", required=True)
    snapshot_command.add_argument("--output", required=True)
    snapshot_command.add_argument("--read-only", action="store_true")
    for name in ('source-folders', 'retire-source', 'restore-source'):
        command = commands.add_parser(name)
        command.add_argument('--database', required=True)
        command.add_argument('--output', required=True)
        if name == 'source-folders':
            command.add_argument('--offset', type=int, default=0)
            command.add_argument('--limit', type=int, default=200)
            command.add_argument('--include-removed', action='store_true')
        else:
            command.add_argument('--folder', required=True)
    query_command = commands.add_parser("query")
    query_command.add_argument("--request", required=True)
    query_command.add_argument("--database", required=True)
    query_command.add_argument("--output", required=True)
    query_command.add_argument("--read-only", action="store_true")
    index_command = commands.add_parser("ensure-index")
    index_command.add_argument("--database", required=True)
    index_command.add_argument("--output", required=True)
    refresh_command = commands.add_parser('refresh-analysis')
    refresh_command.add_argument('--database', required=True)
    refresh_command.add_argument('--output', required=True)
    refresh_command.add_argument('--progress')
    status_command = commands.add_parser('indexed-status')
    status_command.add_argument('--database', required=True)
    status_command.add_argument('--request', required=True)
    status_command.add_argument('--output', required=True)
    dictionary_command = commands.add_parser('event-dictionary')
    dictionary_command.add_argument('--database', required=True)
    dictionary_command.add_argument('--file', required=True)
    dictionary_command.add_argument('--output', required=True)
    detail_command = commands.add_parser("detail")
    detail_command.add_argument("--log-id", required=True)
    detail_command.add_argument("--database", required=True)
    detail_command.add_argument("--output", required=True)
    detail_command.add_argument("--read-only", action="store_true")
    detail_command.add_argument('--revision')
    revisions_command = commands.add_parser('analysis-revisions')
    revisions_command.add_argument('--log-id', required=True)
    revisions_command.add_argument('--database', required=True)
    revisions_command.add_argument('--output', required=True)
    revisions_command.add_argument('--offset', type=int, default=0)
    revisions_command.add_argument('--limit', type=int, default=32)
    revisions_command.add_argument('--read-only', action='store_true')
    series_command = commands.add_parser('series')
    series_command.add_argument('--log-id', required=True)
    series_command.add_argument('--database', required=True)
    series_command.add_argument('--request')
    series_command.add_argument('--recipe', choices=('battery', 'gnss', 'ekf'))
    series_command.add_argument('--topic')
    series_command.add_argument('--field')
    series_command.add_argument('--instance', type=int, default=0)
    series_command.add_argument('--time-from', type=float)
    series_command.add_argument('--time-to', type=float)
    series_command.add_argument('--budget', type=int, default=2048)
    series_command.add_argument('--output', required=True)
    for name in ('capture-report', 'export-captured'):
        command = commands.add_parser(name)
        command.add_argument('--capture', required=True)
        command.add_argument('--output', required=True)
        if name == 'capture-report':
            command.add_argument('--database', required=True)
            command.add_argument('--request', required=True)
        else:
            command.add_argument('--destination', required=True)
            command.add_argument('--progress')
    for name in ('storage-info', 'archive', 'recover-archive', 'reassociate', 'clean-cache', 'restore-cache'):
        command = commands.add_parser(name)
        command.add_argument('--database', required=True)
        command.add_argument('--output', required=True)
        if name in ('storage-info', 'archive', 'recover-archive', 'clean-cache'):
            command.add_argument('--library', required=True)
        if name in ('archive', 'clean-cache'):
            command.add_argument('--request', required=True)
        if name == 'archive':
            command.add_argument('--destination', required=True)
        if name == 'storage-info':
            command.add_argument('--offset', type=int, default=0)
            command.add_argument('--limit', type=int, default=200)
        if name == 'reassociate':
            command.add_argument('--folder', required=True)
        if name == 'restore-cache':
            command.add_argument('--recovery', required=True)
    backup_command = commands.add_parser("backup")
    backup_command.add_argument("--library", required=True)
    backup_command.add_argument("--destination", required=True)
    backup_command.add_argument("--include-ulog", action="store_true")
    backup_command.add_argument("--output", required=True)
    inspect_command = commands.add_parser("inspect-backup")
    inspect_command.add_argument("--archive", required=True)
    inspect_command.add_argument("--output", required=True)
    restore_command = commands.add_parser("restore")
    restore_command.add_argument("--archive", required=True)
    restore_command.add_argument("--library", required=True)
    restore_command.add_argument("--output", required=True)
    recover_command = commands.add_parser("recover-restore")
    recover_command.add_argument("--library", required=True)
    recover_command.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command in ('source-folders', 'retire-source', 'restore-source'):
            import library_sources
            result = (library_sources.source_folders(args.database, args.offset, args.limit, args.include_removed)
                      if args.command == 'source-folders' else
                      library_sources.set_removed(args.database, args.folder, args.command == 'retire-source'))
            atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'ok': True}))
            return 0
        if args.command == 'analysis-revisions':
            result = analysis_revisions(args.log_id, args.database, args.offset, args.limit, args.read_only)
            atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'ok': True}))
            return 0
        if args.command == 'event-dictionary':
            result = import_event_dictionary(args.database, args.file)
            atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'sha256': result['sha256'], 'ok': True}))
            return 0
        if args.command == 'indexed-status':
            if Path(args.request).stat().st_size > 1024 * 1024:
                raise ValueError('Requête d’index trop volumineuse.')
            result = indexed_status(args.database, json.loads(Path(args.request).read_text(encoding='utf-8')))
            atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'ok': True}))
            return 0
        if args.command == 'refresh-analysis':
            result = refresh_analysis(args.database, args.output, args.progress)
            print(json.dumps({'command': args.command, 'revision': result['revision'], 'ok': True}))
            return 0
        if args.command == 'series':
            if args.request:
                if Path(args.request).stat().st_size > 1024 * 1024:
                    raise ValueError('Requête de télémétrie trop volumineuse.')
                request = json.loads(Path(args.request).read_text(encoding='utf-8'))
            else:
                request = {'seriesVersion': 1, 'instance': args.instance, 'budget': args.budget}
                if args.recipe: request['recipe'] = args.recipe
                else: request.update(topic=args.topic, field=args.field)
                if args.time_from is not None: request['timeFrom'] = args.time_from
                if args.time_to is not None: request['timeTo'] = args.time_to
            result = telemetry_series(args.log_id, args.database, request)
            atomic_json(args.output, result)
            print(json.dumps({'command': 'series', 'logID': args.log_id, 'ok': True}))
            return 0
        if args.command in ('capture-report', 'export-captured'):
            import library_reports
            if args.command == 'capture-report':
                if Path(args.request).stat().st_size > 16 * 1024 * 1024:
                    raise ValueError('Requête de rapport trop volumineuse.')
                result = library_reports.capture_report(args.database, args.capture, json.loads(Path(args.request).read_text(encoding='utf-8')))
            else:
                result = library_reports.prepare_report(args.capture, args.destination, progress=args.progress)
            atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'ok': True}))
            return 0
        if args.command in ('storage-info', 'archive', 'recover-archive', 'reassociate', 'clean-cache', 'restore-cache'):
            import library_archives
            request = None
            if hasattr(args, 'request'):
                if Path(args.request).stat().st_size > 16 * 1024 * 1024:
                    raise ValueError('Sélection de stockage trop volumineuse.')
                request = json.loads(Path(args.request).read_text(encoding='utf-8'))
            if args.command == 'storage-info': result = library_archives.storage_info(args.database, args.library, args.offset, args.limit)
            elif args.command == 'archive': result = library_archives.archive_logs(args.database, args.library, args.destination, request.get('logIDs'))
            elif args.command == 'recover-archive': result = library_archives.recover_archive(args.database, args.library)
            elif args.command == 'reassociate': result = library_archives.reassociate(args.database, args.folder)
            elif args.command == 'clean-cache': result = library_archives.clean_detail_cache(args.database, args.library, request.get('logIDs'))
            else: result = library_archives.restore_detail_cache(args.database, args.recovery)
            atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'ok': True}))
            return 0
        if args.command in ("query", "ensure-index"):
            import library_repository
            db = open_database(args.database, read_only=getattr(args, "read_only", False))
            try:
                if args.command == "ensure-index":
                    library_repository.initialize(db)
                    result = {"queryVersion": 1, "revision": int(db.execute("SELECT value FROM kl_meta WHERE key='revision'").fetchone()[0]), "ok": True}
                else:
                    if Path(args.request).stat().st_size > 16 * 1024 * 1024:
                        raise ValueError("La requête de bibliothèque dépasse 16 Mio.")
                    request = json.loads(Path(args.request).read_text(encoding="utf-8"))
                    result = library_repository.query(db, request, read_only=args.read_only)
            finally:
                db.close()
            atomic_json(args.output, result)
            print(json.dumps({"command": args.command, "revision": result["revision"], "ok": True}))
            return 0
        if args.command in ("backup", "inspect-backup", "restore", "recover-restore"):
            import library_storage
            if args.command == "backup":
                result = library_storage.backup(args.library, args.destination, args.include_ulog)
            elif args.command == "inspect-backup":
                result = library_storage.inspect_backup(args.archive)
            elif args.command == "restore":
                result = library_storage.restore(args.archive, args.library)
            else:
                result = library_storage.recover_restore(args.library)
            atomic_json(args.output, result)
            print(json.dumps({"command": args.command, "ok": True}))
            return 0
        if args.command == "detail":
            result = detail(args.log_id, args.database, args.output, read_only=args.read_only, revision=args.revision)
            print(json.dumps({"logID": result["id"], "status": result["status"]}))
            return 0
        if args.command == "scan":
            result = scan(args.folder, args.database, args.output, args.progress, skip_snapshot=args.skip_snapshot, archive_destination=args.archive_destination)
        else:
            db = open_database(args.database, read_only=args.read_only)
            try:
                result = snapshot(db)
            finally:
                db.close()
            atomic_json(args.output, result)
        print(json.dumps({"logs": len(result["logs"]), "importStats": result["importStats"]}, ensure_ascii=False))
        return 0
    except Exception as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
