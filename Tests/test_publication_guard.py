"""Publication guard tests use constructed, synthetic private-looking data."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).parents[1] / "tools" / "check-publication.py"
SPEC = importlib.util.spec_from_file_location("publication_guard", MODULE_PATH)
guard = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = guard
SPEC.loader.exec_module(guard)


class PublicationGuardTests(unittest.TestCase):
    def test_sensitive_categories_and_redacted_output(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as private:
            root = Path(folder)
            private_user_path = "/" + "Users" + "/synthetic-person/flight"
            fake_token = "ghp_" + "a" * 40
            fake_key = "-----BEGIN " + "PRIVATE KEY-----"
            lan = ".".join(str(part) for part in (192, 168, 7, 99))
            secret_identifier = "synthetic-unique-controller-id"
            (root / "source.py").write_text("\n".join((private_user_path, fake_token, fake_key, lan)), encoding="utf-8")
            (root / "binary.dat").write_bytes(b"\x00\xff" + secret_identifier.encode())
            (root / "settings.json").write_text("{}")
            (root / "log.ulg").write_bytes(b"fake")
            (root / "fleet.sqlite").write_bytes(b"fake")
            (root / "stock.csv").write_text("a,b\n")
            (root / "photo.png").write_bytes(b"fake")
            blocklist = Path(private) / "private.json"
            blocklist.write_text(json.dumps({"not-displayed-category": [secret_identifier]}))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = guard.main(["--path", str(root), "--blocklist", str(blocklist)])
            self.assertEqual(code, 1)
            expected = {"chemin-utilisateur", "secret-ou-cle-privee", "adresse-reseau-local", "identifiant-prive-blocklist", "etat-local-ou-secret", "log-brut", "base-de-donnees", "csv-non-synthetique", "image-a-verifier"}
            for category in expected:
                self.assertIn("[" + category + "]", output.getvalue())
            for sensitive in (private_user_path, fake_token, fake_key, lan, secret_identifier, "not-displayed-category", str(root), str(blocklist)):
                self.assertNotIn(sensitive, output.getvalue())
            self.assertIn('"binary.dat" [identifiant-prive-blocklist]', output.getvalue())

    def test_safe_placeholders_documentation_addresses_and_synthetic_fixture(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "source.py").write_text("/Users/USER/demo\n/Users/<username>/demo\nhttp://127.0.0.1\nhttp://192.0.2.5\nhttp://198.51.100.25\nhttp://203.0.113.5\npassword = 'example-password'\n")
            (root / ".gitignore").write_text("*.db\n*.ulg\nreports/\n.env\n")
            fixture = root / "Tests" / "fixtures" / "synthetic" / "fleet.csv"
            fixture.parent.mkdir(parents=True)
            fixture.write_text("demo,value\n")
            icon = root / "assets" / "icon" / "app.png"
            icon.parent.mkdir(parents=True)
            icon.write_bytes(b"synthetic")
            self.assertEqual(guard.scan(root, guard.export_files(root), ()), [])

    def test_literal_secrets_and_safe_secret_placeholder(self):
        private_assignment = "api_key = '" + "notrealvalue123" + "'"
        result = guard.content_findings(Path("source.txt"), private_assignment.encode(), ())
        self.assertEqual({finding.category for finding in result}, {"secret-litteral"})
        self.assertEqual(guard.content_findings(Path("source.txt"), b"api_key = 'your_example_key'", ()), set())

    def test_symlinks_missing_files_and_oversized_file_are_not_silently_ignored(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "source.txt").write_text("okay")
            (root / "linked.txt").symlink_to(root / "source.txt")
            with (root / "large.dat").open("wb") as stream:
                stream.truncate(guard.MAX_FILE_BYTES + 1)
            result = guard.scan(root, [Path("linked.txt"), Path("missing.txt"), Path("large.dat")], ())
            self.assertEqual({item.category for item in result}, {"lien-symbolique-a-verifier", "fichier-selectionne-manquant", "fichier-volumineux-non-analyse"})

    def test_git_selection_untracked_and_extra(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "tracked.txt").write_text("okay")
            (root / "new.txt").write_text("okay")
            (root / "ignored.txt").write_text("okay")
            (root / ".gitignore").write_text("ignored.txt\n")
            subprocess.run(["git", "-C", str(root), "add", "tracked.txt", ".gitignore"], check=True)
            self.assertEqual(guard.git_files(root, False), [Path(".gitignore"), Path("tracked.txt")])
            self.assertEqual(guard.git_files(root, True), [Path(".gitignore"), Path("new.txt"), Path("tracked.txt")])
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(guard.main(["--repo", str(root), "--extra", "ignored.txt"]), 0)

    def test_blocklist_must_stay_outside_export_and_errors_do_not_echo_values(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            blocklist = root / "private.json"
            blocklist.write_text(json.dumps(["synthetic-sensitive-value"]))
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                self.assertEqual(guard.main(["--path", str(root), "--blocklist", str(blocklist)]), 2)
            self.assertNotIn(str(root), output.getvalue())
            self.assertNotIn("synthetic-sensitive-value", output.getvalue())
            blocklist.write_text('{"synthetic-sensitive-value": [')
            with contextlib.redirect_stderr(output):
                self.assertEqual(guard.main(["--path", str(root), "--blocklist", str(blocklist)]), 2)
            self.assertNotIn("synthetic-sensitive-value", output.getvalue())

    def test_runtime_state_is_ignored_and_forced_git_add_is_still_blocked(self):
        # Even an empty local config is private. Test both the repository's
        # ignore rules and the guard after someone explicitly bypasses them.
        names = ["annotations.json", "settings.json", "views.json", "fleet.json",
                 "gcs-settings.json", "gcs-collection.json", "import-options.json",
                 "progress.json", ".archive-journal.json", ".restore-journal.json"]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".gitignore").write_bytes((MODULE_PATH.parents[1] / ".gitignore").read_bytes())
            for name in names:
                (root / name).write_text("{}")
            self.assertEqual(guard.git_files(root, True), [Path(".gitignore")])
            subprocess.run(["git", "-C", str(root), "add", "-f", "--", *names], check=True)
            findings = guard.scan(root, guard.git_files(root, True), ())
            self.assertEqual({item.path for item in findings}, set(names))
            self.assertEqual({item.category for item in findings}, {"etat-local-ou-secret"})

    def test_control_characters_in_names_are_escaped(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            filename = "test\nsecret.ulg"
            (root / filename).write_bytes(b"fake")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(guard.main(["--path", str(root)]), 1)
            self.assertIn('"test\\nsecret.ulg"', output.getvalue())

    def test_guard_own_source_is_clean(self):
        self.assertEqual(guard.content_findings(Path("tools/check-publication.py"), MODULE_PATH.read_bytes(), ()), set())

    def test_renamed_raw_data_and_generated_reports_are_blocked(self):
        cases = ((b"ULog" + bytes((1, 18, 53)), "log-brut"),
                 (b"SQLite format 3" + bytes((0,)), "base-de-donnees"),
                 (bytes.fromhex("cffaedfe"), "binaire-compile-a-verifier"))
        for data, category in cases:
            self.assertEqual({finding.category for finding in guard.content_findings(Path("innocent.dat"), data, ())}, {category})
        self.assertIn("rapport-genere", guard.path_categories(Path("fleet-report.html")))
        self.assertEqual(guard.path_categories(Path("Sources/ReportRenderer.swift")), set())

    def test_extra_path_cannot_read_through_symlink_parent(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as outside:
            root = Path(folder)
            (Path(outside) / "outside.txt").write_text("okay")
            (root / "linked").symlink_to(outside, target_is_directory=True)
            result = guard.scan(root, [Path("linked/outside.txt")], ())
            self.assertEqual({finding.category for finding in result}, {"lien-symbolique-a-verifier"})


if __name__ == "__main__":
    unittest.main()
