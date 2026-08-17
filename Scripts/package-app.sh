#!/usr/bin/env bash
# Build DevType and assemble a stable .app bundle for TCC identity.
# Output: .build/DevType.app  (bundle ID: com.devtype.app)
#
# Stability: TCC keys off the designated requirement. Ad-hoc signing pins it to the
# CDHash, so any binary change resets Accessibility / Input Monitoring / Post Events.
# Signing with the stable certificate from Scripts/make-signing-cert.sh pins it to the
# certificate instead, and grants survive rebuilds. When the SPM binary is unchanged
# this script still skips wipe + resign so the CDHash stays put either way.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-debug}"
# Prefer SPM triple subdirectory when present (deterministic); fall back to flat path.
TRIPLE=""
if command -v python3 >/dev/null 2>&1; then
  TRIPLE="$(swift -print-target-info 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["target"]["triple"])' 2>/dev/null || true)"
fi
if [[ -n "${TRIPLE}" && -d ".build/${TRIPLE}/${CONFIGURATION}" ]]; then
  PRODUCT_DIR=".build/${TRIPLE}/${CONFIGURATION}"
else
  PRODUCT_DIR=".build/${CONFIGURATION}"
fi
APP_BUNDLE=".build/DevType.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RESOURCES_DIR="${CONTENTS}/Resources"
BUNDLE_ID="com.devtype.app"
PLIST_SRC="${ROOT}/Resources/Info.plist"
# Sidecar: sha256 of the SPM binary last successfully packaged (not the signed Mach-O inside the .app).
SOURCE_HASH_STAMP="${APP_BUNDLE}.source-sha256"
STALE_APP="${ROOT}/build/DevType.app"
STALE_SUFFIX="${ROOT}/build/DevType.app.stale"

# Signing identity. Scripts/signing-identity.sh is the single owner of the choice
# (an Apple-issued certificate when one exists, else the stable self-signed one,
# else ad-hoc) so packaging, release, and the tests cannot drift apart on what
# "the identity" means. It never creates keychain state; minting the self-signed
# fallback stays here, where DEVTYPE_SKIP_AUTO_CERT can suppress it.
SIGN_KIND=""
SIGN_ARG=""
resolve_signing_identity() {
  local line
  line="$("${ROOT}/Scripts/signing-identity.sh")" || return 1
  SIGN_KIND="${line%%$'\t'*}"
  SIGN_ARG="${line#*$'\t'}"
  [[ -n "${SIGN_KIND}" && -n "${SIGN_ARG}" ]]
}

if ! resolve_signing_identity; then
  echo "error: could not resolve a signing identity" >&2
  exit 1
fi

if [[ "${SIGN_KIND}" == "none" ]]; then
  if [[ "${DEVTYPE_SKIP_AUTO_CERT:-0}" == "1" ]]; then
    SIGN_KIND="ad-hoc"
    SIGN_ARG="-"
  else
    echo "==> no usable signing identity — running Scripts/make-signing-cert.sh"
    if ! "${ROOT}/Scripts/make-signing-cert.sh" \
       || ! resolve_signing_identity \
       || [[ "${SIGN_KIND}" == "none" ]]; then
      echo "warning: could not create signing identity; falling back to ad-hoc" >&2
      SIGN_KIND="ad-hoc"
      SIGN_ARG="-"
    fi
  fi
fi

if [[ "${SIGN_KIND}" == "ad-hoc" ]]; then
  SIGN_MODE="ad-hoc"
else
  SIGN_MODE="certificate"
