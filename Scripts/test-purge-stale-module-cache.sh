#!/usr/bin/env bash
# A PCM compiled outside this checkout is deleted; one that names it is kept.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devtype-purge-pcm.XXXXXX")"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# shellcheck source=Scripts/lib-shell-test-harness.sh
source "${ROOT}/Scripts/lib-shell-test-harness.sh"
harness_subject "${ROOT}/Scripts/purge-stale-module-cache.sh" "${TMP_ROOT}"

expect_ok "missing build directory" "${TMP_ROOT}/does-not-exist"
if ! grep -q 'ok: no stale module caches' "${TMP_ROOT}/stdout"; then
  echo "FAIL: missing directory did not report a clean cache" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: missing directory reports clean"
  PASS=$((PASS + 1))
fi

fresh="${TMP_ROOT}/fresh"
mkdir -p "${fresh}/ModuleCache"
printf 'module cache at %s/.build/ModuleCache\n' "${ROOT}" > "${fresh}/ModuleCache/keep.pcm"
expect_ok "pcm from this checkout" "${fresh}"
if [[ ! -f "${fresh}/ModuleCache/keep.pcm" ]]; then
  echo "FAIL: a PCM that names this checkout was deleted" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: local PCM kept"
  PASS=$((PASS + 1))
fi

unrelated="${TMP_ROOT}/unrelated"
mkdir -p "${unrelated}/ModuleCache"
printf 'not a module cache path\n' > "${unrelated}/ModuleCache/other.pcm"
expect_ok "pcm without a build path" "${unrelated}"
if [[ ! -f "${unrelated}/ModuleCache/other.pcm" ]]; then
  echo "FAIL: a PCM that is not a foreign build cache was deleted" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: unrelated PCM kept"
  PASS=$((PASS + 1))
fi

stale="${TMP_ROOT}/stale"
mkdir -p "${stale}/ModuleCache"
printf 'was compiled at /tmp/other-checkout/.build/ModuleCache\n' > "${stale}/ModuleCache/stale.pcm"
expect_ok "pcm from another checkout" "${stale}"
if [[ -d "${stale}/ModuleCache" ]]; then
  echo "FAIL: foreign ModuleCache was kept" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: foreign ModuleCache removed"
  PASS=$((PASS + 1))
fi
if ! grep -q 'purged ModuleCache dirs' "${TMP_ROOT}/stdout"; then
  echo "FAIL: purge did not announce itself" >&2
  FAIL=$((FAIL + 1))
else
  echo "ok: purge announced"
  PASS=$((PASS + 1))
fi

harness_summary "purge stale module cache"
