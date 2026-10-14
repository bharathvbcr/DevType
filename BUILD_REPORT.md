# DevType build report

Living status for the 2026-10-13 GitPulse backlog. Nothing has been merged to `main`. Nothing has been pushed. `AUDIT_REPORT.md` stays untracked.

HEAD at audit start: `31773e8`. This file is untracked on `main` along with `AUDIT_REPORT.md`.

## Wave D (in review)

Registered-worktree scan: `gitpulse_insights` and `gitpulse_collision_risk` both `ok: true`. Two worktrees (`main` dirty only by these two untracked reports, detached `base3d0` clean), 0 overlapping files, 0 unscanned, `sessions_ok` true, live Claude/Codex 0. Grok review worktrees under `~/.grok` are still not registered. Order-front's committed `AppDelegate.swift` edit is a later merge conflict, not a live hold this scan can see.

DevMap generation 549. `devmap_status` says `is_fresh` true and `source_freshness` true. GitPulse's codeintel facet on the same generation says `is_fresh` false (obsolete extraction payload). Impact walks are a lower bound (`walk_incomplete`, depth 2). `SecretStore.swift` has two partial-parse regions (bytes 5969 and 12245, 0 bytes lost). `resolvedLanguage` direct callers are `lookup`, `p`, and `plural` in the same file; unresolved namesakes for that name are empty. `withArchiveLock` direct callers are `consolidateIntoFile`, `delete`, `performExclusiveTransaction`, `set`, and `value`.

Three slices, disjoint files. The benchmark gate on `ft-5122c7a1` is already on `main` (`BenchmarkGate`, ceilings, B1, `Scripts/ci-local.sh` step 2b, `docs/DEVELOPMENT.md` local-only). B3 (palette keystroke with usage boosts) is not added. It touches the unmerged palette branch, so it is not started. Secure Input already samples `NSWorkspace` only on a lock edge (`SecureInputMonitor.swift` lines 76-80 and 125-136). `checkLockStatus()` still attributes on demand; the 350 ms tick does not call it. No code change, and the card text was not rewritten.

| Task | Revision at start | Slice |
| --- | --- | --- |
| `ft-c03bf527895f612b51d7ca6bd72333d2` language cache | 3 review | Branch `audit/ft-c03bf527-language-cache`. Implementation `6fa13376`, attack `797d4f74`. Agent filter 33 tests, 0 failures. Publish only if cache, language, and epoch are unchanged. Full suite and `dev verify` unmet |
| `ft-da0d4ce99bd5cb124478d3467ce8bae3` archive lock | 3 review | Branch `audit/ft-da0d4ce9-archive-lock`. Implementation `87f23033`, attack `acce5fe` (frozen clock spun), fix `7f5c622`. Agent filter 25 tests, 0 failures. A stalled injected clock refuses. Sync main `set` while busy returns `errSecIO` immediately. Physical Touch ID and Keychain `-25293` unmet |
| `ft-230179974c5d2f0f5b035866978c402a` rigor | 5 review | Sentinel slice only. Branch `audit/ft-23017997-unclean-exit`. Implementation `e628dd6`, attack `bba7bd2` (JSON 0/1 read as Bool; `..` copied), fix `7832f28`. Agent filter 28 tests, 0 failures. A directory at the sentinel path still hides the flag and does not delete children. CI, Swift 6, flake runs, and qualification stay unmet |
| `ft-5122c7a1d701be6adad52718cb978167` bench gate | left inbox | Section A and B13 already on `main`. B3 (palette keystroke bench) waits on the unmerged palette branch. Other hotspots not started |

After the wave, `gitpulse_insights` and `gitpulse_collision_risk` were both `ok: true` again: 2 scanned worktrees, 0 overlapping files, 0 unscanned, live Claude/Codex 0. Grok worktrees are still not registered. Codeintel generation is now 551, `is_fresh` false, `source_freshness` false (the indexed tree differs, and the extraction payload is obsolete). That is a lower bound, not a clean graph. Main's only dirty files are the two untracked reports. No benchmark was run this wave.

