"""Immutable analysis revisions; the caller owns the SQLite transaction."""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import re
import sqlite3
import zlib

ANALYSIS_REVISION_VERSION = 1
MAX_ANALYSIS_BYTES = 64 * 1024 * 1024
MAX_REVISION_STORAGE_BYTES = 512 * 1024 * 1024


class RevisionBudgetError(ValueError):
    """Preserve the published analysis when revision retention cannot proceed."""


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


def revision_page(db, log_id, offset, limit):
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
