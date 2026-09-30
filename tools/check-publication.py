#!/usr/bin/env python3
"""Read-only publication guard for a Git working tree or a source export.

Examples:
    python3 tools/check-publication.py --include-untracked
    python3 tools/check-publication.py --path /tmp/public-source --blocklist /tmp/private.json

The default scans current working-tree contents selected by ``git ls-files``;
it does not audit Git history, GitHub metadata, release assets or dependencies.
``--path`` scans every file in an exported directory, including dotfiles.
Output contains paths, categories and line numbers only, never matched values.
Exit status: 0 = no findings within this coverage, 1 = findings, 2 = scan error.
A clean result is not a guarantee that a repository contains no personal data.
Use a separate secret scanner and a human review before changing visibility.

Private blocklist format: a JSON array of nonempty strings, or an object whose
values are arrays of such strings. Object keys are not printed. Matching is
literal and case-sensitive, against paths and file bytes, including binary
files. Keep the blocklist outside the repository; it can contain known real
controller IDs, stock identifiers, names, dates, emails or infrastructure.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from dataclasses import dataclass


MAX_FILE_BYTES = 16 * 1024 * 1024
RAW_EXTENSIONS = {".ulg", ".ulog", ".binlog", ".tlog"}
DATABASE_EXTENSIONS = {".db", ".sqlite", ".sqlite3", ".db-shm", ".db-wal"}
BUILD_EXTENSIONS = {".zip", ".dmg", ".pkg", ".ipa", ".pyc", ".pyo", ".tar", ".gz", ".tgz", ".7z", ".rar"}
KEY_EXTENSIONS = {".p12", ".pfx", ".key", ".keystore", ".mobileprovision"}
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".heic", ".tiff", ".gif", ".icns"}
PRIVATE_COMPONENTS = {
    ".git", ".ssh", ".aws", ".codex", ".claude",
    ".build", "deriveddata", "__pycache__", ".venv", "venv",
    "private", "private-notes", "private_notes", "local-data", "local_data",
    "downloads", "telechargements", "téléchargements", "reports", "exports",
    "carte sd drone", "application support", "node_modules",
}
PRIVATE_FILENAMES = {
    ".ds_store", "annotations.json", "settings.json", "preferences.json",
    "library.json", "snapshot.json", "fleet-snapshot.json", "manifest.json",
    "collection-queue.json", "queue.json", "credentials.json", "secrets.json",
    "views.json", "import-options.json", "gcs-settings.json", "gcs-collection.json",
    "fleet.json", "progress.json", ".archive-journal.json", ".restore-journal.json",
    "id_rsa", "id_ed25519", "known_hosts", "authorized_keys",
}
USER_PATH = re.compile(b"/" + b"Users/" + rb"([^/\s\x00\"'`<>]+)")
SAFE_USER_SEGMENTS = {b"USER", b"USERNAME", b"user", b"username", b"example", b"demo", b"Shared", b"utilisateur", b"yourname"}
IPV4 = re.compile(rb"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
IPV6 = re.compile(rb"(?<![\w:])(?:[fF][cCdD]|[fF][eE][89aAbB])[0-9a-fA-F:]+(?:%[\w.-]+)?(?![\w:])")
TOKEN_PATTERNS = (
    re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{20,255}|github_pat_[A-Za-z0-9_]{20,255})\b"),
    re.compile(rb"\b(?:xox[baprs]-[A-Za-z0-9-]{16,}|AKIA[0-9A-Z]{16})\b"),
    re.compile(rb"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,255}\b"),
    re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----"),
)
ASSIGNMENT_SECRET = re.compile(
    rb"(?i)\b(?:password|passwd|api_key|api-key|access_token|auth_token|client_secret)\b"
    rb"[\"']?\s*[:=]\s*[\"']([^\"'\r\n]{8,})[\"']"
)
SAFE_SECRET_WORDS = (b"example", b"placeholder", b"changeme", b"change_me", b"your_", b"dummy", b"test", b"demo", b"redacted", b"<", b"${")


@dataclass(frozen=True, order=True)
class Finding:
    path: str
    category: str
    line: int | None = None


def run_git(root: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    if result.returncode:
        # Git error messages can contain usernames, paths and URLs.
        raise ValueError("Impossible de lire la sélection Git ; utilisez --path pour un export.")
    return result.stdout


def git_files(root: Path, include_untracked: bool) -> list[Path]:
    raw = run_git(root, "ls-files", "-z")
    if include_untracked:
        raw += run_git(root, "ls-files", "--others", "--exclude-standard", "-z")
    return sorted({Path(os.fsdecode(name)) for name in raw.split(b"\x00") if name})


def export_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for current, dirs, names in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in list(dirs):
            directory = current_path / name
            if directory.is_symlink() or name == ".git":
                files.append(directory.relative_to(root))
                dirs.remove(name)
        files.extend((current_path / name).relative_to(root) for name in names)
    return sorted(files)


def load_blocklist(path: Path | None) -> tuple[bytes, ...]:
    if path is None:
        return ()
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        raise ValueError("Blocklist privée illisible ou JSON invalide.") from None
    if isinstance(payload, dict):
        if not all(isinstance(value, list) for value in payload.values()):
            raise ValueError("La blocklist doit contenir des listes de chaînes.")
        payload = [item for values in payload.values() for item in values]
    if not isinstance(payload, list) or not all(isinstance(item, str) and item for item in payload):
        raise ValueError("La blocklist doit être une liste de chaînes non vides.")
    return tuple({item.encode("utf-8") for item in payload})


def path_categories(relative: Path) -> set[str]:
    parts = [part.lower() for part in relative.parts]
    name = relative.name.lower()
    suffix = relative.suffix.lower()
    categories: set[str] = set()
    if any(part in PRIVATE_COMPONENTS or part.endswith((".app", ".dsym")) for part in parts):
        categories.add("dossier-prive-ou-artefact")
    if name in PRIVATE_FILENAMES or name.startswith(".env") and name not in {".env.example", ".env.sample"}:
        categories.add("etat-local-ou-secret")
    if suffix in RAW_EXTENSIONS:
        categories.add("log-brut")
    if suffix in DATABASE_EXTENSIONS or name.endswith((".sqlite-wal", ".sqlite-shm", ".sqlite3-wal", ".sqlite3-shm")):
        categories.add("base-de-donnees")
    if suffix in BUILD_EXTENSIONS:
        categories.add("artefact-build-ou-archive")
    if suffix in KEY_EXTENSIONS:
        categories.add("cle-ou-identite")
    if suffix in {".html", ".json", ".pdf", ".xlsx"} and re.match(r"(?:fleet[-_])?report(?:[-_.]|$)", name):
        categories.add("rapport-genere")
    if suffix == ".csv" and not (len(parts) >= 3 and parts[:2] == ["tests", "fixtures"] and "synthetic" in parts[2:]):
        categories.add("csv-non-synthetique")
    # Public icon resources are deliberately allowed; photos/screenshots need
    # a separate explicit review and should not enter source exports silently.
    if suffix in IMAGE_EXTENSIONS and parts[:2] != ["assets", "icon"]:
        categories.add("image-a-verifier")
    return categories


def is_lan_address(raw: bytes) -> bool:
    try:
        address = ipaddress.ip_address(raw.decode("ascii").split("%", 1)[0])
    except ValueError:
        return False
    if address.is_loopback:
        return False
    if isinstance(address, ipaddress.IPv6Address):
        return address.is_private or address.is_link_local
    first, second, third, _ = address.packed
    # RFC 5737 documentation ranges and localhost are intentionally accepted.
    if (first, second, third) in {(192, 0, 2), (198, 51, 100), (203, 0, 113)}:
        return False
    return (first == 10 or first == 172 and 16 <= second <= 31
            or (first, second) in {(192, 168), (169, 254)}
            or first == 100 and 64 <= second <= 127)


def content_findings(relative: Path, data: bytes, blocklist: tuple[bytes, ...]) -> set[Finding]:
    result: set[Finding] = set()
    name = relative.as_posix()
    binary = b"\x00" in data

    def add(category: str, offset: int) -> None:
        result.add(Finding(name, category, None if binary else data.count(b"\n", 0, offset) + 1))

    if data.startswith(b"ULog" + bytes((1, 18, 53))):
        add("log-brut", 0)
    if data.startswith(b"SQLite format 3" + bytes((0,))):
        add("base-de-donnees", 0)
    if data[:4] in {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "7f454c46")}:
        add("binaire-compile-a-verifier", 0)

    for match in USER_PATH.finditer(data):
        if match.group(1) not in SAFE_USER_SEGMENTS:
            add("chemin-utilisateur", match.start())
    for pattern in TOKEN_PATTERNS:
        for match in pattern.finditer(data):
            add("secret-ou-cle-privee", match.start())
    for match in ASSIGNMENT_SECRET.finditer(data):
        value = match.group(1).lower()
        if not any(word in value for word in SAFE_SECRET_WORDS):
            add("secret-litteral", match.start())
    for pattern in (IPV4, IPV6):
        for match in pattern.finditer(data):
            if is_lan_address(match.group()):
                add("adresse-reseau-local", match.start())
    for needle in blocklist:
        offset = data.find(needle)
        if offset >= 0:
            add("identifiant-prive-blocklist", offset)
    return result


def scan(root: Path, files: list[Path], blocklist: tuple[bytes, ...]) -> list[Finding]:
    findings: set[Finding] = set()
    for relative in files:
        display = relative.as_posix()
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Les fichiers supplémentaires doivent être relatifs à la racine analysée.")
        path = root / relative
        for category in path_categories(relative):
            findings.add(Finding(display, category))
        if any(needle in os.fsencode(display) for needle in blocklist):
            findings.add(Finding(display, "identifiant-prive-blocklist"))
        if path.is_symlink():
            findings.add(Finding(display, "lien-symbolique-a-verifier"))
            continue
        if any((root / parent).is_symlink() for parent in relative.parents if parent != Path(".")):
            findings.add(Finding(display, "lien-symbolique-a-verifier"))
            continue
        if path.is_dir():
            continue
        if not path.is_file():
            findings.add(Finding(display, "fichier-selectionne-manquant"))
            continue
        if path.stat().st_size > MAX_FILE_BYTES:
            findings.add(Finding(display, "fichier-volumineux-non-analyse"))
            continue
        try:
            data = path.read_bytes()
        except OSError:
            raise ValueError("Un fichier sélectionné ne peut pas être lu.") from None
        findings.update(content_findings(relative, data, blocklist))
    return sorted(findings, key=lambda item: (item.path, item.category, item.line or 0))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--path", type=Path, help="Analyser tous les fichiers d'un export, sans sélection Git.")
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="Racine du dépôt (défaut : dossier courant).")
    parser.add_argument("--include-untracked", action="store_true", help="Ajouter les fichiers Git non suivis et non ignorés.")
    parser.add_argument("--extra", type=Path, action="append", default=[], help="Fichier supplémentaire relatif à la racine (répétable).")
    parser.add_argument("--blocklist", type=Path, help="JSON privé extérieur au dépôt, dont les valeurs ne sont jamais affichées.")
    args = parser.parse_args(argv)
    try:
        root = (args.path or args.repo).resolve()
        if not root.is_dir():
            raise ValueError("La racine doit être un dossier existant.")
        if args.path and args.include_untracked:
            raise ValueError("--include-untracked concerne uniquement la sélection Git.")
        blocklist = load_blocklist(args.blocklist)
        if args.blocklist and args.blocklist.resolve().is_relative_to(root):
            raise ValueError("La blocklist privée doit rester à l'extérieur de la racine analysée.")
        files = export_files(root) if args.path else git_files(root, args.include_untracked)
        files = sorted(set(files + args.extra))
        findings = scan(root, files, blocklist)
    except OSError:
        print("ERREUR : impossible de lire un élément nécessaire à l'analyse.", file=sys.stderr)
        return 2
    except ValueError as error:
        # All errors raised above deliberately omit private values and paths.
        print(f"ERREUR : {error}", file=sys.stderr)
        return 2
    for finding in findings:
        location = f":{finding.line}" if finding.line is not None else ""
        print(f"{json.dumps(finding.path, ensure_ascii=True)}{location} [{finding.category}]")
    print(f"{len(files)} fichiers analysés ; {len(findings)} signalements.")
    print("Couverture : fichiers courants, chemins, secrets usuels, LAN et blocklist facultative ; historique Git et métadonnées GitHub exclus.")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
