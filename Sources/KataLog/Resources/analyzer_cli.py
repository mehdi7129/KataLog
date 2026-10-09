"""Argument parsing and command dispatch for the public analyzer entry point."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from output_paths import backup_source_paths, validate_outputs


def main(argv, analyzer):
    parser = argparse.ArgumentParser(description="Import local incrémental de logs PX4")
    commands = parser.add_subparsers(dest="command", required=True)
    scan_command = commands.add_parser("scan")
    scan_command.add_argument("--folder", required=True)
    scan_command.add_argument("--database", required=True)
    scan_command.add_argument("--output", required=True)
    scan_command.add_argument("--progress")
    scan_command.add_argument("--skip-snapshot", action="store_true")
    scan_command.add_argument('--archive-destination')
    scan_command.add_argument('--client-id')
    scan_command.add_argument('--additional-output', action='append', default=[])
    snapshot_command = commands.add_parser("snapshot")
    snapshot_command.add_argument("--database", required=True)
    snapshot_command.add_argument("--output", required=True)
    snapshot_command.add_argument("--read-only", action="store_true")
    for name in ('source-folders', 'retire-source', 'restore-source'):
        command = commands.add_parser(name)
        command.add_argument('--database', required=True)
        command.add_argument('--output', required=True)
        if name == 'source-folders':
            command.add_argument('--offset', type=int, default=0)
            command.add_argument('--limit', type=int, default=200)
            command.add_argument('--include-removed', action='store_true')
        else:
            command.add_argument('--folder', required=True)
    query_command = commands.add_parser("query")
    query_command.add_argument("--request", required=True)
    query_command.add_argument("--database", required=True)
    query_command.add_argument("--output", required=True)
    query_command.add_argument("--read-only", action="store_true")
    query_command.add_argument("--proximity-cache", help=argparse.SUPPRESS)
    index_command = commands.add_parser("ensure-index")
    index_command.add_argument("--database", required=True)
    index_command.add_argument("--output", required=True)
    refresh_command = commands.add_parser('refresh-analysis')
    refresh_command.add_argument('--database', required=True)
    refresh_command.add_argument('--output', required=True)
    refresh_command.add_argument('--progress')
    status_command = commands.add_parser('indexed-status')
    status_command.add_argument('--database', required=True)
    status_command.add_argument('--request', required=True)
    status_command.add_argument('--output', required=True)
    dictionary_command = commands.add_parser('event-dictionary')
    dictionary_command.add_argument('--database', required=True)
    dictionary_command.add_argument('--file', required=True)
    dictionary_command.add_argument('--output', required=True)
    detail_command = commands.add_parser("detail")
    detail_command.add_argument("--log-id", required=True)
    detail_command.add_argument("--database", required=True)
    detail_command.add_argument("--output", required=True)
    detail_command.add_argument("--read-only", action="store_true")
    detail_command.add_argument('--revision')
    revisions_command = commands.add_parser('analysis-revisions')
    revisions_command.add_argument('--log-id', required=True)
    revisions_command.add_argument('--database', required=True)
    revisions_command.add_argument('--output', required=True)
    revisions_command.add_argument('--offset', type=int, default=0)
    revisions_command.add_argument('--limit', type=int, default=32)
    revisions_command.add_argument('--read-only', action='store_true')
    series_command = commands.add_parser('series')
    series_command.add_argument('--log-id', required=True)
    series_command.add_argument('--database', required=True)
    series_command.add_argument('--request')
    series_command.add_argument('--recipe', choices=('battery', 'gnss', 'ekf'))
    series_command.add_argument('--topic')
    series_command.add_argument('--field')
    series_command.add_argument('--instance', type=int, default=0)
    series_command.add_argument('--time-from', type=float)
    series_command.add_argument('--time-to', type=float)
    series_command.add_argument('--budget', type=int, default=2048)
    series_command.add_argument('--output', required=True)
    for name in ('capture-report', 'export-captured'):
        command = commands.add_parser(name)
        command.add_argument('--capture', required=True)
        command.add_argument('--output', required=True)
        if name == 'capture-report':
            command.add_argument('--database', required=True)
            command.add_argument('--request', required=True)
        else:
            command.add_argument('--destination', required=True)
            command.add_argument('--progress')
    for name in ('storage-info', 'archive', 'recover-archive', 'reassociate', 'clean-cache', 'restore-cache'):
        command = commands.add_parser(name)
        command.add_argument('--database', required=True)
        command.add_argument('--output', required=True)
        if name in ('storage-info', 'archive', 'recover-archive', 'clean-cache'):
            command.add_argument('--library', required=True)
        if name in ('archive', 'clean-cache'):
            command.add_argument('--request', required=True)
        if name == 'archive':
            command.add_argument('--destination', required=True)
        if name == 'storage-info':
            command.add_argument('--offset', type=int, default=0)
            command.add_argument('--limit', type=int, default=200)
        if name == 'reassociate':
            command.add_argument('--folder', required=True)
        if name == 'restore-cache':
            command.add_argument('--recovery', required=True)
    backup_command = commands.add_parser("backup")
    backup_command.add_argument("--library", required=True)
    backup_command.add_argument("--destination", required=True)
    backup_command.add_argument("--include-ulog", action="store_true")
    backup_command.add_argument("--output", required=True)
    inspect_command = commands.add_parser("inspect-backup")
    inspect_command.add_argument("--archive", required=True)
    inspect_command.add_argument("--output", required=True)
    restore_command = commands.add_parser("restore")
    restore_command.add_argument("--archive", required=True)
    restore_command.add_argument("--library", required=True)
    restore_command.add_argument("--output", required=True)
    recover_command = commands.add_parser("recover-restore")
    recover_command.add_argument("--library", required=True)
    recover_command.add_argument("--output", required=True)
    for name in ('clients', 'create-client', 'rename-client', 'delete-client', 'assign-client', 'retire-all-sources', 'reset-library'):
        command = commands.add_parser(name)
        command.add_argument('--database', required=True)
        command.add_argument('--output', required=True)
        if name in ('create-client', 'rename-client', 'delete-client', 'assign-client'):
            command.add_argument('--request', required=True)
        if name == 'clients':
            command.add_argument('--read-only', action='store_true')
        if name == 'reset-library':
            command.add_argument('--library', required=True)
            command.add_argument('--all-settings', action='store_true')
    args = parser.parse_args(argv)
    try:
        if args.command not in ('scan', 'detail', 'refresh-analysis'):
            outputs = [args.output, getattr(args, 'progress', None), getattr(args, 'proximity_cache', None)]
            inputs = [analyzer.__file__, *[getattr(args, name, None) for name in ('request', 'file', 'archive', 'capture', 'recovery')]]
            if args.command == 'restore' and (Path(args.output).exists() or Path(args.output).is_symlink()):
                inputs.extend(backup_source_paths(args.archive))
            if hasattr(args, 'capture'):
                inputs.extend(Path(args.capture) / name for name in ('context.json', 'capture-manifest.json'))
            if args.command == 'export-captured':
                inputs.extend(Path(args.destination) / name for name in ('rapport.json', 'summary.json', 'manifest.json'))
            if args.command == 'backup':
                outputs.append(args.destination)
            validate_outputs(outputs, database=getattr(args, 'database', None),
                             library=getattr(args, 'library', None) or getattr(args, 'capture', None), folder=getattr(args, 'folder', None),
                             inputs=inputs,
                             copy_sources=args.command in ('backup', 'restore', 'recover-restore'))
        if args.command in ('clients', 'create-client', 'rename-client', 'delete-client', 'assign-client', 'retire-all-sources', 'reset-library'):
            import library_clients
            request = None
            if hasattr(args, 'request'):
                if Path(args.request).stat().st_size > 16 * 1024 * 1024:
                    raise ValueError('Requête de clients trop volumineuse.')
                request = json.loads(Path(args.request).read_text(encoding='utf-8'))
            if args.command == 'reset-library':
                result = library_clients.reset_library(args.database, args.library, args.all_settings)
            elif args.command == 'retire-all-sources':
                result = library_clients.retire_all_sources(args.database)
            else:
                result = library_clients.command(args.database, args.command, request, read_only=getattr(args, 'read_only', False))
            analyzer.atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'ok': True}))
            return 0
        if args.command in ('source-folders', 'retire-source', 'restore-source'):
            import library_sources
            result = (library_sources.source_folders(args.database, args.offset, args.limit, args.include_removed)
                      if args.command == 'source-folders' else
                      library_sources.set_removed(args.database, args.folder, args.command == 'retire-source'))
            analyzer.atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'ok': True}))
            return 0
        if args.command == 'analysis-revisions':
            result = analyzer.analysis_revisions(args.log_id, args.database, args.offset, args.limit, args.read_only)
            analyzer.atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'ok': True}))
            return 0
        if args.command == 'event-dictionary':
            result = analyzer.import_event_dictionary(args.database, args.file)
            analyzer.atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'sha256': result['sha256'], 'ok': True}))
            return 0
        if args.command == 'indexed-status':
            if Path(args.request).stat().st_size > 1024 * 1024:
                raise ValueError('Requête d’index trop volumineuse.')
            result = analyzer.indexed_status(args.database, json.loads(Path(args.request).read_text(encoding='utf-8')))
            analyzer.atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'ok': True}))
            return 0
        if args.command == 'refresh-analysis':
            result = analyzer.refresh_analysis(args.database, args.output, args.progress)
            print(json.dumps({'command': args.command, 'revision': result['revision'], 'ok': True}))
            return 0
        if args.command == 'series':
            if args.request:
                if Path(args.request).stat().st_size > 1024 * 1024:
                    raise ValueError('Requête de télémétrie trop volumineuse.')
                request = json.loads(Path(args.request).read_text(encoding='utf-8'))
            else:
                request = {'seriesVersion': 1, 'instance': args.instance, 'budget': args.budget}
                if args.recipe: request['recipe'] = args.recipe
                else: request.update(topic=args.topic, field=args.field)
                if args.time_from is not None: request['timeFrom'] = args.time_from
                if args.time_to is not None: request['timeTo'] = args.time_to
            result = analyzer.telemetry_series(args.log_id, args.database, request)
            analyzer.atomic_json(args.output, result)
            print(json.dumps({'command': 'series', 'logID': args.log_id, 'ok': True}))
            return 0
        if args.command in ('capture-report', 'export-captured'):
            import library_reports
            if args.command == 'capture-report':
                if Path(args.request).stat().st_size > 16 * 1024 * 1024:
                    raise ValueError('Requête de rapport trop volumineuse.')
                result = library_reports.capture_report(args.database, args.capture, json.loads(Path(args.request).read_text(encoding='utf-8')))
            else:
                result = library_reports.prepare_report(args.capture, args.destination, progress=args.progress)
            analyzer.atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'ok': True}))
            return 0
        if args.command in ('storage-info', 'archive', 'recover-archive', 'reassociate', 'clean-cache', 'restore-cache'):
            import library_archives
            request = None
            if hasattr(args, 'request'):
                if Path(args.request).stat().st_size > 16 * 1024 * 1024:
                    raise ValueError('Sélection de stockage trop volumineuse.')
                request = json.loads(Path(args.request).read_text(encoding='utf-8'))
            if args.command == 'storage-info': result = library_archives.storage_info(args.database, args.library, args.offset, args.limit)
            elif args.command == 'archive': result = library_archives.archive_logs(args.database, args.library, args.destination, request.get('logIDs'))
            elif args.command == 'recover-archive': result = library_archives.recover_archive(args.database, args.library)
            elif args.command == 'reassociate': result = library_archives.reassociate(args.database, args.folder)
            elif args.command == 'clean-cache': result = library_archives.clean_detail_cache(args.database, args.library, request.get('logIDs'))
            else: result = library_archives.restore_detail_cache(args.database, args.recovery)
            analyzer.atomic_json(args.output, result)
            print(json.dumps({'command': args.command, 'ok': True}))
            return 0
        if args.command in ("query", "ensure-index"):
            import library_repository
            db = analyzer.open_database(args.database, read_only=getattr(args, "read_only", False))
            try:
                if args.command == "ensure-index":
                    library_repository.initialize(db)
                    result = {"queryVersion": 1, "revision": int(db.execute("SELECT value FROM kl_meta WHERE key='revision'").fetchone()[0]), "ok": True}
                else:
                    if Path(args.request).stat().st_size > 16 * 1024 * 1024:
                        raise ValueError("La requête de bibliothèque dépasse 16 Mio.")
                    request = json.loads(Path(args.request).read_text(encoding="utf-8"))
                    result = library_repository.query(db, request, read_only=args.read_only, proximity_cache=args.proximity_cache)
            finally:
                db.close()
            analyzer.atomic_json(args.output, result)
            print(json.dumps({"command": args.command, "revision": result["revision"], "ok": True}))
            return 0
        if args.command in ("backup", "inspect-backup", "restore", "recover-restore"):
            import library_storage
            if args.command == "backup":
                result = library_storage.backup(args.library, args.destination, args.include_ulog)
            elif args.command == "inspect-backup":
                result = library_storage.inspect_backup(args.archive)
            elif args.command == "restore":
                result = library_storage.restore(args.archive, args.library)
            else:
                result = library_storage.recover_restore(args.library)
            analyzer.atomic_json(args.output, result)
            print(json.dumps({"command": args.command, "ok": True}))
            return 0
        if args.command == "detail":
            result = analyzer.detail(args.log_id, args.database, args.output, read_only=args.read_only, revision=args.revision)
            print(json.dumps({"logID": result["id"], "status": result["status"]}))
            return 0
        if args.command == "scan":
            result = analyzer.scan(args.folder, args.database, args.output, args.progress, skip_snapshot=args.skip_snapshot, archive_destination=args.archive_destination, client_id=args.client_id, additional_outputs=args.additional_output)
        else:
            db = analyzer.open_database(args.database, read_only=args.read_only)
            try:
                result = analyzer.snapshot(db)
            finally:
                db.close()
            analyzer.atomic_json(args.output, result)
        print(json.dumps({"logs": len(result["logs"]), "importStats": result["importStats"]}, ensure_ascii=False))
        return 0
    except Exception as error:
        print(f"{type(error).__name__}: {error}", file=sys.stderr)
        return 1
