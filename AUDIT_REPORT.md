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
