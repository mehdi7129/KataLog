"""Versioned, incremental SQLite projections and bounded library queries.

Canonical JSON remains in logs. Triggers enqueue changed content/source IDs;
queries never decode the entire library after the initial projection build.
"""
from __future__ import annotations

import base64
from datetime import date, datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import sqlite3
import struct
import unicodedata
import uuid

QUERY_VERSION = 1
PROJECTION_VERSION = 6
MESSAGE_METADATA_FIELDS = ('source', 'tag', 'rawTimestamp', 'rawLogLevel', 'sourceIndex')
MAX_QUERY_BYTES = 4 * 1024 * 1024
MAX_PAGE_SIZE = 200
PRIORITIES = {"EMERGENCY": 8, "ALERT": 7, "CRITICAL": 6, "ERROR": 5, "WARNING": 4, "WARN": 4, "NOTICE": 3, "INFO": 2, "DEBUG": 1}


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def normalized(value):
    text = " ".join(str(value or "").split()).casefold()
    return "".join(char for char in unicodedata.normalize("NFKD", text) if not unicodedata.combining(char))


def classification_key(message):
    level = str(message.get("level", "UNKNOWN"))
    return "text-v1:" + str(len(level.encode("utf-8"))) + ":" + level + " ".join(str(message.get("text", "")).split())


def initialize(db):
    db.execute('PRAGMA cache_size=-131072')
    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    version = db.execute("SELECT value FROM kl_meta WHERE key='projectionVersion'").fetchone() if 'kl_meta' in tables else None
    if version and int(version[0]) not in (1, 2, 3, 4, 5, PROJECTION_VERSION):
        raise ValueError("Version d’index de bibliothèque non prise en charge.")
    if not version or int(version[0]) != PROJECTION_VERSION:
        database = db.execute('PRAGMA database_list').fetchone()[2]
        if database:
            from library_storage import backup
            db.commit()
            root = Path(database).resolve().parent
            recovery = root / ('recovery-index-' + uuid.uuid4().hex)
            recovery.mkdir()
            backup(root, recovery / 'before.zip', include_ulog=False)
            db.execute("INSERT OR REPLACE INTO settings(key,value) VALUES('indexMigrationBackup',?)", (str(recovery / 'before.zip'),))
            db.commit()
    if "kl_meta" in tables:
        if version and int(version[0]) in (1, 2):
            # Only derived index tables are rebuilt. Canonical log/detail JSON,
            # provenance, settings and the library schema remain unchanged.
            for name in ('kl_source_insert', 'kl_source_delete', 'kl_log_insert', 'kl_log_update', 'kl_log_delete', 'kl_detail_insert', 'kl_detail_update', 'kl_detail_delete'):
                db.execute('DROP TRIGGER IF EXISTS ' + name)
            for name in ('kl_messages', 'kl_events', 'kl_event_cache', 'kl_definitions', 'kl_definition_presence', 'kl_group_stats', 'kl_family_stats', 'kl_groups', 'kl_logs', 'kl_dirty', 'kl_meta'):
                db.execute('DROP TABLE IF EXISTS ' + name)
        elif version and int(version[0]) not in (3, 4, 5, PROJECTION_VERSION):
            raise ValueError("Version d’index de bibliothèque non prise en charge.")
    db.executescript("""
        CREATE TABLE IF NOT EXISTS kl_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS kl_dirty(log_id TEXT PRIMARY KEY,flags INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS source_observations(log_id TEXT NOT NULL,path TEXT NOT NULL,state TEXT NOT NULL,checked_at TEXT NOT NULL,PRIMARY KEY(log_id,path));
        CREATE TRIGGER IF NOT EXISTS kl_observation_insert AFTER INSERT ON source_observations BEGIN
            INSERT INTO kl_dirty(log_id,flags) VALUES(new.log_id,2) ON CONFLICT(log_id) DO UPDATE SET flags=flags|2;
        END;
        CREATE TRIGGER IF NOT EXISTS kl_observation_update AFTER UPDATE ON source_observations BEGIN
            INSERT INTO kl_dirty(log_id,flags) VALUES(new.log_id,2) ON CONFLICT(log_id) DO UPDATE SET flags=flags|2;
        END;
        CREATE TABLE IF NOT EXISTS kl_logs(
            id TEXT PRIMARY KEY,summary_hash TEXT NOT NULL,drone_id TEXT NOT NULL,
            drone_name TEXT NOT NULL,gcs_uuid TEXT,gcs_status TEXT NOT NULL,
            date TEXT NOT NULL,date_day TEXT NOT NULL,status TEXT NOT NULL,
            duration REAL NOT NULL,failsafe INTEGER NOT NULL,search_text TEXT NOT NULL,
            summary_projection TEXT NOT NULL,cached_messages INTEGER NOT NULL,cached_alerts INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS kl_groups(
            id TEXT PRIMARY KEY,source_key TEXT NOT NULL,title TEXT NOT NULL,
            level TEXT NOT NULL,priority INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS kl_definitions(
            id INTEGER PRIMARY KEY,checksum TEXT UNIQUE NOT NULL,
            group_id TEXT NOT NULL,class_key TEXT NOT NULL,family TEXT NOT NULL,
            level TEXT NOT NULL,priority INTEGER NOT NULL,is_alert INTEGER NOT NULL,
            raw_text TEXT NOT NULL,search_text TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS kl_messages(
            log_id TEXT NOT NULL,sequence INTEGER NOT NULL,message_id TEXT NOT NULL,
            definition_id INTEGER NOT NULL,timestamp REAL NOT NULL,position_json TEXT,metadata_json TEXT,
            PRIMARY KEY(log_id,sequence)
        );
        CREATE INDEX IF NOT EXISTS kl_logs_date ON kl_logs(date DESC,id DESC);
        CREATE INDEX IF NOT EXISTS kl_logs_drone_date ON kl_logs(drone_id,date DESC,id DESC);
        CREATE INDEX IF NOT EXISTS kl_logs_status ON kl_logs(status,date DESC,id DESC);
        CREATE INDEX IF NOT EXISTS kl_logs_names ON kl_logs(drone_id,date DESC,id DESC,drone_name);
        CREATE INDEX IF NOT EXISTS kl_logs_links ON kl_logs(drone_id,gcs_status,gcs_uuid);
        CREATE INDEX IF NOT EXISTS kl_logs_totals ON kl_logs(status,drone_id,duration,failsafe,cached_messages,cached_alerts);
        CREATE INDEX IF NOT EXISTS kl_logs_scope_meta ON kl_logs(id,drone_id,drone_name,gcs_uuid,gcs_status,date,date_day,status,duration,failsafe,cached_messages,cached_alerts);
        CREATE INDEX IF NOT EXISTS kl_canonical_parser ON logs(parser_version,id);
        CREATE INDEX IF NOT EXISTS kl_definitions_family ON kl_definitions(family,id);
        CREATE INDEX IF NOT EXISTS kl_definitions_level ON kl_definitions(level,id);
        CREATE INDEX IF NOT EXISTS kl_definitions_alert ON kl_definitions(is_alert,id);
        CREATE INDEX IF NOT EXISTS kl_definitions_group ON kl_definitions(group_id,id);
        CREATE INDEX IF NOT EXISTS kl_messages_definition ON kl_messages(definition_id,log_id);
        CREATE INDEX IF NOT EXISTS kl_messages_time ON kl_messages(log_id,timestamp,sequence);
        CREATE TABLE IF NOT EXISTS kl_group_stats(
            group_id TEXT PRIMARY KEY,family TEXT NOT NULL,message_count INTEGER NOT NULL,
            log_count INTEGER NOT NULL,drone_count INTEGER NOT NULL,first_date TEXT,last_date TEXT
        );
        CREATE TABLE IF NOT EXISTS kl_family_stats(family TEXT PRIMARY KEY,log_count INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS kl_definition_presence(
            definition_id INTEGER PRIMARY KEY,encoding TEXT NOT NULL,log_presence BLOB NOT NULL,
            message_count INTEGER NOT NULL,log_count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS kl_event_cache(
            log_id TEXT PRIMARY KEY,summary_hash TEXT NOT NULL,parser_version TEXT NOT NULL,
            state TEXT NOT NULL,event_count INTEGER NOT NULL,translated_count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS kl_events(
            log_id TEXT NOT NULL,sequence INTEGER NOT NULL,time_seconds REAL,
            internal_level TEXT NOT NULL,external_level TEXT NOT NULL,search_text TEXT NOT NULL,
            event_json TEXT NOT NULL,PRIMARY KEY(log_id,sequence)
        );
        CREATE INDEX IF NOT EXISTS kl_events_internal ON kl_events(internal_level,log_id,sequence);
        CREATE INDEX IF NOT EXISTS kl_events_external ON kl_events(external_level,log_id,sequence);
        CREATE INDEX IF NOT EXISTS kl_events_time ON kl_events(log_id,time_seconds,sequence);
        CREATE TRIGGER IF NOT EXISTS kl_detail_insert AFTER INSERT ON flight_details BEGIN
            INSERT INTO kl_dirty(log_id,flags) VALUES(new.log_id,4)
            ON CONFLICT(log_id) DO UPDATE SET flags=flags|4;
        END;
        CREATE TRIGGER IF NOT EXISTS kl_detail_update AFTER UPDATE ON flight_details BEGIN
            INSERT INTO kl_dirty(log_id,flags) VALUES(new.log_id,4)
            ON CONFLICT(log_id) DO UPDATE SET flags=flags|4;
        END;
        CREATE TRIGGER IF NOT EXISTS kl_detail_delete AFTER DELETE ON flight_details BEGIN
            INSERT INTO kl_dirty(log_id,flags) VALUES(old.log_id,4)
            ON CONFLICT(log_id) DO UPDATE SET flags=flags|4;
        END;
        CREATE TRIGGER IF NOT EXISTS kl_source_insert AFTER INSERT ON sources BEGIN
            INSERT INTO kl_dirty(log_id,flags) VALUES(new.log_id,2)
            ON CONFLICT(log_id) DO UPDATE SET flags=flags|2;
        END;
        CREATE TRIGGER IF NOT EXISTS kl_source_delete AFTER DELETE ON sources BEGIN
            INSERT INTO kl_dirty(log_id,flags) VALUES(old.log_id,2)
            ON CONFLICT(log_id) DO UPDATE SET flags=flags|2;
        END;
        CREATE TRIGGER IF NOT EXISTS kl_log_insert AFTER INSERT ON logs BEGIN
            INSERT INTO kl_dirty(log_id,flags) VALUES(new.id,1)
            ON CONFLICT(log_id) DO UPDATE SET flags=flags|1;
        END;
        CREATE TRIGGER IF NOT EXISTS kl_log_update AFTER UPDATE ON logs BEGIN
            INSERT INTO kl_dirty(log_id,flags) VALUES(new.id,1)
            ON CONFLICT(log_id) DO UPDATE SET flags=flags|1;
        END;
        CREATE TRIGGER IF NOT EXISTS kl_log_delete AFTER DELETE ON logs BEGIN
            INSERT INTO kl_dirty(log_id,flags) VALUES(old.id,1)
            ON CONFLICT(log_id) DO UPDATE SET flags=flags|1;
        END;
    """)
    if 'metadata_json' not in {row[1] for row in db.execute('PRAGMA table_info(kl_messages)')}:
        db.execute('ALTER TABLE kl_messages ADD COLUMN metadata_json TEXT')
    db.execute("INSERT OR IGNORE INTO kl_meta(key,value) VALUES('projectionVersion',?)", (str(PROJECTION_VERSION),))
    presence_migration = bool(version and int(version[0]) == 3)
    event_migration = bool(version and int(version[0]) in (3, 4))
    metadata_migration = bool(version and int(version[0]) in (3, 4, 5))
    db.execute("INSERT OR IGNORE INTO kl_meta(key,value) VALUES('revision','0')")
    built = db.execute("SELECT value FROM kl_meta WHERE key='initialized'").fetchone()
    definition_cache = {}
    changed_definitions = set()
    if not built:
        for identity, summary in db.execute("SELECT id,summary FROM logs"):
            project_log(db, identity, summary, definition_cache)
        refresh_rollups(db)
        refresh_presence(db)
        for identity, parser, summary in db.execute('SELECT log_id,parser_version,summary FROM flight_details'):
            project_events(db, identity, parser, summary)
        db.execute("DELETE FROM kl_dirty")
        db.execute("INSERT INTO kl_meta(key,value) VALUES('initialized','1')")
        db.execute("UPDATE kl_meta SET value=CAST(value AS INTEGER)+1 WHERE key='revision'")
        db.commit()
    else:
        dirty = list(db.execute("SELECT log_id,flags FROM kl_dirty"))
        summaries_changed = False
        for identity, flags in dirty:
            if flags & 1:
                changed_definitions.update(row[0] for row in db.execute('SELECT DISTINCT definition_id FROM kl_messages WHERE log_id=?', (identity,)))
            row = db.execute("SELECT summary FROM logs WHERE id=?", (identity,)).fetchone()
            if row:
                changed = bool(project_log(db, identity, row[0], definition_cache))
                summaries_changed |= changed
                if changed:
                    changed_definitions.update(item[0] for item in db.execute('SELECT DISTINCT definition_id FROM kl_messages WHERE log_id=?', (identity,)))
            else:
                db.execute("DELETE FROM kl_messages WHERE log_id=?", (identity,))
                db.execute("DELETE FROM kl_logs WHERE id=?", (identity,))
                db.execute('DELETE FROM kl_events WHERE log_id=?', (identity,))
                db.execute('DELETE FROM kl_event_cache WHERE log_id=?', (identity,))
                summaries_changed = True
            if row and flags & 4:
                cached = db.execute('SELECT parser_version,summary FROM flight_details WHERE log_id=?', (identity,)).fetchone()
                if cached:
                    project_events(db, identity, cached[0], cached[1])
                else:
                    db.execute('DELETE FROM kl_events WHERE log_id=?', (identity,))
                    db.execute('DELETE FROM kl_event_cache WHERE log_id=?', (identity,))
            db.execute("DELETE FROM kl_dirty WHERE log_id=?", (identity,))
        if dirty:
            if summaries_changed:
                refresh_rollups(db)
                refresh_presence(db, changed_definitions)
            db.execute("UPDATE kl_meta SET value=CAST(value AS INTEGER)+1 WHERE key='revision'")
        if presence_migration:
            refresh_presence(db)
        if event_migration:
            for identity, parser, summary in db.execute('SELECT log_id,parser_version,summary FROM flight_details'):
                project_events(db, identity, parser, summary)
        if metadata_migration:
            for identity, summary in db.execute('SELECT id,summary FROM logs'):
                # Most old summaries have no per-message provenance. Avoid
                # decoding all canonical JSON when none of these keys exist.
                if not any('"' + key + '"' in summary for key in MESSAGE_METADATA_FIELDS):
                    continue
                for sequence, message in enumerate(json.loads(summary).get('messages', [])):
                    metadata = {key: message[key] for key in MESSAGE_METADATA_FIELDS if key in message}
                    if metadata:
                        db.execute('UPDATE kl_messages SET metadata_json=? WHERE log_id=? AND sequence=?',
                                   (json.dumps(metadata, ensure_ascii=False, allow_nan=False), identity, sequence))
        if event_migration or metadata_migration:
            db.execute("UPDATE kl_meta SET value=? WHERE key='projectionVersion'", (str(PROJECTION_VERSION),))
            db.execute("UPDATE kl_meta SET value=CAST(value AS INTEGER)+1 WHERE key='revision'")
        db.commit()


