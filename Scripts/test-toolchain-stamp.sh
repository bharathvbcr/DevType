#!/usr/bin/env bash
# Regression tests for Scripts/toolchain-stamp.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devtype-toolchain-stamp.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# shellcheck source=Scripts/lib-shell-test-harness.sh
source "${ROOT}/Scripts/lib-shell-test-harness.sh"
harness_subject "${ROOT}/Scripts/toolchain-stamp.sh" "${TMP_ROOT}"

expect_fail "empty stamp rejected" DTXcode ""
expect_fail "unknown stamp rejected" DTXcode unknown
expect_fail "unreadable sdk rejected" DTSDKName macosxunknown
expect_ok "xcode stamp accepted" DTXcode 2700
expect_ok "xcode build id accepted" DTXcodeBuild 27A266a
expect_ok "sdk name accepted" DTSDKName macosx27.0
expect_ok "platform version accepted" DTPlatformVersion 27.0
expect_fail "missing value rejected" DTXcode

harness_summary "toolchain stamp"
