# DevType build report

Living status for the 2026-10-13 GitPulse backlog. Nothing has been merged to `main`. Nothing has been pushed.

Audit start: `31773e8`. This report and `AUDIT_REPORT.md` are committed at `b01a4f5`. The Wave E through Wave I sections, and the deferred pass below, are uncommitted updates on that commit.

## Pass after Wave I (deferred)

No code change. `ft-06d301ac` stays review, now revision 11, sequence 19981. Verification is null. `held_for_review` is false. The log is request `wave-j-reverify-held`.

Registered-worktree scan: `gitpulse_insights` ok. Seven worktrees. `main` is dirty by this report. Detached `base3d0` is clean. Five GitPulse lanes are dirty, with 8 overlapping files and 0 unscanned. Live Claude/Codex 0. `ft-5122c7a1d701be6adad52718cb978167` is `review` revision 4 on `gitpulse/performance-follow-through-make-the-audi-bccb61e8`. Codeintel generation 559, `source_freshness` true, `is_fresh` false, freshness reason "stored extraction payload is obsolete". DevMap `prewarm` explore: one definition, one bound caller (`AIActionPanel.open`), `walk_incomplete`, depth cap 2. A lower bound. No DevMap rebuild. No `devmap gap-record`.

Re-read on `main` (tests not re-run):

- The selection notification callback calls `handleAXNotification`, which records `NSWorkspace` facts and hops to `refreshQueue`. It does not copy an AX attribute. The monitor was not moved onto `readQueue`.
- `liveMismatch` calls `observeFocus` only when `checkElement || checkRange`.
- `SnippetSearch` narrows an extended query and caches a boosted result when the caller passes `boostRevision` and `boostSource`. `CommandPaletteCatalog` passes both.
- The snippet manager calls `SnippetManagerFilter.matchingIDs` with `groupsRevision`.
- Preferences `show()` calls `reloadAll()` once. `TriggerConflictsCache` keys on `libraryRevision`.
- `AITransformFlow` does not call `prewarm`. Chunk budgets go through `AIChunkPlanner`. `staticTokenCache` is an `AIBoundedCache`.

Still open, and not started:

- Paste-hold still has a `kAXValue` fallback at `DeliveryVerifier.swift:118`. That fallback stays.
- `LibraryHealth.refresh` still calls `SnippetStore.unresolvedConflicts()`, and load still records unresolved versions. `SnippetStore.swift` is on the unmerged library branch.
- `SecretStore` still sleeps inside the archive lock. The archive-lock branch holds that file. This card does not rewrite `withArchiveLock`.
- The `readQueue` main-only audit stays open. `SelectionReader.swift` is on the marker branch.
- Palette, manager, `AppDelegate`, `AITextTransformer`, `AIActionPanel`, and `AIPreviewPanel` are dirty in the registered lanes above. The follow-through lane also holds `Scripts/ci-local.sh`, `EventTapEngine.swift`, and `AuditBenchmarkTests.swift`.
- Full `./Scripts/test.sh` and `dev verify` were not run.

## Wave I (in review)

Registered-worktree scan after the slice: `gitpulse_insights` ok and `gitpulse_collision_risk` ok. Seven worktrees. `main` is dirty by this report (1 file). Detached `base3d0` is clean. Five GitPulse lanes are dirty: `command-palette-integration-surface-sele-37d01951` (18 files), `converge-duplicated-implementations-flag-86574ec8` (31), `on-device-ai-follow-ons-decide-semantic-7c6c9de9` (17), `performance-follow-through-make-the-audi-bccb61e8` (9), and `performance-voice-live-typing-and-ai-pre-6e433224` (6). Collisions: 6 overlapping files, 0 unscanned, `sessions_ok` true, live Claude/Codex 0, 5 GitPulse sessions. The overlapping paths are `Scripts/ci-local.sh`, `Sources/DevTypeAppCore/AIActionPanel.swift`, `Sources/DevTypeAppCore/AppDelegate.swift`, `Sources/DevTypeAppCore/MacroPalettePanel.swift`, `Sources/ExpanderEngine/Sync/CommandPaletteCatalog.swift`, and `docs/DEVELOPMENT.md`. `ImageAttachmentStore.swift` and `BUILD_REPORT.md` are not in that overlap. The grok implementer worktrees under `~/.grok/worktrees/apps-devtype/` are not registered. Their commits are not in this clone. A parent loop over those trees was blocked; before this branch, pairwise `diff -q` of `ImageAttachmentStore.swift` matched main on the image, snapshot, and library worktrees only.

Codeintel generation 558. This scan: `source_freshness` true, `is_fresh` false, `analyzer_freshness` false, freshness reason "stored extraction payload is obsolete", 11,853 symbols, 49,397 edges. Direct `devmap_status` before the slice said `is_fresh` true on that generation. Affected-tests for the file showed 8 of 15, `truncated` and `walk_incomplete`. Blast was 174 impacted, 1 of 2 layers, `walk_incomplete`. That is a lower bound. No DevMap rebuild. No `devmap gap-record`.

One slice of `ft-06d301ac`, not the whole sweep. Fable approved `9115789` from the parent `diff` and the test file. No reviewer subagent. The card is review revision 10, sequence 19958, not done. Verification is null. `held_for_review` is false.

