#!/bin/bash
set -euo pipefail

# Local ad hoc build + synthetic runtime qualification. No release, Keychain or fleet access.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
export KATALOG_ARCH="${KATALOG_ARCH:-$(/usr/bin/uname -m)}"
host_args=(--architecture "$KATALOG_ARCH")
if [[ -n "${KATALOG_SMOKE_EXPECT_MAJOR:-}" ]]; then host_args+=(--major "$KATALOG_SMOKE_EXPECT_MAJOR"); fi
python3 "$project_dir/tools/check-native-host.py" "${host_args[@]}"
platform_version="$(/usr/bin/sw_vers -productVersion)"
smoke_root="$(mktemp -d /private/tmp/katalog-package-smoke.XXXXXX)"
report_path="${KATALOG_SMOKE_REPORT:-$project_dir/reports/package-smoke-verification.json}"
if [[ "$report_path" != /* ]]; then report_path="$project_dir/$report_path"; fi
export KATALOG_ENGINE_BUILD_DIR="$smoke_root/engine"
export KATALOG_BUILD_DIR="$smoke_root/swift"
export KATALOG_DIST_DIR="$smoke_root/dist"
export KATALOG_SIGN_IDENTITY='-'
export KATALOG_VERSION='0.9.0'
export KATALOG_BUILD_NUMBER='28'
export KATALOG_UPDATE_CHANNEL="${KATALOG_SMOKE_UPDATE_CHANNEL:-disabled}"
export KATALOG_UPDATE_FEED_URL=''
export KATALOG_UPDATE_PUBLIC_KEY=''
if [[ "$KATALOG_UPDATE_CHANNEL" == stable ]]; then
    feed_folder='stable'
    if [[ "$KATALOG_ARCH" == x86_64 ]]; then feed_folder='stable-intel'; fi
    export KATALOG_UPDATE_FEED_URL="https://raw.githubusercontent.com/mehdi7129/KataLog/main/updates/$feed_folder/appcast.xml"
    export KATALOG_UPDATE_PUBLIC_KEY="$(cat "$project_dir/updates/stable/public-key.txt")"
fi
unset KATALOG_ENGINE_PATH KATALOG_NOTARY_PROFILE KATALOG_UI_PREVIEW_BUILD
cd "$project_dir"
bash tools/build-engine.sh
export KATALOG_ENGINE_PATH="$KATALOG_ENGINE_BUILD_DIR/dist/KataLogEngine.app"
bash tools/build-app.sh
app_path="$(cat "$KATALOG_DIST_DIR/LOCAL-APP-PATH.txt")"
python3 tools/verify-distribution.py --app "$app_path" --report "$report_path"
python3 tools/verify-usb-runtime.py --app "$app_path" --report "$smoke_root/usb-bundle-proof.json" --bench-python "$KATALOG_ENGINE_BUILD_DIR/venv/bin/python3"
export_dir="${KATALOG_SMOKE_EXPORT_DIR:-$project_dir/reports/candidate}"
mkdir -p "$export_dir"
cp "$KATALOG_DIST_DIR/KataLog-$KATALOG_VERSION-macOS-$KATALOG_ARCH.zip" "$export_dir/"
cp "$smoke_root/usb-bundle-proof.json" "$export_dir/usb-bundle.json"
python3 - "$report_path" "$platform_version" "$export_dir" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
path = pathlib.Path(sys.argv[1])
report = json.loads(path.read_text())
report['packageSmoke'] = {
    'macOS': sys.argv[2], 'architecture': os.environ['KATALOG_ARCH'], 'signing': 'ad-hoc',
    'notarizationTested': False, 'productionRelease': False,
    'updatesEnabledInBundle': os.environ['KATALOG_UPDATE_CHANNEL'] != 'disabled', 'fleetContacted': False,
}
path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
export = pathlib.Path(sys.argv[3])
archive = export / ('KataLog-' + os.environ['KATALOG_VERSION'] + '-macOS-' + os.environ['KATALOG_ARCH'] + '.zip')
provenance = dict(schemaVersion=1, commit=subprocess.check_output(['git','rev-parse','HEAD'], text=True).strip(),
    architecture=os.environ['KATALOG_ARCH'], version=os.environ['KATALOG_VERSION'], build=os.environ['KATALOG_BUILD_NUMBER'],
    archive=archive.name, sha256=hashlib.sha256(archive.read_bytes()).hexdigest(), signing='ad-hoc',
    runID=os.environ.get('GITHUB_RUN_ID'), runAttempt=os.environ.get('GITHUB_RUN_ATTEMPT'))
(export / 'candidate.json').write_text(json.dumps(provenance, indent=2) + '\n')
print('Packaging synthétique : %d contrôles réussis ; aucun asset publié.' % len(report['checks']))
PY
printf 'Les inputs et l’archive locale restent disponibles sous %s\n' "$smoke_root"
