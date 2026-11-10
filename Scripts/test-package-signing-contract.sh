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

# package-app.sh states the sign step uses no --deep. That invocation must match,
# and hardened-runtime selection must stay on CODESIGN_EXTRA rather than notarize policy.
PACKAGE_APP="${ROOT}/Scripts/package-app.sh"
sign_invocation="$(
  awk '
    /^[[:space:]]*codesign[[:space:]]/ && index($0, "--sign \"${SIGN_ARG}\"") {
      line = $0
      while (line ~ /\\[[:space:]]*$/) {
        if ((getline next_line) <= 0) {
          break
        }
        sub(/\\[[:space:]]*$/, "", line)
        line = line " " next_line
      }
      print line
      exit
    }
  ' "${PACKAGE_APP}"
)"
if [[ -z "${sign_invocation}" ]]; then
  echo "error: package-app.sh sign invocation was not found" >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])--deep([[:space:]]|$)' <<<"${sign_invocation}"; then
  echo "error: package-app.sh sign invocation passes --deep" >&2
  printf '%s\n' "${sign_invocation}" >&2
  exit 1
fi
for required_token in \
  '--force' \
  '--sign "${SIGN_ARG}"' \
  '--identifier "${BUNDLE_ID}"' \
  '${CODESIGN_EXTRA[@]+"${CODESIGN_EXTRA[@]}"}'
do
  if ! grep -Fq -- "${required_token}" <<<"${sign_invocation}"; then
    echo "error: package-app.sh sign invocation dropped ${required_token}" >&2
    printf '%s\n' "${sign_invocation}" >&2
    exit 1
  fi
done
if ! grep -Fq 'HARDENED_REQUEST="${DEVTYPE_HARDENED_RUNTIME:-auto}"' "${PACKAGE_APP}" \
  || ! grep -Fq 'devtype_effective_hardened_runtime "${HARDENED_REQUEST}" "${SIGN_KIND}"' "${PACKAGE_APP}" \
  || ! grep -Fq 'CODESIGN_EXTRA=(--entitlements "${ENTITLEMENTS}")' "${PACKAGE_APP}" \
  || ! grep -Fq 'if [[ "${HARDENED}" == "1" ]]; then' "${PACKAGE_APP}" \
  || ! grep -Fq 'CODESIGN_EXTRA+=(--options runtime --timestamp)' "${PACKAGE_APP}" \
  || ! grep -Fq 'Sign with stable bundle ID (no --deep; sign the bundle itself).' "${PACKAGE_APP}"; then
  echo "error: hardened-runtime selection or the no --deep statement changed" >&2
  exit 1
fi
# Comment-stripped, bash-accurate logical lines. A trailing unquoted backslash
# is deleted and the next physical line is appended with no extra space — bash
# does not insert the space the sign-line awk above inserts, so `--de\` + `ep`
# is one word, `--deep`.
bash_code_lines() {
  awk '
    function strip_comment(line,    i, n, c, sq, dq, out, prev) {
      n = length(line)
      sq = 0
      dq = 0
      out = ""
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (sq) {
          out = out c
          if (c == sprintf("%c", 39)) {
            sq = 0
          }
          continue
        }
        if (dq) {
          if (c == "\\") {
            out = out c
            if (i < n) {
              i++
              out = out substr(line, i, 1)
            }
            continue
          }
          out = out c
          if (c == "\"") {
            dq = 0
          }
          continue
        }
        if (c == sprintf("%c", 39)) {
          sq = 1
          out = out c
          continue
        }
        if (c == "\"") {
          dq = 1
          out = out c
          continue
        }
        if (c == "#") {
          if (i == 1) {
            break
          }
          prev = substr(line, i - 1, 1)
          if (prev ~ /[[:space:]]/) {
            break
          }
        }
        out = out c
      }
      return out
    }
    BEGIN { pending = "" }
    {
      code = strip_comment($0)
      if (code ~ /\\$/) {
        sub(/\\$/, "", code)
        pending = pending code
        next
      }
      print pending code
      pending = ""
    }
    END {
      if (pending != "") {
        print pending
      }
    }
  ' "$1"
}

