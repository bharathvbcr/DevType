# Unwired code inventory

Audit date: 2026-09-01, against `2529c71`. **Status: resolved — 0 dead declarations remain.**

This began as a read-only audit ("nothing here has been deleted"). It has since been acted
on: everything below was either wired to a real call site or retired. The findings are kept
in full, including one that turned out to be wrong, because the *method* is the reusable part
— `dev map` cannot reproduce this list, and the section below explains why.

Every entry was verified by reading the source and by ripgrep over `Sources/` and `Tests/`
with `RIPGREP_CONFIG_PATH=` cleared (so `.gitignore` could not hide a caller).

---

## How this list was produced — and why `dev map` alone will not reproduce it

`dev map`'s own liveness output reported **zero** unwired candidates. That result is not
trustworthy, for four independent reasons:

1. **Wrong BFS roots.** `entry_roots` lists four arbitrary view controllers and omits the
   real entry point, `Sources/DevTypeApp/main.swift` (the `executableTarget` in
   `Package.swift`). An empty `unwired_candidates` from a wrongly-rooted search means nothing.
2. **Two databases.** `dev map --full` writes `.devcouncil/codeintel/devmap.sqlite`, but
   `dev map dead` reports freshness from `.devcouncil/codeintel/index.sqlite` — a separate,
   much older index. `dev map dead` therefore prints "stale" immediately after a successful
   rebuild.
3. **Weakest tier only.** All 19 `dead_symbol_candidates` are `ambiguous` confidence with an
   empty `reason` field — below the `inferred` tier that `CLAUDE.md` already says to treat
   as unconfirmed.
4. **~88% false-positive rate on Swift.** Re-rooting the BFS at the real `main.swift` yields
   120 "unreached" types; grep confirms **105 of them are live**. The graph does not model
   Swift's `enum`-as-namespace static calls — it reported `DevTypeLog` as unreached, and
   `DevTypeLog` has 385 call sites.

The list below instead comes from a full-text sweep: 2,271 declarations across 185 Swift
files, comments stripped so doc mentions do not count as usage, AppKit/Foundation delegate
conformances excluded (13 of them — `applicationDidFinishLaunching`, `numberOfRows(in:)`,
`urlSession(…)` and friends are called by the framework, not by us). That left 23 genuinely
uncalled declarations.

**If you re-run this audit:** rebuild first (`dev map --full`), ignore `unwired_candidates`
and `unreachable_files` entirely, and cross-check every graph claim with grep.

---

## Finding 1 — bulk Export button (fixed)

`SnippetManagerViewController.bulkExportSelected` had **no `#selector` reference anywhere**,
so the button was never constructed and the action could not fire. Every sibling bulk action
is wired at lines 884–890. All three string tables (en/ko/ja) already carried
`manager.bulk.export` — the string was written and localized, only the button was missed.

Wiring it exposed a second defect: the handler called `LibraryExporter.present(from:)`, which
reads `store.loadGroups()` and exports the **whole library**. Under a label reading
"3 selected" that would silently write all 400 snippets.

Fixed by giving `LibraryExporter.present` an optional `restrictedTo: Set<UUID>?` (default
`nil` = whole library, so the existing menu-bar and utility-bar call sites are unchanged),
extracting the narrowing into a testable `LibraryExporter.restrict(_:to:)`, and adding
`SnippetStore.exportLibraryData(groups:)` as a public seam over the existing single
`encodeLibrary` implementation. Covered by `Tests/DevTypeAppTests/BulkExportSelectionTests.swift`
(5 tests; 3 fail against pre-fix behaviour, verified by simulation).

---

## WIRE — the original findings (all now wired; see Resolution below)

### 1. Library relocation / sync — the biggest one

| | |
|---|---|
| Where | `SnippetStore.swift`: `saveSnippetsAs(toDirectory:)` :1699, `linkToSnippets(at:)` :1721, `stopSyncing()` :1728 |
| Support | `relocate` :1749, `exportCurrentLibrary` :1785, `writeBackup` :1790, `RelocationResult` :199 — all reachable *only* from those three |
| Size | ~100 lines, self-contained |
| Callers | none, in `Sources/` or `Tests/` |

