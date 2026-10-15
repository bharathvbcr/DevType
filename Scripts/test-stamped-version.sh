#!/usr/bin/env bash
# Regression tests for Scripts/verify-stamped-version.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devtype-stamped-version.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# shellcheck source=Scripts/lib-shell-test-harness.sh
source "${ROOT}/Scripts/lib-shell-test-harness.sh"
harness_subject "${ROOT}/Scripts/verify-stamped-version.sh" "${TMP_ROOT}"

expect_ok "git-describe build accepted" 1.2.1-4-gabc1234 120 0.1.7 2
expect_ok "dirty git-describe build accepted" 1.2.1-4-gabc1234+dirty 120 0.1.7 2
expect_ok "strict release version accepted" 1.3.0 140 0.1.7 2
expect_ok "retired 1.0.0 / 1 pair is not this repo's placeholder" 1.0.0 1 0.1.7 2
expect_fail "source placeholder pair rejected" 0.1.7 2 0.1.7 2
expect_ok "placeholder version with a different build accepted" 0.1.7 3 0.1.7 2
expect_ok "placeholder build with a real version accepted" 1.3.0 2 0.1.7 2
expect_fail "empty version rejected" "" 2 0.1.7 2
expect_fail "missing arguments rejected" 1.3.0 140 0.1.7

harness_summary "stamped version"
