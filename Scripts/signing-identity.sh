#!/usr/bin/env bash
# Resolve which code-signing identity local packaging should use.
#
# Prints exactly one line to stdout:   <kind><TAB><identity>
#   kind ∈ developer-id | apple-development | local | ad-hoc | none
#   identity is the argument for `codesign --sign` ("-" for ad-hoc / none)
# Everything explanatory goes to stderr, so callers can capture stdout safely.
#
# Why a preference order and not one fixed name:
#
#   TCC and the file-based keychain both key off the code signature, and they do
#   not agree on what "stable" means.
#
#   * Ad-hoc pins the designated requirement to the CDHash, so every rebuild
#     drops Accessibility / Input Monitoring / Post Events.
#   * ANY certificate pins the requirement to the certificate instead, so TCC
#     grants survive rebuilds.
#   * Only an APPLE-ISSUED certificate additionally gets keychain items a stable
#     `teamid:` partition. A self-signed certificate falls back to a per-build
#     `cdhash:` partition, which is precisely the breakage KeychainPartitionPolicy
#     has to heal around on every rebuild (SecretStore.swift §8.10).
#
#   So the order is: Apple-issued beats self-signed, self-signed beats ad-hoc.
#
# Apple-issued identities are discovered BY PREFIX, never by a hardcoded common
# name: the CN of an Apple certificate embeds a personal Apple ID and team ID,
# which must not live in a checked-in script. A free Apple ID is enough — the
# certificate Xcode creates under Settings > Accounts > Manage Certificates is an
# "Apple Development" certificate and qualifies here. Developer ID (paid program)
# is preferred when present because it is the only identity that can be notarized.
#
# Env:
#   DEVTYPE_SIGN_IDENTITY            exact identity to use; "-" forces ad-hoc
#   DEVTYPE_LOCAL_SIGN_IDENTITY      CN of the self-signed fallback certificate
#   DEVTYPE_SIGN_EXPIRY_WARN_DAYS    warn this many days before expiry (default 30)
set -euo pipefail

LOCAL_IDENTITY_CN="${DEVTYPE_LOCAL_SIGN_IDENTITY:-DevType Local Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
EXPIRY_WARN_DAYS="${DEVTYPE_SIGN_EXPIRY_WARN_DAYS:-30}"

# Apple-issued prefixes in preference order, "<prefix>|<kind>".
APPLE_IDENTITY_PREFIXES=(
  "Developer ID Application:|developer-id"
  "Apple Development:|apple-development"
  "Mac Developer:|apple-development"
)

note() { echo "$*" >&2; }

classify() {
  case "$1" in
    "Developer ID Application"*) echo developer-id ;;
    "Apple Development"*|"Mac Developer"*|"Apple Distribution"*) echo apple-development ;;
    *) echo local ;;
  esac
}

# Trial-sign a throwaway Mach-O copy: proves codesign can actually reach the
# private key. Certificate presence is not the same thing — an imported cert whose
# key never arrived, or one whose key ACL denies codesign, looks identical to
# `security find-certificate` and fails only at signing time.
identity_usable() {
  local cn="$1" probe rc=0
  probe="$(mktemp -d "${TMPDIR:-/tmp}/devtype-signprobe.XXXXXX")"
  cp /bin/echo "${probe}/probe"
  if ! codesign --force --sign "${cn}" "${probe}/probe" >/dev/null 2>&1; then
    rc=1
  elif ! codesign --verify --strict "${probe}/probe" >/dev/null 2>&1; then
    rc=1
  fi
  rm -rf "${probe}"
  return "${rc}"
}

# First codesigning identity whose name starts with $1. Sorted so that a keychain
# holding several identities resolves the same way on every run.
find_identity_by_prefix() {
  local prefix="$1" list name
  list="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9][0-9]*) [0-9A-Fa-f][0-9A-Fa-f]* "\(.*\)"$/\1/p' \
    | sort || true)"
  [[ -n "${list}" ]] || return 1
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    case "${name}" in
      "${prefix}"*) printf '%s\n' "${name}"; return 0 ;;
    esac
  done <<<"${list}"
  return 1
}

# Apple-issued certificates expire (the free-Apple-ID ones sooner than most), and
# codesign fails outright the moment they do. Warn while there is still time to
# renew rather than letting a release run discover it.
warn_if_expiring() {
  local cn="$1" pem enddate
  command -v openssl >/dev/null 2>&1 || return 0
  pem="$(security find-certificate -c "${cn}" -p "${KEYCHAIN}" 2>/dev/null || true)"
  [[ -n "${pem}" ]] || return 0
  if printf '%s\n' "${pem}" | openssl x509 -noout -checkend "$(( EXPIRY_WARN_DAYS * 86400 ))" >/dev/null 2>&1; then
    return 0
  fi
  enddate="$(printf '%s\n' "${pem}" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2- || true)"
  note "warning: signing certificate '${cn}' expires within ${EXPIRY_WARN_DAYS} days (${enddate:-date unknown})."
  note "         Renew it in Xcode > Settings > Accounts > Manage Certificates."
  note "         The renewed certificate keeps the same common name, so the designated"
  note "         requirement — and your TCC grants — survive the renewal."
}

emit() { printf '%s\t%s\n' "$1" "$2"; }

# 1. Explicit override wins, and fails loudly rather than silently downgrading:
#    a silent fall back to ad-hoc would reset every TCC grant with no explanation.
explicit="${DEVTYPE_SIGN_IDENTITY:-}"
if [[ -n "${explicit}" ]]; then
  if [[ "${explicit}" == "-" ]]; then
    note "==> signing identity: ad-hoc (DEVTYPE_SIGN_IDENTITY=-)"
    emit ad-hoc -
    exit 0
  fi
  if ! identity_usable "${explicit}"; then
    note "error: DEVTYPE_SIGN_IDENTITY='${explicit}' is not usable by codesign."
    note "       Available: security find-identity -v -p codesigning"
    exit 1
  fi
  warn_if_expiring "${explicit}"
  emit "$(classify "${explicit}")" "${explicit}"
  exit 0
fi

# 2. Apple-issued certificate, best kind first.
for entry in "${APPLE_IDENTITY_PREFIXES[@]}"; do
  prefix="${entry%%|*}"
  kind="${entry##*|}"
  if name="$(find_identity_by_prefix "${prefix}")"; then
    if identity_usable "${name}"; then
      warn_if_expiring "${name}"
      emit "${kind}" "${name}"
      exit 0
    fi
    note "warning: '${name}' is in the keychain but codesign cannot use it — skipping."
  fi
done

# 3. Stable self-signed fallback from Scripts/make-signing-cert.sh.
if security find-certificate -c "${LOCAL_IDENTITY_CN}" "${KEYCHAIN}" >/dev/null 2>&1 \
   && identity_usable "${LOCAL_IDENTITY_CN}"; then
  emit local "${LOCAL_IDENTITY_CN}"
  exit 0
fi

# 4. Nothing usable. The caller decides whether to mint the self-signed certificate
#    or drop to ad-hoc; this script never creates keychain state as a side effect.
emit none -
