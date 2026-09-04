#!/usr/bin/env bash
# Package DevType (if needed) and install the canonical daily-driver copy into Applications.
# Prefers /Applications/DevType.app; falls back to ~/Applications if write fails.
# Quits other DevType processes, validates before a recoverable swap, and quarantines known copies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-debug}"
SRC_APP="${ROOT}/.build/DevType.app"
BUNDLE_ID="com.devtype.app"
SYSTEM_DEST="/Applications/DevType.app"
USER_DEST="${HOME}/Applications/DevType.app"
STALE_EXACT="${ROOT}/build/DevType.app"
STALE_SUFFIX="${ROOT}/build/DevType.app.stale"
QUARANTINE_DIR="${ROOT}/build/.quarantine"

echo "==> packaging via Scripts/package-app.sh ${CONFIGURATION}"
"${ROOT}/Scripts/package-app.sh" "${CONFIGURATION}"

if [[ ! -d "${SRC_APP}" ]]; then
  echo "error: missing ${SRC_APP} after package-app.sh" >&2
  exit 1
fi

designated_requirement() {
  local app="$1"
  [[ -d "${app}" ]] || return 0
  local out
  # codesign writes display output to stderr even on success.
  out="$(codesign -d -r- "${app}" 2>&1 || true)"
  awk '/designated => /{sub(/^# */, ""); sub(/^designated => /, ""); print; exit}' <<<"${out}"
}

bundle_identifier() {
  local app="$1"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "${app}/Contents/Info.plist" 2>/dev/null || true
}

signed_information() {
  local app="$1"
  # Capture first: piping into an early-exiting awk SIGPIPEs codesign, which combines badly with
  # `set -o pipefail` and can turn a successful inspection into a silent installer abort.
  codesign -dvvv "${app}" 2>&1 || true
}

validate_app_bundle() {
  local app="$1"
  local context="$2"
  if [[ ! -d "${app}" ]]; then
    echo "error: ${context} bundle is missing: ${app}" >&2
    return 1
  fi
  if ! codesign --verify --strict "${app}" >/dev/null 2>&1; then
    echo "error: codesign --verify failed for ${context} bundle ${app}" >&2
    return 1
  fi

  local packaged_id
  packaged_id="$(bundle_identifier "${app}")"
  if [[ "${packaged_id}" != "${BUNDLE_ID}" ]]; then
    echo "error: ${context} CFBundleIdentifier=${packaged_id:-missing} does not match ${BUNDLE_ID}" >&2
    return 1
  fi

  local info signed_id
  info="$(signed_information "${app}")"
  signed_id="$(awk -F= '/^Identifier=/{print $2; exit}' <<<"${info}")"
  if [[ "${signed_id}" != "${BUNDLE_ID}" ]]; then
    echo "error: ${context} codesign Identifier=${signed_id:-missing} does not match ${BUNDLE_ID}" >&2
    return 1
  fi

  local requirement
  requirement="$(designated_requirement "${app}")"
  if [[ -z "${requirement}" ]]; then
    echo "error: ${context} designated requirement is unreadable for ${app}" >&2
    return 1
  fi
}

# Validate the package before inspecting or mutating any installed copy. TCC continuity cannot be
# established without a readable designated requirement, so an unknown new identity fails closed.
if ! validate_app_bundle "${SRC_APP}" "packaged"; then
  exit 1
fi

# Snapshot requirements only from bundles proven to own DevType's identifier. Destination
# selection happens later: a wrong-ID /Applications occupant can force a user install, and must
# never become the provenance source for the TCC comparison. Both matching canonical copies are
# retained here because the successful flow replaces one and quarantines the other.
SYSTEM_HAD_DEVTYPE=0
SYSTEM_OLD_REQ=""
if [[ -e "${SYSTEM_DEST}" || -L "${SYSTEM_DEST}" ]] \
    && [[ "$(bundle_identifier "${SYSTEM_DEST}")" == "${BUNDLE_ID}" ]]; then
  SYSTEM_HAD_DEVTYPE=1
  SYSTEM_OLD_REQ="$(designated_requirement "${SYSTEM_DEST}")"
fi

