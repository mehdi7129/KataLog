"""Coherent local backups and staged restores. Caller owns the writer lease.

The library root and its lease inode are never renamed. Originals are read only;
restored jobs are interrupted, and verified ULogs have one new managed copy.
"""
from __future__ import annotations

from datetime import datetime, timezone
import errno
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import stat
import tempfile
import time
import uuid
import zipfile

from local_files import digest_file as digest, require_local_source, stat_signature

BACKUP_VERSION = 1
CONFIG_NAMES = frozenset(("annotations.json", "views.json", "fleet.json", "settings.json",
                          "gcs-collection.json", "gcs-settings.json", 'import-options.json'))
DB_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,95}\.sqlite(?:3)?")
MAX_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_CONFIG_BYTES = 64 * 1024 * 1024
MAX_BACKUP_BYTES = 512 * 1024 ** 3
MAX_ENTRIES = 200_000
DICTIONARY_NAME = re.compile(r'[a-f0-9]{64}\.json\.xz')
ACTIVE_JOB_STATES = frozenset(("queued", "pending", "waiting", "transferring", "downloading", "verifying", "importing"))
SPACE_RESERVE = 16 * 1024 * 1024


class CorruptLibraryStateError(ValueError):
    """Unreadable stored content, distinct from I/O or unsupported versions."""


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def database_names(root):
    return sorted(path.name for path in root.iterdir() if DB_NAME.fullmatch(path.name) and path.is_file() and not path.is_symlink())


def copy_database(source, destination):
    require_local_source(source)
    reader = sqlite3.connect(Path(source).resolve().as_uri() + "?mode=ro", uri=True, timeout=30)
    writer = sqlite3.connect(destination)
    try:
        reader.backup(writer, pages=256)
        if writer.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise CorruptLibraryStateError("La sauvegarde SQLite n’a pas passé le contrôle d’intégrité.")
        version = writer.execute("PRAGMA user_version").fetchone()[0]
        writer.commit()
        return version
    finally:
        writer.close()
        reader.close()


def source_manifest(database):
    if not database.exists():
        return []
    require_local_source(database)
    db = sqlite3.connect(database)
    try:
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not {"logs", "sources"}.issubset(tables):
            return []
        result = []
        for identity, summary in db.execute("SELECT id,summary FROM logs ORDER BY id"):
            if not re.fullmatch(r"[a-f0-9]{64}", identity):
                continue
            value = json.loads(summary)
            paths = {row[0] for row in db.execute("SELECT path FROM sources WHERE log_id=?", (identity,))}
            paths.update(value.get("sourcePaths", []))
            result.append({"logID": identity, "paths": sorted(paths), "archivePath": None, "state": "referenced"})
        return result
    finally:
        db.close()


