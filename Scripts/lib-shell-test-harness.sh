#!/usr/bin/env bash
# Shared harness for the Scripts/test-*.sh regression suites that assert only on a
# command's exit status. Source it; do not execute it.
#
# `test-release-preflight.sh` and `test-release-version.sh` carried byte-identical
# `expect_ok`/`expect_fail` pairs differing only in which script they invoked. The other
# three suites assert on the command's *output* as well, so they keep their own expect
# functions and are deliberately not callers — coupling them would mean a harness whose
# arguments mean something different per caller.
#
# Usage:
#   source "${ROOT}/Scripts/lib-shell-test-harness.sh"
#   harness_subject "${ROOT}/Scripts/release-preflight.sh" "${TMP_ROOT}"
#   expect_ok   "label" arg...
#   expect_fail "label" arg...
#   harness_summary "release preflight"      # prints the tally, exits nonzero on failure

PASS=0
FAIL=0
HARNESS_COMMAND=""
HARNESS_SCRATCH=""

# The command under test, and a scratch directory for its captured streams.
harness_subject() {
  HARNESS_COMMAND="$1"
  HARNESS_SCRATCH="$2"
}

expect_ok() {
  local label="$1"
  shift
  if ! "${HARNESS_COMMAND}" "$@" >"${HARNESS_SCRATCH}/stdout" 2>"${HARNESS_SCRATCH}/stderr"; then
    echo "FAIL: ${label} — expected success" >&2
    cat "${HARNESS_SCRATCH}/stderr" >&2
    FAIL=$((FAIL + 1))
  else
    echo "ok: ${label}"
    PASS=$((PASS + 1))
  fi
}

expect_fail() {
  local label="$1"
  shift
  if "${HARNESS_COMMAND}" "$@" >"${HARNESS_SCRATCH}/stdout" 2>"${HARNESS_SCRATCH}/stderr"; then
    echo "FAIL: ${label} — expected nonzero exit" >&2
    FAIL=$((FAIL + 1))
  else
    echo "ok: ${label}"
    PASS=$((PASS + 1))
  fi
}

harness_summary() {
  echo "$1 tests: ${PASS} passed, ${FAIL} failed"
  [[ "${FAIL}" -eq 0 ]]
}
