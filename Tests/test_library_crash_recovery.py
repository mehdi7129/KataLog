"""Owned SIGKILL fixtures and genuine legacy-schema migration, with no Git at runtime.

The legacy SQL below was produced by the public analyzer/flight_data sources
at 48fa4f8cebb9ccfcff542f6af7c5ce3ea47280fc (source version 0.5.1, parser 1.2.0).
Those exact two SHA hashes also match the installed 0.5.2 engine sources in the
local qualification. No 0.5.3 source was available; that version is not claimed.
Only invented ULogs were parsed. Origin paths/stat metadata are canonicalized;
IDs, messages, controller metadata, parameters and detailed analyses are real
outputs of that legacy parser. No private library or installed app is read here.
"""
import hashlib
from contextlib import closing
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources/KataLog/Resources"
sys.path.insert(0, str(RESOURCES))
import analyzer
import library_archives as archives
import library_repository as repository
import library_storage as storage
from fixture_ulog import GCS_UUID, synthetic_ulog

LEGACY_SOURCE_SHA = {
    "analyzer.py": "0b978159ca73ef33b97310b7cb165876bf8edcc3198d07414bfa59edc46093ce",
    "flight_data.py": "a550ef0755bfb3d4ba3477e4aa82be77d3b7baae61a26e6c5db0052fbc6444e4",
}
LEGACY_SQL = r"""PRAGMA user_version=1;
BEGIN TRANSACTION;
CREATE TABLE files (
            path TEXT PRIMARY KEY, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
            ctime_ns INTEGER NOT NULL, inode INTEGER NOT NULL, log_id TEXT NOT NULL
        );
INSERT INTO "files" VALUES('/synthetic/katalog-legacy/source/old-log.ulg',2074,1,2,3,'8b0d6be99692ddaf0371129e358d013d3ebe0bfc86afa861dc8593e9c1cbb7a2');
CREATE TABLE flight_details (
            log_id TEXT PRIMARY KEY, parser_version TEXT NOT NULL, summary TEXT NOT NULL
        );
INSERT INTO "flight_details" VALUES('8b0d6be99692ddaf0371129e358d013d3ebe0bfc86afa861dc8593e9c1cbb7a2','1.2.0','{"id": "8b0d6be99692ddaf0371129e358d013d3ebe0bfc86afa861dc8593e9c1cbb7a2", "droneID": "0002000000001c1b1a191817161514131211", "droneName": "Public migration fixture", "date": "2030-01-01T00:00:00Z", "dateSource": "gps", "sourcePaths": ["/synthetic/katalog-legacy/source/old-log.ulg"], "fileName": "old-log.ulg", "sizeBytes": 2074, "durationSeconds": 0.7, "flightSeconds": 0.6, "status": "ok", "issues": [], "metadata": {"sys_uuid": "0002000000001c1b1a191817161514131211", "drone_name": "Public migration fixture", "ver_hw": "DROTEK_IO_STAR_TROIS", "firmware": "Inconnu", "parserVersion": "1.2.0", "gcsUUID": "1112131415161718191A1B1C", "gcsIdentityStatus": "verified", "detailParserVersion": "1.2.0"}, "topics": ["battery_status", "dance_status", "event", "sensor_gps", "vehicle_land_detected"], "messages": [{"id": "8b0d6be99692ddaf0371129e358d013d3ebe0bfc86afa861dc8593e9c1cbb7a2-0", "timestampSeconds": 0.1, "level": "WARNING", "text": "Synthetic GPS warning", "family": "GNSS", "groupKey": "GNSS|WARNING|Synthetic GPS warning", "title": "Synthetic GPS warning", "isAlert": true, "position": {"timeSeconds": 0.1, "latitude": 1.0000001, "longitude": 2.0000001, "altitudeMeters": 100.0, "segment": 0}}, {"id": "8b0d6be99692ddaf0371129e358d013d3ebe0bfc86afa861dc8593e9c1cbb7a2-1", "timestampSeconds": 0.2, "level": "INFO", "text": "Synthetic informational message", "family": "Autres", "groupKey": "Autres|INFO|Synthetic informational message", "title": "Synthetic informational message", "isAlert": false, "position": {"timeSeconds": 0.2, "latitude": 1.0000002, "longitude": 2.0000002, "altitudeMeters": 100.0, "segment": 0}}], "metrics": [{"key": "battery.voltage_min", "label": "Tension batterie minimum", "value": 15.125, "unit": "V", "detail": "instance 0; 8/8 échantillons valides et connectés; voltage_v"}, {"key": "battery.current_max", "label": "Courant batterie maximum", "value": 1.0, "unit": "A", "detail": "instance 0; 8/8 échantillons valides et connectés; current_a"}, {"key": "gps.observed_seconds", "label": "GNSS : durée exploitable", "value": 0.7, "unit": "s", "detail": "instance 0, pondéré par timestamps; intervalles > 10 s exclus"}, {"key": "gps.rtk_fixed", "label": "RTK fixé", "value": 100.0, "unit": "%", "detail": "instance 0, pondéré par timestamps; intervalles > 10 s exclus"}, {"key": "gps.rtk_float", "label": "RTK flottant", "value": 0.0, "unit": "%", "detail": "instance 0, pondéré par timestamps; intervalles > 10 s exclus"}, {"key": "gps.other_fix", "label": "Autres états GNSS", "value": 0.0, "unit": "%", "detail": "instance 0, pondéré par timestamps; intervalles > 10 s exclus"}, {"key": "gps.satellites_min", "label": "Satellites minimum", "value": 20.0, "unit": "", "detail": "instance 0, champ satellites_used; aucun seuil de panne déduit"}, {"key": "gps.eph_max", "label": "Erreur horizontale GNSS estimée max.", "value": 0.1, "unit": "m", "detail": "instance 0, champ eph; aucun seuil de panne déduit"}, {"key": "gps.epv_max", "label": "Erreur verticale GNSS estimée max.", "value": 0.2, "unit": "m", "detail": "instance 0, champ epv; aucun seuil de panne déduit"}], "coverage": ["Batterie instance 0 : champ temperature absent.", "Batterie instance 0 : champ remaining absent.", "Événements binaires non décodés : 1 (instance 0); dictionnaire du firmware requis.", "GNSS instance 0 : âge des corrections RTCM absent; statut RTK et eph/epv sont disponibles séparément.", "Durée de vol observée : landed=false, sur la portion enregistrée; extrémités non extrapolées.", "Topic ESC absent : aucune conclusion sur la santé des moteurs/ESC.", "GPS : un récepteur choisi selon les points valides ; fix 3D/différentiel/RTK seulement, lacunes > 10 s et échantillons invalides séparés. Trajectoire d’affichage échantillonnée, pas une trajectoire de commande."], "failsafeObserved": false, "track": {"source": "sensor_gps[0] · WGS84 · lat/lon · altitude MSL", "originalPointCount": 8, "rejectedPointCount": 0, "points": [{"timeSeconds": 0.0, "latitude": 1.0, "longitude": 2.0, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.1, "latitude": 1.0000001, "longitude": 2.0000001, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.2, "latitude": 1.0000002, "longitude": 2.0000002, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.3, "latitude": 1.0000003, "longitude": 2.0000003, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.4, "latitude": 1.0000004, "longitude": 2.0000004, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.5, "latitude": 1.0000004999999998, "longitude": 2.0000005, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.6, "latitude": 1.0000006, "longitude": 2.0000006, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.7, "latitude": 1.0000007, "longitude": 2.0000006999999997, "altitudeMeters": 100.0, "segment": 0}]}, "topicDetails": [{"name": "battery_status", "instance": 0, "sampleCount": 8, "fields": ["connected", "current_a", "timestamp", "voltage_v"]}, {"name": "dance_status", "instance": 0, "sampleCount": 8, "fields": ["timestamp", "uuid[0]", "uuid[10]", "uuid[11]", "uuid[1]", "uuid[2]", "uuid[3]", "uuid[4]", "uuid[5]", "uuid[6]", "uuid[7]", "uuid[8]", "uuid[9]"]}, {"name": "event", "instance": 0, "sampleCount": 1, "fields": ["arguments[0]", "arguments[10]", "arguments[11]", "arguments[12]", "arguments[13]", "arguments[14]", "arguments[15]", "arguments[16]", "arguments[17]", "arguments[18]", "arguments[19]", "arguments[1]", "arguments[20]", "arguments[21]", "arguments[22]", "arguments[23]", "arguments[24]", "arguments[2]", "arguments[3]", "arguments[4]", "arguments[5]", "arguments[6]", "arguments[7]", "arguments[8]", "arguments[9]", "event_sequence", "id", "log_levels", "timestamp"]}, {"name": "sensor_gps", "instance": 0, "sampleCount": 8, "fields": ["alt", "eph", "epv", "fix_type", "lat", "lon", "satellites_used", "time_utc_usec", "timestamp"]}, {"name": "vehicle_land_detected", "instance": 0, "sampleCount": 8, "fields": ["landed", "timestamp"]}], "parameters": {"TEST_PARAM": "1.25"}, "parameterChanges": []}');
CREATE TABLE folders (path TEXT PRIMARY KEY);
INSERT INTO "folders" VALUES('/synthetic/katalog-legacy/source');
CREATE TABLE logs (
            id TEXT PRIMARY KEY, parser_version TEXT NOT NULL, summary TEXT NOT NULL
        );
INSERT INTO "logs" VALUES('8b0d6be99692ddaf0371129e358d013d3ebe0bfc86afa861dc8593e9c1cbb7a2','1.2.0','{"id": "8b0d6be99692ddaf0371129e358d013d3ebe0bfc86afa861dc8593e9c1cbb7a2", "droneID": "0002000000001c1b1a191817161514131211", "droneName": "Public migration fixture", "date": "2030-01-01T00:00:00Z", "dateSource": "gps", "sourcePaths": ["/synthetic/katalog-legacy/source/old-log.ulg"], "fileName": "old-log.ulg", "sizeBytes": 2074, "durationSeconds": 0.7, "flightSeconds": 0.6, "status": "ok", "issues": [], "metadata": {"sys_uuid": "0002000000001c1b1a191817161514131211", "drone_name": "Public migration fixture", "ver_hw": "DROTEK_IO_STAR_TROIS", "firmware": "Inconnu", "parserVersion": "1.2.0", "gcsUUID": "1112131415161718191A1B1C", "gcsIdentityStatus": "verified"}, "topics": ["battery_status", "dance_status", "event", "sensor_gps", "vehicle_land_detected"], "messages": [{"id": "8b0d6be99692ddaf0371129e358d013d3ebe0bfc86afa861dc8593e9c1cbb7a2-0", "timestampSeconds": 0.1, "level": "WARNING", "text": "Synthetic GPS warning", "family": "GNSS", "groupKey": "GNSS|WARNING|Synthetic GPS warning", "title": "Synthetic GPS warning", "isAlert": true, "position": {"timeSeconds": 0.1, "latitude": 1.0000001, "longitude": 2.0000001, "altitudeMeters": 100.0, "segment": 0}}, {"id": "8b0d6be99692ddaf0371129e358d013d3ebe0bfc86afa861dc8593e9c1cbb7a2-1", "timestampSeconds": 0.2, "level": "INFO", "text": "Synthetic informational message", "family": "Autres", "groupKey": "Autres|INFO|Synthetic informational message", "title": "Synthetic informational message", "isAlert": false, "position": {"timeSeconds": 0.2, "latitude": 1.0000002, "longitude": 2.0000002, "altitudeMeters": 100.0, "segment": 0}}], "metrics": [{"key": "battery.voltage_min", "label": "Tension batterie minimum", "value": 15.125, "unit": "V", "detail": "instance 0; 8/8 échantillons valides et connectés; voltage_v"}, {"key": "battery.current_max", "label": "Courant batterie maximum", "value": 1.0, "unit": "A", "detail": "instance 0; 8/8 échantillons valides et connectés; current_a"}, {"key": "gps.observed_seconds", "label": "GNSS : durée exploitable", "value": 0.7, "unit": "s", "detail": "instance 0, pondéré par timestamps; intervalles > 10 s exclus"}, {"key": "gps.rtk_fixed", "label": "RTK fixé", "value": 100.0, "unit": "%", "detail": "instance 0, pondéré par timestamps; intervalles > 10 s exclus"}, {"key": "gps.rtk_float", "label": "RTK flottant", "value": 0.0, "unit": "%", "detail": "instance 0, pondéré par timestamps; intervalles > 10 s exclus"}, {"key": "gps.other_fix", "label": "Autres états GNSS", "value": 0.0, "unit": "%", "detail": "instance 0, pondéré par timestamps; intervalles > 10 s exclus"}, {"key": "gps.satellites_min", "label": "Satellites minimum", "value": 20.0, "unit": "", "detail": "instance 0, champ satellites_used; aucun seuil de panne déduit"}, {"key": "gps.eph_max", "label": "Erreur horizontale GNSS estimée max.", "value": 0.1, "unit": "m", "detail": "instance 0, champ eph; aucun seuil de panne déduit"}, {"key": "gps.epv_max", "label": "Erreur verticale GNSS estimée max.", "value": 0.2, "unit": "m", "detail": "instance 0, champ epv; aucun seuil de panne déduit"}], "coverage": ["Batterie instance 0 : champ temperature absent.", "Batterie instance 0 : champ remaining absent.", "Événements binaires non décodés : 1 (instance 0); dictionnaire du firmware requis.", "GNSS instance 0 : âge des corrections RTCM absent; statut RTK et eph/epv sont disponibles séparément.", "Durée de vol observée : landed=false, sur la portion enregistrée; extrémités non extrapolées.", "Topic ESC absent : aucune conclusion sur la santé des moteurs/ESC.", "GPS : un récepteur choisi selon les points valides ; fix 3D/différentiel/RTK seulement, lacunes > 10 s et échantillons invalides séparés. Trajectoire d’affichage échantillonnée, pas une trajectoire de commande."], "failsafeObserved": false, "track": {"source": "sensor_gps[0] · WGS84 · lat/lon · altitude MSL", "originalPointCount": 8, "rejectedPointCount": 0, "points": [{"timeSeconds": 0.0, "latitude": 1.0, "longitude": 2.0, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.1, "latitude": 1.0000001, "longitude": 2.0000001, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.2, "latitude": 1.0000002, "longitude": 2.0000002, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.3, "latitude": 1.0000003, "longitude": 2.0000003, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.4, "latitude": 1.0000004, "longitude": 2.0000004, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.5, "latitude": 1.0000004999999998, "longitude": 2.0000005, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.6, "latitude": 1.0000006, "longitude": 2.0000006, "altitudeMeters": 100.0, "segment": 0}, {"timeSeconds": 0.7, "latitude": 1.0000007, "longitude": 2.0000006999999997, "altitudeMeters": 100.0, "segment": 0}]}}');
CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO "settings" VALUES('lastImportStats','{"discovered": 1, "imported": 1, "unchanged": 0, "duplicates": 0, "failed": 0}');
CREATE TABLE sources (
            log_id TEXT NOT NULL, path TEXT NOT NULL, PRIMARY KEY(log_id,path)
        );
INSERT INTO "sources" VALUES('8b0d6be99692ddaf0371129e358d013d3ebe0bfc86afa861dc8593e9c1cbb7a2','/synthetic/katalog-legacy/source/old-log.ulg');
COMMIT;
"""

