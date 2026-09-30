"""Archives/reassociation/cache are reversible and preserve original ULogs."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path[:0] = [str(Path(__file__).resolve().parent), str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources')]
import analyzer
import library_archives as archives
import library_repository as repository
from fixture_ulog import synthetic_ulog


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='katalog-archives-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.library = self.root / 'library'; self.library.mkdir()
        self.source = self.root / 'sources'; self.source.mkdir()
        self.original = self.source / 'fixture.ulg'; self.original.write_bytes(synthetic_ulog())
        self.database = self.library / 'library.sqlite'
        self.log = analyzer.scan(self.source, self.database)['logs'][0]
        prepared = analyzer.open_database(self.database)
        try:
            repository.initialize(prepared)
        finally:
            prepared.close()
        self.destination = self.root / 'archive'
        self.signature = analyzer.stat_signature(self.original.stat())
        self.contents = self.original.read_bytes()

    def test_archive_atomic_sha_reuse_originals_preserved(self):
        result = archives.archive_logs(self.database, self.library, self.destination, [self.log['id']])
        self.assertEqual((result['completed'], result['failed'], result['reused']), (1, 0, 0))
        self.assertFalse(result['originalsDeleted'])
        target = self.destination / (self.log['id'] + '.ulg')
        self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), self.log['id'])
        self.assertEqual(self.original.read_bytes(), self.contents)
        self.assertEqual(analyzer.stat_signature(self.original.stat()), self.signature)
        second = archives.archive_logs(self.database, self.library, self.destination, [self.log['id']])
        self.assertEqual((second['completed'], second['reused']), (1, 1))
        self.assertEqual(len(list(self.destination.glob('*.ulg'))), 1)
        self.original.unlink()
        self.assertEqual(analyzer.detail(self.log['id'], self.database)['status'], 'ok')

    def test_scan_optional_archive_copies_even_cached_import_and_reuses_one_copy(self):
        progress = self.root / 'progress.json'
        phases = []
        original_json = analyzer.atomic_json
        def record_progress(path, value):
            if Path(path) == progress:
                phases.append(value.copy())
            return original_json(path, value)
        with patch.object(analyzer, 'atomic_json', side_effect=record_progress):
            result = analyzer.scan(self.source, self.database, progress=progress, skip_snapshot=True, archive_destination=self.destination)
        self.assertEqual(result['importStats']['unchanged'], 1)
        self.assertEqual(result['archiveResult']['completed'], 1)
        self.assertEqual(result['importStats']['archiveCompleted'], 1)
        self.assertTrue(any(row.get('phase') == 'archiving' for row in phases))
        self.assertEqual(phases[-1]['completed'], 1)
        target = self.destination / (self.log['id'] + '.ulg')
        self.assertEqual(target.read_bytes(), self.contents)
        self.assertEqual(analyzer.stat_signature(self.original.stat()), self.signature)
        repeated = analyzer.scan(self.source, self.database, skip_snapshot=True, archive_destination=self.destination)
        self.assertEqual(repeated['archiveResult']['reused'], 1)
        self.assertEqual(len(list(self.destination.glob('*.ulg'))), 1)
        self.original.unlink()
        self.assertEqual(analyzer.detail(self.log['id'], self.database)['status'], 'ok')

    def test_scan_archive_failure_refuses_import_without_changing_previous_analysis(self):
        before = analyzer.open_database(self.database, read_only=True)
        try:
            rows = [tuple(row) for row in before.execute('SELECT * FROM logs')]
            revisions = [tuple(row) for row in before.execute('SELECT * FROM analysis_revisions')]
        finally: before.close()
        with patch.object(archives.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 1})()):
            result = analyzer.scan(self.source, self.database, skip_snapshot=True, archive_destination=self.destination)
        self.assertEqual(result['archiveResult']['failed'], 1)
        self.assertEqual(result['importStats']['archiveFailed'], 1)
        self.assertEqual(result['importStats']['failed'], 1)
        self.assertEqual(result['importStats']['unchanged'], 0)
        self.assertIn('Espace', result['archiveResult']['errors'][0]['error'])
        self.assertEqual(list(self.destination.glob('*.ulg')), [])
        self.assertEqual(list(self.destination.glob('*.partial')), [])
        self.assertEqual(self.original.read_bytes(), self.contents)
        self.assertEqual(analyzer.stat_signature(self.original.stat()), self.signature)
        after = analyzer.open_database(self.database, read_only=True)
        try:
            self.assertEqual([tuple(row) for row in after.execute('SELECT * FROM logs')], rows)
            self.assertEqual([tuple(row) for row in after.execute('SELECT * FROM analysis_revisions')], revisions)
        finally: after.close()

    def test_archive_is_published_and_sha_checked_before_parser_preserving_origin(self):
        fresh = self.library / 'fresh.sqlite'
        original_analyze = analyzer.analyze_file
        calls = []
        def verify_first(path, root, identity, **kwargs):
            path = Path(path)
            self.assertEqual(path, self.destination / (self.log['id'] + '.ulg'))
            self.assertTrue(path.is_file())
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), identity)
            self.assertEqual(list(self.destination.glob('*.partial')), [])
            self.assertEqual(kwargs['origin_context']['fileName'], 'fixture.ulg')
            self.assertEqual(kwargs['origin_context']['sourcePaths'], [str(self.original)])
            calls.append(str(path))
            return original_analyze(path, root, identity, **kwargs)
        with patch.object(analyzer, 'analyze_file', side_effect=verify_first):
            result = analyzer.scan(self.source, fresh, archive_destination=self.destination)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result['importStats']['imported'], 1)
        self.assertEqual(result['logs'][0]['fileName'], 'fixture.ulg')
        self.assertEqual(result['logs'][0]['droneID'], self.log['droneID'])
        self.assertEqual(set(result['logs'][0]['sourcePaths']), {str(self.original), calls[0]})

    def test_removing_sd_after_archive_publication_does_not_interrupt_import(self):
        fresh = self.library / 'fresh.sqlite'
        original_prepare = archives.archive_copy_prepared
        def remove_sd(*args, **kwargs):
            result = original_prepare(*args, **kwargs)
            self.original.unlink()
            return result
        with patch.object(archives, 'archive_copy_prepared', side_effect=remove_sd):
            result = analyzer.scan(self.source, fresh, archive_destination=self.destination)
        self.assertEqual((result['importStats']['imported'], result['importStats']['failed']), (1, 0))
        value = result['logs'][0]
        self.assertEqual(value['fileName'], 'fixture.ulg')
        self.assertEqual(value['droneID'], self.log['droneID'])
        self.assertEqual(value['date'], self.log['date'])
        self.assertEqual({item['state'] for item in value['sourceAvailability']}, {'missing', 'present'})
        detailed = analyzer.detail(value['id'], fresh)
        self.assertEqual(set(detailed['sourcePaths']), set(value['sourcePaths']))
        self.assertEqual(detailed['status'], 'ok')

    def test_archive_failure_does_not_parse_or_publish_new_analysis(self):
        fresh = self.library / 'fresh.sqlite'
        with patch.object(archives.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 1})()), patch.object(analyzer, 'analyze_file', side_effect=AssertionError('Copy must succeed before parser')):
            result = analyzer.scan(self.source, fresh, archive_destination=self.destination)
        self.assertEqual(result['logs'], [])
        self.assertEqual(result['importStats']['failed'], 1)
        db = analyzer.open_database(fresh, read_only=True)
        try:
            for table in ('logs', 'flight_details', 'analysis_revisions', 'sources'):
                self.assertEqual(db.execute('SELECT COUNT(*) FROM ' + table).fetchone()[0], 0)
        finally: db.close()
        self.assertEqual(list(self.destination.glob('*.partial')), [])

    def test_card_identity_and_name_survive_removable_source_loss(self):
        import shutil
        card = self.root / 'card'
        (card / 'data').mkdir(parents=True)
        (card / 'data/name.txt').write_text('Invented card name')
        folder = card / 'log/2026-08-03'; folder.mkdir(parents=True)
        original = folder / '12_34_56.ulg'; original.write_bytes(synthetic_ulog(include_uuid=False))
        identity = hashlib.sha256(original.read_bytes()).hexdigest()
        expected = analyzer.analyze_file(original, card, identity)
        prepare = archives.archive_copy_prepared
        def remove_card(*args, **kwargs):
            result = prepare(*args, **kwargs)
            shutil.rmtree(card)
            return result
        with patch.object(archives, 'archive_copy_prepared', side_effect=remove_card):
            result = analyzer.scan(card, self.library / 'card.sqlite', archive_destination=self.destination)
        value = result['logs'][0]
        for field in ('id', 'droneID', 'droneName', 'date', 'dateSource', 'fileName'):
            self.assertEqual(value[field], expected[field], field)
        self.assertTrue(value['droneID'].startswith('card:'))
        self.assertEqual(value['droneName'], 'Invented card name')

    def test_preparser_crash_recovery_keeps_copy_and_origin_without_fake_analysis(self):
        self.destination.mkdir()
        fresh = self.library / 'fresh.sqlite'
        db = analyzer.open_database(fresh); db.close()
        target = self.destination / (self.log['id'] + '.ulg'); target.write_bytes(self.contents)
        job = {'logID': self.log['id'], 'path': str(target), 'preparedImport': True,
               'originContext': analyzer.base_log(self.original, self.source, self.log['id'], len(self.contents)), 'state': 'pending'}
        state = {'archiveVersion': 1, 'destination': str(self.destination), 'jobs': [job]}
        (self.library / '.archive-journal.json').write_text(json.dumps(state))
        result = archives.recover_archive(fresh, self.library)
        self.assertEqual(result['readyForImport'], 1)
        self.assertEqual(result['completed'], 0)
        self.assertEqual(target.read_bytes(), self.contents)
        recovered = json.loads((Path(result['recoveryDirectory']) / 'journal.json').read_text())
        self.assertEqual(recovered['jobs'][0]['originContext']['fileName'], 'fixture.ulg')
        db = analyzer.open_database(fresh, read_only=True)
        try: self.assertEqual(db.execute('SELECT COUNT(*) FROM logs').fetchone()[0], 0)
        finally: db.close()

    def test_scan_default_reference_mode_makes_no_additional_copy(self):
        with patch.object(archives, 'archive_logs', side_effect=AssertionError('Reference mode must not copy')), patch.object(archives, 'archive_copy_prepared', side_effect=AssertionError('Reference mode must not copy')):
            result = analyzer.scan(self.source, self.database, skip_snapshot=True)
        self.assertNotIn('archiveResult', result)
        self.assertNotIn('archiveRequested', result['importStats'])
        self.assertFalse(self.destination.exists())

    def test_cli_scan_optional_archive_keeps_atomic_copy_contract(self):
        output = self.root / 'output.json'
        self.assertEqual(analyzer.main(['scan', '--folder', str(self.source), '--database', str(self.database), '--output', str(output), '--skip-snapshot', '--archive-destination', str(self.destination)]), 0)
        result = json.loads(output.read_text())
        self.assertEqual(result['archiveResult']['completed'], 1)
        self.assertEqual(hashlib.sha256((self.destination / (self.log['id'] + '.ulg')).read_bytes()).hexdigest(), self.log['id'])

    def test_storage_source_availability_does_not_trust_new_hash_for_old_provenance(self):
        self.original.write_bytes(synthetic_ulog(drone_name='Different fixture name'))
        analyzer.scan(self.source, self.database)
        db = analyzer.open_database(self.database)
        try:
            db.execute('INSERT OR IGNORE INTO sources VALUES(?,?)', (self.log['id'], str(self.original)))
            db.commit()
        finally:
            db.close()
        result = archives.storage_info(self.database, self.library)
        original = next(item for item in result['sources'] if item['logID'] == self.log['id'])
        self.assertEqual(original['availability']['state'], 'modified')

    def test_conflicting_archive_is_not_replaced(self):
        self.destination.mkdir()
        target = self.destination / (self.log['id'] + '.ulg'); target.write_bytes(b'preexisting other content')
        result = archives.archive_logs(self.database, self.library, self.destination, [self.log['id']])
        self.assertEqual(result['failed'], 1)
        self.assertEqual(target.read_bytes(), b'preexisting other content')
        self.assertEqual(self.original.read_bytes(), self.contents)

    def test_insufficient_space_preserves_sources_and_no_published_copy(self):
        with patch.object(archives.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 1})()):
            result = archives.archive_logs(self.database, self.library, self.destination, [self.log['id']])
        self.assertEqual(result['failed'], 1)
        self.assertIn('Espace', result['jobs'][0]['error'])
        self.assertEqual(list(self.destination.glob('*.ulg')), [])
        self.assertEqual(self.original.read_bytes(), self.contents)

    def test_source_mutation_during_copy_refuses_publication(self):
        original_copy = archives.shutil.copyfile
        def mutate(source, target):
            original_copy(source, target)
            Path(source).write_bytes(b'simulated mutable source')
        with patch.object(archives.shutil, 'copyfile', side_effect=mutate):
            result = archives.archive_logs(self.database, self.library, self.destination, [self.log['id']])
        self.assertEqual(result['failed'], 1)
        self.assertEqual(list(self.destination.glob('*.ulg')), [])
        self.assertEqual(list(self.destination.glob('*.partial')), [])

    def test_reassociate_content_only_preserves_history_and_ignores_unrelated(self):
        relocated = self.root / 'relocated'; relocated.mkdir()
        target = relocated / 'renamed.ULG'; target.write_bytes(self.contents)
        (relocated / 'unrelated.ulg').write_bytes(b'unrelated')
        self.original.unlink()
        result = archives.reassociate(self.database, relocated)
        self.assertEqual((result['matched'], result['unrelated']), (1, 1))
        self.assertEqual(result['errors'], [])
        self.assertEqual(analyzer.detail(self.log['id'], self.database)['droneID'], self.log['droneID'])
        db = analyzer.open_database(self.database)
        try:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM logs').fetchone()[0], 1)
            paths = {row[0] for row in db.execute('SELECT path FROM sources')}
            self.assertEqual(paths, {str(self.original), str(target)})
        finally: db.close()

    def test_cleanup_selected_detail_cache_is_reversible_only_cache_changes(self):
        detail = analyzer.detail(self.log['id'], self.database)
        cleaned = archives.clean_detail_cache(self.database, self.library, [self.log['id']])
        self.assertEqual(cleaned['removedCount'], 1)
        db = analyzer.open_database(self.database)
        try:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM flight_details').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM logs').fetchone()[0], 1)
        finally: db.close()
        self.original.unlink()
        restored = archives.restore_detail_cache(self.database, cleaned['recoveryDirectory'])
        self.assertEqual(restored['restoredCount'], 1)
        self.assertEqual(analyzer.detail(self.log['id'], self.database)['parameters'], detail['parameters'])
        self.assertEqual(archives.restore_detail_cache(self.database, cleaned['recoveryDirectory'])['skippedCount'], 1)

    def test_cache_maintenance_publishes_event_revision_for_read_only_queries(self):
        analyzer.detail(self.log['id'], self.database)
        def query():
            db = analyzer.open_database(self.database, read_only=True)
            try: return repository.query(db, {'queryVersion': 1, 'kind': 'events'}, read_only=True)
            finally: db.close()
        cached = query()
        self.assertEqual(cached['total'], 1)
        cleaned = archives.clean_detail_cache(self.database, self.library, [self.log['id']])
        empty = query()
        self.assertEqual(empty['total'], 0)
        self.assertEqual(empty['coverage']['unavailableLogs'], 1)
        self.assertGreater(empty['revision'], cached['revision'])
        archives.restore_detail_cache(self.database, cleaned['recoveryDirectory'])
        restored = query()
        self.assertEqual(restored['total'], 1)
        self.assertGreater(restored['revision'], empty['revision'])

    def test_source_maintenance_does_not_leave_read_only_queries_dirty(self):
        analyzer.detail(self.log['id'], self.database)
        archives.archive_logs(self.database, self.library, self.destination, [self.log['id']])
        archives.reassociate(self.database, self.destination)
        db = analyzer.open_database(self.database, read_only=True)
        try:
            result = repository.query(db, {'queryVersion': 1, 'kind': 'events'}, read_only=True)
            self.assertEqual(result['total'], 1)
            self.assertEqual(len(result['occurrences'][0]['sourcePaths']), 2)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM kl_dirty').fetchone()[0], 0)
        finally: db.close()

    def test_corrupt_cache_recovery_refused(self):
        analyzer.detail(self.log['id'], self.database)
        cleaned = archives.clean_detail_cache(self.database, self.library, [self.log['id']])
        (Path(cleaned['recoveryDirectory']) / 'details.sqlite').write_bytes(b'corrupt')
        with self.assertRaises(ValueError):
            archives.restore_detail_cache(self.database, cleaned['recoveryDirectory'])

    def test_interrupted_archive_can_relink_published_copy_and_keep_partial_in_recovery(self):
        self.destination.mkdir()
        target = self.destination / (self.log['id'] + '.ulg'); target.write_bytes(self.contents)
        partial = self.destination / '.katalog-archive-test.partial'; partial.write_bytes(b'interrupted')
        state = {'archiveVersion': 1, 'destination': str(self.destination), 'jobs': [{'logID': self.log['id'], 'path': str(target), 'temporary': str(partial), 'state': 'pending'}]}
        (self.library / '.archive-journal.json').write_text(json.dumps(state))
        recovered = archives.recover_archive(self.database, self.library)
        self.assertTrue(recovered['recovered']); self.assertEqual(recovered['completed'], 1)
        self.assertFalse(partial.exists())
        self.assertEqual(len(list(self.library.glob('recovery-archive-*/.katalog-archive-test.partial'))), 1)
        self.assertTrue(self.original.exists())

    def test_storage_manifest_is_bounded_and_distinguishes_cache_sources_db(self):
        analyzer.detail(self.log['id'], self.database)
        result = archives.storage_info(self.database, self.library, limit=1)
        self.assertEqual(result['logCount'], 1); self.assertEqual(result['detailCacheCount'], 1)
        self.assertGreater(result['databaseBytes'], 0); self.assertGreater(result['detailCacheBytes'], 0)
        self.assertEqual(result['sources'][0]['availability']['state'], 'present')
        self.assertEqual(result['sources'][0]['sizeBytes'], len(self.contents))


if __name__ == '__main__': unittest.main()
