#!/usr/bin/env bash
# Publish only a verified draft. Failed uploads remain drafts and can be retried;
# an already-public release is immutable and must never be clobbered by a rerun.
# Usage: GH_REPO=owner/repo Scripts/publish-release.sh <tag> <dist-dir>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "error: $*" >&2; exit 1; }
[[ $# -eq 2 ]] || die "usage: $0 <vMAJOR.MINOR.PATCH> <dist-dir>"
TAG="$1"
DIST="$2"
[[ -n "${GH_REPO:-}" ]] || die "GH_REPO must identify the publication repository"
"${ROOT}/Scripts/release-preflight.sh" "${TAG}"
SELECTION="$("${ROOT}/Scripts/select-release-dmg.sh" "${DIST}" "${TAG#v}")"
LOCAL_DMG="$(sed -n 's/^dmg_path=//p' <<<"${SELECTION}")"
EXPECTED_DMG="DevType-${TAG#v}.dmg"
NOTES="${ROOT}/docs/releases/${TAG}.md"
HEAD_COMMIT="$(git -C "${ROOT}" rev-parse HEAD)"

verify_remote_tag() {
  local refs="" remote_commit attempt
  for attempt in 1 2 3 4 5; do
    if refs="$(git -C "${ROOT}" ls-remote --exit-code origin "refs/tags/${TAG}" "refs/tags/${TAG}^{}" 2>/dev/null)"; then
      break
    fi
    [[ "${attempt}" -lt 5 ]] || die "cannot resolve remote tag ${TAG} after bounded retries"
    sleep "$((attempt * 2))"
  done
  # Annotated tags peel to commits; lightweight tags already name the commit.
  remote_commit="$(awk -v tag="refs/tags/${TAG}" '
    $2 == tag { direct = $1 }
    $2 == tag "^{}" { peeled = $1 }
    END { print (peeled != "" ? peeled : direct) }
  ' <<<"${refs}")"
  [[ "${remote_commit}" == "${HEAD_COMMIT}" ]] \
    || die "remote tag ${TAG} does not match checkout ${HEAD_COMMIT}"
}
verify_remote_tag

# The Release workflow publishes on tag push and calls this same script. Running it by hand
# while that workflow is in flight puts two publishers on one immutable release. The
# already-published check below is the backstop, but it only fires *after* a draft has been
# created and a DMG uploaded — and whichever publisher loses the race dies with a confusing
# "already published" error on a release that is actually fine.
#
# Refuse early instead. Deliberately fail-open: a queued/in_progress run we can positively see
# blocks, and anything else (no gh, no network, an unparseable answer) warns and proceeds,
# because a guard that cannot read the truth must not be the thing that stops a release.
concurrent_release_run() {
  [[ -z "${GITHUB_ACTIONS:-}" ]] || return 1          # we ARE the workflow
  [[ "${DEVTYPE_ALLOW_CONCURRENT_PUBLISH:-0}" != "1" ]] || return 1
  local runs
  runs="$(gh run list --repo "${GH_REPO}" --workflow Release --branch "${TAG}" \
            --json status --jq '.[].status' 2>/dev/null)" || {
    echo "warning: could not check for an in-flight Release workflow — proceeding" >&2
    return 1
  }
  grep -qE '^(queued|in_progress|waiting|requested|pending)$' <<<"${runs}"
}
# Called only on the paths that are about to *mutate* the release. An already-published tag
# must still refuse with its own clearer error, and must still do so having made nothing but
# read-only API calls — `test_published_release_is_never_overwritten` pins that.
require_no_concurrent_release_run() {
  concurrent_release_run || return 0
  die "a Release workflow run for ${TAG} is already in flight — it publishes this tag itself.
       Wait for it, or set DEVTYPE_ALLOW_CONCURRENT_PUBLISH=1 to publish by hand anyway."
}

VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devtype-release-verify.XXXXXX")"
trap 'rm -rf "${VERIFY_DIR}"' EXIT

# Enumerate all pages, including drafts. API/auth failures must not be interpreted
# as an absent release; a capped list could miss an existing published version.
gh api --paginate "repos/${GH_REPO}/releases?per_page=100" \
  --jq ".[] | select(.tag_name == \"${TAG}\") | .draft" > "${VERIFY_DIR}/draft-state"
case "$(cat "${VERIFY_DIR}/draft-state")" in
  '')
    require_no_concurrent_release_run
    gh release create "${TAG}" --draft --verify-tag --target "${HEAD_COMMIT}" \
      --title "DevType ${TAG}" --notes-file "${NOTES}"
    ;;
  true)
    require_no_concurrent_release_run
    gh release edit "${TAG}" --verify-tag --title "DevType ${TAG}" \
      --notes-file "${NOTES}" --prerelease=false
    ;;
  false) die "${TAG} is already published; refusing to overwrite public release assets or notes" ;;
  *) die "ambiguous release state for ${TAG}" ;;
