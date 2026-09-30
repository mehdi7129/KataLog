"""Immutable report captures and streaming exports from the indexed library.

The caller holds the library maintenance gate only during capture_report.
prepare_report reads the private capture, never the live DB or source ULogs.
Large reports retain all selected messages in an integral JSON attachment;
the bounded HTML is rendered by the native service after this step.
"""
from __future__ import annotations
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import sqlite3
import tempfile
import time
import uuid

import library_repository as repository

REPORT_VERSION = 1
MAX_CONTEXT_BYTES = 16 * 1024 * 1024
MAX_INLINE_JSON_BYTES = 8 * 1024 * 1024
MAX_HTML_BYTES = 10 * 1024 * 1024
PAGE_SIZE = 200


class ReportCancelled(Exception):
    pass


def _check(cancel):
    if cancel is not None and cancel():
        raise ReportCancelled('Export annulé.')


def now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')


def _hash(path, cancel=None):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(64 * 1024), b''):
            _check(cancel)
            value.update(chunk)
    return value.hexdigest()


def _json_chunks(value):
    """Escape long raw strings in small chunks instead of duplicating them."""
    if isinstance(value, str):
        yield b'"'
        for index in range(0, len(value), 8192):
            yield json.dumps(value[index:index + 8192], ensure_ascii=False)[1:-1].encode('utf-8')
        yield b'"'
    elif isinstance(value, dict):
        yield b'{'
        for index, (key, item) in enumerate(value.items()):
            if index: yield b','
            yield from _json_chunks(str(key)); yield b':'
            yield from _json_chunks(item)
        yield b'}'
    elif isinstance(value, (list, tuple)):
        yield b'['
        for index, item in enumerate(value):
            if index: yield b','
            yield from _json_chunks(item)
        yield b']'
    else:
        yield json.dumps(value, allow_nan=False, separators=(',', ':')).encode('utf-8')


class _Writer:
    def __init__(self, path, cancel):
        self.path, self.cancel = Path(path), cancel
        self.stream = self.path.open('xb')
        self.sha, self.size = hashlib.sha256(), 0

    def write(self, raw):
        for index in range(0, len(raw), 64 * 1024):
            _check(self.cancel)
            chunk = raw[index:index + 64 * 1024]
            self.stream.write(chunk); self.sha.update(chunk); self.size += len(chunk)

    def value(self, value):
        for chunk in _json_chunks(value): self.write(chunk)

    def close(self):
        self.stream.flush(); os.fsync(self.stream.fileno()); self.stream.close()
        return {'name': self.path.name, 'sizeBytes': self.size, 'sha256': self.sha.hexdigest()}


def _write_json(path, value, cancel=None):
    writer = _Writer(path, cancel)
    try:
        writer.value(value)
        return writer.close()
    finally:
        if not writer.stream.closed: writer.stream.close()


def _progress(path, completed, total, current):
    if path is None: return
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.' + destination.name, dir=destination.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump({'completed': completed, 'total': total, 'current': current}, stream, ensure_ascii=False)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)


def _request(value):
    if not isinstance(value, dict) or value.get('reportVersion', REPORT_VERSION) != REPORT_VERSION:
        raise ValueError('Version de rapport non prise en charge.')
    query = value.get('query', {})
    query = dict(query)
    query.update(kind='logs', includeMessages=True, limit=PAGE_SIZE)
    repository.parse_request(query)
    options = value.get('options', {})
    if not isinstance(options, dict): raise ValueError('Options de rapport invalides.')
    parsed = {}
    for key in ('excludePaths', 'excludeIdentity', 'excludeCoordinates', 'includeCachedDetails'):
        option = options.get(key, False)
        if not isinstance(option, bool): raise ValueError('Option de rapport invalide : ' + key)
        parsed[key] = option
    parsed['format'] = options.get('format', 'html')
    if parsed['format'] not in ('json', 'html'): raise ValueError('Format de rapport invalide.')
    mode = value.get('mode', 'full')
    if mode not in ('full', 'selection', 'flight'): raise ValueError('Périmètre de rapport invalide.')
    description = value.get('scopeDescription', 'Toute la bibliothèque')
    if not isinstance(description, str): raise ValueError('Description de périmètre invalide.')
    return {'reportVersion': REPORT_VERSION, 'query': query, 'options': parsed,
            'mode': mode, 'scopeDescription': description,
            'viewRevision': value.get('viewRevision', 0)}


