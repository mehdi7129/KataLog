"""Disposable exact selection cache shared by a single paginated map read.

The app owns the temporary path and removes it on completion/cancellation.
No source-dependent selection is retained and no library file is written here.
"""
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import tempfile

MAX_BYTES = 16 * 1024 * 1024
VERSION = 1


def load(db, path, key):
    if path is None:
        return False
    path = Path(path)
    try:
        if path.is_symlink() or path.stat().st_size > MAX_BYTES:
            return False
        with path.open('r', encoding='utf-8') as stream:
            header = json.loads(stream.readline())
            if header != {'proximityCacheVersion': VERSION, 'key': key}:
                return False
            rows = 0
            for line in stream:
                row = json.loads(line)
                if isinstance(row, dict) and row == {'count': rows}:
                    if stream.read(1):
                        raise ValueError('Trailing cached data')
                    return True
                if not isinstance(row, list) or len(row) != 3 or not isinstance(row[0], str) or not re.fullmatch('[a-f0-9]{64}', row[0]):
                    raise ValueError('Invalid cached match')
                if not all(value is None or (type(value) in (int, float) and math.isfinite(value)) for value in row[1:]):
                    raise ValueError('Invalid cached position')
                db.execute('INSERT INTO kl_proximity_matches VALUES(?,?,?)', row)
                rows += 1
    except (OSError, ValueError, TypeError, sqlite3.IntegrityError):
        pass
    # An interrupted/corrupt cache must not leave a partial selection behind.
    db.execute('DELETE FROM kl_proximity_matches')
    return False


def save(db, path, key):
    if path is None:
        return
    temporary = None
    try:
        path = Path(path)
        if path.is_symlink():
            return
        fd, name = tempfile.mkstemp(prefix='.katalog-proximity-', dir=path.parent)
        temporary = Path(name)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(json.dumps({'proximityCacheVersion': VERSION, 'key': key}) + '\n')
            count = 0
            for row in db.execute('SELECT id,latitude,longitude FROM kl_proximity_matches ORDER BY id'):
                stream.write(json.dumps(tuple(row), separators=(',', ':')) + '\n')
                count += 1
                if stream.tell() > MAX_BYTES - 128:
                    return  # An optimization budget never truncates results.
            stream.write(json.dumps({'count': count}) + '\n')
        os.replace(temporary, path)
    except OSError:
        pass  # Cache availability must not determine query success.
    finally:
        if temporary is not None:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
