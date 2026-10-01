"""Local clients and log attribution, separate from immutable analyses.

All mutations run under the application's writer lease and an SQLite write
transaction. No method in this module removes any physical file.
"""
from __future__ import annotations

import json
from pathlib import Path
import uuid


def initialize(db):
    db.execute('CREATE TABLE IF NOT EXISTS clients(id TEXT PRIMARY KEY,name TEXT NOT NULL)')
    db.execute('CREATE TABLE IF NOT EXISTS log_clients(log_id TEXT PRIMARY KEY,client_id TEXT NOT NULL)')
    db.execute('CREATE INDEX IF NOT EXISTS log_clients_client ON log_clients(client_id,log_id)')
    db.execute('CREATE TRIGGER IF NOT EXISTS log_clients_delete AFTER DELETE ON logs BEGIN DELETE FROM log_clients WHERE log_id=old.id; END')


def prepare_readonly(db):
    """An older library has no clients yet; represent that only in TEMP.

    A second, read-only app instance must neither migrate the writer's library
    nor fail a legitimate Sans client scope during an upgrade.
    """
    tables = {row[0] for row in db.execute("SELECT name FROM main.sqlite_master WHERE type='table'")}
    if 'clients' not in tables:
        db.execute('CREATE TEMP TABLE IF NOT EXISTS clients(id TEXT PRIMARY KEY,name TEXT NOT NULL)')
    if 'log_clients' not in tables:
        db.execute('CREATE TEMP TABLE IF NOT EXISTS log_clients(log_id TEXT PRIMARY KEY,client_id TEXT NOT NULL)')


def validate_id(value, optional=False):
    if optional and value in (None, ''):
        return None
    if not isinstance(value, str) or len(value) > 64:
        raise ValueError('Identifiant de client invalide.')
    try:
        return str(uuid.UUID(value)).upper()
    except (ValueError, AttributeError) as error:
        raise ValueError('Identifiant de client invalide.') from error


def require_client(db, identity):
    identity = validate_id(identity, optional=True)
    if identity is not None and not db.execute('SELECT 1 FROM clients WHERE id=?', (identity,)).fetchone():
        raise ValueError('Ce client n’existe plus. Choisissez un client ou « Sans client ».')
    return identity


def bump_revision(db):
    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='kl_meta'").fetchone():
        db.execute("UPDATE kl_meta SET value=CAST(value AS INTEGER)+1 WHERE key='revision'")


def attach(db, log):
    # Legacy read-only databases may not yet have the additive client tables.
    if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='log_clients'").fetchone():
        return log
    row = db.execute('SELECT c.id,c.name FROM log_clients l JOIN clients c ON c.id=l.client_id WHERE l.log_id=?', (log['id'],)).fetchone()
    log['clientID'], log['clientName'] = (row[0], row[1]) if row else (None, None)
    return log


