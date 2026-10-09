"""Keep checked-in build metadata and packaged plist contracts consistent."""
import base64
import copy
import importlib.util
import json
import plistlib
from pathlib import PurePosixPath
import re
import subprocess
import unittest

from build_fixture import BuildFixture, ROOT

SPEC = importlib.util.spec_from_file_location('katalog_metadata_update_policy', ROOT / 'tools/update-feed.py')
updates = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updates)


def xcode_project():
    return json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(ROOT / 'KataLog.xcodeproj/project.pbxproj')]))


def xcode_phase_files(project, target_name, phase_type):
    objects = project['objects']
    paths = {}

    def visit(reference, parent):
        value = objects[reference]
        source_tree = value.get('sourceTree', '<group>')
        if source_tree not in ('<group>', 'SOURCE_ROOT'):
            return  # SDK/framework/products are not project source inputs.
        base = PurePosixPath() if source_tree == 'SOURCE_ROOT' else parent
        path = base / value.get('path', '')
        if value['isa'] == 'PBXFileReference':
            paths[reference] = path.as_posix()
        else:
            for child in value.get('children', []):
                visit(child, path)

    visit(objects[project['rootObject']]['mainGroup'], PurePosixPath())
    target = next(value for value in objects.values() if value.get('isa') == 'PBXNativeTarget' and value.get('name') == target_name)
    phase = next(objects[key] for key in target['buildPhases'] if objects[key]['isa'] == phase_type)
    return {build_file: paths[objects[build_file]['fileRef']] for build_file in phase['files']}, phase


SOURCE_PHASES = (
    ('KataLog', 'PBXSourcesBuildPhase', 'Sources/KataLog', '.swift'),
    ('KataLogCore', 'PBXSourcesBuildPhase', 'Sources/KataLogCore', '.swift'),
    ('KataLog', 'PBXResourcesBuildPhase', 'Sources/KataLog/Resources', '.py'),
)


def project_settings():
    # These are the scalar XcodeGen target settings, not arbitrary YAML input.
    return dict(re.findall(r'^        ([A-Za-z_][A-Za-z_0-9]*): (.+)$', (ROOT / 'project.yml').read_text(), re.MULTILINE))


def script_default(name):
    text = (ROOT / 'tools/build-app.sh').read_text()
    return re.search(r'\$\{' + re.escape(name) + r':-([^}]*)\}', text)[1]


def plist_setting(value):
    return {'YES': True, 'NO': False}.get(value, int(value) if value.isdigit() else value)


