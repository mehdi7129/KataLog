"""Managed SHA archives and reversible detail-cache maintenance.

Caller owns the library writer lease. All original ULog sources remain read only.
"""
from __future__ import annotations

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import tempfile
import uuid

import analyzer
import library_repository
from library_storage import atomic_json, digest

SHA = re.compile(r'[a-f0-9]{64}')
SPACE_RESERVE = 16 * 1024 * 1024


def now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')


def identities(values):
    if not isinstance(values, list) or len(values) > 100_000 or not all(isinstance(value, str) and SHA.fullmatch(value) for value in values):
        raise ValueError('La sélection doit contenir des identifiants SHA de logs.')
    return list(dict.fromkeys(values))


def verified_archive_copy(source, target, identity, expected_signature=None, on_temporary=None):
    """Publish a verified byte copy without overwriting any existing archive.

    No library row is needed: this also runs before the parser at import time.
    The caller can journal the exact staging file for crash recovery.
    """
    identity = identities([identity])[0]
    source, target = Path(source), Path(target)
    if target.exists() or target.is_symlink():
        if target.is_symlink() or not target.is_file() or digest(target) != identity:
            raise ValueError('Une archive existe avec un contenu différent ; elle est conservée.')
        if expected_signature is not None and target.stat().st_size != expected_signature[0]:
            raise ValueError('La taille de l’archive ne correspond pas à la source préparée.')
        return True
    before = source.stat()
    if source.is_symlink() or not stat.S_ISREG(before.st_mode):
        raise ValueError('La source d’archive doit être un fichier régulier.')
    if expected_signature is not None and analyzer.stat_signature(before) != expected_signature:
        raise ValueError('La source a changé depuis la préparation de l’import.')
    if shutil.disk_usage(target.parent).free < before.st_size + SPACE_RESERVE:
        raise OSError('Espace disponible insuffisant pour archiver ce log.')
    fd, name = tempfile.mkstemp(prefix='.katalog-archive-', suffix='.partial', dir=target.parent)
    os.close(fd)
    temporary = Path(name)
    try:
        if on_temporary:
            on_temporary(temporary)
        shutil.copyfile(source, temporary)
        if temporary.stat().st_size != before.st_size or analyzer.stat_signature(source.stat()) != analyzer.stat_signature(before) or digest(temporary) != identity:
            raise ValueError('La source est modifiée ou ne correspond plus au SHA du log.')
        with temporary.open('rb') as stream:
            os.fsync(stream.fileno())
        # Publish without replacing a file another process could have created.
        os.link(temporary, target)
        return False
    finally:
        temporary.unlink(missing_ok=True)


def archive_copy_prepared(library, destination, source, identity, signature, origin_context):
    """Archive first, then let the caller parse the published managed file.

    Provenance is captured before the removable source can disappear. A crash
    leaves a recoverable journal and never fabricates an analysis in SQLite.
    """
    root, destination = Path(library).resolve(), Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    journal = root / '.archive-journal.json'
    if journal.exists():
        raise ValueError('Un archivage interrompu nécessite une récupération avant de continuer.')
    identity = identities([identity])[0]
    target = destination / (identity + '.ulg')
    job = {'logID': identity, 'path': str(target), 'state': 'pending', 'error': None,
           'reused': False, 'preparedImport': True, 'originContext': origin_context}
    state = {'archiveVersion': 1, 'createdAt': now(), 'destination': str(destination), 'jobs': [job], 'completed': False}
    atomic_json(journal, state)
    def temporary_created(path):
        job['temporary'] = str(path)
        atomic_json(journal, state)
    try:
        job['reused'] = verified_archive_copy(source, target, identity, signature, temporary_created)
        job.update(state='completed', error=None)
    except (OSError, ValueError) as error:
        job.update(state='failed', error=str(error))
        raise
    finally:
        job.pop('temporary', None)
        state['completed'] = True
        atomic_json(journal, state)
        manifest = destination / ('archive-manifest-' + uuid.uuid4().hex + '.json')
        atomic_json(manifest, state)
        journal.unlink()
    return {'path': str(target), 'reused': job['reused'], 'manifestPath': str(manifest)}


