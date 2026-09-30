#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
tools_dir="${KATALOG_DMG_BUILD_DIR:-/private/tmp/katalog-dmg-tools}"
if [[ ! -x "$tools_dir/bin/python3" ]]; then
    python3 -m venv "$tools_dir"
fi
"$tools_dir/bin/python3" -m pip install --disable-pip-version-check --require-hashes -r requirements-dmg-build.txt
app_path="${KATALOG_APP_PATH:-}"
if [[ -z "$app_path" ]]; then
    app_path="$(cat "${KATALOG_DIST_DIR:-$project_dir/dist}/LOCAL-APP-PATH.txt")"
fi
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
prefix='KataLog'
if [[ "$(/usr/libexec/PlistBuddy -c 'Print KataLogUIReviewPreview' "$app_path/Contents/Info.plist" 2>/dev/null || true)" == true ]]; then
    prefix='KataLog-Preview'
fi
output_path="${KATALOG_DMG_PATH:-${KATALOG_DIST_DIR:-$project_dir/dist}/$prefix-$version-macOS-arm64.dmg}"
args=(--app "$app_path" --output "$output_path" --identity "${KATALOG_SIGN_IDENTITY:--}")
if [[ -n "${KATALOG_NOTARY_PROFILE:-}" ]]; then
    args+=(--notary-profile "$KATALOG_NOTARY_PROFILE")
fi
"$tools_dir/bin/python3" tools/build-dmg.py "${args[@]}"