class BuildMetadataContractTests(unittest.TestCase):
    def test_yaml_xcode_defaults_smoke_and_update_policy_agree(self):
        settings = project_settings()
        self.assertEqual(script_default('KATALOG_VERSION'), settings['MARKETING_VERSION'])
        self.assertEqual(script_default('KATALOG_BUILD_NUMBER'), settings['CURRENT_PROJECT_VERSION'])
        self.assertEqual(script_default('KATALOG_UPDATE_CHANNEL'), 'disabled')
        self.assertEqual(script_default('KATALOG_UPDATE_FEED_URL'), '')
        self.assertEqual(script_default('KATALOG_UPDATE_PUBLIC_KEY'), '')
        self.assertEqual(script_default('KATALOG_UI_PREVIEW_BUILD'), '0')
        smoke = dict(re.findall(r"^export (KATALOG_[A-Z_]+)='([^']*)'$", (ROOT / 'tools/package-smoke.sh').read_text(), re.MULTILINE))
        for name in ('VERSION', 'BUILD_NUMBER', 'UPDATE_CHANNEL', 'UPDATE_FEED_URL', 'UPDATE_PUBLIC_KEY'):
            self.assertEqual(smoke['KATALOG_' + name], script_default('KATALOG_' + name), name)
        project = xcode_project()
        objects = project['objects']
        target = next(value for value in objects.values() if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'KataLog')
        configurations = [objects[key] for key in objects[target['buildConfigurationList']]['buildConfigurations']]
        self.assertEqual({config['name'] for config in configurations}, {'Debug', 'Release'})
        keys = ['PRODUCT_BUNDLE_IDENTIFIER', 'MARKETING_VERSION', 'CURRENT_PROJECT_VERSION']
        keys += [key for key in settings if key.startswith('INFOPLIST_KEY_')]
        for config in configurations:
            for key in keys:
                with self.subTest(configuration=config['name'], key=key):
                    self.assertEqual(str(config['buildSettings'][key]), settings[key])
        expected_policy = updates.configured_info({})
        actual_policy = {key.removeprefix('INFOPLIST_KEY_'): plist_setting(value)
                         for key, value in settings.items() if key.startswith(('INFOPLIST_KEY_Katalog', 'INFOPLIST_KEY_SU'))}
        self.assertEqual(actual_policy, expected_policy)

    def assert_source_membership(self, project, target, phase_type, folder, suffix):
        expected = {path.relative_to(ROOT).as_posix() for path in (ROOT / folder).rglob('*' + suffix)}
        self.assertTrue(expected, 'The contract must check real source inputs')
        files, _ = xcode_phase_files(project, target, phase_type)
        actual = {path for path in files.values() if path.endswith(suffix)}
        self.assertEqual(actual, expected, target + ' ' + phase_type + ': regenerate the checked-in Xcode project with xcodegen generate')

    def test_xcode_build_phases_include_current_swift_and_python_sources(self):
        project = xcode_project()
        for target, phase_type, folder, suffix in SOURCE_PHASES:
            with self.subTest(target=target, phase=phase_type):
                self.assert_source_membership(project, target, phase_type, folder, suffix)

    def test_xcode_membership_contract_rejects_a_file_reference_without_phase_entry(self):
        project = xcode_project()
        for target, phase_type, folder, suffix in SOURCE_PHASES:
            with self.subTest(target=target, phase=phase_type):
                broken = copy.deepcopy(project)
                files, phase = xcode_phase_files(broken, target, phase_type)
                omitted = next(key for key, path in files.items() if path.endswith(suffix))
                phase['files'].remove(omitted)
                # The PBXBuildFile and PBXFileReference remain in the project.
                # Presence in the file is insufficient without phase membership.
                with self.assertRaisesRegex(AssertionError, 'regenerate the checked-in Xcode project'):
                    self.assert_source_membership(broken, target, phase_type, folder, suffix)

    def test_plist_template_has_no_obsolete_intermediate_version(self):
        template = (ROOT / 'tools/build-app.sh').read_text().split("<<'PLIST'\n", 1)[1].split('\nPLIST', 1)[0]
        info = plistlib.loads(template.encode())
        for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
            with self.subTest(key=key):
                self.assertNotIn(key, info, 'The final version must be inserted from the validated build inputs')

    def info(self, **environment):
        fixture = BuildFixture(self)
        if environment.get('KATALOG_UI_PREVIEW_BUILD') == '1':
            folder = environment.pop('fixture_output_folder', 'preview-staging')
            environment['KATALOG_DIST_DIR'] = str(fixture.root / folder)
        app, _ = fixture.finish(fixture.start(fixture.project('B'), **environment))
        fixture.assert_marker(app, 'B')
        return app, plistlib.loads((app / 'Contents/Info.plist').read_bytes())

    def assert_manual_updates(self, info, enabled=False, channel='disabled'):
        self.assertEqual(info['KatalogUpdateChannel'], channel)
        self.assertIs(info['KatalogUpdatesEnabled'], enabled)
        self.assertEqual(info['KatalogSparkleVersion'], updates.SPARKLE_VERSION)
        for name in ('SUEnableAutomaticChecks', 'SUAutomaticallyUpdate', 'SUAllowsAutomaticUpdates', 'SUEnableSystemProfiling', 'SUEnableJavaScript'):
            self.assertIs(info[name], False, name)
        for name in ('SUVerifyUpdateBeforeExtraction', 'SURequireSignedFeed'):
            self.assertIs(info[name], True, name)
        self.assertEqual(info['SUSignedFeedFailureExpirationInterval'], 0)
        if not enabled:
            self.assertNotIn('SUFeedURL', info)
            self.assertNotIn('SUPublicEDKey', info)

    def test_default_stable_app_preserves_version_identity_and_library_inputs(self):
        app, info = self.info()
        settings = project_settings()
        self.assertEqual(app.name, 'KataLog.app')
        self.assertEqual(info['CFBundleIdentifier'], settings['PRODUCT_BUNDLE_IDENTIFIER'])
        self.assertEqual(info['CFBundleShortVersionString'], settings['MARKETING_VERSION'])
        self.assertEqual(info['CFBundleVersion'], settings['CURRENT_PROJECT_VERSION'])
        self.assertEqual(info['CFBundleName'], 'KataLog')
        self.assertEqual(info['CFBundleDisplayName'], settings['INFOPLIST_KEY_CFBundleDisplayName'])
        self.assertTrue(info['KatalogBundledEngineRequired'])
        self.assertNotIn('KataLogUIReviewPreview', info)
        self.assertNotIn('KataLogPreviewLibraryComponent', info)
        self.assert_manual_updates(info)

    def test_preview_override_keeps_separate_identity_and_library_component(self):
        app, info = self.info(KATALOG_UI_PREVIEW_BUILD='1', KATALOG_VERSION='9.9.9', KATALOG_BUILD_NUMBER='4242')
        self.assertEqual(app.name, 'KataLog Preview.app')
        self.assertEqual(info['CFBundleIdentifier'], 'com.mehdiguiard.katalog.preview06')
        self.assertEqual(info['CFBundleName'], 'KataLog Preview')
        self.assertEqual(info['CFBundleDisplayName'], 'KataLog Preview')
        self.assertEqual(info['CFBundleShortVersionString'], '9.9.9')
        self.assertEqual(info['CFBundleVersion'], '4242')
        self.assertIs(info['KataLogUIReviewPreview'], True)
        self.assertEqual(info['KataLogPreviewLibraryComponent'], 'KataLogPreview-9.9.9')
        self.assert_manual_updates(info)

    def test_legacy_preview_retains_its_existing_library_fallback(self):
        _, info = self.info(KATALOG_UI_PREVIEW_BUILD='1', KATALOG_VERSION='0.6.0', KATALOG_BUILD_NUMBER='4242', fixture_output_folder='0.6-staging')
        self.assertEqual(info['CFBundleIdentifier'], 'com.mehdiguiard.katalog.preview06')
        self.assertIs(info['KataLogUIReviewPreview'], True)
        self.assertNotIn('KataLogPreviewLibraryComponent', info)
        self.assert_manual_updates(info)

    def test_explicit_stable_and_staging_updates_preserve_identity_and_manual_policy(self):
        key = base64.b64encode(bytes(range(32))).decode()
        for channel in ('stable', 'staging'):
            with self.subTest(channel=channel):
                feed = 'https://updates.example.org/' + channel + '/appcast.xml'
                app, info = self.info(KATALOG_VERSION='9.9.9', KATALOG_BUILD_NUMBER='4242',
                                      KATALOG_UPDATE_CHANNEL=channel, KATALOG_UPDATE_FEED_URL=feed,
                                      KATALOG_UPDATE_PUBLIC_KEY=key)
                self.assertEqual(app.name, 'KataLog.app')
                self.assertEqual(info['CFBundleIdentifier'], project_settings()['PRODUCT_BUNDLE_IDENTIFIER'])
                self.assertEqual(info['CFBundleShortVersionString'], '9.9.9')
                self.assertEqual(info['CFBundleVersion'], '4242')
                self.assertNotIn('KataLogUIReviewPreview', info)
                self.assertNotIn('KataLogPreviewLibraryComponent', info)
                self.assertEqual(info['SUFeedURL'], feed)
                self.assertEqual(info['SUPublicEDKey'], key)
                self.assert_manual_updates(info, enabled=True, channel=channel)


if __name__ == '__main__':
    unittest.main()