## Wave C (in review)

Registered-worktree scan this wave: `gitpulse_insights` and `gitpulse_collision_risk` both `ok: true`, 2 worktrees, 0 overlapping files, 0 unscanned, `sessions_ok` true. Grok worktrees under `~/.grok` are still not registered, so that scan does not cover them. DevMap generation 542: the devmap tool reports `is_fresh` true; GitPulse's codeintel facet on the same generation reports `is_fresh` false (obsolete extraction payload). Impact below is a lower bound (`walk_incomplete`, depth cap 2, one partial-parse file). `currentInputSourceID` has no indexed traversal start. A search of tracked Swift sources finds that name only in comments. The live owner is `KeyboardLayoutState`.

`ft-06d301ac` performance sweep stays in inbox. Its files overlap the TIS owner, this refusal card, the unmerged palette branch, preferences modularization, and `SecretStore`.

| Task | Revision | Status | Where the work is |
| --- | --- | --- | --- |
| `ft-3859d51812d308f5967de27039296b60` TIS | 4 review | code slice verified, not done | Owner already on `main` at `c772b4c`. Parent filter: KeyboardLayoutStateTests 12 + TIS source-contract 1, 0 failures, exit 0. dSYM, manual macOS 27, full suite, and `dev verify` stay unmet |
| `ft-93e0d03eeeba99f7721b10025d3a78de` Lappi peer | 3 review | not done | Branch `audit/ft-93e0d03e-lappi-peer`. Implementation `94fedc6`, attack `6f0bce1` (01600 wrote the query), fix `e488aae` (`0o7777` mask). Agent filter: 49 tests, 0 failures. No second OS user. Full suite and `dev verify` unmet |
| `ft-16d55bfc63ad099d4509ea641f39b6a6` Gemini redirects | 3 review | not done | Branch `audit/ft-16d55bfc-gemini-redirect`. Implementation `575548a`, attack tests `cb7994c`. Agent filter: 40 tests, 0 failures. No API choice. Full suite and `dev verify` unmet |
| `ft-6b20f61e51689b4e6cb305699a3c91f1` refusal | 3 review | not done | Branch `audit/ft-6b20f61e-refusal` from `main`. Implementation `6cc33d5`, attack tests `b73ad38`. Agent filter: 40 tests, 0 failures. Live model refusal, full suite, and `dev verify` unmet. Later merge with order-front may conflict in `AIPreviewPanel.swift` |

## Wave B (in review)

Started after Wave A was in review. Two `gitpulse_insights` / `gitpulse_collision_risk` calls were shed under load (`ok: false`, 0 worktrees scanned, sessions not observed). That result is unknown, not clean. `git worktree list` from this checkout shows only `main` at `31773e8` and detached `base3d0`. The three Wave A directories under `~/.grok/worktrees/apps-devtype/` are not registered worktrees of this repo. DevMap `devmap_status` on this checkout: generation 538, `is_fresh` true, `degraded_reason` null, repository.root this checkout. GitPulse's codeintel facet on the same generation says `is_fresh` false (extraction payload obsolete). Those two disagree; impact answers are a lower bound. `OpenAICompatibleCorrector` file-path impact missed (queried the AI directory; the file lives under Voice/Correction). Symbol impact is walk_incomplete at depth 2. `SnippetExporter` impact is walk_incomplete, 26 edges shown, 0 hidden. `PaletteToolRouter.swift` has partial-parse regions, so its blast radius is unknown inside those ranges.

