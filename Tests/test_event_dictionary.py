"""Public integration fixtures for exact local event-dictionary installation."""
import hashlib
import json
import lzma
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_repository as repository
import library_storage as storage
import px4_events
from fixture_ulog import synthetic_ulog


def external_event_fixture():
    """Keep the exact hash and binary events; move their artifact out of ULog."""
    original = synthetic_ulog()
    content, artifact = bytearray(original[:16]), None
    position = 16
    while position < len(original):
        size, kind = struct.unpack_from('<HB', original, position)
        record = original[position:position + 3 + size]
        payload = record[3:]
        if kind == ord('M'):
            key_size = payload[1]
            if payload[2:2 + key_size].endswith(b' metadata_events'):
                artifact = payload[2 + key_size:]
            else:
                content.extend(record)
        else:
            content.extend(record)
        position += size + 3
    assert artifact is not None
    return bytes(content), artifact


class EventDictionaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-event-dictionary-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.library = self.root / 'library'; self.library.mkdir()
        self.database = self.library / 'library.sqlite'
        content, self.payload = external_event_fixture()
        self.source = self.root / 'source.ulg'; self.source.write_bytes(content)
        self.artifact = self.root / 'all_events.json.xz'; self.artifact.write_bytes(self.payload)
        self.log = analyzer.scan(self.source, self.database)['logs'][0]
        self.checksum = hashlib.sha256(self.payload).hexdigest()

    def test_cli_import_exact_artifact_reuses_without_mutating_originals(self):
        before = (self.source.read_bytes(), analyzer.stat_signature(self.source.stat()),
                  self.artifact.read_bytes(), analyzer.stat_signature(self.artifact.stat()))
        missing = analyzer.detail(self.log['id'], self.database)
        self.assertEqual(missing['eventDictionary']['status'], 'missing')
        output = self.root / 'dictionary-result.json'
        with patch('urllib.request.urlopen', side_effect=AssertionError('network forbidden')):
            self.assertEqual(analyzer.main(['event-dictionary', '--database', str(self.database),
                '--file', str(self.artifact), '--output', str(output)]), 0)
        result = json.loads(output.read_text())
        self.assertEqual(result['dictionaryVersion'], 1)
        self.assertEqual(result['sha256'], self.checksum)
        self.assertEqual(result['definitionVersion'], 1)
        self.assertEqual(result['sizeBytes'], len(self.payload))
        self.assertEqual(result['matchingCachedLogs'], 1)
        self.assertFalse(result['reused'])
        self.assertEqual(Path(result['path']).read_bytes(), self.payload)
        reused = analyzer.import_event_dictionary(self.database, self.artifact)
        self.assertTrue(reused['reused'])
        self.assertEqual(before, (self.source.read_bytes(), analyzer.stat_signature(self.source.stat()),
                                self.artifact.read_bytes(), analyzer.stat_signature(self.artifact.stat())))
        ready = analyzer.detail(self.log['id'], self.database)
        self.assertEqual(ready['eventDictionary']['status'], 'ready')
        self.assertEqual(ready['events'][0]['message'], 'Synthetic voltage 16.0')
        self.assertFalse(any(item.startswith('Événements binaires non décodés :') for item in ready['coverage']))
        self.assertTrue(any('1 traduits' in item for item in ready['coverage']))

    def test_cli_detail_publishes_events_for_immediate_read_only_query(self):
        output = self.root / 'details.json'
        self.assertEqual(analyzer.main(['detail', '--database', str(self.database),
            '--log-id', self.log['id'], '--output', str(output)]), 0)
        db = analyzer.open_database(self.database, read_only=True)
        try:
            result = repository.query(db, {'queryVersion': 1, 'kind': 'events'}, read_only=True)
            self.assertEqual(result['total'], 1)
            self.assertEqual(result['coverage']['cachedLogs'], 1)
            self.assertEqual(result['occurrences'][0]['event']['translationStatus'], 'missing')
            self.assertEqual(db.execute('SELECT COUNT(*) FROM kl_dirty').fetchone()[0], 0)
        finally: db.close()

    def test_unmatched_artifact_never_translates_by_name_or_branch(self):
        analyzer.detail(self.log['id'], self.database)
        definitions = {'version': 1, 'components': {}}
        self.artifact.write_bytes(lzma.compress(json.dumps(definitions).encode()))
        result = analyzer.import_event_dictionary(self.database, self.artifact)
        self.assertEqual(result['matchingCachedLogs'], 0)
        unchanged = analyzer.detail(self.log['id'], self.database)
        self.assertEqual(unchanged['eventDictionary']['status'], 'missing')
        self.assertIsNone(unchanged['events'][0]['message'])

    def test_unavailable_source_retains_raw_cache_after_exact_dictionary_import(self):
        missing = analyzer.detail(self.log['id'], self.database)
        self.source.unlink()
        analyzer.import_event_dictionary(self.database, self.artifact)
        result = analyzer.detail(self.log['id'], self.database)
        self.assertEqual(result['metadata']['detailCacheStatus'], 'previous')
        self.assertEqual(result['events'], missing['events'])
        self.assertEqual(result['eventDictionary']['status'], 'missing')
        self.assertTrue(any('traduction non recalculée' in item for item in result['coverage']))

    def test_malformed_optional_detail_cache_does_not_block_dictionary_install(self):
        db = analyzer.open_database(self.database)
        try:
            db.execute('INSERT INTO flight_details VALUES(?,?,?)', (self.log['id'], analyzer.PARSER_VERSION, 'invalid-json'))
            db.commit()
        finally:
            db.close()
        result = analyzer.import_event_dictionary(self.database, self.artifact)
        self.assertEqual(result['matchingCachedLogs'], 0)
        self.assertTrue(Path(result['path']).is_file())

    def test_invalid_future_oversized_and_bomb_artifacts_are_not_installed(self):
        invalid = [b'not XZ', lzma.compress(b'not JSON'), lzma.compress(json.dumps({'version': 99, 'components': {}}).encode()),
                   self.payload + self.payload]
        for payload in invalid:
            with self.subTest(payloadLength=len(payload)):
                self.artifact.write_bytes(payload)
                with self.assertRaises(ValueError): analyzer.import_event_dictionary(self.database, self.artifact)
        self.artifact.write_bytes(self.payload)
        with patch.object(px4_events, 'MAX_ARTIFACT_BYTES', len(self.payload) - 1):
            with self.assertRaises(ValueError): analyzer.import_event_dictionary(self.database, self.artifact)
        self.artifact.write_bytes(lzma.compress(b'x' * 1025))
        with patch.object(px4_events, 'MAX_DEFINITION_BYTES', 1024):
            with self.assertRaises(ValueError): analyzer.import_event_dictionary(self.database, self.artifact)
        self.assertFalse((self.library / 'event-dictionaries').exists())

    def test_installed_symlink_and_corrupt_existing_artifact_are_rejected(self):
        directory = self.library / 'event-dictionaries'; directory.mkdir()
        target = directory / (self.checksum + '.json.xz')
        target.symlink_to(self.artifact)
        with self.assertRaises(ValueError): analyzer.import_event_dictionary(self.database, self.artifact)
        target.unlink(); target.write_bytes(b'wrong-content')
        with self.assertRaises(ValueError): analyzer.import_event_dictionary(self.database, self.artifact)
        self.assertEqual(target.read_bytes(), b'wrong-content')

    def test_backup_restore_preserves_exact_dictionaries_and_rolls_back_replacement(self):
        installed = analyzer.import_event_dictionary(self.database, self.artifact)
        archive = self.root / 'backup.zip'
        storage.backup(self.library, archive)
        entry = 'event-dictionaries/' + self.checksum + '.json.xz'
        with zipfile.ZipFile(archive) as handle:
            self.assertEqual(handle.read(entry), self.payload)
            manifest = json.loads(handle.read('manifest.json'))
            self.assertEqual(next(item['sha256'] for item in manifest['files'] if item['name'] == entry), self.checksum)
        target = self.root / 'restored'
        storage.restore(archive, target)
        self.assertEqual((target / entry).read_bytes(), self.payload)
        restored = analyzer.detail(self.log['id'], target / 'library.sqlite')
        self.assertEqual(restored['eventDictionary']['status'], 'ready')
        before = Path(installed['path']).read_bytes()
        replace = storage.os.replace
        def fail_dictionary_swap(source, destination):
            if Path(destination) == self.library / 'event-dictionaries' and '.restore-staging-' in str(source):
                raise OSError('synthetic dictionary swap failure')
            return replace(source, destination)
        with patch.object(storage.os, 'replace', side_effect=fail_dictionary_swap):
            with self.assertRaisesRegex(OSError, 'synthetic'): storage.restore(archive, self.library)
        self.assertEqual(Path(installed['path']).read_bytes(), before)
        self.assertFalse((self.library / '.restore-journal.json').exists())

    def test_backup_refuses_dictionary_hash_mismatch_before_publication(self):
        result = analyzer.import_event_dictionary(self.database, self.artifact)
        Path(result['path']).write_bytes(b'corrupt')
        archive = self.root / 'refused.zip'
        with self.assertRaises(ValueError): storage.backup(self.library, archive)
        self.assertFalse(archive.exists())


if __name__ == '__main__': unittest.main()
