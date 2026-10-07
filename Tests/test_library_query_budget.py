"""Synthetic response budgets include snapshot metadata before pagination."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_repository as repository


def encoded_size(value):
    return len(json.dumps(value, ensure_ascii=False, allow_nan=False).encode('utf-8'))


class QueryBudgetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-query-budget-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.database = self.root / 'library.sqlite'
        self.db = analyzer.open_database(self.database)
        self.addCleanup(self.db.close)
        self.client = '11111111-1111-4111-8111-111111111111'
        self.other_client = '22222222-2222-4222-8222-222222222222'
        self.db.executemany('INSERT INTO clients VALUES(?,?)', [
            (self.client, 'Client synthétique Étoile'),
            (self.other_client, 'Autre client synthétique')])
        self.stats = {'discovered': 97, 'imported': 97, 'unchanged': 0,
                      'duplicates': 0, 'failed': 0}
        self.db.execute("INSERT INTO settings VALUES('lastImportStats',?)", (json.dumps(self.stats),))
        self.logs = {}
        self.folders = []

    def add_folders(self, count=60, components=12):
        # Paths are intentionally fictional; no original files are consulted.
        branch = '/'.join(['dossier-étoilé-' * 8] * components)
        self.folders = [f'/synthetic/sources/{index:03d}/{branch}' for index in range(count)]
        self.db.executemany('INSERT INTO folders VALUES(?)', ((folder,) for folder in self.folders))

    def add_log(self, index, points=600, client=None):
        name = f'synthetic-{index:03d}'
        identity = hashlib.sha256(name.encode()).hexdigest()
        value = analyzer.base_log(self.root / (name + '.ulg'), self.root, identity, 1)
        value.update(droneID='synthetic-controller', droneName='Drone synthétique',
                     date='2026-01-01T12:00:00Z', durationSeconds=60, status='ok',
                     messages=[{'id': name, 'text': 'Événement synthétique',
                                'title': 'Événement synthétique', 'groupKey': 'synthetic-warning',
                                'family': 'Synthétique', 'level': 'WARNING',
                                'isAlert': True, 'timestampSeconds': 0}],
                     track={'source': 'synthetic', 'points': [
                         {'latitude': 45.0 + point / 1000000, 'longitude': 2.0,
                          'altitudeMeters': 10, 'timeSeconds': point, 'segment': 0}
                         for point in range(points)]})
        analyzer.remember_log(self.db, value)
        assigned = client or self.client
        self.db.execute('INSERT INTO log_clients VALUES(?,?)', (identity, assigned))
        self.logs[identity] = (value, assigned)

    def reader(self):
        self.db.commit()
        repository.initialize(self.db)
        reader = analyzer.open_database(self.database, read_only=True)
        self.addCleanup(reader.close)
        return reader

    def check_pages(self, reader, kind='logs', client=None, budget=4 * 1024 * 1024):
        request = {'kind': kind, 'limit': 200, 'scope': {'clientID': client}}
        wanted = sorted((identity for identity, (_, assigned) in self.logs.items()
                         if client is None or assigned == client), reverse=True)
        seen, cursors, pages = [], set(), []
        expected_totals = None
        while True:
            page = repository.query(reader, request, read_only=True)
            self.assertLessEqual(encoded_size(page), budget)
            self.assertEqual(page['snapshot']['sourceFolders'], self.folders)
            self.assertEqual(page['snapshot']['importStats'], self.stats)
            self.assertEqual(page['totals']['logs'], len(wanted))
            self.assertEqual(page['totals']['recordedSeconds'], len(wanted) * 60)
            self.assertEqual(page['totals']['messages'], len(wanted))
            self.assertEqual(page['totals']['alertLogs'], len(wanted))
            self.assertEqual(page['totals']['groupCount'], int(bool(wanted)))
            self.assertEqual(page['totals']['familyLogCounts'], {'Synthétique': len(wanted)} if wanted else {})
            if expected_totals is None:
                expected_totals = page['totals']
            self.assertEqual(page['totals'], expected_totals)
            for log in page['snapshot']['logs']:
                original, assigned = self.logs[log['id']]
                self.assertEqual(log['track'], original['track'])
                self.assertEqual(log['clientID'], assigned)
                self.assertEqual(log['summaryMessageCount'], 1)
                seen.append(log['id'])
            pages.append(page)
            cursor = page['nextCursor']
            if cursor is None:
                break
            self.assertTrue(page['snapshot']['logs'])
            self.assertNotIn(cursor, cursors)
            cursors.add(cursor)
            request['cursor'] = cursor
        self.assertEqual(seen, wanted)
        self.assertEqual(len(seen), len(set(seen)))
        return pages

    def test_four_mib_pages_include_long_unicode_sources_without_losing_logs_or_clients(self):
        self.add_folders()
        for index in range(96):
            self.add_log(index)
        self.add_log(96, client=self.other_client)
        reader = self.reader()
        canonical = list(self.db.execute('SELECT id,summary FROM logs ORDER BY id'))
        membership = list(self.db.execute('SELECT log_id,client_id FROM log_clients ORDER BY log_id'))
        for kind in ('logs', 'map'):
            for client in (None, self.client):
                with self.subTest(kind=kind, client=client):
                    pages = self.check_pages(reader, kind, client)
                    self.assertGreater(len(pages), 1)
                    self.assertLess(len(pages[0]['snapshot']['logs']), 80)
        self.assertEqual(list(self.db.execute('SELECT id,summary FROM logs ORDER BY id')), canonical)
        self.assertEqual(list(self.db.execute('SELECT log_id,client_id FROM log_clients ORDER BY log_id')), membership)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM clients').fetchone()[0], 2)

    def test_small_budget_still_paginates_complete_snapshot(self):
        self.add_folders(count=53, components=1)
        for index in range(12):
            self.add_log(index, points=40)
        reader = self.reader()
        budget = 32 * 1024
        with patch.object(repository, 'MAX_QUERY_BYTES', budget):
            for kind in ('logs', 'map'):
                with self.subTest(kind=kind):
                    self.assertGreater(len(self.check_pages(reader, kind, budget=budget)), 1)

    def test_empty_selection_keeps_sources_stats_and_has_no_cursor(self):
        self.add_folders()
        reader = self.reader()
        for kind in ('logs', 'map'):
            with self.subTest(kind=kind):
                pages = self.check_pages(reader, kind)
                self.assertEqual(len(pages), 1)
                self.assertEqual(pages[0]['snapshot']['logs'], [])
                self.assertIsNone(pages[0]['nextCursor'])

    def test_single_oversized_log_is_rejected_without_truncation(self):
        self.add_log(0)
        reader = self.reader()
        with patch.object(repository, 'MAX_QUERY_BYTES', 16 * 1024):
            for kind in ('logs', 'map'):
                with self.subTest(kind=kind), self.assertRaisesRegex(ValueError, 'Un résultat dépasse le budget de page'):
                    repository.query(reader, {'kind': kind}, read_only=True)


if __name__ == '__main__':
    unittest.main()
