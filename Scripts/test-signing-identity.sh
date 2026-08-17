#!/usr/bin/env bash
# Tests for Scripts/signing-identity.sh.
#
# The resolver decides which certificate every local build is signed with, and a
# wrong answer is expensive but silent: dropping from an Apple-issued certificate
# to the self-signed one re-introduces per-build `cdhash:` keychain partitions,
# and dropping to ad-hoc additionally resets every TCC grant. Neither shows up as
# a build failure, so the preference order is pinned here.
#
# `security` and `codesign` are stubbed on PATH: the real keychain differs per
# machine, and a test that only passes on a machine that happens to hold an Apple
# certificate would verify nothing on any other.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="${ROOT}/Scripts/signing-identity.sh"

STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devtype-signtest.XXXXXX")"
trap 'rm -rf "${STUB_DIR}"' EXIT

# --- stubs ------------------------------------------------------------------
# STUB_IDENTITIES: newline-separated identity names `find-identity` reports.
# STUB_CERTS:      newline-separated CNs `find-certificate` finds.
# STUB_UNUSABLE:   newline-separated identity names `codesign --sign` rejects.
cat > "${STUB_DIR}/security" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "$1" in
  find-identity)
    n=0
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      n=$((n + 1))
      printf '  %d) 0000000000000000000000000000000000000000 "%s"\n' "${n}" "${name}"
    done <<< "${STUB_IDENTITIES:-}"
    printf '     %d valid identities found\n' "${n}"
    ;;
  find-certificate)
    # Args: find-certificate -c <cn> [-p] [keychain]
    want=""; pem=0
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -c) want="$2"; shift 2 ;;
        -p) pem=1; shift ;;
        *) shift ;;
      esac
    done
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      if [[ "${name}" == "${want}" ]]; then
        # Deliberately print no PEM: the expiry probe must degrade to a no-op
        # rather than fail when it cannot read the certificate.
        [[ "${pem}" -eq 1 ]] || echo "cert ${want}"
        exit 0
      fi
    done <<< "${STUB_CERTS:-}"
    exit 1
    ;;
  *) exit 1 ;;
esac
STUB

cat > "${STUB_DIR}/codesign" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
identity=""
prev=""
for arg in "$@"; do
  [[ "${prev}" == "--sign" ]] && identity="${arg}"
  prev="${arg}"
done
if [[ -n "${identity}" ]]; then
  # Present in the keychain but explicitly rejected (private key gone / ACL denies).
  while IFS= read -r bad; do
    [[ -n "${bad}" ]] || continue
    [[ "${identity}" == "${bad}" ]] && exit 1
  done <<< "${STUB_UNUSABLE:-}"
  # Not in the keychain at all: real codesign fails, so the stub must too.
  known=0
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    [[ "${identity}" == "${name}" ]] && known=1
  done <<< "${STUB_CERTS:-}
${STUB_IDENTITIES:-}"
  [[ "${known}" -eq 1 ]] || exit 1
fi
exit 0
STUB

chmod +x "${STUB_DIR}/security" "${STUB_DIR}/codesign"
export PATH="${STUB_DIR}:${PATH}"

# --- harness ----------------------------------------------------------------
FAILURES=0
CASES=0

# expect <description> <expected "kind<TAB>identity"> -- runs the resolver with the
# STUB_* / DEVTYPE_* variables already exported by the caller.
expect() {
  local desc="$1" want="$2" got rc=0
  CASES=$((CASES + 1))
  got="$("${RESOLVER}" 2>/dev/null)" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "  FAIL ${desc}: resolver exited ${rc}" >&2
    FAILURES=$((FAILURES + 1))
    return
  fi
  if [[ "${got}" != "${want}" ]]; then
    echo "  FAIL ${desc}" >&2
    echo "       want: $(printf '%q' "${want}")" >&2
    echo "       got:  $(printf '%q' "${got}")" >&2
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "  ok   ${desc}"
}

expect_failure() {
  local desc="$1" rc=0
  CASES=$((CASES + 1))
  "${RESOLVER}" >/dev/null 2>&1 || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    echo "  FAIL ${desc}: expected non-zero exit" >&2
    FAILURES=$((FAILURES + 1))
    return
  fi
  echo "  ok   ${desc}"
}

