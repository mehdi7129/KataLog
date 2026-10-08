"""Local-only source reads shared by analysis and storage. No cloud hydration."""
import hashlib
from pathlib import Path
import stat as stat_module
import sys

CLOUD_SOURCE_DETAIL = ("Fichier présent dans le cloud, mais non téléchargé sur ce Mac. "
                       "Dans le Finder, utilisez « Télécharger » sur le fichier ou son dossier. "
                       "Le résumé et les analyses en cache restent disponibles.")


class CloudSourceUnavailableError(OSError):
    """Reading a File Provider placeholder could block while macOS hydrates it."""


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
