#!/usr/bin/env bash
# Hermetic regression tests for install-app.sh's validation, rollback, and canonical-path cleanup.
# Every app path is under a temporary directory; this test never reads or writes either real
# Applications directory and never signals a real DevType process.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="${ROOT}/Scripts/install-app.sh"
TEST_ROOT="$(mktemp -d /tmp/devtype-install-test.XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

PASS=0
FAIL=0

pass() {
  echo "  ok   $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL $1" >&2
  FAIL=$((FAIL + 1))
}

make_bundle() {
  local path="$1"
  local identifier="$2"
  local marker="$3"
  local requirement="${4:-identifier \"${identifier}\"}"
  mkdir -p "${path}/Contents/MacOS"
  plutil -create xml1 "${path}/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${identifier}" \
    "${path}/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string DevType' \
    "${path}/Contents/Info.plist" >/dev/null
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' \
    "${path}/Contents/Info.plist" >/dev/null
  cp /usr/bin/true "${path}/Contents/MacOS/DevType"
  printf '%s\n' "${marker}" > "${path}/fixture-marker"
  printf '%s\n' "${requirement}" > "${path}/designated-requirement"
  touch "${path}/signature-valid"
}

make_case() {
  local name="$1"
  CASE_ROOT="${TEST_ROOT}/${name}"
  CASE_REPO="${CASE_ROOT}/repo"
  CASE_SYSTEM_DEST="${CASE_ROOT}/system/DevType.app"
  CASE_USER_DEST="${CASE_ROOT}/user/DevType.app"
  CASE_INSTALLER="${CASE_REPO}/Scripts/install-app.sh"
  CASE_OUTPUT="${CASE_ROOT}/installer.out"
  CASE_ERROR="${CASE_ROOT}/installer.err"
  CASE_TCC_RESET_LOG="${CASE_ROOT}/tcc-reset.log"
  CASE_STUBS="${CASE_ROOT}/stubs"

  mkdir -p "${CASE_REPO}/Scripts" "${CASE_STUBS}" "${CASE_ROOT}/home"
  sed \
    -e "s|^SYSTEM_DEST=.*$|SYSTEM_DEST=\"${CASE_SYSTEM_DEST}\"|" \
    -e "s|^USER_DEST=.*$|USER_DEST=\"${CASE_USER_DEST}\"|" \
    "${INSTALLER}" > "${CASE_INSTALLER}"
  chmod +x "${CASE_INSTALLER}"

  cat > "${CASE_REPO}/Scripts/package-app.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# The harness creates the exact packaged fixture before invoking the installer.
STUB

  cat > "${CASE_REPO}/Scripts/reset-tcc.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${STUB_TCC_RESET_LOG:?}"
printf 'reset\n' >> "${STUB_TCC_RESET_LOG}"
STUB

  cat > "${CASE_STUBS}/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB

  cat > "${CASE_STUBS}/pkill" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

  cat > "${CASE_STUBS}/codesign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
app="${!#}"
if [[ "$1" == "--verify" ]]; then
  if [[ "${STUB_FAIL_INSTALLED_VERIFY:-0}" == "1" ]] && \
     { [[ "${app}" == "${STUB_SYSTEM_DEST}" ]] || \
       [[ "${app}" == "${STUB_USER_DEST}" ]]; }; then
    exit 71
  fi
  [[ -f "${app}/signature-valid" ]]
  exit
fi
if [[ "$1" == "-d" && "${2:-}" == "-r-" ]]; then
  [[ -d "${app}" ]] || exit 1
  [[ -f "${app}/designated-requirement" ]] || exit 1
  printf '# designated => %s\n' "$(<"${app}/designated-requirement")" >&2
  exit
fi
if [[ "$1" == "-dvvv" ]]; then
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "${app}/Contents/Info.plist" 2>/dev/null || true)"
  echo "Identifier=${identifier}" >&2
  echo 'Authority=DevType Test Identity' >&2
  exit
fi
exit 2
STUB

  cat > "${CASE_STUBS}/ditto" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/ditto "$@"
