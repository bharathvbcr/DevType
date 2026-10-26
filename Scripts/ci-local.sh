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
# A checkout moved between directories poisons SwiftPM's clang module cache.
# Hosted CI runs the same script after restoring .build.
"${ROOT}/Scripts/purge-stale-module-cache.sh"

echo "==> 1. Linting & Repo Hygiene"
"${ROOT}/Scripts/ci-hygiene.sh"

echo "==> 2. Running SwiftPM Unit Tests"
# Debug timings are not the gate. Step 2b is the release ceiling, and only when
# DEVTYPE_BENCH=1 was set for this script. Strip it here so a debug run cannot
# fail the suite on a wall-clock number the ceilings were not derived from.
env -u DEVTYPE_BENCH "${ROOT}/Scripts/test.sh" -v

echo "==> 2b. Benchmark regression gate (release)"
# Ceilings in Tests/ExpanderEngineTests/AuditBenchmarkTests.swift are ~10x the release numbers, so
# this is the configuration they are meaningful in. Hosted runners share cores and throttle, so
# the gate stays local (see docs/DEVELOPMENT.md "Benchmark regression gate"). A failed ceiling
# fails this script; skipping is announced, never silent. -DDEBUG is needed because other test
# files use `#if DEBUG` hooks that a release test build would otherwise drop.
if [[ "${DEVTYPE_BENCH:-}" == "1" ]]; then
  swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter 'AuditBenchmark|BenchmarkGateSelfTests|FollowThroughBenchmark|VoiceStreamingBenchmark'
else
  echo "  SKIPPED: DEVTYPE_BENCH=1 is not set, so the performance gate did NOT run."
  echo "  The release gate is DEVTYPE_BENCH=1 ./Scripts/ci-local.sh."
fi

echo "==> 3. Swift Build (debug)"
swift build -c debug -v

echo "==> 4. Swift Build (release)"
swift build -c release -v

echo "==> 5. Packaging .app bundle (release)"
"${ROOT}/Scripts/package-app.sh" release

echo "==> 6. Verifying bundle identity & version stamping"
# Foundation Models linkage stays off unless the caller set
# DEVTYPE_REQUIRE_FOUNDATION_MODELS=1. The macos-26 packaging job and every
# tagged release set it; a local run on an older Xcode announces the skip.
"${ROOT}/Scripts/verify-packaged-bundle.sh" "${ROOT}/.build/DevType.app"

echo "=========================================="
echo "==> Local CI PASSED SUCCESSFULLY! ✓"
echo "=========================================="
