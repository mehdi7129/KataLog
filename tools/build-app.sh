#!/bin/bash
set -euo pipefail

# Build outside Desktop/iCloud: file-provider FinderInfo can break code signing.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${KATALOG_BUILD_DIR:-/private/tmp/katalog-swift-build}"
configuration="${KATALOG_CONFIGURATION:-release}"
sign_identity="${KATALOG_SIGN_IDENTITY:--}"
output_dir="$project_dir/dist"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/katalog-clang-cache}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/private/tmp/katalog-xdg-cache}"

cd "$project_dir"
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
binary_dir="$(swift build --disable-sandbox --scratch-path "$build_dir" --configuration "$configuration" --show-bin-path)"
staging_dir="$(mktemp -d /private/tmp/katalog-app.XXXXXX)"
trap 'rm -rf "$staging_dir"' EXIT
app_path="$staging_dir/KataLog.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$output_dir"
cp "$binary_dir/KataLog" "$app_path/Contents/MacOS/KataLog"
# Stop before signing/packaging if an absolute macOS user path survived mapping.
# Do not print the matched path into release logs.
if LC_ALL=C /usr/bin/grep -a -F -q '/Users/' "$app_path/Contents/MacOS/KataLog"; then
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
  <key>CFBundleShortVersionString</key><string>0.5.1</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>CFBundleIconFile</key><string>KataLog</string>
  <key>NSLocalNetworkUsageDescription</key><string>KataLog se connecte à votre GCS pour découvrir votre flotte et récupérer ses logs.</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
printf 'APPL????' > "$app_path/Contents/PkgInfo"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
if [[ "$sign_identity" == "-" ]]; then
    /usr/bin/codesign --force --sign - --identifier com.mehdiguiard.katalog "$app_path"
else
    /usr/bin/codesign --force --sign "$sign_identity" --options runtime --timestamp \
        --identifier com.mehdiguiard.katalog "$app_path"
fi
/usr/bin/codesign --verify --strict --verbose=2 "$app_path"
# Desktop's file provider repeatedly adds FinderInfo to .app directories, even
# after removing it. Archive before copying to Desktop, then verify extraction.
/usr/bin/ditto -c -k --norsrc --keepParent "$app_path" "$staging_dir/KataLog.zip"
mv "$staging_dir/KataLog.zip" "$output_dir/KataLog.zip"
ready_dir="$(mktemp -d /private/tmp/katalog-ready.XXXXXX)"
/usr/bin/ditto -x -k "$output_dir/KataLog.zip" "$ready_dir"
/usr/bin/codesign --verify --strict --verbose=2 "$ready_dir/KataLog.app"
printf '%s\n' "$ready_dir/KataLog.app" > "$output_dir/LOCAL-APP-PATH.txt"
# Retire only the previously generated Desktop bundle, whose attributes change.
if [ -e "$output_dir/KataLog.app" ]; then
    mv "$output_dir/KataLog.app" "$staging_dir/previous-KataLog.app"
fi
printf '\nArchive créée : %s\n' "$output_dir/KataLog.zip"
printf 'Copie locale vérifiée : %s\n' "$ready_dir/KataLog.app"
printf 'Pour installer : décompresser hors du Bureau, puis placer KataLog.app dans Applications.\n'
