#!/usr/bin/env bash
# Regression tests for Scripts/verify-release-version.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="${ROOT}/Scripts/verify-release-version.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devtype-release-version.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

PASS=0
FAIL=0

expect_ok() {
  local label="$1"
  shift
  if ! "${VERIFY}" "$@" >"${TMP_ROOT}/stdout" 2>"${TMP_ROOT}/stderr"; then
    echo "FAIL: ${label} — expected success" >&2
    cat "${TMP_ROOT}/stderr" >&2
    FAIL=$((FAIL + 1))
  else
    echo "ok: ${label}"
    PASS=$((PASS + 1))
  fi
}

expect_fail() {
  local label="$1"
  shift
  if "${VERIFY}" "$@" >"${TMP_ROOT}/stdout" 2>"${TMP_ROOT}/stderr"; then
    echo "FAIL: ${label} — expected nonzero exit" >&2
    FAIL=$((FAIL + 1))
  else
    echo "ok: ${label}"
    PASS=$((PASS + 1))
  fi
}

expect_ok "matching strict release version accepted" v0.1.3 0.1.3
expect_fail "bundle version drift rejected" v0.1.3 0.1.2
expect_fail "post-tag git-describe version rejected" v0.1.3 0.1.3-1-gabcdef0
expect_fail "non-SemVer release tag rejected" v0.1 0.1.0
expect_fail "missing arguments rejected" v0.1.3

echo "release version tests: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