USER_HAD_DEVTYPE=0
USER_OLD_REQ=""
if [[ -e "${USER_DEST}" || -L "${USER_DEST}" ]] \
    && [[ "$(bundle_identifier "${USER_DEST}")" == "${BUNDLE_ID}" ]]; then
  USER_HAD_DEVTYPE=1
  USER_OLD_REQ="$(designated_requirement "${USER_DEST}")"
fi

# Quit every running DevType process before replacing the canonical install.
if pgrep -x DevType >/dev/null 2>&1; then
  echo "==> quitting running DevType processes"
  pkill -x DevType 2>/dev/null || true
  # Brief wait so the bundle is not busy during replace.
  for _ in 1 2 3 4 5; do
    pgrep -x DevType >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -x DevType >/dev/null 2>&1; then
    echo "warning: DevType still running; attempting force quit" >&2
    pkill -9 -x DevType 2>/dev/null || true
    sleep 0.2
  fi
fi

quarantine_path() {
  local path="$1"
  [[ -e "${path}" || -L "${path}" ]] || return 0
  if ! mkdir -p "${QUARANTINE_DIR}"; then
    echo "error: could not create quarantine directory ${QUARANTINE_DIR}" >&2
    return 1
  fi
  local base timestamp dest suffix
  base="$(basename "${path}")"
  timestamp="$(date +%Y%m%d%H%M%S)"
  dest="${QUARANTINE_DIR}/${base}.${timestamp}.$$"
  suffix=0
  while [[ -e "${dest}" || -L "${dest}" ]]; do
    suffix=$((suffix + 1))
    dest="${QUARANTINE_DIR}/${base}.${timestamp}.$$.${suffix}"
  done
  echo "==> quarantining stale ${path} → ${dest}"
  if ! mv "${path}" "${dest}"; then
    echo "error: could not quarantine ${path}; it remains at its original path" >&2
    return 1
  fi
}

unique_adjacent_path() {
  local prefix="$1"
  local candidate="${prefix}.$$"
  local suffix=0
  while [[ -e "${candidate}" || -L "${candidate}" ]]; do
    suffix=$((suffix + 1))
    candidate="${prefix}.$$.${suffix}"
  done
  printf '%s\n' "${candidate}"
}

# Exact build/DevType.app and *.stale leftovers compete for TCC / Launchpad confusion.
if [[ -d "${STALE_EXACT}" ]]; then
  quarantine_path "${STALE_EXACT}"
fi
if [[ -d "${STALE_SUFFIX}" ]]; then
  quarantine_path "${STALE_SUFFIX}"
fi
# Any other DevType.app.stale* under build/
shopt -s nullglob
for stale in "${ROOT}/build"/DevType.app.stale*; do
  quarantine_path "${stale}"
done
shopt -u nullglob

# Copy and validate beside the destination before touching an installed bundle. The old bundle is
# renamed to a unique sibling for the shortest possible swap window, restored if the final move or
# post-move verification fails, and quarantined only after the replacement is verified in place.
install_copy() {
  local dest="$1"
  local dest_parent staging previous invalid_install
  dest_parent="$(dirname "${dest}")"
  if ! mkdir -p "${dest_parent}"; then
    echo "error: could not create destination directory ${dest_parent}" >&2
    return 1
  fi

  staging="$(unique_adjacent_path "${dest}.new")"
  if ! ditto "${SRC_APP}" "${staging}"; then
    echo "error: could not stage ${SRC_APP} beside ${dest}" >&2
    rm -rf "${staging}"
    return 1
  fi
  if ! validate_app_bundle "${staging}" "staged"; then
    rm -rf "${staging}"
    return 1
  fi

  previous=""
  if [[ -e "${dest}" || -L "${dest}" ]]; then
    local existing_id
    existing_id="$(bundle_identifier "${dest}")"
    if [[ "${existing_id}" != "${BUNDLE_ID}" ]]; then
      echo "error: refusing to replace ${dest}; existing CFBundleIdentifier=${existing_id:-unreadable}" >&2
      rm -rf "${staging}"
      return 1
    fi
    previous="$(unique_adjacent_path "${dest}.previous")"
    if ! mv "${dest}" "${previous}"; then
      echo "error: could not preserve existing destination ${dest}" >&2
      rm -rf "${staging}"
      return 1
    fi
  fi

  if ! mv "${staging}" "${dest}"; then
    echo "error: could not move staged bundle into ${dest}" >&2
    rm -rf "${staging}"
    if [[ -n "${previous}" ]]; then
      if ! mv "${previous}" "${dest}"; then
        echo "error: rollback failed; previous bundle remains recoverable at ${previous}" >&2
        return 2
      fi
      echo "    restored previous bundle at ${dest}" >&2
    fi
    return 1
  fi

  if ! validate_app_bundle "${dest}" "installed"; then
    invalid_install="$(unique_adjacent_path "${dest}.invalid")"
    if ! mv "${dest}" "${invalid_install}"; then
      echo "error: verification failed and ${dest} could not be moved aside for rollback" >&2
      [[ -n "${previous}" ]] \
        && echo "error: previous bundle remains recoverable at ${previous}" >&2
      return 2
    fi
    if [[ -n "${previous}" ]]; then
      if ! mv "${previous}" "${dest}"; then
        echo "error: rollback failed; previous bundle remains recoverable at ${previous}" >&2
        echo "error: invalid replacement remains at ${invalid_install}" >&2
        return 2
      fi
      echo "    restored previous bundle at ${dest}" >&2
    fi
    rm -rf "${invalid_install}"
    return 1
  fi

  if [[ -n "${previous}" ]]; then
    if ! quarantine_path "${previous}"; then
      echo "warning: verified install succeeded, but the previous bundle remains at ${previous}" >&2
    fi
  fi
}