CHILD = r'''
import fcntl,json,os,signal,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import analyzer,library_storage as storage,library_archives as archives
request=json.loads(sys.argv[2]);library=Path(request['library']);point=request['point']
lock=(library/'.library-writer.lock').open('a+b');fcntl.flock(lock,fcntl.LOCK_EX)
def die():
    Path(request['checkpoint']).write_text(json.dumps({'point':point,'pid':os.getpid()}))
    os.kill(os.getpid(),signal.SIGKILL)
original_replace=os.replace;original_link=os.link;original_json=storage.atomic_json
def replace(source,target,*args,**kwargs):
    selected=(request['action']=='backup' and Path(target)==Path(request['destination'])) or (
        request['action']=='restore' and point in ('before','after') and
        Path(source).parent.name=='state' and Path(target)==library/'annotations.json') or (
        request['action']=='recover-restore' and point in ('before','after') and
        Path(source).parent.name=='original-files' and Path(target)==library/'library.sqlite')
    if selected and point=='before':die()
    result=original_replace(source,target,*args,**kwargs)
    if selected and point=='after':die()
    return result
def link(source,target,*args,**kwargs):
    selected=request['action'] in ('archive','prepared-archive') and Path(target)==Path(request['destination'])/(request['identity']+'.ulg')
    if selected and point=='before':die()
    result=original_link(source,target,*args,**kwargs)
    if selected and point=='after':die()
    return result
def atomic(path,value):
    result=original_json(path,value)
    if request['action']=='restore' and point=='complete-journal' and Path(path)==library/'.restore-journal.json' and value.get('phase')=='complete':die()
    if request['action']=='recover-restore' and point=='recovery-journal' and Path(path)==library/'.restore-journal.json' and value.get('phase')=='recovering-originals':die()
    return result
os.replace=replace;os.link=link;storage.atomic_json=atomic
if request['action']=='backup':storage.backup(library,request['destination'],include_ulog=True)
elif request['action']=='restore':storage.restore(request['archive'],library)
elif request['action']=='recover-restore':storage.recover_restore(library)
elif request['action']=='archive':archives.archive_logs(library/'library.sqlite',library,request['destination'],[request['identity']])
else:
    source=Path(request['source'])
    archives.archive_copy_prepared(library,request['destination'],source,request['identity'],analyzer.stat_signature(source.stat()),request['originContext'])
raise RuntimeError('Requested checkpoint was not reached')
'''


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def logical_state(library):
    database = Path(library) / "library.sqlite"
    with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)) as db:
        if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise AssertionError("Database is not integral")
        rows = [(identity, json.loads(summary)) for identity, summary in db.execute("SELECT id,summary FROM logs ORDER BY id")]
    return {"logs": rows, "annotations": (Path(library) / "annotations.json").read_bytes()}


class CrashRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="katalog-owned-crash-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def library(self, name, samples, note):
        library = self.root / name; library.mkdir()
        source = self.root / (name + "-original.ulg")
        source.write_bytes(synthetic_ulog(drone_name="Public crash fixture", samples=samples))
        identity = sha(source)
        analyzer.scan(source, library / "library.sqlite", skip_snapshot=True)
        analyzer.detail(identity, library / "library.sqlite")
        (library / "annotations.json").write_text(json.dumps({"schemaVersion": 1, "stockNumbers": {"gcs:" + GCS_UUID.hex().upper(): "TEST-001"}, "note": note}))
        (library / ".library-writer.lock").write_bytes(b"public stable writer inode")
        return library, source, identity

    def kill_at(self, library, action, point, **arguments):
        checkpoint = self.root / ("checkpoint-" + action + "-" + point + ".json")
        request = dict(library=str(library), action=action, point=point, checkpoint=str(checkpoint),
                       **{key: str(value) if isinstance(value, Path) else value for key, value in arguments.items()})
        env = {key: value for key, value in os.environ.items() if not key.startswith(("PYTHON", "DYLD_"))}
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        result = subprocess.run([sys.executable, "-B", "-c", CHILD, str(RESOURCES), json.dumps(request)],
                                cwd=self.root, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr.decode(errors="replace"))
        self.assertTrue(checkpoint.is_file(), "The owned child must reach the requested publication checkpoint")
        self.assertEqual(json.loads(checkpoint.read_text())["point"], point)

    def test_backup_death_before_or_after_publication_keeps_one_integral_archive(self):
        for point in ("before", "after"):
            with self.subTest(point=point):
                library, source, _ = self.library("backup-" + point, 8, "old")
                destination = self.root / ("backup-" + point + ".zip")
                storage.backup(library, destination, include_ulog=True)
                previous = destination.read_bytes()
                source_sha = sha(source)
                config = json.loads((library / "annotations.json").read_text()); config["note"] = "new"
                (library / "annotations.json").write_text(json.dumps(config))
                self.kill_at(library, "backup", point, destination=destination)
                first = storage.inspect_backup(destination); second = storage.inspect_backup(destination)
                self.assertEqual(first, second); self.assertEqual(first["logCount"], 1)
                self.assertEqual(first["missingSourceCount"], 0)
                with zipfile.ZipFile(destination) as archive:
                    captured = json.loads(archive.read("state/annotations.json"))
                self.assertEqual(captured["note"], "old" if point == "before" else "new")
                if point == "before": self.assertEqual(destination.read_bytes(), previous)
                self.assertEqual(sha(source), source_sha)

    def test_restore_death_recovers_complete_old_or_complete_new_state_idempotently(self):
        for point in ("before", "after", "complete-journal"):
            with self.subTest(point=point):
                library, original, _ = self.library("restore-old-" + point, 8, "old")
                incoming, incoming_source, _ = self.library("restore-new-" + point, 9, "new")
                old_state, new_state = logical_state(library), logical_state(incoming)
                originals = {path: (sha(path), path.stat().st_mtime_ns) for path in (original, incoming_source)}
                lease_inode = (library / ".library-writer.lock").stat().st_ino
                backup = self.root / ("restore-" + point + ".zip")
                storage.backup(incoming, backup, include_ulog=True)
                self.kill_at(library, "restore", point, archive=backup)
                result = storage.recover_restore(library)
                self.assertTrue(result["recovered"])
                self.assertEqual(result["completedRestore"], point == "complete-journal")
                self.assertEqual(logical_state(library), new_state if point == "complete-journal" else old_state)
                before = sha(library / "library.sqlite")
                self.assertFalse(storage.recover_restore(library)["recovered"])
                self.assertEqual(sha(library / "library.sqlite"), before)
                self.assertEqual((library / ".library-writer.lock").stat().st_ino, lease_inode)
                self.assertFalse((library / ".restore-journal.json").exists())
                for path, signature in originals.items(): self.assertEqual((sha(path), path.stat().st_mtime_ns), signature)

    def test_recovery_death_before_after_original_move_or_phase_publication_is_retryable(self):
        for point in ('before', 'after', 'recovery-journal'):
            with self.subTest(point=point):
                library, source, _ = self.library('recover-old-' + point, 8, 'old')
                incoming, incoming_source, _ = self.library('recover-new-' + point, 9, 'new')
                old_state = logical_state(library)
                originals = {path: (sha(path), path.stat().st_mtime_ns) for path in (source, incoming_source)}
                lease_inode = (library / '.library-writer.lock').stat().st_ino
                archive = self.root / ('recover-' + point + '.zip')
                storage.backup(incoming, archive, include_ulog=True)
                self.kill_at(library, 'restore', 'after', archive=archive)
                self.kill_at(library, 'recover-restore', point)
                result = storage.recover_restore(library)
                self.assertTrue(result['recovered'])
                self.assertFalse(result['completedRestore'])
                self.assertEqual(logical_state(library), old_state)
                database_sha = sha(library / 'library.sqlite')
                self.assertFalse(storage.recover_restore(library)['recovered'])
                self.assertEqual(sha(library / 'library.sqlite'), database_sha)
                self.assertEqual((library / '.library-writer.lock').stat().st_ino, lease_inode)
                for path, signature in originals.items():
                    self.assertEqual((sha(path), path.stat().st_mtime_ns), signature)

    def test_archive_death_recovers_verified_copy_or_preserved_partial_idempotently(self):
        for point in ("before", "after"):
            with self.subTest(point=point):
                library, source, identity = self.library("archive-" + point, 8, "unchanged")
                before = logical_state(library); source_signature = (sha(source), source.stat().st_mtime_ns)
                destination = self.root / ("archives-" + point)
                self.kill_at(library, "archive", point, destination=destination, identity=identity)
                result = archives.recover_archive(library / "library.sqlite", library)
                self.assertTrue(result["recovered"])
                target = destination / (identity + ".ulg")
                if point == "after":
                    self.assertEqual(result["completed"], 1); self.assertEqual(sha(target), identity)
                    with closing(sqlite3.connect(library / "library.sqlite")) as db:
                        self.assertEqual(db.execute("SELECT COUNT(*) FROM sources WHERE log_id=? AND path=?", (identity, str(target))).fetchone()[0], 1)
                else:
                    self.assertEqual(result["interrupted"], 1); self.assertFalse(target.exists())
                    self.assertTrue(list(library.glob("recovery-archive-*/*.partial")))
                self.assertEqual(logical_state(library), before)
                after = sha(library / "library.sqlite")
                self.assertFalse(archives.recover_archive(library / "library.sqlite", library)["recovered"])
                self.assertEqual(sha(library / "library.sqlite"), after)
                self.assertEqual((sha(source), source.stat().st_mtime_ns), source_signature)

    def test_prepared_import_death_retains_provenance_without_inventing_analysis(self):
        for point in ("before", "after"):
            with self.subTest(point=point):
                library = self.root / ("prepared-" + point); library.mkdir()
                db = analyzer.open_database(library / "library.sqlite"); db.close()
                source = self.root / ("prepared-" + point + ".ulg")
                source.write_bytes(synthetic_ulog(drone_name="Public prepared archive", samples=8))
                identity = sha(source); signature = (identity, source.stat().st_mtime_ns)
                destination = self.root / ("prepared-archive-" + point)
                context = {"id": identity, "fileName": source.name, "date": "2030-01-01T00:00:00Z", "dateSource": "gps", "fixture": "invented"}
                self.kill_at(library, "prepared-archive", point, destination=destination, identity=identity, source=source, originContext=context)
                result = archives.recover_archive(library / "library.sqlite", library)
                self.assertEqual(result.get("readyForImport", 0), 1 if point == "after" else 0)
                journal = json.loads((Path(result["recoveryDirectory"]) / "journal.json").read_text())
                self.assertEqual(journal["jobs"][0]["originContext"], context)
                if point == "after": self.assertEqual(sha(destination / (identity + ".ulg")), identity)
                with closing(sqlite3.connect(library / "library.sqlite")) as db: self.assertEqual(db.execute("SELECT COUNT(*) FROM logs").fetchone()[0], 0)
                self.assertFalse(archives.recover_archive(library / "library.sqlite", library)["recovered"])
                self.assertEqual((sha(source), source.stat().st_mtime_ns), signature)

    def test_true_legacy_schema_fixture_migrates_without_git_or_ulog_source(self):
        library = self.root / "legacy-library"; library.mkdir()
        database = library / "library.sqlite"
        with closing(sqlite3.connect(database)) as db: db.executescript(LEGACY_SQL)
        annotations = {"schemaVersion": 1, "stockNumbers": {"gcs:" + GCS_UUID.hex().upper(): "TEST-001"}, "familyOverrides": {"text-v1:synthetic": "Synthetic family"}}
        (library / "annotations.json").write_text(json.dumps(annotations, sort_keys=True))
        before = logical_state(library)
        expected = hashlib.sha256(synthetic_ulog(drone_name="Public migration fixture", samples=8)).hexdigest()
        self.assertEqual([row[0] for row in before["logs"]], [expected])
        self.assertTrue(before["logs"][0][1]["messages"])
        annotation_sha = sha(library / "annotations.json")
        db = analyzer.open_database(database)
        try:
            repository.initialize(db)
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT parser_version FROM logs").fetchone()[0], "1.2.0")
            first_revisions = list(map(tuple, db.execute("SELECT id,analysis_sha256 FROM analysis_revisions ORDER BY id")))
            self.assertEqual(len(first_revisions), 2)
            repository.initialize(db)
            self.assertEqual(list(map(tuple, db.execute("SELECT id,analysis_sha256 FROM analysis_revisions ORDER BY id"))), first_revisions)
            page = repository.query(db, {"queryVersion": 1, "kind": "logs"}, read_only=True)
            self.assertEqual(page["totals"]["logs"], 1)
        finally: db.close()
        versions = analyzer.analysis_revisions(expected, database, read_only=True)
        detail = next(row for row in versions["revisions"] if row["kind"] == "detail")
        historical = analyzer.detail(expected, database, read_only=True, revision=detail["id"])
        self.assertEqual(historical["metadata"]["detailParserVersion"], "1.2.0")
        self.assertTrue(all(row["state"] == "missing" for row in historical["sourceAvailability"]))
        self.assertEqual(logical_state(library), before)
        self.assertEqual(sha(library / "annotations.json"), annotation_sha)


if __name__ == "__main__": unittest.main()
