"""Runtime cache publication fixtures, with no real interpreter replaced."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime_cache', ROOT / 'tools/prepare-python-runtime.py')
cache = importlib.util.module_from_spec(spec); spec.loader.exec_module(cache)


class PythonRuntimeCacheTests(unittest.TestCase):
    def archive(self, root, name, version):
        target = root / name
        with tarfile.open(target, 'w:gz') as archive:
            for path, content, mode in [('python/bin/python3', '#!/bin/sh\nprintf \'%s\\n\' \'[' + version.replace('.', ',') + ']\'\n', 0o755),
                                        ('python/lib/public-fixture.txt', 'invented runtime fixture', 0o644)]:
                data = content.encode(); member = tarfile.TarInfo(path); member.size = len(data); member.mode = mode
                archive.addfile(member, io.BytesIO(data))
        return target, hashlib.sha256(target.read_bytes()).hexdigest()

    def test_valid_cache_reuse_preserves_binary_inode_mtime_and_all_bytes(self):
        with tempfile.TemporaryDirectory(prefix='katalog-runtime-cache-') as name:
            work = Path(name); archive, digest = self.archive(work, 'valid.tar.gz', '3.13.15')
            root = work / 'cache'; self.assertEqual(cache.prepare(root, archive, digest, '3.13.15')['cache'], 'prepared')
            signatures = {str(path.relative_to(root)): (path.stat().st_ino, path.stat().st_mtime_ns, path.read_bytes())
                          for path in (root / 'python').rglob('*') if path.is_file()}
            self.assertEqual(cache.prepare(root, archive, digest, '3.13.15')['cache'], 'reused')
            self.assertEqual(signatures, {str(path.relative_to(root)): (path.stat().st_ino, path.stat().st_mtime_ns, path.read_bytes())
                                         for path in (root / 'python').rglob('*') if path.is_file()})

    def test_wrong_version_in_staging_never_replaces_existing_runtime(self):
        with tempfile.TemporaryDirectory(prefix='katalog-runtime-stage-') as name:
            work = Path(name); valid, digest = self.archive(work, 'valid.tar.gz', '3.13.15')
            root = work / 'cache'; cache.prepare(root, valid, digest, '3.13.15')
            before = (root / 'python/bin/python3').read_bytes(), (root / 'python/bin/python3').stat().st_ino
            invalid, invalid_digest = self.archive(work, 'invalid.tar.gz', '0.0.0')
            with self.assertRaisesRegex(ValueError, 'Staged CPython'):
                cache.prepare(root, invalid, invalid_digest, '3.13.15')
            self.assertEqual(before, ((root / 'python/bin/python3').read_bytes(), (root / 'python/bin/python3').stat().st_ino))
            self.assertFalse(list(root.glob('python-stage-*')))


if __name__ == '__main__': unittest.main()
