# Diagnostic follow-up: erase evidence and test storage

Scope: the DevType 0.1.9 (175) report generated at 2026-09-09T20:15:17.565Z. Work was performed in the verified, initially clean checkout at `/Users/bharath/Code/apps/DevType`, starting from `10b37d4`.

This record describes the first diagnostic pass. The subsequent [comprehensive hardening audit](2026-09-09-comprehensive-hardening.md) extends its coverage and records the later source/test state.

## Findings and changes

**Verified from the report:** the failed GitPulse expansion had a 49-unit AX value, a collapsed caret at 49, and six whitespace units where DevType expected a six-unit trigger. Three of those whitespace units were non-ASCII. The bounded scan covered the complete reported value and did not find the expected text. Permissions were granted and the event tap had no recorded disables. The report alone cannot establish whether the editor changed the text or exposed stale accessibility data.

The six Codex AX `noFocus` reads were followed by clipboard selection captures. On-device transforms recorded nine successes and no failures. Those observations do not establish an AI-model failure, and thirteen posted-but-unverified injections do not establish thirteen failed deliveries.

**Verified in source and regression tests:** `EraseExecutor` previously considered only the whole-field value and selected range. It refused even when a separate exact-range read could confirm the trigger. The new `EraseRangeEvidenceTests` reproduces the report's geometry with synthetic text and an injected AX reader; before the behavior change, its recovery assertions failed while all 54 existing `EraseSafetyTests` passed.

The executor now reuses `SelectionReader.copyStringForRange` to check the exact erase window after a readable mismatch. The plain and attributed parameterized attributes are tried in order, using the element's existing bounded AX messaging timeout. A valid initial value takes no additional range-text read.

Recovery requires all of the following:

- The caller can vouch that this is a just-typed trigger, rather than a later undo or voice correction.
- The selection is collapsed and unchanged after the extra read.
- The plan's text, UTF-16 width and grapheme count agree; the requested window is no larger than 32,768 UTF-16 units and the caret passes the existing plausible-range ceiling.
- The returned text has exactly the requested UTF-16 width and passes the existing case/whitespace comparison.

Conflicting views return the existing HID-only result. They cannot authorize an AX range write, an erase after a possible prior write, or an erase after input/target cancellation. An unsupported range API, wrong text, invalid length or changed selection still refuses. A content-free `rangeProbe` status distinguishes those cases in subsequent diagnostic reports.

**Verified in source and a failing regression:** XCTest processes previously resolved the installed app's `Application Support/DevType` directory. `VoiceCaptureRaceTests` constructs a coordinator whose default diagnostics recorder is `.shared`, so synthetic terminal outcomes can reach that directory. The shared `SupportDirectory` resolver now detects loaded XCTest bundles and provides one unique temporary root for each test process. This also isolates default recovery paths and AX/timing sidecars. A persistence test exercises the shared voice recorder in that root.

**Inferred:** the report's millisecond-spaced voice cancellations, missing-microphone failures and deliberately failing persistence patterns are consistent with that test contamination. Existing historical records were preserved because their provenance cannot be reconstructed reliably from the content-free manifest.

## Preserved boundaries

Security impact: this change adds a bounded read-only AX probe and isolates test filesystem defaults. It adds no dependency, permission grant, authentication bypass, secret migration or network destination. Raw text is absent from the new diagnostic messages. Keychain and explicit external fixture paths are not redirected by test support-directory isolation.

The unreadable master key (`-25293`) remains an authorization issue requiring the app's **Preferences > Advanced > Repair Secret Storage** flow. `SecretStore` and its authorization rules were not changed, and no repair was attempted. Posted-but-unverified paste outcomes remain unverified; the report does not prove those pastes failed.

## Verification evidence

Production-code change size: 96 lines added, 24 removed. Twelve regression tests and the architecture/audit documentation accompany the changes.

- `/tmp/devtype-diag-baseline.log`: 144 existing focused tests passed before changes.
- `/tmp/devtype-diag-isolation-red.log`: two assertions demonstrated that tests selected the real app directory.
- `/tmp/devtype-diag-isolation-green.log`: the two initial storage tests passed after isolation.
- `/tmp/devtype-diag-range-red.log`: 60 tests executed, 15 assertion failures in the new recovery tests; all 54 existing erase tests passed. The injected read boundary was present, with the original evaluation behavior still in place.
- `/tmp/devtype-diag-focused.log`: 131 focused tests passed after the recovery change, before adding the final malformed-range, posting and persistence checks.
- `/tmp/devtype-diag-ci.log`: full suite executed 2,875 tests with zero failures and one skip. All 12 newly added tests ran. The skipped `WhisperServerControllerTests.testStartAndStopRoundTrip` reported: "whisper.cpp or its model is not installed on this machine." All five optional benchmarks were enabled with `DEVTYPE_BENCH=1`.
- Full local CI exited successfully: shell/release fixtures, debug and release builds, packaging, strict codesign verification and mandatory weak Foundation Models linkage passed. The package is `.build/DevType.app`, version `0.1.9+dirty` (175), signed with the existing Apple Development identity. Hardened Runtime is disabled; this is a local development package, not notarized distribution proof. `/Applications/DevType.app` remains version `0.1.9` (175).
- SHA-256 fingerprints of the installed app's `voice-terminal-manifest.json` and `voice-trace.jsonl` were unchanged across the full suite. The baseline fingerprints are in `/tmp/devtype-diag-user-files-before.json`; no diagnostic contents were printed.
- `git diff --check` passed after the final documentation update. The production changes and new test sources were covered by the completed CI run; the final update added only this verification record.

## Verification limits

The exact GitPulse field and physical typing sequence have not been reproduced. This patch can recover when the range API supplies matching text; it intentionally refuses when the editor provides no such evidence. Native posting, real clipboard consumption, microphone permissions/devices and the user's Keychain authorization remain separate live checks. The installed app was not replaced, and no release was published.

The repo map was read before source exploration. GitPulse's worktree/collision facets reported one clean worktree and no overlaps; its code-intelligence facet was unavailable because the on-disk schema was 19 and the tool required 20. Source inspection supplied the call-site evidence; no claim of a current symbol graph is made.

## External contract

Apple documents [`kAXStringForRangeParameterizedAttribute`](https://developer.apple.com/documentation/applicationservices/kaxstringforrangeparameterizedattribute) as the substring for a requested range. [`AXUIElementCopyParameterizedAttributeValue`](https://developer.apple.com/documentation/applicationservices/1461203-axuielementcopyparameterizedattr) can return unsupported, no-value and messaging-failure errors; none is treated as positive evidence here.
