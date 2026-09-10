#!/usr/bin/env bash
# Contract tests for Scripts/export-lcov.sh. Does not run the Swift suite.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORTER="${ROOT}/Scripts/export-lcov.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devtype-export-lcov.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

PASS=0
FAIL=0

ENGINE="Sources/ExpanderEngine/Updates/AppVersion.swift"
CORE="Sources/DevTypeAppCore/AppDelegate.swift"
NATIVE="Sources/DevTypeSafety/DevTypeSafety.m"

write_lcov() {
  local dest="$1"
  shift
  {
    for rel in "$@"; do
      printf 'SF:%s/%s\n' "${ROOT}" "${rel}"
      printf 'DA:1,3\n'
      printf 'LF:1\n'
      printf 'LH:1\n'
      printf 'end_of_record\n'
    done
  } > "${dest}"
}

expect_ok() {
  local label="$1"
  shift
  if ! "${EXPORTER}" "$@" >"${TMP_ROOT}/stdout" 2>"${TMP_ROOT}/stderr"; then
    echo "FAIL: ${label} — expected success" >&2
    cat "${TMP_ROOT}/stderr" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  echo "ok: ${label}"
  PASS=$((PASS + 1))
}

expect_fail() {
  local label="$1"
  shift
  if "${EXPORTER}" "$@" >"${TMP_ROOT}/stdout" 2>"${TMP_ROOT}/stderr"; then
    echo "FAIL: ${label} — expected nonzero exit" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  echo "ok: ${label}"
  PASS=$((PASS + 1))
}

stderr_has() {
  local label="$1"
  local needle="$2"
  if ! grep -q "${needle}" "${TMP_ROOT}/stderr"; then
    echo "FAIL: ${label} — stderr did not contain '${needle}'" >&2
    cat "${TMP_ROOT}/stderr" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  PASS=$((PASS + 1))
}

VALID="${TMP_ROOT}/valid.info"
write_lcov "${VALID}" "${ENGINE}" "${CORE}" "${NATIVE}"
OUT="${TMP_ROOT}/out/lcov.info"
expect_ok "absolute SF paths rewrite to checkout-relative" \
  --from-lcov "${VALID}" --output "${OUT}"
if grep -q "^SF:/" "${OUT}"; then
  echo "FAIL: rewritten LCOV still has absolute SF paths" >&2
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
fi
for rel in "${ENGINE}" "${CORE}" "${NATIVE}"; do
  if ! grep -q "^SF:${rel}$" "${OUT}"; then
    echo "FAIL: rewritten LCOV missing SF:${rel}" >&2
    FAIL=$((FAIL + 1))
  else
    PASS=$((PASS + 1))
  fi
done
if ! grep -q "^DA:1,3$" "${OUT}"; then
  echo "FAIL: rewritten LCOV dropped DA records" >&2
  FAIL=$((FAIL + 1))
else
  PASS=$((PASS + 1))
fi

EMPTY="${TMP_ROOT}/empty.info"
: > "${EMPTY}"
expect_fail "empty LCOV is fatal" --from-lcov "${EMPTY}" --output "${TMP_ROOT}/empty-out.info"
stderr_has "empty LCOV names the emptiness" "empty LCOV"

NODA="${TMP_ROOT}/noda.info"
printf 'SF:%s/%s\nend_of_record\n' "${ROOT}" "${NATIVE}" > "${NODA}"
expect_fail "summary-only LCOV is fatal" --from-lcov "${NODA}" --output "${TMP_ROOT}/noda-out.info"
stderr_has "summary-only LCOV names DA records" "no DA line records"

NONATIVE="${TMP_ROOT}/nonative.info"
write_lcov "${NONATIVE}" "${ENGINE}" "${CORE}"
expect_fail "missing DevTypeSafety.m is fatal" --from-lcov "${NONATIVE}" --output "${TMP_ROOT}/nonative-out.info"
stderr_has "missing native names the file" "DevTypeSafety.m"

OUTSIDE="${TMP_ROOT}/outside.info"
printf 'SF:/tmp/not-this-repo.swift\nDA:1,1\nend_of_record\n' > "${OUTSIDE}"
expect_fail "SF outside the checkout is fatal" --from-lcov "${OUTSIDE}" --output "${TMP_ROOT}/outside-out.info"
stderr_has "outside path is named" "outside the checkout"

MISSING="${TMP_ROOT}/missing.info"
write_lcov "${MISSING}" "${ENGINE}" "${CORE}" "${NATIVE}" "Sources/DoesNotExist.swift"
expect_fail "SF for a missing source is fatal" --from-lcov "${MISSING}" --output "${TMP_ROOT}/missing-out.info"
stderr_has "missing source is named" "does not exist"

STALE_BIN="${TMP_ROOT}/stale-bin"
mkdir -p "${STALE_BIN}/codecov" \
  "${STALE_BIN}/DevTypePackageTests.xctest/Contents/MacOS" \
  "${STALE_BIN}/DevTypeSafety.build"
touch "${STALE_BIN}/codecov/default.profdata" \
  "${STALE_BIN}/DevTypePackageTests.xctest/Contents/MacOS/DevTypePackageTests" \
  "${STALE_BIN}/DevTypeSafety.build/DevTypeSafety.m.o"
MOCK_COV="${TMP_ROOT}/mock-llvm-cov"
cat > "${MOCK_COV}" <<'EOF'
#!/usr/bin/env bash
echo "warning: profile data may be out of date - object is newer" >&2
printf 'SF:/dev/null\nDA:1,1\nend_of_record\n'
exit 0
EOF
chmod +x "${MOCK_COV}"
LLVM_COV="${MOCK_COV}" expect_fail "stale profile is fatal" \
  --bin-dir "${STALE_BIN}" --output "${TMP_ROOT}/stale-out.info"
stderr_has "stale profile names the mismatch" "out of date"

echo "export-lcov tests: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
