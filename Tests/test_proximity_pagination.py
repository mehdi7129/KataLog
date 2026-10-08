"""Exact spatial selection is reused across pages, including helper processes."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_proximity as proximity
import library_repository as repository
import proximity_cache

AREA = {'latitude': 45.0, 'longitude': 4.0, 'radiusMeters': 100}
TRACK = {'points': [{'latitude': 45.0, 'longitude': 4.0, 'timeSeconds': 0, 'segment': 0}]}


class ProximityPaginationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='katalog-proximity-pages-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.database = self.root / 'library.sqlite'
        self.db = analyzer.open_database(self.database)
        self.addCleanup(self.db.close)
        repository.initialize(self.db)

    def populate(self, count):
        identities = []
        for index in range(count):
            identity = hashlib.sha256(str(index).encode()).hexdigest()
            log = analyzer.base_log(self.root / (str(index) + '.ulg'), self.root, identity, 1)
            log.update(status='ok', date='2026-09-01', track=TRACK)
            analyzer.remember_log(self.db, log)
            proximity.cache_track(self.db, identity, TRACK)
            identities.append(identity)
        self.db.commit()
        repository.initialize(self.db)
        return identities

    def page(self, cache=None, **values):
        return repository.query(self.db, {'kind': 'map-overview', 'limit': 5000, 'proximity': AREA, **values}, read_only=True,
                                proximity_cache=cache)

    def test_5001_cached_tracks_are_decoded_once_across_pages(self):
        identities = self.populate(5001)
        began = time.perf_counter()
        with patch.object(proximity, 'complete_track', wraps=proximity.complete_track) as complete:
            first = self.page()
            second = self.page(cursor=first['nextCursor'])
        self.assertEqual((len(first['markers']), len(second['markers'])), (5000, 1))
        self.assertEqual({row['id'] for row in first['markers'] + second['markers']}, set(identities))
        self.assertIsNone(second['nextCursor'])
        self.assertEqual(complete.call_count, 5001)
        print({'proximityTracks': len(identities), 'completeTrackCalls': complete.call_count,
               'seconds': time.perf_counter() - began})

    def test_cli_pages_share_disposable_cache_across_processes(self):
        identities = self.populate(11)
        request = self.root / 'request.json'
        output = self.root / 'result.json'
        cache = self.root / 'selection.jsonl'
        counts = self.root / 'calls.txt'
        module = Path(analyzer.__file__).parent
        # Run the actual CLI in a fresh process for each page, instrumenting
        # only full-track calls. Public request/result JSON remains unchanged.
        code = '''import sys
from pathlib import Path
sys.path.insert(0, sys.argv.pop(1))
import analyzer, library_proximity
original = library_proximity.complete_track
counter = Path(sys.argv.pop(1))
def counted(*args, **kwargs):
    with counter.open('a') as stream: stream.write('track\\n')
    return original(*args, **kwargs)
library_proximity.complete_track = counted
raise SystemExit(analyzer.main())
'''
        cursor, found = None, []
        while True:
            request.write_text(json.dumps({'kind': 'map-overview', 'limit': 5, 'proximity': AREA, 'cursor': cursor}))
            subprocess.run([sys.executable, '-c', code, str(module), str(counts), 'query', '--database', str(self.database),
                            '--request', str(request), '--output', str(output), '--read-only', '--proximity-cache', str(cache)],
                           check=True, capture_output=True, text=True)
            result = json.loads(output.read_text())
            found.extend(row['id'] for row in result['markers'])
            cursor = result['nextCursor']
            if cursor is None:
                break
        self.assertEqual(set(found), set(identities))
        self.assertEqual(len(counts.read_text().splitlines()), len(identities))

    def test_scope_radius_and_revision_invalidate_cached_selection(self):
        identities = self.populate(3)
        with patch.object(proximity, 'complete_track', wraps=proximity.complete_track) as complete:
            self.page()
            self.page()
            self.assertEqual(complete.call_count, 3)
            self.assertEqual(self.page(proximity={**AREA, 'latitude': 0})['markers'], [])
            self.assertEqual(complete.call_count, 6)
            self.assertEqual(len(self.page(scope={'logIDs': identities[:1]})['markers']), 1)
            self.assertEqual(complete.call_count, 7)
            self.db.execute("UPDATE kl_meta SET value=CAST(value AS INTEGER)+1 WHERE key='revision'")
            self.db.commit()
            self.page(scope={'logIDs': identities[:1]})
            self.assertEqual(complete.call_count, 8)

    def test_missing_source_becomes_available_without_database_revision(self):
        sys.path.insert(0, str(Path(__file__).parent))
        from fixture_ulog import synthetic_ulog
        payload = synthetic_ulog()
        identity = hashlib.sha256(payload).hexdigest()
        source = self.root / 'later.ulg'
        analyzer.remember_log(self.db, analyzer.base_log(source, self.root, identity, len(payload)))
        self.db.execute('INSERT INTO sources VALUES(?,?)', (identity, str(source)))
        self.db.commit()
        repository.initialize(self.db)
        cache = self.root / 'selection.jsonl'
        first = self.page(cache=cache, proximity={**AREA, 'radiusMeters': 20_100_000})
        self.assertEqual(first['proximityUnavailableLogs'], 1)
        self.assertFalse(cache.exists())
        source.write_bytes(payload)
        second = self.page(cache=cache, proximity={**AREA, 'radiusMeters': 20_100_000})
        self.assertEqual(first['revision'], second['revision'])
        self.assertEqual(second['proximityUnavailableLogs'], 0)
        # Read-only parsing did not retain a full trajectory: source availability
        # must still be reconsidered on the next page/read.
        self.assertFalse(cache.exists())
        source.unlink()
        self.assertEqual(self.page(cache=cache)['proximityUnavailableLogs'], 1)

    def test_corrupt_or_oversized_cache_never_changes_results(self):
        identities = self.populate(3)
        cache = self.root / 'selection.jsonl'
        self.page(cache=cache)
        raw = cache.read_text()
        for corrupted in (raw.rsplit('\n', 2)[0], raw + 'trailing', raw.replace('{"count": 3}', '{"count": 2}')):
            cache.write_text(corrupted)
            self.db.execute('DELETE FROM kl_proximity_metadata')
            self.db.commit()
            result = self.page(cache=cache)
            self.assertEqual({row['id'] for row in result['markers']}, set(identities))
        cache.unlink()
        self.db.execute('DELETE FROM kl_proximity_metadata')
        self.db.commit()
        with patch.object(proximity_cache, 'MAX_BYTES', 128):
            self.assertEqual(len(self.page(cache=cache)['markers']), 3)
        self.assertFalse(cache.exists())

    def test_interruption_does_not_publish_partial_cache(self):
        identities = self.populate(3)
        cache = self.root / 'selection.jsonl'
        original = proximity.complete_track
        count = 0
        def interrupted(*args, **kwargs):
            nonlocal count
            count += 1
            if count == 2:
                raise InterruptedError('Synthetic cancellation')
            return original(*args, **kwargs)
        with patch.object(proximity, 'complete_track', side_effect=interrupted), self.assertRaises(InterruptedError):
            self.page(cache=cache)
        self.assertFalse(cache.exists())
        self.assertEqual({row['id'] for row in self.page(cache=cache)['markers']}, set(identities))

    def test_direct_query_cache_cannot_replace_library_or_sources(self):
        self.populate(1)
        source = self.root / 'original.ulg'
        source.write_bytes(b'preserved original')
        identity = self.db.execute('SELECT id FROM logs').fetchone()[0]
        self.db.execute('INSERT INTO sources VALUES(?,?)', (identity, str(source)))
        self.db.commit()
        repository.initialize(self.db)
        config = self.root / 'settings.json'
        config.write_text('{"schemaVersion":1}')
        for target in (self.database, source, config):
            before = target.read_bytes()
            with self.subTest(target=target.name), self.assertRaises(ValueError):
                self.page(cache=target)
            self.assertEqual(target.read_bytes(), before)
        self.assertEqual(self.db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')

    def test_unwritable_cache_cleanup_does_not_fail_query(self):
        self.populate(1)
        cache = self.root / 'selection.jsonl'
        original = Path.unlink
        def refuse_cache_cleanup(path, *args, **kwargs):
            if path.name.startswith('.katalog-proximity-'):
                raise PermissionError('Synthetic cache cleanup refusal')
            return original(path, *args, **kwargs)
        with patch.object(proximity_cache.os, 'replace', side_effect=PermissionError('Synthetic publication refusal')), \
             patch.object(Path, 'unlink', refuse_cache_cleanup):
            self.assertEqual(len(self.page(cache=cache)['markers']), 1)
        self.assertFalse(cache.exists())


if __name__ == '__main__':
    unittest.main()