def link(db, identity, path):
    path = Path(path).resolve()
    before = path.stat()
    if not stat.S_ISREG(before.st_mode) or digest(path) != identity or analyzer.stat_signature(path.stat()) != analyzer.stat_signature(before):
        raise ValueError('Le fichier ne correspond pas au SHA attendu ou a changé pendant la vérification.')
    db.execute('INSERT OR IGNORE INTO sources VALUES(?,?)', (identity, str(path)))
    db.execute('INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?)', (str(path), *analyzer.stat_signature(before), identity))
    db.execute('INSERT OR REPLACE INTO source_observations VALUES(?,?,?,?)', (identity, str(path), 'present', now()))


def storage_info(database, library, offset=0, limit=200):
    if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 200:
        raise ValueError('Pagination du stockage invalide.')
    root = Path(library).resolve()
    db = analyzer.open_database(database, read_only=True)
    try:
        log_count = db.execute('SELECT COUNT(*) FROM logs').fetchone()[0]
        cache_count, cache_bytes = db.execute('SELECT COUNT(*),COALESCE(SUM(LENGTH(CAST(summary AS BLOB))),0) FROM flight_details').fetchone()
        revision_count, revision_bytes = 0, 0
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='analysis_revisions'").fetchone():
            revision_count = db.execute('SELECT COUNT(*) FROM analysis_revisions').fetchone()[0]
            counter = db.execute("SELECT value FROM settings WHERE key='analysisRevisionStorageBytes'").fetchone()
            revision_bytes = int(counter[0]) if counter else 0
        source_count = db.execute('SELECT COUNT(*) FROM sources').fetchone()[0]
        rows = db.execute('SELECT sources.log_id,sources.path,files.log_id AS known_log_id,files.size,files.mtime_ns,files.ctime_ns,files.inode FROM sources LEFT JOIN files ON files.path=sources.path ORDER BY sources.log_id,sources.path LIMIT ? OFFSET ?', (limit, offset)).fetchall()
        checked = now()
        sources = []
        for row in rows:
            known = {**dict(row), 'log_id': row['known_log_id']} if row['size'] is not None else None
            availability = analyzer.source_availability(row['path'], row['log_id'], known, checked)
            try:
                size = Path(row['path']).stat().st_size
            except OSError:
                size = None
            sources.append({'logID': row['log_id'], 'path': row['path'], 'sizeBytes': size, 'availability': availability})
        db_bytes = sum(path.stat().st_size for path in root.iterdir() if path.is_file() and not path.is_symlink() and (path.suffix in ('.sqlite', '.sqlite3') or path.name.endswith(('-wal', '-shm'))))
        recoveries = [{'name': path.name, 'sizeBytes': sum(child.stat().st_size for child in path.rglob('*') if child.is_file() and not child.is_symlink())} for path in sorted(root.glob('recovery-*')) if path.is_dir() and not path.is_symlink()]
        return {'storageVersion': 1, 'checkedAt': checked, 'logCount': log_count, 'sourceCount': source_count,
                'detailCacheCount': cache_count, 'detailCacheBytes': cache_bytes, 'databaseBytes': db_bytes,
                'analysisRevisionCount': revision_count, 'analysisRevisionBytes': revision_bytes,
                'analysisRevisionBudgetBytes': analyzer.MAX_REVISION_STORAGE_BYTES,
                'sources': sources, 'nextOffset': offset + len(sources) if offset + len(sources) < source_count else None,
                'recoveries': recoveries, 'originalsDeleted': False}
    finally:
        db.close()