| Task | Revision | Status | Where the work is |
| --- | --- | --- | --- |
| `ft-06d301ac43af0a7d1d43dbd24d676830` image import one-decode | 10 review | item 12 met on this branch; the sweep's other criteria unmet; not done | Branch `audit/ft-06d301ac-image-decode`. Fix `6a69648`, attack tests `9115789`. Parent `diff` of `ImageAttachmentStore.swift` against main is four hunks. Worktree filter after `9115789`: 97 tests, 0 failures, exit 0 (agent-reported: ExpanderEngine 88, DevTypeApp 9). Parent re-run was blocked by the harness. Full suite and `dev verify` unmet. Verification null |

`importImage(from:)` and `save(data:preferredExtension:)` stay source-compatible. Both call internal overloads that use `defaultInspectMetadata` and `defaultDecodeImage`. `prepareImage` and `save(data:)` share `acceptImagePayload`. An unsupported extension and a byte count over `maxImportedImageBytes` are refused before metadata and before `NSImage(data:)`. A metadata rejection skips the decode and the write. A nil decode throws `unreadableImage` and writes nothing. `save(prepared:)` does not call `save(data:)`, `validateDecodedImageSize`, or `NSImage`. It rechecks the mutable byte ceiling and atomic-writes the validated bytes, or throws `oversizedImage` with the byte count when the cap dropped after prepare. `PreparedImage`'s init is fileprivate and is called only after `acceptImagePayload`. `validateDecodedImageSize` is `internal` and the ImageIO walk is the same (`ShouldCache` false, the same caps). The stored name is `UUID` plus the lowercased extension. The written bytes are the validated payload. Caps, `resolvedURL`, `loadImage`, delete, orphan collection, and `supportedExtensions` are unchanged. No new `FailureCode`. No new dependency. Callers were not edited.

The attack added JPEG and mixed-case PNG imports, a `.jpg` name (not `.jpeg`), empty data (`unreadableImage("0 bytes")`, metadata 1, decode 0), a directory, the exact cap and one byte over it, a second `save(prepared:)`, a cap drop after prepare, a nil decode, and concurrent stores. Production was not changed after `6a69648`. Red before the split (agent-reported): `testImportImageValidatesAndDecodesOnce` saw metadata 2 and decode 2. After `6a69648` those counts are 1 and 1. A regular file of size cap+1 is refused by the stat before the read. The later `read(upToCount:)` overflow needs a file that grows after the stat, and there is no size-injection seam.

### Left unmet on this card

- SelectionMonitor is not hopped onto `readQueue`. The readQueue main-only API audit is not done.
- An erase of an N-character trigger still issues a focus query when `checkElement` and `checkRange` are both false.
- Paste-hold still falls back to full `kAXValue` when the windowed read cannot answer. That fallback stays.
- Palette narrowing, snippet-manager hashing, Preferences `reloadAll` once, AI prewarm, and the conflict / `SecretStore` checks are not this slice.
- No before/after benchmark. An accepted payload pays one ImageIO metadata walk and one `NSImage` decode. Parent has not timed it.
- Full `./Scripts/test.sh` and `dev verify` were not run.
- The selection-marker bound is on `audit/ft-06d301ac-marker-bound` (`c820d5a`). The expansion image bytes are on `audit/ft-06d301ac-image-bytes` (`06c68f5`). The clipboard snapshot is on `audit/ft-06d301ac-snapshot-bound` (`28d062c`). None of those are in `9115789`.

### Deferred this wave

- `ft-5122c7a1d701be6adad52718cb978167` bench gate. Still inbox. No palette B3. No unmeasured hotspot rewrite.
- `ft-1c6669c1ee7788129e57e56a0e19ca67` injection. Already review. Not restarted. `EventTapEngine` was not edited.
- `ft-7f34376060acdc85a759e2fccc989c20` Espanso. Image criteria stay in review. Alfred, Raycast, nested groups, and rich text stay open.
- `ft-3859d51812d308f5967de27039296b60` TIS. Stays review. dSYM and the manual macOS 27 run stay open.
- `ft-21791f0c6a2e2de2a71c7b58af0de7b1` protected span. Stays review. Criterion 3 unmet.
- `ft-d2d8bcc27acc03703dce238469b1b7e3` voice quadratic and `ft-2287d05b806c05c9dff527ef9ba50d92` modularization. Not restarted.
- `ft-0e11634c8058959a738d6d12d10c4f33` clone convergence and `ft-7ab99fad831ee1fb9707f68d50692354` large-file splits. Not started. The converge lane above is dirty on `AppDelegate.swift` and `MacroPalettePanel.swift`. This slice did not edit those files.
- Owner-decision cards, not implemented: `ft-0e5ece50f52cab9492c6f91a92a0729b`, `ft-3ca735f221ea890cbd7b033c1a8595af`, `ft-327ddd0ec021786353fd83f4a6aeecce`, `ft-f4d2393df40aa94ed6b3f6e6a21f257f`. The on-device-AI lane above is dirty. This slice did not edit it.
- Five GitPulse lanes appeared after Wave H. Their overlapping files are named above. This slice did not edit them.

## Wave H (in review)

Registered-worktree scan after the slice: `gitpulse_insights` ok. Two worktrees (`main` dirty by this report, detached `base3d0` clean), collisions ok (0 overlapping, 0 unscanned, `sessions_ok` true, live Claude/Codex 0). Codeintel generation 557, `source_freshness` true, `is_fresh` false, freshness reason "stored extraction payload is obsolete". The grok implementer worktrees are not registered. Their commits are not in this clone.