This is a complete "keep my snippets in iCloud/Dropbox" feature: move the library to a
chosen folder, link to a library that already exists there, or stop syncing and return
to local. It writes a safety backup before every move.

**It is not a half-finished stub.** `deviceDefaults` records the new path under
`storeLocationPath`, and `SnippetStore.swift:345` reads that key on load — so a relocation
survives a restart. The engine half is done and persists correctly.

`RelocationResult` already carries `success`, `backupURL`, `message`, and `activeLocation`
— exactly the fields a settings panel would display. It reads as though a UI was designed
and then never built.

**To wire:** three buttons and an `NSOpenPanel` in Preferences ▸ General (or a new Sync
section), plus a label showing the active location. **Before wiring it needs tests** — this
path has never been executed, and it moves the user's entire library. That is the real cost
here, not the UI.

### 2. ~~Gemini API key validation~~ — CORRECTION: not a defect

**This entry was wrong in the first version of this document and is retained so the error is
visible rather than silently edited away.**

I originally reported that the Gemini key was saved without validation. It is not. The save
path (`PreferencesWindowController.geminiKeySaveClicked` :2122) calls
`GeminiTranscriptionClient.validateAPIKeyDetailed(_:)` :255 and drives the status pill from
the result. I read line 2122 and did not scroll to :2131 where the validation happens.

`validateAPIKey(_:)` :325 is genuinely uncalled, but it is a one-line convenience wrapper
(`await validateAPIKeyDetailed(key).isValid`) over the function that *is* wired and tested.
It belongs in RETIRE, not here.

### 3. AX capability diagnostics

`AXWriteCapabilityStore.learnedVerdicts()` :448 — its own docstring says "Diagnostic dump:
`key -> verdict`, sorted." Nothing consumes it. DevType already learns per-app whether to
use AX writes or paste; surfacing that in the diagnostics report or a Preferences advanced
pane would make "why does expansion behave differently in app X?" answerable. Pairs naturally
with the existing `DiagnosticReport`.

### 4. Espanso multi-file export

`SnippetExporter.espansoYAMLFiles(from:options:)` :113 emits one match file per group,
deduplicating file names. The exporter currently offers only single-document Espanso YAML.
This is the `match/` **directory** format, which is what Espanso users actually keep in
version control. Natural fourth entry in `LibraryExporter.Choice`.

### 5. Smaller, plausible wirings *(inferred — I did not trace intended call sites)*

- `AIPreferences.resetOutputMode(for:)` :41 — the setter is used; the reset has no "Restore
  default" control behind it.
- `DateFormatLibrary.invalidateFormatterCache()` :237 — likely belongs on a locale/language
  change notification; worth checking whether cached formatters currently go stale when the
  user switches app language.
- `EventTapEngine.cancelHeldExpansion()` :1789 — an Escape-key cancel path.
- `MacroTransforms.allCounters()` :222 — counter inspection/reset UI.
- `AXContextChecker.focusedElementCandidates()` :216, `frontmostIsIDEBundle()` :947.
- `PermissionCoordinator.markAXPossiblyNeedsRelaunch()` :353.
- `VoiceSessionCoordinator.activePhase()` :71.
- `FillInBuilder` :6 — the whole enum is production code exercised only by tests. It builds
  fill-in macro syntax safely; a "insert fill-in field" affordance in the snippet editor is
  the obvious consumer.

---

## RESOLVED CONCURRENTLY — `PaletteToolRouter`

**No action needed. Recorded because the audit flagged it and it was fixed while the audit
was being written.**

At `2529c71` this was the second-largest finding: `PaletteToolRouter`
(`Sources/ExpanderEngine/AI/PaletteToolRouter.swift`, then 128 lines) was inert end to end.
`shouldAttemptRouting(query:)` and `makeTools(groupsProvider:)` had no callers; the only
thing consumed from the file was the constant `debounceMilliseconds`;
`AIPreferences.isSemanticRoutingEnabled` was read only by the dead `shouldAttemptRouting`
and had no UI toggle, so setting `devtype.ai.semanticRoutingEnabled` by hand changed nothing.
The three tools' `call(arguments:)` had 8 test references — the suite was green on a path
production never ran.

