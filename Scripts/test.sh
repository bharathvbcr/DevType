#!/usr/bin/env bash
# Run SwiftPM tests with a full Xcode toolchain when available.
# Default macOS `xcode-select` may point at Command Line Tools only — swift test
# then fails; prefer Xcode.app's DEVELOPER_DIR.
#
# `./Scripts/test.sh --coverage` (or `--enable-code-coverage`) instruments
# Swift *and* DevTypeSafety.m, then writes coverage/lcov.info for GitPulse.
# Plain `./Scripts/test.sh` is unchanged: no coverage flags, no export.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  fi
fi

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  echo "==> DEVELOPER_DIR=${DEVELOPER_DIR}"
fi

want_coverage=0
scratch="${ROOT}/.build"
prev=""
for arg in "$@"; do
  case "$arg" in
    --coverage|--enable-code-coverage) want_coverage=1 ;;
    --disable-code-coverage) want_coverage=0 ;;
    --scratch-path=*) scratch="${arg#--scratch-path=}" ;;
  esac
  if [[ "${prev}" == "--scratch-path" ]]; then
    scratch="${arg}"
  fi
  prev="${arg}"
done

if [[ "${want_coverage}" -eq 0 ]]; then
  exec swift test "$@"
fi

if [[ "${scratch}" != /* ]]; then
  scratch="${ROOT}/${scratch}"
fi

forward=()
has_enable=0
has_profile=0
for arg in "$@"; do
  if [[ "${arg}" == "--coverage" ]]; then
    continue
  fi
  if [[ "${arg}" == "--enable-code-coverage" ]]; then
    has_enable=1
  fi
  if [[ "${arg}" == "-fprofile-instr-generate" ]]; then
    has_profile=1
  fi
  forward+=("${arg}")
done
if [[ "${has_enable}" -eq 0 ]]; then
  forward+=(--enable-code-coverage)
fi
if [[ "${has_profile}" -eq 0 ]]; then
  # SwiftPM coverage does not instrument the ObjC trampoline. Without these
  # flags, GitPulse's native family stays empty even when Swift LCOV is present.
  forward+=(-Xcc -fprofile-instr-generate -Xcc -fcoverage-mapping)
fi

echo "==> Coverage run (Swift + DevTypeSafety.m) → coverage/lcov.info"
test_ec=0
swift test "${forward[@]}" || test_ec=$?

bin_dir="${scratch}/debug"
if [[ ! -f "${bin_dir}/codecov/default.profdata" ]]; then
  bin_dir="${scratch}/$(uname -m)-apple-macosx/debug"
fi

export_ec=0
"${ROOT}/Scripts/export-lcov.sh" --bin-dir "${bin_dir}" || export_ec=$?
if [[ "${test_ec}" -ne 0 ]]; then
  exit "${test_ec}"
fi
exit "${export_ec}"
