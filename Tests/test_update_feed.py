"""Local update preparation: fabricated archives, no Keychain or remote publishing."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("katalog_update_feed", ROOT / "tools/update-feed.py")
feed = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(feed)
KEY = base64.b64encode(bytes(range(1, 33))).decode()
SIGNATURE = base64.b64encode(bytes(range(64))).decode()


class UpdateFeedTests(unittest.TestCase):
    def test_ui_review_preview_cannot_activate_feed_or_become_update_archive(self):
        info = dict(CFBundleIdentifier="com.mehdiguiard.katalog.preview06", CFBundleShortVersionString="0.6.0",
                    CFBundleVersion="8", KataLogUIReviewPreview=True)
        disabled = feed.configured_info(info)
        self.assertFalse(disabled["KatalogUpdatesEnabled"])
        with self.assertRaisesRegex(ValueError, "review UI"):
            feed.configured_info(info, "stable", "https://example.org/appcast.xml", KEY)
        with tempfile.TemporaryDirectory(prefix="katalog-preview-feed-") as directory:
            archive = Path(directory) / "KataLog-Preview-0.6.0-macOS-arm64.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("KataLog Preview.app/Contents/Info.plist", plistlib.dumps(disabled))
            with self.assertRaisesRegex(ValueError, "preview UI"):
                feed.archive_info(archive)

    def metadata(self, *, channel="disabled", build="9"):
        info = dict(CFBundleIdentifier="com.mehdiguiard.katalog", CFBundleShortVersionString="0.6.0",
                    CFBundleVersion=build, LSMinimumSystemVersion="15.0")
        return feed.configured_info(info, channel,
                                    "https://updates.example.org/" + channel + "/appcast.xml" if channel != "disabled" else None,
                                    KEY if channel != "disabled" else None)

    def archive(self, directory, info):
        archive = directory / "KataLog-0.6.0-macOS-arm64.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("KataLog.app/Contents/Info.plist", plistlib.dumps(info))
            output.writestr("KataLog.app/Contents/Resources/synthetic.txt", "fabricated update fixture")
        return archive

    def test_disabled_configuration_has_no_feed_key_or_automatic_activity(self):
        info = feed.configured_info(dict(SUFeedURL="https://old.example.org/appcast.xml", SUPublicEDKey=KEY))
        self.assertFalse(info["KatalogUpdatesEnabled"])
        self.assertEqual(info["KatalogUpdateChannel"], "disabled")
        self.assertNotIn("SUFeedURL", info)
        self.assertNotIn("SUPublicEDKey", info)
        for name in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableJavaScript", "SUEnableSystemProfiling"):
            self.assertIs(info[name], False)
        self.assertIs(info["SURequireSignedFeed"], True)
        self.assertIs(info["SUVerifyUpdateBeforeExtraction"], True)
        self.assertEqual(info["SUSignedFeedFailureExpirationInterval"], 0)
        with self.assertRaises(ValueError):
            feed.configured_info({}, "disabled", "https://example.org/appcast.xml", KEY)

    def test_activation_requires_https_feed_canonical_public_key_and_known_channel(self):
        for channel in ("stable", "staging"):
            self.assertTrue(self.metadata(channel=channel)["KatalogUpdatesEnabled"])
        for url in ("http://example.org/appcast.xml", "https://user:password@example.org/appcast.xml",
                    "https://example.org/appcast.xml?token=test", "https://example.org/appcast.xml#fragment",
                    "https://example.org:8443/appcast.xml", "https://example.org/file.zip", "https://[::1]/appcast.xml"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                feed.configured_info({}, "stable", url, KEY)
        for key in ("", "invalid", base64.b64encode(bytes(32)).decode(), base64.b64encode(bytes(64)).decode()):
            with self.subTest(key=key), self.assertRaises(ValueError):
                feed.configured_info({}, "stable", "https://example.org/appcast.xml", key)
        with self.assertRaises(ValueError):
            feed.configured_info({}, "other")

    def test_appcast_restricts_platform_build_architecture_and_staging(self):
        for channel in ("stable", "staging"):
            document = ET.fromstring(feed.feed_xml(self.metadata(channel=channel), "https://example.org/app.zip", 123,
                                                  "Correction <test> & fiabilité\nSeconde ligne", channel, SIGNATURE))
            item = document.find("channel/item")
            self.assertEqual(item.findtext("{" + feed.SPARKLE + "}version"), "9")
            self.assertEqual(item.findtext("{" + feed.SPARKLE + "}minimumSystemVersion"), "15.0.0")
            self.assertEqual(item.findtext("{" + feed.SPARKLE + "}hardwareRequirements"), "arm64")
            self.assertEqual(item.findtext("{" + feed.SPARKLE + "}channel"), "staging" if channel == "staging" else None)
            self.assertEqual(item.find("enclosure").get("{" + feed.SPARKLE + "}edSignature"), SIGNATURE)
            self.assertIn("&lt;test&gt;", item.findtext("description"))

    def test_draft_preserves_archive_and_creates_only_local_unsigned_reviewable_files(self):
        with tempfile.TemporaryDirectory(prefix="katalog-update-test-") as directory:
            work = Path(directory)
            archive = self.archive(work, self.metadata())
            original = archive.read_bytes()
            output = work / "draft"
            with patch.object(feed, "tool", side_effect=AssertionError("No signing or Keychain for draft")):
                manifest = feed.prepare(archive, "https://example.org/" + archive.name, output, "Synthetic notes", "staging", draft=True)
            self.assertEqual(archive.read_bytes(), original)
            self.assertEqual((output / archive.name).read_bytes(), original)
            self.assertFalse(manifest["uploaded"])
            self.assertEqual(manifest["status"], "draft")
            self.assertEqual(manifest["archiveSHA256"], hashlib.sha256(original).hexdigest())
            self.assertTrue((output / "appcast.draft.xml").is_file())
            self.assertFalse((output / "appcast.xml").exists())
            self.assertNotIn(str(work), (output / "update-manifest.json").read_text())
            with self.assertRaisesRegex(ValueError, "existe déjà"):
                feed.prepare(archive, "https://example.org/" + archive.name, output, "Notes", "staging", draft=True)

    def test_wrong_build_name_channel_security_and_private_notes_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="katalog-update-test-") as directory:
            work = Path(directory)
            archive = self.archive(work, self.metadata())
            url = "https://example.org/" + archive.name
            for previous in (9, 10):
                with self.assertRaisesRegex(ValueError, "build doit augmenter"):
                    feed.prepare(archive, url, work / "invalid", "Notes", "stable", draft=True, previous_build=previous)
            with self.assertRaisesRegex(ValueError, "nom exact"):
                feed.prepare(archive, "https://example.org/wrong.zip", work / "invalid", "Notes", "stable", draft=True)
            with self.assertRaisesRegex(ValueError, "même canal"):
                feed.prepare(archive, url, work / "invalid", "Notes", "stable", previous_build=8)
            for notes in ("x" * (128 * 1024 + 1), "/" + "Users/example/personal"):
                with self.assertRaises(ValueError):
                    feed.prepare(archive, url, work / "notes-invalid", notes, "stable", draft=True)
            self.assertFalse((work / "invalid").exists())

    def test_signed_preparation_verifies_archive_and_feed_with_matching_dedicated_key(self):
        with tempfile.TemporaryDirectory(prefix="katalog-update-test-") as directory:
            work = Path(directory)
            archive = self.archive(work, self.metadata(channel="staging"))
            sign = work / "sign_update"; sign.touch()
            calls = []
            def tool(arguments):
                calls.append(arguments)
                if Path(arguments[0]).name == "generate_keys":
                    return KEY
                if "--verify" in arguments:
                    return ""
                if str(arguments[-1]).endswith(".zip"):
                    return SIGNATURE
                candidate = Path(arguments[-1])
                candidate.write_bytes(b"<!-- synthetic embedded feed signature -->\n" + candidate.read_bytes())
                return ""
            with patch.object(feed, "tool", side_effect=tool):
                result = feed.prepare(archive, "https://example.org/" + archive.name, work / "signed", "Synthetic", "staging",
                                      sign_update=sign, previous_build=8)
            self.assertEqual(result["status"], "signed-local")
            self.assertFalse(result["uploaded"])
            self.assertEqual(len(calls), 5)
            self.assertTrue(all("katalog-sparkle-staging" in call for call in calls))
            self.assertEqual(sum("--verify" in call for call in calls), 2)
            document = (work / "signed/appcast.xml").read_text()
            self.assertIn(SIGNATURE, document)
            self.assertIn("embedded feed signature", document)

    def test_mismatched_key_and_unsafe_archive_security_never_produce_signed_feed(self):
        with tempfile.TemporaryDirectory(prefix="katalog-update-test-") as directory:
            work = Path(directory)
            archive = self.archive(work, self.metadata(channel="stable"))
            sign = work / "sign_update"; sign.touch()
            different = base64.b64encode(bytes([33]) * 32).decode()
            with patch.object(feed, "tool", return_value=different), self.assertRaisesRegex(ValueError, "ne correspond pas"):
                feed.prepare(archive, "https://example.org/" + archive.name, work / "signed", "Notes", "stable", sign_update=sign, previous_build=8)
            unsafe = self.metadata(channel="stable"); unsafe["SURequireSignedFeed"] = False
            archive = self.archive(work, unsafe)
            with patch.object(feed, "tool", side_effect=AssertionError("No key lookup for unsafe metadata")), self.assertRaisesRegex(ValueError, "configuration signée"):
                feed.prepare(archive, "https://example.org/" + archive.name, work / "signed", "Notes", "stable", sign_update=sign, previous_build=8)
            self.assertFalse((work / "signed").exists())

    def test_private_key_files_are_refused_inside_repository_or_output(self):
        with tempfile.TemporaryDirectory(prefix="katalog-update-test-") as directory:
            work = Path(directory)
            archive = self.archive(work, self.metadata(channel="staging"))
            sign = work / "sign_update"; sign.touch()
            for path in (ROOT / "never-created-test.key", work / "output/test.key"):
                with self.assertRaisesRegex(ValueError, "jamais être placée"):
                    feed.prepare(archive, "https://example.org/" + archive.name, work / "output", "Notes", "staging", sign_update=sign,
                                 private_key_file=path, previous_build=8)

    def test_signed_preparation_requires_explicit_previous_build_before_key_lookup(self):
        with tempfile.TemporaryDirectory(prefix="katalog-update-test-") as directory:
            work = Path(directory)
            archive = self.archive(work, self.metadata(channel="staging"))
            with patch.object(feed, "tool", side_effect=AssertionError("No Keychain without a build baseline")):
                with self.assertRaisesRegex(ValueError, "build précédent est requis"):
                    feed.prepare(archive, "https://example.org/" + archive.name, work / "output", "Notes", "staging")
                with self.assertRaisesRegex(ValueError, "négatif"):
                    feed.prepare(archive, "https://example.org/" + archive.name, work / "output", "Notes", "staging", draft=True, previous_build=-1)


if __name__ == "__main__":
    unittest.main()
