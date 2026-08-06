#!/usr/bin/env bash
# Package DevType (if needed) and install a single daily-driver copy into Applications.
# Prefers /Applications/DevType.app; falls back to ~/Applications if write fails.
# Quits other DevType processes, installs atomically, and quarantines stale build/ artifacts.
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
  out="$(codesign -d -r- "${app}" 2>/dev/null || true)"
  awk '/designated => /{sub(/^# */, ""); sub(/^designated => /, ""); print; exit}' <<<"${out}"
}

# Compare designated requirement before overwrite. A CDHash-pinned (ad-hoc) → cert-pinned
# switch (or any requirement change) leaves Settings toggles authorizing the old identity;
# CGRequest* then returns false with no prompt. Reset TCC once when that happens.
PREV_DEST=""
if [[ -d "${SYSTEM_DEST}" ]]; then
  PREV_DEST="${SYSTEM_DEST}"
elif [[ -d "${USER_DEST}" ]]; then
  PREV_DEST="${USER_DEST}"
fi
OLD_REQ=""
NEW_REQ="$(designated_requirement "${SRC_APP}")"
NEED_TCC_RESET=0
if [[ -n "${PREV_DEST}" ]]; then
  OLD_REQ="$(designated_requirement "${PREV_DEST}")"
  if [[ -n "${OLD_REQ}" && -n "${NEW_REQ}" && "${OLD_REQ}" != "${NEW_REQ}" ]]; then
    NEED_TCC_RESET=1
    echo "==> signing requirement changed — will reset TCC grants after install"
    echo "    old: ${OLD_REQ}"
    echo "    new: ${NEW_REQ}"
  fi
fi

# Prefer one running identity: quit every DevType process before replacing the install.
if pgrep -x DevType >/dev/null 2>&1; then
  echo "==> quitting running DevType processes (single-identity install)"
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
  [[ -e "${path}" ]] || return 0
  mkdir -p "${QUARANTINE_DIR}"
  local base
  base="$(basename "${path}")"
  local dest="${QUARANTINE_DIR}/${base}.$(date +%Y%m%d%H%M%S)"
  echo "==> quarantining stale ${path} → ${dest}"
  rm -rf "${dest}"
  mv "${path}" "${dest}"
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

# Atomic-ish replace: stage beside destination, then swap.
install_copy() {
  local dest="$1"
  local dest_parent
  dest_parent="$(dirname "${dest}")"
  mkdir -p "${dest_parent}"
  local staging="${dest}.new.$$"
  rm -rf "${staging}"
  ditto "${SRC_APP}" "${staging}"
  # Swap into place (remove old, move new).
  rm -rf "${dest}"
  mv "${staging}" "${dest}"
}

DEST=""
if install_copy "${SYSTEM_DEST}" 2>/dev/null; then
  DEST="${SYSTEM_DEST}"
else
  echo "warning: could not write ${SYSTEM_DEST}; installing to ${USER_DEST}" >&2
  mkdir -p "${HOME}/Applications"
  if ! install_copy "${USER_DEST}"; then
    echo "error: failed to install to ${USER_DEST}" >&2
    exit 1
  fi
  DEST="${USER_DEST}"
fi

if ! codesign --verify --strict "${DEST}" >/dev/null 2>&1; then
  echo "error: codesign --verify failed for ${DEST}" >&2
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

PACKAGED_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${DEST}/Contents/Info.plist")"
if [[ "${PACKAGED_ID}" != "${BUNDLE_ID}" ]]; then
  echo "error: CFBundleIdentifier=${PACKAGED_ID} does not match ${BUNDLE_ID}" >&2
  exit 1
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
echo "    Single identity: use ${DEST} as the daily driver."

# Quarantine the packaging source so Launchpad / open / TCC cannot confuse .build vs Applications.
# package-app.sh will recreate .build/DevType.app on the next packaging pass.
if [[ -d "${SRC_APP}" ]]; then
  echo "==> quarantining dual-install source ${SRC_APP} (daily driver is ${DEST})"
  quarantine_path "${SRC_APP}"
  # Also quarantine the source-hash stamp so the next package does a clean rebuild/sign.
  if [[ -f "${SRC_APP}.source-sha256" ]]; then
    quarantine_path "${SRC_APP}.source-sha256"
  fi
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
