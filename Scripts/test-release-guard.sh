#!/usr/bin/env bash
# Regression test for the tagged-release trust boundary in Scripts/release.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="${ROOT}/Scripts/release.sh"
EXPECTED="error: DEVTYPE_SKIP_NOTARIZE=1 is only permitted for untagged local dry runs; tagged release v0.1.3 must be notarized"

if OUTPUT="$(DEVTYPE_RELEASE_TAG=v0.1.3 DEVTYPE_SKIP_NOTARIZE=1 "${RELEASE}" 2>&1)"; then
  echo "FAIL: tagged release accepted an unnotarized dry-run flag" >&2
  exit 1
fi

if ! grep -Fqx "${EXPECTED}" <<<"${OUTPUT}"; then
  echo "FAIL: tagged release failed for the wrong reason" >&2
  printf '%s\n' "${OUTPUT}" >&2
  exit 1
fi

echo "ok: tagged release rejects unnotarized dry-run mode"