def project_log(db, identity, summary, definition_cache=None):
    checksum = hashlib.sha256(summary.encode("utf-8")).hexdigest()
    previous = db.execute("SELECT summary_hash FROM kl_logs WHERE id=?", (identity,)).fetchone()
    if previous and previous[0] == checksum:
        return False
    log = json.loads(summary)
    if not isinstance(log, dict) or log.get("id") != identity:
        raise ValueError("Résumé de bibliothèque invalide ; l’index n’a pas été publié.")
    message_list = log.get("messages", [])
    projection = {key: value for key, value in log.items() if key not in ("messages", "sourceAvailability")}
    projection["messages"] = []
    stamp = str(log.get("date", ""))
    try:
        day = date.fromisoformat(stamp[:10]).isoformat()
    except ValueError:
        day = ""
    metadata = log.get("metadata", {})
    gcs_uuid = str(metadata.get("gcsUUID", "")).upper()
    if not re.fullmatch(r"[0-9A-F]{24}", gcs_uuid) or gcs_uuid in ("0" * 24, "F" * 24):
        gcs_uuid = None
    fields = [log.get("fileName", ""), log.get("droneName", ""), log.get("droneID", ""), stamp, identity, *log.get('sourcePaths', [])]
    alerts = sum(bool(message.get('isAlert', PRIORITIES.get(message.get('level'), 0) >= 4 or '[ALARM]' in message.get('text', '').upper() or 'failsafe activated' in message.get('text', '').lower())) for message in message_list)
    db.execute("""INSERT INTO kl_logs(id,summary_hash,drone_id,drone_name,gcs_uuid,gcs_status,date,date_day,status,duration,failsafe,search_text,summary_projection,cached_messages,cached_alerts)
                  VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                  summary_hash=excluded.summary_hash,drone_id=excluded.drone_id,drone_name=excluded.drone_name,
                  gcs_uuid=excluded.gcs_uuid,gcs_status=excluded.gcs_status,date=excluded.date,date_day=excluded.date_day,
                  status=excluded.status,duration=excluded.duration,failsafe=excluded.failsafe,
                  search_text=excluded.search_text,summary_projection=excluded.summary_projection,
                  cached_messages=excluded.cached_messages,cached_alerts=excluded.cached_alerts""",
               (identity, checksum, log["droneID"], log["droneName"], gcs_uuid, metadata.get("gcsIdentityStatus", "unavailable"),
                stamp, day, log.get("status", "error"), float(log.get("durationSeconds", 0)), int(bool(log.get("failsafeObserved"))),
                normalized(" ".join(str(value) for value in fields)), json.dumps(projection, ensure_ascii=False, allow_nan=False), len(message_list), alerts))
    db.execute("DELETE FROM kl_messages WHERE log_id=?", (identity,))
    for index, message in enumerate(message_list):
        text, level = str(message.get("text", "")), str(message.get("level", "UNKNOWN"))
        priority = PRIORITIES.get(level, 0)
        family = str(message.get("sourceFamily") or message.get("family", "Autres"))
        source_key = str(message.get("groupKey") or family + "|" + level + "|" + " ".join(text.split()))
        group_cache_key = ('group', source_key)
        group_id = definition_cache.get(group_cache_key) if definition_cache is not None else None
        if group_id is None:
            group_id = hashlib.sha256(source_key.encode("utf-8")).hexdigest()
            if definition_cache is not None and len(definition_cache) < 10_000:
                definition_cache[group_cache_key] = group_id
        title = str(message.get("title") or re.sub(r"^\[[^\]]+\]\s*", "", " ".join(text.split())))
        alert = message.get("isAlert")
        if alert is None:
            alert = priority >= 4 or "[ALARM]" in text.upper() or "failsafe activated" in text.lower()
        cache_key = ('definition', group_id, family, level, priority, int(bool(alert)), text)
        definition_id = definition_cache.get(cache_key) if definition_cache is not None else None
        if definition_id is None:
            db.execute("INSERT OR IGNORE INTO kl_groups(id,source_key,title,level,priority) VALUES(?,?,?,?,?)", (group_id, source_key, title, level, priority))
            definition = (group_id, classification_key(message), family, level, priority, int(bool(alert)), text, normalized(text))
            definition_hash = hashlib.sha256(json.dumps(definition, ensure_ascii=False).encode('utf-8')).hexdigest()
            db.execute("INSERT OR IGNORE INTO kl_definitions(checksum,group_id,class_key,family,level,priority,is_alert,raw_text,search_text) VALUES(?,?,?,?,?,?,?,?,?)", (definition_hash, *definition))
            definition_id = db.execute("SELECT id FROM kl_definitions WHERE checksum=?", (definition_hash,)).fetchone()[0]
            if definition_cache is not None and len(definition_cache) < 10_000:
                definition_cache[cache_key] = definition_id
        metadata = {key: message[key] for key in MESSAGE_METADATA_FIELDS if key in message}
        db.execute("INSERT INTO kl_messages(log_id,sequence,message_id,definition_id,timestamp,position_json,metadata_json) VALUES(?,?,?,?,?,?,?)",
                   (identity, index, str(message.get("id", identity + "-" + str(index))), definition_id,
                    float(message.get("timestampSeconds", 0)), json.dumps(message["position"], allow_nan=False) if message.get("position") else None,
                    json.dumps(metadata, ensure_ascii=False, allow_nan=False) if metadata else None))
    return True


