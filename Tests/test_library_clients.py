"""Client boundaries, complete trajectory matching and non-destructive reset."""
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_clients as clients
import library_proximity as proximity
import library_repository as repository
import library_reports as reports
from fixture_ulog import synthetic_ulog, record, MAGIC


def track_ulog(points):
    data = MAGIC + bytes([1]) + struct.pack('<Q', 1_000_000)
    data += record('F', b'sensor_gps:uint64_t timestamp;int32_t lat;int32_t lon;int32_t alt;uint8_t fix_type;')
    data += record('A', struct.pack('<BH', 0, 1) + b'sensor_gps')
    for time, latitude, longitude, fix in points:
        data += record('D', struct.pack('<HQiiiB', 1, int((time+1)*1e6), int(latitude*1e7), int(longitude*1e7), 1000, fix))
    return data


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-clients-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.database = self.root / 'library.sqlite'
        self.a = clients.command(self.database, 'create-client', {'name': 'Client Alpha'})['id']
        self.b = clients.command(self.database, 'create-client', {'name': 'Client Beta'})['id']

    def add(self, name, client=None, date='2026-01-01', family='GPS'):
        db = analyzer.open_database(self.database)
        identity = hashlib.sha256(name.encode()).hexdigest()
        value = analyzer.base_log(self.root / (name + '.ulg'), self.root, identity, 1)
        message = {'id': name, 'text': name, 'title': name, 'groupKey': name, 'family': family,
                   'level': 'WARNING', 'isAlert': True, 'timestampSeconds': 0}
        value.update(droneID='one-controller', droneName='Synthetic drone', status='ok', date=date, durationSeconds=10, messages=[message])
        analyzer.remember_log(db, value)
        if client:
            db.execute('INSERT INTO log_clients VALUES(?,?)', (identity, client))
        db.commit(); db.close()
        return identity

    def query(self, **request):
        db = analyzer.open_database(self.database)
        try:
            return repository.query(db, request)
        finally:
            db.close()

    def test_clients_scope_every_query_kind_and_counts_without_identity_duplication(self):
        first = self.add('alpha', self.a, family='Batterie')
        second = self.add('beta', self.b, family='GNSS')
        self.add('unassigned')
        self.assertEqual(self.query()['totals']['droneCount'], 1)
        for client, wanted in ((self.a, first), (self.b, second)):
            for kind in ('logs', 'map'):
                result = self.query(kind=kind, scope={'clientID': client})
                self.assertEqual(result['totals']['logs'], 1)
                self.assertEqual([log['id'] for log in result['snapshot']['logs']], [wanted])
                self.assertEqual(result['snapshot']['logs'][0]['clientID'], client)
            self.assertEqual(self.query(kind='messages', scope={'clientID': client})['total'], 1)
            groups = self.query(kind='groups', scope={'clientID': client})
            self.assertEqual(groups['total'], 1)
            self.assertEqual(self.query(kind='group-keys', groupID=groups['groups'][0]['id'], scope={'clientID': self.a if client == self.b else self.b})['total'], 0)
            self.assertEqual(self.query(kind='drones', scope={'clientID': client})['drones'][0]['logCount'], 1)
        self.assertEqual(self.query(kind='catalogue', scope={'clientID': self.a})['families'], ['Batterie'])
        self.assertEqual(self.query(scope={'clientID': ''})['totals']['logs'], 1)
        self.assertEqual(self.query(scope={'clientID': self.a, 'families': ['Batterie']})['totals']['logs'], 1)
        self.assertEqual(self.query(scope={'clientID': self.a, 'families': ['GNSS']})['totals']['logs'], 0)

    def test_bulk_assignment_applies_entire_selection_over_page_limit(self):
        for index in range(205):
            self.add('item-%d' % index, self.a)
        result = clients.command(self.database, 'assign-client', {'scope': {'clientID': self.a}, 'clientID': self.b})
        self.assertEqual(result['assignedLogs'], 205)
        self.assertEqual(self.query(scope={'clientID': self.a})['totals']['logs'], 0)
        self.assertEqual(self.query(scope={'clientID': self.b})['totals']['logs'], 205)

    def test_subset_assignment_and_delete_unassign_without_removing_logs(self):
        first = self.add('one', self.a); self.add('two', self.a)
        result = clients.command(self.database, 'assign-client', {'scope': {'logIDs': [first]}, 'clientID': self.b})
        self.assertEqual(result['assignedLogs'], 1)
        result = clients.command(self.database, 'delete-client', {'id': self.b})
        self.assertEqual(result['unassignedLogs'], 1)
        self.assertEqual(self.query(scope={'clientID': ''})['totals']['logs'], 1)
        self.assertEqual(self.query()['totals']['logs'], 2)

    def test_duplicate_reanalysis_and_rename_preserve_assignment_outside_recorded_analysis(self):
        source = self.root / 'original'; source.mkdir()
        path = source / 'example.ulg'; path.write_bytes(synthetic_ulog())
        first = analyzer.scan(source, self.database, client_id=self.a)['logs'][0]
        duplicate = self.root / 'duplicate'; duplicate.mkdir()
        shutil.copyfile(path, duplicate / 'copy.ulg')
        analyzer.scan(duplicate, self.database, client_id=self.b)
        analyzer.scan(source, self.database, client_id=self.b)
        db = analyzer.open_database(self.database)
        db.execute("UPDATE logs SET parser_version='older'"); db.commit(); db.close()
        analyzer.scan(source, self.database, client_id=self.b)
        clients.command(self.database, 'rename-client', {'id': self.a, 'name': 'Renamed organization'})
        detail = analyzer.detail(first['id'], self.database)
        self.assertEqual(detail['clientID'], self.a)
        self.assertEqual(detail['clientName'], 'Renamed organization')
        db = analyzer.open_database(self.database)
        self.assertNotIn('clientID', json.loads(db.execute('SELECT summary FROM logs').fetchone()[0]))
        db.close()

    def test_legacy_additive_migration_and_client_cursor_invalidation(self):
        self.add('one', self.a); self.add('two', self.a)
        page = self.query(scope={'clientID': self.a}, limit=1)
        clients.command(self.database, 'rename-client', {'id': self.a, 'name': 'New name'})
        with self.assertRaisesRegex(ValueError, 'changé'):
            self.query(scope={'clientID': self.a}, limit=1, cursor=page['nextCursor'])
        db = analyzer.open_database(self.database)
        db.execute('DROP TABLE log_clients'); db.execute('DROP TABLE clients'); db.commit(); db.close()
        self.assertEqual(self.query(scope={'clientID': ''})['totals']['logs'], 2)

    def test_report_selection_and_privacy(self):
        secret_name = 'PRIVATE-CLIENT-NAME-9E80'
        clients.command(self.database, 'rename-client', {'id': self.a, 'name': secret_name})
        identity = self.add('alpha', self.a); self.add('beta', self.b)
        db = analyzer.open_database(self.database)
        detail = json.loads(db.execute('SELECT summary FROM logs WHERE id=?', (identity,)).fetchone()[0])
        detail.update(clientID=self.a, clientName=secret_name,
                      parameters={'CLIENT': secret_name, 'CLIENT_ID': self.a},
                      parameterDetails={'nested': {'clientName': secret_name, 'clientID': self.a}})
        db.execute('INSERT INTO flight_details VALUES(?,?,?)', (identity, analyzer.PARSER_VERSION, json.dumps(detail)))
        db.commit(); db.close()
        capture = self.root / 'capture'
        result = reports.capture_report(self.database, capture, {'query': {'scope': {'clientID': self.a}}, 'options': {'format': 'json'}})
        self.assertEqual(result['totalLogs'], 1)
        output = self.root / 'output'
        reports.prepare_report(capture, output)
        data = json.loads((output / 'rapport.json').read_text())
        self.assertEqual(data['logs'][0]['clientName'], secret_name)
        self.assertEqual(data['logs'][0]['clientID'], self.a)
        for option in ('excludeIdentity', 'excludePaths', 'excludeCoordinates'):
            capture = self.root / ('capture-' + option)
            destination = self.root / ('export-' + option)
            reports.capture_report(self.database, capture, {
                'query': {'scope': {'clientID': self.a}},
                'scopeDescription': secret_name + ' ' + self.a,
                'options': {'format': 'html', option: True, 'includeCachedDetails': True}})
            reports.prepare_report(capture, destination)
            for file in destination.rglob('*'):
                if file.is_file():
                    self.assertNotIn(secret_name.encode(), file.read_bytes(), file.name)
                    self.assertNotIn(self.a.encode(), file.read_bytes(), file.name)
            payload = json.loads((destination / 'rapport.json').read_text())
            self.assertEqual(len(payload['logs']), 1)
            self.assertNotIn('clientID', payload['logs'][0])
            self.assertNotIn('clientName', payload['logs'][0])
            self.assertNotIn('parameterDetails', payload['logs'][0])

    def test_clients_read_only_does_not_initialize_or_modify_database(self):
        db = analyzer.open_database(self.database)
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)'); db.close()
        before = self.database.read_bytes()
        with patch.object(clients, 'initialize', side_effect=AssertionError('No writes in clients list')):
            result = clients.command(self.database, 'clients', read_only=True)
        self.assertEqual(len(result['clients']), 2)
        self.assertEqual(self.database.read_bytes(), before)
        with self.assertRaisesRegex(ValueError, 'lecture seule'):
            clients.command(self.database, 'delete-client', {'id': self.a}, read_only=True)

    def test_old_schema_readonly_queries_use_temporary_compatibility_only(self):
        self.add('legacy')
        self.query()  # canonical projection is ready, as in a 0.7 library
        db = analyzer.open_database(self.database)
        for table in ('log_clients', 'clients', 'spatial_tracks'):
            db.execute('DROP TABLE ' + table)
        db.commit(); db.execute('PRAGMA wal_checkpoint(TRUNCATE)'); db.close()
        original = self.database.read_bytes()
        reader = analyzer.open_database(self.database, read_only=True)
        try:
            unassigned = repository.query(reader, {'scope': {'clientID': ''}}, read_only=True)
            self.assertEqual(unassigned['totals']['logs'], 1)
            other = repository.query(reader, {'scope': {'clientID': self.a}}, read_only=True)
            self.assertEqual(other['totals']['logs'], 0)
            page = repository.query(reader, {'kind': 'map', 'scope': {'clientID': ''},
                'proximity': {'latitude': 1, 'longitude': 2, 'radiusMeters': 10}}, read_only=True)
            self.assertEqual(page['proximityUnavailableLogs'], 1)
            self.assertFalse(reader.execute("SELECT 1 FROM main.sqlite_master WHERE name='log_clients'").fetchone())
        finally:
            reader.close()
        self.assertEqual(self.database.read_bytes(), original)

    def test_failed_imports_are_visible_in_client_and_retry_preserves_prior_attribution(self):
        folder = self.root / 'unreadable'; folder.mkdir()
        path = folder / 'source.ulg'; path.write_bytes(synthetic_ulog())
        with patch.object(analyzer, 'digest_file', side_effect=PermissionError('fixture unavailable')):
            failed = analyzer.scan(folder, self.database, client_id=self.a)
            analyzer.scan(folder, self.database, client_id=self.b)
        self.assertEqual(failed['logs'][0]['clientID'], self.a)
        self.assertEqual(self.query(scope={'clientID': self.a})['totals']['logs'], 1)
        self.assertEqual(self.query(scope={'clientID': self.b})['totals']['logs'], 0)
        analyzer.scan(folder, self.database, client_id=self.b)
        self.assertEqual(self.query(scope={'clientID': self.b})['totals']['logs'], 1)
        db = analyzer.open_database(self.database)
        self.assertEqual(db.execute('SELECT COUNT(*) FROM log_clients').fetchone()[0], 1)
        db.close()
        bad = self.root / 'corrupt'; bad.mkdir(); (bad / 'corrupt.ulg').write_bytes(b'not a ulog')
        corrupt = analyzer.scan(bad, self.database, client_id=self.a)
        self.assertEqual(next(log for log in corrupt['logs'] if log['status'] == 'error')['clientID'], self.a)

    def test_directory_import_failure_keeps_client_context(self):
        folder = self.root / 'directory-errors'; folder.mkdir()
        def walk(root, onerror, followlinks):
            onerror(PermissionError(13, 'fixture directory unavailable', str(folder / 'inaccessible')))
            yield str(root), [], []
        with patch.object(analyzer.os, 'walk', side_effect=walk):
            analyzer.scan(folder, self.database, client_id=self.a)
            analyzer.scan(folder, self.database, client_id=self.b)
        page = self.query(scope={'clientID': self.a})
        self.assertEqual(page['totals']['logs'], 1)
        self.assertEqual(page['snapshot']['logs'][0]['clientID'], self.a)
        self.assertEqual(self.query(scope={'clientID': self.b})['totals']['logs'], 0)

    def test_reset_retains_every_original_unknown_file_and_writer_lock(self):
        source = self.root / 'Collected Logs'; source.mkdir()
        path = source / 'example.ulg'; raw = synthetic_ulog(); path.write_bytes(raw)
        original = self.root / 'original.ulg'; original.write_bytes(raw)
        lock = self.root / '.library-writer.lock'; lock.write_text('stable')
        inode = lock.stat().st_ino
        opaque = self.root / 'unowned.sqlite'; opaque.write_bytes(b'unknown')
        analyzer.scan(source, self.database, client_id=self.a)
        clients.retire_all_sources(self.database)
        result = clients.reset_library(self.database, self.root)
        self.assertFalse(result['originalsDeleted'])
        self.assertEqual(self.query()['totals']['logs'], 0)
        self.assertEqual(len(clients.command(self.database, 'clients')['clients']), 2)
        self.assertEqual(path.read_bytes(), raw); self.assertEqual(original.read_bytes(), raw)
        self.assertEqual(opaque.read_bytes(), b'unknown'); self.assertEqual(lock.stat().st_ino, inode)
        clients.reset_library(self.database, self.root, all_settings=True)
        self.assertEqual(clients.command(self.database, 'clients')['clients'], [])
        self.assertEqual(path.read_bytes(), raw)
        self.assertEqual(analyzer.scan(source, self.database)['importStats']['imported'], 1)