DevMap before the slice: generation 557. Direct `devmap_status` said `is_fresh` true on that generation; the GitPulse facet says `is_fresh` false. Affected-tests for `snapshotPasteboard` and `acquireUserClipboardSnapshot` showed 7 of 25, `truncated` and `walk_incomplete`. That is a lower bound. No DevMap rebuild. No `devmap gap-record`.

One slice of `ft-06d301ac`, not the whole sweep. Fable approved `28d062c` from the parent `diff` and the test file. A reviewer subagent did not return a verdict. The card is review revision 8, not done. Verification is null. `held_for_review` is false.

| Task | Revision | Status | Where the work is |
| --- | --- | --- | --- |
| `ft-06d301ac43af0a7d1d43dbd24d676830` clipboard snapshot | 8 review | snapshot bound met on this branch; the sweep's other criteria unmet; not done | Branch `audit/ft-06d301ac-snapshot-bound`. Fix `a839525`, attack tests `28d062c`. Parent `diff` of `PasteboardBroker.swift` against main is one hunk at `snapshotPasteboard`. Worktree filter after `28d062c`: 69 tests, 0 failures, exit 0 (agent-reported). Parent re-run was blocked by the harness. Full suite and `dev verify` unmet. Verification null |

`snapshotPasteboard` calls `snapshotRepresentations`. Promised types are not read. TIFF (`public.tiff` and `NeXT TIFF v4.0 pasteboard type`) is not read only when the same item also offers PNG, `public.jpeg`, or `public.gif`. A TIFF-only item is kept. The match is exact, so `public.JPEG` is not JPEG and a TIFF beside it is read. TIFF on one item and PNG on another are both read. Once the remaining budget is already 0, later types are not read. Nil data does not consume the budget. The first over-budget type is still read once, not stored, and does not reduce the budget, so a later smaller type is still read. A type that exactly fills the budget is kept. Empty data is stored. Items past `snapshotMaxItems` are not read. An item with nothing stored is not appended. Stored bytes never exceed the budget. `snapshotMaxBytes` stays 4 MB. `writeUserClipboardImage` still publishes TIFF and PNG. The snapshot stays on the caller thread. No new `FailureCode`. The marker bound and the expansion image-byte publication are not on this branch.

The attack added zero and negative budgets, every skipped type, near-miss type names, two over-budget reads then a fit, a later item's over-budget type, nil-only items, empty input, `maxItems` of 0, empty data, TIFF after PNG, legacy TIFF, cross-item TIFF and PNG, sequential calls, and concurrent calls. Production was not changed after `a839525`. The skipped counter is only logged, so tests prove those types are not read rather than that the counter incremented. `pasteboardItems == nil` still returns nil; a named board cannot force that case.

### Left unmet on this card

- SelectionMonitor is not hopped onto `readQueue`. The readQueue main-only API audit is not done.
- Paste-hold still falls back to full `kAXValue` when the windowed read cannot answer. That fallback stays.
- `ImageAttachmentStore.prepareImage` and `save(data:)` still decode the same import twice.
- Palette narrowing, snippet-manager hashing, Preferences `reloadAll` once, AI prewarm, and the conflict / `SecretStore` checks are not this slice.
- No before/after benchmark. This slice does not read promised types, a redundant TIFF, or any type after the budget is spent. The first over-cap `data(forType:)` can still happen. Parent has not timed it.
- Full `./Scripts/test.sh` and `dev verify` were not run.
- The selection-marker bound is on `audit/ft-06d301ac-marker-bound` (`c820d5a`). The expansion image bytes are on `audit/ft-06d301ac-image-bytes` (`06c68f5`). Neither is in `28d062c`.

### Deferred this wave

- `ft-5122c7a1d701be6adad52718cb978167` bench gate. Still inbox. No palette B3. No unmeasured hotspot rewrite.
- `ft-1c6669c1ee7788129e57e56a0e19ca67` injection. Already review. Not restarted. `EventTapEngine` was not edited.
- `ft-7f34376060acdc85a759e2fccc989c20` Espanso. Image criteria stay in review. Alfred, Raycast, nested groups, and rich text stay open.
- `ft-3859d51812d308f5967de27039296b60` TIS. Stays review. dSYM and the manual macOS 27 run stay open.
- `ft-21791f0c6a2e2de2a71c7b58af0de7b1` protected span. Stays review. Criterion 3 unmet.
- `ft-d2d8bcc27acc03703dce238469b1b7e3` voice quadratic and `ft-2287d05b806c05c9dff527ef9ba50d92` modularization. Not restarted.
- `ft-0e11634c8058959a738d6d12d10c4f33` clone convergence and `ft-7ab99fad831ee1fb9707f68d50692354` large-file splits. Not started.
- Owner-decision cards, not implemented: `ft-0e5ece50f52cab9492c6f91a92a0729b`, `ft-3ca735f221ea890cbd7b033c1a8595af`, `ft-327ddd0ec021786353fd83f4a6aeecce`, `ft-f4d2393df40aa94ed6b3f6e6a21f257f`.
- `ImageAttachmentStore` double-decode (card item 12) stays unmet. It is a different file and was not started beside this review.

## Wave G (in review)

