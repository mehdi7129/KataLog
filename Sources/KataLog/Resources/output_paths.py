"""Preflight result files without creating or migrating the library."""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unicodedata
import zipfile

from library_storage import CONFIG_NAMES, DB_NAME, MAX_MANIFEST_BYTES
from local_files import require_local_source

CONTROL_NAMES = CONFIG_NAMES | frozenset(('.library-writer.lock', '.restore-journal.json', '.archive-journal.json'))


def backup_source_paths(path):
    """Reserve incoming provenance; restore still fully validates the archive."""
    require_local_source(path)
    with zipfile.ZipFile(path) as archive:
        if archive.getinfo('manifest.json').file_size > MAX_MANIFEST_BYTES:
            raise ValueError('Manifeste de sauvegarde trop volumineux.')
        manifest = json.loads(archive.read('manifest.json'))
    sources = manifest.get('sources', []) if isinstance(manifest, dict) else None
    if not isinstance(sources, list):
        raise ValueError('Provenances de sauvegarde invalides.')
    for source in sources:
        paths = source.get('paths') if isinstance(source, dict) else None
        if not isinstance(paths, list) or not all(isinstance(path, str) for path in paths):
            raise ValueError('Chemins de provenance invalides dans la sauvegarde.')
        yield from paths


def path_identity(path):
    resolved = path.resolve()
    # Reserve case/normalization variants even before the target exists. This
    # is deliberately conservative on case-sensitive volumes too.
    key = unicodedata.normalize('NFD', str(resolved)).casefold()
    try:
        metadata = path.stat()
    except FileNotFoundError:
        return key, None, path.is_symlink()
    return key, (metadata.st_dev, metadata.st_ino), True


def source_paths(database, outputs, inspect_aliases, use_copy=False):
    for root in (database.parent.resolve(), database.resolve().parent):
        journal = root / '.restore-journal.json'
        if journal.exists() or journal.is_symlink():
            if inspect_aliases:
                raise ValueError('Récupération en attente : choisissez un nouveau chemin de sortie pour préserver les sources.')
            return  # Recovery must finish before any active SQLite connection.
    if not database.is_file():
        return
    if use_copy and not inspect_aliases:
        return  # Storage recovery with a new result never opens active SQLite.
    with contextlib.ExitStack() as cleanup:
        if use_copy:
            # Even mode=ro can rebuild a corrupt SHM. Inspect only copies before
            # storage has captured the exact active files for recovery.
            copied = Path(cleanup.enter_context(tempfile.TemporaryDirectory(prefix='katalog-output-check-'))) / database.name
            for suffix in ('', '-wal', '-shm', '-journal'):
                source = Path(str(database) + suffix)
                if source.exists():
                    require_local_source(source)
                    shutil.copyfile(source, Path(str(copied) + suffix))
            database = copied
        db = None
        try:
            require_local_source(database)
            db = sqlite3.connect(database.resolve().as_uri() + '?mode=ro', uri=True)
            if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sources'").fetchone():
                if inspect_aliases:
                    rows = db.execute('SELECT DISTINCT path FROM sources')
                else:
                    # A new result cannot overwrite an existing source. Keep
                    # missing recorded paths reserved via the path index, with
                    # no traversal of originals on every paginated UI query.
                    candidates = sorted({str(path.absolute()) for path in outputs} | {str(path.resolve()) for path in outputs})
                    rows = db.execute('SELECT DISTINCT path FROM sources WHERE path IN (' + ','.join('?' for _ in candidates) + ')', candidates)
                for row in rows:
                    yield Path(row[0])
        except sqlite3.DatabaseError as error:
            if inspect_aliases:
                raise ValueError('La bibliothèque ne permet pas de vérifier cette sortie existante ; choisissez un nouveau chemin de sortie.') from error
        finally:
            if db is not None:
                db.close()


def validate_outputs(outputs, database=None, library=None, folder=None, inputs=(), copy_sources=False):
    """Reject collisions before work starts; ordinary JSON exports stay legal."""
    outputs = [Path(path) for path in outputs if path is not None]
    if not outputs:
        return
    identities = [path_identity(path) for path in outputs]

    def matches(left, right):
        return left[0] == right[0] or (left[1] is not None and left[1] == right[1])

    for index, identity in enumerate(identities):
        if any(matches(identity, other) for other in identities[:index]):
            raise ValueError('Les chemins de sortie doivent être distincts.')

    protected = [Path(path) for path in inputs if path is not None]
    protected.extend((Path(__file__), Path(__file__).with_name('analyzer.py'),
                      Path(__file__).with_name('analyzer_cli.py'), Path(__file__).with_name('analysis_revisions.py')))
    database = Path(database) if database is not None else None
    roots = {database.parent, database.resolve().parent} if database is not None else set()
    if library is not None:
        roots.add(Path(library))
    databases = [database] if database is not None else []
    for root in roots:
        protected.extend(root / name for name in CONTROL_NAMES)
        databases.extend((root / 'library.sqlite', root / 'gcs-queue.sqlite'))
        if root.is_dir():
            databases.extend(path for path in root.iterdir() if DB_NAME.fullmatch(path.name))
        dictionaries = path_identity(root / 'event-dictionaries')[0]
        if any(target[0] == dictionaries or target[0].startswith(dictionaries + os.sep) for target in identities):
            raise ValueError('Le chemin de sortie empiète sur les dictionnaires de la bibliothèque.')
    for path in databases:
        protected.extend(Path(str(path) + suffix) for suffix in ('', '-wal', '-shm', '-journal'))
    if folder is not None:
        source = Path(folder)
        protected.append(source)
        if source.is_dir():
            for current, _, names in os.walk(source, followlinks=False):
                protected.extend(Path(current) / name for name in names if Path(name).suffix.lower() == '.ulg')

    def reject_collisions(paths):
        for path in paths:
            identity = path_identity(path)
            if any(matches(target, identity) for target in identities):
                raise ValueError(f'Le chemin de sortie remplacerait une donnée protégée : {path}')

    reject_collisions(protected)
    # Other SQLite files (notably the independent GCS queue) are protected
    # destinations, but their state must not gate queries/imports of this library.
    source_databases = (database,) if database is not None else {root / 'library.sqlite' for root in roots}
    for path in source_databases:
        reject_collisions(source_paths(path, outputs, inspect_aliases=any(identity[2] for identity in identities), use_copy=copy_sources))
