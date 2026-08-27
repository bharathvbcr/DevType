#!/usr/bin/env bash
# §7.5 — Build, sign, notarize, staple, and package DevType for distribution.
#
# This is the ONLY path that produces an artifact other people can run. What
# package-app.sh signs with locally (see Scripts/signing-identity.sh) is good enough
# for TCC and the keychain but not for anyone else's machine: a self-signed
# certificate is trusted nowhere, and an Apple Development certificate cannot be
# notarized. Distribution requires Developer ID.
#
# Prerequisites (one time):
#   1. Apple Developer Program membership (the paid one — a free Apple ID yields an
#      Apple Development certificate, which is fine for local builds but not this).
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

case "${SKIP_NOTARIZE}" in
  0|1) ;;
  *) die "DEVTYPE_SKIP_NOTARIZE must be 0 or 1 (got '${SKIP_NOTARIZE}')" ;;
esac

# CI supplies the tag explicitly so git-describe cannot quietly build a version
# other than the ref being published. Local dry-runs may omit it intentionally.
if [[ -n "${DEVTYPE_RELEASE_TAG:-}" ]]; then
  "${ROOT}/Scripts/release-preflight.sh" "${DEVTYPE_RELEASE_TAG}"
fi

# --- 1. Identity check ------------------------------------------------------
if [[ "${SKIP_NOTARIZE}" != "1" ]]; then
  HAS_DEV_ID=0
  if [[ -n "${DEVTYPE_SIGN_IDENTITY:-}" ]]; then
    case "${DEVTYPE_SIGN_IDENTITY}" in
      "Developer ID Application"*) HAS_DEV_ID=1 ;;
      *) echo "warning: DEVTYPE_SIGN_IDENTITY is not 'Developer ID Application...'; falling back to local signing" ;;
    esac
  else
    if security find-identity -p codesigning -v 2>/dev/null | grep -q "Developer ID Application"; then
      HAS_DEV_ID=1
      DEVTYPE_SIGN_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null | grep "Developer ID Application" | head -n 1 | sed 's/.*"\(.*\)".*/\1/')"
      export DEVTYPE_SIGN_IDENTITY
    fi
  fi

  if [[ "${HAS_DEV_ID}" -eq 1 ]]; then
    xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 \
      || die "notarytool profile '${NOTARY_PROFILE}' not found. Run: xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <id> --team-id <team> --password <app-specific-pw>"
  else
    echo "==> No Developer ID Application identity available; proceeding with local signing (DEVTYPE_SKIP_NOTARIZE=1)"
    SKIP_NOTARIZE="1"
  fi
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
rm -f "${DIST}"/DevType-*.dmg "${DIST}"/DevType-*.zip
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
[[ -s "${DMG}" ]] || die "DMG is missing or empty: ${DMG}"
hdiutil imageinfo "${DMG}" >/dev/null || die "DMG image verification failed: ${DMG}"
if spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}"; then
  echo "Gatekeeper assessment: passed"
elif [[ "${SKIP_NOTARIZE}" == "1" ]]; then
  echo "warning: Gatekeeper assessment rejected the intentionally unnotarized dry-run artifact"
else
  die "Gatekeeper assessment failed for notarized artifact"
fi
shasum -a 256 "${DMG}"
echo
echo "Done: ${DMG}"
if [[ "${SKIP_NOTARIZE}" == "1" ]]; then
  echo "NOTE: unnotarized. Gatekeeper will block this on other machines."
fi
