#!/usr/bin/env bash
# Regression tests for Scripts/verify-release-version.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devtype-release-version.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# shellcheck source=Scripts/lib-shell-test-harness.sh
source "${ROOT}/Scripts/lib-shell-test-harness.sh"
harness_subject "${ROOT}/Scripts/verify-release-version.sh" "${TMP_ROOT}"

expect_ok "matching strict release version accepted" v0.1.3 0.1.3
expect_fail "bundle version drift rejected" v0.1.3 0.1.2
expect_fail "post-tag git-describe version rejected" v0.1.3 0.1.3-1-gabcdef0
expect_fail "non-SemVer release tag rejected" v0.1 0.1.0
expect_fail "missing arguments rejected" v0.1.3

harness_summary "release version"
