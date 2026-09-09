# DevType hardening audit — 2026-09-09

Status: implementation, focused regressions, full local CI and both sanitizer runs verified within the limits below.

Scope: the supplied diagnostic report, the canonical checkout at `/Users/bharath/Code/apps/DevType`, and the connected persistence, permission, clipboard, AI, voice, import, matching, recovery, and packaging paths. Base commit: `83aef4bfec55a28e9b34f9a3ac64b49a86149465`. The results below describe the audit before the changes were committed and packaged as v0.1.9.

The source inventory contains 216 Swift source files and two C/Objective-C source/header files. This is an inventory, not a claim that every line or every possible application interaction was examined. The audit's DevMap generation 3 snapshot has 534 indexed files, 9,519 symbols and 70,943 edges. It reports 38,542 unresolved calls, including 29,973 unattributed calls; graph reachability alone cannot establish complete coverage.

Production changes add 565 lines and remove 257. There are 39 new regression tests across the diagnostic, system-boundary, clipboard, routing and voice-race suites. Shared owners replace the duplicated atomic-write and task-group timeout paths rather than leaving parallel implementations in place.

## Verified defects and fixes

| Boundary | Evidence before the fix | Implemented behavior and regression |
| --- | --- | --- |
| Diagnostic delivery claims | 126 unverified posts plus 19 successes were summarized as 100% delivered; normal typeahead replay appeared under duplicate writing risk. | Only confirmed success contributes to the verified percentage. Delivery safeguards are distinct from duplicate-risk indicators; risk is explicitly unconfirmed. `DiagnosticHardeningTests`. |
| Repeated Accessibility probing | The report repeats AXManualAccessibility failure within 40 ms. Injected probes reproduced redundant attempts. | One in-flight probe per PID, one-second transient retry cooldown, stale-completion protection and a 256-entry memo ceiling in `AXContextChecker`. `DiagnosticHardeningTests`. |
| Secret retrieval versus maintenance | A failed master-key maintenance probe could obscure a successful fallback read and repeat on subsequent reads. | Retrieval outcome is recorded separately. Automatic consolidation backs off for five seconds; explicit repair/save/decrypt still attempts immediately. Master-key decoding requires 32 bytes, and diagnostics include master authorization needs. `DiagnosticHardeningTests`. |
| Archive I/O treated as absence | A chmod-denied archive was replaced as though empty; a directory at the archive path did not reliably refuse operations. | `SecretStore.loadArchive` distinguishes missing, undecodable and unavailable. Nonregular files and symlinks are refused; read/write size is capped at 64 MiB. Unavailable counts are reported as unknown. `SystemAuditRegressionTests`. |
| Recovery copy destruction | A second unreadable archive replaced the existing recovery copy. | Each quarantine preserves earlier copies. At 32 copies, quarantine refuses rather than deleting data. Corrupt-but-readable archives retain the existing Keychain fallback contract; unsafe/unexamined paths fail closed. `SystemAuditRegressionTests`, `SecretDeleteIntegrityTests`. |
| False successful secret save | A new Keychain value could be saved while an old sealed value remained authoritative after failed eviction. | Failed eviction returns `errSecIO`. Neither copy is discarded on that failure; retry can complete the transaction. Existing archive locking and disk read-back verification remain in place. `SystemAuditRegressionTests`, `SecretArchiveLockTests`. |
| Nonatomic voice record replacement | Two store instances produced 107 write/read failures in 200 concurrent operations. | The existing `FilePermissions` owner now creates unique 0600 staging files, synchronizes their contents and publishes with one rename. Secret archives and voice records share it. Fault injection confirms prior content and staging cleanup; stress now uses eight stores and 2,000 writes. |
| Writer/recovery size mismatch | A 1,048,702-byte raw record overwrote a 137-byte recoverable record even though recovery rejected the larger size. | Voice writes use recovery's own standard limits and preserve the old destination when oversized: manifest/raw 1 MiB, final 4 MiB, receipt 64 KiB. `SystemAuditRegressionTests`. |
| Subprocess output and lifetime | A 2 MiB response was retained without a ceiling; a descendant holding stdout made the caller lose the already-written prefix and left a reader blocked. | `BoundedProcess` drains in bounded nonblocking batches, retains at most 1 MiB by default, closes its handles and reports incomplete/truncated output. Identity parsing requires successful, complete output. Exit status, invalid UTF-8, timeout and inherited-pipe cases are tested. |
| Numeric conversion crashes | Nonfinite AI budgets crashed the test process with “Double value cannot be converted to Int because it is either infinite or NaN.” A negative secret clipboard duration scheduled a negative delay. | AI budgets validate signs/finiteness and use checked sums/conversions. Clipboard deadlines normalize invalid values and cap extremes at one day. Subprocess and model deadlines are also bounded before conversion. |
| Ineffective AI timeout | A cancellation-ignoring engine did not return to its caller within the 0.5-second test deadline. | `SingleFlightLatch.run` owns the result race, cancels work, gives a 50 ms cleanup grace and resumes the caller. Admission stays occupied until the real operation exits. A hundred attempted overlapping requests cannot start more work. Palette routing and Foundation Models correction share this owner; invalid deadlines admit no work. |
| Stale voice setup and callbacks | Retiring the generation during handler setup still opened the microphone once; a retired callback still updated the HUD. | Generation is checked after handler setup, before capture/finalization and when audio-level callbacks reach the coordinator. Optional-preview failure cannot record stale diagnostics after its await. `VoiceCaptureRaceTests`. |

