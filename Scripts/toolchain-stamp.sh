#!/usr/bin/env bash
# Echo a toolchain stamp, or refuse one that was never read.
#
# package-app.sh used to write the literal "unknown" (and "macosxunknown")
# when xcodebuild or xcrun produced nothing, and the package gate only checked
# that the plist keys existed. A missing tool then looked like a stamp.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 <stamp-name> <value>" >&2
  exit 2
fi

NAME="$1"
VALUE="$2"

case "${VALUE}" in
  ""|unknown|macosxunknown)
    echo "error: toolchain stamp ${NAME} was not read (value '${VALUE}')" >&2
    exit 1
    ;;
esac

printf '%s\n' "${VALUE}"