code_contains_token() {
  local file="$1"
  local token="$2"
  bash_code_lines "${file}" | grep -F -q -- "${token}"
}

# The checker has to catch the bypasses the space-joining awk misses, and must
# not treat a comment as an invocation.
SPLIT_DEEP="${TEST_ROOT}/split-deep.sh"
QUOTED_DEEP="${TEST_ROOT}/quoted-deep.sh"
ARRAY_DEEP="${TEST_ROOT}/array-deep.sh"
COMMENT_ONLY="${TEST_ROOT}/comment-only.sh"
CONSULTS_NOTARIZE="${TEST_ROOT}/consults-notarize.sh"
printf '%s\n' \
  'codesign --force --sign "${SIGN_ARG}" --de\' \
  'ep --identifier "${BUNDLE_ID}"' \
  > "${SPLIT_DEEP}"
printf '%s\n' "codesign --force --sign \"\${SIGN_ARG}\" '--deep'" > "${QUOTED_DEEP}"
printf '%s\n' 'CODESIGN_EXTRA+=(--deep)' > "${ARRAY_DEEP}"
printf '%s\n' '# --deep and DEVTYPE_SKIP_NOTARIZE mentioned only in a comment' > "${COMMENT_ONLY}"
printf '%s\n' 'skip="${DEVTYPE_SKIP_NOTARIZE:-0}"' > "${CONSULTS_NOTARIZE}"
if ! code_contains_token "${SPLIT_DEEP}" '--deep' \
  || ! code_contains_token "${QUOTED_DEEP}" '--deep' \
  || ! code_contains_token "${ARRAY_DEEP}" '--deep'; then
  echo "error: --deep detector missed a split, quoted, or CODESIGN_EXTRA hiding place" >&2
  exit 1
fi
if code_contains_token "${COMMENT_ONLY}" '--deep' \
  || code_contains_token "${COMMENT_ONLY}" 'DEVTYPE_SKIP_NOTARIZE'; then
  echo "error: comment-only mention was treated as an invocation" >&2
  exit 1
fi
if ! code_contains_token "${CONSULTS_NOTARIZE}" 'DEVTYPE_SKIP_NOTARIZE'; then
  echo "error: detector missed an executable DEVTYPE_SKIP_NOTARIZE use" >&2
  exit 1
fi
if code_contains_token "${PACKAGE_APP}" '--deep'; then
  echo "error: package-app.sh code passes --deep after bash continuation joining" >&2
  bash_code_lines "${PACKAGE_APP}" | grep -n -F -- '--deep' >&2 || true
  exit 1
fi
if code_contains_token "${PACKAGE_APP}" 'DEVTYPE_SKIP_NOTARIZE'; then
  echo "error: package-app.sh must not consult DEVTYPE_SKIP_NOTARIZE" >&2
  exit 1
fi

sign_count=0
sign_logical=""
codesign_count=0
# Stored so the parentheses stay inside a regex and are not parsed as a subshell.
codesign_command_re='(^|[[:space:](;|&])codesign[[:space:]]'
while IFS= read -r logical; do
  if [[ "${logical}" =~ ${codesign_command_re} ]]; then
    codesign_count=$((codesign_count + 1))
    ascii_rest="$(printf '%s' "${logical}" | LC_ALL=C tr -d '\11\40-\176')"
    if [[ -n "${ascii_rest}" ]]; then
      echo "error: codesign invocation is not plain ASCII argv" >&2
      printf '%s\n' "${logical}" >&2
      exit 1
    fi
    if [[ "${logical}" == *"--sign"* ]]; then
      sign_count=$((sign_count + 1))
      sign_logical="${logical}"
    fi
  fi