def capture_report(database, capture, request, cancel=None):
    """Capture DB+in-memory annotations/views as one revision under caller gate."""
    context = _request(request)
    target = Path(capture)
    _check(cancel)
    target.mkdir(parents=True, exist_ok=False, mode=0o700)
    reader = sqlite3.connect(Path(database).resolve().as_uri() + '?mode=ro', uri=True, timeout=.5)
    writer = sqlite3.connect(target / 'library.sqlite')
    completed = False
    try:
        reader.backup(writer, pages=64, progress=lambda *args: _check(cancel), sleep=.05)
        writer.close()
        writer = None
        # Derived projections are prepared only in the captured copy. This also
        # supports an older library while leaving the live schema untouched.
        copy = sqlite3.connect(target / 'library.sqlite')
        try:
            repository.initialize(copy)
            scope, _, _, annotations, masks, _, scope_hash = repository.parse_request(context['query'])
            repository.setup_annotations(copy, annotations, masks)
            statement, params, active = repository.selection_statement(scope)
            revision = int(copy.execute("SELECT value FROM kl_meta WHERE key='revision'").fetchone()[0])
            totals = {'logs': copy.execute(statement + 'SELECT COUNT(*) FROM selected', params).fetchone()[0],
                      'messages': copy.execute(statement + 'SELECT COUNT(*) FROM matching JOIN selected ON selected.id=matching.log_id', params).fetchone()[0],
                      'droneCount': copy.execute(statement + 'SELECT COUNT(DISTINCT drone_id) FROM selected', params).fetchone()[0]}
        finally: copy.close()
        context.update(revision=revision, scopeHash=scope_hash, capturedAt=now(), captureID=uuid.uuid4().hex)
        _write_json(target / 'context.json', context, cancel)
        manifest = {'reportVersion': REPORT_VERSION, 'revision': revision, 'scopeHash': scope_hash,
                    'captureID': context['captureID'], 'capturedAt': context['capturedAt'],
                    'contextSHA256': _hash(target / 'context.json', cancel),
                    'databaseSHA256': _hash(target / 'library.sqlite', cancel),
                    'totalLogs': totals['logs'], 'totalMessages': totals['messages'],
                    'totals': totals}
        _write_json(target / 'capture-manifest.json', manifest, cancel)
        completed = True
        return manifest
    finally:
        if writer is not None: writer.close()
        reader.close()
        if not completed: shutil.rmtree(target)


def _load_capture(capture, cancel=None):
    root = Path(capture)
    for filename in ('context.json', 'capture-manifest.json'):
        path = root / filename
        if path.is_symlink() or path.stat().st_size > MAX_CONTEXT_BYTES:
            raise ValueError('Capture de rapport invalide.')
    manifest = json.loads((root / 'capture-manifest.json').read_text())
    context = json.loads((root / 'context.json').read_text())
    if manifest.get('reportVersion') != REPORT_VERSION or context.get('reportVersion') != REPORT_VERSION:
        raise ValueError('Version de capture invalide.')
    if _hash(root / 'context.json', cancel) != manifest.get('contextSHA256') or _hash(root / 'library.sqlite', cancel) != manifest.get('databaseSHA256'):
        raise ValueError('La capture du rapport a changé ; export refusé.')
    if any(context.get(key) != manifest.get(key) for key in ('revision', 'scopeHash', 'captureID', 'capturedAt')):
        raise ValueError('Révision de capture incohérente.')
    return context, manifest


