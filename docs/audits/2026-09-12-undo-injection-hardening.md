# Undo and text-injection hardening audit

Scope: the September 12 diagnostic report, Backspace expansion undo, shared erase/injection behavior, Preferences, and diagnostic truthfulness. Baseline: `9a1dd68`. Changes are isolated on `codex/undo-hardening`; concurrent secret-model changes in the main checkout are outside this patch.

## Findings and changes

| Finding | Evidence and resolution |
| --- | --- |
| Undo bypassed the shared injection lifetime | The old `performUndo` posted through its own AX/erase/clipboard chain. It now prepares a request for `enqueueInjection`, inheriting target checks, cancellation, timeout, host capability policy, clipboard ownership/residency, and delivery evidence. |
| Queued undo could outlive its input/focus evidence | A claimed record now carries its original PID/element, input revision, and undo generation. Input, clearing, a new expansion, engine stop/pause, and disabling the setting revoke stale work. Tests drive the actual token through delayed erase and command-chord callbacks. |
| Matching bypasses could preserve stale undo | Autorepeat, disabled/secure/suspended matching, and application activation now invalidate undo. Ordinary later input still permits bounded widening only when field evidence supports it. |
| Undo reported posting as confirmed success | Removing its Boolean clipboard path preserves the shared `postedUnverified` result until delivery is observed. Successful and unverified undo retain undo-specific telemetry paths. |
| Every refusal claimed the target text changed | Finite diagnostic messages now distinguish unreadable text after input, selection, changed context, and an otherwise unverifiable reversal. Raw field text is not included. |
| Input counts could crash on overflow | The pre-fix `Int.max + 1` regression terminated XCTest with signal 5. Delivery/replay and post-expansion counters now use the existing saturating arithmetic owner. |
| Public bounds could be bypassed | Zero/negative widening limits used to search one character; arbitrarily large limits and freshness windows bypassed the advertised caps. Tests first reproduced these failures. Widening is capped at 16 UTF-16 units, freshness at five seconds, and copied field data at the bounded caret window. |
| Repeated text made substring-based widening ambiguous | The pre-fix `aa` followed by another `aa` produced an erase of `aaa` and restored `xa`, losing ownership of the original occurrence. Undo now anchors widening to the recorded insertion position. Missing origin evidence and multiple unanchored matches refuse; repeated ASCII, emoji, and combining text have positive preservation tests. |
| Erase geometry could split Unicode characters | Pre-fix tests approved slices inside surrogate pairs, combining characters, and joined emoji. Boundary validation belongs in the shared erase precondition and undo widening, before lossy UTF-16 decoding can become false evidence. Alternate range corroboration must preserve this refusal. |
| No setting to disable automatic reversal | General → Typing now contains an accessible, localized “Undo expansion with Backspace” switch. Default on preserves existing behavior. Off is persisted, prevents recording/claiming undo, clears stale records, and revokes queued undo even if immediately re-enabled. |

## Preserved invariants

- No record is claimed for an unknown/different process, an expired record, disabled undo, or a record already consumed.
- No inverse undo record is created by undo itself.
- Text typed after expansion is preserved only with a recorded insertion position and a matching bounded field window. An unobserved edit cannot authorize widening.
- Active selections retain their delete-selection meaning; undo does not collapse them into a larger destructive erase.
- An unreadable field plus intervening input never authorizes blind undo, including at the final asynchronous erase gate.
- Strict undo cannot borrow a typed-trigger caret vouch or bypass verification through the developer erase-check override.
- A failed preflight can return the swallowed Backspace only while the source remains current. After mutation or a context change, an extra delete is unsafe and is not replayed.
- Native application Undo, snippet-editor Undo, and “Undo last AI” remain separate features.
- The patch adds no dependencies, permissions, authentication bypass, network services, or secret-store mutation.

## Validation record

**Verified:** the initial unmodified baseline passed 578 selected tests. New regressions then produced 14 assertion failures across five tests and an independent overflow crash (signal 5). Unicode regressions produced seven more assertion failures before the boundary fix. Separate regressions demonstrated that alternate range corroboration could bypass the Unicode refusal and that repeated text made widening ambiguous. The final focused suite passed 274 tests.

| Check on final source | Result |
| --- | --- |
| Full XCTest suite with optional benchmarks enabled | 3,128 executed, 3,127 passed, one explicit live-Whisper skip, zero failures |
| Thread Sanitizer | 490 selected tests passed; no race report |
| Address Sanitizer | 490 selected tests passed; no memory-error report |
| Native Preferences | Actual target/action, accessibility label, persistence, pane reload, and English/Korean/Japanese strings passed. English and Japanese rendered layouts inspected. |
| Release build, packaging, signing, and Foundation Models linkage | Full `ci-local.sh` passed, including shell/installer fixtures, debug and release builds, bundle verification, signature verification, and required weak framework linkage |
| Repeated stress run | 20 ordinary runs × 50 tests = 1,000 executions, zero failures; each run includes 12,000 seeded erase/widening cases and 3,200 concurrent claims |