Registered-worktree scan before the slice: `gitpulse_insights` and `gitpulse_collision_risk` both `ok: true`. Two worktrees (`main` dirty by this report, detached `base3d0` clean), 0 overlapping files, 0 unscanned, `sessions_ok` true, live Claude/Codex 0. The scan after the slice did not run: GitPulse deferred `git worktree` under load (`ok: false` on worktrees, changes, collisions, and sessions). That is not a clean scan. The implementer worktree under `~/.grok/worktrees/apps-devtype/` is not registered. Its commits are not in this clone.

DevMap generation 556. `devmap_status` said `is_fresh` true and `source_freshness` true. The GitPulse codeintel facet on the same generation said `is_fresh` false, freshness reason "stored extraction payload is obsolete". Affected-tests for `imageRepresentations`, `pasteImageViaClipboard`, `writeUserClipboardImage`, and `performImageInject` was truncated (12 of 64 tests shown) and `walk_incomplete` (stopped at depth 3). That is a lower bound. `pasteImageViaClipboard`'s direct caller in that lower bound is `TextInjectionPipeline.performImageInject`. `writeUserClipboardImage` is also reached from `AppDelegate.applyCopyResult`. `AppDelegate.swift` is not in the diff. No DevMap rebuild. No `devmap gap-record`.

One slice of `ft-06d301ac`, not the whole sweep. Reviewer approved `06c68f5`. The card is review revision 6, not done. Verification is null.

| Task | Revision | Status | Where the work is |
| --- | --- | --- | --- |
| `ft-06d301ac43af0a7d1d43dbd24d676830` native image bytes | 6 review | expansion re-encode met on this branch; the sweep's other criteria unmet; not done | Branch `audit/ft-06d301ac-image-bytes`. Fix `3e073cd`, attack tests `06c68f5`. Worktree `git diff --stat b01a4f5...HEAD`: 3 files, +1398/−5. Filter after `06c68f5`: 92 tests, 0 failures, exit 0 (agent-reported). Parent re-run was blocked by the harness. Full suite and `dev verify` unmet. Verification null |

`pasteImageViaClipboard` takes `imagePath: String? = nil`. `performImageInject` passes `context.snippet.imagePath`. png, jpg, jpeg, gif, and tiff publish the stored file bytes under one type (`public.jpeg`, `public.gif`, `.png`, `.tiff`). TIFF and PNG are not synthesized beside those bytes. bmp, webp, heic, `.tif`, an unknown extension, a nil or empty path, a `resolvedURL` rejection (`..`), an unreadable or over-cap stat, and a read longer than `maxImportedImageBytes` fall back to TIFF+PNG and are not cached. An over-cap stat does not read. A read whose count differs from the stat and is still within the cap is published once and not cached. The cache is per broker, keyed by standardized path, mtime, and size, one entry per path, at most 4 entries, total payload bytes at most the cap, oldest insertion evicted, and a hit does not refresh age. `payloadBytes` passed to `calculateImageRestoreDelay` is that prepared count. The formula and `InjectTiming` constants are unchanged. `writeUserClipboardImage` still publishes TIFF and PNG. An empty `NSImage` does not clear the board. No new `FailureCode`. The marker bound is not on this branch. It stays on `audit/ft-06d301ac-marker-bound` (`c820d5a`).

The attack added mixed-case extensions, the exact cap, a second broker, rejected paths staying uncached, `./foo.png` sharing a cache entry with `foo.png`, the default file reader, a directory and an unreadable file, and concurrent stores. Production was not changed after `3e073cd`. An empty file makes `FileHandle.read(upToCount:)` return nil, so the paste falls back instead of publishing empty native bytes. The same mtime and size can still serve stale bytes.

### Left unmet on this card

- SelectionMonitor is not hopped onto `readQueue`. The readQueue main-only API audit is not done.
- Paste-hold still falls back to full `kAXValue` when the windowed read cannot answer. That fallback stays.
- The clipboard snapshot is still synchronous and still calls `data(forType:)` before the 4 MB budget.
- `ImageAttachmentStore.prepareImage` and `save(data:)` still decode the same import twice.
- Palette narrowing, snippet-manager hashing, Preferences `reloadAll` once, AI prewarm, and the conflict / `SecretStore` checks are not this slice.
- No before/after benchmark. This slice does not synthesize an uncompressed TIFF beside stored png, jpeg, gif, or tiff bytes. Parent has not timed it.
- Full `./Scripts/test.sh` and `dev verify` were not run.
- The selection-marker bound is on the other branch, not in `06c68f5`.

### Deferred this wave

- `ft-5122c7a1d701be6adad52718cb978167` bench gate. Still inbox. No palette B3. No unmeasured hotspot rewrite.
- `ft-1c6669c1ee7788129e57e56a0e19ca67` injection. Already review. Not restarted. `EventTapEngine` was not edited.
- `ft-7f34376060acdc85a759e2fccc989c20` Espanso. Image criteria stay in review. Alfred, Raycast, nested groups, and rich text stay open.
- `ft-3859d51812d308f5967de27039296b60` TIS. Stays review. dSYM and the manual macOS 27 run stay open.
- `ft-21791f0c6a2e2de2a71c7b58af0de7b1` protected span. Stays review. Criterion 3 unmet.
- `ft-d2d8bcc27acc03703dce238469b1b7e3` voice quadratic and `ft-2287d05b806c05c9dff527ef9ba50d92` modularization. Not restarted.
- `ft-0e11634c8058959a738d6d12d10c4f33` clone convergence and `ft-7ab99fad831ee1fb9707f68d50692354` large-file splits. Not started.
- Owner-decision cards, not implemented: `ft-0e5ece50f52cab9492c6f91a92a0729b`, `ft-3ca735f221ea890cbd7b033c1a8595af`, `ft-327ddd0ec021786353fd83f4a6aeecce`, `ft-f4d2393df40aa94ed6b3f6e6a21f257f`.