destination="${!#}"
if [[ "${STUB_CORRUPT_STAGE:-0}" == "1" && "${destination}" == *.new.* ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.impostor' \
    "${destination}/Contents/Info.plist" >/dev/null
fi
STUB

  cat > "${CASE_STUBS}/mv" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
source_path="$1"
destination="$2"
if [[ "${STUB_FAIL_INSTALL_MOVES:-0}" == "1" && "${source_path}" == *.new.* ]] && \
   { [[ "${destination}" == "${STUB_SYSTEM_DEST}" ]] || \
     [[ "${destination}" == "${STUB_USER_DEST}" ]]; }; then
  exit 73
fi
exec /bin/mv "$@"
STUB

  chmod +x \
    "${CASE_REPO}/Scripts/package-app.sh" \
    "${CASE_REPO}/Scripts/reset-tcc.sh" \
    "${CASE_STUBS}/pgrep" \
    "${CASE_STUBS}/pkill" \
    "${CASE_STUBS}/codesign" \
    "${CASE_STUBS}/ditto" \
    "${CASE_STUBS}/mv"
}

run_case() {
  local corrupt_stage="${1:-0}"
  local fail_install_moves="${2:-0}"
  local fail_installed_verify="${3:-0}"
  local rc=0
  PATH="${CASE_STUBS}:${PATH}" \
    HOME="${CASE_ROOT}/home" \
    STUB_CORRUPT_STAGE="${corrupt_stage}" \
    STUB_FAIL_INSTALL_MOVES="${fail_install_moves}" \
    STUB_FAIL_INSTALLED_VERIFY="${fail_installed_verify}" \
    STUB_SYSTEM_DEST="${CASE_SYSTEM_DEST}" \
    STUB_USER_DEST="${CASE_USER_DEST}" \
    STUB_TCC_RESET_LOG="${CASE_TCC_RESET_LOG}" \
    "${CASE_INSTALLER}" debug >"${CASE_OUTPUT}" 2>"${CASE_ERROR}" || rc=$?
  return "${rc}"
}

marker_is() {
  local app="$1"
  local expected="$2"
  [[ -f "${app}/fixture-marker" ]] && \
    [[ "$(<"${app}/fixture-marker")" == "${expected}" ]]
}

quarantine_contains() {
  local expected="$1"
  local marker
  while IFS= read -r marker; do
    [[ "$(<"${marker}")" == "${expected}" ]] && return 0
  done < <(find "${CASE_REPO}/build/.quarantine" -type f -name fixture-marker 2>/dev/null)
  return 1
}

tcc_reset_count() {
  if [[ ! -f "${CASE_TCC_RESET_LOG}" ]]; then
    printf '0\n'
    return
  fi
  awk 'END { print NR }' "${CASE_TCC_RESET_LOG}"
}

echo "==> valid install preserves every displaced bundle and removes the canonical duplicate"
make_case valid
make_bundle "${CASE_REPO}/.build/DevType.app" com.devtype.app new-source
make_bundle "${CASE_SYSTEM_DEST}" com.devtype.app old-system
make_bundle "${CASE_USER_DEST}" com.devtype.app old-user
if run_case; then
  if marker_is "${CASE_SYSTEM_DEST}" new-source; then
    pass "verified bundle installed at preferred destination"
  else
    fail "preferred destination does not contain the new bundle"
  fi
  if [[ ! -e "${CASE_USER_DEST}" ]]; then
    pass "alternate same-bundle destination was removed"
  else
    fail "alternate same-bundle destination survived a successful install"
  fi
  if quarantine_contains old-system \
      && quarantine_contains old-user \
      && quarantine_contains new-source; then
    pass "old destination, alternate destination, and package source are all recoverable"
  else
    fail "quarantine did not retain every displaced bundle with a unique path"
  fi
  if ! grep -Fq 'Single identity' "${CASE_OUTPUT}"; then
    pass "installer does not claim it searched the whole machine for duplicates"
  else
    fail "installer printed the false 'Single identity' claim"
  fi
else
  fail "valid installation unexpectedly failed"
fi

echo "==> copied bundle is validated before either destination is displaced"
make_case invalid-stage
make_bundle "${CASE_REPO}/.build/DevType.app" com.devtype.app new-source
make_bundle "${CASE_SYSTEM_DEST}" com.devtype.app old-system
make_bundle "${CASE_USER_DEST}" com.devtype.app old-user
if run_case 1 0; then
  fail "installer accepted a staged bundle with the wrong identifier"
else
  if marker_is "${CASE_SYSTEM_DEST}" old-system \
      && marker_is "${CASE_USER_DEST}" old-user; then
    pass "invalid staging leaves both existing destinations untouched"
  else
    fail "invalid staging displaced an existing destination"
  fi
fi

echo "==> a failed final move rolls each old destination back"
make_case failed-move
make_bundle "${CASE_REPO}/.build/DevType.app" com.devtype.app new-source
make_bundle "${CASE_SYSTEM_DEST}" com.devtype.app old-system
make_bundle "${CASE_USER_DEST}" com.devtype.app old-user
if run_case 0 1; then
  fail "installer reported success when both final moves failed"
else
  if marker_is "${CASE_SYSTEM_DEST}" old-system \
      && marker_is "${CASE_USER_DEST}" old-user; then
    pass "failed moves restore both previous destinations"
  else
    fail "a failed move destroyed a previous destination"
  fi
fi

echo "==> a failed in-place verification restores each old destination"
make_case failed-installed-verification
make_bundle "${CASE_REPO}/.build/DevType.app" com.devtype.app new-source
make_bundle "${CASE_SYSTEM_DEST}" com.devtype.app old-system
make_bundle "${CASE_USER_DEST}" com.devtype.app old-user
if run_case 0 0 1; then
  fail "installer reported success after forced in-place verification failures"
else
  if marker_is "${CASE_SYSTEM_DEST}" old-system \
      && marker_is "${CASE_USER_DEST}" old-user; then
    pass "failed in-place verification restores both previous destinations"
  else
    fail "in-place verification failure destroyed a previous destination"
  fi
fi

echo "==> unrelated alternate bundle is never quarantined by pathname alone"
make_case unrelated-alternate
make_bundle "${CASE_REPO}/.build/DevType.app" com.devtype.app new-source
make_bundle "${CASE_USER_DEST}" com.example.unrelated unrelated-user-app
if run_case; then
  if marker_is "${CASE_SYSTEM_DEST}" new-source \
      && marker_is "${CASE_USER_DEST}" unrelated-user-app; then
    pass "only an alternate with the DevType bundle identifier is quarantined"
  else
    fail "installer removed an unrelated alternate-path app"
  fi
else
  fail "install with an unrelated alternate-path app unexpectedly failed"
fi

echo "==> TCC continuity follows the DevType bundle that was actually replaced"
make_case tcc-selected-fallback
make_bundle \
  "${CASE_REPO}/.build/DevType.app" \
  com.devtype.app \
  new-source \
  'identifier "com.devtype.app" and anchor apple generic'
make_bundle \
  "${CASE_SYSTEM_DEST}" \
  com.example.unrelated \
  unrelated-system-app \
  'identifier "com.devtype.app" and anchor apple generic'
make_bundle \
  "${CASE_USER_DEST}" \
  com.devtype.app \
  old-user \
  'identifier "com.devtype.app" and cdhash H"old-user"'
if run_case; then
  if marker_is "${CASE_SYSTEM_DEST}" unrelated-system-app \
      && marker_is "${CASE_USER_DEST}" new-source; then
    pass "fallback preserves the unrelated system app and replaces the user DevType copy"
  else
    fail "fallback displaced the wrong bundle or failed to install the user copy"
  fi
  if [[ "$(tcc_reset_count)" == "1" ]]; then
    pass "changed requirement resets TCC exactly once"
  else
    fail "changed requirement did not reset TCC exactly once"
  fi
  if grep -Fq "old (${CASE_USER_DEST}): identifier \"com.devtype.app\" and cdhash H\"old-user\"" "${CASE_OUTPUT}" \
      && grep -Fq 'new: identifier "com.devtype.app" and anchor apple generic' "${CASE_OUTPUT}"; then
    pass "TCC comparison reports the replaced user bundle requirement"
  else
    fail "TCC comparison used a requirement from the wrong destination"
  fi
else
  fail "valid fallback installation unexpectedly failed"
fi

echo "==> unchanged requirement does not reset TCC"
make_case tcc-unchanged
make_bundle \
  "${CASE_REPO}/.build/DevType.app" \
  com.devtype.app \
  new-source \
  'identifier "com.devtype.app" and anchor apple generic'
make_bundle \
  "${CASE_SYSTEM_DEST}" \
  com.example.unrelated \
  unrelated-system-app \
  'identifier "com.example.unrelated" and cdhash H"impostor"'
make_bundle \
  "${CASE_USER_DEST}" \
  com.devtype.app \
  old-user \
  'identifier "com.devtype.app" and anchor apple generic'
if run_case; then
  if marker_is "${CASE_SYSTEM_DEST}" unrelated-system-app \
      && marker_is "${CASE_USER_DEST}" new-source \
      && [[ ! -e "${CASE_TCC_RESET_LOG}" ]]; then
    pass "unchanged fallback DevType requirement leaves TCC records intact"
  else
    fail "unrelated system requirement triggered a reset or was displaced"
  fi
else
  fail "unchanged-requirement installation unexpectedly failed"
fi

echo "==> first install without an existing DevType does not reset TCC"
make_case tcc-first-install
make_bundle \
  "${CASE_REPO}/.build/DevType.app" \
  com.devtype.app \
  new-source \
  'identifier "com.devtype.app" and anchor apple generic'
if run_case; then
  if [[ ! -e "${CASE_TCC_RESET_LOG}" ]]; then
    pass "first install has no stale DevType requirement to reset"
  else
    fail "first install reset TCC without a prior DevType bundle"
  fi
else
  fail "first installation unexpectedly failed"
fi

echo "==> unreadable prior DevType requirement resets TCC rather than assuming continuity"
make_case tcc-old-requirement-unreadable
make_bundle \
  "${CASE_REPO}/.build/DevType.app" \
  com.devtype.app \
  new-source \
  'identifier "com.devtype.app" and anchor apple generic'
make_bundle "${CASE_SYSTEM_DEST}" com.devtype.app old-system
rm "${CASE_SYSTEM_DEST}/designated-requirement"
if run_case; then
  if marker_is "${CASE_SYSTEM_DEST}" new-source \
      && [[ "$(tcc_reset_count)" == "1" ]]; then
    pass "unknown prior continuity installs safely and resets TCC exactly once"
  else
    fail "unknown prior continuity was treated as unchanged"
  fi
else
  fail "install with an unreadable prior requirement unexpectedly failed"
fi

echo "==> unreadable packaged requirement fails before an installed bundle is displaced"
make_case tcc-new-requirement-unreadable
make_bundle "${CASE_REPO}/.build/DevType.app" com.devtype.app new-source
rm "${CASE_REPO}/.build/DevType.app/designated-requirement"
make_bundle "${CASE_SYSTEM_DEST}" com.devtype.app old-system
if run_case; then
  fail "installer accepted a package with an unreadable designated requirement"
else
  if marker_is "${CASE_SYSTEM_DEST}" old-system \
      && [[ ! -e "${CASE_TCC_RESET_LOG}" ]]; then
    pass "unknown new identity leaves the installed bundle and TCC records untouched"
  else
    fail "unknown new identity mutated the existing installation"
  fi
fi

echo
if [[ "${FAIL}" -ne 0 ]]; then
  echo "install-app tests: ${FAIL} failed, ${PASS} passed" >&2
  exit 1
fi
echo "install-app tests: ${PASS}/${PASS} passed"
