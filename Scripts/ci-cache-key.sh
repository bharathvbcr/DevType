#!/usr/bin/env bash
# SwiftPM cache identity for hosted macOS runners.
#
# `runner.os` is "macOS" on both macos-14 and macos-26, so a key of
# `spm-${{ runner.os }}-…` with restore prefix `spm-macOS-` also matches
# `spm-macOS-macos26-…`. The macOS 14 job would then restore a build
# produced by the Foundation Models SDK. The runner label is the isolation
# boundary, and the Xcode version keeps a compiler change from reusing
# objects built by the previous image.
#
# Usage: ci-cache-key.sh <macos-14|macos-26> <xcode-version>
# Prints the cache id on stdout. The workflow appends the Package.resolved
# hash and uses "<id>-" as the restore prefix.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <macos-14|macos-26> <xcode-version>" >&2
  exit 2
fi

RUNNER="$1"
XCODE="$2"

case "${RUNNER}" in
  macos-14|macos-26) ;;
  *)
    echo "error: runner label must be macos-14 or macos-26 (got ${RUNNER})" >&2
    exit 1
    ;;
esac

if [[ ! "${XCODE}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "error: xcode version must be numeric (got ${XCODE})" >&2
  exit 1
fi

printf 'devtype-build-%s-xcode%s\n' "${RUNNER}" "${XCODE}"