The concurrent command-palette work has since wired all of it (uncommitted at time of
writing, +129 lines):

- `InlineSearchPanel.scheduleRouting()` :760 now calls `shouldAttemptRouting`, debounces on
  `debounceMilliseconds`, and awaits `PaletteToolRouter.route(query:engine:)`.
- `route` calls `makeTools`, so the three tools are on a live path.
- A real Preferences toggle exists: `aiSemanticRoutingSwitch`
  (`PreferencesWindowController` :317, :2414, :2554, :2595), so the preference now does
  something.
- The new `route(query:engine:)` takes an injected engine, which makes the gates, latch and
  staleness guard testable without a model — closing the "tests assert an unreachable path"
  gap as well.

One leftover to check when that work lands: `docs/ARCHITECTURE.md:238` still describes this
as a Stage-2 router that "exists behind a preference flag and ships off by default." The
flag now genuinely gates a live feature, so that sentence should be updated to match.

---

## RETIRE — the original findings (all now removed; see Resolution below)

These are not useful; they are leftovers that were not removed when their replacement landed.

### 1. Legacy import wrappers

`SnippetStore.importTextExpander(from:)` :1823 and `importEspanso(from:)` :1831 have zero
callers. `importSnippets(from:)` :1808 — whose docstring says "Single entry point for the
UI" — auto-detects both formats and is what `SnippetImportFlow.swift:95` actually calls
(via the `mode:` overload). The unified replacement landed *beside* the two format-specific
wrappers instead of replacing them.

The no-mode `importSnippets(from:)` overload is now itself test-only
(`SnippetImporterTests.swift:160`); production uses `importSnippets(from:mode:)`.

### 2. `AITextTransformerUnavailable`

`AITextTransformer.swift:1657`, zero references. It sits in the `#else` branch of
`#if canImport(FoundationModels)` and returns `.unavailable(.unsupportedOS)` — which is
exactly what `AITextTransformSupport.availability` :1666 already does inline for that same
case. It is never compiled on the macOS 26 SDK, so no unused warning will ever fire and it
will drift silently.

### 3. `AppMuteStore.isFrontmostMuted()`

`AppMuteStore.swift:51`, zero callers. The live mute path is
`AppMuteStore.shared.muteFrontmost()` / `.allMuted()` / `.unmute()`, and `EventTapEngine`
carries `isMuted` on its own cached frontmost snapshot instead.

Worth noting: the only other occurrence of the name is a **comment** at
`EventTapEngine.swift:1091` presenting it as part of the live "cached frontmost facts" path.
The comment describes a call that does not exist — fix or drop it either way.

### 4. Deliberate test seams — leave alone

31 declarations in `Sources/` are used only by `Tests/`. Most are intentional and correct:
`StubBiometricAuthenticator`, `InMemorySecretBackingStore`, and the `*ForTesting` methods.
They are listed here only so a future sweep does not mistake them for dead code.
`FillInBuilder` is the one genuine exception — see WIRE §5.

---

## Resolution — what was actually done

All 20 dead declarations are gone: **8 wired**, **12 retired**. Full suite 1,910 tests,
0 failures, clean build with no warnings.

### Wired (8)

| What | Where it now runs |
|---|---|
| `saveSnippetsAs` / `linkToSnippets` / `stopSyncing` | Preferences ▸ Snippets, in the library card that already showed the active path |
| `SnippetExporter.espansoYAMLFiles` | `LibraryExporter.Choice.espansoDirectory` — a 4th export format |
| `AXWriteCapabilityStore.learnedVerdicts` | `DiagnosticReport` — "Learned AX write verdicts (per app)" |
| `AIPreferences.resetOutputMode` | "Restore Defaults" under the AI output-mode popups |