class ProximityTests(ClientTests):
    def write_track(self, filename, points, client=None):
        folder = self.root / filename; folder.mkdir()
        path = folder / 'track.ulg'; path.write_bytes(track_ulog(points))
        log = analyzer.scan(folder, self.database, client_id=client)['logs']
        return hashlib.sha256(path.read_bytes()).hexdigest(), path

    def search(self, client=None, **kwargs):
        return self.query(kind='map', proximity={'latitude': 1, 'longitude': 2, 'radiusMeters': 10},
                          scope={'clientID': client}, **kwargs)

    def test_crossing_segment_without_inside_vertex_and_dateline(self):
        identity, _ = self.write_track('crossing', [(0, 1, 1.999, 6), (1, 1, 2.001, 6)])
        page = self.search()
        self.assertEqual([log['id'] for log in page['snapshot']['logs']], [identity])
        self.assertEqual(page['proximityUnavailableLogs'], 0)
        track = {'points': [{'latitude': 0, 'longitude': 179.9, 'timeSeconds': 0, 'segment': 0},
                            {'latitude': 0, 'longitude': -179.9, 'timeSeconds': 1, 'segment': 0}]}
        self.assertTrue(proximity.intersects(track, {'latitude': 0, 'longitude': 180, 'radiusMeters': 100}))
        self.assertFalse(proximity.intersects(track, {'latitude': 0, 'longitude': 0, 'radiusMeters': 100}))

    def test_gap_and_invalid_fix_are_never_bridged(self):
        self.write_track('gap', [(0, 1, 1.999, 6), (30, 1, 2.001, 6)])
        self.write_track('invalid', [(0, 1, 1.999, 6), (1, 1, 2, 0), (2, 1, 2.001, 6)])
        self.assertEqual(self.search()['totals']['logs'], 0)

    def test_full_resolution_not_preview_and_complete_cache_after_source_removal(self):
        points = [(i*.01, 1.01, 2, 6) for i in range(1000)]
        points[500] = (5.00, 1, 2, 6)
        identity, path = self.write_track('dense', points)
        summary = self.query()['snapshot']['logs'][0]
        self.assertFalse(any(point['latitude'] == 1 for point in summary['track']['points']))
        self.assertEqual(self.search()['totals']['logs'], 1)
        path.unlink()
        self.assertEqual(self.search()['totals']['logs'], 1)
        db = analyzer.open_database(self.database); db.execute('DELETE FROM spatial_tracks'); db.commit(); db.close()
        page = self.search()
        self.assertEqual(page['totals']['logs'], 0)
        self.assertEqual(page['proximityUnavailableLogs'], 1)

    def test_before_limit_and_scope_sources_verified(self):
        wanted, _ = self.write_track('wanted', [(0, 1, 1.999, 6), (1, 1, 2.001, 6)], self.a)
        for index in range(85):
            self.add('newer-%d' % index, self.b, date='2035-01-01')
        page = self.search()
        self.assertEqual([log['id'] for log in page['snapshot']['logs']], [wanted])
        self.assertEqual(page['proximityUnavailableLogs'], 85)
        self.assertEqual(self.search(self.a)['proximityUnavailableLogs'], 0)
        self.assertEqual(self.search(self.b)['totals']['logs'], 0)
        changed_id, changed_path = self.write_track('changed', [(0, 1, 2, 6), (1, 1, 2, 6)])
        changed_path.write_bytes(b'modified content')
        db = analyzer.open_database(self.database); db.execute('DELETE FROM spatial_tracks WHERE log_id=?', (changed_id,)); db.commit(); db.close()
        self.assertEqual(self.search(self.a)['totals']['logs'], 1)
        self.assertEqual(self.search()['proximityUnavailableLogs'], 86)

    def test_legacy_track_writable_query_caches_exact_source_for_later_offline_search(self):
        identity, path = self.write_track('upgraded', [(0, 1, 1.999, 6), (1, 1, 2.001, 6)])
        self.query()  # same prepared-index prerequisite as the native library
        db = analyzer.open_database(self.database)
        db.execute('DELETE FROM spatial_tracks'); db.commit(); db.close()
        request = {'kind': 'map', 'proximity': {'latitude': 1, 'longitude': 2, 'radiusMeters': 10}}
        reader = analyzer.open_database(self.database, read_only=True)
        self.assertEqual(repository.query(reader, request, read_only=True)['totals']['logs'], 1)
        self.assertEqual(reader.execute('SELECT COUNT(*) FROM spatial_tracks').fetchone()[0], 0)
        reader.close()
        self.assertEqual(self.search()['totals']['logs'], 1)  # writable preparation
        path.unlink()
        reader = analyzer.open_database(self.database, read_only=True)
        try:
            with patch.object(analyzer, 'ULog', side_effect=AssertionError('Must use cached complete GPS')):
                self.assertEqual(repository.query(reader, request, read_only=True)['totals']['logs'], 1)
        finally:
            reader.close()


if __name__ == '__main__':
    unittest.main()
