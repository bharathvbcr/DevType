#!/usr/bin/env bash
# The macOS 14 cache restore prefix must not match a macOS 26 cache key.
# runner.os is "macOS" for both images; this suite locks the label-scoped id.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devtype-ci-cache-key.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# shellcheck source=Scripts/lib-shell-test-harness.sh
source "${ROOT}/Scripts/lib-shell-test-harness.sh"
harness_subject "${ROOT}/Scripts/ci-cache-key.sh" "${TMP_ROOT}"

expect_ok "macos-14 id" macos-14 15.4
expect_ok "macos-26 id" macos-26 26.1
expect_ok "patch xcode version" macos-26 26.1.0
expect_fail "unknown runner" macos-15 26.0
expect_fail "runner.os label" macOS 26.0
expect_fail "empty xcode version" macos-14 ""
expect_fail "non-numeric xcode version" macos-14 "15.4;rm"
expect_fail "missing argument" macos-14

id14="$("${ROOT}/Scripts/ci-cache-key.sh" macos-14 15.4)"
id26="$("${ROOT}/Scripts/ci-cache-key.sh" macos-26 26.1)"
if [[ "${id14}" != "devtype-build-macos-14-xcode15.4" ]]; then
  echo "FAIL: macos-14 id was ${id14}" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: macos-14 id spelling"
  PASS=$((PASS + 1))
fi
if [[ "${id26}" != "devtype-build-macos-26-xcode26.1" ]]; then
  echo "FAIL: macos-26 id was ${id26}" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: macos-26 id spelling"
  PASS=$((PASS + 1))
fi

key26="${id26}-abc123"
prefix14="${id14}-"
if [[ "${key26}" == "${prefix14}"* ]]; then
  echo "FAIL: macOS 14 restore prefix matches a macOS 26 key" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: macOS 14 prefix misses macOS 26 keys"
  PASS=$((PASS + 1))
fi
key14="${id14}-abc123"
prefix26="${id26}-"
if [[ "${key14}" == "${prefix26}"* ]]; then
  echo "FAIL: macOS 26 restore prefix matches a macOS 14 key" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: macOS 26 prefix misses macOS 14 keys"
  PASS=$((PASS + 1))
fi

action="${ROOT}/.github/actions/swift-build-cache/action.yml"
if ! grep -q 'Scripts/ci-cache-key.sh' "${action}"; then
  echo "FAIL: swift-build-cache action does not derive its key from ci-cache-key.sh" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: cache action uses ci-cache-key.sh"
  PASS=$((PASS + 1))
fi
if grep -n 'runner\.os' "${action}" "${ROOT}/.github/workflows/ci.yml" "${ROOT}/.github/workflows/release.yml"; then
  echo "FAIL: a workflow still keys the cache on runner.os" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: workflows do not key the cache on runner.os"
  PASS=$((PASS + 1))
fi
if grep -n 'actions/cache@' "${ROOT}/.github/workflows/ci.yml" "${ROOT}/.github/workflows/release.yml"; then
  echo "FAIL: a workflow inlines actions/cache; the key must stay in swift-build-cache" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: workflows do not inline actions/cache"
  PASS=$((PASS + 1))
fi
# shellcheck disable=SC2016 # GitHub Actions expression, not a shell expansion
if ! grep -q 'runner: ${{ matrix.runner }}' "${ROOT}/.github/workflows/ci.yml"; then
  echo "FAIL: test job does not pass the matrix runner into the cache action" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: test job passes the matrix runner"
  PASS=$((PASS + 1))
fi
for wf in ci.yml release.yml; do
  if ! grep -q 'runner: macos-26' "${ROOT}/.github/workflows/${wf}"; then
    echo "FAIL: ${wf} does not pin a macos-26 cache scope" >&2
    FAIL=$((FAIL + 1))
  else
    echo "ok: ${wf} pins a macos-26 cache scope"
    PASS=$((PASS + 1))
  fi
done

harness_summary "ci cache key"