def _header(db, row, context):
    value = json.loads(row['summary_projection'])
    if context['options']['includeCachedDetails']:
        tables = {item[0] for item in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if 'flight_details' in tables:
            cached = db.execute('SELECT summary,parser_version FROM flight_details WHERE log_id=?', (row['id'],)).fetchone()
            if cached:
                candidate = json.loads(cached[0])
                if candidate.get('id') == row['id']:
                    # Cache enrichment never overwrites canonical identity/date.
                    for key in ('analysisRevision', 'parameters', 'parameterDetails', 'parameterChanges', 'topicDetails', 'telemetryFields', 'telemetryCatalogue',
                                'telemetry', 'events', 'eventDictionary', 'eventCoverage', 'metadataDetails', 'dropouts', 'batteryDetails', 'gnssDetails'):
                        if key in candidate: value[key] = candidate[key]
                    if 'analysis_revisions' in tables:
                        revision = db.execute("SELECT id,log_id,kind,parser_version,analysis_sha256,created_at,size_bytes FROM analysis_revisions WHERE log_id=? AND kind='detail' AND parser_version=? AND analysis_sha256=?", (row['id'], cached[1], hashlib.sha256(cached[0].encode()).hexdigest())).fetchone()
                        if revision:
                            import analyzer
                            value['analysisRevision'] = analyzer.revision_metadata(db, revision)
    value['droneName'] = row['canonical_name']
    value['stockNumber'] = row['stock_number']
    value['selectionIncludesFailsafe'] = not context['messageActive']
    if row['annotation_key'].startswith('gcs:') and value.get('metadata', {}).get('gcsUUID') is None:
        value['annotationGCSUUID'] = row['annotation_key'][4:]
    paths = {item[0] for item in db.execute('SELECT path FROM sources WHERE log_id=?', (row['id'],))}
    paths.update(value.get('sourcePaths', []))
    value['sourcePaths'] = sorted(paths)
    value.pop('messages', None)
    return value


class _Shared:
    """Conservative allowlist: unknown free text may contain any excluded data."""
    def __init__(self):
        self.drones, self.families = {}, {}
        self.group_salt = os.urandom(32)

    def drone(self, value):
        return self.drones.setdefault(value, f'drone-{len(self.drones) + 1:04d}')

    def family(self, value):
        return self.families.setdefault(value, f'Famille {len(self.families) + 1}')

    def header(self, source, ordinal):
        drone = self.drone(source['droneID'])
        try:
            datetime.fromisoformat(source['date'].replace('Z', '+00:00'))
            date = source['date']
        except (ValueError, TypeError, AttributeError):
            date = 'Date inconnue'
        return {'id': f'log-{ordinal:06d}', 'droneID': drone, 'droneName': drone,
                'date': date, 'dateSource': 'Date source', 'sourcePaths': [],
                'fileName': f'log-{ordinal:06d}.ulg', 'sizeBytes': source['sizeBytes'],
                'durationSeconds': source['durationSeconds'], 'flightSeconds': source.get('flightSeconds'),
                'flightObservedSeconds': source.get('flightObservedSeconds'),
                'flightCoverageSeconds': source.get('flightCoverageSeconds'),
                'flightCoverageFraction': source.get('flightCoverageFraction'),
                'status': source['status'] if source['status'] in ('ok', 'error', 'warning', 'partial') else 'partial',
                'issues': [], 'metadata': {}, 'topics': [], 'metrics': [],
                'coverage': ['Synthèse anonymisée : textes et métadonnées brutes retirés.'],
                'failsafeObserved': bool(source.get('failsafeObserved')),
                'selectionIncludesFailsafe': source['selectionIncludesFailsafe']}

    def message(self, source, ordinal):
        family = self.family(source.get('family', 'Autres'))
        level = source.get('level', 'UNKNOWN')
        if level not in repository.PRIORITIES: level = 'UNKNOWN'
        return {'id': f'occurrence-{ordinal}', 'timestampSeconds': source['timestampSeconds'],
                'level': level, 'text': 'Texte brut retiré du rapport partagé', 'title': 'Texte brut retiré',
                'family': family, 'groupKey': 'group-' + hashlib.sha256(self.group_salt + str(source['groupKey']).encode()).hexdigest(), 'isAlert': bool(source['isAlert']),
                'isMasked': bool(source.get('isMasked'))}


def prepare_report(capture, destination, cancel=None, progress=None):
    """Stream full selection from a capture to a new unpublished directory."""
    context, captured = _load_capture(capture, cancel)
    root = Path(destination)
    root.mkdir(parents=True, exist_ok=False, mode=0o700)
    query = context['query']
    scope, _, _, annotations, masks, _, scope_hash = repository.parse_request(query)
    db = sqlite3.connect((Path(capture) / 'library.sqlite').resolve().as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    db.set_progress_handler(lambda: 1 if cancel is not None and cancel() else 0, 1000)
    shared = any(context['options'][key] for key in ('excludePaths', 'excludeIdentity', 'excludeCoordinates'))
    redaction = _Shared() if shared else None
    writer = None
    completed = False
    last_progress = time.monotonic()
    try:
        repository.setup_annotations(db, annotations, masks)
        db.execute('CREATE TEMP TABLE report_source_folders(path TEXT PRIMARY KEY)')
        statement, params, active = repository.selection_statement(scope)
        context['messageActive'] = active
        if scope_hash != captured['scopeHash']: raise ValueError('Périmètre de capture incohérent.')
        revision = int(db.execute("SELECT value FROM kl_meta WHERE key='revision'").fetchone()[0])
        if revision != captured['revision']: raise ValueError('Révision du rapport incohérente.')
        exported_scope = 'Synthèse anonymisée de la sélection capturée' if shared else context['scopeDescription']
        export_manifest = {'schemaVersion': REPORT_VERSION, 'producer': 'KataLog', 'mode': context['mode'], 'revision': str(revision),
                           'scopeDescription': exported_scope, 'generatedAt': captured['capturedAt'],
                           'includesMaskedMessages': scope['includeMasked'],
                           'completeness': 'partial' if context['options']['includeCachedDetails'] and not shared else 'summary',
                           'availableSections': ['messages'] if shared else ['messages', 'metrics', 'metadata', 'topics', 'sources'],
                           'unavailableSections': ['rawText', 'metadata', 'parameters', 'events', 'topics', 'telemetry', 'coordinates', 'sourcePaths', 'identity'] if shared else [],
                           'requestedPrivacy': context['options'],
                           'effectivePrivacy': {'excludePaths': shared, 'excludeIdentity': shared, 'excludeCoordinates': shared,
                                                'freeTextRemoved': shared, 'unknownMetadataRemoved': shared},
                           'capturedLogCount': captured['totalLogs'], 'capturedMessageCount': captured['totalMessages'],
                           'scopeHash': None if shared else captured['scopeHash'],
                           'captureContextSHA256': None if shared else captured['contextSHA256'],
                           'captureDatabaseSHA256': None if shared else captured['databaseSHA256'],
                           'captureProvenance': 'Immutable SQLite capture with local annotations; source ULogs unchanged',
                           'detailPolicy': 'cached-only' if context['options']['includeCachedDetails'] and not shared else 'summary',
                           'rawDataIncluded': not shared}
        writer = _Writer(root / 'rapport.json', cancel)
        writer.write(b'{"schemaVersion":1,"generatedAt":'); writer.value(captured['capturedAt'])
        stats = repository.latest_import_stats(db)
        if shared:
            stats = {key: value for key, value in stats.items() if key in ('discovered', 'imported', 'unchanged', 'duplicates', 'failed', 'reanalyzed') and type(value) is int}
        writer.write(b',"importStats":'); writer.value(stats)
        writer.write(b',"reportManifest":'); writer.value(export_manifest)
        writer.write(b',"logs":[')
        log_count, message_count, detailed_count = 0, 0, 0
        _progress(progress, 0, captured['totalLogs'], 'Préparation des données du rapport…')
        valid_logs, seconds, alert_logs, failsafe_logs = 0, 0.0, 0, 0
        families = {}
        cursor = db.execute(statement + 'SELECT * FROM selected ORDER BY date DESC,id DESC', params)
        while True:
            _check(cancel)
            page = cursor.fetchmany(PAGE_SIZE)
            if not page: break
            for row in page:
                _check(cancel)
                log_count += 1
                source = _header(db, row, context)
                if not shared:
                    db.executemany('INSERT OR IGNORE INTO report_source_folders VALUES(?)',
                                   ((str(Path(path).parent),) for path in source.get('sourcePaths', [])))
                if any(key in source for key in ('parameters', 'events', 'telemetryFields')): detailed_count += 1
                header = redaction.header(source, log_count) if redaction else source
                if log_count > 1: writer.write(b',')
                writer.write(b'{')
                for index, (key, value) in enumerate(header.items()):
                    if index: writer.write(b',')
                    writer.value(key); writer.write(b':'); writer.value(value)
                writer.write(b',"messages":[')
                records = db.execute(statement + 'SELECT matching.* FROM matching WHERE log_id=? ORDER BY timestamp,sequence', params + [row['id']])
                per_log_messages, per_log_alerts, seen_families = 0, 0, set()
                for item in records:
                    _check(cancel)
                    message_count += 1; per_log_messages += 1
                    record = repository.message_record(item)
                    if record['isAlert']:
                        per_log_alerts += 1
                        if row['status'] != 'error': seen_families.add(record['family'])
                    if redaction: record = redaction.message(record, message_count)
                    if per_log_messages > 1: writer.write(b',')
                    writer.value(record)
                    if time.monotonic() - last_progress >= .25:
                        _progress(progress, log_count - 1, captured['totalLogs'],
                                  f'{message_count} messages · {writer.size} octets · génération JSON')
                        last_progress = time.monotonic()
                writer.write(b']}')
                if row['status'] != 'error':
                    valid_logs += 1; seconds += row['duration']
                    failsafe_logs += bool(row['failsafe']) and not active
                    alert_logs += bool(per_log_alerts or (row['failsafe'] and not active))
                    for family in seen_families:
                        label = redaction.family(family) if redaction else family
                        families[label] = families.get(label, 0) + 1
            _progress(progress, log_count, captured['totalLogs'],
                      f'{message_count} messages · {writer.size} octets · génération JSON')
            last_progress = time.monotonic()
        writer.write(b'],"sourceFolders":[')
        for index, row in enumerate(db.execute('SELECT path FROM report_source_folders ORDER BY path')):
            if index: writer.write(b',')
            writer.value(row[0])
        writer.write(b']}')
        full_entry = writer.close(); writer = None
        if log_count != captured['totalLogs'] or message_count != captured['totalMessages']:
            raise ValueError('Le rapport ne contient pas toutes les occurrences capturées.')
        export_manifest.update(totalLogs=log_count, totalMessages=message_count, detailedCachedLogCount=detailed_count,
                               renderMode='interactive' if full_entry['sizeBytes'] <= MAX_INLINE_JSON_BYTES else 'summary-with-attachments',
                               inlineJSONBudget=MAX_INLINE_JSON_BYTES, htmlBudget=MAX_HTML_BYTES,
                               files=[full_entry], truncated=False)
        summary = {'schemaVersion': REPORT_VERSION, 'generatedAt': captured['capturedAt'],
                   'scopeDescription': exported_scope, 'totalLogs': log_count, 'totalMessages': message_count,
                   'validLogs': valid_logs, 'recordedSeconds': seconds, 'alertLogs': alert_logs,
                   'failsafeLogs': failsafe_logs, 'familyLogCounts': families,
                   'droneCount': len(redaction.drones) if redaction else captured['totals']['droneCount'],
                   'rawDataIncluded': not shared, 'detailedCachedLogCount': detailed_count}
        export_manifest['files'].append(_write_json(root / 'summary.json', summary, cancel))
        _write_json(root / 'manifest.json', export_manifest, cancel)
        _progress(progress, log_count, captured['totalLogs'],
                  f'{message_count} messages · données intégrales prêtes · composition du rapport')
        completed = True
        return {'reportVersion': REPORT_VERSION, 'revision': revision, 'scopeHash': None if shared else scope_hash,
                'renderMode': export_manifest['renderMode'], 'logCount': log_count, 'messageCount': message_count,
                'rawDataIncluded': not shared, 'files': export_manifest['files'], 'manifest': export_manifest}
    except sqlite3.OperationalError as error:
        if cancel is not None and cancel(): raise ReportCancelled('Export annulé.') from error
        raise
    finally:
        if writer is not None: writer.stream.close()
        db.close()
        if not completed: shutil.rmtree(root)
