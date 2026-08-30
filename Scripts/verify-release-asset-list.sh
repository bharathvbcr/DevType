#!/usr/bin/env bash
# Verify that a published GitHub release contains exactly the intended DMG.
# Asset names are read one per line from stdin (the shape emitted by gh --jq).
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

if [[ $# -ne 1 ]]; then
  echo "usage: $0 DevType-MAJOR.MINOR.PATCH.dmg" >&2
  exit 64
fi

EXPECTED="$1"
[[ "${EXPECTED}" =~ ^DevType-[0-9]+\.[0-9]+\.[0-9]+\.dmg$ ]] \
  || die "expected asset '${EXPECTED}' is not a strict DevType release DMG name"

ASSETS=()
while IFS= read -r asset; do
  ASSETS+=("${asset}")
done

if [[ ${#ASSETS[@]} -eq 0 ]]; then
  die "published release has no assets; expected ${EXPECTED}"
fi

if [[ ${#ASSETS[@]} -ne 1 ]]; then
  {
    echo "error: published release must contain exactly one asset (${EXPECTED}); found ${#ASSETS[@]}:"
    printf '  %q\n' "${ASSETS[@]}"
  } >&2
  exit 1
fi

[[ "${ASSETS[0]}" == "${EXPECTED}" ]] \
  || die "published asset '${ASSETS[0]}' does not match ${EXPECTED}"

echo "verified published asset inventory: ${EXPECTED}"
