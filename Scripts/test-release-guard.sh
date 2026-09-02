#!/usr/bin/env bash
# Regression test for the tagged-release trust boundary in Scripts/release.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="${ROOT}/Scripts/release.sh"
EXPECTED="error: tagged release v0.1.3 is unnotarized; set DEVTYPE_ALLOW_UNTRUSTED_RELEASE=1 only for an explicitly untrusted publication"

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

EXPECTED_POLICY="error: DEVTYPE_ALLOW_UNTRUSTED_RELEASE=1 requires DEVTYPE_SKIP_NOTARIZE=1"
if OUTPUT="$(DEVTYPE_RELEASE_TAG=not-a-tag DEVTYPE_ALLOW_UNTRUSTED_RELEASE=1 "${RELEASE}" 2>&1)"; then
  echo "FAIL: untrusted-release opt-in accepted a trusted-mode mismatch" >&2
  exit 1
fi
if ! grep -Fqx "${EXPECTED_POLICY}" <<<"${OUTPUT}"; then
  echo "FAIL: trusted-mode mismatch failed for the wrong reason" >&2
  printf '%s\n' "${OUTPUT}" >&2
  exit 1
fi

echo "ok: untrusted-release opt-in requires notarization to be skipped"

EXPECTED_TAG="error: release tag 'not-a-tag' is not strict SemVer vMAJOR.MINOR.PATCH"
if OUTPUT="$(DEVTYPE_RELEASE_TAG=not-a-tag DEVTYPE_SKIP_NOTARIZE=1 DEVTYPE_ALLOW_UNTRUSTED_RELEASE=1 "${RELEASE}" 2>&1)"; then
  echo "FAIL: untrusted-release opt-in did not continue to release validation" >&2
  exit 1
fi
if ! grep -Fqx "${EXPECTED_TAG}" <<<"${OUTPUT}"; then
  echo "FAIL: untrusted-release opt-in failed for the wrong reason" >&2
  printf '%s\n' "${OUTPUT}" >&2
  exit 1
fi

echo "ok: explicit untrusted-release opt-in passes the trust boundary"
