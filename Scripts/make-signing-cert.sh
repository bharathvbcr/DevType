#!/usr/bin/env bash
# Create a stable local code-signing identity so TCC grants survive rebuilds.
#
# This is the FALLBACK identity. Scripts/signing-identity.sh prefers an Apple-issued
# certificate when the keychain has one — a free Apple ID is enough (Xcode > Settings >
# Accounts > Manage Certificates > + > Apple Development), and it is strictly better
# here: an Apple-issued signature also gives keychain items a stable `teamid:`
# partition, where a self-signed one falls back to a per-build `cdhash:` partition
# that KeychainPartitionPolicy has to heal after every rebuild (SecretStore.swift §8.10).
# Run this script when you have no Apple ID to sign with.
#
# Ad-hoc signing (codesign --sign -) pins the designated requirement to the CDHash:
#     designated => cdhash H"..."
# Every binary change mints a new CDHash, so Accessibility / Input Monitoring / Post
# Events grants stop matching and silently fail (CGRequest* returns false with no
# prompt, because the Settings row still authorizes the previous CDHash).
#
# A self-signed certificate pins the requirement to the certificate instead:
#     designated => identifier "com.devtype.app" and certificate root = H"..."
# which is stable across rebuilds, so grants persist.
#
# Idempotent: re-running is a no-op once the identity exists.
set -euo pipefail

# DEVTYPE_LOCAL_SIGN_IDENTITY, not DEVTYPE_SIGN_IDENTITY: the latter names the identity
# to *sign with*, which may be an Apple certificate this script must never fabricate.
CN="${DEVTYPE_LOCAL_SIGN_IDENTITY:-DevType Local Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
DAYS="${DEVTYPE_SIGN_DAYS:-3650}"

# A self-signed certificate carrying an Apple-issued common name would collide with
# the real thing in every by-name lookup (find-identity, find-certificate, the
# Authority line codesign prints) while chaining to no Apple root — so refuse.
case "${CN}" in
  "Apple Development"*|"Apple Distribution"*|"Developer ID"*|"Mac Developer"*|"iPhone Developer"*)
    echo "error: refusing to create a self-signed certificate named '${CN}'." >&2
    echo "       That name is reserved for Apple-issued certificates. To sign with a real" >&2
    echo "       one, leave DEVTYPE_LOCAL_SIGN_IDENTITY unset — Scripts/signing-identity.sh" >&2
    echo "       finds Apple certificates automatically." >&2
    exit 1
    ;;
esac

# Trial-sign a throwaway Mach-O copy: proves codesign can reach the private key.
# `security find-identity -p codesigning` reports 0 valid identities for an untrusted
# self-signed root even when signing works, so it is not a usable readiness check.
verify_identity_usable() {
  local probe
  probe="$(mktemp -d "${TMPDIR:-/tmp}/devtype-signprobe.XXXXXX")"
  trap 'rm -rf "${probe}"' RETURN
  cp /bin/echo "${probe}/probe"
  codesign --force --sign "${CN}" "${probe}/probe" >/dev/null 2>&1 || return 1
  codesign --verify --strict "${probe}/probe" >/dev/null 2>&1
}

if security find-certificate -c "${CN}" "${KEYCHAIN}" >/dev/null 2>&1; then
  echo "==> identity already present: ${CN}"
  if verify_identity_usable; then
    echo "    usable by codesign: yes"
    echo "    nothing to do — Scripts/package-app.sh will use it automatically"
    exit 0
  fi
  echo "error: '${CN}' is in the keychain but codesign cannot use it (private key missing?)." >&2
  echo "       Delete it in Keychain Access (login keychain) and re-run this script." >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devtype-cert.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

echo "==> generating self-signed code-signing certificate: ${CN}"
openssl req -x509 -newkey rsa:2048 -sha256 -days "${DAYS}" -nodes \
  -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
  -subj "/CN=${CN}/O=DevType/C=US" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "subjectKeyIdentifier=hash" 2>/dev/null

if ! openssl x509 -in "${WORK}/cert.pem" -noout -text | grep -q "Code Signing"; then
  echo "error: generated certificate lacks the codeSigning extended key usage" >&2
  exit 1
fi

# OpenSSL 3 defaults (AES-256-CBC + SHA-256 MAC) fail Apple's PKCS#12 import with
# "MAC verification failed"; SHA1/3DES is what the Security framework accepts.
echo "==> exporting PKCS#12"
P12_PASS="$(openssl rand -hex 16)"
if ! openssl pkcs12 -export -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
      -out "${WORK}/identity.p12" -name "${CN}" \
      -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg SHA1 \
      -passout "pass:${P12_PASS}" 2>/dev/null; then
  # LibreSSL already defaults to Apple-compatible algorithms and rejects the flags above.
  openssl pkcs12 -export -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -out "${WORK}/identity.p12" -name "${CN}" -passout "pass:${P12_PASS}"
fi

echo "==> importing into login keychain"
security import "${WORK}/identity.p12" -k "${KEYCHAIN}" -P "${P12_PASS}" \
  -T /usr/bin/codesign -T /usr/bin/security

if ! verify_identity_usable; then
  echo "error: imported '${CN}' but codesign could not use it." >&2
  echo "       If macOS showed a keychain access prompt, re-run and choose Always Allow." >&2
  exit 1
fi

CERT_SHA1="$(security find-certificate -c "${CN}" -Z "${KEYCHAIN}" 2>/dev/null \
  | awk -F': ' '/^SHA-1 hash/{print $2; exit}')"

echo "==> done: ${CN}"
echo "    keychain: ${KEYCHAIN}"
echo "    cert SHA-1: ${CERT_SHA1:-unknown}"
echo "    valid for: ${DAYS} days"
echo
echo "    Next: ./Scripts/install-app.sh"
echo "    The first install after switching identity changes the CDHash one last time,"
echo "    so reset stale grants once:  ./Scripts/reset-tcc.sh"
echo "    After that, grants persist across rebuilds."
