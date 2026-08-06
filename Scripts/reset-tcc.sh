#!/usr/bin/env bash
# Clear DevType's TCC records so the next Request produces a real prompt.
#
# Needed when a Settings toggle is ON but the app still preflights denied: the stored
# row authorizes an older code identity (ad-hoc CDHash from a previous build), so
# CGRequestListenEventAccess / AXIsProcessTrustedWithOptions return false immediately
# and no prompt is shown — tccd never even logs a request.
#
# Run Scripts/make-signing-cert.sh first to stop this recurring on every install.
set -euo pipefail

BUNDLE_ID="${DEVTYPE_BUNDLE_ID:-com.devtype.app}"
SERVICES=(ListenEvent Accessibility PostEvent)

if pgrep -x DevType >/dev/null 2>&1; then
  echo "==> quitting DevType (records must be reset while it is not running)"
  pkill -x DevType 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    pgrep -x DevType >/dev/null 2>&1 || break
    sleep 0.2
  done
  pgrep -x DevType >/dev/null 2>&1 && pkill -9 -x DevType 2>/dev/null || true
fi

for svc in "${SERVICES[@]}"; do
  echo "==> tccutil reset ${svc} ${BUNDLE_ID}"
  tccutil reset "${svc}" "${BUNDLE_ID}" || true
done

echo
echo "==> done — records cleared for ${BUNDLE_ID}"
echo "    1. open /Applications/DevType.app"
echo "    2. In Setup (or Permission Recovery ⌘⇧P) click Request for each capability"
echo "    3. Approve the system prompts — the new grant binds to the current identity"
echo
echo "    If a stale DevType row still appears in a Settings list, remove it with the"
echo "    minus button before re-granting."
