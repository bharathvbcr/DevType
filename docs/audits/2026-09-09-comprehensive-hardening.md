# Delivery and session hardening audit — 2026-09-09

This audit continues [the diagnostic follow-up](2026-09-09-diagnostic-followup.md) in `/Users/bharath/Code/apps/DevType`, based on `10b37d40339cc1e50e7298927ac84aae1fce4595`. It incorporates that pass's changes. The similarly named `/Users/bharath/Code/devtools/DevType` directory contains workspace metadata rather than the Git checkout.

## Scope and evidence standard

The audit followed matching/input buffers into erase planning, AX evidence, injection lifetime, voice recognition admission, transcript assembly, live/final delivery, cancellation, diagnostics and recovery. The complete local test suite also exercises providers, correction validation, persistence, macros, permissions and release fixtures. Passing those tests is evidence for their asserted contracts, not proof that every line or every native application was exercised.

The initial focused baseline passed 156 existing/current tests. Every issue below was attacked through a failing behavioral regression before its corresponding fix; read/delivery seams were extracted without changing the behavior where native UI access otherwise prevented deterministic testing. No test posts real keystrokes to prove these new delivery contracts.

## Verified defects and repairs

| Boundary | Reproduced defect | Canonical repair / regression |
|---|---|---|
| Erase planning | Contradictory UTF-16/backspace counts passed even with matching text, missing AX evidence or a no-op fast path. | `ErasePlan.validationFailure`, checked by the pure evaluator and executor before reads/mutation and again before posting; `ErasePlanIntegrityTests`. |
| Speech revisions | Batch revisions could move backward; live duplicates/conflicting equal revisions and final-to-volatile downgrades were inconsistently accepted. | `SpeechSegment.canReplace` shared by reducer/assembler. Equal-revision final promotion remains supported; `SpeechSegmentIntegrityTests`. |
| Assembler admission | A rejected overflow could still seal prior text; a silent endpoint could seal text while reporting no change. | Validate before mutation and report commit-barrier changes accurately; existing silent-endpoint behavior and all prior integration tests retained. |
| Completion evidence | Batch completion repair silently considered only the live assembler's first 512 segments. | Join every accepted batch segment from the reducer's canonical ordered state; a 600-segment regression checks the complete result. |
| Provider storage | Generic admission retained oversized segment/completion payloads without the native adapter's bounds. | Shared result/alternative limits, identity and metadata validation, aggregate retention limits, and explicit terminal failure before delivery or persistence. |
| Queued live delivery | 2,000 cancelled-session segments still ran after retirement while main was busy. | Capture the originating task bag and recheck it at dispatch; preserve FIFO within the admitted session. |
| Final-delivery admission | A call from an old session could cross the main-actor hop into a replacement session and inject using its validity token. | Bind session ID, generation and lease at delivery entry, before admitting work; preserve explicit target-mismatch reporting. |
| Terminal delivery | A queued live segment could append after final delivery returned but before coordinator retirement. | Explicit live/finalizing/finished delivery phases close live admission, including recognized-state mutation, until another session begins. |
| Queue retention | A blocked main queue retained every large revision despite bounded reducer state. | Reserve/release pending delivery bytes and callback count in `SessionTaskBag`; overflow causes a typed failure and cleanup, not silent truncation. |
| Session synchronization | Concurrent generation reads raced with retirement; Thread Sanitizer reported three data-race warnings and terminated the test process. | Synchronize the public generation getter with the same lock as mutation. |
| Cancellation reentrancy | Retirement held its lock while invoking `Task.cancel()`. A cancellation handler reading session state deadlocked. | Publish retirement and detach tasks under lock, then invoke cancellation handlers after unlocking. |
| Voice edit ordering | Three immediate live revisions submitted three overlapping injections; the real pipeline cancels the preceding operation. | `VoiceInsertionService` admits one live edit at a time and computes the next diff from the latest bounded assembler state only after completion. A 10,000-revision test observes two edits. |
| Delivery truthfulness | Final delivery returned a success-shaped receipt before its injection outcome; failure receipts became inserted outcomes. | Join live work, await the pipeline's terminal result, map evidence into a receipt, validate receipt ownership, and retain non-delivery as `savedButNotInserted`. Duplicate/late callbacks cannot overwrite a newer session. |
| Suppressed final edit | A reconciler no-op caused by its length/commit protection was reported as an inserted final transcript. | Only an already-matching owned transcript qualifies for no-op delivery; a suppressed proposal records non-delivery while retaining existing text. |
| Input buffers | Negative layout capacity crashed with `Can't remove more items from a collection than it has`; combining marks bypassed grapheme-based retention; nonfinite hold durations could disable expiry. | Clamp layout capacity to zero, bound type-ahead payload in UTF-16 units and normalize nonfinite intervals; `InputBufferBoundaryTests`. |