def refresh_rollups(db):
    """SQL-only aggregates; source summaries are never decoded a second time."""
    db.execute('DELETE FROM kl_group_stats')
    db.execute('''INSERT INTO kl_group_stats
        SELECT d.group_id,MIN(d.family),COUNT(*),COUNT(DISTINCT m.log_id),COUNT(DISTINCT l.drone_id),MIN(l.date),MAX(l.date)
        FROM kl_messages m JOIN kl_definitions d ON d.id=m.definition_id JOIN kl_logs l ON l.id=m.log_id GROUP BY d.group_id''')
    db.execute('DELETE FROM kl_family_stats')
    db.execute('''INSERT INTO kl_family_stats
        SELECT d.family,COUNT(DISTINCT m.log_id) FROM kl_messages m JOIN kl_definitions d ON d.id=m.definition_id
        JOIN kl_logs l ON l.id=m.log_id WHERE d.is_alert=1 AND l.status<>'error' GROUP BY d.family''')


def refresh_presence(db, definition_ids=None):
    """Compact log membership avoids rereading millions of occurrences per filter.

    Stable SQLite rowids are local ordinals only, never public identities. Sparse
    definitions use uint64 ordinals; dense ones use bits. Both preserve exact
    distinct-log counts and are refreshed only for changed definitions.
    """
    ordinals = dict(db.execute('SELECT id,rowid FROM kl_logs'))
    identities = (row[0] for row in db.execute('SELECT id FROM kl_definitions')) if definition_ids is None else sorted(definition_ids)
    for identity in identities:
        values, message_count = [], 0
        for log_id, count in db.execute('SELECT log_id,COUNT(*) FROM kl_messages WHERE definition_id=? GROUP BY log_id', (identity,)):
            values.append(ordinals[log_id])
            message_count += count
        if not values:
            db.execute('DELETE FROM kl_definition_presence WHERE definition_id=?', (identity,))
            continue
        largest = max(values)
        dense_size = largest // 8 + 1
        if dense_size <= len(values) * 8 and largest <= 1_000_000:
            bits = bytearray(dense_size)
            for value in values:
                bits[value // 8] |= 1 << (value % 8)
            encoding, payload = 'bits-v1', bytes(bits)
        else:
            encoding, payload = 'ordinals-v1', b''.join(struct.pack('>Q', value) for value in sorted(values))
        db.execute('INSERT OR REPLACE INTO kl_definition_presence VALUES(?,?,?,?,?)', (identity, encoding, payload, message_count, len(values)))


def presence_bits(encoding, payload):
    if encoding == 'bits-v1':
        if len(payload) > 125_001:
            raise ValueError('Projection de présence hors budget.')
        return int.from_bytes(payload, 'little')
    if encoding == 'ordinals-v1' and len(payload) % 8 == 0:
        result = 0
        for value, in struct.iter_unpack('>Q', payload):
            if value > 1_000_000:
                raise ValueError('Ordre interne hors budget de la projection compacte.')
            result |= 1 << value
        return result
    raise ValueError('Projection de présence invalide.')


def project_events(db, identity, parser_version, summary):
    checksum = hashlib.sha256(summary.encode('utf-8')).hexdigest()
    previous = db.execute('SELECT summary_hash,parser_version FROM kl_event_cache WHERE log_id=?', (identity,)).fetchone()
    if previous and tuple(previous) == (checksum, parser_version):
        return
    try:
        value = json.loads(summary)
    except (ValueError, TypeError):
        value = None
    events = value.get('events') if isinstance(value, dict) else None
    state = 'available' if isinstance(events, list) else 'legacy'
    if not isinstance(events, list):
        events = None
    if not isinstance(value, dict) or value.get('id') != identity or value.get('status') == 'error':
        state, events = 'invalid', None
    if events and any(not isinstance(event, dict) for event in events):
        state, events = 'invalid', None
    try:
        encoded_events = [json.dumps(event, ensure_ascii=False, allow_nan=False) for event in events or []]
    except (ValueError, TypeError, RecursionError):
        # An old or damaged optional cache must not block all canonical
        # library queries or leave a partly published event projection.
        state, events, encoded_events = 'invalid', None, []
    db.execute('DELETE FROM kl_events WHERE log_id=?', (identity,))
    translated = 0
    for sequence, (event, encoded_event) in enumerate(zip(events or [], encoded_events)):
        stamp = event.get('timeSeconds')
        if type(stamp) not in (int, float) or not math.isfinite(stamp):
            stamp = None
        internal = str(event.get('internalLevelName') or 'UNKNOWN')
        external = str(event.get('externalLevelName') or 'UNKNOWN')
        search = normalized(' '.join(str(event.get(key) or '') for key in ('eventID', 'message', 'eventName', 'namespace', 'group', 'translationStatus')))
        db.execute('INSERT INTO kl_events VALUES(?,?,?,?,?,?,?)', (identity, sequence, stamp, internal, external, search, encoded_event))
        translated += event.get('translationStatus') == 'translated'
    db.execute('INSERT OR REPLACE INTO kl_event_cache VALUES(?,?,?,?,?,?)', (identity, checksum, parser_version, state, len(events or []), translated))


def string_list(value, field):
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > 100_000 or not all(isinstance(item, str) for item in value):
        raise ValueError("Filtre invalide : " + field)
    return sorted(set(value))


def parse_request(request):
    if not isinstance(request, dict) or type(request.get("queryVersion", QUERY_VERSION)) is not int or request.get("queryVersion", QUERY_VERSION) != QUERY_VERSION:
        raise ValueError("Version de requête non prise en charge.")
    raw = {} if request.get('kind') in ('drones', 'group-keys', 'catalogue') else request.get("scope", {})
    if not isinstance(raw, dict):
        raise ValueError("Périmètre invalide.")
    scope = {field: string_list(raw.get(field, []), field) for field in ("droneKeys", "families", "levels", "statuses", 'logIDs')}
    for field, default in (("includeUnknownDates", True), ("alertOnly", False), ("includeMasked", False)):
        if not isinstance(raw.get(field, default), bool):
            raise ValueError("Filtre booléen invalide : " + field)
        scope[field] = raw.get(field, default)
    for field in ("dateFrom", "dateTo"):
        value = raw.get(field)
        if value not in (None, ""):
            if not isinstance(value, str):
                raise ValueError("Date de filtre invalide.")
            try:
                value = date.fromisoformat(value).isoformat()
            except ValueError as error:
                raise ValueError("Date de filtre invalide.") from error
        scope[field] = value or None
    if scope["dateFrom"] and scope["dateTo"] and scope["dateFrom"] > scope["dateTo"]:
        raise ValueError("La date de début dépasse la date de fin.")
    for field in ("search", "logSearch"):
        if not isinstance(raw.get(field, ""), str):
            raise ValueError("Recherche invalide.")
        scope[field] = normalized(raw.get(field, ""))
    limit = request.get("limit", MAX_PAGE_SIZE)
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= MAX_PAGE_SIZE:
        raise ValueError("Taille de page invalide (1 à 200).")
    kind = request.get("kind", "logs")
    if kind not in ("logs", "groups", "messages", 'drones', 'map', 'group-keys', 'events', 'catalogue'):
        raise ValueError("Type de requête non pris en charge.")
    if kind == 'map':
        limit = min(limit, 80)
    annotations = request.get("annotations", {})
    if not isinstance(annotations, dict) or annotations.get("schemaVersion", 1) != 1:
        raise ValueError("Version d’annotations non prise en charge.")
    if any(not isinstance(annotations.get(field, {}), dict) for field in ("familyOverrides", "stockNumbers")):
        raise ValueError("Annotations invalides.")
    masks = string_list(request.get("maskedMessageKeys", []), "maskedMessageKeys")
    group = request.get("groupID")
    if group is not None and (not isinstance(group, str) or not re.fullmatch(r"[a-f0-9]{64}", group)):
        raise ValueError("Identifiant de groupe invalide.")
    if kind == 'group-keys' and group is None:
        raise ValueError('Un groupe est requis pour sa prévisualisation de masquage.')
    if not isinstance(request.get("includeMessages", False), bool):
        raise ValueError("includeMessages doit être booléen.")
    if request.get('registrySearch') is not None and not isinstance(request['registrySearch'], str):
        raise ValueError('Recherche du registre invalide.')
    if request.get('sortOrder', 'recent') not in ('recent', 'oldest'):
        raise ValueError('Ordre de tri invalide.')
    fingerprint = {"scope": scope, "annotations": annotations, "maskedMessageKeys": masks}
    fingerprint['registrySearch'] = normalized(request.get('registrySearch'))
    fingerprint['sortOrder'] = request.get('sortOrder', 'recent')
    if request.get('eventLevelSource', 'internal') not in ('internal', 'external'):
        raise ValueError('Source du niveau d’événement invalide.')
    if not isinstance(request.get('eventSearch', ''), str):
        raise ValueError('Recherche d’événement invalide.')
    fingerprint['eventLevelSource'] = request.get('eventLevelSource', 'internal')
    fingerprint['eventLevels'] = string_list(request.get('eventLevels', []), 'eventLevels')
    fingerprint['eventSearch'] = normalized(request.get('eventSearch', ''))
    scope_hash = hashlib.sha256(json.dumps(fingerprint, sort_keys=True, ensure_ascii=False, allow_nan=False).encode("utf-8")).hexdigest()
    return scope, limit, kind, annotations, masks, group, scope_hash


def setup_annotations(db, annotations, masks):
    db.create_function("kl_normalize", 1, normalized, deterministic=True)
    db.executescript("""
        DROP TABLE IF EXISTS temp.kl_family_overrides;
        DROP TABLE IF EXISTS temp.kl_stock_numbers;
        DROP TABLE IF EXISTS temp.kl_masks;
        CREATE TEMP TABLE kl_family_overrides(key TEXT PRIMARY KEY,family TEXT NOT NULL);
        CREATE TEMP TABLE kl_stock_numbers(key TEXT PRIMARY KEY,number TEXT NOT NULL);
        CREATE TEMP TABLE kl_masks(key TEXT PRIMARY KEY);
    """)
    for key, value in annotations.get("familyOverrides", {}).items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise ValueError("Règle de famille invalide.")
        db.execute("INSERT INTO kl_family_overrides VALUES(?,?)", (key, value))
    for key, value in annotations.get("stockNumbers", {}).items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise ValueError("Numéro de drone invalide.")
        db.execute("INSERT INTO kl_stock_numbers VALUES(?,?)", (key, value))
    db.executemany("INSERT INTO kl_masks VALUES(?)", ((key,) for key in masks))
    db.commit()


IDENTITY = """CASE WHEN l.gcs_status<>'rejected' AND l.gcs_uuid IS NOT NULL THEN 'gcs:'||l.gcs_uuid
                   WHEN l.gcs_status<>'rejected' AND links.uuid_count=1 THEN 'gcs:'||links.uuid
                   ELSE 'ulog:'||l.drone_id END"""
LOG_JOINS = """ LEFT JOIN links ON links.drone_id=l.drone_id
                LEFT JOIN names ON names.drone_id=l.drone_id
                LEFT JOIN kl_stock_numbers sn ON sn.key=""" + IDENTITY + """
                LEFT JOIN kl_stock_numbers legacy ON legacy.key='ulog:'||l.drone_id"""
FAMILY = "COALESCE(over_class.family,over_group.family,d.family)"
MESSAGE_JOINS = """ JOIN kl_definitions d ON d.id=m.definition_id
                    JOIN kl_groups g ON g.id=d.group_id
                    LEFT JOIN kl_family_overrides over_class ON over_class.key=d.class_key
                    LEFT JOIN kl_family_overrides over_group ON over_group.key=g.source_key
                    LEFT JOIN kl_masks mask ON mask.key=d.class_key"""
CTE = """WITH links AS (
            SELECT drone_id,COUNT(DISTINCT gcs_uuid) AS uuid_count,MIN(gcs_uuid) AS uuid
            FROM kl_logs INDEXED BY kl_logs_links WHERE gcs_status<>'rejected' AND gcs_uuid IS NOT NULL GROUP BY drone_id
         ), controllers AS (
            SELECT DISTINCT drone_id FROM kl_logs INDEXED BY kl_logs_links
         ), names AS MATERIALIZED (
            SELECT c.drone_id,(SELECT n.drone_name FROM kl_logs n INDEXED BY kl_logs_names
                WHERE n.drone_id=c.drone_id AND n.drone_name<>'Drone non identifié'
                ORDER BY n.date DESC,n.id DESC LIMIT 1) AS drone_name
            FROM controllers c
         ) """


def predicates(scope):
    logs, log_values, messages, message_values = [], [], [], []
    for field, expression in (("droneKeys", IDENTITY), ("statuses", "l.status"), ('logIDs', 'l.id')):
        if scope[field]:
            logs.append(expression + " IN (" + ",".join("?" for _ in scope[field]) + ")")
            log_values.extend(scope[field])
    if scope['droneKeys'] and all(key.startswith('ulog:') for key in scope['droneKeys']):
        logs.append('l.drone_id IN (' + ','.join('?' for _ in scope['droneKeys']) + ')')
        log_values.extend(key[5:] for key in scope['droneKeys'])
    date_clauses, date_values = [], []
    if scope["dateFrom"]:
        date_clauses.append("l.date_day>=?")
        date_values.append(scope["dateFrom"])
    if scope["dateTo"]:
        date_clauses.append("l.date_day<=?")
        date_values.append(scope["dateTo"])
    if date_clauses:
        condition = "l.date_day<>'' AND " + " AND ".join(date_clauses)
        logs.append("(" + condition + (" OR l.date_day=''" if scope["includeUnknownDates"] else "") + ")")
        log_values.extend(date_values)
    elif not scope["includeUnknownDates"]:
        logs.append("l.date_day<>''")
    if scope["logSearch"]:
        logs.append("(kl_normalize(l.search_text||' '||COALESCE(sn.number,'')||' '||COALESCE(legacy.number,'')||' '||COALESCE(names.drone_name,'')) LIKE ? ESCAPE '\\' OR EXISTS(SELECT 1 FROM sources WHERE sources.log_id=l.id AND kl_normalize(sources.path) LIKE ? ESCAPE '\\'))")
        log_values.append(like_pattern(scope["logSearch"]))
        log_values.append(like_pattern(scope["logSearch"]))
    for field, expression in (("families", FAMILY), ("levels", "d.level")):
        if scope[field]:
            messages.append(expression + " IN (" + ",".join("?" for _ in scope[field]) + ")")
            message_values.extend(scope[field])
    if scope["alertOnly"]:
        messages.append("d.is_alert=1")
    if not scope["includeMasked"]:
        messages.append("mask.key IS NULL")
    if scope["search"]:
        messages.append("d.search_text LIKE ? ESCAPE '\\'")
        message_values.append(like_pattern(scope["search"]))
    message_active = bool(scope["families"] or scope["levels"] or scope["alertOnly"] or scope["search"])
    return " AND ".join(logs) or "1", log_values, " AND ".join(messages) or "1", message_values, message_active


def like_pattern(value):
    return "%" + value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"


def cursor_value(encoded, revision, scope_hash, kind, group):
    if encoded is None:
        return 0
    try:
        if not isinstance(encoded, str) or len(encoded) > 2048:
            raise ValueError()
        value = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
    except (ValueError, TypeError, UnicodeError) as error:
        raise ValueError("Curseur de page invalide.") from error
    if not isinstance(value, dict) or value.get("revision") != revision or value.get("scopeHash") != scope_hash or value.get("kind") != kind or value.get("groupID") != group:
        raise ValueError("Les données ou filtres ont changé ; rechargez la première page.")
    offset = value.get("offset")
    if not isinstance(offset, int) or isinstance(offset, bool) or not 0 <= offset < 2 ** 63:
        raise ValueError("Position de curseur invalide.")
    return offset


def encode_cursor(revision, scope_hash, kind, group, offset, position=None):
    value = {"revision": revision, "scopeHash": scope_hash, "kind": kind, "groupID": group, "offset": offset}
    if position is not None:
        value['position'] = position
    return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).decode().rstrip("=")