DEST=""
SYSTEM_INSTALL_RC=0
install_copy "${SYSTEM_DEST}" || SYSTEM_INSTALL_RC=$?
if [[ "${SYSTEM_INSTALL_RC}" -eq 0 ]]; then
  DEST="${SYSTEM_DEST}"
else
  if [[ "${SYSTEM_INSTALL_RC}" -eq 2 ]]; then
    echo "error: installation stopped because the system destination could not be rolled back" >&2
    exit 1
  fi
  echo "warning: could not write ${SYSTEM_DEST}; installing to ${USER_DEST}" >&2
  USER_INSTALL_RC=0
  install_copy "${USER_DEST}" || USER_INSTALL_RC=$?
  if [[ "${USER_INSTALL_RC}" -ne 0 ]]; then
    if [[ "${USER_INSTALL_RC}" -eq 2 ]]; then
      echo "error: user destination could not be rolled back; inspect the recovery path above" >&2
    fi
    echo "error: failed to install to ${USER_DEST}" >&2
    exit 1
  fi
  DEST="${USER_DEST}"
fi

if ! validate_app_bundle "${DEST}" "installed"; then
  echo "error: installed bundle failed final verification at ${DEST}" >&2
  exit 1
fi

# Capture codesign output first: piping it into awk that exits on the first match
# SIGPIPEs codesign, and `set -o pipefail` + `set -e` would abort here silently.
SIGNED_INFO="$(codesign -dvvv "${DEST}" 2>&1 || true)"
SIGNED_ID="$(awk -F= '/^Identifier=/{print $2; exit}' <<<"${SIGNED_INFO}")"
SIGNED_AUTHORITY="$(awk -F= '/^Authority=/{print $2; exit}' <<<"${SIGNED_INFO}")"
if [[ "${SIGNED_ID}" != "${BUNDLE_ID}" ]]; then
  echo "error: codesign Identifier=${SIGNED_ID} does not match ${BUNDLE_ID}" >&2
  exit 1
fi

PACKAGED_ID="$(bundle_identifier "${DEST}")"

# The installer knows only these two canonical daily-driver paths. Remove the other one only when
# its bundle identifier proves it is another DevType copy, and only after the selected destination
# has passed both staged and in-place verification.
if [[ "${DEST}" == "${SYSTEM_DEST}" ]]; then
  ALTERNATE_DEST="${USER_DEST}"
else
  ALTERNATE_DEST="${SYSTEM_DEST}"
fi
if [[ -e "${ALTERNATE_DEST}" || -L "${ALTERNATE_DEST}" ]]; then
  ALTERNATE_ID="$(bundle_identifier "${ALTERNATE_DEST}")"
  if [[ "${ALTERNATE_ID}" == "${BUNDLE_ID}" ]]; then
    echo "==> quarantining alternate DevType install ${ALTERNATE_DEST}"
    if ! quarantine_path "${ALTERNATE_DEST}"; then
      echo "error: verified install is at ${DEST}, but alternate copy remains at ${ALTERNATE_DEST}" >&2
      exit 1
    fi
  else
    echo "warning: leaving ${ALTERNATE_DEST} untouched; CFBundleIdentifier=${ALTERNATE_ID:-unreadable}" >&2
  fi