def command(database, operation, request=None, read_only=False):
    import analyzer
    import library_repository as repository
    request = request or {}
    if not isinstance(request, dict):
        raise ValueError('Requête de clients invalide.')
    if read_only and operation != 'clients':
        raise ValueError('Modification interdite en lecture seule.')
    db = analyzer.open_database(database, read_only=read_only)
    try:
        if operation == 'clients':
            if not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='clients'").fetchone():
                return {'clients': []}
            return {'clients': [dict(row) for row in db.execute('SELECT id,name FROM clients ORDER BY name COLLATE NOCASE,id')]}
        repository.initialize(db)
        if operation == 'assign-client':
            scope, _, _, annotations, masks, _, _ = repository.parse_request(dict(request, kind='logs'))
            repository.setup_annotations(db, annotations, masks)
        db.execute('BEGIN IMMEDIATE')
        if operation in ('create-client', 'rename-client'):
            name = request.get('name')
            if not isinstance(name, str) or not name.strip() or len(name.strip()) > 120 or any(ord(c) < 32 for c in name):
                raise ValueError('Le nom du client doit contenir de 1 à 120 caractères.')
            name = name.strip()
            identity = (validate_id(request['id']) if request.get('id') is not None else str(uuid.uuid4()).upper())
            if operation == 'rename-client':
                require_client(db, identity)
                db.execute('UPDATE clients SET name=? WHERE id=?', (name, identity))
            else:
                if db.execute('SELECT 1 FROM clients WHERE id=?', (identity,)).fetchone():
                    raise ValueError('Ce client existe déjà.')
                db.execute('INSERT INTO clients VALUES(?,?)', (identity, name))
            result = {'id': identity, 'name': name}
        elif operation == 'delete-client':
            identity = require_client(db, request.get('id'))
            if identity is None:
                raise ValueError('Choisissez le client à retirer.')
            count = db.execute('DELETE FROM log_clients WHERE client_id=?', (identity,)).rowcount
            db.execute('DELETE FROM clients WHERE id=?', (identity,))
            result = {'id': identity, 'unassignedLogs': count, 'originalsDeleted': False}
        elif operation == 'assign-client':
            identity = require_client(db, request.get('clientID'))
            statement, params, _ = repository.selection_statement(scope)
            db.execute('CREATE TEMP TABLE client_assignment AS ' + statement + 'SELECT id FROM selected', params)
            count = db.execute('SELECT COUNT(*) FROM client_assignment').fetchone()[0]
            db.execute('DELETE FROM log_clients WHERE log_id IN (SELECT id FROM client_assignment)')
            if identity:
                db.execute('INSERT INTO log_clients SELECT id,? FROM client_assignment', (identity,))
            result = {'clientID': identity, 'assignedLogs': count}
        else:
            raise ValueError('Action client inconnue.')
        bump_revision(db)
        db.commit()
        return result
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


def retire_all_sources(database):
    import analyzer
    import library_sources
    db = analyzer.open_database(database)
    try:
        db.execute('BEGIN IMMEDIATE')
        db.execute('INSERT OR IGNORE INTO source_folder_retirements SELECT path,? FROM folders', (analyzer.utc_now(),))
        bump_revision(db)
        result = {**library_sources.counts(db), 'logsDeleted': False, 'originalsDeleted': False}
        db.commit()
        return result
    finally:
        db.close()


def reset_library(database, library, all_settings=False):
    """Reset known database rows only; even unknown tables/files survive.

    The caller clears its owned preferences, identities and collection state
    for a full reset. Stable writer locks and original logs are never touched.
    """
    import analyzer
    import library_repository as repository
    if Path(database).resolve().parent != Path(library).resolve():
        raise ValueError('La base doit appartenir à la bibliothèque choisie.')
    db = analyzer.open_database(database)
    try:
        repository.initialize(db)
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        db.execute('BEGIN IMMEDIATE')
        count = db.execute('SELECT COUNT(*) FROM logs').fetchone()[0]
        # Explicitly enumerate owned state: never glob or unlink library files.
        owned = ('log_clients', 'spatial_tracks', 'flight_details', 'analysis_revisions',
                 'sources', 'files', 'folders', 'source_folder_retirements', 'source_observations',
                 'managed_archives', 'kl_messages', 'kl_definitions', 'kl_groups', 'kl_group_stats',
                 'kl_family_stats', 'kl_definition_presence', 'kl_events', 'kl_event_cache', 'logs',
                 'kl_logs', 'kl_dirty')
        for table in owned:
            if table in tables:
                db.execute('DELETE FROM ' + table)
        db.execute("DELETE FROM settings WHERE key='lastImportStats'")
        db.execute("INSERT OR REPLACE INTO settings VALUES('analysisRevisionStorageBytes','0')")
        if all_settings:
            db.execute('DELETE FROM clients')
        bump_revision(db)
        db.commit()
        repository.initialize(db)
        return {'ok': True, 'removedLogs': count, 'allSettings': all_settings, 'originalsDeleted': False}
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
