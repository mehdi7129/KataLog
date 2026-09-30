"""Integration checks against real PX4 logs and focused metric correctness checks.

Run: python3 -m unittest discover -s Tests -v
Set KATALOG_PRIVATE_FIXTURES to an external reference corpus to enable real-log
integration checks. No private logs or identities are included in the repository.
Source logs are read-only; working copies live in TemporaryDirectory.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import numpy as np
from pyulog import ULog
from fixture_ulog import synthetic_ulog

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Sources/KataLog/Resources/analyzer.py"
PRIVATE_FIXTURES = os.environ.get("KATALOG_PRIVATE_FIXTURES")
CARD = Path(PRIVATE_FIXTURES).expanduser() if PRIVATE_FIXTURES else None
REAL_FILES = sorted(CARD.rglob("*.ulg")) if CARD else []
spec = importlib.util.spec_from_file_location("analyzer", SCRIPT)
analyzer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyzer)


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="katalog-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.source = self.work / "sources"
        self.source.mkdir()
        self.database = self.work / "library.sqlite"
        self.output = self.work / "report.json"
        self.progress = self.work / "progress.json"
        self.fixture_files = list(REAL_FILES)
        if not self.fixture_files:
            fixtures = self.work / 'public-fixtures'
            fixtures.mkdir()
            for index, name in enumerate((None, 'Synthetic public controller')):
                path = fixtures / ('fixture-%d.ulg' % index)
                path.write_bytes(synthetic_ulog(drone_name=name))
                self.fixture_files.append(path)

    def scan(self, source=None):
        return analyzer.scan(source or self.source, self.database, self.output, self.progress)

    def require_private_corpus(self, minimum=1):
        if len(REAL_FILES) < minimum:
            self.skipTest("Set KATALOG_PRIVATE_FIXTURES to the external reference corpus")

    def copy(self, filename="test.ulg", source=None):
        destination = self.source / filename
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source or self.fixture_files[0], destination)
        return destination

    def test_real_nine_logs_exact_results_and_source_unchanged(self):
        self.require_private_corpus()
        self.assertEqual(len(REAL_FILES), 9, "Expected the supplied nine-log fixture")
        originals = {str(path): analyzer.digest_file(path) for path in REAL_FILES}
        result = self.scan(CARD)
        self.assertEqual(result["importStats"], {"discovered": 9, "imported": 9, "unchanged": 0, "duplicates": 0, "failed": 0})
        logs = result["logs"]
        self.assertEqual({log["status"] for log in logs}, {"ok"})
        self.assertEqual(len({log["droneID"] for log in logs}), 1)
        source_names = {analyzer.clean_name(ULog(str(path)).msg_info_dict.get("drone_name")) for path in REAL_FILES}
        source_names.discard("")
        self.assertEqual({log["droneName"] for log in logs}, source_names)
        self.assertAlmostEqual(sum(log["durationSeconds"] for log in logs), 4185.721797, places=5)
        self.assertAlmostEqual(sum(log["flightSeconds"] for log in logs), 4147.3523, places=5)
        messages = [message for log in logs for message in log["messages"]]
        self.assertEqual(len(messages), 360)
        self.assertEqual(sum(message["isAlert"] for message in messages), 84)
        self.assertEqual(sum(message["level"] == "INFO" for message in messages), 280)
        self.assertEqual(sum(log["failsafeObserved"] for log in logs), 1)
        self.assertEqual(sum("[batt_smbus]" in message["text"] for message in messages), 15)
        self.assertEqual(sum("Associate failed" in message["text"] for message in messages), 38)
        identified = [log for log in logs if log["metadata"].get("gcsUUID")]
        self.assertEqual(len(identified), 8)
        source_identities = {bytes.fromhex(str(ULog(str(path)).msg_info_dict["sys_uuid"])[12:])[::-1].hex().upper() for path in REAL_FILES}
        self.assertEqual({log["metadata"]["gcsUUID"] for log in identified}, source_identities)
        self.assertEqual({log["metadata"]["gcsIdentityStatus"] for log in identified}, {"verified"})
        missing = [log for log in logs if "gcsUUID" not in log["metadata"]]
        self.assertEqual(len(missing), 1)
        self.assertEqual(missing[0]["metadata"]["gcsIdentityStatus"], "unavailable")
        self.assertNotIn("dance_status", missing[0]["topics"])
        self.assertTrue(all(log["metadata"]["parserVersion"] == analyzer.PARSER_VERSION for log in logs))
        for log in logs:
            self.assertEqual(log["dateSource"], "gps")
            self.assertTrue(log["date"].endswith("Z"))
            self.assertTrue(any("binaires non décodés" in item for item in log["coverage"]))
            self.assertTrue(all(isinstance(value, str) for value in log["metadata"].values()))
            self.assertTrue(all(np.isfinite(metric["value"]) for metric in log["metrics"]))
        self.assertEqual(originals, {str(path): analyzer.digest_file(path) for path in REAL_FILES})
        self.assertEqual(json.loads(self.output.read_text())["logs"], logs)
        self.assertEqual(json.loads(self.progress.read_text())["completed"], 9)

    def test_reimport_does_not_hash_or_parse_unchanged_sources(self):
        self.copy()
        self.scan()
        with patch.object(analyzer, "analyze_file", side_effect=AssertionError("parsed unchanged file")), patch.object(analyzer, "digest_file", side_effect=AssertionError("hashed unchanged file")):
            result = self.scan()
        self.assertEqual(result["importStats"]["unchanged"], 1)
        self.assertEqual(len(result["logs"]), 1)

    def test_renamed_copy_and_case_insensitive_discovery(self):
        self.copy("original.ulg")
        self.scan()
        self.copy("other/subdir/RENAMED.ULG")
        result = self.scan()
        self.assertEqual(result["importStats"]["duplicates"], 1)
        self.assertEqual(result["importStats"]["unchanged"], 1)
        self.assertEqual(len(result["logs"]), 1)
        self.assertEqual(len(result["logs"][0]["sourcePaths"]), 2)

    def test_different_uuid_same_filename_is_a_second_drone(self):
        self.copy("card-one/log/2026-01-10/12_00_00.ulg")
        second = self.copy("card-two/log/2026-01-10/12_00_00.ulg")
        old = str(ULog(str(second)).msg_info_dict["sys_uuid"]).encode()
        new = old[:-2] + f"{int(old[-2:], 16) ^ 1:02x}".encode()
        data = second.read_bytes()
        self.assertEqual(data.count(old), 1)
        second.write_bytes(data.replace(old, new))
        result = self.scan()
        self.assertEqual(len(result["logs"]), 2)
        self.assertEqual({log["droneID"] for log in result["logs"]}, {old.decode(), new.decode()})
        contradictory = next(log for log in result["logs"] if log["droneID"] == new.decode())
        self.assertNotIn("gcsUUID", contradictory["metadata"])
        self.assertEqual(contradictory["metadata"]["gcsIdentityStatus"], "rejected")
        self.assertTrue(any("contradiction" in item for item in contradictory["coverage"]))

    def test_empty_folder_and_snapshot_persistence(self):
        result = self.scan()
        self.assertEqual(result["logs"], [])
        self.assertEqual(result["importStats"]["discovered"], 0)
        self.copy()
        imported = self.scan()
        db = analyzer.open_database(self.database)
        self.addCleanup(db.close)
        self.assertEqual(analyzer.snapshot(db)["logs"], imported["logs"])
        self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 1)

    def test_invalid_and_truncated_do_not_abort_valid_file(self):
        self.copy("valid.ulg")
        (self.source / "invalid.ulg").write_bytes(b"Not a ULog")
        truncated = self.copy("truncated.ulg")
        truncated.write_bytes(truncated.read_bytes()[:-5])
        result = self.scan()
        by_name = {log["fileName"]: log for log in result["logs"]}
        self.assertEqual(by_name["valid.ulg"]["status"], "ok")
        self.assertEqual(by_name["invalid.ulg"]["status"], "error")
        self.assertEqual(by_name["invalid.ulg"]["messages"], [])
        self.assertIn(by_name["truncated.ulg"]["status"], ("partial", "error"))
        self.assertTrue(any("tronqué" in issue for issue in by_name["truncated.ulg"]["issues"]))
        self.assertEqual(result["importStats"]["discovered"], 3)

    def test_unknown_loose_logs_are_not_merged_into_same_drone(self):
        (self.source / "one.ulg").write_bytes(b"bad one")
        (self.source / "two.ulg").write_bytes(b"bad two")
        result = self.scan()
        self.assertEqual(len({log["droneID"] for log in result["logs"]}), 2)

    def test_parser_change_invalidates_cache(self):
        self.copy()
        self.scan()
        with patch.object(analyzer, "PARSER_VERSION", "new-version"), patch.object(analyzer, "analyze_file", wraps=analyzer.analyze_file) as parse:
            result = self.scan()
            self.assertEqual(parse.call_count, 1)
        self.assertEqual(result["importStats"]["imported"], 1)
        self.assertEqual(len(result["logs"]), 1)

    def test_changed_file_retries_and_retains_historical_log(self):
        path = self.copy()
        first = self.scan()
        path.write_bytes(b"incomplete replacement")
        result = self.scan()
        self.assertEqual(len(result["logs"]), 2)
        self.assertEqual(result["importStats"]["failed"], 1)
        self.assertIn(first["logs"][0]["id"], [log["id"] for log in result["logs"]])
        old = next(log for log in result["logs"] if log["id"] == first["logs"][0]["id"])
        self.assertEqual(old["sourcePaths"], [])
        self.assertTrue(any("Source originale indisponible" in text for text in old["coverage"]))

    def test_permission_error_isolated_and_retry_removes_transient_error(self):
        self.assertGreaterEqual(len(self.fixture_files), 2)
        self.copy("one.ulg")
        path = self.copy("two.ulg", self.fixture_files[1])
        original_digest = analyzer.digest_file
        def digest(candidate):
            if candidate.resolve() == path.resolve():
                raise PermissionError("fixture read denied")
            return original_digest(candidate)
        with patch.object(analyzer, "digest_file", side_effect=digest):
            first = self.scan()
        self.assertEqual(first["importStats"]["failed"], 1)
        self.assertEqual(first["importStats"]["imported"], 1)
        result = self.scan()
        self.assertEqual(len(result["logs"]), 2)
        self.assertEqual({log["status"] for log in result["logs"]}, {"ok"})

    def test_unreadable_subdirectory_keeps_accessible_imports(self):
        self.copy("valid.ulg")
        unreadable = self.source / "card-unreadable"
        unreadable.mkdir()
        def failing_walk(root, onerror, **kwargs):
            onerror(PermissionError(13, "fixture read denied", str(unreadable.resolve())))
            yield str(self.source.resolve()), [], ["valid.ulg"]
        with patch.object(analyzer.os, "walk", side_effect=failing_walk):
            first = self.scan()
        self.assertEqual(first["importStats"]["imported"], 1)
        self.assertEqual(first["importStats"]["failed"], 1)
        self.assertEqual({log["status"] for log in first["logs"]}, {"ok", "error"})
        result = self.scan()
        self.assertEqual(len(result["logs"]), 1)
        self.assertEqual(result["logs"][0]["status"], "ok")

    def test_tagged_only_messages_are_preserved(self):
        def record(kind, payload):
            return struct.pack("<HB", len(payload), ord(kind)) + payload
        payload = ULog.HEADER_BYTES + bytes([1]) + struct.pack("<Q", 1_000_000)
        payload += record("F", b"dummy:uint64_t timestamp;")
        payload += record("A", struct.pack("<BH", 0, 1) + b"dummy")
        payload += record("C", struct.pack("<BHQ", 52, 42, 1_500_000) + b"[tagged] warning evidence")
        (self.source / "tagged.ulg").write_bytes(payload)
        result = self.scan()
        self.assertEqual(result["logs"][0]["status"], "ok")
        self.assertEqual(len(result["logs"][0]["messages"]), 1)
        self.assertEqual(result["logs"][0]["messages"][0]["level"], "WARNING")
        self.assertEqual(result["logs"][0]["messages"][0]["text"], "[tagged] warning evidence")
        self.assertEqual(result["logs"][0]["durationSeconds"], .5)

    def test_name_from_later_log_updates_old_same_uuid(self):
        self.copy("old.ulg")
        first = self.scan()
        self.assertEqual(first["logs"][0]["droneName"], "Drone non identifié")
        self.copy("recent.ulg", self.fixture_files[-1])
        result = self.scan()
        expected_name = analyzer.clean_name(ULog(str(self.fixture_files[-1])).msg_info_dict.get("drone_name"))
        self.assertTrue(expected_name)
        self.assertEqual({log["droneName"] for log in result["logs"]}, {expected_name})

    def test_card_name_can_be_added_after_cached_import(self):
        self.copy("card/log/old.ulg")
        self.scan()
        metadata = self.source / "card/data/name.txt"
        metadata.parent.mkdir()
        metadata.write_text("Fleet drone 8\x00\n")
        result = self.scan()
        self.assertEqual(result["logs"][0]["droneName"], "Fleet drone 8")
        self.assertEqual(result["importStats"]["unchanged"], 1)

    def test_cloud_only_optional_card_name_does_not_block_import_or_cached_rescan(self):
        log = self.source / 'card/log/old.ulg'
        log.parent.mkdir(parents=True)
        log.write_bytes(synthetic_ulog(drone_name=None))
        metadata = (self.source / 'card/data/name.txt').resolve()
        metadata.parent.mkdir()
        metadata.write_text('Hydrated card name')
        actual = metadata.stat()
        attributes = {key: getattr(actual, key) for key in dir(actual) if key.startswith('st_')}
        attributes['st_flags'] = 0x40000060
        original_stat, original_open = Path.stat, Path.open
        attempts = []

        def file_stat(path, *args, **kwargs):
            return SimpleNamespace(**attributes) if path == metadata else original_stat(path, *args, **kwargs)

        def file_open(path, *args, **kwargs):
            if path == metadata:
                attempts.append(path)
                raise AssertionError('Optional cloud-only name.txt must not be opened to hydrate it')
            return original_open(path, *args, **kwargs)

        with patch.object(Path, 'stat', file_stat), patch.object(Path, 'open', file_open), \
             patch.object(analyzer.sys, 'platform', 'darwin'):
            first = self.scan()
            second = self.scan()
        self.assertEqual(attempts, [])
        self.assertEqual(first['importStats']['imported'], 1)
        self.assertEqual(second['importStats']['unchanged'], 1)
        self.assertEqual(first['logs'][0]['status'], 'ok')
        self.assertEqual(second['logs'][0]['droneName'], 'Drone non identifié')
        hydrated = self.scan()
        self.assertEqual(hydrated['logs'][0]['id'], first['logs'][0]['id'])
        self.assertEqual(hydrated['logs'][0]['droneName'], 'Hydrated card name')
        self.assertEqual(hydrated['importStats']['unchanged'], 1)

    def test_cli_scan_and_snapshot(self):
        self.copy()
        for command in (
            ["scan", "--folder", str(self.source), "--database", str(self.database), "--output", str(self.output), "--progress", str(self.progress)],
            ["snapshot", "--database", str(self.database), "--output", str(self.output)],
        ):
            result = subprocess.run([sys.executable, str(SCRIPT), *command], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(self.output.read_text())["schemaVersion"], 1)
        self.assertEqual(list(self.work.glob(".report.json.*")), [])

    def test_exact_ulg_file_scan_does_not_rescan_siblings(self):
        selected = self.copy('one.ULG')
        self.copy('ignored-two.ulg', self.fixture_files[-1])
        result = analyzer.scan(selected, self.database)
        self.assertEqual(result['importStats']['discovered'], 1)
        self.assertEqual(len(result['logs']), 1)
        self.assertEqual(result['logs'][0]['sourcePaths'], [str(selected.resolve())])
        folder = self.scan()
        self.assertEqual(folder['importStats']['discovered'], 2)
        self.assertEqual(len(folder['logs']), 2)

    def test_500_duplicate_paths_parse_only_once(self):
        original = self.copy("card-000/session.ulg", min(self.fixture_files, key=lambda path: path.stat().st_size))
        for index in range(1, 500):
            destination = self.source / f"card-{index:03}/session.ulg"
            destination.parent.mkdir()
            os.link(original, destination)
        start = time.monotonic()
        with patch.object(analyzer, "analyze_file", wraps=analyzer.analyze_file) as parse:
            first = self.scan()
            self.assertEqual(parse.call_count, 1)
        elapsed = time.monotonic() - start
        start = time.monotonic()
        second = self.scan()
        cached_elapsed = time.monotonic() - start
        self.assertEqual(first["importStats"]["duplicates"], 499)
        self.assertEqual(len(first["logs"][0]["sourcePaths"]), 500)
        self.assertEqual(second["importStats"]["unchanged"], 500)
        print(f"\n500 duplicate paths: first {elapsed:.3f}s; cached {cached_elapsed:.3f}s; 1 parse, 499 content duplicates.")


class MetricTests(unittest.TestCase):
    def empty(self):
        return {"metrics": [], "coverage": [], "flightSeconds": None}

    def dataset(self, name, **data):
        return SimpleNamespace(name=name, multi_id=0, data={key: np.asarray(value) for key, value in data.items()})

    def test_gps_weighted_by_time_not_samples_and_excludes_long_gaps(self):
        log = self.empty()
        gps = self.dataset("sensor_gps", timestamp=[0, 1e6, 4e6, 25e6, 27e6], fix_type=[6, 5, 6, 3, 6])
        analyzer.gps_metrics(log, gps, 0, 27)
        metrics = {metric["key"]: metric["value"] for metric in log["metrics"]}
        self.assertAlmostEqual(metrics["gps.rtk_fixed"], 100 / 6, places=5)
        self.assertAlmostEqual(metrics["gps.rtk_float"], 50)
        self.assertAlmostEqual(metrics["gps.observed_seconds"], 6)
        self.assertTrue(any("exclus" in item for item in log["coverage"]))

    def test_multiple_gps_instances_have_separate_keys(self):
        log = self.empty()
        first = self.dataset("sensor_gps", timestamp=[0, 1e6], fix_type=[6, 6])
        second = self.dataset("sensor_gps", timestamp=[0, 1e6], fix_type=[5, 5])
        second.multi_id = 1
        analyzer.gps_metrics(log, first, 0, 1)
        analyzer.gps_metrics(log, second, 0, 1)
        metrics = {metric["key"]: metric["value"] for metric in log["metrics"]}
        self.assertEqual(metrics["gps.rtk_fixed"], 100)
        self.assertEqual(metrics["gps.rtk_fixed.1"], 0)

    def test_non_monotonic_timestamps_do_not_double_count(self):
        data = self.dataset("vehicle_land_detected", timestamp=[0, 1e6, .5e6, 1.5e6, 2e6], landed=[0, 0, 0, 0, 0])
        log = self.empty()
        analyzer.flight_duration(log, [data], 0, 2)
        self.assertIsNone(log["flightSeconds"])
        data.name = "sensor_gps"
        data.data["fix_type"] = np.array([6, 6, 6, 6, 6])
        analyzer.gps_metrics(log, data, 0, 2)
        self.assertFalse(any(metric["key"] == "gps.rtk_fixed" for metric in log["metrics"]))

    def test_battery_filters_nan_sentinels_and_disconnected_values(self):
        log = self.empty()
        battery = self.dataset("battery_status", voltage_v=[0, 10, np.nan, 1], current_a=[-1, 4, np.nan, 99], temperature=[np.nan, 25, -300, 99], connected=[1, 1, 1, 0])
        analyzer.battery_metrics(log, battery)
        metrics = {metric["key"]: metric["value"] for metric in log["metrics"]}
        self.assertEqual(metrics["battery.voltage_min"], 10)
        self.assertEqual(metrics["battery.current_max"], 4)
        self.assertEqual(metrics["battery.temperature_max"], 25)
        json.dumps(log, allow_nan=False)

    def test_missing_land_data_is_unknown_not_zero(self):
        log = self.empty()
        analyzer.flight_duration(log, [], 0, 200)
        self.assertIsNone(log["flightSeconds"])
        incomplete = self.dataset("vehicle_land_detected", timestamp=[0, 1e6, 200e6], landed=[0, 0, 1])
        analyzer.flight_duration(log, [incomplete], 0, 200)
        self.assertIsNone(log["flightSeconds"])

    def test_short_flight_duration_requires_actual_coverage_not_absolute_tolerance(self):
        log = self.empty()
        sparse = self.dataset("vehicle_land_detected", timestamp=[.5e6, .6e6], landed=[0, 0])
        analyzer.flight_duration(log, [sparse], 0, 1.5)
        self.assertIsNone(log["flightSeconds"])
        self.assertAlmostEqual(log["flightObservedSeconds"], .1)
        self.assertAlmostEqual(log["flightCoverageSeconds"], .1)
        self.assertAlmostEqual(log["flightCoverageFraction"], .1 / 1.5, places=6)
        self.assertTrue(any("6.7 %" in value for value in log["coverage"]))

    def test_complete_short_log_reports_duration_and_coverage(self):
        log = self.empty()
        complete = self.dataset("vehicle_land_detected", timestamp=[0, .5e6, 1e6, 1.5e6], landed=[1, 0, 0, 1])
        analyzer.flight_duration(log, [complete], 0, 1.5)
        self.assertEqual(log["flightSeconds"], 1)
        self.assertEqual(log["flightObservedSeconds"], 1)
        self.assertEqual(log["flightCoverageSeconds"], 1.5)
        self.assertEqual(log["flightCoverageFraction"], 1)

    def test_unknown_flight_samples_do_not_become_zero_observed_flight(self):
        log = self.empty()
        invalid = self.dataset("vehicle_land_detected", timestamp=[0, 1e6], landed=[2, 2])
        analyzer.flight_duration(log, [invalid], 0, 1)
        self.assertIsNone(log["flightSeconds"])
        self.assertIsNone(log["flightObservedSeconds"])
        self.assertEqual(log["flightCoverageSeconds"], 0)
        self.assertEqual(log["flightCoverageFraction"], 0)

    def test_no_land_topic_keeps_all_coverage_values_unknown(self):
        log = self.empty()
        analyzer.flight_duration(log, [], 0, 1)
        for key in ("flightSeconds", "flightObservedSeconds", "flightCoverageSeconds", "flightCoverageFraction"):
            self.assertIsNone(log[key])

    def test_exact_levels_relative_times_and_alarm_info(self):
        for number, level in enumerate(analyzer.LEVELS):
            raw = SimpleNamespace(message="[maestro] [ALARM] COMMUNICATION_FENCING started\t", timestamp=1_500_000, log_level=48 + number)
            result = analyzer.make_message(raw, 1_000_000, "abc", number)
            self.assertEqual(result["level"], level)
            self.assertEqual(result["timestampSeconds"], .5)
            self.assertEqual(result["text"], raw.message)
            self.assertTrue(result["isAlert"])
            self.assertEqual(result["family"], "Communication")
        self.assertTrue(analyzer.is_alert("[commander] Connection to ground station lost", "INFO"))
        self.assertFalse(analyzer.is_alert("[commander] Takeoff detected", "INFO"))

    def test_conservative_grouping_retains_error_codes(self):
        groups = []
        for code in (-1, -2):
            raw = SimpleNamespace(message=f"[batt_smbus] SMBus read error: {code}", timestamp=0, log_level=51)
            groups.append(analyzer.make_message(raw, 0, "x", 0)["groupKey"])
        self.assertNotEqual(*groups)

    def test_message_families_cover_subsystems_and_keep_led_heat_in_lighting(self):
        examples = {
            "[batt_smbus] SMBus read error: -1": "Batterie",
            "[battery] Temperature too high": "Batterie",
            "[wifi_broadcom] Wifi link lost": "Communication",
            "GNSS RTK correction lost": "GNSS",
            "Preflight Fail: Accel 0 inconsistent - check cal": "Capteurs",
            "[esc_status] motor error": "Propulsion",
            "[navigator] landing failed": "Navigation",
            "[logger] write failed": "Système",
            "[rgbled_pwm] Temperature too high disabling LED": "Éclairage",
            "[driver] LED disconnected": "Éclairage",
            "Temperature too high": "Température",
            "[commander] thermal warning": "Température",
            "Something failed": "Autres",
        }
        self.assertEqual(set(examples.values()), set(analyzer.MESSAGE_FAMILIES))
        for message, family in examples.items():
            with self.subTest(message=message):
                self.assertEqual(analyzer.message_family(message), family)

    def identity_dataset(self, identity="1112131415161718191A1B1C", samples=3):
        data = {f"uuid[{index}]": np.repeat(value, samples) for index, value in enumerate(bytes.fromhex(identity))}
        data["timestamp"] = np.arange(samples)
        return self.dataset("dance_status", **data)

    def test_gcs_uuid_reads_all_bytes_and_validates_known_drotek_sys_uuid(self):
        identity = "1112131415161718191A1B1C"
        info = {"ver_hw": "DROTEK_IO_STAR_TROIS", "sys_uuid": "0002000000001c1b1a191817161514131211"}
        coverage = []
        self.assertEqual(analyzer.gcs_uuid([self.identity_dataset()], info, coverage), identity)
        self.assertEqual(coverage, [])
        # Same identity across distinct uORB instances is valid.
        self.assertEqual(analyzer.gcs_uuid([self.identity_dataset(), self.identity_dataset()], info, []), identity)
        self.assertEqual(analyzer.gcs_uuid([self.identity_dataset()], {}, []), identity)
        self.assertIsNone(analyzer.gcs_uuid([], info, []), "sys_uuid alone is not an observed GCS identity")

    def test_gcs_uuid_rejects_malformed_variable_and_broadcast_values(self):
        invalid = []
        missing = self.identity_dataset(); del missing.data["uuid[11]"]; invalid.append(missing)
        extra = self.identity_dataset(); extra.data["uuid[12]"] = np.array([0, 0, 0]); invalid.append(extra)
        variable = self.identity_dataset(); variable.data["uuid[11]"][1] += 1; invalid.append(variable)
        negative = self.identity_dataset(); negative.data["uuid[0]"][1] = -1; invalid.append(negative)
        oversized = self.identity_dataset(); oversized.data["uuid[0]"][1] = 256; invalid.append(oversized)
        floating = self.identity_dataset(); floating.data["uuid[0]"] = np.array([51., 51., 51.]); invalid.append(floating)
        short = self.identity_dataset(); short.data["uuid[0]"] = np.array([51, 51]); invalid.append(short)
        scalar = self.identity_dataset(); scalar.data["timestamp"] = np.array(1); invalid.append(scalar)
        invalid.extend([self.identity_dataset(samples=0), self.identity_dataset("00" * 12), self.identity_dataset("FF" * 12)])
        for index, dataset in enumerate(invalid):
            with self.subTest(case=index):
                coverage = []
                self.assertIsNone(analyzer.gcs_uuid([dataset], {}, coverage))
                self.assertTrue(coverage)

    def test_gcs_uuid_contradictions_never_create_an_association(self):
        first = self.identity_dataset()
        other = self.identity_dataset("0102030405060708090A0B0C")
        coverage = []
        self.assertIsNone(analyzer.gcs_uuid([first, other], {}, coverage))
        self.assertTrue(any("contradictoires" in item for item in coverage))
        info = {"ver_hw": "DROTEK_IO_STAR_TROIS", "sys_uuid": "0002000000000c0b0a090807060504030201"}
        coverage = []
        self.assertIsNone(analyzer.gcs_uuid([first], info, coverage))
        self.assertTrue(any("contradiction" in item for item in coverage))

    def test_gps_date_requires_clock_consistency(self):
        good = self.dataset("sensor_gps", timestamp=[10e6, 11e6], time_utc_usec=[1_750_000_000e6, 1_750_000_001e6])
        self.assertEqual(analyzer.gps_date([good], 10, []), "2025-06-15T15:06:40Z")
        good.data["time_utc_usec"][1] += 10e6
        coverage = []
        self.assertIsNone(analyzer.gps_date([good], 10, coverage))
        self.assertTrue(coverage)
        date, source = analyzer.path_date(Path("/card/log/2026-01-10/12_00_00.ulg"))
        self.assertEqual((date, source), ("2026-01-10T12:00:00", "path"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
