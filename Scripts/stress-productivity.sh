#!/usr/bin/env bash
# Repeat deterministic search, text/macro, input, and voice lifecycle stress suites.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUNDS="${DEVTYPE_STRESS_ROUNDS:-20}"
if [[ ! "$ROUNDS" =~ ^[1-9][0-9]?$ && "$ROUNDS" != 100 ]]; then
  echo "error: DEVTYPE_STRESS_ROUNDS must be an integer from 1 to 100" >&2
  exit 2
fi

FILTER='Productivity|StructuredSnippetSearch|EraseUndoStress|ExpansionFuzz|LiveTypingIntegrationStress|VoiceQueuedDelivery|VoiceDeliveryIntegrity|VoiceCaptureRace|InputBufferBoundary'
ROUND_LOG="$(mktemp "${TMPDIR:-/tmp}/devtype-stress-round.XXXXXX")"
trap 'rm -f "$ROUND_LOG"' EXIT
for ((round = 1; round <= ROUNDS; round++)); do
  echo "==> Stress round ${round}/${ROUNDS}"
  if [[ "$round" == 1 ]]; then
    "$ROOT/Scripts/test.sh" --filter "$FILTER" 2>&1 | tee "$ROUND_LOG"
  else
    "$ROOT/Scripts/test.sh" --skip-build --filter "$FILTER" 2>&1 | tee "$ROUND_LOG"
    fi
  # SwiftPM may exit zero when the filter selects nothing. Require the XCTest parent
  # summary, not an arbitrary child suite or the separate Swift Testing zero-test footer.
  python3 - "$ROUND_LOG" <<'PY'
import pathlib
import re
import sys

output = pathlib.Path(sys.argv[1]).read_text(errors="replace")
summary = re.search(
    r"Test Suite 'Selected tests' passed[^\n]*\n\s*Executed ([1-9][0-9]*) tests?, with 0 failures \(0 unexpected\)",
    output,
)
if summary is None:
    sys.exit("error: stress round did not verify a nonzero, unskipped XCTest selection")
print(f"==> Verified {summary.group(1)} stress tests; no skips or failures")
PY
done
echo "==> All ${ROUNDS} stress rounds passed"
