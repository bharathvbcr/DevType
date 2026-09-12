# Secret isolation audit — 2026-09-12

Scope: GitPulse task `528842ad-9bee-4220-8beb-83c713515213`, “Isolate secrets from snippets; secrets don't need trigger.” No formal acceptance criteria were recorded. This audit covers that change and the storage, authentication, cleanup, search, export, and mutation boundaries it reaches. It is not an audit of unrelated voice, model-provider, or undo work.

Canonical checkout verified: `/Users/bharath/Code/apps/DevType`, origin `https://github.com/bharathvbcr/DevType.git`, main based on `9a1dd683375cb1c82e7ed4e4fe40d2662d341228`. The supplied devtools path is staging metadata. Existing secret-isolation edits were preserved. The separate undo worktree was inspected and left untouched; shared filenames contain separate concerns.

## Method and invariants

The initial focused baseline passed 218 tests. New regression tests ran against the failing behavior before each fix. A pre-audit source snapshot and numbered red/green logs are retained under `/tmp/devtype-secret-audit-before` and `/tmp/devtype-secret-audit-*.log` for this session.

Security impact: these changes strengthen selection validation, transaction exclusion and
cleanup authority while preserving the existing authentication preference and clipboard policy.
They do not widen access or replace unreadable master keys. The audit adds 872 and removes 129
source/test lines relative to the saved pre-audit implementation; documentation is additional.

- Secret metadata remains separate from snippet groups. Values never enter library JSON, snippet exports, search indexes, prompts, or diagnostic messages.
- Legacy UUIDs remain the value-store identifiers. Metadata migration must not read, write, or delete the five synthetic unreadable fallback values.
- Secret access needs an explicit selection, follows the existing authentication preference, and revalidates current metadata. Authentication cancellation preserves the clipboard.
- A failed edit cannot overwrite a competing successful value. Cleanup cannot delete an entry referenced by a newer or unexamined library.
- Existing archive encryption, verified publication, master-key preservation, orphan protection, clipboard markers/ownership/expiry, and typed-trigger exclusion remain covered.

## Confirmed findings and fixes

| Finding | Reproduction | Canonical fix and regression |
| --- | --- | --- |
| Malformed metadata could become an empty usable library and be overwritten. Bare-array duplicate secret IDs escaped validation. | `red1`: duplicate decoding did not throw; missing/null/ambiguous envelopes accepted writes and changed raw bytes. | `SnippetDocument` and `decodeDocument` reject these shapes. `IndependentSecretTests` checks raw-byte preservation and read-failure latching. |
| The legacy flat save API could not add an ordinary snippet when the only existing collection was secrets. | `red1`: the save was refused and the new snippet was absent. | Split ordinary groups and secret metadata before merging, then publish through the existing whole-library owner. |
| Disabled secrets remained in the copy menu; stale selected records could be read after deletion, disabling, or editing during authentication. | `red1`/`red2-confirmed`: disabled menu entries and successful stale resolutions. | Menu eligibility checks enabled state. `SecretMenuFlow` validates the selected record before and after authorization/value retrieval. |
| An external metadata update could bypass selection validation until its file-watcher notification arrived. | `red7`: a deleted external selection still resolved successfully from the old cache. | `loadCurrentSecrets()` verifies the cache/disk digest pair and fails closed when current authority is unavailable. |
| Duplicate authentication callbacks could produce multiple results; a released gate owner could strand completion. Invalid clocks/windows could authorize reuse. | `red2-confirmed` produced success/success/cancel; `red8` produced no result; non-finite clock tests failed. | One completion claim, owner-independent delivery, and finite positive reuse checks in `BiometricGate`. Existing in-flight prompt behavior on app resignation remains tested. |
| Two editors could interleave snapshot/staging/rollback and overwrite the winning value. | `red3`: the competing write entered early; final value reverted to the original. | Extend the existing archive lock over the complete editor transaction. Metadata queries remain available, avoiding the archive/library lock inversion. |
| Retrying failed compensation could overwrite a newer committed value. | `red3`: Cancel restored the original over the newer value. | Revalidate the staged value inside storage exclusion before compensating. Keep orphan protection while compensation remains pending. |
| A storage write could mutate successfully and then report failure, leaving an uncommitted replacement behind. | `red5`: failed save left the staged value. | Register compensation before attempting the write; inspect the resulting value even after reported failure. |
| Cleanup could delete a secret referenced by an unobserved external library update or a writer finishing while cleanup waited. | `red4`: one deletion attempted and the externally referenced value disappeared. | Revalidate liveness under backing exclusion and confirm the cache/disk pair. Retain uncertain items and report `deferred` separately from attempted deletions. |
| A secret matching an AI snippet-tool query could consume its single result slot and return an empty trigger. | `red6-confirmed`: result was empty instead of the ordinary snippet's trigger. | Remove secret records before ranking/capping in `FindSnippetTool`. The deterministic tool test requires no model invocation. |

A suspected table-selection retargeting issue did **not** reproduce. Its regression passes without a UI code change. An older race test had become vacuous because migrated marker groups contain no secret snippets; it now asserts the exact secret count/IDs and examines every stored marker value.

## Coverage and stress design