fi
# Authority line to match when deciding whether an existing bundle can keep its
# signature (see bundle_signing_mode_matches).
SIGN_IDENTITY="${SIGN_ARG}"

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# --- §7.6: version stamping -------------------------------------------------
# Resources/Info.plist carries placeholders; the real version is derived from git
# so a DiagnosticReport from the field maps back to an exact commit. Falls back to
# the source plist values in a tarball / no-git checkout.
#
# CFBundleShortVersionString: nearest tag, e.g. "0.2.1" (or "0.2.1-4-gabc1234" when
#   ahead of the tag, "+dirty" appended for an unclean tree).
# CFBundleVersion: monotonic commit count, which is what macOS / Sparkle compare.
compute_version() {
  local tag desc count dirty
  if ! git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    return 1
  fi
  if ! git -C "${ROOT}" rev-parse HEAD >/dev/null 2>&1; then
    return 1   # repo exists but has no commits yet
  fi
  count="$(git -C "${ROOT}" rev-list --count HEAD 2>/dev/null || echo 0)"
  dirty=""
  git -C "${ROOT}" diff --quiet HEAD -- 2>/dev/null || dirty="+dirty"
  if desc="$(git -C "${ROOT}" describe --tags --always --dirty=+dirty 2>/dev/null)"; then
    tag="${desc#v}"
  else
    tag="0.0.0-$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)${dirty}"
  fi
  VERSION_SHORT="${tag}"
  VERSION_BUILD="${count}"
  return 0
}

VERSION_SHORT=""
VERSION_BUILD=""
if compute_version; then
  echo "==> version ${VERSION_SHORT} (build ${VERSION_BUILD})"
else
  VERSION_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST_SRC}" 2>/dev/null || echo 0.0.0)"
  VERSION_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST_SRC}" 2>/dev/null || echo 1)"
  echo "==> version ${VERSION_SHORT} (build ${VERSION_BUILD}) — no git metadata, using Info.plist values"
fi

# Staged plist = source plist + stamped version. Everything downstream compares and
# copies THIS, not PLIST_SRC, so the existing CDHash-preservation caching still works:
# identical version + identical source plist => byte-identical staged plist => no resign.
PLIST_STAGED="$(mktemp -t devtype-info-plist)"
trap 'rm -f "${PLIST_STAGED}"' EXIT
cp "${PLIST_SRC}" "${PLIST_STAGED}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION_SHORT}" "${PLIST_STAGED}" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION_BUILD}" "${PLIST_STAGED}" >/dev/null

# §7.5: signing assets live in Resources/ for discoverability but must not be copied
# into the shipped bundle.
RESOURCE_EXCLUDES=("Info.plist" "DevType.entitlements")
is_excluded_resource() {
  local name="$1" ex
  for ex in "${RESOURCE_EXCLUDES[@]}"; do
    [[ "${name}" == "${ex}" ]] && return 0
  done
  return 1
}
ENTITLEMENTS="${ROOT}/Resources/DevType.entitlements"

# codesign prints several lines; piping it into a consumer that exits early (awk exit,
# head) SIGPIPEs codesign, and under `set -o pipefail` that non-zero status propagates
# out of the assignment and `set -e` kills the script. Capture once, parse from a
# here-string so the producer is never a live process.
codesign_info() {
  codesign -dvvv "$1" 2>&1 || true
}

file_size() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null
}

bundle_codesign_ok() {
  local app="$1"
  [[ -d "${app}" ]] || return 1
  codesign --verify --strict "${app}" >/dev/null 2>&1 || return 1
  local signed_id
  signed_id="$(awk -F= '/^Identifier=/{print $2; exit}' <<<"$(codesign_info "${app}")")"
  [[ "${signed_id}" == "${BUNDLE_ID}" ]] || return 1
  local packaged_id
  packaged_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app}/Contents/Info.plist" 2>/dev/null || true)"
  [[ "${packaged_id}" == "${BUNDLE_ID}" ]] || return 1
  bundle_signing_mode_matches "${app}" || return 1
  return 0
}

# A bundle signed in the other mode must be resigned even when the binary is unchanged,
# otherwise the designated requirement stays CDHash-pinned (or cert-pinned) by accident.
bundle_signing_mode_matches() {
  local app="$1"
  local info
  info="$(codesign_info "${app}")"
  if [[ "${SIGN_MODE}" == "certificate" ]]; then
    grep -qx "Authority=${SIGN_IDENTITY}" <<<"${info}"
  else
    grep -q 'flags=.*adhoc' <<<"${info}"
  fi
}

