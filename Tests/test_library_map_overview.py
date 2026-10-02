"""Synthetic geographic coverage, compact pages and scope-before-pagination."""
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_clients
import library_map_overview
import library_proximity
import library_repository as repository


def point(latitude=45.76, longitude=4.84, time=0, segment=0):
    return {'latitude': latitude, 'longitude': longitude, 'timeSeconds': time,
            'altitudeMeters': 10, 'segment': segment}


class MapOverviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-map-synthetic-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.database = self.root / 'library.sqlite'
        self.db = analyzer.open_database(self.database)
        self.addCleanup(self.db.close)
        repository.initialize(self.db)
        self.client = '11111111-1111-4111-8111-111111111111'
        self.other_client = '22222222-2222-4222-8222-222222222222'
        self.db.executemany('INSERT INTO clients VALUES(?,?)', [(self.client, 'Synthetic Alpha'), (self.other_client, 'Synthetic Beta')])
        self.db.commit()

    def add(self, name, points=None, date='2026-09-01', client=None, family='GPS', complete=None):
        identity = hashlib.sha256(name.encode()).hexdigest()
        log = analyzer.base_log(self.root / (name + '.ulg'), self.root, identity, 1)
        log.update(droneID='synthetic-controller', droneName='Synthetic', status='ok', date=date,
                   durationSeconds=60, messages=[{'id': name, 'text': name, 'title': name, 'groupKey': name,
                       'family': family, 'level': 'WARNING', 'isAlert': True, 'timestampSeconds': 0}])
        if points is not None:
            log['track'] = {'source': 'synthetic', 'originalPointCount': len(points) + 3,
                            'rejectedPointCount': 3, 'points': points}
        analyzer.remember_log(self.db, log)
        if client:
            self.db.execute('INSERT INTO log_clients VALUES(?,?)', (identity, client))
        if complete is not None:
            library_proximity.cache_track(self.db, identity, {'points': complete})
        self.db.commit()
        return identity

    def query(self, **kwargs):
        return repository.query(self.db, {'kind': 'map-overview', **kwargs})

    def all_pages(self, **kwargs):
        markers, cursor, pages = [], None, []
        while True:
            page = self.query(cursor=cursor, **kwargs)
            markers.extend(page['markers']); pages.append(page)
            cursor = page['nextCursor']
            if not cursor:
                return markers, pages

    def test_all_180_locations_include_eleven_old_english_logs_beyond_eighty(self):
        france = {self.add('recent-france-%03d' % index, [point()], client=self.client) for index in range(169)}
        england = {self.add('old-england-%02d' % index, [point(51.5, -0.12)], date='2025-12-15', client=self.client) for index in range(11)}
        no_gps = self.add('no-gps', client=self.client)
        foreign = self.add('other-client', [point(-33, 151)], client=self.other_client)
        markers, pages = self.all_pages(limit=37, scope={'clientID': self.client})
        self.assertEqual({item['id'] for item in markers}, france | england)
        self.assertEqual(len(markers), 180)
        self.assertEqual(sum(item['latitude'] == 51.5 for item in markers), 11)
        self.assertTrue(all(page['totalLogs'] == 181 and page['locatedLogs'] == 180 for page in pages))
        self.assertTrue(all(len(page['markers']) <= 37 for page in pages))
        self.assertEqual(len(pages), 5)
        self.assertNotIn(no_gps, {item['id'] for item in markers})
        self.assertNotIn(foreign, {item['id'] for item in markers})
        self.assertTrue(all('track' not in item and 'messages' not in item for item in markers))
        self.assertTrue(all(item['clientName'] == 'Synthetic Alpha' for item in markers))
        reverse, _ = self.all_pages(limit=37, scope={'clientID': self.client}, sortOrder='oldest')
        self.assertEqual([item['id'] for item in reverse], [item['id'] for item in reversed(markers)])

    def test_scope_and_geolocation_filter_precede_pagination(self):
        wanted = self.add('wanted-england', [point(51.5, -0.12)], date='2025-12-15', client=self.client, family='Batterie')
        self.add('wrong-family', [point(45, 4)], date='2025-12-15', client=self.client)
        self.add('wrong-date', [point(45, 4)], client=self.client, family='Batterie')
        self.add('wrong-client', [point(45, 4)], date='2025-12-15', client=self.other_client, family='Batterie')
        self.add('unlocated', date='2025-12-15', client=self.client, family='Batterie')
        page = self.query(limit=1, scope={'clientID': self.client, 'families': ['Batterie'], 'dateTo': '2025-12-31'})
        self.assertEqual([item['id'] for item in page['markers']], [wanted])
        self.assertEqual((page['totalLogs'], page['locatedLogs']), (2, 1))
        self.assertIsNone(page['nextCursor'])
        self.assertEqual(self.query(scope={'clientID': '', 'families': ['Batterie']})['totalLogs'], 0)

    def test_overview_reads_only_projected_markers_not_full_summaries_or_sources(self):
        self.add('large-preview', [point(time=index / 10) for index in range(1800)])
        self.query()
        reader = analyzer.open_database(self.database, read_only=True)
        self.addCleanup(reader.close)

        def authorize(action, table, column, *_):
            if action == sqlite3.SQLITE_READ and ((table == 'logs' and column == 'summary') or
                                                 (table == 'kl_logs' and column == 'summary_projection')):
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK

        reader.set_authorizer(authorize)
        with patch.object(analyzer, 'ULog', side_effect=AssertionError('Overview must not open original logs')):
            page = repository.query(reader, {'kind': 'map-overview', 'limit': 5000}, read_only=True)
        self.assertEqual(len(page['markers']), 1)
        self.assertLess(len(json.dumps(page)), 1024)

    def test_marker_uses_existing_valid_point_and_preserves_analysis_gaps_rejections(self):
        points = [point(latitude=100), point(51.5, -0.12, time=1, segment=1), point(52, -1, time=40, segment=2)]
        wanted = self.add('accepted-with-gaps', points)
        self.add('invalid-only', [point(latitude=100), point(longitude=181)])
        original = self.db.execute('SELECT summary FROM logs WHERE id=?', (wanted,)).fetchone()[0]
        page = self.query()
        self.assertEqual((page['totalLogs'], page['locatedLogs']), (2, 1))
        marker = page['markers'][0]
        self.assertEqual((marker['latitude'], marker['longitude']), (51.5, -0.12))
        self.assertEqual(self.db.execute('SELECT summary FROM logs WHERE id=?', (wanted,)).fetchone()[0], original)
        self.assertIsNone(library_map_overview.projected_marker({'track': {'points': [point(time=float('nan'))]}}))

    def test_proximity_applies_before_limit_and_uses_nearest_full_resolution_sample(self):
        area = {'latitude': 51.5, 'longitude': -0.12, 'radiusMeters': 20}
        wanted = self.add('old-near-england', [point(45, 4)], date='2025-12-15', client=self.client,
                          complete=[point(45, 4), point(51.5, -0.12, time=30, segment=1)])
        for index in range(85):
            self.add('newer-away-%02d' % index, [point()], client=self.client, complete=[point()])
        self.add('unavailable', [point(51.5, -0.12)], client=self.client)
        self.add('other-client-near', [point(51.5, -0.12)], client=self.other_client, complete=[point(51.5, -0.12)])
        page = self.query(limit=1, scope={'clientID': self.client}, proximity=area)
        self.assertEqual([item['id'] for item in page['markers']], [wanted])
        self.assertEqual((page['totalLogs'], page['locatedLogs'], page['proximityUnavailableLogs']), (1, 1, 1))
        self.assertEqual((page['markers'][0]['latitude'], page['markers'][0]['longitude']), (51.5, -0.12))
        self.assertIsNone(page['nextCursor'])

    def test_proximity_keeps_gaps_separate_and_supports_legacy_missing_preview(self):
        area = {'latitude': 1, 'longitude': 2, 'radiusMeters': 10}
        gap = [point(1, 1.999), point(1, 2.001, time=30, segment=1)]
        self.add('gps-gap', gap, complete=gap)
        invalid_gap = [point(1, 1.999), point(1, 2.001, time=2, segment=1)]
        self.add('rejected-fix-gap', invalid_gap, complete=invalid_gap)
        wanted = self.add('legacy-no-preview', complete=[point(1, 2)])
        crossing = self.add('crossing-without-inside-vertex', [point(1, 1.999)],
                            complete=[point(1, 1.999), point(1, 2.001, time=1)])
        page = self.query(proximity=area)
        self.assertEqual({item['id'] for item in page['markers']}, {wanted, crossing})
        self.assertEqual((page['totalLogs'], page['locatedLogs']), (2, 2))

    def test_v7_projection_migration_is_backed_up_and_preserves_original_analysis(self):
        wanted = self.add('migration', [point(51.5, -0.12)])
        self.query()
        before = self.db.execute('SELECT summary FROM logs WHERE id=?', (wanted,)).fetchone()[0]
        self.db.execute('ALTER TABLE kl_logs DROP COLUMN map_marker')
        self.db.execute("UPDATE kl_meta SET value='7' WHERE key='projectionVersion'")
        self.db.commit()
        page = self.query()
        self.assertEqual([item['id'] for item in page['markers']], [wanted])
        self.assertEqual(self.db.execute('SELECT summary FROM logs WHERE id=?', (wanted,)).fetchone()[0], before)
        backup = self.db.execute("SELECT value FROM settings WHERE key='indexMigrationBackup'").fetchone()[0]
        self.assertTrue(Path(backup).is_file())
        self.assertEqual(self.db.execute("SELECT value FROM kl_meta WHERE key='projectionVersion'").fetchone()[0], str(repository.PROJECTION_VERSION))

    def test_revision_and_scope_invalidate_overview_cursor(self):
        self.add('one', [point()], client=self.client)
        self.add('two', [point()], client=self.client)
        first = self.query(limit=1, scope={'clientID': self.client})
        with self.assertRaises(ValueError):
            self.query(cursor=first['nextCursor'], scope={'clientID': self.other_client})
        self.add('three', [point()], client=self.client)
        with self.assertRaises(ValueError):
            self.query(cursor=first['nextCursor'], scope={'clientID': self.client})


if __name__ == '__main__':
    unittest.main()