The [native Preferences image](../../.build/undo-audit-evidence/preferences.png) comes from the XCTest host, not an installed release. Its version and engine status are harness state. A test-only double release during window teardown was reproduced and corrected with the repository's existing window ownership convention.

`UndoLifecycleStressTests` includes 100 rounds of 32 concurrent claims, delayed erase/post cancellation, setting off/on transitions, changed process identity, saturated counters, and a million-character field. Existing erase fuzz tests cover 4,000 precondition cases and 8,000 widening cases, including constructed positives so refusal alone cannot make the suite pass. Repeating these fixed seeds exercises timing stability; it does not multiply the number of distinct seeded inputs.

All five optional benchmark tests ran. Example observations: conflict checks for 2,000 snippets took 4.51 ms; 20,000 matcher calls took 7.07 ms; 1,000 cached searches over 2,000 snippets took 767.15 ms. These are measurements from one local run, not enforced performance thresholds or production latency guarantees.

Commands used from this worktree:

```sh
./Scripts/test.sh --filter 'Undo|Erase|SourceContractTests|DiagnosticReportTests|ExpansionUndoPreferencesTests'
./Scripts/test.sh --sanitize thread --filter 'UndoLifecycleStressTests|UndoAuditRegressionTests|Erase|DeliveryWindow|BackspaceIntegrity|InjectionLifetime|TypeAhead|HID|Selection|Clipboard|SourceAppDelivery'
./Scripts/test.sh --sanitize address --filter 'UndoLifecycleStressTests|UndoAuditRegressionTests|Erase|DeliveryWindow|BackspaceIntegrity|InjectionLifetime|TypeAhead|HID|Selection|Clipboard|SourceAppDelivery'
DEVTYPE_BENCH=1 DEVTYPE_REQUIRE_FOUNDATION_MODELS=1 DEVTYPE_UNDO_QA_OUTPUT=/tmp/devtype-undo-final-preferences.png ./Scripts/ci-local.sh
```

The ordinary CI build follows sanitizer builds before any `--skip-build` repetition. Existing selector-construction warnings in `AppCoreFlowCoverageTests.swift` remain; they did not fail compilation and this patch does not alter those tests.

Local evidence is retained in `.build/undo-audit-evidence/`: [full CI](../../.build/undo-audit-evidence/devtype-undo-final-ci.log), [Thread Sanitizer](../../.build/undo-audit-evidence/devtype-undo-final-tsan.log), [Address Sanitizer](../../.build/undo-audit-evidence/devtype-undo-final-asan.log), and fail-before-fix regression logs. [Repeated-run evidence](../../.build/undo-audit-evidence/devtype-undo-final-repeat.log) records all 20 runs. These generated artifacts are ignored by Git. The rebuilt source index covered 579 files with zero parse failures or refused files; this is indexing coverage, not proof that every call was resolved or every behavior was manually audited.

Production changes add 408 lines and remove 301, including removal of the independent Undo mutation chain. The validated bundle is `.build/DevType.app`, version `1.0.0+dirty` build 185. This is a local development build; no notarized distribution, installation, publication, or merge into the concurrently edited main checkout is claimed.

## Report triage and remaining qualification

| Report area | Verified interpretation / qualification |
| --- | --- |
| Permissions and event tap | The supplied snapshot reports granted Listen/AX/Post permissions and a running tap. It does not justify a TCC reset. |
| AI selection/inference | Three initial AX no-focus reads were followed by three clipboard captures; three transforms succeeded. These are separate from paste delivery proof. |
| Cross-app paste | Five posted-but-unverified attempts cannot establish success or failure in the target editor. Real Codex/Claude/native-editor round trips remain a physical qualification step. |
| Secret storage | The report shows an unreadable master key, no sealed archive entries, and five Keychain-resident secrets. Interactive authorization uses the existing Repair Secret Storage action. No authorization or secret data was changed by this audit. |
| Voice | The retained failures are dated September 9. They are historical evidence, not proof of a current microphone/persistence failure. No live dictation/provider trial is claimed. |
| Scope of confidence | Automated tests establish the enumerated contracts for tested inputs and schedules. Already-posted OS events cannot be recalled; unobserved edits in opaque third-party fields cannot be proven absent. No finite suite establishes universal correctness across every application or macOS version. |

Physical acceptance should use disposable text in a native editor and in Codex/Claude: expand and immediately undo; type more text before undo; hold Backspace; switch app/field during an attempted undo; toggle undo off and confirm ordinary deletion; pause the engine; repeat with emoji and combining text. Record actual resulting text and delivery evidence. Do not use user documents or secret values as fixtures.