# When skipping resign, ensure packaged MacOS/DevType still looks like the SPM product.
# Ad-hoc codesign rewrites the Mach-O signature in place — size may grow or shrink slightly
# versus the SPM artifact, so compare within a band (not sha256 of the signed binary).
packaged_binary_aligns_with_spm() {
  local spm="$1"
  local packaged="$2"
  [[ -x "${spm}" && -x "${packaged}" ]] || return 1
  local spm_size pkg_size delta
  spm_size="$(file_size "${spm}")"
  pkg_size="$(file_size "${packaged}")"
  [[ -n "${spm_size}" && -n "${pkg_size}" ]] || return 1
  delta=$((pkg_size - spm_size))
  if [[ "${delta}" -lt 0 ]]; then
    delta=$((-delta))
  fi
  # Reject only wildly different binaries (wrong copy / truncate); 256 KiB band.
  [[ "${delta}" -le 262144 ]]
}

echo "==> swift build -c ${CONFIGURATION}"
swift build -c "${CONFIGURATION}"

BINARY="${PRODUCT_DIR}/DevType"
if [[ ! -x "${BINARY}" ]]; then
  # Deterministic: last path from sorted find (no fragile unsorted head -1).
  BINARY="$(find ".build" -path "*${CONFIGURATION}/DevType" -type f -perm +111 2>/dev/null | sort | tail -n 1)"
fi
if [[ -z "${BINARY}" || ! -x "${BINARY}" ]]; then
  echo "error: built DevType binary not found under .build/" >&2
  exit 1
fi

# Assert Info.plist identity before packaging.
if ! grep -q "<string>${BUNDLE_ID}</string>" "${PLIST_SRC}"; then
  echo "error: ${PLIST_SRC} missing CFBundleIdentifier ${BUNDLE_ID}" >&2
  exit 1
fi
if ! grep -q "<key>CFBundleExecutable</key>" "${PLIST_SRC}" || ! awk '/<key>CFBundleExecutable<\/key>/{getline; while($0 ~ /^[[:space:]]*$/) getline; exit !($0 ~ /<string>DevType<\/string>/)}' "${PLIST_SRC}"; then
  echo "error: ${PLIST_SRC} CFBundleExecutable must be DevType" >&2
  exit 1
fi
if ! grep -q "<key>LSUIElement</key>" "${PLIST_SRC}"; then
  echo "error: ${PLIST_SRC} missing LSUIElement" >&2
  exit 1
fi
# Ensure LSUIElement is true (next non-empty line after the key).
LSUI_VALUE="$(awk '/<key>LSUIElement<\/key>/{getline; while($0 ~ /^[[:space:]]*$/) getline; print}' "${PLIST_SRC}")"
if [[ "${LSUI_VALUE}" != *"<true/>"* ]]; then
  echo "error: LSUIElement must be true (got: ${LSUI_VALUE})" >&2
  exit 1
fi
# Keep TCC usage descriptions in the packaged plist (required for prompts).
for USAGE_KEY in NSAccessibilityUsageDescription NSInputMonitoringUsageDescription; do
  if ! grep -q "<key>${USAGE_KEY}</key>" "${PLIST_SRC}"; then
    echo "error: ${PLIST_SRC} missing ${USAGE_KEY}" >&2
    exit 1
  fi
done

NEW_SOURCE_HASH="$(sha256_file "${BINARY}")"
OLD_SOURCE_HASH=""
if [[ -f "${SOURCE_HASH_STAMP}" ]]; then
  OLD_SOURCE_HASH="$(tr -d '[:space:]' < "${SOURCE_HASH_STAMP}")"
fi

BINARY_UNCHANGED=0
if [[ -n "${OLD_SOURCE_HASH}" && "${NEW_SOURCE_HASH}" == "${OLD_SOURCE_HASH}" ]]; then
  BINARY_UNCHANGED=1
fi

