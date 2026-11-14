"""Reject final release assets that do not belong to the selected source commit."""
import importlib.util
import json
from pathlib import Path
import plistlib
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
SPEC = importlib.util.spec_from_file_location('katalog_release_candidate', ROOT / 'tools/verify-release-candidate.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseCandidateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='katalog-release-contract-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / 'KataLog.app'
        self.resource = self.app / 'Contents/Resources'
        self.resource.mkdir(parents=True)
        self.manifest_path = self.app / 'Contents/Helpers/KataLogEngine.app/Contents/Resources/runtime-manifest.json'
        self.manifest_path.parent.mkdir(parents=True)
        for path, value in {
            'project.yml': '        MARKETING_VERSION: 0.9.0\n        CURRENT_PROJECT_VERSION: 28\n',
            'updates/stable/public-key.txt': 'public-test-key\n',
            'Sources/KataLog/Resources/usb_collect.py': 'VERSION = "current"\n',
            'requirements-runtime.txt': 'runtime-input',
            'requirements-runtime-build.txt': 'build-input',
            'tools/engine-entry.py': 'entry-input',
            'tools/KataLogEngine.spec': 'spec-input',
        }.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(value)
        self.source = self.root / 'Sources/KataLog/Resources/usb_collect.py'
        (self.resource / self.source.name).write_bytes(self.source.read_bytes())
        self.manifest = dict(architecture='arm64', sourceHashes={self.source.name: release.sha256(self.source)},
            requirementsHashes={name: release.sha256(self.root / name) for name in ('requirements-runtime.txt', 'requirements-runtime-build.txt')},
            buildInputHashes={name: release.sha256(self.root / 'tools' / name) for name in ('engine-entry.py', 'KataLogEngine.spec')})
        self.info = dict(CFBundleIdentifier='com.mehdiguiard.katalog', CFBundleShortVersionString='0.9.0',
            CFBundleVersion='28', KatalogArchitecture='arm64', KatalogUpdateChannel='stable', KatalogUpdatesEnabled=True,
            SUFeedURL='https://raw.githubusercontent.com/mehdi7129/KataLog/main/updates/stable/appcast.xml', SUPublicEDKey='public-test-key')
        self.write()

    def write(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
        self.manifest_path.write_text(json.dumps(self.manifest))

    def validate(self, arch='arm64', tag='v0.9.0'):
        return release.validate_candidate_bundle(self.app, arch, tag, self.root)

    def test_both_native_candidates_bind_exact_source_and_architecture(self):
        self.assertTrue(self.validate()['runtimeInputsMatchCheckout'])
        self.info['KatalogArchitecture'] = self.manifest['architecture'] = 'x86_64'
        self.info['SUFeedURL'] = self.info['SUFeedURL'].replace('/stable/', '/stable-intel/')
        self.write()
        self.assertEqual(self.validate('x86_64')['architecture'], 'x86_64')

    def test_relabelled_old_build_wrong_feed_key_or_preview_cannot_pass(self):
        changes = dict(CFBundleIdentifier='com.mehdiguiard.katalog.preview06', CFBundleShortVersionString='0.8.8',
            CFBundleVersion='27', KatalogArchitecture='x86_64', KatalogUpdateChannel='disabled',
            KatalogUpdatesEnabled=1, SUFeedURL=self.info['SUFeedURL'].replace('/stable/', '/stable-intel/'),
            SUPublicEDKey='different-key', KataLogUIReviewPreview=True)
        original = dict(self.info)
        for key, value in changes.items():
            with self.subTest(key=key):
                self.info = dict(original, **{key: value}); self.write()
                with self.assertRaises(ValueError): self.validate()
        self.info = original; self.write()
        with self.assertRaisesRegex(ValueError, 'project version'): self.validate(tag='v0.9.1')

    def test_old_self_consistent_packaged_python_is_rejected_against_checkout(self):
        copied = self.resource / self.source.name
        copied.write_text('VERSION = "old"\n')
        self.manifest['sourceHashes'][self.source.name] = release.sha256(copied)
        self.write()
        with self.assertRaisesRegex(ValueError, 'Python sources'): self.validate()

    def test_changed_runtime_inputs_and_helper_architecture_are_rejected(self):
        self.manifest['requirementsHashes']['requirements-runtime.txt'] = 'old'
        self.write()
        with self.assertRaisesRegex(ValueError, 'runtime inputs'): self.validate()
        self.manifest['architecture'] = 'x86_64'; self.write()
        with self.assertRaisesRegex(ValueError, 'helper architecture'): self.validate()

    def fake_app(self, body):
        executable = self.app / 'Contents/MacOS/KataLog'
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text('#!' + sys.executable + ' -E\n' + body)
        executable.chmod(0o755)

    def test_launch_smoke_waits_for_sqlite_and_reaps_its_process_without_automation(self):
        marker = self.root / 'app.pid'
        self.fake_app('import os, pathlib, sqlite3, time\n'
            'pathlib.Path(' + repr(str(marker)) + ').write_text(str(os.getpid()))\n'
            'library = pathlib.Path(os.environ["KATALOG_LIBRARY_DIR"]); library.mkdir(parents=True)\n'
            'db = sqlite3.connect(library / "library.sqlite"); db.execute("CREATE TABLE initialized (id INTEGER)"); db.commit(); db.close()\n'
            'while True: time.sleep(.1)\n')
        # This checks the harness lifecycle; the real Swift GUI is run on CI.
        with patch.object(release.subprocess, 'run', side_effect=OSError('No Automation permission')):
            proof = release.app_launch_smoke(self.app, self.root / 'proof', timeout=3, ready_observation=.1)
        self.assertTrue(proof['appLaunch'])
        self.assertEqual(proof['shutdown'], 'SIGTERM-launch-smoke-only')
        self.assertFalse(proof['visualInteractionTested'])
        with self.assertRaises(ProcessLookupError): os.kill(int(marker.read_text()), 0)

    def test_early_app_exit_never_produces_success_proof(self):
        self.fake_app('raise SystemExit(7)\n')
        output = self.root / 'failed-proof'
        with self.assertRaisesRegex(ValueError, 'before launch qualification: 7'):
            release.app_launch_smoke(self.app, output, timeout=3, ready_observation=.1)
        self.assertFalse((output / 'app-launch.json').exists())

    def test_zip_dmg_comparison_keeps_symlink_target_and_content_identity(self):
        second = self.root / 'second'; second.mkdir()
        (second / 'same').write_text('bytes')
        (second / 'link').symlink_to('same')
        first = self.root / 'first'; first.mkdir()
        (first / 'same').write_text('bytes')
        (first / 'link').symlink_to('same')
        self.assertEqual(release.bundle_files(first), release.bundle_files(second))
        (second / 'link').unlink(); (second / 'link').symlink_to('../outside')
        self.assertNotEqual(release.bundle_files(first), release.bundle_files(second))


if __name__ == '__main__':
    unittest.main()
