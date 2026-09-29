#!/bin/bash
set -euo pipefail

# Run by the user in Terminal. Installs only this project's local app in the
# user's Applications folder; it does not alter any privacy/security setting.
project_dir="$(cd "$(dirname "$0")" && pwd)"
archive="$project_dir/dist/KataLog.zip"
applications_dir="$HOME/Applications"
destination="$applications_dir/KataLog.app"
staging_dir=""

finish_on_error() {
    local code=$?
    trap - ERR
    printf '\nInstallation interrompue (code %s). Le message précédent indique la cause.\n' "$code"
    if [[ -n "$staging_dir" ]]; then
        printf 'Fichiers préparés : %s\n' "$staging_dir"
    fi
    read -r -p 'Appuyez sur Entrée pour fermer… ' _response || true
    exit "$code"
}
trap finish_on_error ERR

if /usr/bin/pgrep -x KataLog >/dev/null; then
    printf 'KataLog est encore ouvert. Arrêtez les imports et collectes, puis quittez KataLog avant de relancer cet installateur.\n' >&2
    false
fi

printf 'Installation de KataLog dans :\n%s\n\n' "$destination"
if [[ ! -f "$archive" ]]; then
    printf 'Archive absente : %s\n' "$archive" >&2
    false
fi

mkdir -p "$applications_dir"
staging_dir="$(mktemp -d "$applications_dir/.katalog-install.XXXXXX")"
/usr/bin/ditto -x -k "$archive" "$staging_dir"
prepared="$staging_dir/KataLog.app"
[[ -x "$prepared/Contents/MacOS/KataLog" ]]
/usr/bin/codesign --verify --strict "$prepared"

if [[ -e "$destination" ]]; then
    backup_dir="$(mktemp -d "$applications_dir/.katalog-previous.XXXXXX")"
    mv "$destination" "$backup_dir/KataLog.app"
    printf 'Version précédente conservée : %s/KataLog.app\n' "$backup_dir"
fi
mv "$prepared" "$destination"
rmdir "$staging_dir"
staging_dir=""
/usr/bin/codesign --verify --strict "$destination"

printf '\nInstallation terminée. Demande d’ouverture de KataLog…\n'
/usr/bin/open "$destination"
printf '\nDans KataLog : Importer un dossier → choisissez votre dossier de logs.\n'
printf 'Vous pouvez fermer cette fenêtre Terminal.\n'
