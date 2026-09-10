# Selection and delivery hardening audit — 2026-09-10

Base: `b6e5f97ca09c2705de87bc0a8017894a2c31862a`. Canonical checkout: `/Users/bharath/Code/apps/DevType`. The supplied `devtools/DevType` directory is staging, not the Git repository.

## Scope and diagnosis

The supplied diagnostic report recorded `outcome=noFocus app=com.openai.codex axCandidates=0`, `manualAX:unsupported` and `clipboard:unchanged`. No transform was attempted for that selection failure. This verifies that selection acquisition failed; it does not establish a model failure or identify why Codex did not publish a copy. The user's reported `⌘A` is Select All; DevType's explicit AI action is `⌘⌥A`.

The audit traced the actual selection, cache, clipboard, keyboard and final-delivery call chains and checked their existing contracts. Broader repository coverage comes from the complete test suite, build/release fixtures and stress groups for search, macros, erasure, input and voice lifecycle. This is not a claim to have inspected every source line or discovered every possible issue in every subsystem.

A separate task, “Increase test coverage artifacts”, changed the canonical checkout during testing. This audit continued in detached worktree `/private/tmp/devtype-selection-audit-yn2mbs7p`, containing only its own changes on the base commit. Other-task changes are preserved, and isolated results do not implicitly validate them.

## Reproduced defects and fixes

| Boundary | Reproduction on original behavior | Resulting contract |
| --- | --- | --- |
| Cache time validity | Future timestamps and non-finite maximum ages could authorize stale text indefinitely. | Both age and maximum age must be finite and nonnegative, with age within the limit. |
| Cache consumption | A reentrant consumer obtained the same publication twice; validation could clear a newly published selection. | Capture text/element together, validate outside the lock, then atomically claim only the exact validated generation. Missing element identity cannot satisfy a same-element request. |
| AX range arithmetic | A range beginning at 1 with length `Int.max` crashed the test process on integer overflow. | Check length against remaining UTF-16 capacity without adding untrusted integers. |
| Multi-range selection | Missing pieces produced partial text; expired deadlines still launched reads; separator characters escaped the aggregate limit. Background refresh supplied no deadline. | Refuse incomplete aggregates, stop at exhausted budgets (default 1.5 seconds without an enclosing deadline), cap at 64 ranges and include separators in the 200,000-character limit. |
| Clipboard read ownership | Focus/Secure Input changes after posting accepted text; foreign clipboard content could be attributed to the old source and overwritten during restoration. | Recheck source PID and Secure Input throughout polling and before/after lazy reads; require the observed clipboard change count to remain stable. Report `clipboardChanged` when superseded. |
| Copy permission gap | Revoking Post Events during the modifier pause still posted C and returned success. | Copy and paste share command-event construction, continuation and permission checks, and guaranteed Command-release event allocation before posting. |
| Keyboard lookup fallback | An unmapped character resolved to virtual key 9 (V), including callers requesting C. | Missing layout mappings return nil; each command supplies its own physical C/V fallback. |
| Delayed app activation | Fixed-delay AI/palette delivery proceeded when activation failed or another app took focus. | The shared `SourceAppDelivery` owner polls for the original PID, refuses unknown/self/terminated sources, aborts on third-app focus and passes a source predicate through the injection pipeline. Search uses the same owner after fill-in/authentication completes. |
| Test isolation | Running the AI plumbing and selection suites together left an undo row in palette tests, causing seven assertions to fail. | Palette context tests explicitly clear the shared undo fixture in setup and teardown; product ordering remains unchanged. |

The app-activation tests run the original fixed-delay code after extracting its I/O boundary unchanged. The HID permission tests similarly inject posting and pause operations into the original copy choreography. The multi-range tests exercise the original aggregation after separating AX I/O. These red runs demonstrate behavior failures, not merely missing symbols or compilation failures.

One existing cache test expected future timestamps to remain eligible. Its expectation was corrected because single-use and same-app checks do not bound cache lifetime after a clock rollback. All valid-age and original ownership tests remain. No test was removed.

## Preserved invariants and remaining limits

