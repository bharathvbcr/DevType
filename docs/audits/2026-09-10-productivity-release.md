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

The test/script/source hashes remained unchanged from the isolated stress run through final local CI. Documentation-only evidence updates followed validation. Remote platform CI and final tagged bundle checks are recorded separately in the release task's results; public release remains blocked by the signing gate above.


## Platform CI follow-up

The first candidate, `0814688`, passed GitHub's macOS 26 build/test job and repository hygiene, but macOS 14 failed the naming-conversion stress test with 1,550 assertions. Packaging was consequently skipped. [Run 34490217885](https://github.com/bharathvbcr/DevType/actions/runs/34490217885) is retained as failure evidence, not a passing gate.

The conversion boundary incorrectly required a preceding lowercase letter or number. Uncased scripts therefore lost a following capital during repeat conversion. The local Unicode numeric classification of `京` masked the Japanese fixture; Chinese, Arabic and Hindi fixtures reproduced the same class locally with 20 failing assertions, including a shifted macro cursor (`uncased-red.log`). The shared converter now recognizes an uppercase transition after any non-uppercase identifier character.

Adversarial follow-up also reproduced expanding uppercase mappings (`ß` → `SS`, `ﬃ` → `FFI`) with four failing assertions (`expanding-case-red.log`). Capitalized word starts now retain one initial capital and lowercase the remaining expansion. Both fixes keep whole-input cursor mapping, and the deterministic corpus now includes these scripts and expansions. No existing expectation was removed or weakened. The amended release has 30 new tests. Follow-up local and platform results are recorded with the final release artifacts; the earlier stress/sanitizer/full-CI counts above identify the initial candidate.
