#!/usr/bin/env bash
# Drop SwiftPM clang module caches compiled in a different checkout.
#
# Every PCM embeds the absolute ModuleCache path it was built with. After a
# checkout moves, clang aborts C/ObjC compiles with "was compiled with module
# cache path … but the path is currently …", usually buried under a
# _DarwinFoundation cascade. A PCM that names this checkout is left alone.
#
# Usage: purge-stale-module-cache.sh [build-dir]
# build-dir defaults to ./.build, relative to the caller's working directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${1:-.build}"

if [[ ! -d "${BUILD}" ]]; then
  echo "  ok: no stale module caches"
  exit 0
fi

stale_pcm_found=0
stale_pcm=""
# Bound the scan: the first 200 PCMs catch a wholesale stale cache without
# grepping every object file in a multi-gigabyte .build.
while IFS= read -r pcm; do
  [[ -f "${pcm}" ]] || continue
  if ! grep -aqF -- "${ROOT}" "${pcm}" && grep -aqF -- "/.build/" "${pcm}"; then
    stale_pcm="${pcm}"
    stale_pcm_found=1
    break
  fi
done < <(find "${BUILD}" -type f -name '*.pcm' 2>/dev/null | head -n 200)

if [[ "${stale_pcm_found}" -eq 1 ]]; then
  echo "  stale PCM (built elsewhere): ${stale_pcm}"
  # One directory at a time. `find -exec {} +` asks the OS for ARG_MAX, which
  # a restricted environment can refuse, and a ModuleCache tree is small.
  while IFS= read -r dir; do
    rm -rf "${dir}"
  done < <(find "${BUILD}" -type d -name ModuleCache -prune -print)
  echo "  purged ModuleCache dirs; they will be rebuilt during this run"
else
  echo "  ok: no stale module caches"
fi