- Security impact: reads and event posting now require stricter live ownership and permission checks. No access is widened, authentication bypassed, credential/configuration changed, dependency added or network destination introduced. Existing secret authentication remains at `SecretMenuFlow`; this change only pins its eventual delivery target.
- Synthetic copy remains exclusive to explicitly authorized AI actions after a `noFocusedElement` result. Ordinary palette opening and readable-but-empty selections do not trigger it.
- Clipboard text retains copied/unverified provenance. An unchanged board is a failure. A superseding publication is not restored over. Snapshot limits remain eight items/four MiB; this is bounded preservation, not complete clipboard fidelity.
- The clipboard has no authenticated publishing-process identity. A third-party writer before the first observed change can still be indistinguishable from the requested copy. An AX-inaccessible app may implement Copy as copying the current line without a selection. These platform limitations are not converted into verified selection evidence.
- Source restoration permits at most 25 waits of 20 ms, activating once. The operating system may schedule later; 500 ms is the polling budget, not a hard wall-clock execution guarantee. Later pipeline gates retain target/operation checks.
- A synchronous native AX or lazy pasteboard call cannot be preempted by these Swift checks. AX messaging timeouts and cardinality limits bound requested work; the range deadline prevents subsequent pieces and rejects late results. The operating system remains responsible for an in-flight IPC call.
- App identity does not prove the original selection remained unchanged while a model or preview was open. The injection pipeline captures current field/range evidence and refuses later changes; weak-AX hosts still cannot provide complete field identity. Global keyboard events and focus observation cannot form an atomic transaction with another process.
- No installed application, user keyboard layout, clipboard selection, remote branch, release or signing identity is changed by this audit's implementation or tests. The prior branch-consolidation request was completed separately.

## Reproduction and verification evidence

Evidence is retained under `/Users/bharath/Code/apps/DevType/.git/selection-audit-20260910/`.

| Log | Verified result |
| --- | --- |
| `devtype-ai-audit-baseline-20260910.log` | Unmodified baseline: 2,949 tests, one missing-Whisper skip, zero failures; opt-in benchmarks enabled. |
| `devtype-selection-ownership-red.log` | Six original-behavior tests, ten failing assertions. |
| `devtype-selection-range-red.log` | Original range arithmetic terminated the test process with signal 5. |
| `hid-copy-red.log` | Five tests, three failing assertions in the two defective keyboard cases. |
| `range-budget-red.log` | Six tests, eight failing assertions against original aggregation. |
| `source-delivery-red.log` | Six tests, 24 failing assertions against the original fixed wait. |
| `background-budget-red.log` | Seven tests, two failing assertions showing the no-deadline background caller could exceed the read budget. |
| `broad-focused-green.log` | First broad run: 342 tests, seven palette-fixture assertions failed. This is failure evidence. |
| `broad-focused-green-2.log` | After fixes: 348 tests, zero skips/failures across selection, clipboard, HID, AI plumbing and source delivery. |

The first full CI run failed only the documentation-link contract because the new audit link preceded this file's creation (`local-ci-doc-link-failure.log`: 2,977 tests, one skip, one failure). That failure was fixed by supplying the actual report. The repeated full CI run passed 2,977 tests with one missing-Whisper skip, all release/installer/publication/coverage/runner fixtures, debug and release builds, packaging, strict signature validation, version stamping and mandatory weak Foundation Models linkage (`local-ci-first-candidate.log`). The later background-budget refinement adds one regression; its final-source checks are recorded separately below.

One earlier shared-checkout test attempt failed to compile another task's new `USKeyboardLayoutTests` (`cannot find 'kVK_ANSI_Space' in scope`). Its source was left to its owner; isolated validation excludes that unrelated file. The final results below distinguish isolated verification from any later combined-checkout check.

Physical reproduction of the original Codex issue remains unverified: Computer Use refused access to `com.openai.codex` for safety reasons. That refusal was respected. Private pasteboards, simulated focus/permission transitions and captured CGEvents establish the regression contracts without driving Codex. Cross-editor behavior, alternate keyboard/IME layouts, live TCC changes, OS versions/architectures other than this host, physical microphone/device failures and release/notarization remain separate qualification gates. No finite stress run establishes universal correctness.

