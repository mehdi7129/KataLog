"""Repeatable synthetic 50k-summary/5M-message query oracle (no real ULogs).

Example: python Tests/benchmark_library_repository.py --logs 50000 --messages 100
         --drones 500 --repeats 5 --output /tmp/katalog-benchmark.json
The temporary library is removed unless --work specifies an owned test folder.
"""
from __future__ import annotations
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import resource
import shutil
import statistics
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Sources/KataLog/Resources'))
import analyzer
import library_repository as repository


def run(root, logs, messages_per_log, drones, repeats, reuse=False, query_release_file=None):
    root.mkdir(parents=True, exist_ok=True)
    database = root / 'library.sqlite'
    if database.exists() and not reuse:
        raise ValueError('Le dossier de benchmark doit être neuf.')
    if reuse and not database.exists():
        raise ValueError('La bibliothèque synthétique préparée est absente.')
    db = analyzer.open_database(database)
    if reuse and db.execute('SELECT COUNT(*) FROM logs').fetchone()[0] != logs:
        raise ValueError('Le nombre de logs de la fixture préparée ne correspond pas au banc.')
    source_drones = drones - 2 if drones >= 4 else drones
    warning = [index for index in range(messages_per_log) if index % 4 == 0]
    records = [{'id': str(index), 'text': 'Synthetic alert %02d' % index,
        'family': 'Family-%d' % (index % 10), 'level': 'WARNING' if index in warning else 'INFO',
        'isAlert': index in warning, 'timestampSeconds': index,
        'groupKey': 'fixture|%d' % index, 'title': 'Synthetic alert %02d' % index}
        for index in range(messages_per_log)]
    canonical_start = time.perf_counter()
    controller_count, year_count = Counter(), Counter()
    chronological = []
    for index in range(logs):
        drone = index % source_drones
        controller_count[drone] += 1
        identity = hashlib.sha256(str(index).encode()).hexdigest()
        value = analyzer.base_log(root / ('%d.ulg' % index), root, identity, 1)
        year = 2015 + index % 12
        stamp = '' if index % 31 == 0 else '%d-%02d-%02dT12:00:00Z' % (year, index % 12 + 1, index % 28 + 1)
        year_count[year if stamp else 'unknown'] += 1
        chronological.append((stamp, identity, drone))
        if reuse:
            continue
        value.update(droneID='fixture-controller-%d' % drone, droneName='Fleet fixture %d' % (drone % 19),
            date=stamp, durationSeconds=60, status='partial' if index % 29 == 0 else 'ok', messages=records)
        value['metadata']['parserVersion'] = analyzer.PARSER_VERSION
        analyzer.remember_log(db, value)
        if index % 500 == 0: db.commit()
    db.commit()
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    generated = None if reuse else time.perf_counter() - canonical_start
    print(json.dumps({'phase': 'generated', 'logs': logs, 'messages': logs * messages_per_log, 'seconds': generated}), flush=True)
    index_start = time.perf_counter()
    repository.initialize(db)
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
    indexed = time.perf_counter() - index_start
    print(json.dumps({'phase': 'indexed', 'seconds': indexed, 'databaseBytes': database.stat().st_size}), flush=True)
    if query_release_file:
        print(json.dumps({'phase': 'awaiting-quiet-window'}), flush=True)
        deadline = time.monotonic() + 600
        while not query_release_file.exists():
            if time.monotonic() >= deadline:
                raise TimeoutError('Fenêtre calme du benchmark non libérée dans les 10 minutes.')
            time.sleep(.2)
    chronological.sort(reverse=True)
    annotations = {'schemaVersion': 1, 'stockNumbers': {'ulog:fixture-controller-%d' % index: 'STOCK-%03d' % (1 if index in (1, 2) else index) for index in range(drones)}}
    family_messages = sum(record['family'] == 'Family-2' and record['isAlert'] for record in records)
    search_messages = sum(record['text'] == 'Synthetic alert 08' for record in records)
    cases = [
        ('dashboard', {'kind': 'logs'}, logs, logs * messages_per_log),
        ('drone', {'kind': 'logs', 'scope': {'droneKeys': ['ulog:fixture-controller-1']}}, controller_count[1], controller_count[1] * messages_per_log),
        ('groups', {'kind': 'groups'}, logs, logs * messages_per_log),
        ('family', {'kind': 'messages', 'scope': {'families': ['Family-2'], 'alertOnly': True}}, logs if family_messages else 0, logs * family_messages),
        ('search', {'kind': 'logs', 'scope': {'search': 'Synthetic alert 08'}}, logs if search_messages else 0, logs * search_messages),
        ('messages', {'kind': 'messages'}, logs, logs * messages_per_log),
        ('map', {'kind': 'map'}, logs, logs * messages_per_log),
        ('registry', {'kind': 'drones', 'annotations': annotations}, None, None),
    ]
    results = []
    for name, request, expected_logs, expected_messages in cases:
        timings = []
        for iteration in range(repeats):
            begin = time.perf_counter(); response = repository.query(db, request); timings.append(time.perf_counter() - begin)
            if name == 'registry':
                assert response['total'] == drones, (response['total'], drones)
            else:
                assert response['totals']['logs'] == expected_logs, (name, response['totals'], expected_logs)
                assert response['totals']['messages'] == expected_messages, (name, response['totals'], expected_messages)
            if name in ('dashboard', 'drone', 'search', 'map'):
                selected = chronological if name != 'drone' else [row for row in chronological if row[2] == 1]
                actual_ids = [item['id'] for item in response['snapshot']['logs']]
                assert actual_ids == [row[1] for row in selected[:len(actual_ids)]], (name, 'first-page identity oracle')
            elif name in ('family', 'messages'):
                selected_records = [item for item in records if item['family'] == 'Family-2' and item['isAlert']] if name == 'family' else records
                expected_ids = [(row[1], record['id']) for row in chronological[:repository.MAX_PAGE_SIZE] for record in selected_records][:repository.MAX_PAGE_SIZE]
                actual_ids = [(item['logID'], item['message']['id']) for item in response['occurrences']]
                assert actual_ids == expected_ids[:len(actual_ids)], (name, 'first-page occurrence oracle')
            assert len(json.dumps(response, ensure_ascii=False).encode()) <= repository.MAX_QUERY_BYTES
            if name == 'map': assert len(response['snapshot']['logs']) <= 80
            if name == 'messages' and response['nextCursor']:
                second = repository.query(db, dict(request, cursor=response['nextCursor']))
                first_ids = {(item['logID'], item['message']['id']) for item in response['occurrences']}
                second_ids = {(item['logID'], item['message']['id']) for item in second['occurrences']}
                assert not first_ids.intersection(second_ids)
        ordered = sorted(timings)
        p95 = ordered[min(len(ordered)-1, int(.95 * len(ordered)))]
        result = {'case': name, 'seconds': timings, 'p50Seconds': statistics.median(timings), 'p95Seconds': p95,
            'firstRequestSeconds': timings[0], 'subsequentP95Seconds': max(timings[1:]) if len(timings) > 1 else None,
            'budget500msPassed': p95 <= .5, 'responseBytes': len(json.dumps(response, ensure_ascii=False).encode())}
        print(json.dumps(result), flush=True); results.append(result)
    db.close()
    peak_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform != 'darwin':
        peak_rss *= 1024
    return {'benchmarkVersion': 2, 'syntheticOnly': True, 'reusedOwnedPreparedFixture': reuse,
        'cacheProtocol': 'Prepared index; first and subsequent requests included in the unchanged 500ms gate. OS page cache is not controlled.',
        'firstPageIdentityOracle': True, 'parserVersion': analyzer.PARSER_VERSION,
        'projectionVersion': repository.PROJECTION_VERSION, 'sqliteVersion': __import__('sqlite3').sqlite_version,
        'logs': logs, 'messages': logs * messages_per_log, 'drones': drones, 'recordedSeconds': logs * 60,
        'sourceDroneCount': source_drones, 'unknownDates': year_count['unknown'], 'generatedSeconds': generated,
        'firstIndexSeconds': None if reuse else indexed, 'ensureIndexSeconds': indexed, 'databaseBytes': database.stat().st_size,
        'peakRSSBytes': peak_rss, 'rss512MiBPassed': peak_rss <= 512 * 1024 * 1024,
        'queryResults': results, 'all500msPassed': all(item['budget500msPassed'] for item in results)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--logs', type=int, default=1000)
    parser.add_argument('--messages', type=int, default=100)
    parser.add_argument('--drones', type=int, default=500)
    parser.add_argument('--repeats', type=int, default=5)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--work', type=Path)
    parser.add_argument('--reuse', action='store_true', help='Rejouer les requêtes sur une fixture synthétique préparée dans --work.')
    parser.add_argument('--query-release-file', type=Path, help='Attendre ce marqueur après préparation avant de mesurer les requêtes ; attente exclue des timings.')
    args = parser.parse_args()
    if not 1 <= args.logs <= 100_000 or not 1 <= args.messages <= 1000 or not 1 <= args.drones <= 1000 or not 1 <= args.repeats <= 30:
        parser.error('Dimensions de benchmark invalides.')
    if args.work:
        result = run(args.work.resolve(), args.logs, args.messages, args.drones, args.repeats, args.reuse, args.query_release_file)
    else:
        if args.reuse:
            parser.error('--reuse nécessite --work pour une fixture synthétique préparée.')
        with tempfile.TemporaryDirectory(prefix='katalog-benchmark-') as directory:
            result = run(Path(directory), args.logs, args.messages, args.drones, args.repeats, query_release_file=args.query_release_file)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2), encoding='utf-8')
    return 0 if result['all500msPassed'] and result['rss512MiBPassed'] else 2


if __name__ == '__main__': sys.exit(main())
