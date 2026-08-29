#!/usr/bin/env bash
# Require a usable Developer ID Application identity for a notarized release.
#
# Local packaging may legitimately use Apple Development, a self-signed certificate,
# or ad-hoc signing. A distribution build may not: only Developer ID Application can be
# notarized. Keep this decision separate from release.sh so it is adversarially testable
# without compiling the app or touching a real keychain.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="${DEVTYPE_SIGNING_RESOLVER:-${ROOT}/Scripts/signing-identity.sh}"

die() { echo "error: $*" >&2; exit 1; }

[[ -x "${RESOLVER}" ]] || die "signing identity resolver is not executable: ${RESOLVER}"

RESOLVED="$("${RESOLVER}")" \
  || die "could not resolve a usable signing identity"

case "${RESOLVED}" in
  *$'\n'*) die "signing identity resolver returned more than one result" ;;
esac
[[ "${RESOLVED}" == *$'\t'* ]] \
  || die "signing identity resolver returned malformed output"

KIND="${RESOLVED%%$'\t'*}"
IDENTITY="${RESOLVED#*$'\t'}"

[[ "${KIND}" == "developer-id" ]] \
  || die "notarized distribution requires Developer ID Application signing (resolved ${KIND}); set DEVTYPE_SKIP_NOTARIZE=1 only for an intentional local/untrusted artifact"
[[ "${IDENTITY}" == "Developer ID Application:"* ]] \
  || die "resolver classified a non-Developer-ID identity as developer-id: ${IDENTITY}"

printf '%s\n' "${IDENTITY}"
