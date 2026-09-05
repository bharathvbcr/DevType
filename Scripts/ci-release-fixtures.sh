#!/usr/bin/env bash
# Fast publication/installer fixtures shared by local CI, GitHub hygiene, and the
# Release job. This is not a substitute for the Swift test suite: tag publication
# must not re-run the engine tests after the reusable CI workflow has already
# passed (a green CI job followed by a flaky ci-local rerun has failed a release).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

echo "==> Release and installer fixtures"
echo "  - Checking signing identity resolution..."
"${ROOT}/Scripts/test-signing-identity.sh"
echo "  - Checking package signing cache and entitlement contract..."
"${ROOT}/Scripts/test-package-signing-contract.sh"
echo "  - Checking recoverable installer and canonical-path cleanup..."
"${ROOT}/Scripts/test-install-app.sh"
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
echo "  - Checking release capabilities..."
"${ROOT}/Scripts/test-release-capabilities.sh"
echo "  - Checking draft publication and failure recovery..."
python3 "${ROOT}/Scripts/test-release-publication.py"
echo "==> Release and installer fixtures passed"