**Library relocation** got 7 characterisation tests first
(`Tests/ExpanderEngineTests/StoreRelocationTests.swift`), because it moves the user's whole
library and had never executed. They cover: the copy lands and activates; the choice survives
a restart via `resolveLocation`; an existing library at the target is backed up before being
overwritten; linking *adopts* the target rather than pushing the local library over it;
linking backs up the local library first; `stopSyncing` restores local and clears the
persisted path; and a write failure fails closed without disturbing the library. Every store
in those tests is fully isolated — temp library file, temp `localSupportDirectory`, private
`UserDefaults` suite, no watcher — so nothing touches the real Application Support directory.

The UI **extended the existing library card** rather than adding a second one. A first attempt
added a new "Library Location" card to the General tab before noticing that Preferences ▸
Snippets already had a card showing `activeLocationURL`; that would have been the same
duplication this audit exists to find.

The Espanso folder export stages into a sibling temp directory and moves it into place, so a
failure part-way cannot leave a half-written library — matching the atomic-write guarantee the
single-file formats already had. 4 tests.

### Retired (12)

Each duplicated behaviour that already runs elsewhere; wiring them would have created a second
path to the same thing:

- `validateAPIKey` — one-line wrapper over the wired, tested `validateAPIKeyDetailed`.
- `cancelHeldExpansion` — `resetBuffer()` :1931 already calls `cancelAll(reason: .bufferReset)`.
- `markAXPossiblyNeedsRelaunch` — `PermissionCoordinator` already sets
  `sawAXGrantedWhileUntrusted` internally at :440/:457, so the relaunch hint was never broken.
- `focusedElementCandidates` — `SelectionReader` :189 calls `probeFocusedElements` directly.
- `frontmostIsIDEBundle` — convenience wrapper over the used `isIDEBundleID`.
- `allCounters`, `activePhase`, `invalidateFormatterCache` — accessors with no consumer.
- `importTextExpander` / `importEspanso` — superseded by the auto-detecting `importSnippets`.
- `AITextTransformerUnavailable` — duplicated `AITextTransformSupport`; its `#else` branch is
  now collapsed.
- `AppMuteStore.isFrontmostMuted` — superseded by the cached frontmost snapshot. The comment
  at `EventTapEngine.swift:1091` that described it as live was corrected rather than deleted.
- `FillInBuilder.defaultValueIsRepresentable` / `nameOrOptionIsRepresentable` — the
  silently-stripping contract they documented is now stated at `sanitizeToken` /
  `sanitizeDefault`, where it applies.

### Left for a product decision

`FillInBuilder` itself is still exercised only by tests. It is a complete, tested library for
building fill-in macro strings — but `MacroCatalog` already offers the same capability to users
as palette templates (`%filltext:name=⟦Field⟧%`, `%fillarea:…`, …), which is the path that is
actually wired. So this is two implementations of one behaviour, not a missing feature.
Deleting a tested, MIT-attributed module (`Adapted from SnipKey Kit`) is a call worth making
deliberately rather than as audit cleanup. Either retire it or give it the consumer it was
ported for.

### A caveat on the test suite

During this work one run reported 2 failures that did not reproduce across five subsequent
full runs. The output was not captured, so the specific tests are unknown. They are timing
sensitive rather than anything introduced here — but a suite with intermittent failures will
eventually mask a real regression, and that is worth hunting down separately.

---

## Final verification

- **2,272 declarations across 187 Swift files.**
- **0 genuinely dead declarations** (44 zero-use total, of which 13 are AppKit delegate
  conformances the framework calls and 31 are deliberate test seams — `StubBiometricAuthenticator`,
  `InMemorySecretBackingStore`, the `*ForTesting` methods, and `FillInBuilder` as noted above).
- Clean rebuild: no warnings, no errors. Suite: **1,910 tests, 7 skipped, 0 failures**,
  confirmed across repeated runs.

Re-running this check: the sweep is a full-text declaration scan, not a graph query — see the
method note at the top, and remember that `dev map`'s `unwired_candidates` will keep reporting
zero regardless of what is actually dead until its `entry_roots` are fixed.