def bounded_rows(values, mapper, base):
    result, size = [], len(json.dumps(base, ensure_ascii=False, allow_nan=False).encode("utf-8"))
    for value in values:
        mapped = mapper(value)
        increment = len(json.dumps(mapped, ensure_ascii=False, allow_nan=False).encode("utf-8")) + 1
        if size + increment > MAX_QUERY_BYTES - 4096:
            if not result:
                raise ValueError("Un résultat dépasse le budget de page ; utilisez une fiche ou un export détaillé pour ce contenu.")
            break
        result.append(mapped)
        size += increment
    return result


def selection_statement(scope, metadata_only=False):
    log_where, log_values, message_where, message_values, message_active = predicates(scope)
    # A controller-key-only scope cannot match another controller. Preserve
    # the canonical identity predicate (including UUID propagation/rejection),
    # while letting SQLite visit this controller's rows instead of all 50k.
    controller_scope = bool(scope['droneKeys']) and all(key.startswith('ulog:') for key in scope['droneKeys'])
    restricted_logs = bool(scope['droneKeys'] or scope['logIDs'] or scope['statuses'] or scope['dateFrom'] or scope['dateTo'] or not scope['includeUnknownDates'] or scope['logSearch'])
    source = 'eligible CROSS JOIN kl_messages m ON m.log_id=eligible.id' if restricted_logs else 'kl_messages m'
    matched = "SELECT m.log_id,m.sequence,m.message_id,d.group_id,d.class_key,d.family AS source_family," + FAMILY + " AS family,d.level,d.priority,d.is_alert,m.timestamp,d.raw_text,m.position_json,m.metadata_json,g.source_key,g.title,(mask.key IS NOT NULL) AS masked FROM " + source + MESSAGE_JOINS + " WHERE " + message_where
    columns = 'l.*' if not metadata_only else ','.join('l.' + field for field in ('id','drone_id','drone_name','gcs_uuid','gcs_status','date','date_day','status','duration','failsafe','cached_messages','cached_alerts'))
    index = ' INDEXED BY kl_logs_drone_date' if controller_scope else ' INDEXED BY kl_logs_scope_meta' if metadata_only and not scope['logSearch'] else ''
    selected = "SELECT l.rowid AS log_ordinal," + columns + ",COALESCE(names.drone_name,l.drone_name) AS canonical_name," + IDENTITY + " AS annotation_key,links.uuid_count,links.uuid AS propagated_uuid,sn.number AS canonical_stock,legacy.number AS legacy_stock,COALESCE(sn.number,CASE WHEN l.gcs_status<>'rejected' AND links.uuid_count=1 THEN legacy.number END) AS stock_number FROM kl_logs l" + index + LOG_JOINS + " WHERE " + log_where
    eligible = selected
    selected = "SELECT eligible.* FROM eligible"
    if message_active:
        selected += " WHERE EXISTS(SELECT 1 FROM matching WHERE matching.log_id=eligible.id)"
    statement = CTE + ", eligible AS NOT MATERIALIZED (" + eligible + "), matching AS NOT MATERIALIZED (" + matched + "), selected AS (" + selected + ") "
    params = log_values + message_values
    return statement, params, message_active