done < <(bash_code_lines "${PACKAGE_APP}")
if [[ "${codesign_count}" -lt 1 || "${sign_count}" -ne 1 ]]; then
  echo "error: expected one codesign --sign invocation (found sign=${sign_count} codesign=${codesign_count})" >&2
  exit 1
fi
for required_token in \
  '--force' \
  '--sign "${SIGN_ARG}"' \
  '--identifier "${BUNDLE_ID}"' \
  '${CODESIGN_EXTRA[@]+"${CODESIGN_EXTRA[@]}"}' \
  '"${APP_BUNDLE}"'
do
  if [[ "${sign_logical}" != *"${required_token}"* ]]; then
    echo "error: bash-joined sign invocation dropped ${required_token}" >&2
    printf '%s\n' "${sign_logical}" >&2
    exit 1
  fi
done
if [[ "${sign_logical}" == *'--deep'* ]]; then
  echo "error: bash-joined sign invocation passes --deep" >&2
  printf '%s\n' "${sign_logical}" >&2
  exit 1
fi
expansion_names="$(printf '%s\n' "${sign_logical}" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' | sed 's/^\${//' | sort -u)"
expected_names="$(printf '%s\n' APP_BUNDLE BUNDLE_ID CODESIGN_EXTRA SIGN_ARG)"
if [[ "${expansion_names}" != "${expected_names}" ]]; then
  echo "error: sign invocation expands unexpected parameters" >&2
  printf '%s\n' "${expansion_names}" >&2
  exit 1
fi
if printf '%s\n' "${sign_logical}" | grep -Eq '\$[A-Za-z_]'; then
  echo "error: sign invocation has an unbraced parameter expansion" >&2
  printf '%s\n' "${sign_logical}" >&2
  exit 1
fi

# Execute the real CODESIGN_EXTRA block under the system bash that package-app.sh
# calls out: 3.2 with set -u. Empty "${array[@]}" is unbound there; the sign line
# must use the + form, and neither hardened nor unhardened argv may contain --deep.
bash_mm="$(/bin/bash --noprofile --norc -c 'printf "%s.%s\n" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')"
if [[ "${bash_mm}" != "3.2" ]]; then
  echo "error: /bin/bash is ${bash_mm}, want 3.2" >&2
  exit 1
fi
if /bin/bash --noprofile --norc -c 'set -u; CODESIGN_EXTRA=(); printf "%s\n" "${CODESIGN_EXTRA[@]}"' >/dev/null 2>&1; then
  echo "error: /bin/bash set -u accepted an empty \${CODESIGN_EXTRA[@]}; the + guard is untested" >&2
  exit 1
fi

sign_block="$(
  awk '
    index($0, "CODESIGN_EXTRA=(--entitlements") { capture = 1 }
    capture { print }
    capture && index($0, "codesign --force --sign") {
      while ($0 ~ /\\[[:space:]]*$/) {
        if ((getline) <= 0) {
          break
        }
        print
      }
      exit
    }
  ' "${PACKAGE_APP}"
)"
if [[ -z "${sign_block}" || "${sign_block}" != *'codesign --force --sign'* ]]; then
  echo "error: could not extract the CODESIGN_EXTRA sign block" >&2
  exit 1
fi
sign_cmd="$(
  awk '
    index($0, "codesign --force --sign") { capture = 1 }
    capture { print }
    capture {
      if ($0 ~ /\\[[:space:]]*$/) {
        next
      }
      exit
    }
  ' "${PACKAGE_APP}"
)"
if [[ "${sign_cmd}" != *'${CODESIGN_EXTRA[@]+"${CODESIGN_EXTRA[@]}"}'* ]]; then
  echo "error: extracted sign command lost the bash 3.2 empty-array guard" >&2
  printf '%s\n' "${sign_cmd}" >&2
  exit 1
fi