The first pass additionally isolated default XCTest persistence and added bounded exact-range AX corroboration for the diagnostic's stale-value shape. Those regressions remain part of the full suite.

## Enforced bounds and preserved behavior

- Known erase text must agree with both deletion unit systems. Count-only plans retain their documented best-effort behavior but cannot carry contradictory counts. Invalid plans cannot use the user-default escape hatch to bypass structural validation.
- Speech text plus alternatives: 131,072 UTF-8 bytes per result; at most 32 alternatives; segment IDs: 1–256 UTF-8 bytes. Timestamps must be finite/nonnegative and supplied confidences finite in `[0, 1]`.
- Retained segment text, alternatives and IDs: 1,048,576 bytes; 512 live or 4,096 batch segments. Completions are independently bounded before reconciliation/persistence. The existing native analyzer references the shared limits.
- Pending main-queue delivery: 1,048,576 bytes and 4,096 callbacks per bag. Reservations remain accounted for through cancellation until queued callbacks drain. A reservation failure fails the session visibly.
- Live injection: one outstanding edit, with intermediate recognizer revisions coalesced in the assembler. Final delivery has one owner and joins pending live delivery. The existing injection watchdog remains the completion deadline, and the caller's session validity participates in its posting guards.
- A refused live edit uses the existing recovery policy. An uncertain failed post stops further writes for that session. Cancellation while a proposal is outstanding preserves text rather than guessing at an undo; subsequent completion cannot advance a replacement session's ownership.
- Type-ahead: existing 24-grapheme/default 350 ms policy plus a 4,096 UTF-16-unit ceiling. Overflow flushes exactly the admitted text once and passes the current event through. Layout capacity zero retains no events.
- Missing AX evidence and posted-but-unverified pastes remain explicitly unverified. Neither is elevated to physical delivery proof.

Security impact: these changes validate inputs, bound retention and prevent stale document writes. They add no dependency, network destination, permission grant, authentication bypass, secret migration or broader access. Existing Keychain authorization and privacy routing remain intact. New failure messages describe categories/counts, not recognized or typed content. Existing opt-in voice tracing retains its separate content policy.

## Verification record

33 additional regression tests accompany this pass, besides the first pass's 12. Production changes across both passes add 536 lines and remove 222. No existing tests were deleted or weakened.

| Run / log under `/tmp` | Observed result |
|---|---|
| `devtype-comprehensive-baseline.log` | 156 tests passed before this pass. |
| `devtype-comprehensive-red.log` | 11 tests, 64 failing assertions: invalid erase plans, revision/assembler defects, oversized segment and stale queued delivery. |
| `devtype-comprehensive-red2.log` | 15 tests, 14 failing assertions, including buffer bounds, batch evidence truncation and failed-receipt classification. |
| `devtype-comprehensive-delivery-red.log` | Two tests, nine failures: premature/incorrect final receipts and overlapping live writes. |
| `devtype-comprehensive-layout-red.log` | Isolated test process crashed on negative capacity with the collection-removal fatal error. |
| `devtype-comprehensive-generation-tsan-red.log` | Thread Sanitizer detected three races in concurrent generation reads/retirement; process exited with signal 6. The earlier read-only race probe was optimized away; consuming the read in an assertion made this test meaningful. |
| `devtype-comprehensive-tsan-red.log` | Oversized completion produced three failing assertions before completion admission was bounded. |
| `devtype-comprehensive-queue-red.log` | One failing assertion: 100 large queued revisions were admitted rather than seven within the byte budget. |
| `devtype-comprehensive-suppression-red.log` | Two failing assertions: a suppressed final proposal returned paste evidence and a nonzero delivered length. |
| `devtype-comprehensive-cancel-red.log` | Cancellation-handler and retirement expectations timed out, reproducing lock reentrancy deadlock. |
| `devtype-comprehensive-handoff-red.log` | Three failing assertions: an old session's final call injected and claimed ownership inside a newer bound session. The follow-up run also checked and restored target-mismatch classification. |
| `devtype-comprehensive-terminal-red.log` | Three failing assertions: a completed session resumed live typing before its coordinator retired the bag. |
| `devtype-comprehensive-suite1.log` | 2,893 tests, six skips, one failure. The failure exposed target-mismatch classification after prior session state and was fixed; five skips were optional benchmarks disabled in this intermediate run. |
| `devtype-comprehensive-tsan-final.log` | 81 tests passed under Thread Sanitizer, including concurrent retirement, cancellation reentrancy, handoff, queue bounds and delivery lifecycle. No sanitizer warnings. |
| `devtype-comprehensive-asan-final.log` | 243 focused tests passed under Address Sanitizer, with no sanitizer error. |
| `devtype-comprehensive-ci-verified.log` | Full local CI exited 0. 2,908 tests, zero failures, one skip: `WhisperServerControllerTests.testStartAndStopRoundTrip` reports that whisper.cpp or its model is not installed. All five optional benchmarks ran with `DEVTYPE_BENCH=1`; shell/plist/release fixtures, debug/release builds, packaging, strict signature verification and mandatory weak Foundation Models linkage passed. |