def materialize_scope(db, scope):
    """Evaluate filtered IDs once; every subsequent page aggregate is bounded.

    Only compact metadata and matching definition IDs are materialized. Raw
    source JSON and message text remain in their canonical tables.
    """
    for table in ('kl_query_eligible', 'kl_query_definitions', 'kl_query_counts', 'kl_query_selected'):
        db.execute('DROP TABLE IF EXISTS temp.' + table)
    log_scope = dict(scope, families=[], levels=[], alertOnly=False, search='', includeMasked=True)
    statement, params, _ = selection_statement(log_scope, metadata_only=True)
    fields = 'log_ordinal,id,drone_id,drone_name,gcs_uuid,gcs_status,date,date_day,status,duration,failsafe,cached_messages,cached_alerts,canonical_name,annotation_key,uuid_count,propagated_uuid,canonical_stock,legacy_stock,stock_number'
    _, _, message_where, message_values, active = predicates(scope)
    joins = MESSAGE_JOINS[MESSAGE_JOINS.index('JOIN kl_groups'):]
    db.execute('CREATE TEMP TABLE kl_query_definitions AS SELECT d.id,d.group_id,d.family AS source_family,' + FAMILY + ' AS family,d.level,d.priority,d.is_alert,(mask.key IS NOT NULL) AS masked FROM kl_definitions d ' + joins + ' WHERE ' + message_where, message_values)
    db.execute('CREATE UNIQUE INDEX kl_query_definitions_id ON kl_query_definitions(id)')
    restricted = bool(scope['droneKeys'] or scope['logIDs'] or scope['statuses'] or scope['dateFrom'] or scope['dateTo'] or not scope['includeUnknownDates'] or scope['logSearch'])
    largest_ordinal = db.execute('SELECT COALESCE(MAX(rowid),0) FROM kl_logs').fetchone()[0]
    compact = (not restricted and db.execute('SELECT COUNT(*) FROM kl_query_definitions').fetchone()[0] <= 10_000
               and largest_ordinal <= 1_000_000
               and db.execute('SELECT COALESCE(SUM(LENGTH(p.log_presence)),0) FROM kl_query_definitions d JOIN kl_definition_presence p ON p.definition_id=d.id').fetchone()[0] <= 32 * 1024 * 1024)
    fast = None
    if compact:
        selected_bits, alert_bits, message_count, group_ids, family_bits = 0, 0, 0, set(), {}
        for group_id, family, alert, encoding, payload, count in db.execute('SELECT d.group_id,d.family,d.is_alert,p.encoding,p.log_presence,p.message_count FROM kl_query_definitions d JOIN kl_definition_presence p ON p.definition_id=d.id'):
            bits = presence_bits(encoding, payload)
            selected_bits |= bits
            message_count += count
            group_ids.add(group_id)
            if alert:
                alert_bits |= bits
                family_bits[family] = family_bits.get(family, 0) | bits
        valid_bytes = bytearray(largest_ordinal // 8 + 1)
        for ordinal, in db.execute("SELECT rowid FROM kl_logs INDEXED BY kl_logs_totals WHERE status<>'error'"):
            valid_bytes[ordinal // 8] |= 1 << (ordinal % 8)
        valid_bits = int.from_bytes(valid_bytes, 'little')
        selected_bytes = selected_bits.to_bytes(len(valid_bytes), 'little')
        alert_bytes = alert_bits.to_bytes(len(valid_bytes), 'little')
        db.create_function('kl_selected_bit', 1, lambda ordinal: (selected_bytes[ordinal // 8] >> (ordinal % 8)) & 1, deterministic=True)
        db.create_function('kl_alert_bit', 1, lambda ordinal: (alert_bytes[ordinal // 8] >> (ordinal % 8)) & 1, deterministic=True)
        # No log predicate is active in this branch. Copy only id/ordinal;
        # aggregate recorded scalars through the covering totals index and
        # resolve controller names/stock/UUID joins on the bounded output page.
        db.execute('CREATE TEMP TABLE kl_query_selected AS SELECT rowid AS log_ordinal,id FROM kl_logs INDEXED BY sqlite_autoindex_kl_logs_1' + (' WHERE kl_selected_bit(rowid)' if active else ''))
        fast = {'messages': message_count, 'groupCount': len(group_ids), 'familyLogCounts': {family: count for family, bits in sorted(family_bits.items()) if (count := (bits & valid_bits).bit_count())}}
    else:
        db.execute('CREATE TEMP TABLE kl_query_eligible AS ' + statement + 'SELECT ' + fields + ' FROM selected', params)
        db.execute('CREATE UNIQUE INDEX kl_query_eligible_id ON kl_query_eligible(id)')
        source = ('kl_query_eligible e CROSS JOIN kl_messages m ON m.log_id=e.id JOIN kl_query_definitions d ON d.id=m.definition_id'
                  if restricted else 'kl_query_definitions d CROSS JOIN kl_messages m INDEXED BY kl_messages_definition ON m.definition_id=d.id JOIN kl_query_eligible e ON e.id=m.log_id')
        db.execute('CREATE TEMP TABLE kl_query_counts AS SELECT m.log_id,COUNT(*) AS message_count,SUM(d.is_alert) AS alert_count FROM ' + source + ' GROUP BY m.log_id')
        db.execute('CREATE UNIQUE INDEX kl_query_counts_log ON kl_query_counts(log_id)')
        db.execute('CREATE TEMP TABLE kl_query_selected AS SELECT e.*,COALESCE(c.message_count,0) AS message_count,COALESCE(c.alert_count,0) AS alert_count FROM kl_query_eligible e ' + ('JOIN' if active else 'LEFT JOIN') + ' kl_query_counts c ON c.log_id=e.id')
    db.execute('CREATE UNIQUE INDEX kl_query_selected_id ON kl_query_selected(id)')
    if compact:
        db.execute('CREATE UNIQUE INDEX kl_query_selected_ordinal ON kl_query_selected(log_ordinal)')
    if not compact:
        db.execute('CREATE INDEX kl_query_selected_date ON kl_query_selected(date DESC,id DESC)')
    source = ('kl_query_selected s CROSS JOIN kl_messages m ON m.log_id=s.id JOIN kl_query_definitions d ON d.id=m.definition_id'
              if restricted else 'kl_query_definitions d CROSS JOIN kl_messages m INDEXED BY kl_messages_definition ON m.definition_id=d.id JOIN kl_query_selected s ON s.id=m.log_id')
    matching = ('SELECT m.log_id,m.sequence,m.message_id,d.*,m.timestamp,m.position_json,m.metadata_json,'
                '(SELECT class_key FROM kl_definitions WHERE id=d.id) AS class_key,'
                '(SELECT raw_text FROM kl_definitions WHERE id=d.id) AS raw_text,'
                '(SELECT source_key FROM kl_groups WHERE id=d.group_id) AS source_key,'
                '(SELECT title FROM kl_groups WHERE id=d.group_id) AS title FROM ' + source)
    if compact:
        compact_fields = ','.join('l.' + field for field in ('id','drone_id','drone_name','gcs_uuid','gcs_status','date','date_day','status','duration','failsafe','cached_messages','cached_alerts'))
        selected = ('SELECT s.log_ordinal,' + compact_fields + ',NULL AS message_count,NULL AS alert_count,COALESCE(names.drone_name,l.drone_name) AS canonical_name,' + IDENTITY +
                    ' AS annotation_key,links.uuid_count,links.uuid AS propagated_uuid,sn.number AS canonical_stock,legacy.number AS legacy_stock,'
                    "COALESCE(sn.number,CASE WHEN l.gcs_status<>'rejected' AND links.uuid_count=1 THEN legacy.number END) AS stock_number FROM kl_query_selected s CROSS JOIN kl_logs l ON l.id=s.id" + LOG_JOINS)
        prefix = CTE + ', '
    else:
        selected = 'SELECT s.* FROM kl_query_selected s'
        prefix = 'WITH '
    return prefix + 'matching AS NOT MATERIALIZED (' + matching + '), selected AS NOT MATERIALIZED (' + selected + ') ', [], active, fast


def registry_observations(db):
    """One immutable config read, with no invented GCS arrival timestamps."""
    database = db.execute('PRAGMA database_list').fetchone()[2]
    path = Path(database).resolve().parent / 'fleet.json' if database else None
    if path is None or not path.exists():
        return {}, 'none'
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError('Registre des observations GCS invalide ou hors budget.')
    with path.open('rb') as stream:
        raw = stream.read(4 * 1024 * 1024 + 1)
    if len(raw) > 4 * 1024 * 1024:
        raise ValueError('Registre des observations GCS hors budget.')
    value = json.loads(raw)
    if not isinstance(value, dict) or value.get('schemaVersion') != 1 or type(value.get('revision')) is not int or value['revision'] < 0 or not isinstance(value.get('drones'), list) or len(value['drones']) > 10_000:
        raise ValueError('Version ou structure du registre GCS non prise en charge.')
    result = {}
    for entry in value['drones']:
        if not isinstance(entry, dict):
            continue
        identity = entry.get('uuid')
        if not isinstance(identity, str) or not re.fullmatch(r'[A-Fa-f0-9]{24}', identity) or identity.upper() in ('0' * 24, 'F' * 24):
            continue
        key = 'gcs:' + identity.upper()
        stamp, source = None, None
        if entry.get('lastSeenSource') == 'gcs-telemetry' and isinstance(entry.get('lastSeenAtUTC'), str):
            try:
                parsed = datetime.fromisoformat(entry['lastSeenAtUTC'].replace('Z', '+00:00'))
                if parsed.tzinfo is not None:
                    stamp, source = parsed.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z'), 'gcs-telemetry'
            except ValueError:
                pass
        result[key] = {'authorized': entry.get('authorized') is True, 'lastGCSDate': stamp, 'lastGCSSource': source,
                       'name': entry.get('name') if isinstance(entry.get('name'), str) and len(entry['name']) <= 512 else None}
    return result, hashlib.sha256(raw).hexdigest()


def registry_source_coverage(db, statement, params):
    # Stored checks are explicitly dated. Source registration or a former
    # import never asserts that a removable volume is currently available.
    rows = db.execute(statement + '''SELECT selected.annotation_key,sources.path,
        observation.state,observation.checked_at FROM sources
        CROSS JOIN selected ON selected.id=sources.log_id
        LEFT JOIN source_observations observation ON observation.log_id=selected.id AND observation.path=sources.path''', params)
    result = {}
    for key, path, state, checked in rows:
        item = result.setdefault(key, {'states': set(), 'dates': {}})
        if path is not None:
            item['states'].add(state or 'unknown')
            if checked and (not item['dates'].get(state) or checked > item['dates'][state]):
                item['dates'][state] = checked
    coverage = {}
    for key, item in result.items():
        states = item['states']
        if not states or 'unknown' in states:
            status, checked = 'unknown', None
        elif 'present' in states:
            status, checked = 'present-at-check', item['dates'].get('present')
        elif len(states) == 1:
            state = next(iter(states))
            status, checked = state + '-at-check', item['dates'].get(state)
        else:
            status, checked = 'mixed', max(item['dates'].values(), default=None)
        coverage[key] = {'sourceStatus': status, 'sourceCheckedAt': checked}
    return coverage


def query(db, request, read_only=False):
    db.execute('PRAGMA cache_size=-131072')
    # Large user-defined catalogues/filters spill to temporary storage instead
    # of making helper memory proportional to all stored message definitions.
    db.execute('PRAGMA temp_store=FILE')
    scope, limit, kind, annotations, masks, group, scope_hash = parse_request(request)
    fleet, observation_revision = registry_observations(db) if kind == 'drones' else ({}, None)
    if kind == 'drones':
        scope_hash = hashlib.sha256((scope_hash + '\n' + observation_revision).encode()).hexdigest()
    if read_only:
        try:
            metadata = dict(db.execute("SELECT key,value FROM kl_meta"))
            dirty = db.execute("SELECT 1 FROM kl_dirty LIMIT 1").fetchone()
        except sqlite3.OperationalError as error:
            raise ValueError("L’index doit être préparé par l’instance disposant de l’accès en écriture.") from error
        if metadata.get('initialized') != '1' or metadata.get('projectionVersion') != str(PROJECTION_VERSION) or dirty:
            raise ValueError("L’index doit être actualisé par l’instance disposant de l’accès en écriture.")
    else:
        initialize(db)
    setup_annotations(db, annotations, masks)
    db.row_factory = sqlite3.Row
    db.execute("BEGIN")
    try:
        revision = int(db.execute("SELECT value FROM kl_meta WHERE key='revision'").fetchone()[0])
        if read_only and db.execute('SELECT 1 FROM kl_dirty LIMIT 1').fetchone():
            raise ValueError('L’index doit être actualisé par l’instance disposant de l’accès en écriture.')
        offset = cursor_value(request.get("cursor"), revision, scope_hash, kind, group)
        next_position = None
        if kind == 'catalogue':
            entries_sql = "SELECT 'family' AS kind,family AS value FROM kl_definitions UNION SELECT 'family',family FROM kl_family_overrides UNION SELECT 'level',level FROM kl_definitions"
            total = db.execute('SELECT COUNT(*) FROM (' + entries_sql + ')').fetchone()[0]
            entries = db.execute('SELECT kind,value FROM (' + entries_sql + ') ORDER BY kind,value LIMIT ? OFFSET ?', (limit, offset)).fetchall()
            result = {'queryVersion': QUERY_VERSION, 'revision': revision, 'scopeHash': scope_hash,
                      'families': [], 'levels': [], 'total': total, 'nextCursor': None}
            values = bounded_rows(entries, lambda row: {'kind': row[0], 'value': row[1]}, result)
            for item in values:
                result['families' if item['kind'] == 'family' else 'levels'].append(item['value'])
            if offset + len(values) < total:
                result['nextCursor'] = encode_cursor(revision, scope_hash, kind, group, offset + len(values))
            return result
        if kind == 'group-keys':
            clause = ' FROM kl_definitions d WHERE group_id=? AND EXISTS(SELECT 1 FROM kl_messages m WHERE m.definition_id=d.id)'
            total = db.execute('SELECT COUNT(DISTINCT class_key)' + clause, (group,)).fetchone()[0]
            rows = db.execute('SELECT DISTINCT class_key' + clause + ' ORDER BY class_key LIMIT ? OFFSET ?', (group, limit, offset)).fetchall()
            result = {'queryVersion': QUERY_VERSION, 'revision': revision, 'scopeHash': scope_hash, 'total': total, 'nextCursor': None}
            result['classKeys'] = bounded_rows(rows, lambda row: row[0], result)
            if offset + len(result['classKeys']) < total:
                result['nextCursor'] = encode_cursor(revision, scope_hash, kind, group, offset + len(result['classKeys']))
            return result
        statement, params, message_active = selection_statement(scope, metadata_only=kind == 'drones')
        if kind == 'drones':
            unrestricted_registry = not (scope['droneKeys'] or scope['logIDs'] or scope['statuses'] or scope['dateFrom'] or scope['dateTo'] or not scope['includeUnknownDates'] or scope['logSearch'] or message_active)
            if unrestricted_registry:
                # Aggregate recorded counters per controller/key before name
                # and stock joins. Fifty thousand logs do not require fifty
                # thousand lookups of each of the 500 local annotations.
                rows = db.execute(CTE + ''', aggregates AS MATERIALIZED (
                    SELECT ''' + IDENTITY + ''' AS annotation_key,l.drone_id,MIN(l.drone_name) AS fallback_name,
                        MAX(links.uuid_count) AS uuid_count,MAX(l.date) AS last_date,COUNT(*) AS log_count,
                        COALESCE(SUM(CASE WHEN l.status<>'error' THEN l.duration ELSE 0 END),0) AS recorded_seconds,
                        COALESCE(SUM(l.status<>'error' AND (l.cached_alerts>0 OR l.failsafe<>0)),0) AS alert_count
                    FROM kl_logs l INDEXED BY kl_logs_scope_meta LEFT JOIN links ON links.drone_id=l.drone_id
                    GROUP BY annotation_key,l.drone_id
                ), enriched AS NOT MATERIALIZED (
                    SELECT a.*,COALESCE(names.drone_name,a.fallback_name) AS canonical_name,
                        COALESCE(sn.number,CASE WHEN a.annotation_key LIKE 'gcs:%' AND a.uuid_count=1 THEN legacy.number END) AS stock_number
                    FROM aggregates a LEFT JOIN names ON names.drone_id=a.drone_id
                    LEFT JOIN kl_stock_numbers sn ON sn.key=a.annotation_key
                    LEFT JOIN kl_stock_numbers legacy ON legacy.key='ulog:'||a.drone_id
                ) SELECT annotation_key AS id,MIN(drone_id) AS droneID,MIN(canonical_name) AS name,
                    MIN(stock_number) AS stockNumber,MAX(last_date) AS lastDate,SUM(log_count) AS logCount,
                    SUM(recorded_seconds) AS recordedSeconds,SUM(alert_count) AS alertLogCount
                    FROM enriched GROUP BY annotation_key ORDER BY annotation_key''').fetchall()
            else:
                rows = db.execute(statement + '''SELECT annotation_key AS id,MIN(drone_id) AS droneID,
                MIN(canonical_name) AS name,MIN(stock_number) AS stockNumber,
                MAX(date) AS lastDate,COUNT(*) AS logCount,
                COALESCE(SUM(CASE WHEN status<>'error' THEN duration ELSE 0 END),0) AS recordedSeconds,
                COALESCE(SUM(status<>'error' AND (cached_alerts>0 OR failsafe<>0)),0) AS alertLogCount
                FROM selected GROUP BY annotation_key ORDER BY annotation_key''', params).fetchall()
            drones = [dict(row) for row in rows]
            keys = {item['id'] for item in drones}
            controller_keys = {'ulog:' + row[0] for row in db.execute('SELECT DISTINCT drone_id FROM kl_logs')}
            for key, number in annotations.get('stockNumbers', {}).items():
                if key not in keys and key not in controller_keys and (key.startswith('ulog:') and len(key)>5 or re.fullmatch(r'gcs:[A-F0-9]{24}', key)):
                    drones.append({'id': key, 'droneID': key[5:] if key.startswith('ulog:') else '',
                        'name': 'Drone sans log', 'stockNumber': number, 'logCount': 0, 'lastDate': '',
                        'recordedSeconds': 0, 'alertLogCount': 0})
                    keys.add(key)
            for key, observation in fleet.items():
                if observation['authorized'] and key not in keys:
                    drones.append({'id': key, 'droneID': '', 'name': observation['name'] or 'Drone sans log',
                        'stockNumber': annotations.get('stockNumbers', {}).get(key), 'logCount': 0, 'lastDate': '',
                        'recordedSeconds': 0, 'alertLogCount': 0})
                    keys.add(key)
            drones.sort(key=lambda item: item['id'])
            source_coverage = registry_source_coverage(db, statement, params)
            for item in drones:
                item['gcsUUID'] = item['id'][4:] if item['id'].startswith('gcs:') else None
                item.update(source_coverage.get(item['id'], {'sourceStatus': 'unknown' if item['logCount'] else 'none', 'sourceCheckedAt': None}))
                observation = fleet.get(item['id'], {})
                item['lastGCSDate'] = observation.get('lastGCSDate')
                item['lastGCSSource'] = observation.get('lastGCSSource')
            registry_search = normalized(request.get('registrySearch'))
            if registry_search:
                drones = [item for item in drones if registry_search in normalized(' '.join(str(item.get(key) or '') for key in ('id', 'droneID', 'name', 'stockNumber', 'gcsUUID')))]
            result = {'queryVersion': QUERY_VERSION, 'revision': revision, 'scopeHash': scope_hash,
                      'total': len(drones), 'nextCursor': None, 'registryObservationRevision': observation_revision}
            result['drones'] = bounded_rows(drones[offset:offset+limit], dict, result)
            if offset + len(result['drones']) < len(drones):
                result['nextCursor'] = encode_cursor(revision, scope_hash, kind, group, offset + len(result['drones']))
            return result
        unfiltered = not (scope['droneKeys'] or scope['statuses'] or scope['logIDs'] or scope['dateFrom'] or scope['dateTo'] or not scope['includeUnknownDates'] or scope['logSearch'] or message_active or annotations.get('familyOverrides') or (masks and not scope['includeMasked']))
        if unfiltered:
            totals = dict(db.execute("""SELECT COUNT(*) AS logs,COALESCE(SUM(status<>'error'),0) AS validLogs,
                COALESCE(SUM(CASE WHEN status<>'error' THEN duration ELSE 0 END),0) AS recordedSeconds,
                COUNT(DISTINCT drone_id) AS droneCount,COALESCE(SUM(status<>'error' AND failsafe<>0),0) AS failsafeLogs,
                COALESCE(SUM(status<>'error' AND (cached_alerts>0 OR failsafe<>0)),0) AS alertLogs,
                COALESCE(SUM(cached_messages),0) AS messages FROM kl_logs INDEXED BY kl_logs_totals""").fetchone())
            totals['groupCount'] = db.execute('SELECT COUNT(*) FROM kl_group_stats').fetchone()[0]
            totals['familyLogCounts'] = dict(db.execute('SELECT family,log_count FROM kl_family_stats ORDER BY family'))
        else:
            statement, params, message_active, compact_totals = materialize_scope(db, scope)
            summary = db.execute("""SELECT COUNT(*) AS logs,COALESCE(SUM(status<>'error'),0) AS validLogs,
                COALESCE(SUM(CASE WHEN status<>'error' THEN duration ELSE 0 END),0) AS recordedSeconds,
                COUNT(DISTINCT drone_id) AS droneCount,
                COALESCE(SUM(status<>'error' AND failsafe<>0),0) AS failsafeLogs,
                COALESCE(SUM(status<>'error' AND (""" + ('kl_alert_bit(log_ordinal)' if compact_totals else 'alert_count>0') + """
                """ + ("" if message_active else " OR failsafe<>0") + ")),0) AS alertLogs FROM " +
                ('kl_logs INDEXED BY kl_logs_totals CROSS JOIN kl_query_selected ON kl_query_selected.log_ordinal=kl_logs.rowid' if compact_totals else 'kl_query_selected')).fetchone()
            totals = dict(summary)
            if compact_totals is not None:
                totals.update(compact_totals)
            else:
                totals["messages"] = db.execute('SELECT COALESCE(SUM(message_count),0) FROM kl_query_selected').fetchone()[0]
                totals["groupCount"] = db.execute(statement + "SELECT COUNT(DISTINCT group_id) FROM matching", params).fetchone()[0]
                totals["familyLogCounts"] = dict(db.execute(statement + "SELECT family,COUNT(DISTINCT log_id) FROM matching JOIN selected ON selected.id=matching.log_id WHERE is_alert=1 AND selected.status<>'error' GROUP BY family ORDER BY family", params).fetchall())
        import analyzer
        # Global coverage is independent of the current page and selection.
        # Unanalysable error logs require an import retry, not a refresh prompt.
        stale = db.execute("SELECT COUNT(*) FROM logs c INDEXED BY kl_canonical_parser JOIN kl_logs l INDEXED BY kl_logs_scope_meta ON l.id=c.id WHERE COALESCE(c.parser_version,'')<>? AND l.status<>'error'", (analyzer.PARSER_VERSION,)).fetchone()[0]
        if stale:
            totals['libraryStaleAnalysisLogs'] = stale
        result = {"queryVersion": QUERY_VERSION, "revision": revision, "scopeHash": scope_hash, "totals": totals, "nextCursor": None}
        if message_active:
            totals['failsafeLogs'] = 0
        if kind in ("logs", 'map'):
            counts = "cached_messages AS message_count,cached_alerts AS alert_count" if unfiltered else "selected.message_count,selected.alert_count"
            compact_page = not unfiltered and compact_totals is not None
            page_select = ('SELECT selected.*,l.summary_projection,' + counts + ' FROM kl_logs l INDEXED BY kl_logs_date CROSS JOIN selected ON selected.id=l.id' if compact_page else 'SELECT selected.*, ' + counts + ' FROM selected' if unfiltered else 'SELECT selected.*,l.summary_projection,' + counts + ' FROM selected CROSS JOIN kl_logs l ON l.id=selected.id')
            direction = 'ASC' if request.get('sortOrder') == 'oldest' else 'DESC'
            order_source = 'l' if compact_page else 'selected'
            rows = db.execute(statement + page_select + " ORDER BY " + order_source + ".date " + direction + "," + order_source + ".id " + direction + " LIMIT ? OFFSET ?", params + [limit, offset]).fetchall()
            def map_log(row):
                value = json.loads(row["summary_projection"])
                message_count, alert_count = row['message_count'], row['alert_count']
                if message_count is None:
                    message_count, alert_count = db.execute('SELECT COUNT(*),COALESCE(SUM(d.is_alert),0) FROM kl_query_definitions d CROSS JOIN kl_messages m INDEXED BY kl_messages_definition ON m.definition_id=d.id WHERE m.log_id=?', (row['id'],)).fetchone()
                value["droneName"] = row["canonical_name"]
                value["stockNumber"] = row["stock_number"]
                value["summaryMessageCount"] = message_count
                value["summaryAlertMessageCount"] = alert_count
                value["summaryHasAlerts"] = bool(alert_count or (not message_active and row["failsafe"]))
                value['annotationWarning'] = None
                if row['gcs_status'] == 'rejected':
                    value['annotationWarning'] = 'Identité GCS rejetée dans ce log : aucune liaison déduite des autres enregistrements.'
                elif row['uuid_count'] and row['uuid_count'] > 1:
                    value['annotationWarning'] = 'Plusieurs identités GCS sont observées pour ce contrôleur ULog. Les logs sans preuve directe restent séparés.'
                elif row['uuid_count'] == 1 and row['canonical_stock'] and row['legacy_stock'] and row['canonical_stock'] != row['legacy_stock']:
                    value['annotationWarning'] = f"Numéros locaux en conflit : GCS {row['canonical_stock']}, ULog {row['legacy_stock']}. Le numéro GCS est affiché ; les deux annotations sont conservées jusqu’à modification."
                if row["annotation_key"].startswith("gcs:") and value.get("metadata", {}).get("gcsUUID") is None:
                    value["annotationGCSUUID"] = row["annotation_key"][4:]
                source_paths = [item[0] for item in db.execute("SELECT path FROM sources WHERE log_id=? ORDER BY path", (row["id"],))]
                import analyzer
                known_files = {item['path']: item for item in db.execute("SELECT * FROM files WHERE path IN (SELECT path FROM sources WHERE log_id=?)", (row["id"],))}
                analyzer.attach_source_availability(value, source_paths, known_files)
                if request.get("includeMessages", False):
                    message_bytes = 0
                    for item in db.execute(statement + "SELECT matching.* FROM matching WHERE log_id=? ORDER BY timestamp,sequence", params + [row["id"]]):
                        record = message_record(item)
                        message_bytes += len(json.dumps(record, ensure_ascii=False, allow_nan=False).encode('utf-8')) + 1
                        if message_bytes > MAX_QUERY_BYTES - 8192:
                            raise ValueError('Les messages de ce log dépassent le budget de page ; ouvrez les occurrences paginées ou un export détaillé.')
                        value['messages'].append(record)
                return value
            values = bounded_rows(rows, map_log, result)
            folders = sorted({str(Path(path).parent) for value in values for path in value['sourcePaths']})
            result["snapshot"] = {"schemaVersion": 1, "generatedAt": now(), "sourceFolders": folders,
                                  "importStats": latest_import_stats(db), "logs": values}
            total = totals["logs"]
        elif kind == "groups":
            sql = statement + """SELECT group_id AS id,MIN(title) AS title,MIN(family) AS family,MIN(level) AS level,
                MAX(priority) AS priority,COUNT(*) AS messageCount,COUNT(DISTINCT log_id) AS logCount,
                COUNT(DISTINCT selected.drone_id) AS droneCount,MIN(selected.date) AS firstDate,MAX(selected.date) AS lastDate
                FROM matching JOIN selected ON selected.id=matching.log_id GROUP BY group_id
                ORDER BY priority DESC,logCount DESC,id ASC LIMIT ? OFFSET ?"""
            if unfiltered:
                rows = db.execute("""SELECT s.group_id AS id,g.title,s.family,g.level,g.priority,
                    s.message_count AS messageCount,s.log_count AS logCount,s.drone_count AS droneCount,
                    s.first_date AS firstDate,s.last_date AS lastDate
                    FROM kl_group_stats s JOIN kl_groups g ON g.id=s.group_id
                    ORDER BY g.priority DESC,s.log_count DESC,s.group_id ASC LIMIT ? OFFSET ?""", (limit, offset)).fetchall()
            else:
                rows = db.execute(sql, params + [limit, offset]).fetchall()
            def map_group(row):
                value = dict(row)
                key_clause = ' FROM (SELECT DISTINCT class_key FROM kl_definitions d WHERE group_id=? AND EXISTS(SELECT 1 FROM kl_messages m WHERE m.definition_id=d.id))'
                count, size = db.execute('SELECT COUNT(*),COALESCE(SUM(LENGTH(CAST(class_key AS BLOB))),0)' + key_clause, (row['id'],)).fetchone()
                value['classKeyCount'] = count
                value['classKeysComplete'] = count <= 512 and size <= 128 * 1024
                value['classKeys'] = [item[0] for item in db.execute('SELECT class_key' + key_clause + ' ORDER BY class_key', (row['id'],))] if value['classKeysComplete'] else []
                return value
            values = bounded_rows(rows, map_group, result)
            result.update(groups=values, total=totals["groupCount"])
            total = totals["groupCount"]
        elif kind == 'events':
            import analyzer
            coverage = dict(db.execute(statement + '''SELECT COUNT(*) AS selectedLogs,
                COALESCE(SUM(c.log_id IS NOT NULL),0) AS cachedLogs,
                COALESCE(SUM(c.log_id IS NULL),0) AS unavailableLogs,
                COALESCE(SUM(c.state='legacy'),0) AS legacyCacheLogs,
                COALESCE(SUM(c.state='invalid'),0) AS invalidCacheLogs,
                COALESCE(SUM(c.event_count>0),0) AS eventLogs,
                COALESCE(SUM(c.translated_count>0),0) AS translatedLogs,
                COALESCE(SUM(c.parser_version<>?),0) AS previousParserLogs
                FROM selected LEFT JOIN kl_event_cache c ON c.log_id=selected.id''', params + [analyzer.PARSER_VERSION]).fetchone())
            event_clauses, event_values = [], []
            levels = string_list(request.get('eventLevels', []), 'eventLevels')
            if levels:
                level_column = 'external_level' if request.get('eventLevelSource') == 'external' else 'internal_level'
                event_clauses.append('e.' + level_column + ' IN (' + ','.join('?' for _ in levels) + ')')
                event_values.extend(levels)
            search = normalized(request.get('eventSearch', ''))
            if search:
                event_clauses.append("e.search_text LIKE ? ESCAPE '\\'")
                event_values.append(like_pattern(search))
            where = ' WHERE ' + ' AND '.join(event_clauses) if event_clauses else ''
            total = db.execute(statement + 'SELECT COUNT(*) FROM selected JOIN kl_events e ON e.log_id=selected.id' + where, params + event_values).fetchone()[0]
            rows = db.execute(statement + 'SELECT e.*,selected.drone_id,selected.canonical_name,selected.stock_number,selected.date FROM kl_logs l INDEXED BY kl_logs_date CROSS JOIN selected ON selected.id=l.id CROSS JOIN kl_events e ON e.log_id=l.id' + where + ' ORDER BY l.date DESC,l.id DESC,(e.time_seconds IS NULL),e.time_seconds,e.sequence LIMIT ? OFFSET ?', params + event_values + [limit, offset]).fetchall()
            def map_event(row):
                return {'logID': row['log_id'], 'droneID': row['drone_id'],
                        'droneName': 'Drone ' + row['stock_number'] if row['stock_number'] else row['canonical_name'],
                        'date': row['date'], 'sourcePaths': [item[0] for item in db.execute('SELECT path FROM sources WHERE log_id=? ORDER BY path', (row['log_id'],))],
                        'event': json.loads(row['event_json'])}
            values = bounded_rows(rows, map_event, result)
            result.update(occurrences=values, total=total, coverage=coverage)
        else:
            condition, extra = (" WHERE matching.group_id=?", [group]) if group else ("", [])
            if unfiltered:
                count = db.execute('SELECT message_count FROM kl_group_stats WHERE group_id=?', (group,)).fetchone() if group else None
                total = (count[0] if count else 0) if group else totals['messages']
            elif not group:
                total = totals['messages']
            else:
                total = db.execute(statement + "SELECT COUNT(*) FROM matching JOIN selected ON selected.id=matching.log_id" + condition, params + extra).fetchone()[0]
            clauses, position_values, page_offset = (['matching.group_id=?'], [group], offset) if group else ([], [], offset)
            if request.get('cursor'):
                token = json.loads(base64.urlsafe_b64decode(request['cursor'] + '=' * (-len(request['cursor']) % 4)))
                position = token.get('position')
                if position is not None:
                    if not isinstance(position, list) or len(position) != 4 or not isinstance(position[0], str) or not isinstance(position[1], str) or not isinstance(position[2], (int, float)) or isinstance(position[2], bool) or not math.isfinite(position[2]) or type(position[3]) is not int or position[3] < 0:
                        raise ValueError('Position de curseur d’occurrence invalide.')
                    clauses.append('(l.date,l.id)<=(?,?) AND (l.date<? OR l.id<? OR (matching.timestamp>? OR (matching.timestamp=? AND matching.sequence>?)))')
                    position_values.extend((position[0], position[1], position[0], position[1], position[2], position[2], position[3]))
                    page_offset = 0
            where = ' WHERE ' + ' AND '.join(clauses) if clauses else ''
            rows = db.execute(statement + 'SELECT matching.*,selected.drone_id,selected.canonical_name,selected.stock_number,selected.date FROM kl_logs l INDEXED BY kl_logs_date CROSS JOIN selected ON selected.id=l.id CROSS JOIN matching ON matching.log_id=l.id' + where + ' ORDER BY l.date DESC,l.id DESC,matching.timestamp,matching.sequence LIMIT ? OFFSET ?', params + position_values + [limit, page_offset]).fetchall()
            def map_occurrence(row):
                paths = [item[0] for item in db.execute("SELECT path FROM sources WHERE log_id=? ORDER BY path", (row["log_id"],))]
                return {"logID": row["log_id"], "droneID": row["drone_id"], "droneName": "Drone " + row["stock_number"] if row["stock_number"] else row["canonical_name"],
                        "date": row["date"], "sourcePaths": paths, "message": message_record(row)}
            values = bounded_rows(rows, map_occurrence, result)
            if values:
                last = rows[len(values)-1]
                next_position = [last['date'], last['log_id'], last['timestamp'], last['sequence']]
            result.update(occurrences=values, total=total)
        if offset + len(values) < total:
            result["nextCursor"] = encode_cursor(revision, scope_hash, kind, group, offset + len(values), next_position)
        if len(json.dumps(result, ensure_ascii=False, allow_nan=False).encode("utf-8")) > MAX_QUERY_BYTES:
            raise ValueError("La réponse dépasse le budget de requête ; réduisez le périmètre ou utilisez un export détaillé.")
        return result
    finally:
        db.commit()


def message_record(row):
    value = {"id": row["message_id"], "timestampSeconds": row["timestamp"], "level": row["level"],
             "text": row["raw_text"], "family": row["family"], "groupKey": row["source_key"],
             "title": row["title"], "isAlert": bool(row["is_alert"]), "isMasked": bool(row["masked"])}
    if row["position_json"]:
        value["position"] = json.loads(row["position_json"])
    if row['metadata_json']:
        metadata = json.loads(row['metadata_json'])
        value.update({key: metadata[key] for key in MESSAGE_METADATA_FIELDS if key in metadata})
    if row["source_family"] != row["family"]:
        value["sourceFamily"] = row["source_family"]
    return value


def latest_import_stats(db):
    row = db.execute("SELECT value FROM settings WHERE key='lastImportStats'").fetchone()
    return json.loads(row[0]) if row else {key: 0 for key in ("discovered", "imported", "unchanged", "duplicates", "failed")}
