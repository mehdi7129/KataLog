#!/usr/bin/env python3
"""Reuse verified CPython bytes; prepare invalid caches before publication."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile
import uuid


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def entries(archive):
    result = {}
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'python':
            raise ValueError('Invalid CPython archive path')
        if member.isdir():
            continue
        if member.issym() or member.islnk():
            target = PurePosixPath(member.linkname)
            joined = target if member.islnk() else path.parent / target
            normalized = PurePosixPath(os.path.normpath(str(joined)))
            if target.is_absolute() or '..' in normalized.parts or normalized.parts[0] != 'python':
                raise ValueError('Invalid CPython archive link')
            result[str(path)] = {'link': member.linkname, 'hard': member.islnk()}
        elif member.isfile():
            digest = hashlib.sha256()
            with archive.extractfile(member) as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
            result[str(path)] = {'sha256': digest.hexdigest(), 'executable': bool(member.mode & 0o111)}
        else:
            raise ValueError('Unsupported CPython archive node')
    return result


def intact(root, inventory):
    try:
        for name, expected in inventory.items():
            path = root / name
            if 'link' in expected:
                if expected['hard']:
                    target = root / expected['link']
                    if not path.is_file() or path.stat().st_ino != target.stat().st_ino:
                        return False
                elif not path.is_symlink() or os.readlink(path) != expected['link']:
                    return False
                if not path.resolve(strict=True).is_relative_to((root / 'python').resolve()):
                    return False
            elif (path.is_symlink() or not path.is_file() or sha(path) != expected['sha256']
                  or bool(path.stat().st_mode & 0o111) != expected['executable']):
                return False
        return bool(inventory)
    except (OSError, RuntimeError):
        return False


def version_matches(root, version):
    try:
        env = {key: value for key, value in os.environ.items() if not key.startswith(('PYTHON', 'DYLD_'))}
        result = subprocess.run([str(root / 'python/bin/python3'), '-I', '-B', '-c',
                                 'import json,sys; print(json.dumps(list(sys.version_info[:3])))'],
                                env=env, capture_output=True, timeout=20)
        return result.returncode == 0 and json.loads(result.stdout) == list(map(int, version.split('.')))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return False


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex)
    try:
        with temporary.open('w') as stream:
            json.dump(value, stream, sort_keys=True); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def prepare(root, archive_path, digest, version):
    root = root.resolve(); root.mkdir(parents=True, exist_ok=True)
    if sha(archive_path) != digest:
        raise ValueError('CPython archive SHA does not match the pin')
    with tarfile.open(archive_path, 'r:gz') as archive:
        inventory = entries(archive)
        manifest = {'archiveSHA256': digest, 'version': version, 'files': inventory}
        if intact(root, inventory) and version_matches(root, version):
            marker = root / 'python-runtime.json'
            try:
                previous_manifest = json.loads(marker.read_text())
            except (OSError, ValueError):
                previous_manifest = None
            if previous_manifest != manifest:
                atomic_json(marker, manifest)
            return {'cache': 'reused', 'filesVerified': len(inventory), 'archiveSHA256': digest}
        with tempfile.TemporaryDirectory(prefix='python-stage-', dir=root) as staging:
            staged = Path(staging)
            archive.extractall(staged)
            if not intact(staged, inventory) or not version_matches(staged, version):
                raise ValueError('Staged CPython runtime is not integral or has the wrong version')
            destination = root / 'python'
            previous = None
            if destination.exists() or destination.is_symlink():
                previous = root / ('previous-python.' + uuid.uuid4().hex)
                os.replace(destination, previous)
            try:
                os.replace(staged / 'python', destination)
            except BaseException:
                if previous is not None and not destination.exists():
                    os.replace(previous, destination)
                raise
            atomic_json(root / 'python-runtime.json', manifest)
            return {'cache': 'prepared', 'filesVerified': len(inventory), 'archiveSHA256': digest}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--version', required=True)
    options = parser.parse_args()
    print(json.dumps(prepare(options.root, options.archive, options.sha256, options.version)))
