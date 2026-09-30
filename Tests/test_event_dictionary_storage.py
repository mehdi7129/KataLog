"""Offline, hash-bound event artifacts; invented public ULog fixtures only."""
import hashlib
import json
import lzma
from pathlib import Path
import struct
import sys
import tempfile
import unittest

sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources')]
import analyzer
import library_storage
from fixture_ulog import synthetic_ulog


def without_embedded_dictionary(binary):
    result, offset = binary[:16], 16
    while offset < len(binary):
        length, kind = struct.unpack('<HB', binary[offset:offset+3])
        size = length + 3
        if kind != ord('M'):
            result += binary[offset:offset+size]
        offset += size
    return result


class EventDictionaryStorageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-event-dictionary-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.library = self.root / 'library'; self.library.mkdir()
        self.source = self.root / 'source'; self.source.mkdir()
        binary = synthetic_ulog(samples=8)
        full = self.root / 'embedded.ulg'; full.write_bytes(binary)
        ulog = analyzer.ULog(str(full))
        self.payload = b''.join(ulog.msg_info_multiple_dict['metadata_events'][0])
        self.artifact = self.root / 'all_events.json.xz'; self.artifact.write_bytes(self.payload)
        self.log_file = self.source / 'flight.ulg'; self.log_file.write_bytes(without_embedded_dictionary(binary))
        self.database = self.library / 'library.sqlite'
        self.log = analyzer.scan(self.source, self.database)['logs'][0]
        self.original_bytes = self.log_file.read_bytes()

    def test_import_exact_artifact_refreshes_only_matching_cache_and_survives_source_absence(self):
        before = analyzer.detail(self.log['id'], self.database)
        self.assertEqual(before['eventDictionary']['status'], 'missing')
        self.assertEqual(before['events'][0]['translationStatus'], 'missing')
        imported = analyzer.import_event_dictionary(self.database, self.artifact)
        self.assertEqual(imported['sha256'], hashlib.sha256(self.payload).hexdigest())
        self.assertEqual(imported['matchingCachedLogs'], 1)
        self.assertFalse(imported['reused'])
        after = analyzer.detail(self.log['id'], self.database)
        self.assertEqual(after['eventDictionary']['status'], 'ready')
        self.assertEqual(after['events'][0]['translationStatus'], 'translated')
        self.assertIn('16.0', after['events'][0]['message'])
        self.assertEqual(after['events'][0]['argumentsHex'], before['events'][0]['argumentsHex'])
        self.assertEqual(after['droneID'], before['droneID'])
        self.assertEqual(self.log_file.read_bytes(), self.original_bytes)
        self.assertTrue(analyzer.import_event_dictionary(self.database, self.artifact)['reused'])
        self.log_file.unlink()
        offline = analyzer.detail(self.log['id'], self.database)
        self.assertEqual(offline['events'], after['events'])
        self.assertEqual(offline['metadata']['detailCacheStatus'], 'current')

    def test_unrelated_dictionary_never_translates_or_changes_existing_detail_cache(self):
        before = analyzer.detail(self.log['id'], self.database)
        definition = json.loads(lzma.decompress(self.payload))
        definition['components']['1']['event_groups']['default']['events']['123']['message'] = 'Wrong firmware {1}'
        self.artifact.write_bytes(lzma.compress(json.dumps(definition).encode()))
        imported = analyzer.import_event_dictionary(self.database, self.artifact)
        self.assertEqual(imported['matchingCachedLogs'], 0)
        after = analyzer.detail(self.log['id'], self.database)
        self.assertEqual(after['events'], before['events'])
        self.assertEqual(after['eventDictionary']['status'], 'missing')

    def test_source_absent_keeps_raw_cache_and_explains_unrecomputed_dictionary(self):
        before = analyzer.detail(self.log['id'], self.database)
        self.log_file.unlink()
        analyzer.import_event_dictionary(self.database, self.artifact)
        after = analyzer.detail(self.log['id'], self.database)
        self.assertEqual(after['events'], before['events'])
        self.assertEqual(after['metadata']['detailCacheStatus'], 'previous')
        self.assertTrue(any('traduction non recalculée' in value for value in after['coverage']))

    def test_invalid_nonxz_oversized_and_concatenated_artifacts_leave_library_unchanged(self):
        before = self.database.read_bytes()
        for payload in (b'{}', b'\xfd7zXZ\x00' + bytes(4 * 1024 * 1024), self.payload + self.payload,
                        lzma.compress(b'{"version":99,"components":{}}')):
            self.artifact.write_bytes(payload)
            with self.assertRaises(ValueError):
                analyzer.import_event_dictionary(self.database, self.artifact)
            self.assertEqual(self.database.read_bytes(), before)
            self.assertFalse((self.library / 'event-dictionaries').exists())

    def test_dictionary_backup_restore_preserves_exact_artifact_and_root_lease(self):
        imported = analyzer.import_event_dictionary(self.database, self.artifact)
        lease = self.library / '.library-writer.lock'; lease.write_bytes(b'owned fixture lease')
        inode = lease.stat().st_ino
        archive = self.root / 'backup.zip'
        library_storage.backup(self.library, archive)
        self.assertEqual(library_storage.inspect_backup(archive)['fileCount'], 2)
        Path(imported['path']).unlink()
        library_storage.restore(archive, self.library)
        self.assertEqual(Path(imported['path']).read_bytes(), self.payload)
        self.assertEqual(lease.stat().st_ino, inode)
        after = analyzer.detail(self.log['id'], self.database)
        self.assertEqual(after['eventDictionary']['status'], 'ready')

    def test_cli_import_dictionary_contract(self):
        output = self.root / 'reply.json'
        self.assertEqual(analyzer.main(['event-dictionary', '--database', str(self.database), '--file', str(self.artifact), '--output', str(output)]), 0)
        reply = json.loads(output.read_text())
        self.assertEqual(reply['dictionaryVersion'], 1)
        self.assertEqual(reply['sha256'], hashlib.sha256(self.payload).hexdigest())


if __name__ == '__main__':
    unittest.main()