## Preserved invariants and security impact

- No secret master key is overwritten to repair an access failure. Keychain cleanup still requires a verified readable replacement on disk, under the transaction lock.
- File publication narrows exposure: private staging files are 0600 before their first content write. There is no new dependency, permission grant, credential migration, authentication bypass, cloud destination or widened authorization.
- Correction error logs use content-free error metadata. Secret values and raw provider error descriptions are not added to diagnostics.
- No text replacement or undo safety condition was relaxed. A caret/value mismatch still refuses destructive undo; a posted but unverified injection remains unverified.
- Caller deadlines do not release resource admission for work still running. A permanently uncooperative model can occupy one slot indefinitely; later requests take fallback. Swift tasks cannot forcibly terminate arbitrary noncooperative code.
- Ordinary corruption recovery can use surviving Keychain data. An I/O failure or unsafe file type is not silently recast as a missing archive.
- Atomic replacement preserves the prior destination before publication. It is not a guarantee against hardware failure or sudden power loss.

## Verification evidence

Pre-fix runs were performed before changing the corresponding behavior; the clipboard check temporarily removed only this task's normalization block and restored it in a `finally` block.

| Local log | Result |
| --- | --- |
| `/tmp/devtype-hardening-baseline.log` | 75 baseline focused tests passed. |
| `/tmp/devtype-hardening-red.log` | Original diagnostic regressions: 9 tests, 14 assertion failures. |
| `/tmp/devtype-system-audit-red.log` | Broader pre-fix checks: 8 tests, 14 assertion failures. |
| `/tmp/devtype-system-audit-crash-red.log` | Isolated numeric-conversion crash reproduced. |
| `/tmp/devtype-ai-deadline-red.log` | Cancellation-ignoring engine exceeded the caller deadline. |
| `/tmp/devtype-boundary-contract-red.log` | Clipboard duration and voice record-size regressions: 2 tests, 3 assertion failures. |
| `/tmp/devtype-voice-generation-red.log` | Both stale setup/callback regressions failed before their fix. |
| `/tmp/devtype-system-audit-focused4.log` | 86 focused tests passed with no failures. |
| `/tmp/devtype-system-audit-ci.log` | Full local CI passed: 2,863 tests executed, one skipped, zero failures; shell/release fixtures, debug and release builds, packaging, strict codesign and mandatory weak Foundation Models linkage passed. All five optional benchmarks ran with `DEVTYPE_BENCH=1`. |
| `/tmp/devtype-system-audit-tsan.log` | 92 tests passed under Thread Sanitizer, zero failures and no sanitizer report. The test binary's `libclang_rt.tsan_osx_dynamic.dylib` linkage was verified with `otool -L` before the next build. |
| `/tmp/devtype-system-audit-asan.log` | 59 tests passed under Address Sanitizer, zero failures and no sanitizer report. The test binary's `libclang_rt.asan_osx_dynamic.dylib` linkage was verified with `otool -L`. |

The only skipped full-suite test was `WhisperServerControllerTests.testStartAndStopRoundTrip`: “whisper.cpp or its model is not installed on this machine.” No replacement dependency/model was installed. The package is `.build/DevType.app`, version `0.1.8-1-g83aef4b+dirty`, build 174, signed with the existing Apple Development identity. Hardened Runtime is disabled for this development build; this is not notarized distribution evidence. The installed app was not replaced.

Benchmark measurements from this run: 20,000 matcher calls took 10.87 ms; 1,000 cached searches over a 2,000-snippet library took 1,054.94 ms; 200,000 localization lookups took 51.40 ms. These are local measurements without a pre-change benchmark comparison, not a speedup claim.

Existing adversarial suites exercise Unicode/surrogate boundaries, undo deletion ceilings, typing state transitions, overlapping delivery, clipboard ownership churn, bounded imports, archive contention, voice state/recovery and provider privacy. For example, erase/undo fuzzing runs 4,000 erasure cases and 8,000 widened-undo cases; the typing suite runs 40 seeds × 400 transitions for its first invariant alone. Counts describe those actual loops, not exhaustive input-space coverage.

## Verification limits

- The supplied report is historical evidence. Its old voice failures and current authorization snapshots do not establish one current microphone fault.
- Keychain ACL repair requires the user's actual authorization UI. This audit uses isolated stores and does not decrypt or mutate the user's real secrets.
- Physical typing/pasting in password fields, third-party accessibility implementations, microphone/device switching, sleep/wake and real model readiness require a live application/device matrix. Automated policy tests do not establish those interactions.
- Local tests do not prove remote CI, Intel/older-macOS behavior, notarization, distribution trust, provider uptime or recovery after a physical power failure.
- Existing test-only compiler warnings remain: an unused fixture URL, weak-reference diagnostics, and direct `NSLock` calls from an async test fixture. The package uses Swift 5 language mode; a Swift 6 language-mode migration was not part of this change.
- No finite stress run proves absence of all defects. The claims above are limited to reproduced failures, implemented boundaries and the checks recorded here.

## External contracts consulted

- [Apple POSIX open](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/open.2.html), [stat](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/stat.2.html), and [fcntl](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html): descriptor creation, type inspection and nonblocking I/O.
- [Apple TaskGroup documentation](https://developer.apple.com/documentation/swift/taskgroup) and [Swift concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html): task groups wait for their children; cancellation requires cooperation. The local cancellation-ignoring regression independently demonstrated the consequence.