# Identity-critical support: Info.plist + PkgInfo. Cosmetic Resources (icons) alone
# must not force resign — updating sealed resources without resign would invalidate
# the signature, so when we skip resign we leave Resources untouched to preserve CDHash.
identity_plist_unchanged() {
  local packaged="${CONTENTS}/Info.plist"
  [[ -f "${packaged}" ]] || return 1
  local src_id pkg_id src_exec pkg_exec
  src_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST_SRC}" 2>/dev/null || true)"
  pkg_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${packaged}" 2>/dev/null || true)"
  src_exec="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${PLIST_SRC}" 2>/dev/null || true)"
  pkg_exec="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${packaged}" 2>/dev/null || true)"
  [[ "${src_id}" == "${BUNDLE_ID}" && "${pkg_id}" == "${BUNDLE_ID}" ]] || return 1
  [[ "${src_exec}" == "DevType" && "${pkg_exec}" == "DevType" ]] || return 1
  # Full plist compare for usage descriptions / identity — if only icons change, plist still matches.
  # §7.6: compare against the version-stamped staging copy, not the raw source, so a
  # version bump correctly forces a resign but an unchanged build still skips it.
  cmp -s "${PLIST_STAGED}" "${packaged}"
}

IDENTITY_SUPPORT_UNCHANGED=1
if ! identity_plist_unchanged; then
  IDENTITY_SUPPORT_UNCHANGED=0
fi
if [[ ! -f "${CONTENTS}/PkgInfo" ]]; then
  IDENTITY_SUPPORT_UNCHANGED=0
fi

