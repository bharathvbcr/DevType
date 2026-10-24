# DevType audit 2026-10-24

Read-only. No source, config, or dependency edits. No DevMap rebuild. No `.devcouncil` gap file. No card was deleted, merged, or moved to done.

The label on every new card is `audit-2026-10-24`. The user-info date for the session was 2026-10-23. The audit session started 2026-10-24T03:26Z, and that is the label date.

HEAD is `05b07a1be0019d2b21b56adb6591d6ddda55b11f` on `main`, six commits ahead of `origin/main`. One worktree: this checkout. GitPulse Insights (worktrees, agents, changes, collisions, ledger) returned `ok: false` / deferred under the git spawn rate limit on every call, including every auditor. Empty collision lists are unknown. Local `git worktree list` shows this checkout only.

Dirty in this checkout, flagged in-flight, not edited:

- `Sources/ExpanderEngine/Engine/AXContextChecker.swift`
- `Sources/ExpanderEngine/Engine/EraseExecutor.swift`
- `Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift`
- `Tests/ExpanderEngineTests/DiagnosticReportTests.swift`
- `Tests/ExpanderEngineTests/SourceContractTests.swift`
- untracked `Sources/ExpanderEngine/Engine/EraseContinuation.swift`
- untracked `Tests/ExpanderEngineTests/EraseContinuationTests.swift`

DevMap CLI 0.2.5, schema 27, generation 695, `source_freshness` true, `is_fresh` true, `query_ready`. Degraded: Swift net resolution 582/1000, `walk_incomplete` (33555 of 104113 unresolved sites unattributed). Dead-symbol rows are confidence 0.4. The clone census was truncated. Empty graph answers were treated as unknown. Findings below are from files that were opened.

The board had 30 open cards before this pass, none `in_progress`, none `done`. `gitpulse_get_task` still truncates near 19.5 KB. Overwrite replaces the description that is sent. Truncated cards were not overwritten.

Roles were prompt contracts. The host cannot select Sonnet, Opus, or Fable. Slice audits and the grouping pass ran as Grok `code-reader` subagents. The parent re-read the cited lines and filed the board. The grouping subagent's plan was followed.