## Wave F (in review)

Registered-worktree scan after the slice: `gitpulse_insights` and `gitpulse_collision_risk` both `ok: true`. Two worktrees (`main` dirty by this report, detached `base3d0` clean), 0 overlapping files, 0 unscanned, `sessions_ok` true, live Claude/Codex 0. The implementer worktree under `~/.grok/worktrees/apps-devtype/` is not registered. Its commits are not in this clone.

DevMap generation 554. `is_fresh` false, freshness reason "stored extraction payload is obsolete", `source_freshness` true. Affected-tests for `SelectionReader`, `PasteboardBroker`, and `DeliveryVerifier` was `truncated` (6 of 67 shown, 61 hidden), `walk_incomplete`, depth 2. That is a lower bound, not a caller list. Gap recorded: `wave-f-selection-marker-tests`. The implementer worktree has no store. It did not build or copy one.

One slice of `ft-06d301ac`, not the whole sweep. Reviewer approved `c820d5a`. The card is review, not done.

| Task | Revision | Status | Where the work is |
| --- | --- | --- | --- |
| `ft-06d301ac43af0a7d1d43dbd24d676830` selection-marker bound | 4 review | marker bound met on the branch; the sweep's other criteria unmet; not done | Branch `audit/ft-06d301ac-marker-bound`. Fix `719f70d`, attack tests `c820d5a`. Worktree filter after the test fix: 101 tests, 0 failures, exit 0 (agent-reported). Parent re-run was blocked by the harness. Full suite and `dev verify` unmet. Verification null |

`SelectionReader.boundSelectionBody` uses `String.count` (Character). Exactly 200_000 is kept. A non-blank string over that sets `oversizedCharacterCount` and drops the body. A blank string over that (spaces, U+FFFC) drops the body and is not `selectionTooLarge`. `ElementRead` and `Candidate` cannot store a body and a count together. `evaluate` returns `selectionTooLarge` for the first non-own, non-muted oversized candidate and does not use a later shorter candidate or the cache. A fresh cache still beats an own-process oversized count. Hard blocks still win. The marker rung, `kAXSelectedText`, the slow retry, both range strings, the value slice, and each gathered piece go through the bound. One non-blank over-cap piece is oversized and is not joined. Two under-cap pieces whose sum crosses the cap stay unavailable. No new `FailureCode`. `SelectionMonitor.swift`, `PasteboardBroker.swift`, and `DeliveryVerifier.swift` were not part of the approved diff.

The first attack test failed because it treated 200_001 U+200D scalars as 200_001 Characters. A ZWJ run is one Character, so the cap keeps it. Production was not changed. `c820d5a` fixes the test. Spaces and U+FFFC at 200_001 Characters still drop.

### Left unmet on this card

- SelectionMonitor is not hopped onto `readQueue`. The readQueue main-only API audit is not done. An oversized read still looks empty to the monitor, so last-known-good can remain. The new body is not stored.
- Paste-hold still falls back to full `kAXValue` when the windowed read cannot answer. That fallback stays. `InjectionAXReadBudgetTests` require it.
- Image paste is still TIFF then PNG. The clipboard snapshot is still synchronous and still calls `data(forType:)` before the 4 MB budget.
- Palette narrowing, snippet-manager hashing, Preferences `reloadAll` once, AI prewarm, and the conflict / `SecretStore` checks are not this slice.
- No before/after benchmark. This slice is a bound, not a second bench. The marker IPC copy still happens; the body is released after the count.
- Full `./Scripts/test.sh` and `dev verify` were not run.

### Deferred this wave

- `ft-5122c7a1d701be6adad52718cb978167` bench gate. Still inbox. No palette B3. No unmeasured hotspot rewrite.
- `ft-1c6669c1ee7788129e57e56a0e19ca67` injection. Already review. Not restarted.
- `ft-7f34376060acdc85a759e2fccc989c20` Espanso. Image criteria stay in review. Alfred, Raycast, nested groups, and rich text stay open.
- `ft-3859d51812d308f5967de27039296b60` TIS. Stays review. dSYM and the manual macOS 27 run stay open.
- `ft-21791f0c6a2e2de2a71c7b58af0de7b1` protected span. Stays review. Criterion 3 unmet.
- `ft-d2d8bcc27acc03703dce238469b1b7e3` voice quadratic and `ft-2287d05b806c05c9dff527ef9ba50d92` modularization. Not restarted.
- `ft-0e11634c8058959a738d6d12d10c4f33` clone convergence and `ft-7ab99fad831ee1fb9707f68d50692354` large-file splits. Not started.
- Owner-decision cards, not implemented: `ft-0e5ece50f52cab9492c6f91a92a0729b`, `ft-3ca735f221ea890cbd7b033c1a8595af`, `ft-327ddd0ec021786353fd83f4a6aeecce`, `ft-f4d2393df40aa94ed6b3f6e6a21f257f`.

