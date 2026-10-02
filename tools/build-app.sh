#!/bin/bash
set -euo pipefail

# Build outside Desktop/iCloud: file-provider FinderInfo can break code signing.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${KATALOG_BUILD_DIR:-/private/tmp/katalog-swift-build}"
configuration="${KATALOG_CONFIGURATION:-release}"
sign_identity="${KATALOG_SIGN_IDENTITY:--}"
output_dir="${KATALOG_DIST_DIR:-$project_dir/dist}"
version="${KATALOG_VERSION:-0.8.1}"
build_number="${KATALOG_BUILD_NUMBER:-19}"
update_channel="${KATALOG_UPDATE_CHANNEL:-disabled}"
update_feed_url="${KATALOG_UPDATE_FEED_URL:-}"
update_public_key="${KATALOG_UPDATE_PUBLIC_KEY:-}"
ui_preview_build="${KATALOG_UI_PREVIEW_BUILD:-0}"
if [[ "$output_dir" != /* ]]; then output_dir="$project_dir/$output_dir"; fi
if [[ "$build_dir" != /* ]]; then build_dir="$project_dir/$build_dir"; fi
app_name='KataLog.app'
archive_prefix='KataLog'
if [[ "$ui_preview_build" != 0 && "$ui_preview_build" != 1 ]]; then
    printf 'KATALOG_UI_PREVIEW_BUILD doit valoir 0 ou 1.\n' >&2
    exit 1
fi
if [[ "$ui_preview_build" == 1 ]]; then
    if [[ ( "${output_dir%/}" != */preview-staging && ( "${output_dir%/}" != */0.6-staging || "$version" != 0.6.0 ) ) || "$update_channel" != disabled ]]; then
        printf 'La preview UI est réservée à un dossier preview-staging (ou 0.6-staging historique), avec mises à jour désactivées.\n' >&2
        exit 1
    fi
    app_name='KataLog Preview.app'
    archive_prefix='KataLog-Preview'
