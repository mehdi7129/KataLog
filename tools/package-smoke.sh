#!/bin/bash
set -euo pipefail

# Local ad hoc build + synthetic runtime qualification. No release, Keychain or fleet access.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(/usr/bin/uname -s)" != Darwin || "$(/usr/bin/uname -m)" != arm64 ]]; then
    printf 'La recette packaging nécessite macOS Apple Silicon.\n' >&2
    exit 1
fi
platform_version="$(/usr/bin/sw_vers -productVersion)"
if [[ -n "${KATALOG_SMOKE_EXPECT_MAJOR:-}" && "${platform_version%%.*}" != "$KATALOG_SMOKE_EXPECT_MAJOR" ]]; then
    printf 'Le runner ne fournit pas la version macOS attendue.\n' >&2
    exit 1
fi
smoke_root="$(mktemp -d /private/tmp/katalog-package-smoke.XXXXXX)"
report_path="${KATALOG_SMOKE_REPORT:-$project_dir/reports/package-smoke-verification.json}"
if [[ "$report_path" != /* ]]; then report_path="$project_dir/$report_path"; fi
export KATALOG_ENGINE_BUILD_DIR="$smoke_root/engine"
export KATALOG_BUILD_DIR="$smoke_root/swift"
export KATALOG_DIST_DIR="$smoke_root/dist"
export KATALOG_SIGN_IDENTITY='-'
export KATALOG_VERSION='0.8.5'
export KATALOG_BUILD_NUMBER='24'
export KATALOG_UPDATE_CHANNEL='disabled'
export KATALOG_UPDATE_FEED_URL=''
export KATALOG_UPDATE_PUBLIC_KEY=''
unset KATALOG_ENGINE_PATH KATALOG_NOTARY_PROFILE KATALOG_UI_PREVIEW_BUILD
cd "$project_dir"
bash tools/build-engine.sh
export KATALOG_ENGINE_PATH="$KATALOG_ENGINE_BUILD_DIR/dist/KataLogEngine.app"
bash tools/build-app.sh
app_path="$(cat "$KATALOG_DIST_DIR/LOCAL-APP-PATH.txt")"
python3 tools/verify-distribution.py --app "$app_path" --report "$report_path"
python3 - "$report_path" "$platform_version" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
report = json.loads(path.read_text())
report['packageSmoke'] = {
    'macOS': sys.argv[2], 'architecture': 'arm64', 'signing': 'ad-hoc',
    'notarizationTested': False, 'productionRelease': False,
    'updateFeedActive': False, 'fleetContacted': False,
}
path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
print('Packaging synthétique : %d contrôles réussis ; aucun asset publié.' % len(report['checks']))
PY
printf 'Les inputs et l’archive locale restent disponibles sous %s\n' "$smoke_root"