def archive_logs(database, library, destination, log_ids):
    selected = identities(log_ids)
    root, destination = Path(library).resolve(), Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    journal = root / '.archive-journal.json'
    if journal.exists():
        raise ValueError('Un archivage interrompu nécessite une récupération avant de continuer.')
    state = {'archiveVersion': 1, 'createdAt': now(), 'destination': str(destination), 'jobs': [], 'completed': False}
    atomic_json(journal, state)
    db = analyzer.open_database(database)
    try:
        for identity in selected:
            job = {'logID': identity, 'path': str(destination / (identity + '.ulg')), 'state': 'pending', 'error': None, 'reused': False}
            state['jobs'].append(job)
            atomic_json(journal, state)
            temporary = None
            try:
                row = db.execute('SELECT summary FROM logs WHERE id=?', (identity,)).fetchone()
                if not row:
                    raise ValueError('Le log n’est pas dans la bibliothèque.')
                target = Path(job['path'])
                def temporary_created(path):
                    job['temporary'] = str(path)
                    atomic_json(journal, state)
                if target.exists() or target.is_symlink():
                    verified_archive_copy(target, target, identity)
                    link(db, identity, target)
                    job['reused'] = True
                else:
                    original_paths = {row[0] for row in db.execute('SELECT path FROM sources WHERE log_id=? ORDER BY path', (identity,))}
                    original_paths.update(json.loads(row[0]).get('sourcePaths', []))
                    errors = []
                    for candidate in sorted(original_paths):
                        source = Path(candidate)
                        try:
                            job['reused'] = verified_archive_copy(source, target, identity, on_temporary=temporary_created)
                            job.pop('temporary', None)
                            link(db, identity, target)
                            break
                        except (OSError, ValueError) as error:
                            errors.append(str(error))
                            job.pop('temporary', None)
                    else:
                        raise ValueError('Aucune source originale vérifiable disponible : ' + '; '.join(errors[-3:]))
                db.commit()
                job['state'] = 'completed'
            except (OSError, ValueError) as error:
                db.rollback()
                job.update(state='failed', error=str(error))
            finally:
                if temporary:
                    temporary.unlink(missing_ok=True)
                job.pop('temporary', None)
                atomic_json(journal, state)
        state['completed'] = True
        atomic_json(journal, state)
        manifest = destination / ('archive-manifest-' + uuid.uuid4().hex + '.json')
        atomic_json(manifest, state)
        journal.unlink()
        library_repository.initialize(db)
        return {'archiveVersion': 1, 'total': len(selected), 'completed': sum(job['state'] == 'completed' for job in state['jobs']),
                'failed': sum(job['state'] == 'failed' for job in state['jobs']), 'reused': sum(job['reused'] for job in state['jobs']),
                'manifestPath': str(manifest), 'jobs': state['jobs'], 'originalsDeleted': False}
    finally:
        db.close()


def recover_archive(database, library):
    root = Path(library).resolve()
    journal = root / '.archive-journal.json'
    if not journal.exists():
        return {'archiveVersion': 1, 'recovered': False, 'completed': 0, 'interrupted': 0}
    state = json.loads(journal.read_bytes())
    if state.get('archiveVersion') != 1 or not isinstance(state.get('jobs'), list):
        raise ValueError('Journal d’archivage invalide.')
    destination = Path(state.get('destination', '')).resolve()
    db = analyzer.open_database(database)
    try:
        for job in state['jobs']:
            identity = identities([job.get('logID')])[0]
            target = destination / (identity + '.ulg')
            if job.get('path') != str(target):
                raise ValueError('Chemin d’archive différent du journal.')
            try:
                if not db.execute('SELECT 1 FROM logs WHERE id=?', (identity,)).fetchone():
                    if job.get('preparedImport') is not True or not isinstance(job.get('originContext'), dict) or job['originContext'].get('id') != identity:
                        raise ValueError('Log absent de la bibliothèque.')
                    verified_archive_copy(target, target, identity)
                    # The safe copy survives the interruption. It can be
                    # imported later; recovery does not invent an analysis.
                    job.update(state='ready-for-import', error=None)
                else:
                    link(db, identity, target)
                    job.update(state='completed', error=None)
            except (OSError, ValueError) as error:
                job.update(state='interrupted', error=str(error))
            # A partial file is moved to local recovery, never deleted. Only
            # the exact staging name under the declared destination is valid.
            temporary = job.get('temporary')
            if temporary:
                path = Path(temporary)
                if path.parent.resolve() != destination or not path.name.startswith('.katalog-archive-') or path.suffix != '.partial' or path.is_symlink():
                    raise ValueError('Fichier partiel de journal invalide.')
                if path.exists():
                    recovery = root / ('recovery-archive-' + uuid.uuid4().hex)
                    recovery.mkdir()
                    os.replace(path, recovery / path.name)
                job.pop('temporary', None)
        db.commit()
        recovered = root / ('recovery-archive-' + uuid.uuid4().hex)
        recovered.mkdir()
        atomic_json(recovered / 'journal.json', state)
        journal.unlink()
        library_repository.initialize(db)
        return {'archiveVersion': 1, 'recovered': True, 'completed': sum(job['state'] == 'completed' for job in state['jobs']),
                'readyForImport': sum(job['state'] == 'ready-for-import' for job in state['jobs']),
                'interrupted': sum(job['state'] == 'interrupted' for job in state['jobs']), 'recoveryDirectory': str(recovered)}
    finally:
        db.close()


