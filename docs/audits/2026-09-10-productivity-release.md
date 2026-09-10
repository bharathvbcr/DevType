# DevType productivity release audit — 2026-09-10

Base: `133ee7ef61189fc5ef0fd3193cc1e7a0a85809ef`. The canonical checkout is `/Users/bharath/Code/apps/DevType`; the supplied devtools path does not exist. Six pre-existing changes were inventoried and preserved. They are not part of this release's changes.

## Scope and recommendations

The repository map, instruction files, build/release scripts, previous audits and actual call sites guided the audit. The map indexed 544 files and 9,612 symbols with 72,013 edges. GitPulse scanned the one original worktree, with no collisions or unscanned worktrees. Its graph reader explicitly could not attest analyzer freshness. Graph information is navigation evidence, not complete coverage.

The release implements these recommendations together:

1. Make existing snippets easier to retrieve with phrases, field/type filters and exclusions, using the same owner in the manager and palette.
2. Make common developer/writing operations available offline through existing palette and macro controls: four naming styles, portable line operations, correct URL-component encoding and scalar JSON support.
3. Make productivity output dependable: fresh generated values, one calculator formatter, correct cache identity/metadata, bounded queries and limits, safe ranking arithmetic, and stable concurrent cache retention.
4. Keep the improvements reviewable and reproducible with regressions against original code, deterministic adversarial loops, repeated stress runs, sanitizers and the existing release gates.

This is a broad automated regression audit with focused source inspection of the affected paths and their callers. It does not claim that every source line, device, third-party editor, locale or possible failure has been examined.

## Reproduced issues

| Boundary | Original behavior | Release behavior |
|---|---|---|
| Library cache identity | Two unrelated libraries at revision 1 returned the first library's hits. | An explicit store UUID scopes revisions; unscoped callers use a complete content fingerprint. |
| Cache invalidation | Equal-length body edits with unchanged timestamps and changes to app restrictions/plain-text delivery returned stale snippet copies. | The fingerprint covers all stored group/snippet fields through synthesized `Hashable` conformance. |
| Ranking ownership | Two custom boost closures at the same revision reused one ranking. | Cache lexical results independently, then apply the current caller's boost and sort. |
| Query locale | A Turkish-folded caller-owned index could not match a query folded in the process locale. | Query terms use the index's own locale. |
| Result limits | A negative search limit trapped in `prefix`. | Nonpositive limits return empty results; palette section limits normalize at entry. |
| Calculator | `Double(Int.max)` trapped during conversion; 1e-9 became zero. | Palette delegates to the existing `SafeMathParser.format` owner. |
| Generated values | Reopening a cached UUID query returned the same UUID. | Cached rankings regenerate dynamic preview/insertion values. |
| URL components | `&`, `=`, `+`, `?` and `/` were left unescaped. | URL Encode permits only RFC 3986 unreserved characters. |
| JSON documents | Valid scalar JSON was returned unformatted. | Both reading and writing enable scalar fragments; malformed input still returns unchanged. |
| Line portability | CRLF, CR and Unicode separators were ignored by dedupe/sort/number/count. | One shared Unicode-newline splitter serves all line operations. |
| Command ranking | `Int.max` custom boosts trapped in integer addition. | Saturating arithmetic at every boost/context addition. |

The suspected statistics-list issue was not changed: its actual caller already scopes the usage snapshot to current library IDs before ranking. A standalone unscoped projection would not reproduce that UI path.

## Preserved contracts and limits

