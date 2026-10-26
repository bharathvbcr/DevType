#!/usr/bin/env bash
# Identity, version stamp, ATS, toolchain keys, and codesign for a packaged
# DevType.app. Foundation Models linkage runs only when
# DEVTYPE_REQUIRE_FOUNDATION_MODELS=1; otherwise the capability script
# announces the skip and exits 0.
#
# Usage: verify-packaged-bundle.sh <App.app>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <App.app>" >&2
  exit 2
fi

APP="$1"
if [[ ! -d "${APP}" ]]; then
  echo "error: no bundle produced at ${APP}" >&2
  exit 1
fi

PLIST="${APP}/Contents/Info.plist"
if [[ ! -f "${PLIST}" ]]; then
  echo "error: ${APP} has no Contents/Info.plist" >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST}")"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")"
LOCAL_NETWORKING="$(/usr/libexec/PlistBuddy -c \
  'Print :NSAppTransportSecurity:NSAllowsLocalNetworking' "${PLIST}")"

echo "  Bundle Identifier: ${BUNDLE_ID}"
echo "  Stamped Version:   ${VER} (build ${BUILD})"

PLACEHOLDER_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT}/Resources/Info.plist")"
PLACEHOLDER_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${ROOT}/Resources/Info.plist")"
"${ROOT}/Scripts/verify-stamped-version.sh" "${VER}" "${BUILD}" "${PLACEHOLDER_VER}" "${PLACEHOLDER_BUILD}"

if [[ "${LOCAL_NETWORKING}" != "true" ]]; then
  echo "error: packaged Info.plist does not allow narrowly scoped local networking" >&2
  exit 1
fi
for ATS_KEY in NSAllowsArbitraryLoads NSAllowsArbitraryLoadsForMedia NSAllowsArbitraryLoadsInWebContent; do
  if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:${ATS_KEY}" \
    "${PLIST}" >/dev/null 2>&1; then
    echo "error: packaged Info.plist contains broad ATS exception ${ATS_KEY}" >&2
    exit 1
  fi
done

for TOOLCHAIN_KEY in DTXcode DTXcodeBuild DTSDKName DTPlatformVersion; do
  if ! /usr/libexec/PlistBuddy -c "Print :${TOOLCHAIN_KEY}" "${PLIST}" >/dev/null 2>&1; then
    echo "error: packaged Info.plist missing toolchain key ${TOOLCHAIN_KEY}" >&2
    exit 1
  fi
done

# Unset by default so a developer on an older Xcode is not blocked. The
# macos-26 packaging job and every tagged release set the gate.
"${ROOT}/Scripts/verify-release-capabilities.sh" "${APP}"

codesign --verify --strict --verbose=2 "${APP}"
echo "ok: ${APP} passed bundle verification"
