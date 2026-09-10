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
for ((round = 1; round <= ROUNDS; round++)); do
  echo "==> Stress round ${round}/${ROUNDS}"
  if [[ "$round" == 1 ]]; then
    "$ROOT/Scripts/test.sh" --filter "$FILTER"
  else
    "$ROOT/Scripts/test.sh" --skip-build --filter "$FILTER"
  fi
done
echo "==> All ${ROUNDS} stress rounds passed"
