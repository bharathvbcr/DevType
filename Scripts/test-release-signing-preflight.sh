#!/usr/bin/env bash
# Regression tests for the distribution signing gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="${ROOT}/Scripts/release-signing-preflight.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/devtype-release-signing.XXXXXX")"
trap 'rm -rf "${FIXTURE}"' EXIT

STUB="${FIXTURE}/resolver"
cat > "${STUB}" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${STUB_RC:-0}" == "0" ]] || exit "${STUB_RC}"
printf '%s' "${STUB_OUTPUT:-}"
STUB
chmod +x "${STUB}"

PASS=0
FAIL=0

expect_ok() {
  local label="$1" expected="$2" output rc=0
  output="$(DEVTYPE_SIGNING_RESOLVER="${STUB}" "${PREFLIGHT}" 2>"${FIXTURE}/stderr")" || rc=$?
  if [[ "${rc}" -eq 0 && "${output}" == "${expected}" ]]; then
    echo "ok: ${label}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${label} — rc=${rc} output=${output}" >&2
    cat "${FIXTURE}/stderr" >&2
    FAIL=$((FAIL + 1))
  fi
}

expect_fail() {
  local label="$1" rc=0
  DEVTYPE_SIGNING_RESOLVER="${STUB}" "${PREFLIGHT}" >"${FIXTURE}/stdout" 2>"${FIXTURE}/stderr" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "ok: ${label}"
    PASS=$((PASS + 1))
  else
    echo "FAIL: ${label} — expected nonzero exit" >&2
    FAIL=$((FAIL + 1))
  fi
}

export STUB_RC=0
export STUB_OUTPUT=$'developer-id\tDeveloper ID Application: Example (TEAM123456)'
expect_ok "Developer ID is accepted" "Developer ID Application: Example (TEAM123456)"

export STUB_OUTPUT=$'apple-development\tApple Development: Example (TEAM123456)'
expect_fail "Apple Development cannot ship a notarized release"

export STUB_OUTPUT=$'local\tDevType Local Signing'
expect_fail "self-signed identity cannot ship a notarized release"

export STUB_OUTPUT=$'ad-hoc\t-'
expect_fail "ad-hoc identity cannot ship a notarized release"

export STUB_OUTPUT=$'none\t-'
expect_fail "missing identity cannot silently downgrade the release"

export STUB_OUTPUT=$'developer-id\tApple Development: Misclassified (TEAM123456)'
expect_fail "inconsistent developer-id classification is rejected"

export STUB_OUTPUT=$'developer-id\tDeveloper ID Application: One (TEAM123456)\ndeveloper-id\tDeveloper ID Application: Two (TEAM123456)'
expect_fail "multiple resolver results are rejected"

export STUB_OUTPUT='malformed'
expect_fail "malformed resolver output is rejected"

export STUB_OUTPUT=''
export STUB_RC=17
expect_fail "resolver failure is propagated"

echo "release signing preflight tests: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
