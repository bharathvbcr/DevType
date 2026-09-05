#!/usr/bin/env bash
# Regression tests for Scripts/release-preflight.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devtype-release-preflight.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# shellcheck source=Scripts/lib-shell-test-harness.sh
source "${ROOT}/Scripts/lib-shell-test-harness.sh"
harness_subject "${ROOT}/Scripts/release-preflight.sh" "${TMP_ROOT}"

REPO="${TMP_ROOT}/repo"
mkdir -p "${REPO}/docs/releases"
git -C "${REPO}" init -q
git -C "${REPO}" config user.email test@example.com
git -C "${REPO}" config user.name "DevType Release Test"
printf '%s\n' '# DevType v0.1.0' > "${REPO}/docs/releases/v0.1.0.md"
git -C "${REPO}" add docs/releases/v0.1.0.md
git -C "${REPO}" commit -q -m 'test: release preflight fixture'
git -C "${REPO}" tag v0.1.0

expect_ok "clean checkout with exact tag and notes" v0.1.0 "${REPO}"
expect_fail "non-SemVer tag rejected" v0.1 "${REPO}"
expect_fail "missing tag rejected" v0.1.1 "${REPO}"

printf '%s\n' 'uncommitted' > "${REPO}/untracked.txt"
expect_fail "untracked worktree change rejected" v0.1.0 "${REPO}"
rm -f "${REPO}/untracked.txt"

printf '%s\n' 'changed' >> "${REPO}/docs/releases/v0.1.0.md"
expect_fail "tracked worktree change rejected" v0.1.0 "${REPO}"
git -C "${REPO}" checkout -- docs/releases/v0.1.0.md

git -C "${REPO}" checkout -q --detach HEAD
git -C "${REPO}" commit --allow-empty -q -m 'test: move checkout away from tag'
expect_fail "checkout not at tag rejected" v0.1.0 "${REPO}"

# The voice diagnostic trace records dictated text. Preflight must refuse a release while
# it is defaulted on, and must not object once it is off.
VOICE_DIR="${REPO}/Sources/ExpanderEngine/Voice"
mkdir -p "${VOICE_DIR}"

printf '%s\n' '    public static let voiceTracingDefaultsOn = true' > "${VOICE_DIR}/VoicePreferences.swift"
git -C "${REPO}" add Sources
git -C "${REPO}" commit -q -m 'test: tracing defaulted on'
git -C "${REPO}" tag -f v0.2.0 >/dev/null 2>&1
printf '%s\n' '# DevType v0.2.0' > "${REPO}/docs/releases/v0.2.0.md"
git -C "${REPO}" add docs/releases/v0.2.0.md
git -C "${REPO}" commit -q --amend --no-edit
git -C "${REPO}" tag -f v0.2.0 >/dev/null 2>&1
expect_fail "release refused while voice tracing defaults on" v0.2.0 "${REPO}"

printf '%s\n' '    public static let voiceTracingDefaultsOn = false' > "${VOICE_DIR}/VoicePreferences.swift"
git -C "${REPO}" add Sources
git -C "${REPO}" commit -q --amend --no-edit
git -C "${REPO}" tag -f v0.2.0 >/dev/null 2>&1
expect_ok "release allowed once voice tracing defaults off" v0.2.0 "${REPO}"

printf '%s' '# DevType v0.3.0' > "${REPO}/docs/releases/v0.3.0.md"
git -C "${REPO}" add docs/releases/v0.3.0.md
git -C "${REPO}" commit -q -m 'test: notes without terminating newline'
git -C "${REPO}" tag v0.3.0
expect_fail "notes without a terminating newline rejected" v0.3.0 "${REPO}"

harness_summary "release preflight"
