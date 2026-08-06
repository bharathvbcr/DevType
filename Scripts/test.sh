#!/usr/bin/env bash
# Run SwiftPM tests with a full Xcode toolchain when available.
# Default macOS `xcode-select` may point at Command Line Tools only — swift test
# then fails; prefer Xcode.app's DEVELOPER_DIR.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  echo "==> DEVELOPER_DIR=${DEVELOPER_DIR}"
fi

exec swift test "$@"