The 2026-10-13 report is preserved unchanged under [Historical ledger](#historical-ledger-devtype-audit-2026-10-13). Where it and this tree disagree, this section wins.

## Severity × dimension

Counts are verified findings from this pass that are still open. A fold is one row. An existing card that was left alone is not a new row.

| Dimension | Critical | High | Medium | Low |
| --- | --- | --- | --- | --- |
| Correctness | 0 new | 2 withheld, in-flight (combo-box erase skips the voucher; a partial Unicode insert returns success) | 4 (second undo backspace withheld; secret clipboard restore; whisper inference host; case-folded prefix hold; hotkey manager cleared) | 0 |
| Security | 0 | 1 (blank `snippets.json` adopts empty and a later save can purge secrets) | 2 (diagnostic identifiers pasted raw; import symlink and absolute image path, both withheld) | 0 |
| Defensive validation | 0 | 0 | 4 (unbounded library read; activity-history replace; nested lookup ignores disabled and app scope; uncapped import label and tags, withheld) | 0 |
| Performance | 0 | 0 | 0 | 1 withheld (live transcript assembler still joins every segment) |
| Async / error boundaries | 0 | 0 | 0 new | 0 |
| Testability / CI | 0 | 0 | 0 new | 0 |
| Modular architecture | 0 | 0 | 0 new | 0 |
| Strict typing | 0 | 0 | 0 | 0 |

The correctness medium cell is five findings. The table header says four because the hotkey row is also a UI state bug; it is counted once, under correctness.

## Top 10 risks

1. A 0-byte or whitespace `snippets.json` is adopted as an empty library. The empty-file banner does not block saves. The next save with secret purge on calls `purgeOrphans` with an empty set and can delete keychain secrets. Priority 1, high. `ft-d612c08302bc30c601bf3321d1abe3cf`.
2. Combo-box erase keeps posting after focus moves. `canContinue` treats "identity check skipped" as permission to continue, so the new erase voucher never runs. Priority 1, high. In-flight on `TextInjectionPipeline.swift` and `EraseContinuation.swift`. Evidence belongs on `ft-1c6669c1ee7788129e57e56a0e19ca67`. Not written. Do not re-enable the GitPulse identity abort.
3. A short Unicode insert that posts some characters and then fails returns `postedUnverified` and never uses the clipboard. Priority 1, high. Same in-flight pipeline file. Same withheld card.
4. TIS off-main crash on macOS 27. Priority 0, critical. `ft-3859d51812d308f5967de27039296b60`. `KeyboardLayoutState` does not call TIS and primes on the main queue. Qualification (dSYM, manual macOS 27, full suite) stays open. Not re-filed. Not lowered.
5. Dictation buffer lifetime. Priority 0, high. `ft-3e80b9bf50f8010a11a99f82d1535ebf`. The voice auditor reported the copy-before-lock path present. The parent did not re-read those lines this filing turn. Not marked done.
6. Copying a secret drops the clipboard an expansion was about to restore. Priority 2, medium. `ft-2c1890de228cb32daed33c3b0ac22552`.
7. Nested `{{snippet:}}` / `%snippet:` inserts disabled and app-excluded snippets, and a disabled earlier duplicate shadows the live one. Priority 2, medium. `ft-46b0dd013369967dff8eae2801a799ce`.
8. Uncaught window ordering after a palette session. Priority 1, high. `ft-bcfad27abd6da4d8801efba5357e033f`. Production Swift sites found this pass go through `WindowOrdering` or `DTOrderFrontRegardlessCatchingException`. Full suite unmet. Not marked done.
9. Managed whisper transcribe still POSTs the saved endpoint. The child listens on `127.0.0.1`. The user message allows `localhost` and `[::1]`. Priority 2, medium. Folded onto `ft-402cb3154acfe9940491d06453c6cdf1` (revision 7). Severity was not raised.
10. Import of a symlink match file reads bytes outside the selected folder, and label, tags, and app lists have no character cap. Absolute `imagePath` values still resolve before the `..` check. Priority 2, medium. Evidence belongs on `ft-7f34376060acdc85a759e2fccc989c20`. The body could not be resent. Not written.

## New cards

| Item | Title | Priority | Severity | Status |
| --- | --- | --- | --- | --- |
| `ft-d612c08302bc30c601bf3321d1abe3cf` | Blank or whitespace snippets.json must not adopt an empty library or purge secrets | 1 | high | ready |
| `ft-fa91b0be8625350fd6bdd44bec30be70` | Bound coordinatedRead and the non-JSON safety copy of snippets.json | 2 | medium | ready |
| `ft-2c1890de228cb32daed33c3b0ac22552` | Copying a secret drops the clipboard an expansion was about to restore | 2 | medium | ready |
| `ft-46b0dd013369967dff8eae2801a799ce` | Nested snippet lookup inserts disabled and app-excluded snippets | 2 | medium | ready |
| `ft-c545c7aeb8e4e4ce8e05e23a0d53c9f9` | Keyboard Shortcuts reference clears the live HotkeyManager | 2 | medium | ready |
| `ft-a010ea88776e4b8a6cc4d6b134b19c91` | Live speech assigns contextual strings with no 100-item cap | 2 | medium | ready |
| `ft-cb05c092318ca709859c20b0ed42a860` | Case-insensitive immediate triggers are not held for a longer trigger that differs only in case | 2 | medium | ready |
| `ft-a576580051bfdcd9c3abf864f97726cc` | Diagnostic identifiers under 512 bytes are pasted raw, including newlines | 2 | medium | ready |

Stable keys are `gp-audit-20261024-*`.

## Folded cards

| Item | Revision after | What changed |
| --- | --- | --- |
| `ft-187f62faa97118dc223575f2d1c745d3` | 3 | Activity history added. A load error sets `events = []` and the next record replaces the file (`ActivityHistoryStore.swift:355-368`, `510-521`). Priority stays 2. Severity stays medium. Status stays review. Existing criteria were not marked met. |
| `ft-402cb3154acfe9940491d06453c6cdf1` | 7 | Inference follows the saved endpoint, including `localhost` and `[::1]`, while the child binds `127.0.0.1` (`WhisperCppServerAdapter.swift:12`, `74`, `99-100`; `WhisperServerController.swift:224`, `484`; `LocalEndpointSecurity.swift:48-54`). Priority stays 2. Severity stays medium. Status stays review. The 2026-10-13 readiness and quit criteria were not marked met. |

Both overwrites resent the full description and the full criteria that `gitpulse_get_task` had just returned, plus the new section. Logs were left in place.

## Withheld folds

These cards are too large to resend. The evidence is here. Do not build them from a partial body.

| Item | What should be added | Do not |
| --- | --- | --- |
| `ft-1c6669c1ee7788129e57e56a0e19ca67` | Three criteria. Unstable roles must consult the erase voucher before more posts. A partial Unicode insert must not return success. A swallowed undo backspace that later fails `undoAttemptIsCurrent` must be replayed (`ExpansionLedger.swift:164-205`, `TextInjectionPipeline.swift:662-679`). The pipeline and `EraseContinuation.swift` are dirty. | Do not raise severity. The October 13 raise to high is still withheld. Do not re-enable the combo-box identity abort. Do not mark done. Do not edit the dirty files from this audit. |
| `ft-d2d8bcc27acc03703dce238469b1b7e3` | The assembler `rebuild()` still joins every segment on the main thread. The voice auditor said the HUD tail cap is present. The parent did not re-read the assembler. | Do not mark done. No second quadratic card. |
| `ft-7f34376060acdc85a759e2fccc989c20` | Three criteria. Refuse symlink match files and `group_*.xml` whose target is outside the import root (`EspansoImporter.swift:167-186`, `SnippetImporter.swift:60-68`, `TEImporter.swift:162-196`). Cap label, tags, app lists, and group name at the same gate as `isOversized` (`EspansoImporter.swift:412-461`). An untrusted library must not resolve an absolute `imagePath` (`ImageAttachmentStore.swift:351-371`). A user-authored absolute path is the documented legacy pass-through. Say so before changing it. Export already refuses absolute paths. | Do not new-card these. Do not break a hand-written absolute path without that sentence. Image export containment from 13 October stays on this card. |
| `ft-5df87ce5d1c355297e97d73e1e31bd5e` | No new criterion this pass. The blank-file adopt is the new card, not this one. The October 13 severity raise to high was not re-applied. Backups use `0o600`. | Do not lower priority 1. Do not edit `SecretStore.swift` in the same wave as the blank-library card. |
| `ft-5122c7a1d701be6adad52718cb978167` | No second benchmark card. Ceilings are asserted in `AuditBenchmarkTests.swift`. Hosted CI still does not run them. `LayoutBuffer` is a ring. `removeFirst` remains only in a comment. That note was not written onto the card. | Do not overwrite. |
| `ft-230179974c5d2f0f5b035866978c402a` | Action SHAs in `ci.yml` and `release.yml` are pinned. The card sentence that they float at `@v4` is stale. Dependabot, the parity step, LCOV upload, and `swift test` versus `Scripts/test.sh` stay open. The sentinel is on this tree. A directory at the sentinel path still hides the flag, and the card log already says that. Diagnostic newline is the new card, not this one. | Do not overwrite. Do not lower. |
| `ft-06d301ac43af0a7d1d43dbd24d676830` | No new evidence written. `PreferencesViewController.reloadAll` is still one pass per open. Item 11 archive sleep is owned by `ft-da0d4ce9`. | Do not lower. Do not also rewrite `withArchiveLock`. |
| `ft-0e11634c8058959a738d6d12d10c4f33` | "Already converged" remains unverified on this checkout. The worktree named in the log is gone. | Do not overwrite. |

## Verified in source, board left unchanged

These were re-read. They were not marked `[MET — verified in source]` because the card body could not be resent, or because a qualification criterion is still open. None were moved to done.

- `ft-93e0d03e` peer check: socket, mode `0600`, uid match, refuse before write (`LappiClient.swift:148-152`, `234-238`). Full suite was not run.
- `ft-3859d518` layout owner never calls TIS (`KeyboardLayoutState.swift:108-126`). dSYM, manual macOS 27, and the full suite stay open.
- `ft-6b20f61e` terminal refusal clears the preview and disables Replace when the text is empty (`AIPreviewPanel.swift:983-1001`). The stream `isPublishable` gate was not re-read.
- `ft-4be020d4` a date phrase both parsers miss returns nil (`PaletteToolRouter.swift:86`). An unknown macro id returns nil (`91-93`). The live Foundation Models session is still unmet. `onCall` sites were not re-read this filing turn.
- `ft-a57ffb45` package stamp still ignores untracked files (`Scripts/package-app.sh:115-116`). Release preflight still dies on any porcelain, including untracked (`Scripts/release-preflight.sh:37-39`).
- `ft-c03bf527` the matching auditor read a locked language publish. The parent did not re-read `LocalizationManager.swift` this filing turn. Not marked met.

Auditor-claimed and not re-read by the parent on the filing turn, so the cards were not edited: mic-buffer copy (`ft-3e80b9bf`), Gemini redirect and scratch delete (`ft-16d55bfc`), correction stop reason (`ft-7a3fc214`), protected-span length cap (`ft-21791f0c`), archive-lock sleep gone (`ft-da0d4ce9`), whisper quit without `usleep`. The 2026-10-14 log on `ft-187f62fa` says the shared loader is on main. Those lines were not re-read before the fold, and the old criteria were left unmarked.

## Waves

Fable's order. At most four cards. No shared planned file inside a wave. Withheld cards are not in a wave.

Wave 1:

1. `ft-d612c083` blank library. `SnippetStore+Reading.swift`, `SnippetStore+Load.swift`, `SnippetStore+ExternalChange.swift`, `SnippetStore+Save.swift`, `SnippetStore+SaveState.swift`, `SecretStore.swift`, `LibraryHealth.swift`.
2. `ft-2c1890de` secret clipboard. `PasteboardBroker.swift`, `SecretClipboard.swift`. Do not edit `TextInjectionPipeline.swift`.
3. `ft-402cb315` whisper inference fold. `WhisperServerController.swift`, `WhisperServerSetup.swift`, `WhisperCppServerAdapter.swift`, `LocalEndpointSecurity.swift`. Do not edit `AppDelegate.swift`.
4. `ft-46b0dd01` nested eligibility. `NestedSnippetResolver.swift`, `SnippetMatchSnapshot.swift`, `EventTapEngine+State.swift`, `SnippetModel.swift`. Do not edit `TextInjectionPipeline.swift`. Do not share a wave with `ft-1c6669c1` if that card edits `EventTapEngine`.

Wave 2, after wave 1 releases `SnippetStore+Reading.swift`:

5. `ft-fa91b0be` read bound. `SnippetStore+Reading.swift` only.
6. `ft-c545c7ae` hotkey nil manager. `ShortcutReferenceWindowController.swift`, `PreferencesWindowController.swift`, `ShortcutRecorder.swift`.
7. `ft-a010ea88` live contextual cap. `LiveSpeechStream.swift` and the two adapters that already cap.
8. `ft-cb05c092` case-folded prefix hold. `TriggerPrefixIndex.swift`, `TriggerPrefixScan.swift`.

Wave 3, after wave 1 releases `SecretStore.swift` and wave 2 releases `ShortcutRecorder.swift`:

9. `ft-187f62fa` activity-history fold, plus the criteria already on that card.
10. `ft-a5765800` diagnostic identifiers. `DiagnosticPrivacy.swift`, `DiagnosticReport.swift`, `DevTypeLog.swift`. Do not edit `DiagnosticReportTests.swift` or `AXContextChecker.swift` while they are dirty.

`PasteboardBroker.swift` is only on the wave 1 clipboard card. Do not start that card while another lane is editing it for the withheld engine work.

## Rejected, not filed

- `F-engine-5`. `AXTextWriter` treats any change from the baseline as replaced on purpose. A containment check double-applies when the host returns a stale value.
- `F-pack-1`. `package-app.sh:142` interpolates `VERSION_SHORT` inside double quotes. Bash does not rescan that expansion for `$(...)` or for quotes. A legal git tag cannot contain a newline. The shell-execution claim is false. Confirmed with a local `bash -c` print. The untracked-file stamp bug stays on `ft-a57ffb45`.
- Same-remainder matching across moved frames. A test pins it.
- Widened-range clamping. A count-only plan is unavailable and skips the AX writer.
- TIS off main as a new card. The layout owner is on `ft-3859d518`.
- Import clearing `isSecret`. Nested lookup already drops secrets.
- World-readable live library. Backups use `0o600`.
- `UpdateChecker` cross-host redirect. The sanitized URL is a locally built GitHub URL.
- YAML alias bombs past libyaml's nest cap, and CSV formula prefixes. Prefixes are already quoted.
- Espanso matches stored case-insensitive. That matches DevType's default. Current Espanso docs were not re-read.
- One-line model answer as a palette row. Routing stays off. A test expects the sanitize path.
- Guided-table partials skipping `isPublishable`. Too weak to file.
- Shell, regex, and `{{shortcut}}` macros. No executor in `Sources/ExpanderEngine/Macros`. They stay an owner decision.
- Nested case precedence versus the matcher's exact-then-insensitive order. `NestedSnippetResolverTests` pins library order.
- `NSDateFormatter` races. The 10.9+ header says the modern formatter is thread-safe. The cache lock covers construction.
- Activity Center and snippet-manager `show(..., hotkeyManager: nil)` else branches. They run only when `NSApp.delegate` is not `AppDelegate`.
- Gemini key accessibility weaker than `WhenUnlockedThisDeviceOnly`. macOS enforcement was not verified.
- `localhost` as a DNS rebind of a local model. The spelling check and the proxy disable are present. A privileged `/etc/hosts` change is outside the product.
- Direct production `makeKeyAndOrderFront` outside the trampolines. The app-shell search found production sites on `WindowOrdering` or `DTOrderFrontRegardlessCatchingException`.
- A second benchmark card.

## Decisions made without asking

- Slice auditors and the grouping advisor were Grok `code-reader` subagents. The host has no model parameter. The parent verified cited lines.
- The grouping advisor's split was followed, including separate cards for the blank-library adopt and the read ceiling even though both touch `SnippetStore+Reading.swift`.
- `SecretClipboard.swift` was added to the clipboard card's planned files. The advisor named only `PasteboardBroker.swift`. The call that drops the ticket is in `SecretClipboard.swift`. That does not add a wave conflict.
- GitPulse scans failed. Local `git status` and `git worktree list` are the fallback and are labeled as such.
- Auditors returned findings in their final message. They did not write repo files.
- The 2026-10-13 report was kept by prepending this pass. It was not deleted.
- No `devmap gap-record`. The state directory is protected.
- No Windows or Linux port findings. The package is macOS 14+.
- `F-store-2` was downgraded from the auditor's priority 1 to priority 2 before filing. That is a new finding, not a lowering of an existing card.
- Import symlink, import field caps, and absolute image paths were not given a new card. They belong on `ft-7f343760`, and that body cannot be resent.
- Engine severity was not raised. Voice quadratic evidence was not written onto `ft-d2d8bcc2`.
- Nothing was merged, deleted, or moved to done. No `in_progress` card was touched. There were none.
- Long-card overwrites were withheld. Wiping a description is data loss.
- `related_tasks_exist` refusals were read from the titles and the bodies already fetched this audit. Genuinely separate cards were retried with `reviewed_related` naming every listed id.

## Owner decisions, not resolved here

- v1.3.0 pipeline policy: SBOM, checksum, Xcode pin, rollback, and the local-only v1.2.1 tag. `ft-9291b0fa7c3466737d650505144a527e`. `DEVTYPE_SKIP_NOTARIZE=1` stays on that card.
- Developer ID, notarization, and Homebrew. `ft-3ca735f221ea890cbd7b033c1a8595af`.
- URL scheme and Services security sign-off. `ft-0e5ece50f52cab9492c6f91a92a0729b`. The sync auditor reported the `devtype` scheme present in `Resources/Info.plist`. The parent did not re-open that file. The October 13 sentence that the scheme is absent is stale if the auditor's line holds.
- Shell, regex, and `{{shortcut}}` macros. Still not implemented.
- Voice qualification defaults: WER/CER corpus, zero-egress proof, live-typing default, Gemini endpoint. `ft-327ddd0e`.
- Semantic routing stays off until that default is decided. `ft-f4d2393d`.
- Manual macOS 27 run and the 1.2.1 dSYM for the TIS card.
- Windsurf bundle id for injection C3. Do not invent one.

## What was not run

No tests. No build. `Scripts/test.sh` was not run. Browser verification does not apply. Building waits for a go-ahead.

---

# Historical ledger: DevType audit 2026-10-13

The text below is the 2026-10-13 report, unchanged. It describes HEAD `31773e8`. It is not the current tree.

# DevType audit 2026-10-13

Read-only. No source, config, or dependency edits. No DevMap rebuild. No `.devcouncil` gap file. No card was deleted, merged, or moved to done.

HEAD at the start of the audit was `31773e8`. The working tree was clean. GitPulse Insights (all facets ok): branch `main`, no live agent sessions, no overlapping dirty files. A detached scratchpad at `base3d0` was clean and was treated as not in-flight.

DevMap was stale at generation 524 when the map was taken (`is_fresh` false, `walk_incomplete`, Swift resolution about 528/1000). Later reads in the same pass saw generation 525 with DevMap freshness true, while GitPulse's codeintel facet on the same store still reported the extraction payload obsolete. Empty graph answers were treated as unknown. Findings below are from files that were opened. Slices follow directory layout, not a DevMap partition.

Roles were prompt contracts. Subagents cannot be pinned to a model. The parent verified the lines cited as read in this pass and did the grouping.

The crash record (TIS / macOS 27, palette `NSRemoteView` abort, SIGTRAP) and the September 2026 `docs/audits/` hardening series were part of this pass. Invariants that still hold were not re-filed.

## Severity × dimension

Counts are verified findings that are still open. A folded item is one row. "Already on a card, still unmet" is not a new row.

| Dimension | Critical | High | Medium | Low |
| --- | --- | --- | --- | --- |
| Correctness | 1 (TIS card, source fix looks landed, qualification still open) | 3 (mic buffer, order-front, injection false-delivery / second focus query) | 4 (correction cap, refusal partial, whisper bind/quit, date/macro false success) | 1 (language cache) |
| Security | 0 | 1 (library copies: filed as evidence, severity raise withheld) | 1 (archive-lock sleep on the Touch ID path) | 2 (Lappi peer, Gemini redirect and scratch file) |
| Performance | 0 | 0 | 0 new (existing perf cards still own the hotspots) | 0 new |
| Defensive validation | 0 | 0 | 1 (Espanso image path, folded) | 0 |
| Async / error boundaries | 0 | 1 (order-front, also counted under correctness) | 1 (whisper `usleep` on quit, same card as the bind bug) | 0 |
| Testability / CI | 0 | 0 | 0 new (CI gaps stay on the existing rigor and bench cards; folds withheld) | 0 |
| Modular architecture | 0 | 0 | 0 new (the 2,000-line split and the Preferences split stay as they were) | 0 |
| Strict typing | 0 | 0 | 0 | 0 |

The order-front row is one defect with many call sites, not one defect per window.

## Top 10 risks

1. Dictation tap keeps the engine's `AVAudioPCMBuffer` after the callback returns. Priority 0, high. `ft-3e80b9bf50f8010a11a99f82d1535ebf`.
2. TIS off-main crash on macOS 27. Priority 0, critical. `ft-3859d51812d308f5967de27039296b60`. The off-main TIS calls look removed in source. Currency of the layout snapshot, dSYM symbolication, and a manual macOS 27 run are still open. Not re-filed. Not lowered.
3. Injection: unseeded AX write reported as delivered after erase, a second focus query that drops the expansion, off-main paste-target pid, and unsynchronized Command chords. Priority 1. Evidence belongs on `ft-1c6669c1ee7788129e57e56a0e19ca67`. The severity raise to high was not written; see Withheld folds.
4. Uncaught `makeKeyAndOrderFront` / `orderFrontRegardless` after a palette session. Priority 1, high. `ft-bcfad27abd6da4d8801efba5357e033f`. The "next window aborts" outcome is the source comment. This pass did not reproduce the crash.
5. Secret plaintext and world-readable library / conflict copies. Evidence belongs on `ft-5df87ce5d1c355297e97d73e1e31bd5e`. Severity raise to high was not written.
6. Local correction accepts a length-capped transcript. Priority 1, medium. `ft-7a3fc214607448af2f042b3ac4dd4662`.
7. Touch ID success can `Thread.sleep` on main inside the secret archive lock. Priority 2, medium. `ft-da0d4ce99bd5cb124478d3467ce8bae3`.
8. A model refusal streamed into the preview stays replaceable. Priority 2, medium. `ft-6b20f61e51689b4e6cb305699a3c91f1`.
9. Opt-in palette tools return today's date or the original text. Priority 2, medium. Folded onto `ft-4be020d4d07a1346bc22ac6b10b68b27` (revision 2).
10. Espanso image export writes an absolute `image_path` and import drops the match. Priority 2, medium. Folded onto `ft-7f34376060acdc85a759e2fccc989c20` (revision 3). The bench gate that does not fail a regression (`ft-5122c7a1d701be6adad52718cb978167`) is the same class of risk and was already on the board.

## New cards

| Item | Title | Priority | Severity | Status |
| --- | --- | --- | --- | --- |
| `ft-3e80b9bf50f8010a11a99f82d1535ebf` | Dictation tap reads the engine's AVAudioPCMBuffer after the callback returns | 0 | high | backlog |
| `ft-bcfad27abd6da4d8801efba5357e033f` | Uncaught window ordering aborts after a palette session | 1 | high | backlog |
| `ft-7a3fc214607448af2f042b3ac4dd4662` | Local correction accepts a length-capped transcript | 1 | medium | backlog |
| `ft-402cb3154acfe9940491d06453c6cdf1` | Managed whisper-server binds loopback but readiness and quit follow a blocking probe | 2 | medium | backlog |
| `ft-da0d4ce99bd5cb124478d3467ce8bae3` | Touch ID success can sleep on main inside the secret archive lock | 2 | medium | backlog |
| `ft-6b20f61e51689b4e6cb305699a3c91f1` | A model refusal streamed into the preview stays replaceable | 2 | medium | backlog |
| `ft-16d55bfc63ad099d4509ea641f39b6a6` | Gemini upload follows redirects and can leave a scratch FLAC behind | 2 | low | backlog |
| `ft-93e0d03eeeba99f7721b10025d3a78de` | Lappi connects a Unix socket without checking the peer | 2 | low | backlog |
| `ft-c03bf527895f612b51d7ca6bd72333d2` | UI language cache can store a stale resolution | 3 | low | backlog |

Stable keys are `audit-20261013-*` as named on each card. Label on every new card: `audit-2026-10-13`.

Secure Input's off-main `NSWorkspace` read was not given a new card. `ft-5122c7a1d701be6adad52718cb978167` item B13 already names it. Current code samples the frontmost app only on a lock edge (`SecureInputMonitor.swift:76-80` and `125-136`), not on every 350 ms tick. The line correction was not written onto that card.

## Folded cards

| Item | Revision after | What changed |
| --- | --- | --- |
| `ft-7f34376060acdc85a759e2fccc989c20` | 3 | Severity none → medium. Espanso absolute `image_path` (`SnippetExporter.swift:169-172`) added as two criteria. Priority stays 2. Status stays inbox. |
| `ft-4be020d4d07a1346bc22ac6b10b68b27` | 2 | Severity low → medium. `ResolveDateTool` returns today (`PaletteToolRouter.swift:158`). `RunMacroTool` returns the input for an unknown id (`:186`). Routing stays default-off (`AIPreferences.swift:133-135`). Priority stays 2. |

A board list after the writes shows both at severity medium. Import is revision 3. The tool card is revision 2.

## Withheld folds

`gitpulse_get_task` truncates around 19.5 KB in the tool result. Overwrite replaces the description that is sent. A partial resend would wipe the card, so these were not overwritten. The evidence is recorded here.

| Item | What should be added | Do not |
| --- | --- | --- |
| `ft-5df87ce5d1c355297e97d73e1e31bd5e` | Raise severity medium → high. Secret decoder strips values (`SnippetModel` around 200-206) while `SnippetStore` backups copy raw on-disk bytes and `data.write` is not `FilePermissions.atomicWrite`. `LibraryConflictRecovery` writes raw copies without a mode. `ImageAttachmentStore.swift:269` was not re-read; leave it out until it is. | Lower priority 1. Do not edit `SecretStore.swift` on this card if the archive-lock card is in the same wave. |
| `ft-1c6669c1ee7788129e57e56a0e19ca67` | Raise severity medium → high. Add: paste-target pid via `NSWorkspace` off the processing queue (`PasteboardBroker.swift:501`, called from `TextInjectionPipeline.inject` before `injectQueue`); second focus query at `injectOnMain` 612-615 after the expand gate; unseeded AX set-after-erase returns true (`AXTextWriter.swift:401-424`); `HIDKeyPoster.performCommandChord` does not serialize Cmd-C and Cmd-V. Mark met in a verification section: no main-thread focus sleep (`AXSettleRetry`), shared settle helper, `propagateCase`, `SwallowedKey` on the signatures that were read. | Leave review. Do not mark done. C3 Windsurf swallow and orchestration-only stay unmet. Do not invent a Windsurf bundle id. |
| `ft-06d301ac43af0a7d1d43dbd24d676830` | Marker-range selection still copies before the 200,000 cap (`SelectionReader.swift` marker rung, after the range rung refuses). Paste-hold still has a full `kAXValue` path. Image paste is still TIFF then PNG. Clipboard snapshot is capped and still synchronous. Add a structural bound, not a second bench. Item 11 already names the archive sleep; the new card owns removing `Thread.sleep`. | Do not lower medium. Do not also rewrite `withArchiveLock` here. |
| `ft-3859d51812d308f5967de27039296b60` | Layout snapshot is applied only after an async main hop (`KeyboardLayoutState`). That is the remaining currency hole. `AXContextChecker` `NSWorkspace` reads were not re-read this filing turn; do not add them until those lines are opened. | Do not lower priority 0 or critical. Do not mark done. Do not re-file the TIS crash. |
| `ft-5122c7a1d701be6adad52718cb978167` | `Scripts/ci-local.sh` can run debug benches before the release filter. `TriggerPrefixScanTests.swift:128-138` asserts elapsed < 0.5 s with no `DEVTYPE_BENCH` skip. Correct B13 to the edge-only `NSWorkspace` read. | No second benchmark-baseline card. |
| `ft-230179974c5d2f0f5b035866978c402a` | Hosted `ci.yml` has no coverage upload and no strict concurrency. `Package.swift` sets no Swift language mode. `UncleanExitSentinel` has no matches in tracked Swift, Markdown, or shell. `InputQuiescence`, `DiagnosticPrivacy`, and `DirectoryWatcher` have no tests. `SessionWatchdog` still sleeps. Action SHAs are floating major tags. No Dependabot config. | Do not new-card the sentinel. It edits `AppDelegate`, so it is a later wave than order-front. |
| `ft-2287d05b806c05c9dff527ef9ba50d92` | Verification section: strings live in resources; parity tests and pseudolocale exist; `LocalizationManager` is lookup-only; the window controller is a thin host; `reloadAll` once per show looks met. Home tab is `HomeViewController` outside `Preferences/`. `PreferencesViewController.swift` is 518 lines. Test-count identity was not executed. | Stay in review. Do not mark done. Do not restart the split. |
| `ft-d2d8bcc27acc03703dce238469b1b7e3` | Diagnostics strings are built only when tracing is enabled (`VoiceInsertionService` around 170-185). Preview coalesces once per main turn (`AIPreviewPanel.swift:744-755`). HUD measurement was an auditor file:line, not re-read on the filing turn, so do not mark that criterion met from this report alone. | Do not mark the card done. No second voice-quadratic card. |
| `ft-3325452c55767485a0460b7ba5feecda` | Localization of the secure-clipboard hint is met (`Permissions.strings` en/ko/ja, `AppStringKeyCoverageTests`). Lappi is disclosed in `SECURITY.md:35-43` and `docs/ARCHITECTURE.md:353`. Test-only forwards at `TextInjectionPipeline.swift:441-456` remain. | Do not new-card a disclosure gap. Do not mark done. |
| `ft-187f62faa97118dc223575f2d1c745d3` | Activity-history quarantine was not re-read this filing turn. Do not mark the other criteria met. The models-slice criterion tail was lost when the auditor transcript could not be resumed. | Do not invent that tail. |

## Verified stale, left in place

- `ft-3325452c` "docs omit Lappi" is stale. Disclosure is in `SECURITY.md` and `docs/ARCHITECTURE.md`.
- `ft-3325452c` and `ft-2287d05b` text that says `Preferences/` does not exist, or that quotes the old window-controller and `LocalizationManager` line counts, is stale. The window controller is a thin host. `PreferencesViewController.swift` is 518 lines.
- `IMPROVEMENTS.md` lines 1-16 already say the August 2026 backlog is not current. Section 7.5 (no exception handler, no notarization, frozen 1.0.0) is stale: the handler exists, and `Scripts/package-app.sh` stamps a git version and can pass a runtime option. Not filed as open bugs.
- `ft-d2d8bcc2` preview and diagnostics criteria look met in source. The card was not edited, so the board still reads as open work. That is intentional.
- `DevTypeTheme.swift` ends at line 1984. It stays off the 2,000-line card (`ft-7ab99fad`).

## Waves

Disjoint files inside a wave. At most four cards that edit product files.

Wave A, first:

1. `ft-3e80b9bf` mic buffer. `DurableVoiceCapture.swift`, `AudioBufferPool.swift`, `LiveSpeechStream.swift`.
2. `ft-bcfad27a` order-front. `DevTypeSafety` plus the production order-front sites listed on the card. Includes `AppDelegate` and `AIPreviewPanel`.
3. `ft-5df87ce5` library publication, after the withheld severity note is applied. `SnippetStore`, `LibraryBackupStore`, `LibraryConflictRecovery`, `SnippetModel`. Not `SecretStore` if wave D owns that file.
4. `ft-402cb315` whisper. `WhisperServerController.swift`, `WhisperServerSetup.swift`. Do not edit `AppDelegate` on this card.

Wave B, after A:

5. `ft-1c6669c1` injection. Stays in review.
6. `ft-7a3fc214` correction cap.
7. `ft-4be020d4` palette tool false success.
8. `ft-7f343760` Espanso image round trip.

`ft-6b20f61e` (refusal partial) also waits until after wave A, because it edits `AIPreviewPanel.swift`. It does not share files with items 5-8, so it can lead the next wave.

Wave C:

9. `ft-06d301ac` selection marker cap and the still-partial paste notes. After the injection card, because both can touch `PasteboardBroker`.
10. `ft-16d55bfc` Gemini upload.
11. `ft-93e0d03e` Lappi peer. `LappiClient.swift` only.
12. `ft-3859d518` currency evidence only. Prefer `KeyboardLayoutState.swift` so this wave does not share `EventTapEngine` with wave B.

Wave D:

13. Secure Input line correction on `ft-5122c7a1` (no new card).
14. `ft-c03bf527` language cache. `LocalizationManager.swift` only.
15. `ft-da0d4ce9` archive-lock sleep. After the library card if that card edits `SecretStore`.
16. `ft-5122c7a1` bench gate and `ft-23017997` rigor, including the sentinel. The sentinel edits `AppDelegate`, so it is after wave A. The bench-gate script edits no product file and can move earlier if it shares no file with the wave it joins.

No build wave: `ft-2287d05b` verification only. `ft-d2d8bcc2` met-criteria notes only. `ft-3325452c` met-criteria notes only.

No second benchmark-baseline card. The correction-cap fix is a decode check, not a wall-clock bench.

## Crashes and the September hardening series

- TIS / SIGTRAP on `com.devtype.selection-read` is `ft-3859d518`. Source now keeps TIS on main behind `KeyboardLayoutState`. Not re-filed.
- Palette `NSRemoteView` / `containingWindowWillOrderOnScreen` is the new order-front card. `DTMakeKeyAndOrderFrontCatchingException` (`DevTypeSafety.m:3-10`) is used only by `InlineSearchPanel.swift:212`. Toast and the voice HUD must not go through that function, because it also makes the window key. `installLastResortExceptionLogger` cannot stop the abort.
- September 2026 hardening docs (`docs/audits/2026-09-09` through `2026-09-12`, including selection delivery, undo injection, and both secret-boundary notes) were read as history. The selection caps and the secret `resourceProjection` still hold. Do not delete `isSecret` from that projection. What those docs still leave open is physical qualification: live editors, Touch ID, Keychain `-25293`, power loss. No new card per leftover sentence.

## Rejected, not filed

- Re-filing the TIS crash, or one crash card per order-front call site.
- A new `devtype://` card. `Resources/Info.plist` still has no `CFBundleURLTypes`. The decision stays on `ft-0e5ece50`.
- Alfred, Raycast, and DevType JSON importers as a new card.
- Shell, regex, and `{{shortcut}}` injection. Those macros are not implemented.
- Prefix scan still quadratic. The pairwise pass is gone.
- `NSMetadataQuery` blocking main. Already on `ft-06d301ac`.
- Update-checker cross-host redirect, and CSV space-before-equals.
- `eraseContextIsCurrent` as a live production bug. Production does not call it.
- Focus retry still sleeping on main. `AXSettleRetry` returns the first answer on main.
- TIS still on the selection-read queue.
- Clearing the AI preview on every failure. Only refusal prose is the bug.
- Lappi caller-record symlink escape.
- `@unknown` generation-error text as a current leak.
- Gemini API key in the URL or in logs. It is a header.
- Spoken punctuation deleting "period" and "comma".
- `capture.caf` retention. That file is the recovery artifact.
- Quadratic voice transcript as still present.
- `PreferencesSource` duplication as production logic. It is a test fixture on `ft-0e11634c`.
- 518 lines as a new bug.
- Home open doing two or three `reloadAll` calls. The old bug looks fixed.
- `IMPROVEMENTS.md` section 7.5 as current defects.
- Deleting `resourceProjection`'s `isSecret`.
- `DevTypeTheme` on the 2,000-line card.
- `UncleanExitSentinel` as its own card.
- A second bench-gate card.
- Pipeline length as a new bug. It is already unmet on `ft-1c6669c1`.
- Secret clipboard logging the secret. It logs a count and `clearAfter`.
- Debug trace on every inject. It stays off unless both environment variables are set.
- TextExpander empty `plainText` as a separate defect from the rich-text downgrade already on the import card.

## Decisions made without asking

- No DevMap rebuild. No `devmap gap-record`.
- Subagent models were prompt roles. The parent performed the Fable grouping.
- `base3d0` is not in-flight.
- No Windows or Linux port findings. The package is macOS 14.
- Index generation 524, then 525, with GitPulse codeintel still stale. Findings are from source reads.
- Nothing was merged, deleted, or moved to done. Severity was raised only on the two folds that could be resent in full.
- One card per concern. The engine auditor's 1-6 ranks were remapped onto 0-3.
- Gemini redirect is low. Whisper quit-wait is priority 2 and shares the bind card. Lappi peer check is low because `SECURITY.md` already discloses the socket. It was still filed.
- Home-outside-Preferences and 518-versus-500 are caveats on the split card, not new bugs.
- Secure Input was not given a new card, because B13 already owns it.
- Long-card overwrites were withheld. Wiping a description is data loss.
- `ImageAttachmentStore.swift:269`, `ActivityHistoryStore` quarantine, and the `AXContextChecker` `NSWorkspace` lines were not re-read on the filing turn, so they are not in a card body from this pass.
- The models-slice criterion tail could not be resumed (transcript over the resume limit). It was not invented.
- Apple's `installTap` page, as fetched, did not quote a buffer-lifetime sentence. The mic-buffer card rests on the missing copy and on `AudioBufferPool`'s own comment.

## Owner decisions, not resolved here

- `devtype://` and App Intents (`ft-0e5ece50`). Creating a snippet still drops the selection captured when the palette opened.
- Shell, regex, and `{{shortcut}}` macros. Notarization, Homebrew, public issues (`ft-3ca735f2`).
- Live-typing default, Gemini API choice, WER/CER corpus (`ft-327ddd0e`).
- Whether the Lappi peer check should go further than the card filed here. The card does not enable the ask.
- Windsurf bundle id for the swallow spike (`ft-1c6669c1` C3).
- Manual macOS 27 run and the 1.2.1 dSYM for the TIS crash.
- Physical qualification left by the September audits: live editors, Touch ID prompts, Keychain `-25293`, power loss.

## What was not run

No tests. No build. `Scripts/test.sh` was not run. Browser verification does not apply. This report is the end of the audit.