fi

# A CDHash-pinned (ad-hoc) → cert-pinned switch, or any other requirement change, leaves TCC
# records authorizing an identity the installed app no longer satisfies. Compare the verified
# installed requirement only with prior same-bundle identities that this completed flow displaced.
# An unreadable prior requirement cannot prove continuity, so reset rather than preserve possibly
# stale grants. Multiple prior canonical copies still result in one bounded reset.
NEW_REQ="$(designated_requirement "${DEST}")"
NEED_TCC_RESET=0
if [[ "${SYSTEM_HAD_DEVTYPE}" -eq 1 ]] \
    && { [[ -z "${SYSTEM_OLD_REQ}" ]] || [[ "${SYSTEM_OLD_REQ}" != "${NEW_REQ}" ]]; }; then
  NEED_TCC_RESET=1
fi
if [[ "${USER_HAD_DEVTYPE}" -eq 1 ]] \
    && { [[ -z "${USER_OLD_REQ}" ]] || [[ "${USER_OLD_REQ}" != "${NEW_REQ}" ]]; }; then
  NEED_TCC_RESET=1
fi
if [[ "${NEED_TCC_RESET}" -eq 1 ]]; then
  echo "==> signing requirement changed or could not be verified — will reset TCC grants after install"
  if [[ "${SYSTEM_HAD_DEVTYPE}" -eq 1 ]]; then
    echo "    old (${SYSTEM_DEST}): ${SYSTEM_OLD_REQ:-unreadable}"
  fi
  if [[ "${USER_HAD_DEVTYPE}" -eq 1 ]]; then
    echo "    old (${USER_DEST}): ${USER_OLD_REQ:-unreadable}"
  fi
  echo "    new: ${NEW_REQ}"
fi

ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${DEST}/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "${ICON_FILE}" && ! -f "${DEST}/Contents/Resources/${ICON_FILE}.icns" && ! -f "${DEST}/Contents/Resources/${ICON_FILE}" ]]; then
  echo "warning: CFBundleIconFile=${ICON_FILE} but icon resource missing under Contents/Resources" >&2
fi

echo "==> installed: ${DEST}"
echo "    CFBundleIdentifier: ${PACKAGED_ID}"
echo "    codesign Identifier: ${SIGNED_ID}"
echo "    codesign Authority: ${SIGNED_AUTHORITY:-ad-hoc (grants reset on rebuild)}"
echo "    Launch: open ${DEST}"
echo ""
echo "    Canonical daily-driver path: ${DEST}"

# Quarantine the packaging source so Launchpad / open / TCC cannot confuse .build vs Applications.
# package-app.sh will recreate .build/DevType.app on the next packaging pass.
if [[ -d "${SRC_APP}" ]]; then
  echo "==> quarantining dual-install source ${SRC_APP} (daily driver is ${DEST})"
  quarantine_path "${SRC_APP}"
  # Also quarantine both successful-package input stamps so the next package performs every
  # signing contract check from a clean state.
  for package_stamp in source-sha256 entitlements-sha256; do
    if [[ -f "${SRC_APP}.${package_stamp}" ]]; then
      quarantine_path "${SRC_APP}.${package_stamp}"
    fi
  done
  echo "    note: re-run Scripts/package-app.sh when you need a fresh .build/DevType.app for iteration."
  echo "    Do NOT launch a .build copy for daily use — grant TCC only on ${DEST}."
fi
echo "    Tip: pkill -x DevType; open ${DEST}"
if [[ -n "${SIGNED_AUTHORITY}" ]]; then
  echo "    Tip: requirement is cert-pinned — TCC grants survive rebuilds."
  echo "    Tip: Developer ID / notarization is still the path for distribution."
else
  echo "    Tip: ad-hoc CDHash resets TCC on resign — fix once: ./Scripts/make-signing-cert.sh"
fi

if [[ "${NEED_TCC_RESET}" -eq 1 ]]; then
  echo "==> resetting stale TCC records (requirement changed)"
  "${ROOT}/Scripts/reset-tcc.sh"
  echo "    Re-grant in Setup / Permission Recovery after: open ${DEST}"
fi
