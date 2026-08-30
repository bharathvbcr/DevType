#!/usr/bin/env bash
# Regression tests for the published GitHub release asset inventory gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFIER="${ROOT}/Scripts/verify-release-asset-list.sh"

PASS=0
FAIL=0

expect_fail() {
  local label="$1"
  local expected="$2"
  local assets="$3"
  if printf '%s' "${assets}" | "${VERIFIER}" "${expected}" >/dev/null 2>&1; then
    echo "FAIL: ${label} — verifier exited 0, expected nonzero" >&2
    FAIL=$((FAIL + 1))
  else
    PASS=$((PASS + 1))
  fi
}

expect_ok() {
  local label="$1"
  local expected="$2"
  local assets="$3"
  local out
  if ! out="$(printf '%s' "${assets}" | "${VERIFIER}" "${expected}" 2>&1)"; then
    echo "FAIL: ${label} — verifier exited nonzero: ${out}" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  [[ "${out}" == "verified published asset inventory: ${expected}" ]] || {
    echo "FAIL: ${label} — unexpected output: ${out}" >&2
    FAIL=$((FAIL + 1))
    return
  }
  PASS=$((PASS + 1))
}

expect_fail "empty release rejected" "DevType-0.1.2.dmg" ""
expect_ok "single expected DMG accepted" "DevType-0.1.2.dmg" $'DevType-0.1.2.dmg\n'
expect_fail "wrong-version DMG rejected" "DevType-0.1.2.dmg" $'DevType-0.1.1.dmg\n'
expect_fail "stale DMG beside expected rejected" "DevType-0.1.2.dmg" $'DevType-0.1.1.dmg\nDevType-0.1.2.dmg\n'
expect_fail "unexpected side asset rejected" "DevType-0.1.2.dmg" $'DevType-0.1.2.dmg\nchecksums.txt\n'
expect_fail "blank asset name rejected" "DevType-0.1.2.dmg" $'DevType-0.1.2.dmg\n\n'
expect_fail "malformed expected name rejected" "DevType-0.1.2-rc1.dmg" $'DevType-0.1.2-rc1.dmg\n'

echo "release-asset-list tests: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
