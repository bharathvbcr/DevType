#!/usr/bin/env bash
# Validate the immutable inputs to a tagged release before spending build time.
#
# Usage:
#   Scripts/release-preflight.sh <tag> [repo-root]
#
# The optional repo-root is a test seam; production callers use the checkout that
# contains this script. A release must be a strict vMAJOR.MINOR.PATCH tag at the
# checked-out commit, with a non-empty matching notes file and no tracked or
# untracked worktree changes.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

usage() {
  echo "usage: $0 <vMAJOR.MINOR.PATCH> [repo-root]" >&2
  exit 64
}

[[ $# -eq 1 || $# -eq 2 ]] || usage
TAG="$1"
ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

[[ "${TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "release tag '${TAG}' is not strict SemVer vMAJOR.MINOR.PATCH"
[[ -d "${ROOT}" ]] || die "repository root not found: ${ROOT}"
git -C "${ROOT}" rev-parse --show-toplevel >/dev/null 2>&1 \
  || die "not a Git checkout: ${ROOT}"

HEAD_COMMIT="$(git -C "${ROOT}" rev-parse --verify HEAD 2>/dev/null)" \
  || die "checkout has no commit: ${ROOT}"
TAG_COMMIT="$(git -C "${ROOT}" rev-parse --verify "refs/tags/${TAG}^{commit}" 2>/dev/null)" \
  || die "tag '${TAG}' does not resolve to a commit in ${ROOT}"
[[ "${TAG_COMMIT}" == "${HEAD_COMMIT}" ]] \
  || die "tag '${TAG}' resolves to ${TAG_COMMIT}, but checkout is ${HEAD_COMMIT}"

if [[ -n "$(git -C "${ROOT}" status --porcelain --untracked-files=all)" ]]; then
  die "checkout is not clean; commit or remove changes before releasing '${TAG}'"
fi

# The voice diagnostic trace records what the user dictates. It is defaulted on while a
# defect is being chased, which is fine on a developer's machine and not fine in a build
# handed to anyone else. Fail here rather than trusting it to be remembered.
VOICE_PREFS="${ROOT}/Sources/ExpanderEngine/Voice/VoicePreferences.swift"
if [[ -f "${VOICE_PREFS}" ]] \
  && grep -qE '^\s*public static let voiceTracingDefaultsOn = true' "${VOICE_PREFS}"; then
  die "voiceTracingDefaultsOn is true; set it to false before releasing '${TAG}' (it records dictated text)"
fi

NOTES="${ROOT}/docs/releases/${TAG}.md"
[[ -s "${NOTES}" ]] || die "release notes are missing or empty: ${NOTES}"

echo "release preflight passed: ${TAG} at ${HEAD_COMMIT}"
echo "release notes: ${NOTES}"
