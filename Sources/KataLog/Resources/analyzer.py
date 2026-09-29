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
import struct
import sys
import tempfile

import numpy as np
from pyulog import ULog

# Works both as a bundled CLI and when loaded by file path in test tools.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from flight_data import enrich

SCHEMA_VERSION = 1
PARSER_VERSION = "1.2.0"
MESSAGE_FAMILIES = ("Batterie", "Communication", "GNSS", "Capteurs", "Propulsion", "Navigation", "Système", "Éclairage", "Température", "Autres")
LEVELS = ("EMERGENCY", "ALERT", "CRITICAL", "ERROR", "WARNING", "NOTICE", "INFO", "DEBUG")
GAP_SECONDS = 10.0


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


def open_database(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(path), timeout=30)
    db.row_factory = sqlite3.Row
    version = db.execute("PRAGMA user_version").fetchone()[0]
    if version not in (0, SCHEMA_VERSION):
        db.close()
        raise RuntimeError(f"Base de version {version} non prise en charge (attendu {SCHEMA_VERSION}).")
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
        CREATE TABLE IF NOT EXISTS folders (path TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """)
    db.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
    db.commit()
    return db


def digest_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stat_signature(stat):
    return (stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns, stat.st_ino)


def clean_name(value):
    return str(value).replace("\x00", "").strip()[:200] if value is not None else ""


def card_context(path, root):
    """Prefer nearest card metadata; no inferred common vehicle at fleet root."""
    root = Path(root).resolve()
    for ancestor in path.parents:
        candidate = ancestor / "data" / "name.txt"
        try:
            if candidate.is_file():
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
        "flightSeconds": None, "status": "ok", "issues": [], "metadata": {},
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


def make_message(message, start, digest, index):
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
    span = end - start
    coverage = float(np.sum(durations[valid]))
    if not np.any(valid) or coverage < max(0, span - max(2.0, span * 0.01)):
        log["coverage"].append(f"Durée de vol inconnue : couverture landed {coverage:.1f}/{span:.1f} s, lacunes non interpolées.")
        return
    log["flightSeconds"] = round(float(np.sum(durations[valid & (landed[:-1] == 0)])), 6)
    log["coverage"].append("Durée de vol observée : landed=false, sur la portion enregistrée; extrémités non extrapolées.")


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


def analyze_file(path, root, digest=None, detailed=False):
    path = Path(path).resolve()
    digest = digest or digest_file(path)
    log = base_log(path, root, digest, path.stat().st_size)
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
        messages = list(ulog.logged_messages)
        for tagged in ulog.logged_messages_tagged.values():
            messages.extend(tagged)
        messages.sort(key=lambda message: message.timestamp)
        # pyulog.last_timestamp tracks data records but not text records.
        # A text-only log or messages after the last topic must count as well.
        if messages:
            end = max(end, int(messages[-1].timestamp))
        log["durationSeconds"] = round(max(0, end - start) / 1e6, 6)
        log["topics"] = sorted(set(dataset.name for dataset in ulog.data_list))
        log["messages"] = [make_message(message, start, digest, index) for index, message in enumerate(messages)]
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
        enrich(log, ulog, detailed=detailed)
        log["status"] = "partial" if log["issues"] else "ok"
    except Exception as error:
        log["status"] = "error"
        log["issues"].append(f"{type(error).__name__}: {error}")
        log["messages"] = []
        log["metrics"] = []
        log["durationSeconds"] = 0.0
        log["flightSeconds"] = None
        log["coverage"].append("Fichier non analysable; aucune absence d'alerte ne peut en être déduite.")
    return log


def remember_log(db, log):
    db.execute("INSERT OR REPLACE INTO logs(id,parser_version,summary) VALUES(?,?,?)",
               (log["id"], PARSER_VERSION, json.dumps(log, ensure_ascii=False, allow_nan=False)))


def snapshot(db, stats=None):
    if stats is None:
        stored = db.execute("SELECT value FROM settings WHERE key='lastImportStats'").fetchone()
        stats = json.loads(stored[0]) if stored else dict.fromkeys(("discovered", "imported", "unchanged", "duplicates", "failed"), 0)
    logs = [json.loads(row[0]) for row in db.execute("SELECT summary FROM logs")]
    sources = {}
    for row in db.execute("SELECT log_id,path FROM sources ORDER BY path"):
        sources.setdefault(row[0], []).append(row[1])
    # A name learned later for an existing UUID enriches earlier logs.
    names = {}
    for log in sorted(logs, key=lambda log: log["date"]):
        if log["droneName"] != "Drone non identifié":
            names[log["droneID"]] = log["droneName"]
    for log in logs:
        log["sourcePaths"] = sources.get(log["id"], [])
        if not log["sourcePaths"]:
            log["coverage"].append("Source originale indisponible : chemins remplacés par un autre contenu; résumé et messages historiques conservés.")
        log["droneName"] = names.get(log["droneID"], log["droneName"])
    logs.sort(key=lambda log: (log["date"], log["id"]), reverse=True)
    return {"schemaVersion": SCHEMA_VERSION, "generatedAt": utc_now(),
            "sourceFolders": [row[0] for row in db.execute("SELECT path FROM folders ORDER BY path")],
            "importStats": stats, "logs": logs}


def scan(folder, database, output=None, progress=None):
    root = Path(folder).expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f"Dossier introuvable : {root}")
    discovered = []
    walk_errors = []
    walked = []
    for current, dirs, files in os.walk(root, onerror=walk_errors.append, followlinks=False):
        walked.append(str(Path(current).absolute()))
        dirs.sort()
        for filename in sorted(files):
            if Path(filename).suffix.lower() == ".ulg":
                discovered.append(Path(current) / filename)
    stats = dict.fromkeys(("discovered", "imported", "unchanged", "duplicates", "failed"), 0)
    stats["discovered"] = len(discovered)
    db = open_database(database)
    try:
        db.execute("INSERT OR IGNORE INTO folders(path) VALUES(?)", (str(root),))
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
                    stats["unchanged"] += 1
                    # Card name metadata can appear after the first import.
                    _, name = card_context(path, root)
                    if name:
                        row = db.execute("SELECT summary FROM logs WHERE id=?", (cached["log_id"],)).fetchone()
                        saved = json.loads(row[0])
                        if saved["droneName"] == "Drone non identifié":
                            saved["droneName"] = name
                            remember_log(db, saved)
                    db.commit()
                    continue
                digest = digest_file(path)
                existing = db.execute("SELECT parser_version,summary FROM logs WHERE id=?", (digest,)).fetchone()
                if existing and existing["parser_version"] == PARSER_VERSION and json.loads(existing["summary"]).get("status") != "error":
                    saved = json.loads(existing["summary"])
                    _, name = card_context(path, root)
                    if name and saved["droneName"] == "Drone non identifié":
                        saved["droneName"] = name
                        remember_log(db, saved)
                    category = "duplicates"
                else:
                    saved = analyze_file(path, root, digest)
                    remember_log(db, saved)
                    category = "failed" if saved["status"] == "error" else "imported"
                if stat_signature(path.stat()) != signature:
                    raise OSError("Le fichier a changé pendant l'analyse; réimporter une fois la copie terminée.")
                db.execute("INSERT OR REPLACE INTO files(path,size,mtime_ns,ctime_ns,inode,log_id) VALUES(?,?,?,?,?,?)", (absolute, *signature, digest))
                db.execute("DELETE FROM sources WHERE path=? AND log_id<>?", (absolute, digest))
                db.execute("INSERT OR IGNORE INTO sources(log_id,path) VALUES(?,?)", (digest, absolute))
                # Remove a former transient read error after a successful retry.
                unreadable_id = "unreadable:" + hashlib.sha256(absolute.encode()).hexdigest()
                db.execute("DELETE FROM logs WHERE id=?", (unreadable_id,))
                db.execute("DELETE FROM sources WHERE log_id=?", (unreadable_id,))
                db.commit()
                stats[category] += 1
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
            finally:
                if progress:
                    atomic_json(progress, {"completed": index + 1, "total": len(discovered), "current": path.name})
        db.execute("INSERT OR REPLACE INTO settings(key,value) VALUES('lastImportStats',?)", (json.dumps(stats),))
        db.commit()
        result = snapshot(db, stats)
        if output:
            atomic_json(output, result)
        return result
    finally:
        db.close()


def detail(log_id, database, output=None):
    if not re.fullmatch(r"[a-f0-9]{64}", log_id):
        raise ValueError("Identifiant de contenu ULog invalide.")
    db = open_database(database)
    try:
        summary = db.execute("SELECT summary FROM logs WHERE id=?", (log_id,)).fetchone()
        if not summary:
            raise ValueError("Ce log n’est pas dans la bibliothèque.")
        saved = json.loads(summary[0])
        sources = [row[0] for row in db.execute("SELECT path FROM sources WHERE log_id=? ORDER BY path", (log_id,))]
        cached = db.execute("SELECT summary FROM flight_details WHERE log_id=? AND parser_version=?", (log_id, PARSER_VERSION)).fetchone()
        if cached:
            result = json.loads(cached[0])
        else:
            result = None
            for source in sources:
                path = Path(source)
                try:
                    before = stat_signature(path.stat())
                    if digest_file(path) != log_id:
                        continue
                    candidate = analyze_file(path, path.parent, log_id, detailed=True)
                    if stat_signature(path.stat()) != before:
                        continue
                except OSError:
                    continue
                if candidate['status'] == 'error':
                    raise ValueError('Lecture des détails impossible : ' + '; '.join(candidate['issues']))
                result = candidate
                break
            if result is None:
                raise ValueError("Source ULog absente ou modifiée : les résumés restent conservés. Réimportez une copie originale pour ouvrir ses détails.")
            db.execute("INSERT OR REPLACE INTO flight_details(log_id,parser_version,summary) VALUES(?,?,?)",
                       (log_id, PARSER_VERSION, json.dumps(result, ensure_ascii=False, allow_nan=False)))
            db.commit()
        result['sourcePaths'] = sources
        result['droneName'] = saved['droneName']
        if output:
            atomic_json(output, result)
        return result
    finally:
        db.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Import local incrémental de logs PX4")
    commands = parser.add_subparsers(dest="command", required=True)
    scan_command = commands.add_parser("scan")
    scan_command.add_argument("--folder", required=True)
    scan_command.add_argument("--database", required=True)
    scan_command.add_argument("--output", required=True)
    scan_command.add_argument("--progress")
    snapshot_command = commands.add_parser("snapshot")
    snapshot_command.add_argument("--database", required=True)
    snapshot_command.add_argument("--output", required=True)
    detail_command = commands.add_parser("detail")
    detail_command.add_argument("--log-id", required=True)
    detail_command.add_argument("--database", required=True)
    detail_command.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "detail":
            result = detail(args.log_id, args.database, args.output)
            print(json.dumps({"logID": result["id"], "status": result["status"]}))
            return 0
        if args.command == "scan":
            result = scan(args.folder, args.database, args.output, args.progress)
        else:
            db = open_database(args.database)
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
