"""Real synthetic ULogs keep their recorded origin when an identical copy moves."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources')]
import analyzer
import library_archives as archives
from fixture_ulog import synthetic_ulog


class CanonicalProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='katalog-canonical-origin-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.original = self.root / 'original-card' / 'log' / '2024-01-02' / '03_04_05.ulg'
        self.copy = self.root / 'relocated-card' / 'log' / '2025-06-07' / '08_09_10.ulg'
        for path, name in ((self.original, 'Original synthetic card'), (self.copy, 'Relocated synthetic card')):
            path.parent.mkdir(parents=True)
            metadata = path.parents[2] / 'data'
            metadata.mkdir()
            (metadata / 'name.txt').write_text(name)

    def import_previous(self, database, binary):
        self.original.write_bytes(binary)
        self.copy.write_bytes(binary)
        with patch.object(analyzer, 'PARSER_VERSION', 'public-previous-parser'):
            analyzer.scan(self.original.parents[2], database, skip_snapshot=True)
        self.assertEqual(analyzer.digest_file(self.original), analyzer.digest_file(self.copy))
        return self.saved(database)

    def saved(self, database):
        db = analyzer.open_database(database, read_only=True)
        try:
            row = db.execute('SELECT parser_version,summary FROM logs').fetchone()
            return row[0], json.loads(row[1])
        finally:
            db.close()

    def assert_origin(self, saved, previous):
        for field in ('id', 'droneID', 'droneName', 'date', 'dateSource', 'fileName', 'sourcePaths'):
            self.assertEqual(saved[field], previous[field], field)
        self.assertEqual(saved['messages'], previous['messages'])
        self.assertEqual(saved['coverage'], previous['coverage'])

    def test_reimport_after_parser_change_preserves_origin_with_and_without_managed_copy(self):
        binary = synthetic_ulog(samples=0, include_uuid=False, events=False)
        for managed in (False, True):
            with self.subTest(managed=managed):
                database = self.root / ('managed' if managed else 'direct') / 'library.sqlite'
                _, previous = self.import_previous(database, binary)
                destination = self.root / 'archives' if managed else None
                result = analyzer.scan(self.copy.parents[2], database, archive_destination=destination)
                version, current = self.saved(database)
                self.assertEqual(version, analyzer.PARSER_VERSION)
                self.assert_origin(current, previous)
                self.assertEqual(result['importStats']['imported'], 1)
                self.assertIn(str(self.copy), result['logs'][0]['sourcePaths'])
                self.assertEqual(self.original.read_bytes(), binary)
                self.assertEqual(self.copy.read_bytes(), binary)
                if managed:
                    manifest = json.loads(next(destination.glob('archive-manifest-*.json')).read_text())
                    origin = manifest['jobs'][0]['originContext']
                    for field in ('droneID', 'droneName', 'date', 'dateSource', 'fileName', 'sourcePaths'):
                        self.assertEqual(origin[field], previous[field], field)
                    self.assertEqual((destination / (previous['id'] + '.ulg')).read_bytes(), binary)

    def test_refresh_from_reassociated_copy_preserves_recorded_origin(self):
        binary = synthetic_ulog(samples=0, include_uuid=False, events=False)
        database = self.root / 'library' / 'library.sqlite'
        _, previous = self.import_previous(database, binary)
        self.assertEqual(archives.reassociate(database, self.copy.parents[2])['matched'], 1)
        self.original.unlink()
        result = analyzer.refresh_analysis(database)
        self.assertEqual(result['reanalyzed'], 1)
        version, current = self.saved(database)
        self.assertEqual(version, analyzer.PARSER_VERSION)
        self.assert_origin(current, previous)
        self.assertEqual(self.copy.read_bytes(), binary)
        db = analyzer.open_database(database, read_only=True)
        try:
            self.assertEqual({row[0] for row in db.execute('SELECT path FROM sources')},
                             {str(self.original), str(self.copy)})
            self.assertEqual({row[0] for row in db.execute('SELECT parser_version FROM analysis_revisions')},
                             {'public-previous-parser', analyzer.PARSER_VERSION})
        finally:
            db.close()

    def test_newly_recognized_ulog_identity_name_and_gps_override_legacy_fallbacks(self):
        binary = synthetic_ulog(drone_name='Authoritative synthetic controller', samples=3)
        for operation in ('refresh', 'reimport'):
            with self.subTest(operation=operation):
                database = self.root / operation / 'library.sqlite'
                _, authoritative = self.import_previous(database, binary)
                legacy = dict(authoritative)
                fallback = analyzer.base_log(self.original, self.original.parents[2], authoritative['id'], len(binary))
                for field in ('droneID', 'droneName', 'date', 'dateSource'):
                    legacy[field] = fallback[field]
                # A historical parser did not recognize these fields. The
                # current real ULog parser must be allowed to discover them.
                db = analyzer.open_database(database)
                try:
                    with patch.object(analyzer, 'PARSER_VERSION', 'public-previous-parser'):
                        analyzer.remember_log(db, legacy)
                    db.commit()
                finally:
                    db.close()
                if operation == 'refresh':
                    archives.reassociate(database, self.copy.parents[2])
                    self.original.unlink()
                    self.assertEqual(analyzer.refresh_analysis(database)['reanalyzed'], 1)
                else:
                    self.assertEqual(analyzer.scan(self.copy.parents[2], database)['importStats']['imported'], 1)
                _, current = self.saved(database)
                for field in ('droneID', 'droneName', 'date', 'dateSource'):
                    self.assertEqual(current[field], authoritative[field], field)
                for field in ('fileName', 'sourcePaths'):
                    self.assertEqual(current[field], legacy[field], field)
                self.assertEqual(current['dateSource'], 'gps')
                self.assertFalse(current['droneID'].startswith(('card:', 'unknown:')))

    def test_cached_reassociated_copy_archives_the_canonical_origin(self):
        database = self.root / 'library' / 'library.sqlite'
        binary = synthetic_ulog(samples=0, include_uuid=False, events=False)
        self.original.write_bytes(binary)
        self.copy.write_bytes(binary)
        analyzer.scan(self.original.parents[2], database)
        _, previous = self.saved(database)
        archives.reassociate(database, self.copy.parents[2])
        destination = self.root / 'archives'
        result = analyzer.scan(self.copy.parents[2], database, archive_destination=destination)
        self.assertEqual(result['importStats']['unchanged'], 1)
        manifest = json.loads(next(destination.glob('archive-manifest-*.json')).read_text())
        for field in ('droneID', 'droneName', 'date', 'dateSource', 'fileName', 'sourcePaths'):
            self.assertEqual(manifest['jobs'][0]['originContext'][field], previous[field], field)


if __name__ == '__main__':
    unittest.main()