## Wave E (in review)

Registered-worktree scan after the wave: `gitpulse_insights` and `gitpulse_collision_risk` both `ok: true`. Two worktrees (`main` clean before this report edit, detached `base3d0` clean), 0 overlapping files, 0 unscanned, `sessions_ok` true, live Claude/Codex 0. Grok worktrees under `~/.grok/worktrees/apps-devtype/` are still not registered. Their commits are not in this clone. They are not live holds (no Claude or Codex session on them), and their files were not edited from `main`.

DevMap generation 553. `devmap_status`: `is_fresh` false, `source_freshness` true, freshness reason "stored extraction payload is obsolete". `devmap_impact` of `ProtectedSpanExtractor` at depth 2: 33 of 33 shown, `truncated` false, `walk_incomplete` (stopped at depth 2, partial parse, at least 8 unbound call sites). The envelope had no `repository.root`; `db_path` is this checkout. The Wave E commits are not in this checkout, so that graph does not contain the new extractor. Gap recorded: `wave-e-protected-span-impact`. Direct production caller in the lower bound: `CorrectionPipeline.execute`, then `VoiceSessionCoordinator.executeCommands`.

One slice. Opus returned the first fix twice, then approved `84c856e`.

| Task | Revision | Status | Where the work is |
| --- | --- | --- | --- |
| `ft-21791f0c6a2e2de2a71c7b58af0de7b1` protected-span hang | 3 review | criteria 1–2 met on the branch; criterion 3 unmet; not done | Branch `audit/ft-21791f0c-span-bound`. Ceiling `03769729`, case-fold and occupancy `174640c`, duplicate-term skip `84c856e`. Parent filter: 23 tests, 0 failures, exit 0. Full suite and `dev verify` unmet |
| `ft-187f62faa97118dc223575f2d1c745d3` settings quarantine | 2 review | already on `main`; not done | No new commit this wave. Filtered suites earlier this session: CorruptStorePreservation 17, HotkeyMacroPersistence 4, SnippetEditResource 1, AppStringKeyCoverage 9, all 0 failures. `SecretStore` left untouched (archive-lock branch holds it). Full suite and `dev verify` unmet |
| `ft-3325452c55767485a0460b7ba5feecda` post-modularization cleanup | 3 review | already on `main`; not done | No new commit this wave. Filtered suites earlier this session: LocalizationParity 19, DeliveryVerificationPolicy 17, TriggerMatching 12, all 0 failures. `AppDelegate.swift` left untouched. Full suite and `dev verify` unmet |

`ft-21791f0c` verification is null. Done was not requested. A transcript longer than 32,768 UTF-16 units returns no spans, and `CorrectionPipeline` returns the raw text with `validationOutcome` `.notApplicable` without calling the corrector. Email is a forward scan. U+017F and U+212A match the old case-insensitive pattern on the short oracle. Overlap uses a UTF-16 occupancy mark. An exact duplicate dictionary term is searched once. `finish_reason` length stays on unmerged `audit/ft-7a3fc214-correction-cap`. No new `FailureCode`.

Parent re-ran `./Scripts/test.sh --package-path` against the worktree with filter `ProtectedSpanExtractorBound|ProtectedSpan|testPromptIsBoundedForPathologicalInput|testProtectedSpan`: 23 tests, 0 failures, exit 0. Dictionary case (2,000 copies of a 32-character `"a"` term, UTF-16 32,767): 1,023 spans in 53.081 ms. The same case before the duplicate skip was 954.493 ms on a parent run and 929.575 ms on the attack fix, against a 1-second assertion, which is why that commit was returned. Repeated `@a.bc` at UTF-16 32,767: 3,276 spans in 23.754 ms.

### Deferred this wave

