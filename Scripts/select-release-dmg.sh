#!/usr/bin/env bash
# §7.5 — Pick the one release DMG and pin it to the version being released.
#
# The release workflow used to do `find dist -name "DevType-*.dmg" | head -n 1`,
# which silently uploads an arbitrary winner when several DMGs exist and never
# notices when the built name disagrees with the pushed tag (e.g. a tag placed
# behind newer tags makes git describe stamp "0.0.9-3-gabc" into the filename).
# Both shapes ship a mislabeled artifact with exit 0. This script is the single
# owner of that decision: zero or many candidates is fatal, and the surviving
# candidate must be named exactly DevType-<expected-version>.dmg.
#
# Usage:
#   Scripts/select-release-dmg.sh <dist-dir> <expected-version>
#
# Output (for $GITHUB_OUTPUT):
#   dmg_path=<absolute path>
#   dmg_name=<basename>
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

usage() {
  echo "usage: $0 <dist-dir> <expected-version>" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage
DIST="$1"
EXPECTED_VERSION="$2"

[[ "${EXPECTED_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "expected version '${EXPECTED_VERSION}' is not strict SemVer MAJOR.MINOR.PATCH"
[[ -d "${DIST}" ]] || die "dist directory not found: ${DIST}"

# Recursive like the original locate step; exactly-one is enforced below.
# bash 3.2 (system /bin/bash) has no mapfile — collect via read loop.
CANDIDATES=()
while IFS= read -r candidate; do
  CANDIDATES+=("${candidate}")
done < <(find "${DIST}" -type f -name "DevType-*.dmg")

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  die "no DMG found under ${DIST}"
fi

if [[ ${#CANDIDATES[@]} -gt 1 ]]; then
  {
    echo "error: expected exactly one DMG under ${DIST}, found ${#CANDIDATES[@]}:"
    printf '  %s\n' "${CANDIDATES[@]}"
  } >&2
  exit 1
fi

DMG_PATH="${CANDIDATES[0]}"
DMG_NAME="$(basename "${DMG_PATH}")"
EXPECTED_NAME="DevType-${EXPECTED_VERSION}.dmg"

if [[ "${DMG_NAME}" != "${EXPECTED_NAME}" ]]; then
  die "built DMG '${DMG_NAME}' does not match released version '${EXPECTED_VERSION}' (${EXPECTED_NAME}); refusing to publish a mislabeled artifact"
fi

[[ -s "${DMG_PATH}" ]] || die "DMG is empty: ${DMG_PATH}"

DMG_PATH="$(cd "$(dirname "${DMG_PATH}")" && pwd)/${DMG_NAME}"
echo "dmg_path=${DMG_PATH}"
echo "dmg_name=${DMG_NAME}"
