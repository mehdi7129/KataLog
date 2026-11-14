#!/usr/bin/env python3
"""Qualify locally signed draft-release assets on their native CI host.

Read-only GitHub access. No signing key, release publication or feed update.
"""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path, PurePosixPath
import re
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import zipfile

from dmg_mount import readonly_mount

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, **kwargs):
    return subprocess.run([str(value) for value in arguments], check=True, **kwargs)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def bundle_files(root):
    return {str(path.relative_to(root)): ('symlink:' + os.readlink(path) if path.is_symlink() else sha256(path))
            for path in root.rglob('*') if path.is_symlink() or path.is_file()}


def checked_source_commit(source_root, expected):
    top = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], cwd=source_root, text=True).strip()
    if Path(top).resolve() != Path(source_root).resolve():
        raise ValueError('The candidate source must be a Git checkout root.')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source_root, text=True).strip()
    if commit != expected:
        raise ValueError('The checked-out source differs from the candidate commit.')
    if subprocess.check_output(['git', 'status', '--porcelain'], cwd=source_root, text=True).strip():
        raise ValueError('The candidate source checkout has local modifications or untracked files.')
    return commit



def validate_candidate_bundle(app, architecture, release_tag, root=ROOT):
    """Bind the final bundle to the reviewed source, release and update route."""
    settings = dict(re.findall(r'^        (MARKETING_VERSION|CURRENT_PROJECT_VERSION): (.+)$',
                               (root / 'project.yml').read_text(), re.MULTILINE))
    version, build = settings['MARKETING_VERSION'], settings['CURRENT_PROJECT_VERSION']
    if release_tag != 'v' + version:
        raise ValueError('Release tag differs from the checked-out project version.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    folder = 'stable-intel' if architecture == 'x86_64' else 'stable'
    expected = dict(CFBundleIdentifier='com.mehdiguiard.katalog', CFBundleShortVersionString=version,
                    CFBundleVersion=build, KatalogArchitecture=architecture, KatalogUpdateChannel='stable',
                    KatalogUpdatesEnabled=True,
                    SUFeedURL='https://raw.githubusercontent.com/mehdi7129/KataLog/main/updates/' + folder + '/appcast.xml',
                    SUPublicEDKey=(root / 'updates/stable/public-key.txt').read_text().strip())
    for name, value in expected.items():
        if type(info.get(name)) is not type(value) or info.get(name) != value:
            raise ValueError('Final bundle release metadata differs: ' + name)
    if info.get('KataLogUIReviewPreview'):
        raise ValueError('A preview cannot qualify as a stable release.')
    manifest = json.loads((app / 'Contents/Helpers/KataLogEngine.app/Contents/Resources/runtime-manifest.json').read_text())
    if manifest.get('architecture') != architecture:
        raise ValueError('Final helper architecture differs from the selected asset.')
    sources = {path.name: sha256(path) for path in (root / 'Sources/KataLog/Resources').glob('*.py')}
    bundled_sources = {path.name: sha256(path) for path in (app / 'Contents/Resources').glob('*.py')}
    requirements = {name: sha256(root / name) for name in ('requirements-runtime.txt', 'requirements-runtime-build.txt')}
    build_inputs = {name: sha256(root / 'tools' / name) for name in ('engine-entry.py', 'KataLogEngine.spec')}
    if not sources or manifest.get('sourceHashes') != sources or bundled_sources != sources:
        raise ValueError('Final Python sources do not match the exact checked-out commit.')
    if manifest.get('requirementsHashes') != requirements or manifest.get('buildInputHashes') != build_inputs:
        raise ValueError('Final runtime inputs do not match the exact checked-out commit.')
    return dict(version=version, build=build, architecture=architecture, sourceModules=len(sources),
                runtimeInputsMatchCheckout=True, updateFeed=expected['SUFeedURL'])



def app_launch_smoke(app, output, timeout=30, ready_observation=2):
    """Launch the actual Swift app with an empty isolated library after eject."""
    output.mkdir(parents=True, exist_ok=True)
    crashes = Path.home() / 'Library/Logs/DiagnosticReports'
    before = set(crashes.glob('KataLog*'))
    with tempfile.TemporaryDirectory(prefix='katalog-native-ui-', dir='/private/tmp') as temporary:
        library = Path(temporary) / 'library'
        environment = {key: value for key, value in os.environ.items() if not key.startswith('KATALOG_')}
        environment.update(KATALOG_LIBRARY_DIR=str(library), PYTHONHOME='/invalid-katalog-python', PYTHONPATH='/invalid-katalog-modules')
        with (output / 'app-stdout.log').open('wb') as stdout, (output / 'app-stderr.log').open('wb') as stderr:
            process = subprocess.Popen([str(app / 'Contents/MacOS/KataLog')], env=environment,
                                       stdout=stdout, stderr=stderr, start_new_session=True)
            shutdown = None
            try:
                deadline, ready_at = time.monotonic() + timeout, None
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise ValueError('Native Swift app exited before launch qualification: ' + str(process.returncode))
                    database = library / 'library.sqlite'
                    if database.is_file():
                        try:
                            with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=.1) as connection:
                                healthy = connection.execute('PRAGMA quick_check').fetchone() == ('ok',)
                                initialized = connection.execute('SELECT count(*) FROM sqlite_master WHERE type = "table"').fetchone()[0] > 0
                            if healthy and initialized:
                                ready_at = ready_at or time.monotonic()
                        except sqlite3.Error:
                            pass
                    if ready_at is not None and time.monotonic() - ready_at >= ready_observation:
                        break
                    time.sleep(.1)
                else:
                    raise ValueError('Native Swift app did not initialize its isolated SQLite library within the launch deadline.')
                # Target this exact PID; never quit another installed KataLog app.
                script = 'ObjC.import("AppKit"); $.NSRunningApplication.runningApplicationWithProcessIdentifier(' + str(process.pid) + ').terminate;'
                try:
                    subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                    process.wait(timeout=5)
                    if process.returncode != 0:
                        raise ValueError('Native Swift app crashed while closing: ' + str(process.returncode))
                    shutdown = 'NSRunningApplication.terminate'
                except (subprocess.TimeoutExpired, OSError):
                    process.send_signal(signal.SIGTERM)
                    process.wait(timeout=5)
                    if process.returncode not in (0, -signal.SIGTERM):
                        raise ValueError('Native Swift app exited abnormally during fallback shutdown.')
                    shutdown = 'SIGTERM-launch-smoke-only'
            finally:
                # Include any helper children in this invocation's private group.
                try: os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError: pass
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=5)
        new_crashes = sorted(path.name for path in set(crashes.glob('KataLog*')) - before if path.is_file())
        if new_crashes:
            raise ValueError('New KataLog crash diagnostics appeared during launch: ' + ', '.join(new_crashes))
        result = dict(appLaunch=True, nativeSwiftApp=True, isolatedLibraryInitialized=True,
                      databaseQuickCheck=True, shutdown=shutdown, exitCode=process.returncode,
                      newCrashReports=new_crashes, visualInteractionTested=False)
        (output / 'app-launch.json').write_text(json.dumps(result, indent=2) + '\n')
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--architecture', choices=('arm64', 'x86_64'), required=True)
    parser.add_argument('--release-tag', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--source-root', type=Path, default=ROOT,
                        help='Clean checkout of the exact product commit; the qualification harness may be newer.')
    parser.add_argument('--zip-sha256', required=True)
    parser.add_argument('--dmg-sha256', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9a-f]{40}', args.commit) or not all(re.fullmatch(r'[0-9a-f]{64}', value) for value in (args.zip_sha256, args.dmg_sha256)):
        parser.error('An exact source commit and both SHA-256 values are required.')
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', args.release_tag):
        parser.error('A versioned draft release tag is required.')
    source_root = args.source_root.resolve()
    commit = checked_source_commit(source_root, args.commit)
    harness_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    run([sys.executable, ROOT / 'tools/check-native-host.py', '--architecture', args.architecture])
    metadata = json.loads(subprocess.check_output(['gh', 'release', 'view', args.release_tag, '--repo', 'mehdi7129/KataLog',
                                                  '--json', 'isDraft,targetCommitish,tagName'], text=True))
    if not metadata['isDraft'] or metadata['targetCommitish'] != args.commit:
        raise SystemExit('Expected an unpublished draft release targeting the exact candidate commit.')
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    prefix = f'KataLog-{args.release_tag[1:]}-macOS-{args.architecture}'
    with tempfile.TemporaryDirectory(prefix='katalog-signed-qualification-', dir='/private/tmp') as temporary:
        work = Path(temporary)
        run(['gh', 'release', 'download', args.release_tag, '--repo', 'mehdi7129/KataLog', '--dir', work,
             '--pattern', prefix + '.zip', '--pattern', prefix + '.dmg'])
        archive, dmg = work / (prefix + '.zip'), work / (prefix + '.dmg')
        if sha256(archive) != args.zip_sha256 or sha256(dmg) != args.dmg_sha256:
            raise SystemExit('Downloaded candidate hashes do not match the explicitly selected assets.')
        with zipfile.ZipFile(archive) as source:
            for item in source.infolist():
                path = PurePosixPath(item.filename)
                if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != 'KataLog.app':
                    raise SystemExit('Unexpected archive path.')
        extracted = work / 'zip'; extracted.mkdir()
        run(['/usr/bin/ditto', '-x', '-k', archive, extracted])
        installed = work / 'installed'; installed.mkdir()
        with readonly_mount(dmg, prefix='katalog-signed-dmg-') as mount:
            run(['/usr/bin/ditto', '--norsrc', mount / 'KataLog.app', installed / 'KataLog.app'])
        # Execute the installed copy only after the DMG has been ejected.
        app = installed / 'KataLog.app'
        if bundle_files(app) != bundle_files(extracted / 'KataLog.app'):
            raise SystemExit('ZIP and DMG contain different app bundle bytes or symlinks.')
        source_proof = validate_candidate_bundle(app, args.architecture, args.release_tag, source_root)
        run([sys.executable, ROOT / 'tools/verify-distribution.py', '--app', app, '--dmg', dmg,
             '--require-notarized', '--report', output / 'distribution.json'])
        run([sys.executable, ROOT / 'tools/verify-usb-runtime.py', '--app', app, '--report', output / 'usb-runtime.json',
             '--bench-python', sys.executable])
        app_proof = app_launch_smoke(app, output)
        receipt = dict(passed=True, commit=commit, harnessCommit=harness_commit,
                       architecture=args.architecture, releaseTag=args.release_tag,
                       zipSHA256=args.zip_sha256, dmgSHA256=args.dmg_sha256, nativeExecution=True,
                       copiedFromDMGAndEjected=True, bundleSource=source_proof, appLaunch=app_proof,
                       swiftProvenanceAssumption='Operator selected the CI ZIP by commit and SHA-256 and preserved its executables through local signing', published=False)
        (output / 'summary.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt))


if __name__ == '__main__':
    main()
