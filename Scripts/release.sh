#!/usr/bin/env bash
# §7.5 — Build, sign, notarize, staple, and package DevType for distribution.
#
# This is the ONLY path that produces an artifact other people can run. The local
# `DevType Local Signing` cert used by package-app.sh is self-signed: Gatekeeper
# will refuse it on any machine but yours. Distribution requires Developer ID.
#
# Prerequisites (one time):
#   1. Apple Developer Program membership.
#   2. A "Developer ID Application" certificate in your login keychain.
#      Verify:  security find-identity -p codesigning -v | grep "Developer ID"
#   3. A notarytool keychain profile holding an app-specific password:
#        xcrun notarytool store-credentials DevTypeNotary \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-pw>
#
# Usage:
#   ./Scripts/release.sh                       # build + sign + notarize + staple + dmg
#   DEVTYPE_SKIP_NOTARIZE=1 ./Scripts/release.sh   # dry run: sign + dmg only
#
# Env:
#   DEVTYPE_SIGN_IDENTITY  Developer ID Application: Name (TEAMID)   [required unless skipping]
#   DEVTYPE_NOTARY_PROFILE notarytool keychain profile name          [default DevTypeNotary]
#   DEVTYPE_SKIP_NOTARIZE  1 to skip notarize/staple
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT}/dist"
APP_BUNDLE="${ROOT}/.build/DevType.app"
NOTARY_PROFILE="${DEVTYPE_NOTARY_PROFILE:-DevTypeNotary}"
SKIP_NOTARIZE="${DEVTYPE_SKIP_NOTARIZE:-0}"

die() { echo "error: $*" >&2; exit 1; }

# --- 1. Identity check ------------------------------------------------------
if [[ "${SKIP_NOTARIZE}" != "1" ]]; then
  if [[ -z "${DEVTYPE_SIGN_IDENTITY:-}" ]]; then
    echo "Available signing identities:"
    security find-identity -p codesigning -v || true
    die "set DEVTYPE_SIGN_IDENTITY to your 'Developer ID Application: ...' identity"
  fi
  case "${DEVTYPE_SIGN_IDENTITY}" in
    "Developer ID Application"*) ;;
    *) die "DEVTYPE_SIGN_IDENTITY must be a 'Developer ID Application' identity to notarize (got '${DEVTYPE_SIGN_IDENTITY}')" ;;
  esac
  xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 \
    || die "notarytool profile '${NOTARY_PROFILE}' not found. Run: xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <id> --team-id <team> --password <app-specific-pw>"
fi

# --- 2. Build release + package with hardened runtime -----------------------
echo "==> building release bundle"
DEVTYPE_HARDENED_RUNTIME=1 "${ROOT}/Scripts/package-app.sh" release
[[ -d "${APP_BUNDLE}" ]] || die "expected bundle at ${APP_BUNDLE}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_BUNDLE}/Contents/Info.plist")"
echo "==> version ${VERSION}"

# Verify the hardened runtime flag actually landed. Notarization fails without it,
# and the failure message from Apple is much less obvious than this one.
if ! codesign -d --verbose=2 "${APP_BUNDLE}" 2>&1 | grep "flags=.*runtime" >/dev/null; then
  die "bundle is not signed with the Hardened Runtime; notarization would be rejected"
fi
codesign --verify --strict --deep --verbose=2 "${APP_BUNDLE}" \
  || die "codesign verification failed"

mkdir -p "${DIST}"
STAGE="${DIST}/DevType-${VERSION}"
rm -rf "${STAGE}" && mkdir -p "${STAGE}"
cp -R "${APP_BUNDLE}" "${STAGE}/DevType.app"
ln -sf /Applications "${STAGE}/Applications"

# --- 3. Notarize ------------------------------------------------------------
if [[ "${SKIP_NOTARIZE}" == "1" ]]; then
  echo "==> skipping notarization (DEVTYPE_SKIP_NOTARIZE=1)"
else
  ZIP="${DIST}/DevType-${VERSION}.zip"
  echo "==> submitting for notarization (this can take several minutes)"
  # ditto preserves the signature and extended attributes; `zip` does not.
  ditto -c -k --keepParent "${STAGE}/DevType.app" "${ZIP}"
  xcrun notarytool submit "${ZIP}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait \
    || die "notarization failed. Inspect with: xcrun notarytool log <submission-id> --keychain-profile ${NOTARY_PROFILE}"

  echo "==> stapling ticket"
  xcrun stapler staple "${STAGE}/DevType.app" || die "stapler failed"
  xcrun stapler validate "${STAGE}/DevType.app" || die "staple validation failed"
  rm -f "${ZIP}"
fi

# --- 4. DMG -----------------------------------------------------------------
DMG="${DIST}/DevType-${VERSION}.dmg"
echo "==> building ${DMG}"
rm -f "${DMG}"
hdiutil create -volname "DevType ${VERSION}" \
  -srcfolder "${STAGE}" \
  -ov -format ULFO \
  "${DMG}" >/dev/null

if [[ "${SKIP_NOTARIZE}" != "1" ]]; then
  # The DMG itself is a separate artifact and needs its own signature + ticket,
  # otherwise Gatekeeper quarantines the container even though the app inside is fine.
  codesign --force --sign "${DEVTYPE_SIGN_IDENTITY}" --timestamp "${DMG}"
  xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait \
    || die "DMG notarization failed"
  xcrun stapler staple "${DMG}" || die "DMG stapler failed"
fi

rm -rf "${STAGE}"

# --- 5. Verify like an end user --------------------------------------------
echo "==> final verification"
spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}" 2>&1 || true
shasum -a 256 "${DMG}"
echo
echo "Done: ${DMG}"
if [[ "${SKIP_NOTARIZE}" == "1" ]]; then
  echo "NOTE: unnotarized. Gatekeeper will block this on other machines."
fi
