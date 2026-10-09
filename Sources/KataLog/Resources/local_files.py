"""Local file helpers shared by analysis and storage. No cloud hydration."""
import hashlib
import json
import os
from pathlib import Path
import stat as stat_module
import sys
import tempfile

CLOUD_SOURCE_DETAIL = ("Fichier présent dans le cloud, mais non téléchargé sur ce Mac. "
                       "Dans le Finder, utilisez « Télécharger » sur le fichier ou son dossier. "
                       "Le résumé et les analyses en cache restent disponibles.")


class CloudSourceUnavailableError(OSError):
    """Reading a File Provider placeholder could block while macOS hydrates it."""


def atomic_json(path, value, *, separators, prefix):
    """Publish complete JSON with the caller's existing format and staging name."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=prefix, dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, allow_nan=False, separators=separators)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def require_local_source(path, metadata=None):
    metadata = metadata if metadata is not None else Path(path).stat()
    # Some bundled Python versions omit the Darwin constant even though stat
    # still exposes st_flags. Do not interpret this bit on other platforms.
    dataless = getattr(stat_module, 'UF_DATALESS', 0x40000000 if sys.platform == 'darwin' else 0)
    if getattr(metadata, 'st_flags', 0) & dataless:
        raise CloudSourceUnavailableError(CLOUD_SOURCE_DETAIL)
    return metadata


def digest_file(path):
    require_local_source(path)
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stat_signature(stat):
    return (stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns, stat.st_ino)
