#!/usr/bin/env bash
# verify-packaged-bundle.sh rejects placeholder versions, broad ATS, and a
# missing toolchain stamp, and accepts an ad-hoc signed bundle that has none
# of those faults.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devtype-verify-bundle.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# shellcheck source=Scripts/lib-shell-test-harness.sh
source "${ROOT}/Scripts/lib-shell-test-harness.sh"
harness_subject "${ROOT}/Scripts/verify-packaged-bundle.sh" "${TMP_ROOT}"

PLACEHOLDER_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${ROOT}/Resources/Info.plist")"
PLACEHOLDER_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${ROOT}/Resources/Info.plist")"

write_plist() {
  local plist="$1"
  local version="$2"
  local build="$3"
  local local_net="$4"
  local broad_ats="$5"
  local toolchain="$6"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.devtype.fixture" "${plist}" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string DevType" "${plist}" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${version}" "${plist}" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${build}" "${plist}" >/dev/null
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool ${local_net}" "${plist}" >/dev/null
  if [[ "${broad_ats}" == "yes" ]]; then
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "${plist}" >/dev/null
  fi
  if [[ "${toolchain}" == "yes" ]]; then
    /usr/libexec/PlistBuddy -c "Add :DTXcode string 2700" "${plist}" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :DTXcodeBuild string 27A1" "${plist}" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :DTSDKName string macosx27.0" "${plist}" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :DTPlatformVersion string 27.0" "${plist}" >/dev/null
  fi
}

make_app() {
  local name="$1"
  local app="${TMP_ROOT}/${name}.app"
  mkdir -p "${app}/Contents/MacOS"
  write_plist "${app}/Contents/Info.plist" "$2" "$3" "$4" "$5" "$6"
  printf '%s' "${app}"
}

expect_fail "missing bundle" "${TMP_ROOT}/no-such.app"
expect_fail "missing argument"

placeholder="$(make_app placeholder "${PLACEHOLDER_VER}" "${PLACEHOLDER_BUILD}" true no yes)"
expect_fail "source placeholder version" "${placeholder}"

offline="$(make_app offline 9.9.9 99 false no yes)"
expect_fail "local networking disabled" "${offline}"

broad="$(make_app broad 9.9.9 99 true yes yes)"
expect_fail "broad ATS exception" "${broad}"

unstamped="$(make_app unstamped 9.9.9 99 true no no)"
expect_fail "missing toolchain keys" "${unstamped}"

good="$(make_app good 9.9.9 99 true no yes)"
echo 'int main(void) { return 0; }' > "${TMP_ROOT}/main.c"
cc -o "${good}/Contents/MacOS/DevType" "${TMP_ROOT}/main.c"
codesign --sign - --force "${good}"
unset DEVTYPE_REQUIRE_FOUNDATION_MODELS
expect_ok "ad-hoc signed bundle" "${good}"
if ! grep -q 'verified stamped version: 9.9.9 (build 99)' "${TMP_ROOT}/stdout"; then
  echo "FAIL: accepted bundle did not report the stamped version" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: stamped version reported"
  PASS=$((PASS + 1))
fi

harness_summary "verify packaged bundle"