def reassociate(database, folder):
    root = Path(folder).resolve()
    if not root.is_dir():
        raise ValueError('Dossier de réassociation introuvable.')
    db = analyzer.open_database(database)
    matched, unrelated, errors = 0, 0, []
    try:
        for current, dirs, files in os.walk(root, followlinks=False, onerror=lambda error: errors.append(str(error))):
            dirs.sort()
            for filename in sorted(files):
                if Path(filename).suffix.lower() != '.ulg':
                    continue
                path = Path(current) / filename
                if path.is_symlink():
                    continue
                try:
                    before = path.stat()
                    identity = digest(path)
                    if analyzer.stat_signature(path.stat()) != analyzer.stat_signature(before):
                        raise ValueError('Le fichier a changé pendant la recherche.')
                    if not db.execute('SELECT 1 FROM logs WHERE id=?', (identity,)).fetchone():
                        unrelated += 1
                        continue
                    link(db, identity, path)
                    db.commit()
                    matched += 1
                except (OSError, ValueError) as error:
                    db.rollback()
                    errors.append(str(error))
        library_repository.initialize(db)
        return {'reassociateVersion': 1, 'matched': matched, 'unrelated': unrelated, 'errors': errors, 'originalsDeleted': False}
    finally:
        db.close()


def clean_detail_cache(database, library, log_ids):
    selected = identities(log_ids)
    root = Path(library).resolve()
    recovery = root / ('recovery-cache-' + uuid.uuid4().hex)
    recovery.mkdir()
    target = recovery / 'details.sqlite'
    recovered = sqlite3.connect(target)
    db = analyzer.open_database(database)
    try:
        recovered.execute('CREATE TABLE flight_details(log_id TEXT PRIMARY KEY,parser_version TEXT NOT NULL,summary TEXT NOT NULL)')
        recovered.execute('CREATE TABLE analysis_revisions(id TEXT PRIMARY KEY,log_id TEXT NOT NULL,kind TEXT NOT NULL,parser_version TEXT NOT NULL,analysis_sha256 TEXT NOT NULL,created_at TEXT NOT NULL,size_bytes INTEGER NOT NULL,payload BLOB NOT NULL)')
        count, byte_count = 0, 0
        kept = set()
        for identity in selected:
            row = db.execute('SELECT * FROM flight_details WHERE log_id=?', (identity,)).fetchone()
            if row:
                recovered.execute('INSERT INTO flight_details VALUES(?,?,?)', tuple(row))
                count += 1
                byte_count += len(row['summary'].encode('utf-8'))
            for row in db.execute('SELECT * FROM analysis_revisions WHERE log_id=?', (identity,)):
                recovered.execute('INSERT INTO analysis_revisions VALUES(?,?,?,?,?,?,?,?)', tuple(row))
            for kind in ('summary', 'detail'):
                row = db.execute('SELECT id FROM analysis_revisions WHERE log_id=? AND kind=? ORDER BY created_at DESC,id DESC LIMIT 1', (identity, kind)).fetchone()
                if row:
                    kept.add(row[0])
        recovered.commit()
        atomic_json(recovery / 'manifest.json', {'cacheRecoveryVersion': 1, 'createdAt': now(), 'sha256': digest(target), 'cacheCount': count, 'cacheBytes': byte_count})
        db.execute('BEGIN IMMEDIATE')
        db.executemany('DELETE FROM flight_details WHERE log_id=?', ((identity,) for identity in selected))
        removed_revisions = 0
        for identity in selected:
            rows = db.execute('SELECT id FROM analysis_revisions WHERE log_id=?', (identity,)).fetchall()
            for row in rows:
                if row[0] not in kept:
                    db.execute('DELETE FROM analysis_revisions WHERE id=?', (row[0],))
                    removed_revisions += 1
        revision_bytes = db.execute('SELECT COALESCE(SUM(LENGTH(payload)),0) FROM analysis_revisions').fetchone()[0]
        db.execute("INSERT OR REPLACE INTO settings VALUES('analysisRevisionStorageBytes',?)", (str(revision_bytes),))
        db.commit()
        library_repository.initialize(db)
        return {'cacheRecoveryVersion': 1, 'removedCount': count, 'cacheBytes': byte_count, 'removedRevisionCount': removed_revisions,
                'retainedRevisionCount': len(kept), 'recoveryDirectory': str(recovery), 'originalsDeleted': False}
    finally:
        db.close()
        recovered.close()