| Task | Revision | Status | Where the work is |
| --- | --- | --- | --- |
| `ft-7a3fc214607448af2f042b3ac4dd4662` correction cap | 3 | review | Branch `audit/ft-7a3fc214-correction-cap`, commit `eaab053` on `61d43505`. Full suite and `dev verify` not run |
| `ft-4be020d4d07a1346bc22ac6b10b68b27` palette false success | 4 | review | Branch `audit/ft-4be020d4-palette-false-success`, commit `60d4a9e`. Live FoundationModels session not run |
| `ft-7f34376060acdc85a759e2fccc989c20` Espanso image path | 5 | review | Image criteria only, commit `289e742`. Alfred, Raycast, nested groups, and rich text stay open |

## Wave A (in review)

GitPulse Insights before Wave A: `ok` on agents, changes, collisions, ledger, worktrees. Live Claude and Codex sessions: 0. Registered worktrees: `main` (1 untracked file) and detached `base3d0` (clean). Collision risk: `ok`, 0 overlapping files, 0 unscanned, `sessions_ok` true. Gap: that scan does not see the three `~/.grok/worktrees` checkouts. They do not share files with each other. Codeintel facet at that time: generation 527, `analyzer_freshness` false, extraction payload obsolete. Impact from that store is unknown, not safe. Edits stay inside each card's files.

| Task | Revision | Status | Where the work is |
| --- | --- | --- | --- |
| `ft-3e80b9bf50f8010a11a99f82d1535ebf` mic buffer | 5 | review | Branch `audit/ft-3e80b9bf-mic-buffer`, commit `c7f724ff`. Second attack found no new break. Full suite and `dev verify` not run |
| `ft-bcfad27abd6da4d8801efba5357e033f` order-front | 6 | review | Branch `audit/ft-bcfad27a-order-front`, commit `1674c87`. Opus approved the diff. Full suite and `dev verify` not run, so it stays in review |
| `ft-402cb3154acfe9940491d06453c6cdf1` whisper | 6 | review | Branch `audit/ft-402cb315-whisper-probe`, commit `442a65d`. Ready requires the owned child to still be running. Full suite and `dev verify` not run |
| `ft-5df87ce5d1c355297e97d73e1e31bd5e` library | 8 | review | Branch `audit/ft-5df87ce5-library`, commit `0e0f561`, based on order-front. Zero-byte mode-000 overwrite publishes a readable file. Full suite and `dev verify` not run |

Prefix ids (`ft-3e80b9bf` and the others) are `not_found` on `gitpulse_complete_task`. The board key is the full id.

### Order-front is in review

Parent read `DevTypeSafety.m` (make-key `@try` calls both selectors; regardless calls only `orderFrontRegardless`), `WindowOrdering.swift`, `InlineSearchPanel.swift:212` (still calls `DTMakeKeyAndOrderFrontCatchingException`), Toast and Voice HUD call sites, and grepped `Sources/` for `showWindow(` (none). `testVoiceHUDNeverTakesFocus` now fails if the HUD calls `makeKeyAndOrderFront` or `NSApp.activate`. Adversarial commit `e677622` reported no product break. `orderOut` is off-screen and was left alone. Commit `1674c87`. Moved to review at revision 6. Pending before done: full `./Scripts/test.sh`, `dev verify`, and a parent re-run of the filtered suite. The filtered pass is agent-reported.

### Fixes that came back from attack, then landed in review

Mic `c7f724ff`: float64 is copied from the audio buffer list. `AVAudioBuffer.h` only returns `floatChannelData` for float32. Wakes use `NSCondition` and fire on the empty-to-non-empty transition. `dequeueAll` clears pending notices. The memcpy is before the lock. A second attack reported no new break.

Whisper `442a65d`: cancel of a hung post-launch probe stops that child from `onCancel`. `stop()` during the probe cannot be followed by `.success`. A blocked model open that was cancelled returns `.cancelled` and does not spawn. Success also requires `process.isRunning` (`WhisperServerController.swift:298`), which is the dead-child case from commit `74d2f6a`. Out-of-range ports never reach the `spawnedChildProbeURL` precondition.

Filtered suites are agent-reported. The parent read the deciding lines and did not re-run the suites.

