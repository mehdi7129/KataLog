"""Architecture boundaries: synthetic binaries, no foreign process execution."""
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from build_fixture import BuildFixture, ROOT


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


recipe = load('architecture_distribution', 'verify-distribution.py')
signing = load('architecture_signing', 'sign-bundle.py')


class NativeArchitectureTests(unittest.TestCase):
    def bundle(self, directory, architecture='x86_64'):
        app = Path(directory) / 'KataLog.app'
        info = app / 'Contents/Info.plist'
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({'KatalogArchitecture': architecture, 'CFBundleExecutable': 'KataLog'}))
        manifest = app / recipe.HELPER_MANIFEST
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({'architecture': architecture}))
        for relative in ('Contents/MacOS/KataLog', 'Contents/MacOS/katalog-cli', str(recipe.HELPER_EXECUTABLE),
                         'Contents/Helpers/KataLogEngine.app/Contents/Frameworks/python.dylib',
                         'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'):
            binary = app / relative
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(b'\xcf\xfa\xed\xfeSynthetic Mach-O fixture')
        helper_info = app / recipe.HELPER_BUNDLE / 'Contents/Info.plist'
        helper_info.write_bytes(plistlib.dumps({'CFBundleExecutable': 'KataLogEngine'}))
        return app

    def test_real_build_entrypoints_refuse_foreign_or_invalid_arch_before_compilation(self):
        foreign = 'x86_64' if platform.machine() == 'arm64' else 'arm64'
        for name in ('build-app.sh', 'build-engine.sh'):
            script = ROOT / 'tools' / name
            for architecture in (foreign, 'universal2', 'invalid'):
                with self.subTest(script=name, architecture=architecture):
                    env = dict(os.environ, KATALOG_ARCH=architecture, KATALOG_BUILD_LOCK_SCRIPT=str(script))
                    result = subprocess.run(['/bin/bash', str(script)], env=env, capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('KATALOG_ARCH' if architecture != foreign else 'Mac natif', result.stderr)

    def test_intel_metadata_and_archive_name_flow_through_real_packaging_shell(self):
        fixture = BuildFixture(self)
        project = fixture.project('Intel')
        app, _ = fixture.finish(fixture.start(project, KATALOG_ARCH='x86_64', KATALOG_FIXTURE_HOST_ARCH='x86_64'))
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['KatalogArchitecture'], 'x86_64')
        self.assertEqual(json.loads((app / recipe.HELPER_MANIFEST).read_text())['architecture'], 'x86_64')
        self.assertTrue((fixture.shared / ('dist/KataLog-' + info['CFBundleShortVersionString'] + '-macOS-x86_64.zip')).is_file())

    def test_wrong_helper_binary_is_rejected_before_swift_compilation(self):
        fixture = BuildFixture(self)
        project = fixture.project('Mixed')
        foreign = 'x86_64' if platform.machine() == 'arm64' else 'arm64'
        process = fixture.start(project, KATALOG_FIXTURE_MACHO_ARCH=foreign)
        stdout, stderr = process.communicate(timeout=30)
        self.assertNotEqual(process.returncode, 0, stdout)
        self.assertIn('architecture déclarée', stderr)
        self.assertFalse((fixture.signals / 'Mixed-swift').exists())

    def test_runtime_skip_requires_foreign_architecture_and_never_runs_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.bundle(directory)
            with patch.object(recipe.platform, 'machine', return_value='arm64'), patch.object(recipe.subprocess, 'run') as run:
                verifier = recipe.Verification(app, skip_runtime=True)
                self.assertFalse(verifier.runtime_policy()['runtimeExecuted'])
                with self.assertRaisesRegex(recipe.CheckError, 'explicitly disabled'):
                    verifier.runtime()
                run.assert_not_called()
                with self.assertRaisesRegex(recipe.CheckError, 'native matching Mac'):
                    recipe.Verification(app).runtime_policy()
            with patch.object(recipe.platform, 'machine', return_value='x86_64'):
                with self.assertRaisesRegex(recipe.CheckError, 'native runtime checks are required'):
                    recipe.Verification(app, skip_runtime=True).runtime_policy()
                translated = subprocess.CompletedProcess([], 0, stdout=b'1\n')
                with patch.object(recipe.subprocess, 'run', return_value=translated), self.assertRaisesRegex(recipe.CheckError, 'Rosetta'):
                    recipe.Verification(app).runtime_policy()

    def test_cross_architecture_inspection_report_cannot_claim_full_runtime_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.bundle(directory)
            report = Path(directory) / 'report.json'
            with patch.object(recipe.platform, 'machine', return_value='arm64'), \
                 patch.object(recipe.Verification, 'inspect_bundle', return_value={}), patch.object(recipe.Verification, 'privacy', return_value={}), \
                 patch.object(recipe.Verification, 'portable_macho', return_value={}), patch.object(recipe.Verification, 'updates', return_value={}), \
                 patch.object(recipe.Verification, 'signature', return_value={}), patch.object(recipe.Verification, 'runtime') as runtime:
                self.assertEqual(recipe.main(['--app', str(app), '--report', str(report), '--skip-runtime']), 0)
                runtime.assert_not_called()
            result = json.loads(report.read_text())
            self.assertEqual(result['status'], 'inspection-passed')
            self.assertEqual(result['runtimeExecution'], 'skipped-cross-architecture')

    def test_all_native_components_must_match_except_reviewed_universal_sparkle(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.bundle(directory)
            verifier = recipe.Verification(app)
            overrides = {}
            def inspect(arguments, **unused):
                path = Path(arguments[-1])
                if arguments[0].endswith('/lipo'):
                    return overrides.get(str(path.relative_to(app)), 'arm64 x86_64' if 'Sparkle.framework' in str(path) else 'x86_64').encode()
                if arguments[1] == '-l':
                    return b'Load command 1\n cmd LC_BUILD_VERSION\n minos 15.0\n'
                return b'file:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n'
            with patch.object(verifier, 'command', side_effect=inspect):
                self.assertEqual(verifier.portable_macho()['requiredArchitecture'], 'x86_64')
                for bad in ('arm64', 'arm64 x86_64'):
                    overrides[str(recipe.HELPER_EXECUTABLE)] = bad
                    with self.subTest(architecture=bad), self.assertRaisesRegex(recipe.CheckError, 'portability findings'):
                        verifier.portable_macho()
                overrides.clear()
                info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
                info['KatalogArchitecture'] = 'arm64'
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(recipe.CheckError, 'architectures do not match'):
                    verifier.portable_macho()

    def test_signing_foreign_bundle_only_invokes_inspection_and_signing_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.bundle(directory)
            calls = []
            def run(arguments, **unused):
                calls.append(arguments)
                return subprocess.CompletedProcess(arguments, 0)
            with patch.object(signing.subprocess, 'check_output', return_value=''), patch.object(signing.subprocess, 'run', side_effect=run):
                signing.sign_bundle(app, 'Synthetic Developer ID')
            self.assertTrue(calls)
            self.assertTrue(all(arguments[0] == '/usr/bin/codesign' for arguments in calls))
            self.assertTrue(any(str(app) == arguments[-1] for arguments in calls))


if __name__ == '__main__':
    unittest.main()
