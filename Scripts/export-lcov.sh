#!/usr/bin/env bash
# Write the LCOV GitPulse actually reads: per-file SF records and
# per-line DA hit counts, with source paths relative to the checkout.
#
# `swift test --enable-code-coverage` leaves llvm-cov JSON under .build, which
# GitPulse does not ingest, and Apple's llvm-cov ignores --path-equivalence here
# so SF lines stay absolute unless we rewrite them. SwiftPM also does not pass
# clang coverage flags to DevTypeSafety.m — the test wrapper injects those;
# this script refuses a report that silently dropped the native file.
#
# Usage:
#   Scripts/export-lcov.sh [--bin-dir DIR] [--output PATH] [--from-lcov FILE]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

die() { echo "error: $*" >&2; exit 1; }

BIN_DIR=""
OUTPUT="${ROOT}/coverage/lcov.info"
FROM_LCOV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir)
      [[ $# -ge 2 ]] || die "--bin-dir requires a directory"
      BIN_DIR="$2"
      shift 2
      ;;
    --bin-dir=*)
      BIN_DIR="${1#--bin-dir=}"
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a path"
      OUTPUT="$2"
      shift 2
      ;;
    --output=*)
      OUTPUT="${1#--output=}"
      shift
      ;;
    --from-lcov)
      [[ $# -ge 2 ]] || die "--from-lcov requires a file"
      FROM_LCOV="$2"
      shift 2
      ;;
    --from-lcov=*)
      FROM_LCOV="${1#--from-lcov=}"
      shift
      ;;
    -h|--help)
      echo "usage: $0 [--bin-dir DIR] [--output PATH] [--from-lcov FILE]"
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

default_bin_dir() {
  local scratch="${ROOT}/.build"
  local candidate
  for candidate in "${scratch}/debug" "${scratch}/$(uname -m)-apple-macosx/debug"; do
    if [[ -f "${candidate}/codecov/default.profdata" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

llvm_cov() {
  if [[ -n "${LLVM_COV:-}" ]]; then
    "${LLVM_COV}" "$@"
  else
    xcrun llvm-cov "$@"
  fi
}

RAW="$(mktemp "${TMPDIR:-/tmp}/devtype-lcov.XXXXXX")"
ERR="$(mktemp "${TMPDIR:-/tmp}/devtype-lcov-err.XXXXXX")"
trap 'rm -f "${RAW}" "${ERR}"' EXIT

if [[ -n "${FROM_LCOV}" ]]; then
  [[ -f "${FROM_LCOV}" ]] || die "LCOV input not found: ${FROM_LCOV}"
  cp "${FROM_LCOV}" "${RAW}"
else
  if [[ -z "${BIN_DIR}" ]]; then
    BIN_DIR="$(default_bin_dir)" \
      || die "no coverage profile under .build; run ./Scripts/test.sh --coverage"
  fi
  PROF="${BIN_DIR}/codecov/default.profdata"
  EXE="${BIN_DIR}/DevTypePackageTests.xctest/Contents/MacOS/DevTypePackageTests"
  OBJ="${BIN_DIR}/DevTypeSafety.build/DevTypeSafety.m.o"
  [[ -f "${PROF}" ]] || die "missing profile ${PROF}; run ./Scripts/test.sh --coverage"
  [[ -f "${EXE}" ]] || die "missing test binary ${EXE}"
  [[ -f "${OBJ}" ]] || die "missing instrumented ${OBJ}; run ./Scripts/test.sh --coverage so DevTypeSafety.m is compiled with clang coverage flags"

  if ! llvm_cov export --format=lcov \
    --instr-profile="${PROF}" \
    --object="${EXE}" \
    --object="${OBJ}" \
    --ignore-filename-regex='/\.build/|/Checkouts/|/Tests/' \
    >"${RAW}" 2>"${ERR}"; then
    die "llvm-cov export failed: $(cat "${ERR}")"
  fi
  if grep -q 'out of date' "${ERR}"; then
    die "profile data does not match the test binary (llvm-cov: out of date). Re-run ./Scripts/test.sh --coverage and do not invoke swift build before exporting."
  fi
fi

python3 - "${ROOT}" "${RAW}" "${OUTPUT}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
raw_path = Path(sys.argv[2])
output = Path(sys.argv[3])
text = raw_path.read_text()
if not text.strip():
    raise SystemExit("error: empty LCOV file")

out_lines = []
files = []
da = 0
hits = 0
for line in text.splitlines(True):
    newline = "\n" if line.endswith("\n") else ""
    body = line.rstrip("\n")
    if body.startswith("SF:"):
        raw = body[3:]
        path = Path(raw)
        if path.is_absolute():
            try:
                rel = path.resolve().relative_to(root)
            except ValueError as exc:
                raise SystemExit(f"error: coverage path is outside the checkout: {raw}") from exc
        else:
            rel = Path(raw)
        resolved = (root / rel).resolve()
        try:
            rel = resolved.relative_to(root)
        except ValueError as exc:
            raise SystemExit(f"error: coverage path is outside the checkout: {raw}") from exc
        if not resolved.exists():
            raise SystemExit(f"error: coverage source does not exist: {rel}")
        rel_s = rel.as_posix()
        files.append(rel_s)
        out_lines.append(f"SF:{rel_s}{newline}")
        continue
    if body.startswith("DA:"):
        da += 1
        try:
            count = int(body.split(",", 1)[1])
        except (IndexError, ValueError) as exc:
            raise SystemExit(f"error: malformed DA record: {body}") from exc
        if count > 0:
            hits += 1
    out_lines.append(line)

if da == 0:
    raise SystemExit("error: LCOV has no DA line records (summary-only output is not coverage)")

if "Sources/DevTypeSafety/DevTypeSafety.m" not in files:
    raise SystemExit("error: LCOV is missing Sources/DevTypeSafety/DevTypeSafety.m (native coverage was not exported)")
if not any(name.startswith("Sources/ExpanderEngine/") for name in files):
    raise SystemExit("error: LCOV is missing Sources/ExpanderEngine/")
if not any(name.startswith("Sources/DevTypeAppCore/") for name in files):
    raise SystemExit("error: LCOV is missing Sources/DevTypeAppCore/")

output.parent.mkdir(parents=True, exist_ok=True)
output.write_text("".join(out_lines))
miss = da - hits
print(f"==> Wrote {output} ({len(files)} files, {hits} hit / {miss} miss)")
PY