### Implementer evidence, not yet re-run by the parent

- Mic: `./Scripts/test.sh --filter 'AudioBufferPool|LiveSpeechStream|DurableVoice|VoiceSessionRedesignTests'` reported 29 tests, 0 failures. Enqueue of a 2048-frame mono float buffer: 3223.5 ns/call in debug. No pre-fix enqueue baseline; enqueue was not on the hot path. Live microphone not opened.
- Whisper: `./Scripts/test.sh --filter WhisperServer` reported 43 ExpanderEngine tests passed. `stop()` 0.000114 s versus 2.036 s before the fix on the same fixture. `testStartAndStopRoundTrip` skipped (whisper.cpp not installed). `AppDelegate.swift` was not in the implementer's file list.
- Order-front: `./Scripts/test.sh --filter 'DevTypeSafetyTests|testToastNeverTakesFocus'` reported exit 0 before the `showWindow` return. That run does not cover the hole.

Full suite, `dev verify`, and Manvi evidence are not done. These cards will go to review, not done, after Opus approves.

## Tasks deferred or blocked

- `ft-5df87ce5d1c355297e97d73e1e31bd5e` library was deferred until order-front reached review, then started on a branch cut from `audit/ft-bcfad27a-order-front`. Severity was not raised medium to high: a partial overwrite would wipe the description. `SecretStore.swift` stays out of this card while `ft-da0d4ce99bd5cb124478d3467ce8bae3` is open.
- `ft-1c6669c1ee7788129e57e56a0e19ca67` injection. Already in review. Not restarted. Not marked done. Windsurf bundle id not invented.
- `ft-06d301ac43af0a7d1d43dbd24d676830` performance sweep. Not started. Item 1 must wait until the TIS owner is verified. Items also name files held by the palette, refusal, preferences, and secret-store cards.
- `ft-3859d51812d308f5967de27039296b60` TIS. Code slice is on `main`. Not lowered. Not marked done. dSYM and the manual macOS 27 run stay open.
- No-build cards are not marked done. On the board this session: `ft-2287d05b806c05c9dff527ef9ba50d92` is review. `ft-d2d8bcc27acc03703dce238469b1b7e3` and `ft-3325452c55767485a0460b7ba5feecda` are inbox. None were restarted.

## Benchmark deltas

| Path | Before | After | Gate |
| --- | --- | --- | --- |
| `AudioBufferPool.enqueue` 2048-frame mono float32, debug, 1000 calls | no baseline (not previously on the hot path) | 1906.3 ns/call after the float64 fix; earlier pass 3223.5 ns/call. Second attack printed 2432.2 ns/call in the same debug run | written justification. Parent has not re-timed |
| `WhisperServerController.stop` grace wait | 2.036 s blocking the caller | hung-probe stop 30–57 µs across agent runs; cooperative about 50–70 µs | under the 5% ceiling. Parent has not re-timed |
| Window ordering | not a hot path | no bench | not applicable |
| Correction `responseText` decode, debug, min of 8 × 4000 | reconstructed content-only decoder in the same build | about 1.13× then 1.18× (`previousMinNs` 9.8–10.3 ms per 4000, `currentMinNs` 11.0–12.1 ms) | over 5%. Written justification: the extra stop fields sit on the HTTP response path, after the request wait, not on the keystroke path. Parent has not re-timed |
| Palette tool resolve / Espanso image export | not keystroke paths | no bench | not applicable |

## New tasks filed

- `gp-protected-span-regex-hang` (`ft-21791f0c6a2e2de2a71c7b58af0de7b1`), inbox, revision 1. Agent-reported: a 900,000-character raw transcript did not return inside `ProtectedSpanExtractor` (ICU) before the length-cap flag was read. Parent did not reproduce it. Not folded into the length-cap card, the mic card, or `ft-d2d8bcc2`. Not fixed in this wave.

## Fable decisions