record_sign_argv() {
  local hardened="$1"
  local outfile="$2"
  local mode="$3"
  if ! SIGN_BLOCK="${sign_block}" SIGN_ARGV_OUT="${outfile}" HARDENED_UNDER_TEST="${hardened}" \
    /bin/bash --noprofile --norc -c '
      set -euo pipefail
      codesign() { printf "%s\n" "$@" > "$SIGN_ARGV_OUT"; }
      ENTITLEMENTS="/tmp/devtype-signing-contract-entitlements"
      SIGN_ARG="-"
      SIGN_MODE="ad-hoc"
      BUNDLE_ID="com.devtype.app"
      APP_BUNDLE="/tmp/DevType.app"
      HARDENED="$HARDENED_UNDER_TEST"
      if [[ "$HARDENED_UNDER_TEST" == "empty" ]]; then
        CODESIGN_EXTRA=()
        eval "$SIGN_CMD"
      else
        eval "$SIGN_BLOCK"
      fi
    ' >/dev/null; then
    echo "error: sign block aborted under /bin/bash set -u (mode=${mode})" >&2
    exit 1
  fi
}

assert_argv() {
  local outfile="$1"
  shift
  local expected=("$@")
  local actual=()
  local line
  while IFS= read -r line; do
    actual+=("${line}")
  done < "${outfile}"
  if [[ "${#actual[@]}" -ne "${#expected[@]}" ]]; then
    echo "error: sign argv has ${#actual[@]} words, want ${#expected[@]}" >&2
    printf '  actual: %s\n' "${actual[@]}" >&2
    exit 1
  fi
  local i
  for i in "${!expected[@]}"; do
    if [[ "${actual[$i]}" != "${expected[$i]}" ]]; then
      echo "error: sign argv[${i}]='${actual[$i]}' want '${expected[$i]}'" >&2
      exit 1
    fi
    if [[ "${actual[$i]}" == "--deep" ]]; then
      echo "error: sign argv passes --deep" >&2
      exit 1
    fi
  done
}

UNHARDENED_ARGV="${TEST_ROOT}/argv-unhardened"
HARDENED_ARGV="${TEST_ROOT}/argv-hardened"
EMPTY_ARGV="${TEST_ROOT}/argv-empty"
record_sign_argv 0 "${UNHARDENED_ARGV}" unhardened
record_sign_argv 1 "${HARDENED_ARGV}" hardened
SIGN_CMD="${sign_cmd}" record_sign_argv empty "${EMPTY_ARGV}" empty
assert_argv "${UNHARDENED_ARGV}" \
  --force --sign - --identifier com.devtype.app \
  --entitlements /tmp/devtype-signing-contract-entitlements \
  /tmp/DevType.app
assert_argv "${HARDENED_ARGV}" \
  --force --sign - --identifier com.devtype.app \
  --entitlements /tmp/devtype-signing-contract-entitlements \
  --options runtime --timestamp \
  /tmp/DevType.app
assert_argv "${EMPTY_ARGV}" \
  --force --sign - --identifier com.devtype.app \
  /tmp/DevType.app

if ! grep -Fq 'git -C "${ROOT}" diff --quiet HEAD --' "${PACKAGE_APP}" \
  || ! grep -Fq 'git -C "${ROOT}" describe --tags --always --dirty=+dirty' "${PACKAGE_APP}"; then
  echo "error: version-stamp git diff --quiet / git describe lines changed" >&2
  exit 1
fi
if ! grep -Fq "DEVTYPE_SKIP_NOTARIZE: '1'" "${ROOT}/.github/workflows/release.yml"; then
  echo "error: release workflow no longer sets DEVTYPE_SKIP_NOTARIZE=1" >&2
  exit 1
fi
if ! grep -Fq 'SKIP_NOTARIZE="${DEVTYPE_SKIP_NOTARIZE:-0}"' "${ROOT}/Scripts/release.sh"; then
  echo "error: release.sh no longer reads DEVTYPE_SKIP_NOTARIZE" >&2
  exit 1
fi

echo "package signing contract regression passed"
