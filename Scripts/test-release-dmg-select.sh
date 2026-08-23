#!/usr/bin/env bash
# Tests for Scripts/select-release-dmg.sh.
#
# Each case encodes a defect the release workflow's old inline locate step
# (`find dist -name "DevType-*.dmg" | head -n 1`) shipped with: zero matches
# handled, but multiple DMGs resolved to an arbitrary winner and any
# DevType-*.dmg name was accepted even when it disagreed with the released tag.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELECTOR="${ROOT}/Scripts/select-release-dmg.sh"

PASS=0
FAIL=0

TMPDIR_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devtype-select-dmg.XXXXXX")"
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

fixture() {
  local dir="${TMPDIR_ROOT}/$1"
  mkdir -p "${dir}"
  printf '%s' "${dir}"
}

expect_fail() {
  local label="$1"
  shift
  if "${SELECTOR}" "$@" >/dev/null 2>&1; then
    echo "FAIL: ${label} — selector exited 0, expected nonzero" >&2
    FAIL=$((FAIL + 1))
  else
    PASS=$((PASS + 1))
  fi
}

expect_ok() {
  local label="$1"
  local expected_name="$2"
  shift 2
  local out
  if ! out="$("${SELECTOR}" "$@" 2>&1)"; then
    echo "FAIL: ${label} — selector exited nonzero:" >&2
    echo "${out}" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  if [[ "$(grep -c '^dmg_path=' <<<"${out}")" -ne 1 || "$(grep -c '^dmg_name=' <<<"${out}")" -ne 1 ]]; then
    echo "FAIL: ${label} — output missing dmg_path/dmg_name lines: ${out}" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  if [[ "$(grep '^dmg_name=' <<<"${out}" | cut -d= -f2-)" != "${expected_name}" ]]; then
    echo "FAIL: ${label} — wrong dmg_name in output: ${out}" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  if [[ "$(grep '^dmg_path=' <<<"${out}" | cut -d= -f2-)" != /* ]]; then
    echo "FAIL: ${label} — dmg_path is not absolute: ${out}" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  PASS=$((PASS + 1))
}

# Case 1: dist directory missing entirely → fatal.
D="$(fixture case1-missing-dist)"
rm -rf "${D}"
expect_fail "missing dist dir is fatal" "${D}" "0.0.9"

# Case 2: empty dist → fatal (old step also caught this).
D="$(fixture case2-empty)"
expect_fail "no DMG found is fatal" "${D}" "0.0.9"

# Case 3: exactly one matching DMG → passes with absolute path + name.
D="$(fixture case3-single)"
printf 'dmg-bytes' > "${D}/DevType-0.0.9.dmg"
expect_ok "single matching DMG selected" "DevType-0.0.9.dmg" "${D}" "0.0.9"

# Case 4: single DMG whose name disagrees with the tag version → fatal.
# Old inline logic accepted this silently and published the mislabeled artifact.
D="$(fixture case4-version-drift)"
printf 'dmg-bytes' > "${D}/DevType-0.0.9-3-gabc123.dmg"
expect_fail "version-suffixed DMG rejected" "${D}" "0.0.9"

# Case 5: single DMG from an entirely different version → fatal.
D="$(fixture case5-wrong-version)"
printf 'dmg-bytes' > "${D}/DevType-0.1.0.dmg"
expect_fail "wrong-version DMG rejected" "${D}" "0.0.9"

# Case 6: two candidate DMGs → fatal, no arbitrary winner.
# Old inline logic picked whichever find listed first and uploaded it.
D="$(fixture case6-ambiguous)"
printf 'old' > "${D}/DevType-0.0.8.dmg"
printf 'new' > "${D}/DevType-0.0.9.dmg"
expect_fail "multiple DMGs rejected" "${D}" "0.0.9"

# Case 7: zero-byte DMG that otherwise matches → fatal.
D="$(fixture case7-empty-file)"
: > "${D}/DevType-0.0.9.dmg"
expect_fail "empty DMG rejected" "${D}" "0.0.9"

echo "select-release-dmg tests: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