esac

uploaded=0
for attempt in 1 2 3 4 5; do
  if gh release upload "${TAG}" "${LOCAL_DMG}" --clobber; then
    uploaded=1
    break
  fi
  [[ "${attempt}" -lt 5 ]] || break
  sleep "$((attempt * 2))"
done
[[ "${uploaded}" -eq 1 ]] || die "could not upload ${LOCAL_DMG} after bounded retries"

verify_release() {
  local expected_draft="$1" downloaded=0 attempt view_ok=0
  for attempt in 1 2 3 4 5; do
    if gh release view "${TAG}" --json tagName,name,isDraft,isPrerelease,body,assets \
      > "${VERIFY_DIR}/release.json"; then
      view_ok=1
      break
    fi
    [[ "${attempt}" -lt 5 ]] || break
    sleep "$((attempt * 2))"
  done
  [[ "${view_ok}" -eq 1 ]] || die "could not retrieve release metadata for ${TAG} after bounded retries"
  # JSON parsing preserves trailing newlines and rejects missing/null booleans.
  # Shell command substitution silently strips newlines from both note bodies.
  python3 - "${VERIFY_DIR}/release.json" "${NOTES}" "${TAG}" "${expected_draft}" \
    > "${VERIFY_DIR}/asset-names.txt" <<'PY'
import json
from pathlib import Path
import sys

metadata_path, notes_path, tag, draft = sys.argv[1:]
metadata = json.loads(Path(metadata_path).read_text())
def require(condition, message):
    if not condition:
        sys.exit("error: " + message)
require(metadata.get("tagName") == tag, "release tag mismatch")
require(metadata.get("name") == "DevType " + tag, "release title mismatch")
require(metadata.get("isDraft") is (draft == "true"), "unexpected release draft state")
require(metadata.get("isPrerelease") is False, "unexpected prerelease state")
body = metadata.get("body")
require(isinstance(body, str) and body.encode("utf-8") == Path(notes_path).read_bytes(),
        "release body differs from curated notes")
assets = metadata.get("assets")
require(isinstance(assets, list), "release assets unavailable")
for asset in assets:
    require(isinstance(asset, dict) and isinstance(asset.get("name"), str), "invalid asset metadata")
    print(asset["name"])
PY
  "${ROOT}/Scripts/verify-release-asset-list.sh" "${EXPECTED_DMG}" < "${VERIFY_DIR}/asset-names.txt"

  for attempt in 1 2 3 4 5; do
    if gh release download "${TAG}" --pattern "${EXPECTED_DMG}" --dir "${VERIFY_DIR}" --clobber; then
      downloaded=1
      break
    fi
    [[ "${attempt}" -lt 5 ]] || break
    sleep "$((attempt * 2))"
  done
  [[ "${downloaded}" -eq 1 ]] || die "could not download ${EXPECTED_DMG} after bounded retries"
  "${ROOT}/Scripts/select-release-dmg.sh" "${VERIFY_DIR}" "${TAG#v}" >/dev/null
  cmp -s "${LOCAL_DMG}" "${VERIFY_DIR}/${EXPECTED_DMG}" \
    || die "uploaded DMG differs from the locally built artifact"
}

verify_release true
verify_remote_tag
undraft_ok=0
for attempt in 1 2 3 4 5; do
  if gh release edit "${TAG}" --draft=false --verify-tag; then
    undraft_ok=1
    break
  fi
  [[ "${attempt}" -lt 5 ]] || break
  sleep "$((attempt * 2))"
done
[[ "${undraft_ok}" -eq 1 ]] || die "could not undraft release ${TAG} after bounded retries"
verify_release false
echo "verified GitHub release ${TAG}: curated notes and ${EXPECTED_DMG} match"