## Final stress and sanitizer results

The final source adds 29 behavioral regressions. `final-focused.log` passed 349 tests with no skips or failures. `stress-50.log` completed all 50 rounds, each verifying 167 tests without skips/failures: 8,350 test executions. The new cache regression alone made 160,000 concurrent consumption attempts across 10,000 publications; its UTF-16 boundary matrix ran 16,000 cases. These are repeated deterministic scenarios, not that many unique randomized inputs. `stress-summary.json` records the checked counts.

`tsan.log` passed 368 selected tests, including selection, clipboard, HID, source delivery, voice delivery/capture races, watchdogs and single-flight lifetime checks. `asan.log` passed 413 selected tests, extending the selection/delivery checks across macros, search, input and erasure. Neither run skipped tests or reported sanitizer findings. `tsan-linkage.txt` and `asan-linkage.txt` verify the respective sanitizer dylib in the executed test binary. Sanitizers do not establish leak freedom or coverage of uninstrumented operating-system code.

The isolated code index refreshed successfully: 560 files, 9,767 symbols, 73,560 edges, no parse failures or refused files. Source inspection confirmed the new delivery owner is called by AI replacement, palette insertion and search expansion. The index still reports 38,756 unresolved calls and capped neighborhood results; it is navigation evidence, not complete runtime coverage. Its counts describe the indexed candidate before the last additional budget regression.

The initial integration checked all 17 owned paths and preserved 18 unrelated dirty paths byte-for-byte. Further changes from the concurrent task were left intact. `integration-base.json`, `integration-check.json`, `pre-integration/` and `integrated-sha256.json` preserve the ownership checks and rollback copies. `final-source-inputs.json` identifies the final application/test/runner bytes used for stress and sanitizer checks; documentation was updated afterward.

## Final build and integration qualification

`final-ci.log` passed the final 2,978-test suite with zero failures and one missing-Whisper skip. All five opt-in performance checks ran. Shell/plist hygiene, release/installer/publication/LCOV/runner fixtures and both debug/release compilation also passed. The subsequent certificate trial-sign operation did not return for more than three minutes. This audit stopped its own CI/sign-probe process tree; the run is **not** recorded as a complete final CI pass. A previously completed candidate CI pass is identified separately above.

The combined-checkout test attempt (`combined-checkout-tests.log`) waited on another task's SwiftPM process, PID 92028. Only this audit's queued test was stopped. It executed no tests and is not a passing integration check. Additional unrelated source and test files were changing in the shared checkout; isolated evidence excludes those changes. The audited paths are checked byte-for-byte when integrated.

The final local package uses the existing `DEVTYPE_SIGN_IDENTITY=- DEVTYPE_HARDENED_RUNTIME=1` options to avoid retrying certificate authorization while retaining Hardened Runtime. `final-package-adhoc.log` completed successfully, and `final-package-verification.log` confirms mandatory weak Foundation Models linkage and strict codesign validation. Bundle identity, version stamping, SDK/Xcode metadata and the narrowly scoped local-networking transport configuration were checked against the final plist. The intermediate default ad-hoc package (runtime disabled) is recorded separately in `adhoc-default-runtime.log`; the final artifact replaces it with runtime enabled.

The artifact is `/private/tmp/devtype-selection-audit-yn2mbs7p/.build/DevType.app`, version `1.0.0-3-gb6e5f97+dirty` (182), executable SHA-256 `14fae65b2f38c7ffbe6f8fe724a9da6ccdfe89c88499479525b3c2cbe673e993`. `final-package-metadata.json` and `final-codesign-details.txt` retain its identity. It is an ad-hoc validation artifact, not a change to the installed application's identity or distribution policy. Trusted signing, notarization, installation and physical UI qualification remain open. The native certificate-probe wait is an external qualification failure; no credential, Keychain ACL or signing script was altered to conceal it.

Application source changes add 380 lines and remove 244 across six files. The three fixed-delay delivery paths and duplicated copy/paste choreography are replaced by their shared owners. Tests add 447 lines and remove five (fixture/expectation corrections), with 29 new regression methods. No dependency was added.
