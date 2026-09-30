"""Persistent source-folder visibility; original paths and analyses stay intact.

Mutations require the application's library writer lease, like scan/archive.
SQLite additionally serializes each folder update in an immediate transaction.
"""
from __future__ import annotations

from datetime import datetime, timezone
import os
from pathlib import Path
import stat


def has_retirements(db):
    return bool(db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='source_folder_retirements'").fetchone())


def active_folders(db):
    clause = ' WHERE NOT EXISTS(SELECT 1 FROM source_folder_retirements r WHERE r.path=folders.path)' if has_retirements(db) else ''
    return [row[0] for row in db.execute('SELECT path FROM folders' + clause + ' ORDER BY path')]


def folder_state(path):
    path = Path(path)
    try:
        if not stat.S_ISDIR(path.stat().st_mode):
            return 'missing'
        # stat alone does not establish permission to list an import folder.
        with os.scandir(path):
            pass
        return 'present'
    except FileNotFoundError:
        if len(path.parts) > 2 and path.parts[:2] == ('/', 'Volumes'):
            volume = Path('/Volumes') / path.parts[2]
            try:
                if not os.path.ismount(volume):
                    return 'offline'
            except OSError:
                return 'unknown'
        return 'missing'
    except PermissionError:
        return 'inaccessible'
    except OSError:
        return 'unknown'


def counts(db):
    total = db.execute('SELECT COUNT(*) FROM folders').fetchone()[0]
    removed = (db.execute('SELECT COUNT(*) FROM folders f JOIN source_folder_retirements r ON r.path=f.path').fetchone()[0]
               if has_retirements(db) else 0)
    return {'activeCount': total - removed, 'removedCount': removed}


def source_folders(database, offset=0, limit=200, include_removed=False):
    if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 200 or type(include_removed) is not bool:
        raise ValueError('Pagination des sources invalide.')
    import analyzer
    db = analyzer.open_database(database, read_only=True)
    try:
        db.execute('BEGIN')
        result = counts(db)
        retired = has_retirements(db)
        source = ('SELECT f.path,(r.path IS NOT NULL) AS removed FROM folders f LEFT JOIN source_folder_retirements r ON r.path=f.path'
                  if retired else 'SELECT path,0 AS removed FROM folders')
        source = 'SELECT * FROM (' + source + ')'
        if not include_removed:
            source += ' WHERE removed=0'
        total = result['activeCount'] + result['removedCount'] if include_removed else result['activeCount']
        folders = []
        for row in db.execute(source + ' ORDER BY path LIMIT ? OFFSET ?', (limit, offset)):
            # The boundary excludes similarly named siblings. DISTINCT avoids
            # counting a log twice when it has multiple copies below this root.
            prefix = row[0].rstrip('/') + '/'
            # Every prefix ends with ASCII '/'. Its exclusive successor is
            # therefore the same root followed by '0', even for Unicode roots
            # or '/'. A covering path/log index bounds each folder count.
            upper = prefix[:-1] + '0'
            log_count = db.execute('SELECT COUNT(DISTINCT log_id) FROM sources WHERE path>=? AND path<?', (prefix, upper)).fetchone()[0]
            folders.append({'path': row[0], 'logCount': log_count, 'state': folder_state(row[0]), 'removed': bool(row[1])})
        result.update(total=total, nextOffset=offset + len(folders) if offset + len(folders) < total else None, folders=folders)
        return result
    finally:
        db.close()


def set_removed(database, folder, removed):
    import analyzer
    path = str(Path(folder).expanduser().resolve())
    db = analyzer.open_database(database)
    try:
        db.execute('BEGIN IMMEDIATE')
        if not db.execute('SELECT 1 FROM folders WHERE path=?', (path,)).fetchone():
            raise ValueError('Ce dossier n’est pas une source enregistrée de la bibliothèque.')
        if removed:
            changed = db.execute('INSERT OR IGNORE INTO source_folder_retirements VALUES(?,?)',
                                 (path, datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'))).rowcount
        else:
            changed = db.execute('DELETE FROM source_folder_retirements WHERE path=?', (path,)).rowcount
        if changed and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='kl_meta'").fetchone():
            db.execute("UPDATE kl_meta SET value=CAST(value AS INTEGER)+1 WHERE key='revision'")
        result = {'path': path, 'removed': removed, **counts(db), 'logsDeleted': False, 'originalsDeleted': False}
        db.commit()
        return result
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()