- `ft-06d301ac43af0a7d1d43dbd24d676830` performance sweep. Still inbox. Planned files overlap TIS, the refusal card, the palette branch, preferences, and `SecretStore`.
- `ft-5122c7a1d701be6adad52718cb978167` bench gate. Still inbox. Section A and B13 are on `main`. B3 waits on the unmerged palette branch.
- `ft-1c6669c1ee7788129e57e56a0e19ca67` injection. Already review. Not restarted.
- `ft-7f34376060acdc85a759e2fccc989c20` Espanso. Image criteria are in review. Alfred, Raycast, nested groups, and rich text stay open. Nested-group schema migration is an owner decision.
- `ft-3859d51812d308f5967de27039296b60` TIS. Stays review. dSYM and the manual macOS 27 run stay open.
- `ft-d2d8bcc27acc03703dce238469b1b7e3` voice quadratic and `ft-2287d05b806c05c9dff527ef9ba50d92` modularization. Not restarted.
- `ft-0e11634c8058959a738d6d12d10c4f33` clone convergence and `ft-7ab99fad831ee1fb9707f68d50692354` large-file splits. Structural, and the clone card overlaps the settings stores.
- Owner-decision cards, not implemented: `ft-0e5ece50f52cab9492c6f91a92a0729b`, `ft-3ca735f221ea890cbd7b033c1a8595af`, `ft-327ddd0ec021786353fd83f4a6aeecce`, `ft-f4d2393df40aa94ed6b3f6e6a21f257f`.

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
- `ft-06d301ac43af0a7d1d43dbd24d676830` performance sweep. Review revision 11. Marker bound, native image bytes, clipboard snapshot, and image one-decode are on four unmerged branches (`c820d5a`, `06c68f5`, `28d062c`, `9115789`). On `main`, the notification handler hops to `refreshQueue`, erase focus is conditional, palette narrowing and the manager revision are present, Preferences reloads once, and the AI prewarm/chunk/cache slice is present. Those reads were not re-tested this pass. Still open: the paste-hold `kAXValue` fallback (kept), the `SnippetStore` conflict read, `SecretStore` (archive-lock branch), and the `readQueue` audit (`SelectionReader` is on the marker branch). `ft-5122c7a1d701be6adad52718cb978167` is review revision 4 on the follow-through lane. This pass did not edit those files.
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
| `ProtectedSpanExtractor` on repeated `a`, debug | agent-reported, unmodified: 5,000 in 223 ms, 10,000 in 1,276 ms, 20,000 in 5,623 ms. Parent did not re-time the unmodified path | parent: 900,000-character case returned inside its 0.007 s test; UTF-16 32,767 `a` in 47.056 ms | speedup. Parent has not re-timed the pre-fix samples |
| Dictionary overlap, 2,000 × 32-character `"a"` against 32,767 `"a"` | attack, before the occupancy mark: 68.65 s (earlier sample 102.66 s), 1,023 spans | parent after `84c856e`: 53.081 ms, 1,023 spans. Agent samples on that commit: 57.9–63.9 ms | under the 1 s test bound, with margin. Parent timed one run |
| Repeated `@a.bc` at UTF-16 32,767 | attack before the occupancy mark: 1,665 ms, then 391 ms, 3,276 spans | parent: 23.754 ms, 3,276 spans | under the 250 ms test bound |
| Selection marker / over-cap body | not timed | no bench | structural bound. The AX copy still happens; the body is not retained. Parent has not timed it |
| Image expansion TIFF+PNG re-encode | not timed | no bench | structural. Stored png, jpeg, gif, and tiff bytes are published as themselves. bmp, webp, and heic still re-encode. Parent has not timed it |
| Clipboard snapshot `data(forType:)` | not timed | no bench | structural. Promised types, a TIFF beside PNG, JPEG, or GIF, and every type after the budget is spent are not read. The first over-cap type can still be read once. Parent has not timed it |
| Image import metadata and decode | not timed | no bench | structural. One ImageIO metadata walk and one `NSImage` decode per accepted payload. `save(prepared:)` does not decode again. Parent has not timed it |

## New tasks filed

- `gp-protected-span-regex-hang` (`ft-21791f0c6a2e2de2a71c7b58af0de7b1`). Filed in an earlier wave. Wave E moved it to review at revision 3. No new card was filed in Wave E, Wave F, Wave G, Wave H, or Wave I. The SelectionMonitor hop and the bmp/webp/heic fallback stayed on `ft-06d301ac`. The import double-decode is met on `audit/ft-06d301ac-image-decode` and is not a new card.

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
- Wave E is only `ft-21791f0c`. It does not share files with the unmerged audit diffs. `CorrectionPipeline.swift` is in scope. `VoiceSessionTypes.swift` and the length-cap correctors are not.
- A transcript past the span ceiling uses `validationOutcome` `.notApplicable`. No new `FailureCode`.
- Criterion 3 stays unmet on this branch. The card goes to review with that criterion open.
- The first span commit (`03769729`) was returned: ICU case-fold missed U+017F and U+212A, and the overlap walk still took 68.65 s under the new ceiling. `174640c` was returned because the dictionary case passed at 929 ms and 954 ms against a 1-second assertion. `84c856e` is the approved head. Exact duplicate terms are skipped. `"Hello"` and `"hello"` stay distinct.
- The settings card and the cleanup card were moved to review on source that is already on `main`, plus filtered tests. They are not done.
- Do not merge any audit branch to `main` from this session. Do not rebuild DevMap inside the implementer worktree, and do not copy this checkout's database there.
- Wave F is one slice of `ft-06d301ac`: the selection-string bound only. One implementer. `SelectionMonitor` stays off `readQueue`. `DeliveryVerifier`'s full `kAXValue` fallback stays. Image TIFF+PNG and the clipboard snapshot stay. The size unit stays `String.count`. Exactly 200_000 Characters is accepted. A blank over-cap string is not `selectionTooLarge`. A ZWJ run is one Character and is kept. The attack that required 200_001 ZWJs to count as 200_001 Characters was a bad assertion; production was not changed.
- A foreign oversized count does not fall through to a later shorter candidate or the cache. An own-process oversized count does not outrank a fresh cache.
- The card goes to review with the other sweep criteria named and unmet. It is not done.
- Wave G is the next slice of the same card: expansion image paste only. One implementer, branch `audit/ft-06d301ac-image-bytes` from `b01a4f5`, not from the marker branch. User-copy `writeUserClipboardImage` stays TIFF+PNG. bmp, webp, and heic stay on that fallback because those types are not reliably pasteable as native-only. The clipboard snapshot and the paste-hold `kAXValue` fallback stay. `AppDelegate` was not edited. No new `FailureCode`. No benchmark. An empty file falls back because `FileHandle.read(upToCount:)` returns nil. A same-size same-mtime change can serve stale bytes. The card returns to review with the other sweep criteria unmet. It is not done.
- Wave H is the clipboard-snapshot slice of the same card. One implementer, branch `audit/ft-06d301ac-snapshot-bound` from `b01a4f5`, not stacked on the image branch or the marker branch. Take the structural bound. Do not hop the snapshot off the caller thread. Drop TIFF (`public.tiff` and legacy `NeXT TIFF v4.0 pasteboard type`) only when the same item also offers PNG, `public.jpeg`, or `public.gif`. A TIFF-only item stays. Promised types stay unread. `snapshotMaxBytes`, `snapshotMaxItems`, and `snapshotSkippedTypes` stay. The first over-budget type can still be read once, because AppKit has no size API; it is not stored and does not reduce the budget. `writeUserClipboardImage` stays TIFF+PNG. Expansion image publication stays on the image branch. No new `FailureCode`. No benchmark. The card returns to review at revision 8 with the other sweep criteria unmet. It is not done.
- Wave I is one decode per accepted attachment on the same card. One implementer, branch `audit/ft-06d301ac-image-decode` from `b01a4f5`, not from the image, marker, or snapshot branches. `save(prepared:)` does not re-enter validating `save(data:)`. Public `save(data:)` stays the trust boundary and still validates once. `PreparedImage` is constructed in this file only after those checks (fileprivate init). Metadata rejection stays before the AppKit decode. `save(prepared:)` may refuse, without decoding, when `maxImportedImageBytes` dropped after prepare. Caps, `resolvedURL`, `loadImage`, delete, and orphan collection stay. Callers stay. `PasteboardBroker`, `AppDelegate`, `SnippetStore`, `EspansoImporter`, and `SnippetImporter` stay. No new `FailureCode`. No new dependency. No benchmark. The card returns to review at revision 10 with the other sweep criteria unmet. It is not done.
- The pass after Wave I starts no slice. Re-reads on `main` show the notification hop, conditional erase focus, palette narrowing, manager revision, one Preferences reload, and the AI prewarm/chunk/cache split are already present. The paste-hold `kAXValue` fallback stays. `SnippetStore` and `SecretStore` stay with the lanes that hold them. The `readQueue` audit stays open. `ft-5122c7a1d701be6adad52718cb978167` stays review revision 4 on the follow-through lane. The card stays review at revision 11. It is not done.

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

