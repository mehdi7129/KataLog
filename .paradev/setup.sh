#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
  echo "KataLog requires macOS 15+ and the Xcode / Swift 6 toolchain." >&2
  exit 1
fi
macos_version="$(sw_vers -productVersion)"
if [[ "${macos_version%%.*}" -lt 15 ]]; then
  echo "KataLog requires macOS 15+ (found $macos_version)." >&2
  exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "Install Xcode / Swift 6 and select its toolchain before running setup." >&2
  exit 1
fi

# Match the Python version and hashed runtime dependencies used by CI.
python_command="${KATALOG_SETUP_PYTHON:-python3.13}"
if [[ -z "${KATALOG_SETUP_PYTHON:-}" ]]; then
  for candidate in /opt/homebrew/opt/python@3.13/bin/python3.13 /usr/local/opt/python@3.13/bin/python3.13; do
    if [[ -x "$candidate" ]]; then
      python_command="$candidate"
      break
    fi
  done
fi
if ! command -v "$python_command" >/dev/null 2>&1; then
  echo "Install Python 3.13 (brew install python@3.13), or set KATALOG_SETUP_PYTHON to its executable." >&2
  exit 1
fi
"$python_command" -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 13) else "KataLog setup requires Python 3.13.")'

if [[ ! -e .venv ]]; then
  "$python_command" -m venv .venv
fi
if [[ ! -x .venv/bin/python ]]; then
  echo "The existing .venv is invalid. Move it aside and rerun setup." >&2
  exit 1
fi
.venv/bin/python -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 13) else "The existing .venv must use Python 3.13. Move it aside and rerun setup.")'
.venv/bin/python -m pip install --disable-pip-version-check --only-binary=:all: --require-hashes -r requirements-runtime.txt
swift package resolve

echo "Workspace ready. Use source .venv/bin/activate before running Python or Swift test gates."