reset_env() {
  export STUB_IDENTITIES="" STUB_CERTS="" STUB_UNUSABLE=""
  unset DEVTYPE_SIGN_IDENTITY DEVTYPE_LOCAL_SIGN_IDENTITY || true
}

TAB=$'\t'
LOCAL_CN="DevType Local Signing"
APPLE_CN="Apple Development: dev@example.com (ABCDE12345)"
DEVID_CN="Developer ID Application: Example (TEAM123456)"

echo "==> Scripts/signing-identity.sh"

# The regression this exists for: with BOTH an Apple certificate and the
# self-signed fallback present, packaging used to hardcode the self-signed one.
reset_env
STUB_IDENTITIES="${APPLE_CN}"
STUB_CERTS="${APPLE_CN}
${LOCAL_CN}"
expect "Apple Development beats the self-signed fallback" "apple-development${TAB}${APPLE_CN}"

reset_env
STUB_IDENTITIES="${DEVID_CN}
${APPLE_CN}"
STUB_CERTS="${DEVID_CN}
${APPLE_CN}"
expect "Developer ID beats Apple Development" "developer-id${TAB}${DEVID_CN}"

reset_env
STUB_CERTS="${LOCAL_CN}"
expect "self-signed fallback when no Apple certificate exists" "local${TAB}${LOCAL_CN}"

reset_env
expect "reports none when nothing is usable" "none${TAB}-"

# A certificate whose private key is gone still appears in find-identity; signing
# with it fails. Skip it rather than hard-failing the build.
reset_env
STUB_IDENTITIES="${APPLE_CN}"
STUB_CERTS="${APPLE_CN}
${LOCAL_CN}"
STUB_UNUSABLE="${APPLE_CN}"
expect "skips an Apple certificate codesign cannot use" "local${TAB}${LOCAL_CN}"

reset_env
STUB_CERTS="${LOCAL_CN}"
STUB_UNUSABLE="${LOCAL_CN}"
expect "reports none when the fallback certificate is unusable" "none${TAB}-"

reset_env
STUB_IDENTITIES="${APPLE_CN}"
STUB_CERTS="${APPLE_CN}"
export DEVTYPE_SIGN_IDENTITY="-"
expect "DEVTYPE_SIGN_IDENTITY=- forces ad-hoc" "ad-hoc${TAB}-"

reset_env
STUB_IDENTITIES="${DEVID_CN}
${APPLE_CN}"
STUB_CERTS="${DEVID_CN}
${APPLE_CN}"
export DEVTYPE_SIGN_IDENTITY="${APPLE_CN}"
expect "explicit override outranks a better auto-detected identity" "apple-development${TAB}${APPLE_CN}"

# Must not silently downgrade: a quiet fall back to ad-hoc would reset TCC grants
# with nothing in the output to explain why.
reset_env
STUB_CERTS="${LOCAL_CN}"
export DEVTYPE_SIGN_IDENTITY="Apple Development: absent@example.com (ZZZZZ00000)"
expect_failure "unusable explicit override fails instead of downgrading"

reset_env
export DEVTYPE_LOCAL_SIGN_IDENTITY="Custom Local Cert"
STUB_CERTS="Custom Local Cert"
expect "DEVTYPE_LOCAL_SIGN_IDENTITY renames the fallback" "local${TAB}Custom Local Cert"

# --- make-signing-cert.sh must never fabricate an Apple-named certificate -----
echo "==> Scripts/make-signing-cert.sh"
CASES=$((CASES + 1))
rc=0
env -u DEVTYPE_SIGN_IDENTITY \
    DEVTYPE_LOCAL_SIGN_IDENTITY="Apple Development: spoof@example.com (ZZZZZ00000)" \
    "${ROOT}/Scripts/make-signing-cert.sh" >/dev/null 2>&1 || rc=$?
if [[ "${rc}" -eq 0 ]]; then
  echo "  FAIL refuses to self-sign an Apple-reserved common name" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  ok   refuses to self-sign an Apple-reserved common name"
fi

echo
if [[ "${FAILURES}" -ne 0 ]]; then
  echo "signing identity tests: ${FAILURES}/${CASES} FAILED" >&2
  exit 1
fi
echo "signing identity tests: ${CASES}/${CASES} passed"
