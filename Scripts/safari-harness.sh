#!/usr/bin/env bash
# Live end-to-end harness: drives the INSTALLED /Applications/DevType.app in a real Safari with
# real HID key events, then reports what each field held. See docs/DEVELOPMENT.md ("Safari live
# harness") and `Scripts/safari-harness.sh --help`.
#
# Builds the SafariHarness executable (SwiftPM target, not part of the app bundle) and execs it, so
# the process macOS attributes privacy permissions to stays the terminal app you launched this from.
#
#   Scripts/safari-harness.sh --dry-run      everything except posting events
#   Scripts/safari-harness.sh --live         the real run (types into Safari for a few minutes)
#   Scripts/safari-harness.sh --add-snippet  opens DevType's editor with the harness snippet
#
# Never run from CI: it needs a logged-in GUI session, Accessibility, and DevType running.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

# Build output goes to stderr-quiet unless it fails, so the harness's own preflight is what you read.
build_log="$(mktemp -t safari-harness-build)"
if ! swift build -c debug --product SafariHarness >"${build_log}" 2>&1; then
  cat "${build_log}" >&2
  rm -f "${build_log}"
  echo "error: swift build failed" >&2
  exit 1
fi
rm -f "${build_log}"

BIN="$(swift build -c debug --show-bin-path)/SafariHarness"
exec "${BIN}" --repo "${ROOT}" "$@"