- Typed insertion, AX evidence, undo, secure input, app scoping, clipboard ownership, Keychain authorization and cloud consent are not relaxed.
- Security impact: cache invalidation now includes delivery-policy metadata, preventing stale restrictions from being returned. There is no widened access, new data destination, credential/config edit or dependency.
- Library formats are unchanged. Revisions passed without a library identity now use content hashing; store-backed production callers supply the explicit identity to retain their constant-time cache check.
- Arbitrary ranking closures are never used as a shared result identity. Lexical results remain cached, while caller-specific scores are recomputed.
- Index/query cache slots remain bounded. Query input is capped at 4,096 UTF-8 bytes and 12 terms; body search covers 2,000 characters. The palette additionally caps queries at 512 characters. These limits are not full-content search coverage.
- Case conversion preserves Unicode letters/digits and uses a fixed locale for identifier conventions. Macros map cursor offsets with whole-input context, including acronym transitions. This is not a guarantee of language-specific identifier validity.
- No test is allowed to count a skipped dependency, unexecuted check or posted-but-unverified native insertion as a success.

## Evidence

Logs use the prefix `/tmp/devtype-major-`.

| Log | Result |
|---|---|
| `baseline.log` | 2,911 tests, six skips, zero failures before this task's changes. Five skips were opt-in benchmarks; one required whisper.cpp/model installation. |
| `original-regressions.log` | A detached checkout of the exact original commit ran nine regressions with 13 failing assertions, including the corrected equal-score ranking fixture. |
| `limit-red.log`, `calculator-red.log` | Separate original-behavior processes reproduced negative-limit and integer-conversion traps. |
| `portability-red.log` | Two original-code tests failed 17 assertions for line separators and index/query locale mismatch. |
| `command-overflow-red.log` | An isolated original-code process terminated on extreme command ranking arithmetic. |
| `features2.log` | 180 focused tests, one optional benchmark skip, zero failures. |
| `focused-final.log` | 182 focused tests, one optional benchmark skip, zero failures before the subsequent manager adapter test. |

An initial incremental build after changing public model conformances encountered stale linker references. `swift package clean` followed by a full rebuild resolved it. An early new macro test incorrectly called the Mustache-only adapter for TextExpander syntax; it was corrected to exercise the actual `MacroRenderer` entry point, preserving the expected outputs. Neither failed attempt is counted as passing validation.

## Release gates

`Scripts/release-signing-preflight.sh` currently fails with:

```text
error: notarized distribution requires Developer ID Application signing (resolved apple-development); set DEVTYPE_SKIP_NOTARIZE=1 only for an intentional local/untrusted artifact
```

Local build/signature validation cannot substitute for Developer ID, notarization, Gatekeeper acceptance, remote CI, or supported-platform execution. Physical microphone/device switching, sleep/wake, TCC transitions, real Keychain ACL authorization, live provider behavior and native insertion across editors remain unverified by these automated tests. No finite stress run establishes universal correctness.

## External contracts

