"""Concurrent synthetic builds cannot mix the engine, Swift products or capture."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from build_fixture import BuildFixture, ROOT


class BuildInvocationIsolationTests(unittest.TestCase):
    def test_two_default_builds_capture_their_own_sources_and_binaries(self):
        fixture = BuildFixture(self)
        first = fixture.start(fixture.project('A'))
        fixture.wait_for(fixture.signals / 'A-swift')
        second = fixture.start(fixture.project('B'))
        app_a, _ = fixture.finish(first)
        app_b, waiting = fixture.finish(second)
        fixture.assert_marker(app_a, 'A')
        fixture.assert_marker(app_b, 'B')
        self.assertIn('attente de sa capture finale', waiting)
        self.assertEqual((fixture.shared / 'dist/LOCAL-APP-PATH.txt').read_text().strip(), str(app_b))
        self.assertEqual((fixture.shared / 'engine/inputs/modules/analyzer.py').read_text(), 'BUILD_MARKER = "B"\n')

    def test_explicit_build_roots_remain_supported(self):
        fixture = BuildFixture(self)
        build = fixture.shared / 'explicit-swift'
        engine = fixture.shared / 'explicit-engine'
        process = fixture.start(fixture.project('B'), KATALOG_BUILD_DIR=str(build), KATALOG_ENGINE_BUILD_DIR=str(engine))
        app, _ = fixture.finish(process)
        fixture.assert_marker(app, 'B')
        self.assertEqual((build / 'release/KataLog').read_text(), 'B')
        self.assertEqual((engine / 'inputs/modules/analyzer.py').read_text(), 'BUILD_MARKER = "B"\n')
        self.assertFalse((fixture.shared / 'swift').exists())
        self.assertFalse((fixture.shared / 'engine').exists())

    def test_package_smoke_keeps_its_unique_root_and_disabled_updates(self):
        fixture = BuildFixture(self)
        project = fixture.project('B')
        shutil.copyfile(ROOT / 'tools/package-smoke.sh', project / 'tools/package-smoke.sh')
        verifier = project / 'tools/verify-distribution.py'
        source = verifier.read_text().split('if __name__ == "__main__":', 1)[0]
        verifier.write_text(source + '''if __name__ == "__main__":
    path = Path(sys.argv[sys.argv.index('--report') + 1])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({'checks': [{'synthetic': True}]}))
''')
        process = subprocess.Popen(['/bin/bash', str(project / 'tools/package-smoke.sh')],
                                   env=fixture.environment(KATALOG_UPDATE_CHANNEL='stable'),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(BuildFixture.stop, process)
        stdout, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, stdout + stderr)
        root = Path(next(line.split(' sous ', 1)[1] for line in stdout.splitlines()
                         if line.startswith('Les inputs et l’archive locale restent disponibles sous ')))
        self.addCleanup(shutil.rmtree, root)
        self.assertTrue(str(root).startswith('/private/tmp/katalog-package-smoke.'))
        app = Path((root / 'dist/LOCAL-APP-PATH.txt').read_text().strip())
        fixture.captures.append(app)
        fixture.assert_marker(app, 'B')
        self.assertTrue((root / 'engine/inputs/modules/analyzer.py').is_file())
        self.assertTrue((root / 'swift/release/KataLog').is_file())
        report = json.loads((project / 'reports/package-smoke-verification.json').read_text())
        self.assertFalse(report['packageSmoke']['productionRelease'])
        self.assertFalse(report['packageSmoke']['updateFeedActive'])
        import plistlib
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['KatalogUpdateChannel'], 'disabled')
        self.assertFalse(info['KatalogUpdatesEnabled'])

    def test_termination_releases_lock_and_existing_lock_file_can_be_reused(self):
        with tempfile.TemporaryDirectory(prefix='katalog-build-lock-test-', dir='/private/tmp') as directory:
            root = Path(directory)
            helper = root / 'build-lock.py'
            helper.write_text((ROOT / 'tools/build-lock.py').read_text().replace("Path('/private/tmp')", 'Path(' + repr(str(root)) + ')'))
            script = root / 'owner.sh'
            started = root / 'started'
            script.write_text('printf started > "$1"\nsleep 30\nprintf unexpected > "$1"\n')
            env = {key: value for key, value in os.environ.items() if not key.startswith('KATALOG_BUILD_LOCK_')}
            owner = subprocess.Popen([sys.executable, str(helper), str(script), str(started)], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.addCleanup(BuildFixture.stop, owner)
            deadline = time.monotonic() + 5
            while not started.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(started.exists())
            next_script = root / 'next.sh'; next_script.write_text('printf acquired\n')
            next_build = subprocess.Popen([sys.executable, str(helper), str(next_script)], env=env,
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.addCleanup(BuildFixture.stop, next_build)
            # The first line is emitted immediately on contention, before wait.
            self.assertIn('attente de sa capture finale', next_build.stderr.readline())
            owner.send_signal(signal.SIGTERM)
            owner.communicate(timeout=5)
            self.assertEqual(owner.returncode, 128 + signal.SIGTERM)
            stdout, _ = next_build.communicate(timeout=5)
            self.assertEqual((next_build.returncode, stdout), (0, 'acquired'))
            self.assertEqual(started.read_text(), 'started')
            self.assertTrue(list(root.glob('katalog-build-*.lock')))
            retry = subprocess.run([sys.executable, str(helper), str(next_script)], env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual((retry.returncode, retry.stdout), (0, 'acquired'))

    def test_invalid_inherited_descriptor_fails_before_the_build(self):
        with tempfile.TemporaryDirectory(prefix='katalog-invalid-build-lock-', dir='/private/tmp') as directory:
            script = Path(directory) / 'never.sh'
            marker = Path(directory) / 'marker'
            script.write_text('touch "$1"\n')
            env = dict(os.environ, KATALOG_BUILD_LOCK_FD='999999')
            result = subprocess.run([sys.executable, str(ROOT / 'tools/build-lock.py'), str(script), str(marker)],
                                    env=env, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