- Wave A ran mic, order-front, and whisper first. Library started only after order-front was in review, on a branch cut from that work, so `PreferencesWindowController.swift` keeps the `showWindow` removal.
- Whisper and order-front may proceed in separate worktrees even though order-front's blast radius includes `AppDelegate.swift`. The whisper card must not edit that file.
- Non-loopback whisper URLs stay rejected by `LocalEndpointSecurity`. The card's non-loopback case is `invalidEndpoint`, plus a localhost-versus-`127.0.0.1` probe test.
- `showWindow` is a return, not an approval. Adversarial review of order-front waits until that fix lands, so the attack hits the fixed code.
- Mic and whisper adversarial passes run against `cd7eff55` and `ad5396cd`.
- GitPulse prefix lookup is not a board key. Use the full `ft-` id.
- Wave B, when A is in review: correction cap (`ft-7a3fc214`), palette false success (`ft-4be020d4`), and the Espanso image criteria only. The Espanso card's nested-group schema migration, Alfred/Raycast importers, and rich-text spike are not this wave. Refusal (`ft-6b20f61e`) leads the following wave because it shares `AIPreviewPanel.swift` with order-front.
- Image export branched from `main`, not the library branch. It does not edit `SnippetStore` or `LibraryBackupStore`, so it does not revert the backup fix. `LibraryExporter.writeEspansoDirectory` is in scope only to copy the relative image bytes.
- Palette operation ids match a closed list after trim and ASCII case-fold. Stripping punctuation before the match was a fail-open and was sent back (`cf43023`).
- Correction decode is slower than a reconstructed content-only decoder by more than 5% in debug. Accepted as a written justification because it is not the keystroke path. No new `FailureCode` case.
- The Espanso card stays in review with the other import criteria unmet. It is not done.
- A live FoundationModels session for `app_choice.tool` was not run. That criterion stays unmet. The card is not done.
- Wave C branches Lappi, Gemini, and refusal from `main`. Order-front is not a ref in this checkout, so refusal does not stack on it. A later merge can conflict in `AIPreviewPanel.swift`. The performance sweep does not run beside these four. The TIS owner is not rewritten. Peer rejection reuses `connectRefused` and does not add a `LappiUnavailableReason` case. Gemini reuses `LocalEndpointURLSessionDelegate` and does not edit that delegate.
- Wave D is the language cache, the archive-lock sleep, and the unclean-exit sentinel. The library card did not edit `SecretStore.swift`, so the archive lock branches from `main`. The sentinel may touch `AppDelegate.swift` launch and termination only. It does not stack on order-front. The benchmark card stays inbox: its gate and the Secure Input edge sample are already on `main`, and B3 waits on the unmerged palette branch. Rigor components other than the sentinel stay unmet. No Swift 6 language mode. No fabricated qualification result.

## Owner decisions still pending

- `devtype://` and App Intents (`ft-0e5ece50`).
- Shell, regex, and `{{shortcut}}` macros. Notarization, Homebrew, public issues (`ft-3ca735f2`).
- Live-typing default, Gemini API choice, WER/CER corpus (`ft-327ddd0e`).
- Whether the Lappi peer check goes further than `ft-93e0d03eeeba99f7721b10025d3a78de`.
- Windsurf bundle id (`ft-1c6669c1` C3).
- Manual macOS 27 run and the 1.2.1 dSYM.
- Physical qualification: live editors, Touch ID, Keychain `-25293`, power loss.
- Nested snippet-group schema migration on `ft-7f343760`. Not started. The image-path criteria do not need it.

## Not verified

- Parent has not re-run the filtered suites or the full suite. Wave D counts above are agent-reported. Parent read the publish condition, the archive-lock stall check, and the crash-report integer parser.
- `dev verify` was not run. No DevCouncil lease.
- Live `AVAudioEngine` microphone path was not opened.
- `testStartAndStopRoundTrip` needs whisper.cpp, which is not installed.
