#!/bin/bash
set -euo pipefail

# User-opened launcher: extracts the signed local build away from Desktop's
# file provider, then asks macOS LaunchServices to open the app normally.
project_dir="$(cd "$(dirname "$0")" && pwd)"
archive="$project_dir/dist/KataLog.zip"

fail() {
    printf '\n%s\n' "$1"
    read -r -p 'Appuyez sur Entrée pour fermer… ' _response || true
    exit 1
}

[[ -f "$archive" ]] || fail "Archive introuvable : $archive"
launch_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/katalog-launch.XXXXXX")"
/usr/bin/ditto -x -k "$archive" "$launch_dir" || fail "Échec de l’extraction de KataLog."
app_path="$launch_dir/KataLog.app"
[[ -x "$app_path/Contents/MacOS/KataLog" ]] || fail "L’exécutable KataLog est absent ou non exécutable."
/usr/bin/codesign --verify --strict "$app_path" || fail "La signature de KataLog n’est pas valide."

printf 'Ouverture de KataLog…\n%s\n' "$app_path"
/usr/bin/open "$app_path" || fail "macOS n’a pas pu ouvrir KataLog. Conservez le message d’erreur affiché ci-dessus."
printf '\nLa demande d’ouverture a été envoyée. Dans KataLog : Importer un dossier → choisissez votre dossier de logs.\n'
printf 'Vous pouvez fermer cette fenêtre Terminal.\n'
