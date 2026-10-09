"""The shared writer preserves both public formats and atomic failure behavior."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_storage as storage


class AtomicJSONTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='katalog-atomic-json-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.value = {'nom': 'été', 'rows': [1, {'ok': True}], 'none': None}
        self.formats = (
            (analyzer.atomic_json, b'{"nom":"\xc3\xa9t\xc3\xa9","rows":[1,{"ok":true}],"none":null}', '.state.json.'),
            (storage.atomic_json, b'{"nom": "\xc3\xa9t\xc3\xa9", "rows": [1, {"ok": true}], "none": null}', '.state.json'),
        )

    def test_exact_bytes_and_staging_prefix_are_preserved(self):
        for writer, expected, prefix in self.formats:
            with self.subTest(writer=writer.__module__):
                path = self.root / writer.__module__ / 'state.json'
                with patch.object(tempfile, 'mkstemp', wraps=tempfile.mkstemp) as staging:
                    self.assertIsNone(writer(str(path), self.value))
                self.assertEqual(path.read_bytes(), expected)
                staging.assert_called_once_with(prefix=prefix, dir=path.parent)
                self.assertEqual(list(path.parent.iterdir()), [path])

    def test_serialization_failures_preserve_original_and_remove_staging(self):
        for writer, _, _ in self.formats:
            for invalid, error in ((object(), TypeError), (float('nan'), ValueError)):
                with self.subTest(writer=writer.__module__, error=error.__name__):
                    path = self.root / 'state.json'
                    path.write_bytes(b'original bytes')
                    with self.assertRaises(error):
                        writer(path, {'written_first': 'partial', 'invalid': invalid})
                    self.assertEqual(path.read_bytes(), b'original bytes')
                    self.assertEqual(list(self.root.iterdir()), [path])

    def test_replace_failure_preserves_original_and_removes_staging(self):
        for writer, expected, _ in self.formats:
            with self.subTest(writer=writer.__module__):
                path = self.root / 'state.json'
                path.write_bytes(b'original bytes')

                def refuse_replace(source, destination):
                    self.assertEqual(Path(source).read_bytes(), expected)
                    self.assertEqual(destination, path)
                    self.assertEqual(path.read_bytes(), b'original bytes')
                    raise OSError('synthetic replace failure')

                with patch.object(os, 'replace', side_effect=refuse_replace), self.assertRaisesRegex(OSError, 'synthetic replace'):
                    writer(path, self.value)
                self.assertEqual(path.read_bytes(), b'original bytes')
                self.assertEqual(list(self.root.iterdir()), [path])

    def test_complete_staging_is_flushed_and_synced_before_publication(self):
        real_fsync, real_replace = os.fsync, os.replace
        for writer, expected, _ in self.formats:
            with self.subTest(writer=writer.__module__):
                path = self.root / 'state.json'
                path.write_bytes(b'original bytes')
                events = []

                def sync(descriptor):
                    staging = [item for item in self.root.iterdir() if item != path]
                    self.assertEqual(len(staging), 1)
                    self.assertEqual(staging[0].read_bytes(), expected)
                    self.assertEqual(path.read_bytes(), b'original bytes')
                    events.append('fsync')
                    return real_fsync(descriptor)

                def publish(source, destination):
                    self.assertEqual(events, ['fsync'])
                    events.append('replace')
                    return real_replace(source, destination)

                with patch.object(os, 'fsync', side_effect=sync), patch.object(os, 'replace', side_effect=publish):
                    writer(path, self.value)
                self.assertEqual(events, ['fsync', 'replace'])
                self.assertEqual(path.read_bytes(), expected)
                self.assertEqual(list(self.root.iterdir()), [path])


if __name__ == '__main__':
    unittest.main()
