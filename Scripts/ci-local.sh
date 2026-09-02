#!/usr/bin/env bash
# Local CI script mirroring .github/workflows/ci.yml
# Runs linting, syntax verification, unit tests, debug build, release build, and packaging.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=========================================="
echo "==> DevType Local CI (ci:local)"
echo "=========================================="

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

echo "==> Toolchain check"
swift --version
xcodebuild -version

echo "==> 0. Stale module-cache preflight"
# A checkout moved between directories poisons SwiftPM's clang module cache:
# every PCM embeds the absolute ModuleCache path it was built with, so after a
# move clang aborts C/ObjC compiles with "was compiled with module cache path
# ... but the path is currently ..." buried under a _DarwinFoundation* cascade.
# Purge any cache containing a PCM whose embedded path is not under ROOT.
stale_pcm_found=0
while IFS= read -r pcm; do
  [[ -f "${pcm}" ]] || continue
  # Bound the scan: sampling the first 200 PCMs is enough to catch a wholesale
  # stale cache, and keeps this preflight O(few hundred MB of grep) worst case.
  if ! grep -aq -- "${ROOT}" "${pcm}" && grep -aq "/.build/" "${pcm}"; then
    echo "  stale PCM (built elsewhere): ${pcm}"
    stale_pcm_found=1
    break
  fi
done < <(find .build -type f -name '*.pcm' 2>/dev/null | head -n 200)
if [[ "${stale_pcm_found}" -eq 1 ]]; then
  find .build -type d -name ModuleCache -prune -exec rm -rf {} +
  echo "  purged ModuleCache dirs; they will be rebuilt during this run"
else
  echo "  ok: no stale module caches"
fi

echo "==> 1. Linting & Repo Hygiene"
echo "  - Checking shell scripts syntax..."
for f in Scripts/*.sh; do
  bash -n "$f" || { echo "error: syntax check failed for $f" >&2; exit 1; }
done
if [[ -f "./ci:local" ]]; then
  bash -n "./ci:local" || { echo "error: syntax check failed for ./ci:local" >&2; exit 1; }
fi

echo "  - Checking property lists..."
plutil -lint Resources/Info.plist
plutil -lint Resources/DevType.entitlements

echo "  - Checking signing identity resolution..."
"${ROOT}/Scripts/test-signing-identity.sh"
echo "  - Checking distribution signing gate..."
"${ROOT}/Scripts/test-release-signing-preflight.sh"

echo "  - Checking release DMG selection..."
"${ROOT}/Scripts/test-release-dmg-select.sh"
echo "  - Checking published release asset inventory..."
"${ROOT}/Scripts/test-release-asset-list.sh"
echo "  - Checking tagged-release trust boundary..."
"${ROOT}/Scripts/test-release-guard.sh"
echo "  - Checking release tag/bundle version matching..."
"${ROOT}/Scripts/test-release-version.sh"
echo "  - Checking release preflight..."
"${ROOT}/Scripts/test-release-preflight.sh"

echo "==> 2. Running SwiftPM Unit Tests"
"${ROOT}/Scripts/test.sh" -v

echo "==> 3. Swift Build (debug)"
swift build -c debug -v

echo "==> 4. Swift Build (release)"
swift build -c release -v

echo "==> 5. Packaging .app bundle (release)"
"${ROOT}/Scripts/package-app.sh" release

echo "==> 6. Verifying bundle identity & version stamping"
APP=".build/DevType.app"
if [[ ! -d "$APP" ]]; then
  echo "error: no bundle produced at $APP" >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

echo "  Bundle Identifier: $BUNDLE_ID"
echo "  Stamped Version:   $VER (build $BUILD)"

if [ "$VER" = "1.0.0" ] && [ "$BUILD" = "1" ]; then
  echo "error: version was not stamped from git (found placeholder 1.0.0 / build 1)" >&2
  exit 1
fi

codesign --verify --strict --verbose=2 "$APP"

echo "=========================================="
echo "==> Local CI PASSED SUCCESSFULLY! ✓"
echo "=========================================="