COSMETIC_CHANGED=0
if [[ -d "${ROOT}/Resources" ]]; then
  for resfile in "${ROOT}/Resources"/*; do
    if [[ -f "${resfile}" ]]; then
      resname="$(basename "${resfile}")"
      # Info.plist is handled separately as identity support; entitlements are a
      # signing input, not a bundle resource.
      is_excluded_resource "${resname}" && continue
      if [[ ! -f "${RESOURCES_DIR}/${resname}" ]] || ! cmp -s "${resfile}" "${RESOURCES_DIR}/${resname}"; then
        COSMETIC_CHANGED=1
      fi
    fi
  done
fi

PACKAGED_EXE="${MACOS_DIR}/DevType"
BINARY_ALIGN_OK=0
if packaged_binary_aligns_with_spm "${BINARY}" "${PACKAGED_EXE}"; then
  BINARY_ALIGN_OK=1
fi

SKIP_RESIGN=0
HARDENED_WANTED="${DEVTYPE_HARDENED_RUNTIME:-0}"
HARDENED_PRESENT=0
if codesign -d --verbose=2 "${APP_BUNDLE}" 2>&1 | grep -q "flags=.*runtime"; then
  HARDENED_PRESENT=1
fi

if [[ "${BINARY_UNCHANGED}" -eq 1 \
   && "${IDENTITY_SUPPORT_UNCHANGED}" -eq 1 \
   && "${BINARY_ALIGN_OK}" -eq 1 ]] \
   && bundle_codesign_ok "${APP_BUNDLE}"; then
  if [[ "${HARDENED_WANTED}" == "1" && "${HARDENED_PRESENT}" -eq 0 ]]; then
    SKIP_RESIGN=0
  else
    SKIP_RESIGN=1
  fi
elif [[ "${BINARY_UNCHANGED}" -eq 1 && "${IDENTITY_SUPPORT_UNCHANGED}" -eq 1 ]] \
   && ! packaged_binary_aligns_with_spm "${BINARY}" "${PACKAGED_EXE}"; then
  echo "==> packaged MacOS/DevType does not align with SPM product — will resign"
fi

if [[ "${SKIP_RESIGN}" -eq 1 ]]; then
  echo "==> packaging ${APP_BUNDLE} (unchanged identity — preserving signature / CDHash)"
  if [[ "${COSMETIC_CHANGED}" -eq 1 ]]; then
    echo "    note: cosmetic Resources differ but resign skipped to preserve CDHash"
    echo "    (icons/resources refresh on next binary or Info.plist change)"
  fi
else
  echo "==> packaging ${APP_BUNDLE}"
  # Prefer in-place updates over rm -rf so the bundle path stays continuous for TCC.
  mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

  # Copy the version-stamped plist so usage descriptions and identity stay intact
  # while CFBundleShortVersionString / CFBundleVersion carry real values (§7.6).
  cp "${PLIST_STAGED}" "${CONTENTS}/Info.plist"

  if [[ "${BINARY_UNCHANGED}" -eq 1 && -x "${PACKAGED_EXE}" ]] \
     && packaged_binary_aligns_with_spm "${BINARY}" "${PACKAGED_EXE}"; then
    echo "    binary content unchanged — keeping existing MacOS/DevType"
  else
    cp "${BINARY}" "${PACKAGED_EXE}"
    chmod +x "${PACKAGED_EXE}"
  fi

  # Copy all resources except signing inputs / the separately-staged plist.
  if [[ -d "${ROOT}/Resources" ]]; then
    for resfile in "${ROOT}/Resources"/*; do
      [[ -e "${resfile}" ]] || continue
      is_excluded_resource "$(basename "${resfile}")" && continue
      cp -R "${resfile}" "${RESOURCES_DIR}/"
    done
  fi

  # PkgInfo marks this as an application bundle (APPL / ???? creator).
  printf 'APPL????' > "${CONTENTS}/PkgInfo"

  # Sign with stable bundle ID (no --deep; sign the bundle itself).
  # Only runs when SPM binary or identity support changed (or prior signature invalid).
  # §7.5: notarization requires the Hardened Runtime. It is OFF by default so local
  # dev signing behaviour is unchanged, and ON automatically for a Developer ID
  # identity (the only identity that can be notarized) or when forced explicitly.
  CODESIGN_EXTRA=()
  HARDENED="${DEVTYPE_HARDENED_RUNTIME:-auto}"
  if [[ "${HARDENED}" == "auto" ]]; then
    # Developer ID only. An Apple Development certificate can carry the Hardened
    # Runtime too, but its entitlements would then need a provisioning profile to
    # be honoured, and it can never be notarized — so local dev stays unhardened.
    if [[ "${SIGN_KIND}" == "developer-id" ]]; then HARDENED=1; else HARDENED=0; fi
  fi
  if [[ "${HARDENED}" == "1" ]]; then
    CODESIGN_EXTRA+=(--options runtime --timestamp)
    if [[ -f "${ENTITLEMENTS}" ]]; then
      CODESIGN_EXTRA+=(--entitlements "${ENTITLEMENTS}")
    fi
    echo "    signing: ${SIGN_MODE} (${SIGN_ARG}) [hardened runtime]"
  else
    echo "    signing: ${SIGN_MODE} (${SIGN_ARG})"
  fi
  # bash 3.2 (system /bin/bash) treats "${empty[@]}" as unbound under `set -u`, so the
  # default non-hardened path would abort here. The `+` expansion drops to nothing instead.
  codesign --force --deep --sign "${SIGN_ARG}" --identifier "${BUNDLE_ID}" \
    ${CODESIGN_EXTRA[@]+"${CODESIGN_EXTRA[@]}"} "${APP_BUNDLE}" >/dev/null
fi

# Verify codesign identifier matches Info.plist CFBundleIdentifier (TCC identity).
SIGNED_INFO="$(codesign_info "${APP_BUNDLE}")"
SIGNED_ID="$(awk -F= '/^Identifier=/{print $2; exit}' <<<"${SIGNED_INFO}")"
if [[ "${SIGNED_ID}" != "${BUNDLE_ID}" ]]; then
  echo "error: codesign Identifier=${SIGNED_ID} does not match ${BUNDLE_ID}" >&2
  exit 1
fi

# Verify usage descriptions survived packaging (required for TCC prompts / Settings listing).
for USAGE_KEY in NSAccessibilityUsageDescription NSInputMonitoringUsageDescription; do
  if ! /usr/libexec/PlistBuddy -c "Print :${USAGE_KEY}" "${CONTENTS}/Info.plist" >/dev/null 2>&1; then
    echo "error: packaged Info.plist missing ${USAGE_KEY}" >&2
    exit 1
  fi
done
PACKAGED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${CONTENTS}/Info.plist")"
if [[ "${PACKAGED_ID}" != "${BUNDLE_ID}" ]]; then
  echo "error: packaged CFBundleIdentifier=${PACKAGED_ID} does not match ${BUNDLE_ID}" >&2
  exit 1
fi

if ! codesign --verify --strict "${APP_BUNDLE}" >/dev/null 2>&1; then
  echo "error: codesign --verify failed for ${APP_BUNDLE}" >&2
  exit 1
fi

# Record SPM source hash so the next run can skip resign when the binary is identical.
# (Cannot compare MacOS/DevType sha256 to SPM — codesign rewrites the Mach-O signature blob.)
printf '%s\n' "${NEW_SOURCE_HASH}" > "${SOURCE_HASH_STAMP}"

CDHASH="$(awk -F= '/^CDHash=/{print $2; exit}' <<<"${SIGNED_INFO}")"
# The designated requirement is what TCC stores; print it so a CDHash-pinned bundle
# (grants reset on every rebuild) is visible at a glance.
REQUIREMENT_OUT="$(codesign -d -r- "${APP_BUNDLE}" 2>/dev/null || true)"
DESIGNATED_REQ="$(awk '/designated => /{sub(/^# */, ""); sub(/^designated => /, ""); print; exit}' \
  <<<"${REQUIREMENT_OUT}")"

