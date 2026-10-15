#!/usr/bin/env bash
# Fail when a packaged bundle still carries the source Info.plist placeholders.
#
# package-app.sh stamps CFBundleShortVersionString from `git describe` and
# CFBundleVersion from the commit count. With no git metadata it copies
# Resources/Info.plist instead. Those source values are 0.1.7 and 2. The old
# guard looked for 1.0.0 and 1, which this repository does not use, so the
# no-git fallback passed.
#
# A checkout whose describe is exactly the placeholder and whose commit count
# is exactly the placeholder build cannot be told apart from that fallback.
# That pair is the placeholder. Git-describe builds, including "+dirty", pass.
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "usage: $0 <bundle-version> <bundle-build> <placeholder-version> <placeholder-build>" >&2
  exit 2
fi

BUNDLE_VERSION="$1"
BUNDLE_BUILD="$2"
PLACEHOLDER_VERSION="$3"
PLACEHOLDER_BUILD="$4"

if [[ -z "${BUNDLE_VERSION}" || -z "${BUNDLE_BUILD}" || -z "${PLACEHOLDER_VERSION}" || -z "${PLACEHOLDER_BUILD}" ]]; then
  echo "error: version arguments must be non-empty" >&2
  exit 1
fi

if [[ "${BUNDLE_VERSION}" == "${PLACEHOLDER_VERSION}" && "${BUNDLE_BUILD}" == "${PLACEHOLDER_BUILD}" ]]; then
  echo "error: version was not stamped from git (found source placeholder ${BUNDLE_VERSION} / build ${BUNDLE_BUILD})" >&2
  exit 1
fi

echo "verified stamped version: ${BUNDLE_VERSION} (build ${BUNDLE_BUILD})"