- Parent has not re-run the Wave A–D filtered suites or the full suite. Those counts are agent-reported, except the Wave E filter and the settings and cleanup filters named above, which the parent read. Parent read the publish condition, the archive-lock stall check, and the crash-report integer parser.
- `dev verify` was not run. No DevCouncil lease. `ft-21791f0c` verification is null, so it stays in review.
- Criterion 3 of `ft-21791f0c` (`finish_reason` length is still `fallbackToRaw`) was not exercised on `audit/ft-21791f0c-span-bound`.
- Pre-fix span timings (5,000 / 10,000 / 20,000 repeated `a`) were not re-run by the parent. The 900,000-character input was not run against unmodified `extract`.
- Live `AVAudioEngine` microphone path was not opened.
- `testStartAndStopRoundTrip` needs whisper.cpp, which is not installed.
- Wave F filter (101 tests, 0 failures, exit 0) is agent-reported from the worktree after `c820d5a`. The parent `swift test --package-path` run was blocked by the harness. No live oversized AX host was read. Full suite and `dev verify` were not run. DevMap for this slice stays a lower bound (`wave-f-selection-marker-tests`).
- Wave G filter (92 tests, 0 failures, exit 0) is agent-reported from the worktree after `06c68f5`. The parent `git --git-dir` and `--package-path` runs were blocked by the harness. A worktree agent confirmed the diff stat. The post-slice GitPulse insights call was deferred under load and is not a clean scan. Full suite and `dev verify` were not run.
- Wave H filter (69 tests, 0 failures, exit 0) is agent-reported from the worktree after `28d062c`. The parent confirmed one production hunk with `diff` and read the helper and the attack tests. The parent did not re-run `./Scripts/test.sh`. A reviewer subagent did not return a verdict. Post-slice `gitpulse_insights` succeeded (generation 557, `is_fresh` false, collisions clean on the two registered worktrees). Full suite and `dev verify` were not run.
- Wave I filter (97 tests, 0 failures, exit 0; ExpanderEngine 88, DevTypeApp 9) is agent-reported from the worktree after `9115789`. The parent confirmed four production hunks with `diff` and read `acceptImagePayload`, `save(prepared:)`, `writeImageBytes`, and the attack tests. The parent did not re-run `./Scripts/test.sh`. No reviewer subagent. Post-slice `gitpulse_insights` and `gitpulse_collision_risk` succeeded (generation 558, facet `is_fresh` false, 7 registered worktrees, 6 overlapping files among five GitPulse lanes, none of them `ImageAttachmentStore.swift`). The unregistered grok worktrees were not fully scanned. Full suite and `dev verify` were not run.
- The pass after Wave I re-read the call sites named above and did not re-run `AITransformExtrasTests`, `UIPerformanceReuseTests`, or `./Scripts/test.sh`. `refreshCacheFromFocus`'s attribute copies were not line-audited; they are reached from `performRefresh` on `refreshQueue`. DevMap generation 559 is not analyzer-fresh, and the `prewarm` walk is incomplete. Unregistered grok worktrees were not scanned file-by-file this pass.
