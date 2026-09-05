#!/usr/bin/env bash
# Hermetic regression for package-app.sh's entitlement and Hardened Runtime cache gates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=package-signing-contract.sh
source "${ROOT}/Scripts/package-signing-contract.sh"

TEST_ROOT="$(mktemp -d -t devtype-package-signing-test)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

SOURCE_ENTITLEMENTS="${TEST_ROOT}/DevType.entitlements"
STALE_ENTITLEMENTS="${TEST_ROOT}/DevType.stale.entitlements"
ORDER_A_ENTITLEMENTS="${TEST_ROOT}/DevType.order-a.entitlements"
ORDER_B_ENTITLEMENTS="${TEST_ROOT}/DevType.order-b.entitlements"
ENTITLEMENTS_STAMP="${TEST_ROOT}/DevType.app.entitlements-sha256"
APP="${TEST_ROOT}/DevType.app"
CONTENTS="${APP}/Contents"
EXECUTABLE="${CONTENTS}/MacOS/DevType"

plutil -create xml1 "${SOURCE_ENTITLEMENTS}"
cp "${SOURCE_ENTITLEMENTS}" "${STALE_ENTITLEMENTS}"
/usr/libexec/PlistBuddy \
  -c 'Add :com.apple.security.automation.apple-events bool true' \
  "${STALE_ENTITLEMENTS}" >/dev/null

# The fingerprint is semantic and deterministic, not an XML key-order hash.
cp "${SOURCE_ENTITLEMENTS}" "${ORDER_A_ENTITLEMENTS}"
/usr/libexec/PlistBuddy -c 'Add :alpha bool true' "${ORDER_A_ENTITLEMENTS}" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :omega string value' "${ORDER_A_ENTITLEMENTS}" >/dev/null
cp "${SOURCE_ENTITLEMENTS}" "${ORDER_B_ENTITLEMENTS}"
/usr/libexec/PlistBuddy -c 'Add :omega string value' "${ORDER_B_ENTITLEMENTS}" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :alpha bool true' "${ORDER_B_ENTITLEMENTS}" >/dev/null
[[ "$(devtype_entitlements_hash "${ORDER_A_ENTITLEMENTS}")" == \
   "$(devtype_entitlements_hash "${ORDER_B_ENTITLEMENTS}")" ]]

mkdir -p "${CONTENTS}/MacOS"
plutil -create xml1 "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string DevType' "${CONTENTS}/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string com.devtype.signing-contract-test' "${CONTENTS}/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "${CONTENTS}/Info.plist" >/dev/null
# Use an existing Mach-O rather than a script: codesign does not attach an entitlement blob to a
# script main executable, which would make this test exercise a different signature shape.
cp /usr/bin/true "${EXECUTABLE}"

# Establish the old, internally coherent package state.
codesign --force --sign - --entitlements "${STALE_ENTITLEMENTS}" "${APP}" >/dev/null
devtype_entitlements_hash "${STALE_ENTITLEMENTS}" > "${ENTITLEMENTS_STAMP}"
devtype_entitlements_are_current "${STALE_ENTITLEMENTS}" "${ENTITLEMENTS_STAMP}" "${APP}"

# Change only the entitlement input. The cache gate must now force a re-sign, and the embedded
# stale Automation entitlement must independently fail the post-sign contract.
if devtype_entitlements_are_current "${SOURCE_ENTITLEMENTS}" "${ENTITLEMENTS_STAMP}" "${APP}"; then
  echo "error: entitlement-only change was incorrectly eligible for skip-resign" >&2
  exit 1
fi
if devtype_signed_entitlements_match "${SOURCE_ENTITLEMENTS}" "${APP}"; then
  echo "error: stale Automation entitlement incorrectly matched the empty source contract" >&2
  exit 1
fi

# The default policy is `auto`: Developer ID requires Hardened Runtime. A valid-looking legacy
# signature without the runtime flag must therefore be ineligible for skip-resign.
AUTO_HARDENED="$(devtype_effective_hardened_runtime auto developer-id)"
[[ "${AUTO_HARDENED}" == "1" ]]
if devtype_bundle_hardened_runtime_matches "${APP}" "${AUTO_HARDENED}"; then
  echo "error: Developer ID auto policy accepted a bundle without Hardened Runtime" >&2
  exit 1
fi

# Model the corrective package pass: re-sign with the current empty entitlement set and runtime,
# then publish the stamp only after both postconditions hold.
codesign --force --sign - --options runtime \
  --entitlements "${SOURCE_ENTITLEMENTS}" "${APP}" >/dev/null
devtype_signed_entitlements_match "${SOURCE_ENTITLEMENTS}" "${APP}"
devtype_bundle_hardened_runtime_matches "${APP}" 1
devtype_entitlements_hash "${SOURCE_ENTITLEMENTS}" > "${ENTITLEMENTS_STAMP}"
devtype_entitlements_are_current "${SOURCE_ENTITLEMENTS}" "${ENTITLEMENTS_STAMP}" "${APP}"

if devtype_effective_hardened_runtime invalid developer-id >/dev/null 2>&1; then
  echo "error: invalid Hardened Runtime policy was accepted" >&2
  exit 1
fi

# Verify toolchain metadata keys are preserved in Info.plist
for TOOLCHAIN_KEY in DTXcode DTXcodeBuild DTSDKName DTPlatformVersion; do
  /usr/libexec/PlistBuddy -c "Add :${TOOLCHAIN_KEY} string test-${TOOLCHAIN_KEY}" "${CONTENTS}/Info.plist" >/dev/null
  if [[ "$(/usr/libexec/PlistBuddy -c "Print :${TOOLCHAIN_KEY}" "${CONTENTS}/Info.plist")" != "test-${TOOLCHAIN_KEY}" ]]; then
    echo "error: toolchain key ${TOOLCHAIN_KEY} not preserved in Info.plist" >&2
    exit 1
  fi
done

echo "package signing contract regression passed"