Two CI attempts (`devtype-comprehensive-ci.log` and `devtype-comprehensive-ci-final.log`) were deliberately stopped during tests to add the handoff and terminal-admission regressions found in final review. Neither is counted as a passing CI run. The subsequent `devtype-comprehensive-ci-verified.log` covers the final production/test state and passed every enabled gate.

The resulting `.build/DevType.app` was `0.1.9+dirty` (175), signed by the existing Apple Development identity. Strict codesign validation and the designated requirement passed. Hardened Runtime is disabled and notarization was not performed: this is a local development package. Final edits after CI only updated documentation; production/test sources were unchanged. `git diff --check` passed.

The subsequent user-requested installation placed that exact tested binary at `/Applications/DevType.app` as `0.1.9+dirty` (175). The installer preserved the previous app under `build/.quarantine`, retained the signing requirement without resetting TCC, and quarantined the duplicate build bundle. The installed executable hash and signature passed verification, and one process from the installed path remained running throughout a ten-second launch check. The installation log is `/tmp/devtype-install-2026-09-09.log`; this record describes that installation before the later clean v0.1.9 commit/tag/install request.

SHA-256 fingerprints of the real application's `voice-terminal-manifest.json` and `voice-trace.jsonl` still match `/tmp/devtype-diag-user-files-before.json` after the complete suite. Test diagnostics did not alter either existing file; their contents were not printed.

Reproduction commands, from the canonical checkout:

```sh
DEVTYPE_SKIP_AUTO_CERT=1 DEVTYPE_REQUIRE_FOUNDATION_MODELS=1 DEVTYPE_BENCH=1 ./Scripts/ci-local.sh
./Scripts/test.sh --sanitize thread --filter 'VoiceQueuedDeliveryTests|VoiceDeliveryIntegrityTests|VoiceCaptureRaceTests|SpeechSegmentIntegrityTests|InjectionLifetimeTests|SessionWatchdogTests|VoiceSessionRedesignTests'
./Scripts/test.sh --sanitize address --filter 'Erase|TypeAhead|CharacterRing|Layout|InputBufferBoundary|VoiceDeliveryIntegrity|SpeechSegmentIntegrity|VoiceQueued|LiveTypingIntegrationStress|VoicePipelineStress|TranscriptDiff'
```

Run these sequentially: sanitizer configurations share SwiftPM's build directory. The final CI run rebuilds the ordinary debug/release products after sanitizer testing.

## Coverage limits and remaining live checks

**Verified:** the repo map was read first, the graph was rebuilt/migrated to its current schema, and GitPulse reported one dirty worktree with no overlapping sessions. The graph impact queries returned 80 of 1,031 erase dependents and 80 of 2,466 voice dependents at depth three, both truncated/incomplete. They guided inspection but do not establish complete caller coverage; source inspection and the full suite supplied additional evidence.

The final index rebuild covered 545 files. GitPulse can read the graph, but its binary lacks the parsing frontend needed to attest analyzer freshness; that facet remains explicitly unverified. Collision scanning covered the one worktree without truncation or missed worktrees and found no overlapping edits.

**Unverified:** the exact GitPulse editor/physical typing sequence from the report, real microphone devices/permission transitions, actual clipboard consumption in each host, live cloud/model outputs and older supported macOS/toolchain combinations. Synthetic AX and injection doubles verify decisions, ordering and bookkeeping, not native insertion into every application. Optional local Whisper integration requires the executable/model to be installed.

The diagnostic's unreadable master key (`-25293`) still requires the installed app's **Preferences > Advanced > Repair Secret Storage** authorization flow. Keychain repair was not attempted, and no public release was published. Local tests and sanitizers cannot establish universal correctness across third-party editors or future operating-system changes.