def restore_detail_cache(database, recovery_directory):
    root = Path(recovery_directory).resolve()
    manifest = json.loads((root / 'manifest.json').read_bytes())
    target = root / 'details.sqlite'
    if manifest.get('cacheRecoveryVersion') != 1 or target.is_symlink() or digest(target) != manifest.get('sha256'):
        raise ValueError('Sauvegarde de cache invalide ou corrompue.')
    source = sqlite3.connect(target.as_uri() + '?mode=ro', uri=True)
    db = analyzer.open_database(database)
    restored, skipped = 0, 0
    try:
        if source.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('Sauvegarde de cache SQLite corrompue.')
        for row in source.execute('SELECT log_id,parser_version,summary FROM flight_details'):
            if not db.execute('SELECT 1 FROM logs WHERE id=?', (row[0],)).fetchone() or db.execute('SELECT 1 FROM flight_details WHERE log_id=?', (row[0],)).fetchone():
                skipped += 1
                continue
            value = json.loads(row[2])
            if value.get('id') != row[0]:
                raise ValueError('Identité incohérente dans le cache restauré.')
            db.execute('INSERT INTO flight_details VALUES(?,?,?)', row)
            restored += 1
        if source.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='analysis_revisions'").fetchone():
            source.row_factory = sqlite3.Row
            for row in source.execute('SELECT * FROM analysis_revisions'):
                analyzer.decoded_revision(row)
                if not db.execute('SELECT 1 FROM logs WHERE id=?', (row['log_id'],)).fetchone() or db.execute('SELECT 1 FROM analysis_revisions WHERE id=?', (row['id'],)).fetchone():
                    continue
                # Retain exact JSON bytes and capture date; validation above
                # verifies decompression bounds, SHA and stable revision ID.
                stored = int(db.execute("SELECT value FROM settings WHERE key='analysisRevisionStorageBytes'").fetchone()[0])
                if stored + len(row['payload']) > analyzer.MAX_REVISION_STORAGE_BYTES:
                    raise analyzer.RevisionBudgetError('Révisions restaurées au-delà du budget de 512 Mio ; état actif conservé.')
                db.execute('INSERT INTO analysis_revisions VALUES(?,?,?,?,?,?,?,?)', tuple(row))
                db.execute("INSERT OR REPLACE INTO settings VALUES('analysisRevisionStorageBytes',?)", (str(stored + len(row['payload'])),))
        db.commit()
        library_repository.initialize(db)
        return {'cacheRecoveryVersion': 1, 'restoredCount': restored, 'skippedCount': skipped}
    finally:
        source.close()
        db.close()