- [Swift integer conversions](https://github.com/swiftlang/swift/blob/main/stdlib/public/core/Integers.swift) and the existing tested `SafeMathParser` establish the floating-point boundary behavior.
- [Foundation JSONSerialization](https://developer.apple.com/documentation/foundation/jsonserialization) documents scalar-fragment options.
- [Swift Character.isUppercase](https://developer.apple.com/documentation/swift/character/isuppercase) and the standard Character properties provide Unicode case/newline classification.

## Completed isolated stress and sanitizer checks

A second process started coverage testing in the original checkout during the first stress attempt. That attempt stopped after two completed rounds and was not counted as the final run. The process was left untouched. All subsequent checks ran in `/tmp/devtype-major-release` on `codex/devtype-productivity-v1`, copied from the original commit with only this task's 26 changed/new paths. GitPulse scanned all three temporary/original worktrees without truncation; their 26 overlapping paths were the deliberate validation copies. The original-code checkout was removed after preserving its regression inputs in `/tmp/devtype-major-reproduction-inputs`.

- `isolated-stress.log`: 20 complete rounds, 88 tests per round, 1,760 test executions, no skips or failures. The new loops alone cover 40,000 concurrent-search cases, 40,000 parser cases and 80,000 naming-conversion cases. Existing erase/undo fuzzing contributes 240,000 cases across the rounds. These are repeated deterministic cases, not exhaustive unique-input coverage.
- `tsan.log`: 84 tests passed, no Thread Sanitizer findings. `tsan-linkage.txt` confirms the test executable loaded `libclang_rt.tsan_osx_dynamic.dylib`.
- `asan-broad.log`: 329 tests passed, no Address Sanitizer findings, covering the broader macro/input/voice blast radius. `asan-linkage.txt` confirms `libclang_rt.asan_osx_dynamic.dylib`. An earlier narrower 46-test ASan pass also succeeded.
- Six malformed or out-of-range stress round settings were refused with exit status 2 before running tests. Bounds are 1–100 rounds.
- The isolated DevMap build reported 552 indexed files, 72,561 edges and generation 1. Its old-symbol candidates map to the pre-existing cleanup edits intentionally excluded from this release; they are not deletion proof.
- All local links in changed documentation resolve. Source, test and script hashes stayed unchanged throughout these completed validation runs.

The initial isolated candidate includes 28 new tests; two additional Unicode regressions were added after platform CI. Its full-suite count differs from the initial shared-checkout baseline because three pre-existing tests were excluded with their owner's changes. Existing test-only warnings about a fixture variable, weak references and async `NSLock` calls remain; no production Swift 6 language-mode migration is claimed.

## Full local release gate

`DEVTYPE_SKIP_AUTO_CERT=1 DEVTYPE_REQUIRE_FOUNDATION_MODELS=1 DEVTYPE_BENCH=1 ./Scripts/ci-local.sh` exited 0 (`/tmp/devtype-major-ci.log`). It ran 2,936 tests with zero failures and one skip: `WhisperServerControllerTests.testStartAndStopRoundTrip` requires a local whisper.cpp executable/model. All five opt-in benchmarks ran. Shell syntax, plist validation, release/installer/publication fixtures, debug and release builds, bundle packaging, strict codesign, version stamping and mandatory weak Foundation Models linkage passed. The CI-stage package was `0.1.9+dirty` (176), prior to the release commit/tag. No installed application was replaced.

The code was validated on macOS 27 arm64 with the installed Xcode toolchain/26.5 SDK and a macOS 14 deployment target. That target alone does not prove execution on macOS 14.

The search benchmark ran 1,000 cached queries over 2,000 snippets in 727.47 ms, using the explicit library identity/revision fast path. The original-code run measured 1,338.68 ms. These runs were not controlled for machine load, so the difference is an observation, not an attributed speedup. Other final measurements: 20,000 matcher calls in 6.03 ms; 200,000 localization lookups in 34.41 ms.

The test/script/source hashes remained unchanged from the isolated stress run through final local CI. Documentation-only evidence updates followed validation. Remote platform CI and final tagged bundle checks are recorded separately in the release task's results; trusted notarized distribution remains unavailable; the repository separately supports intentional unnotarized publication.


## Platform CI follow-up

The first candidate, `0814688`, passed GitHub's macOS 26 build/test job and repository hygiene, but macOS 14 failed the naming-conversion stress test with 1,550 assertions. Packaging was consequently skipped. [Run 34490217885](https://github.com/bharathvbcr/DevType/actions/runs/34490217885) is retained as failure evidence, not a passing gate.

The conversion boundary incorrectly required a preceding lowercase letter or number. Uncased scripts therefore lost a following capital during repeat conversion. The local Unicode numeric classification of `京` masked the Japanese fixture; Chinese, Arabic and Hindi fixtures reproduced the same class locally with 20 failing assertions, including a shifted macro cursor (`uncased-red.log`). The shared converter now recognizes an uppercase transition after any non-uppercase identifier character.

Adversarial follow-up also reproduced expanding uppercase mappings (`ß` → `SS`, `ﬃ` → `FFI`) with four failing assertions (`expanding-case-red.log`). Capitalized word starts now retain one initial capital and lowercase the remaining expansion. Both fixes keep whole-input cursor mapping, and the deterministic corpus now includes these scripts and expansions. No existing expectation was removed or weakened. The amended release has 30 new tests. Follow-up local and platform results are recorded with the final release artifacts; the earlier stress/sanitizer/full-CI counts above identify the initial candidate.

## Continuation audit: complete query admission

The interrupted task left the candidate at `052b75c`. Live GitHub inspection verified [run 34496125875](https://github.com/bharathvbcr/DevType/actions/runs/34496125875): macOS 14 and 26 build/test, hygiene and packaging all passed. The local `final-ci.log` executed 2,938 tests with one missing-Whisper skip and no failures. The final 20-round log executed 90 tests per round; final targeted ASan and TSan logs each executed 66 tests without findings. These are previous-candidate checks, not automatic proof for subsequent edits.

A fresh follow-up baseline ran 46 relevant tests with no failures. Five new regressions then produced ten failing assertions against the unchanged candidate (`/tmp/devtype-followup-query-red.log`):

- A thirteenth term or text after byte 4,096 could contain an exclusion that the parser silently discarded. Both indexed search and the legacy scorer returned a partial-query match.
- Empty negative filters (`-title:`, `-tag:`, `-is:`) widened results.
- Palette truncation at character 512 discarded a trailing exclusion before search and cache lookup.
- The manager adapter exposed these partial matches to bulk-action selection.

The canonical parser now rejects over-limit queries and incomplete filters with a typed reason. The manager and palette display localized explanations and no selectable rows; valid queries restore results. Explicit command mode keeps its command grammar. UTF-8 is checked before decoding or allocation, so the cap cannot split a scalar. The 12-term, byte and palette-character ceilings remain; their former truncate-and-search semantics are intentionally retired because they violate conjunctive filtering. Existing tests were retained.

Security impact: this change narrows matching and changes no permission, Keychain, authentication, secret-storage or network boundary. The implementation remains dependency-free beyond the existing package dependencies. An additional deterministic adversarial test asserts the expected result for 2,000 combinations of repeated predicates, literal/quoted exclusions, Unicode whitespace and term-limit crossings. The native window regression drives a synthetic fixture, verifies the visible reason, clears stale selection, refuses empty-area clicks and restores valid results. It does not access the user's stored secret values.

Distribution policy was rechecked in `.github/workflows/release.yml`, README and DEVELOPMENT: the existing workflow explicitly opts into an ad-hoc signed, unnotarized public DMG. The earlier signing error blocks trusted notarized distribution; it does not mean the repository lacks a supported unnotarized release path. That policy is unchanged. Physical microphone/device switching, TCC transitions, real Keychain ACL authorization and native injection across third-party editors remain separate, unverified gates.

Continuation validation so far: 20 stress rounds passed with 96 tests each (1,920 executions, zero skips/failures), including 40,000 asserted exclusion/boundary cases. TSan passed 91 selected tests; ASan passed 157 across search, macros, erase/undo, input and voice. The loaded sanitizer runtime was verified with `otool -L` immediately after each run. Logs: `/tmp/devtype-followup-stress.log`, `-tsan.log`, `-asan.log`. The native window/query/localization group passed 60 tests without skips (`-window.log`). Eight new tests were added in this continuation; all original tests remain.

The original checkout also contains 12 unrelated changed/new/deleted paths belonging to earlier cleanup and coverage work. Their exact residual against `052b75c`, original diff, untracked archive and per-file hashes are preserved under `dist/v1.0.0-release-evidence` in the canonical checkout. They remain outside the release commit.

The stress runner itself had a separate false-success defect: a substituted test process returned zero with “No matching test cases were run”, and the real runner printed “All 1 stress rounds passed” (`/tmp/devtype-followup-empty-stress-red.log`). Seven runner fixtures exposed four failures before the fix (`-runner-red.log`), then all passed. The runner now inspects the selected XCTest parent summary and refuses zero tests, skips, missing summaries or nonzero process status. The separate Swift Testing zero-test footer is not mistaken for the XCTest result. These fixtures run in local and remote release CI. No new dependency was added; Python 3 already runs the release fixtures.

The continuation's full source suite executed 2,946 tests with one skip and zero failures (`/tmp/devtype-followup-ci.log`): the sole skip requires the absent local whisper.cpp executable/model. Debug and release compilation passed. Source production changes for the complete release add 470 lines and remove 176. The code graph refreshed to 552 files, 9,689 symbols and 73,167 edges (generation 2), with no failed parses or refused discovery; graph resolution still is not proof of runtime coverage. The runner-only change followed this full suite and is independently covered by its failure-injection fixtures and a repeated actual stress run. Final commit/package/remote results are retained in the release evidence directory.

The first direct computer-use attempt to read `/Applications/DevType.app` returned `Computer Use server error -10005: timeoutReached`. Automated AppKit fixture execution is verified independently; this failed connection is not installed-app interaction evidence. Before installation, the previous app and packaged candidate had identical designated signing requirements, preserving the installer's TCC continuity path.

The hardened runner then completed another 20 real rounds, explicitly verifying 96 tests and zero skips/failures in every round (1,920 executions; `/tmp/devtype-followup-verified-stress.log`). All release/installer/publication/runner fixtures passed afterward (`-final-fixtures.log`). The application source and Swift tests remained byte-identical to the sanitizer/full-suite runs; only the independently tested runner and documentation changed afterward. Local CI also completed packaging, strict signature, version-stamping and mandatory weak Foundation Models linkage successfully.

## Final release inputs and local installation

The immutable release input is `ef2bd025cb6ed010af08aec9fc87c0ad84fc2deb`, tagged `v1.0.0` (annotated tag object `d02f2345c3b14c0b416dcd739e4d0eced5d01150`). The former unpublished local candidate is retained at `refs/devtype/candidates/v1.0.0-052b75c`; no previously public tag was replaced. The final release adds 1,207 lines and removes 198 across 29 files, including 38 new Swift tests and seven stress-runner fixture tests.

[Main CI 34516468374](https://github.com/bharathvbcr/DevType/actions/runs/34516468374) and [CodeQL](https://github.com/bharathvbcr/DevType/actions/runs/34516467122) passed. Main CI includes debug/release builds, packaging and mandatory weak Foundation Models linkage. Actual platform test counts:

| Platform | Toolchain / architecture | Tests | Skipped | Failures |
| --- | --- | --- | --- | --- |
| macOS 14 | Swift 5.10 / Xcode 15.4 / arm64 | 2,939 | 12 | 0 |
| macOS 26 | Swift 6.3.3 / Xcode 26.6 / arm64 | 2,946 | 13 | 0 |

Hosted skips identify unavailable Foundation Models/Apple Intelligence, opt-in benchmarks and missing local Whisper. The local full suite ran the benchmarks and available model tests, with only the missing-Whisper skip. These platform results do not establish Intel runtime qualification. [Release workflow 34518098540](https://github.com/bharathvbcr/DevType/actions/runs/34518098540) records the separate tag CI, artifact construction, exact asset inventory and byte-identical download/publication checks.

The local v1.0.0 build 179 was installed at `/Applications/DevType.app` with the existing Apple Development identity and Hardened Runtime enabled. Strict/deep codesign passed; the installed executable SHA-256 matched the preserved package (`1821fea0f47788d47dcae5a8a246a181ac585d0230caa84e3af2ce33443e0d81`). Startup logs confirmed `identityChanged=false`, listen/AX/post grants preserved, `tapRunning=true` and `Status: Active`. Gatekeeper returned exit 3 (`rejected`), as expected for this intentional unnotarized distribution path. Direct computer-use reads still timed out; no cross-editor insertion or microphone interaction is claimed.

Persistent artifacts live under `dist/DevType-1.0.0-local-ef2bd02` and `dist/v1.0.0-release-evidence` in the canonical checkout, including logs, checksums, the old application, a complete pre-release Git bundle, and the integration stash reference. The canonical `main` branch was fast-forwarded while preserving 12 unrelated paths outside the release. Ten remain byte-identical to their original snapshot; two shared fixture/documentation files retain both the release and prior changes. This documentation follow-up changes no application source, tests, scripts, or release artifact.
