#!/usr/bin/env bash
# Regression tests for Scripts/verify-release-capabilities.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devtype-release-caps.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# shellcheck source=Scripts/lib-shell-test-harness.sh
source "${ROOT}/Scripts/lib-shell-test-harness.sh"
harness_subject "${ROOT}/Scripts/verify-release-capabilities.sh" "${TMP_ROOT}"

# Setup mock app bundles
MOCK_APP_PASS="${TMP_ROOT}/Pass.app"
mkdir -p "${MOCK_APP_PASS}/Contents/MacOS"
touch "${MOCK_APP_PASS}/Contents/MacOS/DevType"

MOCK_APP_FAIL="${TMP_ROOT}/Fail.app"
mkdir -p "${MOCK_APP_FAIL}/Contents/MacOS"
touch "${MOCK_APP_FAIL}/Contents/MacOS/DevType"

MOCK_APP_NO_BIN="${TMP_ROOT}/NoBin.app"
mkdir -p "${MOCK_APP_NO_BIN}/Contents/MacOS"

# Setup mock otool scripts
MOCK_OTOOL_PASS="${TMP_ROOT}/mock_otool_pass.sh"
cat <<'EOF' > "${MOCK_OTOOL_PASS}"
#!/usr/bin/env bash
cat <<'OUT'
/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
/System/Library/Frameworks/FoundationModels.framework/Versions/A/FoundationModels (compatibility version 1.0.0, current version 1.5.2, weak)
/usr/lib/libSystem.B.dylib
OUT
EOF
chmod +x "${MOCK_OTOOL_PASS}"

MOCK_OTOOL_FAIL="${TMP_ROOT}/mock_otool_fail.sh"
cat <<'EOF' > "${MOCK_OTOOL_FAIL}"
#!/usr/bin/env bash
cat <<'OUT'
/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
/usr/lib/libSystem.B.dylib
OUT
EOF
chmod +x "${MOCK_OTOOL_FAIL}"

# Linked, but STRONGLY — the regression that would ship a DMG dyld refuses to load
# on every Mac below macOS 26. Same framework name, no `weak` marker.
MOCK_OTOOL_STRONG="${TMP_ROOT}/mock_otool_strong.sh"
cat <<'EOF' > "${MOCK_OTOOL_STRONG}"
#!/usr/bin/env bash
cat <<'OUT'
/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
/System/Library/Frameworks/FoundationModels.framework/Versions/A/FoundationModels (compatibility version 1.0.0, current version 1.5.2)
/usr/lib/libSystem.B.dylib
OUT
EOF
chmod +x "${MOCK_OTOOL_STRONG}"

# otool itself failing must not read as "no framework found".
MOCK_OTOOL_BROKEN="${TMP_ROOT}/mock_otool_broken.sh"
cat <<'EOF' > "${MOCK_OTOOL_BROKEN}"
#!/usr/bin/env bash
echo "otool: can't open file: truncated or malformed object" >&2
exit 1
EOF
chmod +x "${MOCK_OTOOL_BROKEN}"

# 1. Gate unset: skips with notice, exits 0
DEVTYPE_REQUIRE_FOUNDATION_MODELS=0 expect_ok "gate unset skips with notice" "${MOCK_APP_FAIL}"
if ! grep -q "skipping" "${TMP_ROOT}/stdout"; then
  echo "FAIL: gate unset did not print notice about skipping" >&2
  exit 1
fi

# 2. Gate set: missing app path argument fails
DEVTYPE_REQUIRE_FOUNDATION_MODELS=1 expect_fail "missing app path argument rejected"

# 3. Gate set: non-existent app bundle fails
DEVTYPE_REQUIRE_FOUNDATION_MODELS=1 expect_fail "non-existent app bundle rejected" "${TMP_ROOT}/NonExistent.app"

# 4. Gate set: missing binary fails
DEVTYPE_REQUIRE_FOUNDATION_MODELS=1 expect_fail "app bundle with missing binary rejected" "${MOCK_APP_NO_BIN}"

# 5. Gate set: linked binary passes
DEVTYPE_REQUIRE_FOUNDATION_MODELS=1 OTOOL="${MOCK_OTOOL_PASS}" expect_ok "linked binary passes" "${MOCK_APP_PASS}"

# 6. Gate set: unlinked binary fails with reason
DEVTYPE_REQUIRE_FOUNDATION_MODELS=1 OTOOL="${MOCK_OTOOL_FAIL}" expect_fail "unlinked binary rejected" "${MOCK_APP_FAIL}"
if ! grep -q "FoundationModels" "${TMP_ROOT}/stderr"; then
  echo "FAIL: rejection did not name FoundationModels in stderr" >&2
  exit 1
fi

# 7. Gate set: strongly linked binary fails and says why
DEVTYPE_REQUIRE_FOUNDATION_MODELS=1 OTOOL="${MOCK_OTOOL_STRONG}" expect_fail "strongly linked binary rejected" "${MOCK_APP_PASS}"
if ! grep -q "strongly" "${TMP_ROOT}/stderr"; then
  echo "FAIL: strong-linkage rejection did not name the linkage in stderr" >&2
  exit 1
fi

# 8. Gate set: otool failing is an error, not a silent pass and not "not linked"
DEVTYPE_REQUIRE_FOUNDATION_MODELS=1 OTOOL="${MOCK_OTOOL_BROKEN}" expect_fail "otool failure rejected" "${MOCK_APP_PASS}"
if ! grep -q "failed to inspect" "${TMP_ROOT}/stderr"; then
  echo "FAIL: otool failure was not reported as an inspection failure" >&2
  exit 1
fi

harness_summary "release capabilities"