# Remove competing legacy build/ bundles (exact + .stale leftovers).
if [[ -d "${STALE_APP}" ]]; then
  echo "warning: removing stale ${STALE_APP} (competes with ${APP_BUNDLE} for TCC / same bundle ID)."
  rm -rf "${STALE_APP}"
fi
if [[ -d "${STALE_SUFFIX}" ]]; then
  echo "warning: removing stale ${STALE_SUFFIX}"
  rm -rf "${STALE_SUFFIX}"
fi
shopt -s nullglob
for stale in "${ROOT}/build"/DevType.app.stale*; do
  echo "warning: removing stale ${stale}"
  rm -rf "${stale}"
done
shopt -u nullglob

echo "==> done: ${APP_BUNDLE}"
echo "    CFBundleIdentifier: ${BUNDLE_ID}"
echo "    codesign Identifier: ${SIGNED_ID}"
echo "    CDHash: ${CDHASH}"
echo "    Signing: ${SIGN_KIND} (${SIGN_ARG})"
echo "    Designated requirement: ${DESIGNATED_REQ:-unknown}"
echo "    Source sha256: ${NEW_SOURCE_HASH}"
if [[ "${SKIP_RESIGN}" -eq 1 ]]; then
  echo "    Resign: skipped (binary + identity plist unchanged; cosmetic-only changes deferred)"
else
  echo "    Resign: performed"
fi
if [[ "${SIGN_MODE}" == "ad-hoc" ]]; then
  echo "    Warning: ad-hoc signature — requirement is CDHash-pinned, so TCC grants reset"
  echo "             on every binary change. Fix once: ./Scripts/make-signing-cert.sh"
fi
echo "    Binary: ${BINARY}"
echo "    Run: open ${APP_BUNDLE}"
echo "    Or:  ${MACOS_DIR}/DevType"
echo "    Tip: install to Applications / Launchpad: ./Scripts/install-app.sh"
echo "    Tip: quit all other DevType copies before granting permissions"
if [[ "${SIGN_MODE}" == "certificate" ]]; then
  echo "    Tip: TCC grants are pinned to the certificate — they survive rebuilds"
  if [[ "${SIGN_KIND}" == "local" ]]; then
    echo "    Tip: this is the self-signed fallback. An Apple-issued certificate (free Apple ID,"
    echo "         Xcode > Settings > Accounts > Manage Certificates) additionally gives keychain"
    echo "         items a stable teamid: partition instead of a per-build cdhash: one."
  fi
else
  echo "    Tip: TCC grants stick across launches; they reset if the binary changes and is re-signed"
fi
