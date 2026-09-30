#!/bin/bash
set -euo pipefail

# Build inputs are pinned, fetched with SHA-256 verification, and extracted only
# under /private/tmp. No Python installation or user preference is modified.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${KATALOG_ENGINE_BUILD_DIR:-/private/tmp/katalog-engine-build}"
case "$build_dir" in
    /private/tmp/*) ;;
    *) printf 'KATALOG_ENGINE_BUILD_DIR doit être un sous-dossier de /private/tmp.\n' >&2; exit 1 ;;
esac
if [[ "$(/usr/bin/uname -s)" != Darwin || "$(/usr/bin/uname -m)" != arm64 ]]; then
    printf 'Ce moteur cible macOS ARM64. Construisez-le sur un Mac Apple Silicon.\n' >&2
    exit 1
fi
mkdir -p "$build_dir/downloads" "$build_dir/inputs" "$build_dir/licenses-source"
# Reusing a build directory must not compile a removed or renamed module from
# an earlier source tree. Preserve old generated inputs, then copy the exact
# current public module set into a fresh directory.
if [[ -e "$build_dir/inputs/modules" ]]; then
    previous_inputs="$(mktemp -d "$build_dir/previous-modules.XXXXXX")"
    mv "$build_dir/inputs/modules" "$previous_inputs/"
fi
mkdir -p "$build_dir/inputs/modules"
export PYINSTALLER_CONFIG_DIR="$build_dir/pyinstaller-cache"
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_CACHE_DIR="$build_dir/pip-cache"
unset PYTHONPATH PYTHONHOME
export PYTHONDONTWRITEBYTECODE=1

python_url='https://github.com/astral-sh/python-build-standalone/releases/download/20260929/cpython-3.13.15%2B20260929-aarch64-apple-darwin-install_only_stripped.tar.gz'
python_sha='d66c67f16148c7454b1509c32747175f7669c8b8e105b97b92a0000d66af6e6e'
licenses_url='https://github.com/astral-sh/python-build-standalone/releases/download/20260929/cpython-3.13.15%2B20260929-aarch64-apple-darwin-pgo%2Blto-full.tar.zst'
licenses_sha='f6d0b397d62a6041ef67ca5180fe989fc0acbd3058ffc31c8ab4b43cae1ba430'

fetch_verified() {
    local url="$1" expected="$2" target="$3" actual=''
    if [[ -f "$target" ]]; then actual="$(/usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print $1}')"; fi
    if [[ "$actual" != "$expected" ]]; then
        /usr/bin/curl --fail --location --silent --show-error --retry 3 "$url" --output "$target.part"
        actual="$(/usr/bin/shasum -a 256 "$target.part" | /usr/bin/awk '{print $1}')"
        if [[ "$actual" != "$expected" ]]; then
            printf 'SHA-256 incorrect pour une dépendance du moteur.\n' >&2
            exit 1
        fi
        mv "$target.part" "$target"
    fi
}
fetch_verified "$python_url" "$python_sha" "$build_dir/downloads/cpython.tar.gz"
fetch_verified "$licenses_url" "$licenses_sha" "$build_dir/downloads/cpython-full.tar.zst"
python3 "$project_dir/tools/prepare-python-runtime.py" --root "$build_dir" \
    --archive "$build_dir/downloads/cpython.tar.gz" --sha256 "$python_sha" --version 3.13.15
/usr/bin/tar -xf "$build_dir/downloads/cpython-full.tar.zst" -C "$build_dir/licenses-source" python/licenses python/PYTHON.json
python_path="$build_dir/python/bin/python3"
"$python_path" -c 'import platform, sys; assert sys.version_info[:3] == (3, 13, 15); assert platform.machine() == "arm64"'
if [[ ! -x "$build_dir/venv/bin/python" ]] || ! "$build_dir/venv/bin/python" -c \
    'import pathlib,sys; assert sys.version_info[:3] == (3,13,15); assert pathlib.Path(sys.base_prefix).resolve() == pathlib.Path(sys.argv[1]).resolve()' "$build_dir/python"; then
    if [[ -e "$build_dir/venv" ]]; then
        previous_venv="$(mktemp -d "$build_dir/previous-venv.XXXXXX")"
        mv "$build_dir/venv" "$previous_venv/"
    fi
    "$python_path" -m venv "$build_dir/venv"
fi
venv_python="$build_dir/venv/bin/python"

cp "$project_dir/tools/engine-entry.py" "$project_dir/tools/KataLogEngine.spec" "$build_dir/inputs/"
cp "$project_dir/assets/icon/KataLog.icns" "$build_dir/inputs/KataLog.icns"
cp "$project_dir/requirements-runtime.txt" "$project_dir/requirements-runtime-build.txt" "$build_dir/inputs/"
cp "$project_dir"/Sources/KataLog/Resources/*.py "$build_dir/inputs/modules/"
"$venv_python" -m pip install --only-binary=:all: --require-hashes -r "$build_dir/inputs/requirements-runtime-build.txt"
# Keep previous generated engines available for inspection instead of allowing
# PyInstaller's --noconfirm to discard the earlier onedir/bundle prototype.
for previous in "$build_dir/dist/KataLogEngine" "$build_dir/dist/KataLogEngine.app"; do
    if [[ -e "$previous" ]]; then
        archive_dir="$(mktemp -d "$build_dir/previous-engine.XXXXXX")"
        mv "$previous" "$archive_dir/"
    fi
done
cd "$build_dir/inputs"
"$venv_python" -m PyInstaller --noconfirm --clean --workpath "$build_dir/pyinstaller-work" \
    --distpath "$build_dir/dist" "$build_dir/inputs/KataLogEngine.spec"
engine_dir="$build_dir/dist/KataLogEngine.app"
engine_executable="$engine_dir/Contents/MacOS/KataLogEngine"

# Include the upstream licence texts, including CPython's static native
# dependencies and NumPy's bundled native components, without build metadata.
"$venv_python" - "$build_dir" "$python_url" "$python_sha" "$licenses_url" "$licenses_sha" <<'PY'
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
output = root / 'dist' / 'KataLogEngine.app' / 'Contents' / 'Resources'
licenses = output / 'Licenses'
licenses.mkdir()
shutil.copytree(root / 'licenses-source' / 'python' / 'licenses', licenses / 'CPython')
packages = {}
for name in ('numpy', 'pyulog', 'pyinstaller'):
    distribution = importlib.metadata.distribution(name)
    packages[name] = distribution.version
    count = 0
    for file in distribution.files or ():
        path = Path(str(file))
        if any(part.lower().startswith(('license', 'copying')) for part in path.parts):
            source = Path(distribution.locate_file(file))
            if source.is_file():
                target = licenses / name / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
                count += 1
    if not count:
        raise RuntimeError(f'Missing upstream license: {name}')

def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

import ast
tree = ast.parse((root / 'inputs' / 'modules' / 'analyzer.py').read_text())
parser_version = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign)
                      and any(isinstance(target, ast.Name) and target.id == 'PARSER_VERSION' for target in node.targets))
manifest = {
    'format': 1,
    'protocol': 1,
    'parserVersion': parser_version,
    'python': '.'.join(map(str, sys.version_info[:3])),
    'architecture': 'arm64',
    'minimumMacOS': '15.0',
    'packages': packages,
    'pythonDistribution': {'url': sys.argv[2], 'sha256': sys.argv[3]},
    'pythonLicenses': {'url': sys.argv[4], 'sha256': sys.argv[5]},
    'sourceHashes': {path.name: sha256(path) for path in sorted((root / 'inputs' / 'modules').glob('*.py'))},
    'requirementsHashes': {name: sha256(root / 'inputs' / name) for name in ('requirements-runtime.txt', 'requirements-runtime-build.txt')},
    'buildInputHashes': {name: sha256(root / 'inputs' / name) for name in ('engine-entry.py', 'KataLogEngine.spec')},
}
(output / 'runtime-manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
(output / 'THIRD-PARTY-NOTICES.txt').write_text(
    'KataLog embedded engine\n'
    'CPython 3.13.15, built by Astral python-build-standalone, and its statically linked components.\n'
    'NumPy 2.5.3 and its bundled native components. pyulog 1.2.4.\n'
    'PyInstaller 6.22.3 bootloader: GPL with an exception for bundled applications.\n'
    'Complete upstream license texts are included in Licenses/.\n'
    'PyInstaller and its Python build dependencies are build tools; only its bootloader is distributed.\n'
    'Runtime requires no external Python, package manager, or internet package download.\n'
)
PY

# Fail before app packaging on private paths, hidden compressed code paths,
# external native dependencies, wrong architecture, or a newer macOS minimum.
"$venv_python" - "$engine_dir" <<'PY'
import json
import marshal
from pathlib import Path
import re
import subprocess
import sys
import types
import zipfile
from PyInstaller.archive.readers import CArchiveReader

root = Path(sys.argv[1])
forbidden = (('/' + 'Users' + '/').encode(), b'/opt/homebrew/', b'/usr/local/Cellar/')
code_count = 0
binary_count = 0

def check_bytes(data):
    if any(token in data for token in forbidden):
        raise RuntimeError('Absolute private or external package-manager path in bundled data.')

def check_code(code):
    global code_count
    if not isinstance(code, types.CodeType):
        return
    code_count += 1
    if Path(code.co_filename).is_absolute():
        raise RuntimeError('Absolute filename in compiled Python code.')
    check_bytes(code.co_filename.encode())
    for constant in code.co_consts:
        if isinstance(constant, types.CodeType):
            check_code(constant)
        elif isinstance(constant, str):
            check_bytes(constant.encode())
        elif isinstance(constant, bytes):
            check_bytes(constant)

for path in sorted(root.rglob('*')):
    if path.is_symlink():
        if not path.resolve().is_relative_to(root.resolve()):
            raise RuntimeError('Symlink escapes embedded runtime.')
        continue
    if not path.is_file():
        continue
    data = path.read_bytes()
    check_bytes(data)
    if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe'):
        binary_count += 1
        architecture = subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).strip()
        if architecture != 'arm64':
            raise RuntimeError('Unexpected embedded binary architecture.')
        loads = subprocess.check_output(['/usr/bin/otool', '-L', str(path)], text=True)
        for line in loads.splitlines()[1:]:
            target = line.strip().split(' (', 1)[0]
            if target.startswith('/') and not target.startswith(('/usr/lib/', '/System/Library/')):
                raise RuntimeError('External native dependency in embedded runtime.')
        commands = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
        for block in re.split(r'Load command \d+', commands):
            if 'cmd LC_BUILD_VERSION' in block:
                minimum = re.search(r'^\s+minos (\d+)\.(\d+)', block, re.MULTILINE)
            elif 'cmd LC_VERSION_MIN_MACOSX' in block:
                minimum = re.search(r'^\s+version (\d+)\.(\d+)', block, re.MULTILINE)
            else:
                continue
            if minimum is None or tuple(map(int, minimum.groups())) > (15, 0):
                raise RuntimeError('Embedded binary requires macOS newer than 15.0.')
    if path.name == 'base_library.zip':
        with zipfile.ZipFile(path) as archive:
            for name in archive.namelist():
                payload = archive.read(name)
                check_bytes(payload)
                if name.endswith('.pyc'):
                    check_code(marshal.loads(payload[16:]))

archive = CArchiveReader(str(root / 'Contents' / 'MacOS' / 'KataLogEngine'))
for name, info in archive.toc.items():
    kind = info[-1]
    if kind in ('s', 'm', 'M'):
        data = archive.extract(name)
        check_bytes(data)
        check_code(marshal.loads(data))
    elif kind == 'z':
        pyz = archive.open_embedded_archive(name)
        for module in pyz.toc:
            check_code(pyz.extract(module))
print(json.dumps({'enginePrivacy': 'ok', 'compiledCodeObjectsChecked': code_count, 'nativeBinariesChecked': binary_count}))
PY

# BUNDLE signed itself before the additional resource notices were copied.
# Refresh only its enclosing ad-hoc resource seal; release signing happens later.
/usr/bin/codesign --force --sign - --identifier com.mehdiguiard.katalog.engine "$engine_dir"
/usr/bin/codesign --verify --strict --verbose=2 "$engine_dir"

empty_test="$(mktemp -d "$build_dir/smoke.XXXXXX")"
mkdir -p "$empty_test/empty" "$empty_test/home"
/usr/bin/env -i HOME="$empty_test/home" PATH=/usr/bin:/bin \
    "$engine_executable" --katalog-runtime-info
/usr/bin/env -i HOME="$empty_test/home" PATH=/usr/bin:/bin \
    "$engine_executable" -u -B analyzer scan --folder "$empty_test/empty" \
    --database "$empty_test/library.sqlite" --output "$empty_test/snapshot.json"
/usr/bin/env -i HOME="$empty_test/home" PATH=/usr/bin:/bin \
    "$engine_executable" gcs --help >/dev/null
"$venv_python" - "$empty_test/snapshot.json" <<'PY'
import json, sys
snapshot = json.load(open(sys.argv[1]))
assert snapshot['logs'] == []
PY
printf '%s\n' "$engine_dir" > "$build_dir/ENGINE-PATH.txt"
printf '\nMoteur autonome créé : %s\n' "$engine_dir"
printf 'Signature actuelle : ad hoc ; signer les composants avec Developer ID lors du packaging de l’app.\n'