fi
if [[ -n "${KATALOG_ENGINE_PATH:-}" && "$KATALOG_ENGINE_PATH" != /* ]]; then
    KATALOG_ENGINE_PATH="$project_dir/$KATALOG_ENGINE_PATH"
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/katalog-clang-cache}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/private/tmp/katalog-xdg-cache}"

# Compile an immutable source snapshot outside Desktop's file provider.
# Only public build inputs are copied; fleet data, .git, dist and reports are excluded.
source_dir="$(mktemp -d /private/tmp/katalog-source.XXXXXX)"
staging_dir=""
cleanup() {
    if [[ -n "$staging_dir" ]]; then rm -rf "$staging_dir"; fi
    rm -rf "$source_dir"
}
trap cleanup EXIT
python3 - "$project_dir" "$source_dir" <<'PY'
import pathlib, shutil, stat, sys
source, destination = map(pathlib.Path, sys.argv[1:])
def copy_public_file(original, copied):
    # copyfile avoids Desktop File Provider xattr/resource-fork requests. Keep
    # executable modes, while never transferring FinderInfo into the snapshot.
    shutil.copyfile(original, copied)
    pathlib.Path(copied).chmod(stat.S_IMODE(pathlib.Path(original).stat().st_mode))
    return copied
for entry in ('Package.swift', 'Package.resolved', 'LICENSE', 'Sources', 'Tests', 'tools',
              'requirements-runtime-build.txt', 'requirements-runtime.txt', 'assets/icon'):
    original, copied = source / entry, destination / entry
    if not original.exists():
        continue
    copied.parent.mkdir(parents=True, exist_ok=True)
    if original.is_dir():
        shutil.copytree(original, copied, symlinks=True, copy_function=copy_public_file,
                        ignore=shutil.ignore_patterns('.DS_Store', '__pycache__', '*.pyc'))
    else:
        copy_public_file(original, copied)
PY
project_dir="$source_dir"
cd "$project_dir"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[0-9]+$ ]]; then
    printf 'Version ou numéro de build invalide.\n' >&2
    exit 1
fi
# Fail before a costly build if the public source snapshot lacks the reviewed GPL.
python3 - "$project_dir" <<'PY'
import importlib.util, pathlib, sys
project = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location('katalog_distribution', project / 'tools/verify-distribution.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.validate_project_license_source(project)
PY
if [[ -z "${KATALOG_ENGINE_PATH:-}" ]]; then
    bash tools/build-engine.sh
    engine_path="${KATALOG_ENGINE_BUILD_DIR:-/private/tmp/katalog-engine-build}/dist/KataLogEngine.app"
else
    engine_path="$KATALOG_ENGINE_PATH"
fi
[[ -x "$engine_path/Contents/MacOS/KataLogEngine" ]] || { printf 'Moteur embarqué absent.\n' >&2; exit 1; }
"$engine_path/Contents/MacOS/KataLogEngine" --katalog-runtime-info
python3 - "$engine_path/Contents/Resources/runtime-manifest.json" "$project_dir" <<'PY'
import hashlib, json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
resources = pathlib.Path(sys.argv[2]) / 'Sources/KataLog/Resources'
expected = {source.name: hashlib.sha256(source.read_bytes()).hexdigest()
            for source in sorted(resources.glob('*.py'))}
if not expected or manifest.get('sourceHashes') != expected:
    raise SystemExit('Le moteur embarqué ne correspond pas exactement aux sources actuelles. Reconstruisez-le.')
project = pathlib.Path(sys.argv[2])
requirements = {name: hashlib.sha256((project / name).read_bytes()).hexdigest()
                for name in ('requirements-runtime.txt', 'requirements-runtime-build.txt')}
build_inputs = {name: hashlib.sha256((project / 'tools' / name).read_bytes()).hexdigest()
                for name in ('engine-entry.py', 'KataLogEngine.spec')}
if manifest.get('requirementsHashes') != requirements or manifest.get('buildInputHashes') != build_inputs:
    raise SystemExit('Les dépendances ou la configuration du moteur embarqué ont changé. Reconstruisez-le.')
PY
# Source locations must stay useful without publishing this machine's username
# or absolute checkout path in #filePath strings and compiler debug information.
privacy_flags=(
    -Xswiftc -file-prefix-map -Xswiftc "$project_dir=/KataLog"
    -Xswiftc -debug-prefix-map -Xswiftc "$project_dir=/KataLog"
    -Xswiftc -file-prefix-map -Xswiftc "$HOME=/home/build"
    -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/home/build"
    -Xswiftc -file-compilation-dir -Xswiftc /KataLog
    -Xcc "-ffile-prefix-map=$project_dir=/KataLog"
    -Xcc "-fdebug-prefix-map=$project_dir=/KataLog"
    -Xcc "-ffile-prefix-map=$HOME=/home/build"
    -Xcc "-fdebug-prefix-map=$HOME=/home/build"
)
swift build --disable-sandbox --scratch-path "$build_dir" --configuration "$configuration" --product KataLog "${privacy_flags[@]}"
swift build --disable-sandbox --scratch-path "$build_dir" --configuration "$configuration" --product katalog-cli "${privacy_flags[@]}"
binary_dir="$(swift build --disable-sandbox --scratch-path "$build_dir" --configuration "$configuration" --show-bin-path)"
staging_dir="$(mktemp -d /private/tmp/katalog-app.XXXXXX)"
app_path="$staging_dir/$app_name"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Helpers" "$app_path/Contents/Frameworks" "$output_dir"
cp "$binary_dir/KataLog" "$app_path/Contents/MacOS/KataLog"
cp "$binary_dir/katalog-cli" "$app_path/Contents/MacOS/katalog-cli"
sparkle_framework="$binary_dir/Sparkle.framework"
if [[ ! -d "$sparkle_framework" ]]; then
    sparkle_framework="$build_dir/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
[[ -d "$sparkle_framework" ]] || { printf 'Framework Sparkle 2.10.0 absent. Résolvez les dépendances SwiftPM.\n' >&2; exit 1; }
/usr/bin/ditto --norsrc "$sparkle_framework" "$app_path/Contents/Frameworks/Sparkle.framework"
sparkle_license="$build_dir/artifacts/sparkle/Sparkle/LICENSE"
if [[ ! -f "$sparkle_license" ]]; then
    # Some SwiftPM artifact snapshots retain only the binary framework.
    # The licence is also in the pinned Sparkle package checkout.
    sparkle_license="$build_dir/checkouts/Sparkle/LICENSE"
fi
[[ -f "$sparkle_license" ]] || { printf 'Licence du SDK Sparkle absente.\n' >&2; exit 1; }
mkdir -p "$app_path/Contents/Resources/Licenses"
cp "$sparkle_license" "$app_path/Contents/Resources/Licenses/Sparkle-LICENSE.txt"
# CLI SwiftPM builds may leave a development search path; the installed app must find its embedded framework.
if ! /usr/bin/otool -l "$app_path/Contents/MacOS/KataLog" | /usr/bin/grep -F -q '@executable_path/../Frameworks'; then
    /usr/bin/install_name_tool -add_rpath '@executable_path/../Frameworks' "$app_path/Contents/MacOS/KataLog"
fi
/usr/bin/ditto --norsrc "$engine_path" "$app_path/Contents/Helpers/KataLogEngine.app"
# Stop before signing/packaging if an absolute macOS user path survived mapping.
# Do not print the matched path into release logs.
if LC_ALL=C /usr/bin/grep -a -F -q '/Users/' "$app_path/Contents/MacOS/KataLog" "$app_path/Contents/MacOS/katalog-cli"; then
    printf 'Publication interrompue : un chemin utilisateur absolu est présent dans l’exécutable.\n' >&2
    exit 1
fi
cp Sources/KataLog/Resources/*.py "$app_path/Contents/Resources/"
cp assets/icon/KataLog.icns "$app_path/Contents/Resources/KataLog.icns"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>KataLog</string>
  <key>CFBundleIdentifier</key><string>com.mehdiguiard.katalog</string>
  <key>CFBundleName</key><string>KataLog</string>
  <key>CFBundleDisplayName</key><string>KataLog</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.8.0</string>
  <key>CFBundleVersion</key><string>18</string>
  <key>KatalogBundledEngineRequired</key><true/>
  <key>CFBundleIconFile</key><string>KataLog</string>
  <key>NSLocalNetworkUsageDescription</key><string>KataLog se connecte à votre GCS pour découvrir votre flotte et récupérer ses logs.</string>
  <key>NSDesktopFolderUsageDescription</key><string>KataLog accède aux dossiers de logs choisis sur votre Bureau pour les analyser et y conserver les copies collectées.</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$app_path/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$build_number" "$app_path/Contents/Info.plist"
if [[ "$ui_preview_build" == 1 ]]; then
    /usr/bin/plutil -insert KataLogUIReviewPreview -bool true "$app_path/Contents/Info.plist"
    if [[ "${output_dir%/}" == */preview-staging ]]; then
        /usr/bin/plutil -insert KataLogPreviewLibraryComponent -string "KataLogPreview-$version" "$app_path/Contents/Info.plist"
    fi
    /usr/bin/plutil -replace CFBundleIdentifier -string com.mehdiguiard.katalog.preview06 "$app_path/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleName -string 'KataLog Preview' "$app_path/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleDisplayName -string 'KataLog Preview' "$app_path/Contents/Info.plist"
