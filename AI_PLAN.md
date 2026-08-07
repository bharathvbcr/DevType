# DevType — On-device AI + Hybrid Command Palette (revised plan of record)

Supersedes previous AI_PLAN.md content. Same goal, corrected API basis.

Everything below was verified on this machine by reading the installed
`.swiftinterface` and by running the suite (`Scripts/test.sh` → **451 tests, 0 failures**,
exit 0). Line references were opened, not recalled.

---

## 0. Correction: the SDK this repo actually builds against

`AI_PLAN.md` is written against "**MacOSX27.0.sdk**, FoundationModels **2.0.62.1**".
That is not what is installed, and its entire Section B does not compile here.

| Claim in `AI_PLAN.md` | Measured on this machine |
| --- | --- |
| `MacOSX27.0.sdk` | Only `MacOSX.sdk` **26.5**. `MacOSX26.sdk` / `MacOSX26.5.sdk` are symlinks to it. No 27.0 SDK. |
| FoundationModels `2.0.62.1` | `-user-module-version 1.5.2`, `-target arm64e-apple-macos26.5` |
| `GenerationError` is `deprecated: 27.0` | The 1501-line interface contains **zero** occurrences of the string `deprecated`. Nothing is deprecated. |
| `LanguageModelError` | 0 occurrences |
| `PrivateCloudComputeLanguageModel` | 0 occurrences |
| `ContextOptions.reasoningLevel` | 0 occurrences (`ContextOptions` does not exist) |
| `GenerationOptions(samplingMode:)` | 0 occurrences. Real init is `init(sampling:temperature:maximumResponseTokens:)` — **current, not deprecated**. |
| `LanguageModelCapabilities` / `.guidedGeneration` | 0 occurrences |
| `GeneratedContent.ParsingError` | 0 occurrences (`decodingFailure` is still the live case) |
| `SystemLanguageModel.Adapter` is `obsoleted: 27.0` | `public struct Adapter` exists and is not obsoleted |
| Stream exposes `TextFragment` / `TextSegmentReplacement` | `ResponseStream.Element == Snapshot { content, rawContent }`. Cumulative snapshots only; no fragment type. |

`sw_vers` does report `ProductVersion 27.0`, but on `BuildVersion 26A5388g` — a 26.x build
train — and the host OS version is irrelevant to compilation anyway. **What you can call is
set by the SDK, and the SDK is 26.5.**

### Consequence

- **B1, B2, B3, B5 are struck.** They describe APIs that do not exist. B1 is the sharpest
  one to retract: it claims the current error mapping is broken and silently degrades every
  failure to "unknown error". It does not. `AITextTransformer.mapGenerationError`
  (`AITextTransformer.swift:439`) maps **all nine** real `GenerationError` cases correctly.
  Rewriting it against `LanguageModelError` would break the build.
- **B2 also dissolves the "PCC vs. chunking" decision** the old plan flagged as needing an
  answer before Milestone 4. There is no PCC type to call. If oversized input matters,
  chunking (C8) is the only available answer — see §B′4.
- **B4 is half real** and survives in reduced form as §B′ below.

Sections **A, C, and D were checked line by line and are accurate.** Every file:line
citation in them resolves to exactly the code described. That work stands and drives the
plan.

---

## A. Blocking — the typed path cannot fire today *(confirmed, unchanged)*

### A1. `SelectionMonitor` clears its cache the moment the selection collapses

`Sources/ExpanderEngine/AI/SelectionMonitor.swift:286-289` — confirmed verbatim:

```swift
guard let text = SelectionReader.copySelectedText(from: element), !text.isEmpty else {
    clearCache()
    return
}
```

`defaultTTL` is `1.5` (`:17`). The typed design requires the cache to *outlive* the
selection: typing `;proof` replaces the selection with the trigger text, which fires
`kAXSelectedTextChangedNotification` with an empty selection, which clears the cache before
the trigger ever matches. `handleTypedAITransformExpand` then refuses at
`EventTapEngine.swift:1420` with "AI selection unavailable". **The TTL never gets a chance
to matter.** This is the single reason the headline feature does nothing.

The erase arithmetic downstream is already correct: the selection is replaced by `;proof`,
the erase plan removes those 6 characters, and the transform is injected into the resulting
gap. Net effect is selection → transformed text, as designed. Only the cache lifetime is wrong.

**Fix — make the cache last-known-good rather than live:**