def backup(library, destination, include_ulog=False):
    """Capture under caller's quiescence; publish only a fully validated ZIP."""
    root, destination = Path(library).resolve(), Path(destination).resolve()
    if not root.is_dir():
        raise ValueError("Le dossier de bibliothèque est introuvable.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    preflight = backup_preflight(root, destination, include_ulog)
    with tempfile.TemporaryDirectory(prefix="katalog-backup-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        (staging / "state").mkdir()
        versions = {}
        for name in database_names(root):
            versions[name] = copy_database(root / name, staging / "state" / name)
        for name in sorted(CONFIG_NAMES):
            source = root / name
            if source.is_symlink():
                raise ValueError("Un fichier de configuration est un lien symbolique ; sauvegarde refusée.")
            if source.exists():
                if require_local_source(source).st_size > MAX_CONFIG_BYTES:
                    raise ValueError("Configuration trop volumineuse pour une sauvegarde sûre : " + name)
                raw = source.read_bytes()
                value = json.loads(raw)
                if not isinstance(value, dict) or value.get("schemaVersion", 1) != 1:
                    raise ValueError("Version de configuration non prise en charge : " + name)
                (staging / "state" / name).write_bytes(raw)
        dictionaries = root / 'event-dictionaries'
        if dictionaries.is_symlink():
            raise ValueError('Le dossier des dictionnaires ne doit pas être un lien symbolique.')
        if dictionaries.exists():
            from px4_events import _definitions, MAX_ARTIFACT_BYTES
            (staging / 'event-dictionaries').mkdir()
            for source in sorted(dictionaries.iterdir()):
                if source.name.startswith('.dictionary-') and source.name.endswith('.partial'):
                    continue
                if not source.is_file() or source.is_symlink() or not DICTIONARY_NAME.fullmatch(source.name) or require_local_source(source).st_size > MAX_ARTIFACT_BYTES:
                    raise ValueError('Artefact de dictionnaire non sûr ; sauvegarde refusée.')
                with source.open('rb') as handle:
                    payload = handle.read(MAX_ARTIFACT_BYTES + 1)
                if hashlib.sha256(payload).hexdigest() != source.name[:64]:
                    raise ValueError('Empreinte du dictionnaire incorrecte.')
                _definitions(payload)
                (staging / 'event-dictionaries' / source.name).write_bytes(payload)
        sources = source_manifest(staging / "state" / "library.sqlite")
        if include_ulog:
            (staging / "ulogs").mkdir()
            for source in sources:
                copied = False
                for path_string in source["paths"]:
                    path = Path(path_string)
                    target = staging / "ulogs" / (source["logID"] + ".ulg")
                    try:
                        before = require_local_source(path)
                        if not stat.S_ISREG(before.st_mode):
                            continue
                        shutil.copyfile(path, target)
                        after = path.stat()
                        if stat_signature(before) != stat_signature(after):
                            target.unlink(missing_ok=True)
                            continue
                        if digest(target) != source["logID"]:
                            target.unlink(missing_ok=True)
                            continue
                    except OSError as error:
                        target.unlink(missing_ok=True)
                        if error.errno in (errno.ENOSPC, errno.EDQUOT):
                            raise
                        continue
                    source.update(archivePath=target.relative_to(staging).as_posix(), state="archived")
                    copied = True
                    break
                if not copied:
                    source["state"] = "unavailable"
        entries = []
        for path in sorted(staging.rglob("*")):
            if path.is_file():
                entries.append({"name": path.relative_to(staging).as_posix(), "sizeBytes": path.stat().st_size, "sha256": digest(path)})
        manifest = {"backupVersion": BACKUP_VERSION, "createdAt": now(), "includeUlog": bool(include_ulog),
                    "databaseVersions": versions, "files": entries, "sources": sources,
                    "missingSourceCount": sum(source["state"] == "unavailable" for source in sources)}
        atomic_json(staging / "manifest.json", manifest)
        archive_path = staging / "backup.zip"
        with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            archive.write(staging / "manifest.json", "manifest.json")
            for entry in entries:
                archive.write(staging / entry["name"], entry["name"])
        # The captured SQLite files already exist in our private staging area.
        # Reuse their hash-matched bytes for the archive integrity check instead
        # of allocating a second full database copy beside every large backup.
        inspection = inspect_backup(archive_path, _database_files={name: staging / 'state' / name for name in versions})
        with archive_path.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(archive_path, destination)
        return {"backupVersion": BACKUP_VERSION, "path": str(destination), "sha256": digest(destination),
                "sizeBytes": destination.stat().st_size, "logCount": len(sources),
                "archivedLogCount": sum(source["state"] == "archived" for source in sources),
                "missingSourceCount": manifest["missingSourceCount"], "inspection": inspection, 'preflight': preflight}


def backup_preflight(library, destination, include_ulog=False):
    """Conservative peak estimate on the actual staging/publication volume.

    Stat checks estimate availability and size; the subsequent capture/copy
    still verifies SQLite integrity, source stability and exact content SHA.
    A later ENOSPC cannot publish an incomplete backup.
    """
    began = time.perf_counter()
    root, destination = Path(library).resolve(), Path(destination).resolve()
    state_bytes, entries = 0, 0
    for name in database_names(root):
        state_bytes += (root / name).stat().st_size
        wal = root / (name + '-wal')
        if wal.is_file() and not wal.is_symlink():
            state_bytes += wal.stat().st_size
        entries += 1
    for name in CONFIG_NAMES:
        path = root / name
        if path.is_symlink():
            raise ValueError('Configuration liée : préflight de sauvegarde refusé.')
        if path.is_file():
            state_bytes += path.stat().st_size
            entries += 1
    dictionaries = root / 'event-dictionaries'
    if dictionaries.is_symlink():
        raise ValueError('Dossier de dictionnaires lié : préflight refusé.')
    if dictionaries.is_dir():
        for path in dictionaries.iterdir():
            if path.is_file() and not path.is_symlink() and DICTIONARY_NAME.fullmatch(path.name):
                state_bytes += path.stat().st_size
                entries += 1
    sources = source_manifest(root / 'library.sqlite') if include_ulog else []
    source_bytes, missing = 0, 0
    for source in sources:
        sizes = []
        for path in source['paths']:
            try:
                attributes = require_local_source(path)
                if stat.S_ISREG(attributes.st_mode):
                    sizes.append(attributes.st_size)
            except OSError:
                pass
        if sizes:
            # A smaller stale alias must not underestimate a later valid copy.
            source_bytes += max(sizes)
            entries += 1
        else:
            missing += 1
    uncompressed = state_bytes + source_bytes
    required = 2 * uncompressed + (uncompressed + 49) // 50 + 2 * MAX_MANIFEST_BYTES + entries * 1024 + SPACE_RESERVE
    available = shutil.disk_usage(destination.parent).free
    result = {'estimate': 'conservative-peak', 'checkedAt': now(), 'estimatedRequiredBytes': required,
              'availableBytes': available, 'stateBytes': state_bytes, 'sourceBytes': source_bytes,
              'sourceCount': len(sources), 'missingSourceCount': missing, 'sourceValidation': 'stat-only; SHA verified during copy',
              'temporaryVolume': str(destination.parent), 'elapsedSeconds': time.perf_counter() - began}
    if available < required:
        raise ValueError(f'Espace insuffisant pour la sauvegarde : environ {required} octets nécessaires, {available} disponibles. Aucun backup incomplet publié.')
    return result


def safe_entry(name):
    parts = PurePosixPath(name).parts
    if not name or "\\" in name or "\x00" in name or name.startswith("/") or any(part in (".", "..") for part in name.split("/")):
        return False
    if len(parts) != 2 or parts[0] not in ("state", "ulogs", 'event-dictionaries'):
        return False
    if parts[0] == "state":
        return parts[1] in CONFIG_NAMES or DB_NAME.fullmatch(parts[1]) is not None
    if parts[0] == 'event-dictionaries':
        return DICTIONARY_NAME.fullmatch(parts[1]) is not None
    return re.fullmatch(r"[a-f0-9]{64}\.ulg", parts[1]) is not None


def validated_manifest(archive):
    infos = archive.infolist()
    names = [info.filename for info in infos]
    if len(infos) > MAX_ENTRIES or len(names) != len(set(names)) or names.count("manifest.json") != 1:
        raise ValueError("Archive de sauvegarde invalide : doublons, manifeste absent ou trop de fichiers.")
    if sum(info.file_size for info in infos) > MAX_BACKUP_BYTES:
        raise ValueError("La taille décompressée de la sauvegarde dépasse la limite.")
    for info in infos:
        mode = info.external_attr >> 16
        if info.flag_bits & 1 or stat.S_ISLNK(mode) or info.is_dir() or (info.filename != "manifest.json" and not safe_entry(info.filename)):
            raise ValueError("Archive non sûre : chemin, chiffrement ou lien non pris en charge.")
    if archive.getinfo("manifest.json").file_size > MAX_MANIFEST_BYTES:
        raise ValueError("Manifeste de sauvegarde trop volumineux.")
    manifest = json.loads(archive.read("manifest.json"))
    if not isinstance(manifest, dict) or manifest.get("backupVersion") != BACKUP_VERSION:
        raise ValueError("Version de sauvegarde non prise en charge.")
    entries = manifest.get("files")
    if not isinstance(entries, list) or len(entries) != len(infos) - 1:
        raise ValueError("Le manifeste ne correspond pas aux fichiers de l’archive.")
    indexed = {}
    for entry in entries:
        if not isinstance(entry, dict) or not safe_entry(entry.get("name", "")) or entry["name"] in indexed:
            raise ValueError("Entrée de manifeste invalide.")
        size = entry.get("sizeBytes")
        if not isinstance(size, int) or isinstance(size, bool) or size < 0 or not re.fullmatch(r"[a-f0-9]{64}", str(entry.get("sha256", ""))):
            raise ValueError("Taille ou empreinte invalide dans le manifeste.")
        if entry['name'].startswith('event-dictionaries/') and (size > 4 * 1024 * 1024 or entry['sha256'] != PurePosixPath(entry['name']).name[:64]):
            raise ValueError('Dictionnaire sauvegardé hors budget ou incohérent.')
        indexed[entry["name"]] = entry
    if set(indexed) != set(names) - {"manifest.json"}:
        raise ValueError("L’archive contient des fichiers non déclarés.")
    for name, entry in indexed.items():
        if archive.getinfo(name).file_size != entry["sizeBytes"]:
            raise ValueError("Taille de fichier différente du manifeste.")
        checksum, count = hashlib.sha256(), 0
        with archive.open(name) as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                count += len(block)
                if count > entry["sizeBytes"]:
                    raise ValueError("Taille décompressée supérieure au manifeste.")
                checksum.update(block)
        if count != entry["sizeBytes"] or checksum.hexdigest() != entry["sha256"]:
            raise ValueError("Sauvegarde corrompue : empreinte de fichier incorrecte.")
        if name.startswith('event-dictionaries/'):
            from px4_events import _definitions
            payload = archive.read(name)
            if not payload.startswith(b'\xfd7zXZ\x00'):
                raise ValueError('Dictionnaire sauvegardé non compressé XZ.')
            _definitions(payload)
    sources = manifest.get("sources", [])
    if not isinstance(sources, list):
        raise ValueError("Liste des provenances de sauvegarde invalide.")
    for source in sources:
        if not isinstance(source, dict) or not re.fullmatch(r"[a-f0-9]{64}", str(source.get("logID", ""))):
            raise ValueError("Provenance ULog invalide dans le manifeste.")
        archived = source.get("archivePath")
        if archived is not None and (archived != "ulogs/" + source["logID"] + ".ulg" or archived not in indexed or indexed[archived]["sha256"] != source["logID"]):
            raise ValueError("Archive ULog incohérente avec son identifiant de contenu.")
        if not isinstance(source.get("paths"), list) or not all(isinstance(path, str) for path in source["paths"]):
            raise ValueError("Chemins de provenance invalides dans le manifeste.")
    return manifest


def inspect_backup(path, *, _database_files=None):
    require_local_source(path)
    with zipfile.ZipFile(path) as archive:
        manifest = validated_manifest(archive)
        versions = manifest.get("databaseVersions", {})
        if not isinstance(versions, dict):
            raise ValueError("Versions SQLite invalides dans le manifeste.")
        with tempfile.TemporaryDirectory(prefix="katalog-inspect-backup-") as temporary:
            for entry in manifest["files"]:
                name = entry["name"]
                filename = PurePosixPath(name).name
                if name.startswith("state/") and DB_NAME.fullmatch(filename):
                    captured = (_database_files or {}).get(filename)
                    if captured is not None and Path(captured).is_file() and not Path(captured).is_symlink() and digest(captured) == entry['sha256']:
                        target = Path(captured)
                    else:
                        target = Path(temporary) / filename
                        with archive.open(name) as source, target.open("xb") as destination:
                            shutil.copyfileobj(source, destination, length=1024 * 1024)
                    db = sqlite3.connect(target.as_uri() + "?mode=ro", uri=True)
                    try:
                        version = db.execute("PRAGMA user_version").fetchone()[0]
                        if version not in (0, 1) or versions.get(filename) != version:
                            raise ValueError("Version SQLite de sauvegarde non prise en charge ou incohérente.")
                        if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                            raise ValueError("Sauvegarde SQLite corrompue.")
                        if filename == 'library.sqlite':
                            import analyzer
                            analyzer.validate_analysis_revisions(db)
                    finally:
                        db.close()
                elif name.startswith("state/") and filename in CONFIG_NAMES:
                    if entry["sizeBytes"] > MAX_CONFIG_BYTES:
                        raise ValueError("Configuration de sauvegarde trop volumineuse.")
                    value = json.loads(archive.read(name))
                    if not isinstance(value, dict) or value.get("schemaVersion", 1) != 1:
                        raise ValueError("Version de configuration sauvegardée non prise en charge.")
                elif name.startswith('event-dictionaries/'):
                    from px4_events import _definitions, MAX_ARTIFACT_BYTES
                    if entry['sizeBytes'] > MAX_ARTIFACT_BYTES or entry['sha256'] != filename[:64]:
                        raise ValueError('Dictionnaire sauvegardé hors budget ou incohérent.')
                    payload = archive.read(name)
                    if not payload.startswith(b'\xfd7zXZ\x00'):
                        raise ValueError('Dictionnaire sauvegardé non compressé XZ.')
                    _definitions(payload)
    return {"backupVersion": manifest["backupVersion"], "createdAt": manifest.get("createdAt", ""),
            "databaseVersions": manifest.get("databaseVersions", {}), "fileCount": len(manifest["files"]),
            "logCount": len(manifest.get("sources", [])), "includeUlog": bool(manifest.get("includeUlog")),
            "missingSourceCount": manifest.get("missingSourceCount", 0),
            "uncompressedBytes": sum(entry["sizeBytes"] for entry in manifest["files"])}


def prepare_restored_state(staging, manifest, root, archive_directory):
    for config in (staging / "state").glob("*.json"):
        value = json.loads(config.read_bytes())
        if not isinstance(value, dict) or value.get("schemaVersion", 1) != 1:
            raise ValueError("Version de configuration restaurée non prise en charge.")
        if config.name in ("gcs-collection.json", "gcs-settings.json"):
            value["reconnect"] = False
            value["queuePaused"] = True
            for job in value.get("queue", []):
                if job.get("state") in ACTIVE_JOB_STATES:
                    job.update(state="interrupted", error="Restauration : attendre un nouvel inventaire avant reprise.")
            atomic_json(config, value)
    for database in (staging / "state").iterdir():
        if not DB_NAME.fullmatch(database.name):
            continue
        db = sqlite3.connect(database)
        try:
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if version not in (0, 1) or manifest.get("databaseVersions", {}).get(database.name) != version:
                raise ValueError("Version SQLite restaurée non prise en charge ou incohérente.")
            if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ValueError("La base restaurée est corrompue.")
            if database.name == 'library.sqlite':
                import analyzer
                analyzer.validate_analysis_revisions(db)
            tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if database.name == "library.sqlite" and {"logs", "sources", "files"}.issubset(tables):
                for source in manifest.get("sources", []):
                    if source.get("archivePath"):
                        staged = staging / source["archivePath"]
                        final = root / archive_directory / staged.name
                        attributes = staged.stat()
                        db.execute("INSERT OR IGNORE INTO sources(log_id,path) VALUES(?,?)", (source["logID"], str(final)))
                        db.execute("INSERT OR REPLACE INTO files(path,size,mtime_ns,ctime_ns,inode,log_id) VALUES(?,?,?,?,?,?)",
                                   (str(final), attributes.st_size, attributes.st_mtime_ns, attributes.st_ctime_ns, attributes.st_ino, source["logID"]))
            for table in ("jobs", "gcs_jobs", "collection_jobs", "transfers"):
                if table in tables and "state" in {row[1] for row in db.execute('PRAGMA table_info("' + table + '")')}:
                    states = sorted(ACTIVE_JOB_STATES)
                    db.execute('UPDATE "' + table + '" SET state=? WHERE state IN (' + ','.join('?' for _ in states) + ')', ("interrupted", *states))
            db.commit()
            if database.name == 'library.sqlite' and {'logs', 'sources', 'flight_details'}.issubset(tables):
                import library_repository
                library_repository.initialize(db)
            db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        finally:
            db.close()


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_restore_journal(journal, record):
    atomic_json(journal, record)
    sync_directory(journal.parent)


def move_restore_entry(source, destination):
    """Order the file move durably before publishing the next journal phase."""
    os.replace(source, destination)
    sync_directory(source.parent)
    if destination.parent != source.parent:
        sync_directory(destination.parent)


def is_stored_content_corruption(error):
    if isinstance(error, (CorruptLibraryStateError, json.JSONDecodeError, UnicodeDecodeError)):
        return True
    return isinstance(error, sqlite3.DatabaseError) and (
        getattr(error, 'sqlite_errorcode', -1) & 0xff) in (sqlite3.SQLITE_CORRUPT, sqlite3.SQLITE_NOTADB)


def capture_state_files(root, destination_root, managed, *, reserve_for_backup=False):
    """Copy and verify managed bytes without opening any active SQLite file."""
    files = []
    for name in sorted(managed):
        if name == 'event-dictionaries':
            directory = root / name
            if directory.is_symlink() or not directory.is_dir():
                raise ValueError('Dossier de dictionnaires non sûr ; conservation refusée.')
            candidates = sorted(directory.iterdir())
        else:
            candidates = [root / (name + suffix) for suffix in
                          (('', '-wal', '-shm', '-journal') if DB_NAME.fullmatch(name) else ('',))]
        for path in candidates:
            if path.is_symlink():
                raise ValueError('Fichier lié symboliquement ; conservation brute refusée.')
            if not path.exists():
                continue
            attributes = path.stat()
            if not stat.S_ISREG(attributes.st_mode):
                raise ValueError('Fichier non régulier ; conservation brute refusée.')
            files.append((path, attributes))
    total = sum(value.st_size for _, value in files)
    required = total + SPACE_RESERVE
    if reserve_for_backup:
        # One raw working copy plus backup's database capture and ZIP, including
        # a conservative compression overhead, manifest and entry metadata.
        required += 2 * total + (total + 49) // 50 + 2 * MAX_MANIFEST_BYTES + len(files) * 1024
    if len(files) > MAX_ENTRIES or total > MAX_BACKUP_BYTES or shutil.disk_usage(destination_root.parent).free < required:
        raise ValueError('Espace ou budget insuffisant pour conserver les fichiers bruts.')
    destination_root.mkdir(exist_ok=True)
    entries = []

    def signature(attributes):
        return attributes.st_dev, attributes.st_ino, attributes.st_size, attributes.st_mtime_ns, attributes.st_ctime_ns

    for source, before in files:
        name = source.relative_to(root).as_posix()
        destination = destination_root / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        with source.open('rb') as reader, destination.open('xb') as writer:
            if signature(os.fstat(reader.fileno())) != signature(before):
                raise ValueError('Un fichier actif a changé avant sa conservation : ' + name)
            shutil.copyfileobj(reader, writer, length=1024 * 1024)
            writer.flush()
            os.fsync(writer.fileno())
        checksum = digest(destination)
        if checksum != digest(source) or signature(source.stat()) != signature(before):
            raise ValueError('La conservation brute ne correspond pas aux fichiers actifs : ' + name)
        entries.append({'name': name, 'sizeBytes': before.st_size, 'sha256': checksum,
                        'mtimeNs': before.st_mtime_ns, 'mode': stat.S_IMODE(before.st_mode)})
        sync_directory(destination.parent)
    sync_directory(destination_root)
    return entries


def preserve_raw_state(root, recovery, managed, validation_error):
    """Preserve unreadable bytes, without claiming a coherent SQLite backup."""
    entries = capture_state_files(root, recovery / 'raw-files', managed)
    manifest = {'preservationVersion': 1, 'kind': 'raw-unvalidated-state', 'createdAt': now(),
                'validationError': {'type': type(validation_error).__name__, 'message': str(validation_error),
                                    'sqliteCode': getattr(validation_error, 'sqlite_errorcode', None)},
                'files': entries}
    atomic_json(recovery / 'raw-manifest.json', manifest)
    sync_directory(recovery)


def restore(archive_path, library):
    """Validate, stage and swap managed files; preserve the root lease inode."""
    root = Path(library).resolve()
    root.mkdir(parents=True, exist_ok=True)
    if root.is_symlink():
        raise ValueError("Le dossier de bibliothèque ne doit pas être un lien symbolique.")
    journal = root / ".restore-journal.json"
    if journal.is_symlink():
        raise ValueError('Journal de restauration lié symboliquement ; opération refusée.')
    if journal.exists():
        raise ValueError("Une restauration interrompue nécessite une récupération avant de continuer.")
    require_local_source(archive_path)
    token = uuid.uuid4().hex
    recovery = root / ("recovery-" + token)
    archive_directory = "restored-ulogs-" + token
    with tempfile.TemporaryDirectory(prefix=".restore-staging-", dir=root) as temporary:
        staging = Path(temporary)
        with zipfile.ZipFile(archive_path) as archive:
            manifest = validated_manifest(archive)
            for entry in manifest["files"]:
                target = staging / entry["name"]
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry["name"]) as source, target.open("xb") as destination:
                    shutil.copyfileobj(source, destination, length=1024 * 1024)
        (staging / "state").mkdir(exist_ok=True)
        prepare_restored_state(staging, manifest, root, archive_directory)
        managed = set(database_names(root)) | {name for name in CONFIG_NAMES if (root / name).exists()}
        if (root / 'event-dictionaries').exists():
            managed.add('event-dictionaries')
        incoming = {path.name for path in (staging / "state").iterdir() if path.is_file()}
        for name in set(managed) | incoming:
            if (root / name).is_symlink():
                raise ValueError("Fichier de bibliothèque lié symboliquement ; restauration refusée.")
        recovery.mkdir()
        # Even a read-only SQLite connection can rewrite a corrupt SHM file.
        # Validate the pre-restore backup on an owned copy, never active bytes.
        with tempfile.TemporaryDirectory(prefix='.before-capture-', dir=recovery) as temporary_before:
            captured = Path(temporary_before)
            capture_state_files(root, captured, managed, reserve_for_backup=True)
            try:
                # A crashed DELETE-mode writer needs rollback before a coherent
                # read. Only our disposable copy may be opened for that write.
                for name in database_names(captured):
                    if (captured / (name + '-journal')).exists():
                        connection = sqlite3.connect(captured / name)
                        try:
                            connection.execute('SELECT name FROM sqlite_master LIMIT 1').fetchall()
                        finally:
                            connection.close()
                backup(captured, recovery / "before.zip", include_ulog=False)
            except (ValueError, sqlite3.DatabaseError) as error:
                if not is_stored_content_corruption(error):
                    raise
                preserve_raw_state(root, recovery, managed, error)
        original = recovery / "original-files"
        original.mkdir()
        sync_directory(recovery)
        moved, installed = [], []
        record = {"restoreVersion": 1, "phase": "prepared", "recoveryDirectory": recovery.name,
                  "archiveDirectory": archive_directory, "moved": moved, "installed": installed}
        write_restore_journal(journal, record)
        try:
            for name in sorted(managed):
                for suffix in ("", "-wal", "-shm", "-journal") if DB_NAME.fullmatch(name) else ("",):
                    filename = name + suffix
                    if (root / filename).exists():
                        moved.append(filename)
                        write_restore_journal(journal, record)
                        move_restore_entry(root / filename, original / filename)
            for name in sorted(incoming):
                installed.append(name)
                write_restore_journal(journal, record)
                move_restore_entry(staging / "state" / name, root / name)
            if (staging / 'event-dictionaries').exists():
                installed.append('event-dictionaries')
                write_restore_journal(journal, record)
                move_restore_entry(staging / 'event-dictionaries', root / 'event-dictionaries')
            if (staging / "ulogs").exists():
                installed.append(archive_directory)
                write_restore_journal(journal, record)
                move_restore_entry(staging / "ulogs", root / archive_directory)
            record["phase"] = "complete"
            write_restore_journal(journal, record)
            recover_restore(root)
        except BaseException:
            # Read the durable phase, including a possibly published commit.
            # The same recovery is safe if this rollback is itself interrupted.
            recover_restore(root)
            raise
        return {"restoreVersion": 1, "recoveryDirectory": str(recovery),
                "fileCount": len(incoming), "logCount": len(manifest.get("sources", [])),
                "archivedLogCount": sum(bool(source.get("archivePath")) for source in manifest.get("sources", [])),
                "missingSourceCount": manifest.get("missingSourceCount", 0), "jobsRestoredActive": False}


def recover_restore(library):
    """Recover an interrupted file swap under the caller's writer lease."""
    root = Path(library).resolve()
    journal = root / ".restore-journal.json"
    if journal.is_symlink():
        raise ValueError('Journal de restauration lié symboliquement ; opération refusée.')
    if not journal.exists():
        return {"restoreVersion": 1, "recovered": False}
    require_local_source(journal)
    record = json.loads(journal.read_bytes())
    if record.get("restoreVersion") != 1 or not re.fullmatch(r"recovery-[a-f0-9]{32}", record.get("recoveryDirectory", "")):
        raise ValueError("Journal de restauration invalide ; récupération automatique refusée.")
    recovery = root / record["recoveryDirectory"]
    if recovery.is_symlink() or not recovery.is_dir():
        raise ValueError("Dossier de récupération invalide.")
    archive_directory = record.get("archiveDirectory", "")
    if not re.fullmatch(r"restored-ulogs-[a-f0-9]{32}", archive_directory):
        raise ValueError("Dossier d’archives du journal invalide.")
    if record.get('phase') not in ('prepared', 'recovering-entrants', 'recovering-originals', 'complete'):
        raise ValueError('Phase du journal de restauration inconnue.')
    for names in (record.get("moved", []), record.get("installed", [])):
        if not isinstance(names, list):
            raise ValueError("Liste de fichiers du journal invalide.")
        for name in names:
            database = re.sub(r"-(?:wal|shm|journal)$", "", name) if isinstance(name, str) else ""
            if not isinstance(name, str) or (name not in (archive_directory, 'event-dictionaries') and name not in CONFIG_NAMES and not DB_NAME.fullmatch(database)):
                raise ValueError("Chemin de récupération non autorisé.")
        if len(names) != len(set(names)):
            raise ValueError('Fichier dupliqué dans le journal de restauration.')
    original = recovery / 'original-files'
    leftovers = recovery / 'interrupted-restored-files'
    for directory in (original, leftovers):
        if directory.is_symlink() or (directory.exists() and not directory.is_dir()):
            raise ValueError('Dossier de récupération invalide.')
    if not original.is_dir():
        raise ValueError('Les fichiers originaux de la restauration sont introuvables.')
    moved, installed = record.get('moved', []), record.get('installed', [])
    for name in set(moved + installed):
        if any((directory / name).is_symlink() for directory in (root, original, leftovers)):
            raise ValueError('Fichier de récupération lié symboliquement ; récupération refusée.')
    if record['phase'] != 'complete':
        for name in moved:
            if not (original / name).exists() and not (root / name).exists():
                raise ValueError('Fichier original manquant ; journal conservé : ' + name)
        if record['phase'] == 'prepared':
            record['phase'] = 'recovering-entrants'
            write_restore_journal(journal, record)
        if record['phase'] == 'recovering-entrants':
            leftovers.mkdir(exist_ok=True)
            sync_directory(recovery)
            for name in reversed(installed):
                target = root / name
                # A legacy v1 recovery may already have returned an original,
                # or the original move was only an intent when interrupted.
                if name in moved and not (original / name).exists():
                    continue
                if target.exists():
                    if (leftovers / name).exists():
                        raise ValueError('Deux fichiers à préserver ; journal conservé : ' + name)
                    move_restore_entry(target, leftovers / name)
            record['phase'] = 'recovering-originals'
            write_restore_journal(journal, record)
        for name in reversed(moved):
            source = original / name
            target = root / name
            if source.exists():
                if target.exists():
                    raise ValueError('Un fichier empêche la remise de l’original : ' + name)
                move_restore_entry(source, target)
        if any(not (root / name).exists() or (original / name).exists() for name in moved):
            raise ValueError('Récupération incomplète ; journal conservé.')
        if any((root / name).exists() for name in set(installed) - set(moved)):
            raise ValueError('Fichiers entrants encore actifs ; journal conservé.')
    elif any(not (root / name).exists() for name in installed) or any(not (original / name).exists() for name in moved):
        raise ValueError('Restauration complète non vérifiable ; journal conservé.')
    journal.unlink()
    sync_directory(root)
    return {"restoreVersion": 1, "recovered": True, "recoveryDirectory": str(recovery),
            "completedRestore": record.get("phase") == "complete"}
