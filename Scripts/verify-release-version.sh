#!/usr/bin/env bash
# Verify that a packaged bundle's version is exactly the version named by a release tag.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <release-tag> <bundle-version>" >&2
  exit 2
fi

RELEASE_TAG="$1"
BUNDLE_VERSION="$2"

if [[ ! "${RELEASE_TAG}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: release tag '${RELEASE_TAG}' is not a strict vMAJOR.MINOR.PATCH tag" >&2
  exit 1
fi

EXPECTED_VERSION="${RELEASE_TAG#v}"
if [[ "${BUNDLE_VERSION}" != "${EXPECTED_VERSION}" ]]; then
  echo "error: bundle version '${BUNDLE_VERSION}' does not match release tag '${RELEASE_TAG}' (expected '${EXPECTED_VERSION}')" >&2
  exit 1
fi

echo "verified release version: ${RELEASE_TAG} -> ${BUNDLE_VERSION}"