- On an empty selection, **keep** the existing entry; let `isFresh(maxAge:)` retire it.
- Clear only on: app switch, feature disable, Secure Input, mute, allowlist removal, or a
  focus change to a *different* AX element.
- Store the `AXUIElement` alongside the text and assert same-element at expand time
  (`CFEqual`). This is what makes a longer TTL safe.
- Add `consumeSelection()` — single-use, so two triggers in a row cannot both transform the
  same stale text.
- Raise the TTL to **6 s**. 1.5 s is shorter than it takes to type a 6-character trigger.
  Single-use + same-element containment carries the safety, not the clock.

**Test gap that let this ship:** `AIPlumbingTests` seeds the cache via
`seedCacheForTesting(_:)`, so it never exercises the notification path. Add a test that
drives `handleAXNotification`-shaped input (non-empty → empty) and asserts survival.

### A2. Weak-AX rejection compounds A1
`cachedSelection(rejectWeakAX: true)` (`:105`) drops Chrome/Slack/Electron. Defensible, but
combined with A1 the typed path works nowhere. After A1, keep the rejection and give it a
distinct message ("Chrome doesn't report selections reliably — use ⌘⌥A here") instead of the
generic `ai.typed.selectionUnavailable`.

### A3. Cancelling the preview eats the typed trigger *(confirmed)*
`EventTapEngine.swift:1440-1467`: erase runs, `endExpansion()` fires, the panel takes over.
Cancel leaves the user with neither their trigger nor a result. Pass the erased trigger to
the panel and re-inject on cancel via the existing `erasePlan: .empty` path.

### A4. CI never compiles the AI code *(confirmed)*
All three jobs in `.github/workflows/ci.yml` are `runs-on: macos-14` (lines 23, 58, 99).
`canImport(FoundationModels)` is false there, so `AITextTransformer` compiles to the `#else`
stub. Add a `macos-26` job; keep `macos-14` as the regression guard for the stub path and the
`.macOS(.v14)` deployment target.

---

## B′. The macOS 26 surface you own but do not use

This replaces old Section B. Everything here exists in the installed interface.

### B′1. `prewarm()` warms a session that is then discarded *(was D1 — promoted, biggest win)*
`AITextTransformer.swift:196-209` builds `warmSession` with placeholder instructions
("You transform text…"), but `runTransform` constructs a **fresh** session per call at
`:332` with the real per-kind instructions. The warmed prefix cache never applies. Prefill
dominates perceived latency.

The real API is `prewarm(promptPrefix: Prompt? = nil)` (interface line 342) — so prewarm with
the actual per-kind instructions and prompt framing. Fresh-session-per-call is the right
*safety* default (no transcript bleed); only the warm path needs to match it.

### B′2. `sampling` — real, current, and unused
`GenerationOptions.SamplingMode` (line 1313) offers `.greedy`, `.random(top:seed:)`, and
`.random(probabilityThreshold:seed:)`. The code passes only `temperature` (`:334`). Use
`.greedy` for `proofread` — it is a correction task where retry variance is a bug, not a
feature. `seed:` also makes transforms reproducible, which makes the Retry button honest.

### B′3. Locale gating before the spend
`supportedLanguages` (line 586) and `supportsLocale(_:)` (line 589) are never called. Today a
non-supported locale fails *after* a ~1.4 s prefill with `.unsupportedLanguageOrLocale`.
Check once at palette open and grey out AI rows with a real reason.

### B′4. `isChunkSafe` is declared, tested, and never used *(was C8 — now forced)*
With PCC off the table, chunking is the only answer to `.inputTooLarge` for the four
chunk-safe kinds. Either implement paragraph chunking (serialized through the same
single-flight latch, streaming progress per chunk) or delete the property. `contextSize`
(line 634) is real, so the budget maths is sound — it is only the >context path that dead-ends.

### B′5. Cheap correctness items
- `session.isResponding` (line 335) is a cheaper truth source than the actor latch. Keep the
  latch (it is the right UX guard); use `isResponding` for diagnostics.
- **Fix the stale comment** at `AITextTransformer.swift:142`: concurrent `respond` does not
  "trap the process", it throws `.concurrentRequests` — which the code already maps at `:458`.
- `mapGenerationError` sends `.unsupportedGuide` to `.unknown(...)` (`:460`). Give it a case
  and a localization key; guided-generation failure is diagnosable, not mysterious.
- `resolvedInstructions` (`:375-384`): the `if kind == .custom` branch is byte-identical to the
  fallthrough. Dead branch — delete.

### B′6. Two unused capabilities that serve "complete use of on-device AI"
Both exist in the installed SDK and neither is referenced anywhere in `Sources/`:

- **`Tool` protocol** (line 1184) + `ToolDefinition`/`ToolCall`/`ToolOutput`. The on-device
  model can call *DevType's own* functions. This is a materially better answer to natural-language
  palette routing (C4 stage 2) than a `@Generable` classifier: instead of asking the model to
  pick an ID from a list, expose `resolveDate`, `runMacro`, and `findSnippet` as tools and let
  "next friday in ISO" resolve through `DateFormatLibrary` — real logic, not a guess. It also
  removes the classifier's failure mode where the model invents an ID that does not exist.
- **`SystemLanguageModel.UseCase.contentTagging`** (line 525) — a purpose-built tagging model.
  Natural fit for auto-suggesting groups/tags on snippet creation, and as a cheap
  intent-router for the palette.

---

## C. Palette — from "search box with AI rows" to a real command surface *(confirmed)*

### C1. The snippet editor cannot set `aiTransform` *(confirmed)*
`SnippetEditorSheet.swift:721-737` renders a **read-only hint**; `:1621-1625` preserves the
value on save. No control sets it. AI snippets can only be born from a template, never
converted or changed. Add an "AI transform" popup (None + 9 kinds + Custom) next to the
trigger field.

### C2. `custom` is fully implemented and completely unreachable *(confirmed — highest leverage)*
The whole path works: `EventTapEngine.swift:1456-1467` routes `snippet.replacementText` →
`customInstructions` when `kind == .custom`; `AITextTransformer.resolvedInstructions` appends
it; `AITransformFlow` threads it. It is unreachable because of exactly two things:
`AITransformKind.builtInPalette` filters `.custom` out (`AITransformKind.swift:40-42`) and
C1's missing control.

**Fix:** (a) the C1 popup; (b) a **`>` prefix** in the palette routing free text to `.custom`
— `> make this sound like a Slack message` becomes a one-shot instruction over the selection.
This is the single change that turns a fixed 9-verb menu into an open-ended one, and it is
most of what "complete use of on-device AI" means in practice.

### C3. The palette hides tools the codebase already has *(confirmed)*
`MacroCatalog.all` (~50 descriptors) and `MacroTransforms` already implement case conversion,
UUID, random values, and counters. `SafeMathParser` exists in
`DynamicTemplateEngine.swift:4` and is unit-tested. `CommandPaletteCatalog.commands`
(`:115-239`) is a hand-rolled list of 11 that exposes none of it.

Bridge `MacroCatalog` → `[PaletteCommand]` so one catalogue feeds both palettes, then add:
case ops, line ops (sort/dedupe/trim/number), encode (base64/URL/HTML/JSON/hash), generate
(UUID/lorem/password), count (preview-only), time (`next friday`, `in 3 weeks`, epoch ⇄ date),
and `= 1200 * 1.0825` inline math through the existing parser.

`parseRelativeDayQuery` (`:440`) already does dynamic `date±N`. Generalize it into one typed
query parser (`= expr`, `> instruction`, `date±N`, `+3w`, `next friday`) instead of growing
the regex list.

### C4. `semanticBoostIDs` is plumbed but nothing supplies it *(confirmed)*
`matchCommands` accepts it and applies a decaying boost (`:303`); `InlineSearchPanel.swift:627`
never passes one. Two stages:

- **Stage 1 — offline, zero latency.** `NLEmbedding` (NaturalLanguage is not currently
  imported anywhere in `Sources/`). Note it is a *word* embedding — multi-word queries need
  token-vector averaging, and it returns `nil` for out-of-vocabulary tokens, so the fallback
  to today's behaviour must be the default path, not the exception.
- **Stage 2 — model-backed, strictly off the critical path.** Prefer the **`Tool` approach
  from B′6** over a `@Generable` classifier. Either way: ~250 ms debounce, never gates
  rendering, guarded by `AIPreferences.isEnabled` and the single-flight latch so palette
  typing cannot starve a real transform.

Keep `conversationalBoost` (`:581`) regardless — it is a good cheap prior.

### C5. Rank commands by use *(confirmed, with a wrinkle the old plan missed)*
Snippets get `usageBoost`; commands are static-scored only. **`UsageStatsStore` is keyed by
`UUID`** (`Stat` at `:20-35`, every accessor takes `UUID`), but `PaletteCommand.id` is a
`String` like `"ai.proofread"`. "Extend `UsageStatsStore` with command IDs" is therefore not a
one-liner — decide between a parallel string-keyed sidecar (cleaner, my recommendation) or a
deterministic UUIDv5-style derivation from the command ID (no schema change, but opaque in the
on-disk file). Also seed the empty-query view from recency instead of the hard-coded
`suggestedIDs` set (`:281-285`).

