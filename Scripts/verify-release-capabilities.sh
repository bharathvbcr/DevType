#!/usr/bin/env bash
# Verify release bundle capabilities before publishing.
#
# Two separate assertions, and both matter:
#
#   1. FoundationModels.framework is linked at all. A binary built on a toolchain
#      without the SDK compiles every `#if canImport(FoundationModels)` to its
#      fallback, so the DMG silently ships with no AI transforms, no Local AI
#      dictation corrector and no macOS 26 speech engine. That is exactly what
#      v0.1.7 published.
#
#   2. It is linked WEAKLY. DevType's deployment target is macOS 14 and the
#      framework only exists from macOS 26, so a strong link makes dyld refuse to
#      launch the app on every Mac below 26 — a far worse regression than the one
#      above, and invisible to the machine that built it. Availability guards keep
#      the calls safe; the weak load command is what keeps launch safe.
set -euo pipefail

APP="${1:-}"

if [[ "${DEVTYPE_REQUIRE_FOUNDATION_MODELS:-0}" != "1" ]]; then
  echo "notice: DEVTYPE_REQUIRE_FOUNDATION_MODELS not set; skipping Foundation Models linkage check"
  exit 0
fi

if [[ -z "${APP}" ]]; then
  echo "error: missing app bundle path argument" >&2
  exit 1
fi

if [[ ! -d "${APP}" ]]; then
  echo "error: app bundle not found at '${APP}'" >&2
  exit 1
fi

BINARY="${APP}/Contents/MacOS/DevType"
if [[ ! -f "${BINARY}" ]]; then
  # Check if executable has different name from Info.plist
  EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${APP}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "${EXEC_NAME}" && -f "${APP}/Contents/MacOS/${EXEC_NAME}" ]]; then
    BINARY="${APP}/Contents/MacOS/${EXEC_NAME}"
  else
    echo "error: Mach-O binary not found in '${APP}/Contents/MacOS'" >&2
    exit 1
  fi
fi

OTOOL="${OTOOL:-otool}"
if ! command -v "${OTOOL}" >/dev/null 2>&1 && [[ ! -x "${OTOOL}" ]]; then
  echo "error: otool not found at '${OTOOL}'" >&2
  exit 1
fi

OTOOL_OUT="$("${OTOOL}" -L "${BINARY}" 2>&1)" || {
  echo "error: failed to inspect dependencies with otool on '${BINARY}': ${OTOOL_OUT}" >&2
  exit 1
}

FM_LINES="$(echo "${OTOOL_OUT}" | grep "FoundationModels\.framework" || true)"
if [[ -z "${FM_LINES}" ]]; then
  echo "error: '${BINARY}' is not linked against FoundationModels.framework (built without Foundation Models SDK)" >&2
  exit 1
fi

# `otool -L` marks an LC_LOAD_WEAK_DYLIB entry by appending `, weak)` to its line.
if ! echo "${FM_LINES}" | grep -q "weak"; then
  echo "error: '${BINARY}' links FoundationModels.framework strongly; it must be weak or the app cannot launch below macOS 26:" >&2
  echo "${FM_LINES}" >&2
  exit 1
fi

echo "ok: '${BINARY}' weakly links FoundationModels.framework"
exit 0