| Boundary | Evidence |
| --- | --- |
| Legacy formats and corruption | Bare arrays, v1/v2 envelopes, schema-3 round trips, duplicate IDs, ambiguous/null/missing collections, newer-schema refusal, exact UUID/label/date/tag/effective-scope preservation. |
| Fallback preservation | Five unreadable synthetic Keychain residents survive metadata migration with zero value operations; existing master-key flapping, locked-tier, verified archive, and migration tests remain active. |
| Editing and failure recovery | Create/update/metadata-only/delete, stale metadata, partial value writes, refused persistence, delayed compensation, unavailable transaction, retained orphan leases, and competing archive instances. |
| Concurrency | Deterministic interleavings plus eight writers performing 240 edits with imports and cleanup. Final metadata/value association and every attempted outcome are checked. |
| Model-based stress | 16 seeds × 80 operations = 1,280 operations per run: secret creation, edits, toggles, rejected writes, deletion, same-named snippet imports, resets, exports, and orphan cleanup. Each operation checks every committed secret against an independent expected model. |
| Read/privacy boundaries | Disabled/stale/external selections, duplicate/cancelled/failed/delayed authorization, ephemeral gate ownership, trigger-free palettes, native mouse selection, typed-trigger/nested/AI exclusion, and clipboard write-failure/ownership/expiry tests. |
| UI and documentation | Native AppKit editor/manager tests and rendered synthetic-data snapshots; existing Advanced repair route; deferred cleanup remains visible. |

## Verification record

All results below are verified from completed commands and their logs. Coverage is measured
line execution, not proof that every state or branch is correct.

| Check | Result | Evidence |
| --- | --- | --- |
| Full SwiftPM suite with opt-in benchmarks and Swift/Objective-C coverage | 3,142 tests, one skipped, zero failures; coverage export succeeded | `DEVTYPE_BENCH=1 DEVTYPE_SECRET_UI_SNAPSHOT_DIR=/tmp/devtype-secret-ui ./Scripts/test.sh --scratch-path .build/secret-audit --coverage --jobs 6`; `/tmp/devtype-secret-audit-final-full.log` |
| Thread Sanitizer | 96 selected tests, zero failures, no sanitizer diagnostics | `/tmp/devtype-secret-audit-final-tsan.log` |
| Address Sanitizer | 228 selected tests, zero failures, no sanitizer diagnostics | `/tmp/devtype-secret-audit-asan.log` |
| Repeated adversarial tests | 20 completed runs, zero failures: 25,600 model operations and 4,800 concurrent edit attempts, plus deterministic editor/auth/cleanup regressions | `/tmp/devtype-secret-audit-repeat-01.log` through `-20.log` |
| Optimized build | Release build completed successfully | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --scratch-path .build/secret-audit --jobs 6`; `/tmp/devtype-secret-audit-release.log` |
| Release and installer fixtures | Passed, including signing-selection, installer rollback, coverage admission and publication-recovery fixtures | `./Scripts/ci-release-fixtures.sh`; `/tmp/devtype-secret-audit-release-fixtures.log` |
| Static repository checks | All 34 shell files passed syntax validation; both property lists and three localization property lists passed; `git diff --check` passed | Same shell/plist checks used by `Scripts/ci-local.sh` |
| Native render inspection | Editor and manager synthetic-data images inspected; labels and controls fit, no trigger field or stored value shown | `/tmp/devtype-secret-ui/secret-editor.png`, `/tmp/devtype-secret-ui/secret-manager.png` |
| Code-intelligence refresh | 584 files indexed, zero extraction failures, fresh manifest; unresolved calls remain advisory | `devmap build --manifest --json`; `/tmp/devtype-secret-audit-devmap.json` |

The skipped test is `WhisperServerControllerTests.testStartAndStopRoundTrip`: the local
whisper.cpp runtime or model is not installed. No secrets test was skipped. Full `ci-local.sh`
packaging/signing and installed-app verification were not run; the current task did not install
or publish a release.

The coverage artifact is `coverage/lcov.info` (217 files, 52,569 hit lines and 20,581 missed
lines). Relevant file coverage: `SecretModel` 100%, `BiometricGate` 93.4%, `SecretMenuFlow`
89.8%, `SnippetEditTransaction` 89.3%, `SnippetStore` 86.8%, `SecretStore` 81.8%, editor 85.6%,
manager 69.9%. These figures cover each entire file, including unchanged functionality.

Two verification setup problems were retained as evidence rather than counted as passes:
an initial coverage run passed its tests but the exporter rejected generated SwiftPM source
outside the checkout (`error: coverage path is outside the checkout:`); rerunning in the
supported in-checkout scratch directory passed both.
The first repetition attempt timed out after 60 seconds waiting for the release build's SwiftPM
lock (`Another instance of SwiftPM ... is already running` followed by `subprocess.TimeoutExpired`),
before any tests ran. All 20 reported repetitions ran after that build completed.

## Limits

No live credential values were used. No installed app, master key, Keychain ACL, signing identity, or real secret was changed. The user's five reported fallback secrets were not repaired. Physical Touch ID, third-party password fields/clipboard managers, and actual **Preferences → Advanced → Repair Secret Storage** remain manual verification gates.

Tests exercise cooperating storage instances, fault injection, file-lock contention, and normal error recovery. They do not establish universal OS/provider behavior or power-loss rollback across the separate metadata and value files. Each file retains its existing atomic publication; editor compensation is not a durable cross-file journal. No absolute “complete confidence” claim is made.
