"""Run the actual app packaging shell with synthetic compilers and binaries."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

# Real file copying, manifests, plist, update configuration and ZIP publication
# remain active. Only compilation, binary inspection and signing are replaced.
COMMAND = r'''import hashlib, json, os, pathlib, sys, time
mode, *args = sys.argv[1:]
def marker(root):
    return (root / 'Sources/KataLog/Resources/analyzer.py').read_text().split('=')[1].strip().strip('"')
if mode == 'engine':
    build, project = map(pathlib.Path, args)
    (build / 'inputs/modules/analyzer.py').write_text((project / 'Sources/KataLog/Resources/analyzer.py').read_text())
    contents = build / 'dist/KataLogEngine.app/Contents'
    (contents / 'MacOS').mkdir(parents=True, exist_ok=True)
    (contents / 'Resources').mkdir(exist_ok=True)
    executable = contents / 'MacOS/KataLogEngine'
    executable.write_text('#!/bin/sh\nprintf \'{"protocol":1}\\n\'\n')
    executable.chmod(0o755)
    (contents / 'Resources/fixture-marker').write_text(marker(project))
    def hashes(root, names):
        return {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in names}
    manifest = dict(sourceHashes=hashes(project / 'Sources/KataLog/Resources', ['analyzer.py']),
                    requirementsHashes=hashes(project, ['requirements-runtime.txt', 'requirements-runtime-build.txt']),
                    buildInputHashes=hashes(project / 'tools', ['engine-entry.py', 'KataLogEngine.spec']))
    (contents / 'Resources/runtime-manifest.json').write_text(json.dumps(manifest))
elif mode == 'swift':
    build = pathlib.Path(args[args.index('--scratch-path')+1])
    binary = build / 'release'
    if '--show-bin-path' in args:
        print(binary)
    else:
        name = args[args.index('--product')+1]
        value = marker(pathlib.Path.cwd())
        binary.mkdir(parents=True, exist_ok=True)
        (binary / name).write_text(value)
        (binary / 'Sparkle.framework').mkdir(exist_ok=True)
        license = build / 'checkouts/Sparkle/LICENSE'
        license.parent.mkdir(parents=True, exist_ok=True)
        license.write_text('Synthetic Sparkle license')
        if name == 'KataLog':
            signals = pathlib.Path(os.environ['KATALOG_FIXTURE_SIGNALS'])
            (signals / (value + '-swift')).touch()
            if value == 'A':
                deadline = time.monotonic() + 2
                while not (signals / 'B-swift').exists() and time.monotonic() < deadline:
                    time.sleep(.01)
elif mode == 'otool':
    print('@executable_path/../Frameworks')
else:
    assert mode == 'codesign', mode
'''


class BuildFixture:
    def __init__(self, case):
        self.case = case
        self.temporary = tempfile.TemporaryDirectory(prefix='katalog-build-fixture-', dir='/private/tmp')
        case.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.signals = self.root / 'signals'; self.signals.mkdir()
        self.shared = self.root / 'shared'; self.shared.mkdir()
        self.bin = self.root / 'bin'; self.bin.mkdir()
        self.command = self.root / 'command.py'; self.command.write_text(COMMAND)
        for name in ('swift', 'otool', 'codesign'):
            program = self.bin / name
            program.write_text('#!/bin/bash\nexec ' + self.quote(sys.executable) + ' ' + self.quote(self.command) + ' ' + name + ' "$@"\n')
            program.chmod(0o755)
        self.captures = []
        case.addCleanup(self.cleanup_captures)

    @staticmethod
    def quote(value):
        import shlex
        return shlex.quote(str(value))

    def cleanup_captures(self):
        for path in self.captures:
            shutil.rmtree(path.parent, ignore_errors=True)

    def project(self, name):
        project = self.root / name
        for directory in ('tools', 'Sources/KataLog/Resources', 'assets/icon'):
            (project / directory).mkdir(parents=True, exist_ok=True)
        for name in ('LICENSE', 'requirements-runtime.txt', 'requirements-runtime-build.txt', 'assets/icon/KataLog.icns',
                     'tools/engine-entry.py', 'tools/KataLogEngine.spec', 'tools/update-feed.py', 'tools/verify-distribution.py', 'tools/dmg_mount.py'):
            shutil.copyfile(ROOT / name, project / name)
        (project / 'Package.swift').write_text('// Synthetic compiler input\n')
        (project / 'Sources/KataLog/Resources/analyzer.py').write_text('BUILD_MARKER = "' + project.name + '"\n')
        app = (ROOT / 'tools/build-app.sh').read_text()
        # Redirect the old shared defaults too: the regression must never touch
        # a developer's actual scratch directory, with or without the fix.
        for old, new in (('/private/tmp/katalog-swift-build', self.shared / 'swift'),
                         ('/private/tmp/katalog-engine-build', self.shared / 'engine'),
                         ('/private/tmp/katalog-clang-cache', self.shared / 'clang'),
                         ('/private/tmp/katalog-xdg-cache', self.shared / 'xdg')):
            app = app.replace(old, str(new))
        for name in ('otool', 'codesign'):
            app = app.replace('/usr/bin/' + name, self.quote(self.bin / name))
        (project / 'tools/build-app.sh').write_text(app)
        engine = (ROOT / 'tools/build-engine.sh').read_text().split('python_url=', 1)[0]
        engine = engine.replace('/private/tmp/katalog-engine-build', str(self.shared / 'engine'))
        engine += self.quote(sys.executable) + ' ' + self.quote(self.command) + ' engine "$build_dir" "$project_dir"\n'
        (project / 'tools/build-engine.sh').write_text(engine)
        lock = ROOT / 'tools/build-lock.py'
        if lock.exists():
            (project / 'tools/build-lock.py').write_text(lock.read_text().replace("Path('/private/tmp')", 'Path(' + repr(str(self.root)) + ')'))
        (project / 'tools/sign-bundle.py').write_text('# Synthetic signing boundary.\n')
        return project

    def environment(self, **updates):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith('KATALOG_') and key not in ('CLANG_MODULE_CACHE_PATH', 'XDG_CACHE_HOME')}
        env.update(PATH=str(self.bin) + os.pathsep + env.get('PATH', '/usr/bin:/bin'),
                   KATALOG_DIST_DIR=str(self.shared / 'dist'), KATALOG_FIXTURE_SIGNALS=str(self.signals))
        env.update(updates)
        return env

    def start(self, project, **updates):
        process = subprocess.Popen(['/bin/bash', str(project / 'tools/build-app.sh')],
                                   env=self.environment(**updates), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.case.addCleanup(self.stop, process)
        return process

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate(timeout=5)

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=30)
        self.case.assertEqual(process.returncode, 0, stdout + stderr)
        line = next(line for line in stdout.splitlines() if line.startswith('Copie locale vérifiée : '))
        capture = Path(line.split(' : ', 1)[1])
        self.captures.append(capture)
        return capture, stderr

    def wait_for(self, path, timeout=10):
        deadline = time.monotonic() + timeout
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        self.case.assertTrue(path.exists(), 'Synthetic build did not reach ' + path.name)

    def assert_marker(self, app, expected):
        for relative in ('MacOS/KataLog', 'MacOS/katalog-cli', 'Helpers/KataLogEngine.app/Contents/Resources/fixture-marker'):
            self.case.assertEqual((app / 'Contents' / relative).read_text(), expected, relative)
        self.case.assertEqual((app / 'Contents/Resources/analyzer.py').read_text(), 'BUILD_MARKER = "' + expected + '"\n')