fi
# Embed KataLog's own GPL and public attribution separately from dependencies.
python3 - "$project_dir" "$app_path" <<'PY'
import importlib.util, pathlib, sys
project, app = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location('katalog_distribution', project / 'tools/verify-distribution.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.write_project_license(project, app)
module.validate_project_license(app, module.plistlib.loads((app / 'Contents/Info.plist').read_bytes()))
PY
update_arguments=(configure --app "$app_path" --channel "$update_channel")
if [[ -n "$update_feed_url" ]]; then update_arguments+=(--feed-url "$update_feed_url"); fi
if [[ -n "$update_public_key" ]]; then update_arguments+=(--public-key "$update_public_key"); fi
python3 tools/update-feed.py "${update_arguments[@]}"
printf 'APPL????' > "$app_path/Contents/PkgInfo"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
python3 tools/sign-bundle.py --app "$app_path" --identity "$sign_identity"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
# Desktop's file provider repeatedly adds FinderInfo to .app directories, even
# after removing it. Archive before copying to Desktop, then verify extraction.
archive="$output_dir/$archive_prefix-$version-macOS-arm64.zip"
if [[ -e "$archive" ]]; then
    previous_dir="$(mktemp -d "$output_dir/previous-build.XXXXXX")"
    mv "$archive" "$previous_dir/"
fi
/usr/bin/ditto -c -k --norsrc --keepParent "$app_path" "$archive"
if [[ -e "$output_dir/$archive_prefix.zip" ]]; then
    previous_dir="$(mktemp -d "$output_dir/previous-build.XXXXXX")"
    mv "$output_dir/$archive_prefix.zip" "$previous_dir/"
fi
cp "$archive" "$output_dir/$archive_prefix.zip"
ready_dir="$(mktemp -d /private/tmp/katalog-ready.XXXXXX)"
/usr/bin/ditto -x -k "$output_dir/$archive_prefix.zip" "$ready_dir"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$ready_dir/$app_name"
printf '%s\n' "$ready_dir/$app_name" > "$output_dir/LOCAL-APP-PATH.txt"
# Retire only the previously generated Desktop bundle, whose attributes change.
if [ -e "$output_dir/$app_name" ]; then
    previous_dir="$(mktemp -d "$output_dir/previous-build.XXXXXX")"
    mv "$output_dir/$app_name" "$previous_dir/"
fi
printf '\nArchive créée : %s\n' "$archive"
printf 'Copie locale vérifiée : %s\n' "$ready_dir/$app_name"
printf 'Pour installer : décompresser hors du Bureau, puis placer %s dans Applications.\n' "$app_name"