### C6. Preview panel gaps *(confirmed)*
- No diff. For `proofread` "what changed" is the entire question, and both strings are
  already in hand.
- No kind-switcher in the panel header — changing your mind costs a full ⌘⌥A round trip.
- **`AIPreviewPanel.swift:514-515` writes `NSPasteboard.general` directly**, desyncing
  `changeCount` — precisely the hazard `PasteboardBroker` exists to prevent. Route it through
  the broker. (Smallest and most clearly correct item in section C.)

### C7. No undo after a `.direct` replace *(confirmed)*
`proofread` defaults to `.direct`: selection replaced, original gone, no confirmation. Stash
the pre-transform text and expose "Undo last AI" in the palette.

---

## D. Performance *(confirmed; D1 promoted to B′1)*

1. **Three `tokenCount` round-trips per transform** — `evaluateBudget` (`:387-404`) awaits
   instructions, input, and framing separately. Instructions and framing are static per kind;
   cache them keyed by kind. Only the input count is genuinely dynamic.
2. **Clipboard read on every keystroke** — `InlineSearchPanel.swift:624` calls
   `NSPasteboard.general.string(forType:)` inside `refreshHits()`. Read once on panel open and
   on `changeCount` change.
3. **Whole-table reload per keystroke** — `refreshHits` rebuilds every row then calls
   `tableView.reloadData()` (`:643`). Fine at 50 rows; not once C3 lands. Diff and reload ranges.
4. **`matchCommands` re-does per-command `loc.s(titleKey)` lookups for every term.**
   Precompute a lowercased search blob per command once at catalogue build.
5. **New — dead O(n²) scan in the ranking hot loop.** `CommandPaletteCatalog.swift:305-314`:
   an `if case .date(.offsetDays(...))` whose body is **empty except for a comment**. It runs a
   `hits.contains(where:)` scan for every command on every keystroke and then does nothing
   with the result. Delete it.

---

## Revised sequencing

**Milestone 1 — make it work.** A1 selection cache (+ the notification-path test) · A2
message · A3 cancel restores trigger · A4 macOS 26 CI job · B′1 prewarm.
*Nothing here is new surface. A1 alone is the difference between the feature existing and not.*

**Milestone 2 — make it reachable.** C1 editor popup · C2 `custom` + `>` prefix · C6
broker fix + diff · C7 undo · D1/D2.
*C2 is the highest-leverage item in the document: two small changes unlock a fully built path.*

**Milestone 3 — make it a command palette.** C3 MacroCatalog bridge + typed query parser ·
C5 usage ranking (decide the key-type question first) · D3/D4/D5.

**Milestone 4 — finish the on-device surface.** B′2 sampling · B′3 locale gating · B′4
chunking (now mandatory, not optional) · B′5 cleanups.

**Milestone 5 — semantics.** C4 stage 1 (NLEmbedding) → measure → stage 2 via the `Tool`
protocol (B′6) only if stage 1 falls short.

Deployment target stays `.macOS(.v14)`: every FoundationModels call stays behind
`#if canImport(FoundationModels)` + `if #available(macOS 26.0, *)`, with the `#else` stub for
macOS 14–25. **There is no macOS 27 tier to add.** Revisit only when a 27.0 SDK actually ships
and the interface can be re-read.

---

## Gaps against the original request

- **"format"** — the 9 kinds are proofread, rewrite, paraphrase, expand, condense, formal,
  friendly, bulletize, promptEnhance. There is no general *format/reformat* (as JSON, as a
  table, as Markdown). Either add a kind, or treat it as the flagship `>` custom instruction
  from C2. `DynamicGenerationSchema` (interface line 1330) supports runtime-shaped structured
  output if you want a real "format as ⟨schema⟩" tool.
- **Prebuilt tools / instant macros** — C3 is the whole answer, and the inventory already
  exists; this is bridging work, not new logic.
- **Natural-language palette** — C4 stage 1 is free and safe. Stage 2 spends model time on
  *search*, in an app whose promise is that expansion never waits on a model. The debounced
  non-blocking design keeps that promise; B′6's `Tool` routing keeps it *and* grounds the
  answer in real date/macro logic instead of a classifier's guess. Worth choosing deliberately
  rather than defaulting into it.
