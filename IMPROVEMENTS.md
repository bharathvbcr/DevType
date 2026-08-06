# DevType — Improvement Backlog

Findings from a full read of `Sources/` (22.5k LOC), `Tests/`, and `Scripts/`.
Every item cites verified file + line. Ordered by (impact × likelihood) ÷ effort.

---

## Tier 0 — Do this week

### 0.1 The repo has zero commits
`git log` → *"your current branch 'main' does not have any commits yet"*. `git status` shows
everything untracked. 22.5k lines, no history, no revert, no tags, no remote.

```bash
git add -A && git commit -m "Initial import" && git tag v0.1.0
```

Also: `.gitignore:52-53` ignores `AGENTS.md` and `CLAUDE.md` — both exist and are byte-identical.
Track one, symlink the other.

### 0.2 No CI
No `.github/`. `Scripts/test.sh` is local-only and hardcodes `/Applications/Xcode.app`
(`test.sh:11-13`). For a CGEventTap keystroke interceptor, a silent regression in
`AbbreviationMatcher` or `ErasePlan` destroys user text. Add a `macos-14` workflow running
`swift build && swift test` on push.

### 0.3 Corrupt or evicted library file → user's snippets replaced with 4 demos, then synced
`SnippetStore.swift:327-338`

```swift
} catch {
    let backupURL = fileURL.appendingPathExtension("bak")
    try? FileManager.default.removeItem(at: backupURL)   // destroys the PREVIOUS backup
    try? FileManager.default.copyItem(at: fileURL, to: backupURL)
    let defaults = Self.sanitizeGroups([SnippetGroup(name: ..., snippets: defaultSnippets())])
    writeGroupsToDisk(defaults, force: true)             // bypasses digest + block guards
    return defaults
}
```

`force: true` skips `blockedReason()` and the digest guard (`:441`, `:449-457`). A partially-synced
iCloud file, a mid-write read, or a truncated download replaces the whole library — and that
replacement propagates to every other device.

Compounding: `:296` uses `fileExists(atPath:)`, which returns `false` for an evicted iCloud file
(`.snippets.json.icloud`). There is **no `startDownloadingUbiquitousItem(at:)` anywhere in the
repo**. Empty file (`:315-317`) silently returns `[]` with no `LoadIssue` set, and the next save
persists the emptiness.

**Fix:** never auto-write on failed load. Surface a blocking "library unreadable" state. Keep
timestamped `.bak.N` copies. Materialize ubiquitous items before reading.

### 0.4 No export path at all
Grep across `Sources/`: the only hit is `private func exportCurrentLibrary(tag:)`
(`SnippetStore.swift:642`), reachable only from `writeBackup`. No `NSSavePanel` anywhere.

Import is fully built (TextExpander + Espanso auto-detect, `AppDelegate.swift:534-574`) — the door
only swings one way, which is the opposite of the lock-in story the importers sell against. It is
also the only escape hatch if the store enters the write-blocked state (§1.4). The encode logic
already exists four times over (`:444-447`, `:576-578`, `:606-608`, `:643-645`). This is ~10 lines
plus a save panel.

---

## Tier 1 — Correctness

### 1.1 The event tap runs on the main thread
`EventTapEngine.swift:565` — `CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)`

Every `Thread.sleep`, `usleep`, synchronous AX IPC, `NSWorkspace` call, and JSON disk write on the
callback path is a **system-wide keyboard stall** and a direct cause of `tapDisabledByTimeout`.
`processingQueue` exists but the tap is not on it.

This single fact is why most of Tier 2 matters. A dedicated thread with its own `CFRunLoop` for
the tap source decouples the swallow decision from AppKit and disk.

### 1.2 Reinjected trigger keys are not tagged synthetic → re-expansion loop
`TextInjectionPipeline.swift:331`

```swift
let source = CGEventSource(stateID: .privateState) ?? CGEventSource(stateID: .hidSystemState)
```

`postUnicodeKeyEvent` and `sendLeftArrows` (`:2042`) build a **bare** source. `makeTaggedEventSource()`
(`:1101`) sets `source?.userData = SyntheticEventMarker.magicUserData`; `sendBackspaces` (`:1932`)
and `postCmdVKeyEvents` (`:1797`) use it correctly. These two do not.

So the tap's `isSynthetic` check (`EventTapEngine.swift:336`) fails for reinjected keys — they land
in the ring buffer and can re-fire the same snippet. `isExpanding` is not protection:
`restoreTriggerAfterFailedPaste` (`:1035`) runs from a 250 ms deferred re-verify (`:996`), by which
time `isExpanding` is already false. Paste unavailable → AX failed → trigger reinserted → matcher
sees the trigger again → expands again. **Two-line fix.**

### 1.3 No watchdog — one missed completion bricks expansion until relaunch
`TextInjectionPipeline.swift:276-298`

```swift
let group = DispatchGroup()
group.enter()
DispatchQueue.main.async { self.injectOnMain(...) { group.leave() } }
group.wait()          // no timeout
```

`injectQueue` is serial. If any path fails to call `completion` (most plausibly `presentFillIn` at
`EventTapEngine.swift:810`, when the panel is closed by another route), `group.wait()` blocks the
queue forever *and* `_isExpanding` never clears — so `EventTapEngine.swift:361` passes every key
through. DevType silently stops expanding, with no log line.

**Fix:** `group.wait(timeout: .now() + 10)` plus a `DispatchSourceTimer` that force-clears
`_isExpanding` and logs. Log double-completions too.

### 1.4 Blocked saves are invisible; the UI reports success for writes that never landed
`SnippetStore.swift:396-409` — `_cachedGroups` is updated *before* the write and listeners fire
unconditionally after it, regardless of `SaveOutcome`.

No file under `Sources/DevTypeApp/` references `SaveOutcome`, `.blockedByRemoteChange`, or
`.blockedByNewerSchema`. Every caller discards it:
`SnippetManagerViewController.swift:568` — `_ = SnippetStore.shared.saveGroups(groups)`.

Once `_saveBlocked` latches (`:452-455`) it clears only on a forced write or `reloadFromDisk`. In
the no-watcher configuration (`:196` passes `watcherFactory: { _ in nil }`) or on a missed watcher
event, the store becomes permanently write-blocked while the UI reports success. Every edit is
lost on quit.

### 1.5 `onExpansionSucceeded` fires on refuse and failure — and rewrites the whole library on main
`EventTapEngine.swift:955-960` invokes the success callback on *every* terminal path, including
`refuseInjectKeepingSwallow`, `.failedSilent`, and erase-precondition refusals. The declared
contract (`:179`) says success only.

Downstream (`AppDelegate.swift:421`) that calls `SnippetStore.incrementUsage`
(`SnippetStore.swift:424-437`), which does `loadGroups()` → mutate → `saveGroups()` →
`writeGroupsToDisk`: full pretty-printed JSON encode, full-file read + SHA256 for the digest guard,
atomic whole-file write, then fires *every* store listener (rebuilding `EventTapEngine.snippets`,
reloading the manager table, re-running the search panel).

**A refused expansion in a password field rewrites the entire library to disk on the thread the
event tap lives on.** At 1000 snippets that is ~1 MB of I/O per keystroke-triggered attempt.

**Fix:** thread `InjectOutcome` through the completion; move usage counters to a coalesced sidecar
file — they are not library data.

### 1.6 Cursor positioning counts UTF-16 units but arrows move graphemes
`TextInjectionPipeline.swift:1140` — `let moveLeftCount = totalUTF16Length - offset`

This is exactly the bug `ErasePlan` was written to eliminate; its doc comment says *"AX ranges are
UTF-16 code units. A posted backspace removes one grapheme cluster."* Same is true of
`kVK_LeftArrow`, but the fix never reached the cursor path. `InjectionPlanner.swift:46` even
asserts the wrong invariant.

Repro: `{{cursor}}` with an emoji or astral CJK char after it. `attemptAXCaretPosition` (`:1163`) is
correct, so this only bites on the HID fallback — i.e. Chrome/Electron, the majority path.

### 1.7 Clipboard restore can chain onto the previous snippet
`injectSecureClipboardPasteOnMain` passes `completeBeforeRestore: true` (`:911`), calling completion
at `:1513` while the payload is still on the pasteboard, with restore deferred up to
`secureClipboardPasteHoldTimeout = 8.0` (`:72`). The injectQueue releases immediately, so the next
expand within that window snapshots **our payload** as `oldItems`.

Back-to-back expands can leave a previous snippet — potentially the secure-clipboard password
payload — permanently on the user's clipboard. Also `restorePasteboard` (`:1755`) silently abandons
restore whenever `changeCount` moved, with no fallback, no log, no retry: the user's clipboard is
just gone.

`oldItems` also eagerly materializes every representation of every item on main — lazily-provided
items (file promises, large images) are either paid for or lost.

### 1.8 Secure Input is polled at 350 ms but the swallow decision uses the polled flag
`EventTapEngine.swift:365` gates on `engine.isSecureInputActive`, fed by
`SecureInputMonitor.startMonitoring(interval: 0.35)`. For up to 350 ms after a password field takes
focus, a matching trigger is still swallowed then asynchronously reinjected — **reordering
characters in a password field.**

Cheap fix: call the non-IPC `IsSecureEventInputEnabled()` in the callback *only after a match is
found* (rare), before swallowing.

### 1.9 `sanitize` silently deletes snippets on every save
`SnippetStore.swift:688-699` drops empty-trigger snippets and case-sensitive duplicates with no
warning, unconditionally in `saveGroups` (`:397`) and every load (`:326`). Duplicate a snippet and
edit the body before the trigger → it's gone at the next save.

Note the de-dup key here is case-**sensitive** while `AbbreviationMatcher` de-dupes on `lowercased()`
(`AbbreviationMatcher.swift:54-57`). So `:Hi` and `:hi` both survive to disk, then one is silently
shadowed at match time. `SnippetSearch.conflictingTriggers` (`:60-71`) is exactly the diagnostic
users need for this — and it is **dead code**, referenced nowhere.

### 1.10 `importGroups` replaces same-named groups wholesale
`SnippetStore.swift:412-422` — `current[idx] = group`. Espanso group names come from file basenames
(`EspansoImporter.swift:437`), so importing a `base.yml` or a TE group named `General` obliterates
the user's default group. No dry-run, no diff, no merge-by-trigger, no "import into new group".

### 1.11 Unsynchronized shared state
- `PermissionCoordinator.swift:95` — `lastInjectOutcome` written from injectQueue, main, and
  processingQueue with no lock, while `_cachedSnapshot` right beside it is carefully guarded.
  `InjectOutcome.refused(String)` carries a `String`, so torn writes are an over-release risk.
- `SecureInputMonitor.swift:31,43-44,64` — `lastReportedLocked` raced between the timer handler and
  `start`/`stopMonitoring`.
- `EventTapEngine.swift:149-150` — `eventTapPort`/`runLoopSource` mutated by `start`/`stop`, read by
  `reEnableTap()` (from the callback) and `checkTapHealth()`, unlocked in a class where everything
  else is locked.

### 1.12 `%clipboard` bypasses clipboard sanitization
`DynamicTemplateEngine.swift:211-215` carefully strips `{{...}}` from clipboard content before
substituting `{{clipboard}}`. But `MacroParser.swift:309-311` inserts the **raw** clipboard for the
TE-style `%clipboard` token, and `MacroRenderer.swift:71-82` then feeds that straight into the
mustache engine. A clipboard containing `{{calc:2^999}}` or `{{cursor}}` is evaluated. The
sanitizer exists; one path just doesn't call it.

### 1.13 No file coordination — multi-instance and cloud races
Zero uses of `NSFileCoordinator`, `NSFilePresenter`, or `NSFileVersion` in the repo. The optimistic
digest check (`:449-461`) is TOCTOU; `.atomic` gives a rename, not exclusion. On remote change,
`reloadFromDisk` (`:544-563`) unconditionally replaces the cache — no merge, no
keep-mine/keep-theirs, and iCloud's own `NSFileVersion.unresolvedConflictVersionsOfItem` is never
consulted.

---

## Tier 2 — Performance (all on the main thread, per keystroke)

### 2.1 The matcher is rebuilt from scratch on every keystroke ← biggest single win
`EventTapEngine.swift:1003`

```swift
let activeSnippets = snippets ?? self.snippets
let matcher = AbbreviationMatcher(snippets: activeSnippets)   // full rebuild, per key event
```

`AbbreviationMatcher.init` (`:42-63`) iterates all snippets and builds **two dictionaries**, calling
`.count` (grapheme walk) and `.lowercased()` (allocation) per trigger. At 1000 snippets: ~2000
dictionary inserts + ~1000 string allocations **per typed character**, inside a CGEventTap callback
that macOS disables if it exceeds its time budget.

The matcher is already an immutable value type. Build it once in the `snippets` setter (`:201-205`)
and store it. Smallest diff, largest effect in the codebase.

### 2.2 ~40 AX round trips per expansion, none cached
`AXContextChecker.copyFocusedElementOnce` (`:491-527`) runs all three probes unconditionally, even
when `systemWideMapped` is already `.available`. The only consumer of the losing probes is
`debugLogFocusProbe`, which bails on `guard DebugTrace.isEnabled` (`:656`) — so shipping builds pay
2 extra AX IPC round trips (each up to `messagingTimeoutSeconds = 0.05`) for nothing.

And focus is re-resolved at `TextInjectionPipeline.swift:376`, `:422`, `:464`, `:798`, `:1205`,
`:2015`, `:2017`, plus `verifyFocusedTextDelivery` inside `runPasteHoldLoop` **every 50 ms for up to
350 ms** (`:1566`). Threading one resolved `AXUIElement` through the expand — the pattern already
used correctly in `performGuardedErase` — cuts this ~80%.

### 2.3 Per-keystroke allocations in the callback
| Line | Cost |
|---|---|
| `EventTapEngine.swift:382` | `[UniChar](repeating: 0, count: 128)` — 256-byte heap alloc per key. Use `withUnsafeTemporaryAllocation`. |
| `:385` | `String(utf16CodeUnits:)` per key, even for keys that get discarded |
| `:411` | `String(engine.ringBuffer)` per key, which `AbbreviationMatcher.match` immediately converts back with `Array(buffer)` (`:84`) |
| `:408` | `ringBuffer.removeFirst(...)` — O(n) memmove every key at steady state. It's called a ring buffer but it's an `Array` with a shift. |
| `:423` | `TISCopyCurrentKeyboardInputSource` + CFString bridge per key, to test a constant. `installInputSourceObserver()` (`:1080`) already subscribes to the change notification — cache the bool there. |
| `:419` | `AppMuteStore.isFrontmostMuted()` → `NSWorkspace.frontmostApplication` + `NSLock` per key. The `didActivateApplication` observer is already installed at `:1064`. |

`AbbreviationMatcher.lookup` (`:76-79`) allocates 2 strings per call and is called with the
*identical range twice* (`:91` and `:103`, plus a third at `:120`) — up to 6 allocations ×
`min(maxLength, 64)` iterations per keystroke.

### 2.4 `NSLock` on the hot path invites priority inversion
`engine.lock`, `AppMuteStore.lock`, `PermissionCoordinator.snapshotLock`,
`AXWriteCapabilityStore.lock` are all `NSLock`, which does not donate priority. The
user-interactive tap callback can block behind a utility-QoS file-watch thread holding
`engine.lock` in the `snippets` setter. Use `os_unfair_lock`, or better, an atomically-swapped
immutable snapshot struct that removes locking from the callback entirely.

### 2.5 Watcher feedback loop with main-thread megabyte reads
`SnippetStore.swift:530-542` — every one of the app's own writes trips `DirectoryWatcher`
(`StoreWatcher.swift:31-35` watches the *directory* for `.write, .rename, .delete`), which schedules
`externalChangeDetected()` → full-file read + SHA256 **on main**. There is no debouncing anywhere.
During iCloud churn `MetadataQueryWatcher` piles on with no `disableUpdates()/enableUpdates()`
batching.

`isApplyingExternalState` is set at `:545-546` and **never read** — the intended reentrancy guard,
left unfinished.

Also `MetadataQueryWatcher.swift:29` predicates on filename only, so it fires on *any* file named
`DevType-snippets.json` anywhere in the user's ubiquitous containers.

### 2.6 Full-field UTF-16 copy in the erase precondition
`ErasePlan.swift:148,177` — `Array(value.utf16)` where `value` is the entire focused field. A 200 KB
document in TextEdit/Xcode is a 400 KB heap alloc, 2–3× per expansion, on main. Only the last
`plan.utf16Count` units before the caret are needed. Related: `verifyTextDelivery`
(`TextInjectionPipeline.swift:1894`) does `value.contains(expectedText)` — an O(n·m) scan of the
whole field, every 50 ms hold-loop tick.

### 2.7 `resolveVirtualKeyCodeForChar` brute-forces 128 `UCKeyTranslate` calls per ⌘V
`TextInjectionPipeline.swift:1827-1863`, called from `postCmdVKeyEvents` (`:1799`) on main, on every
paste and every retry, to find the keycode for "v". Cache per input source. Also two
`usleep(15_000)` at `:1805`/`:1818` = 30 ms of hard main-thread block per paste, 60 ms with retry.

### 2.8 Search recomputes lowercased snippet bodies on every keystroke
`SnippetSearch.swift:73-85` lowercases `triggerKeyword`, `displayTitle`, **and the full
`replacementText`** for every snippet, per `controlTextDidChange` (`InlineSearchPanel.swift:457-460`).
At 1000 snippets × 500 bytes that's ~500 KB of allocation per typed character. Precompute
normalized index fields per library revision.

### 2.9 `DateFormatter` churn
`DateFormatLibrary.swift:52-54` — `presetsByID` is a **computed** property, so the 16-entry
dictionary is rebuilt on every `format()` call. `:62-77` allocates a fresh `DateFormatter` per call
(~1 ms each). `DynamicTemplateEngine` has a formatter cache (`:283-302`) but `processDateTags`
(`:244`) routes to `DateFormatLibrary.format` and bypasses it entirely. Make it a `static let`;
cache formatters by `(spec, locale, timeZone)`. The cache also pins `Locale.current` at fill time
(`:293`) and never invalidates on region change.

### 2.10 `tapDisabledByTimeout` handling is fire-and-forget
`EventTapEngine.swift:331-334` / `reEnableTap()` (`:595-601`): re-enable, log, done. No counter, no
rate limiting, no distinction between `ByTimeout` (our callback was too slow — actionable) and
`ByUserInput`, no escalation. Given §1.1, timeout-disable is the most likely field failure mode and
it produces one indistinguishable `notice` line. Add per-reason counters, backoff before full
reinstall, and surface the count in `DiagnosticReport`.

---

## Tier 3 — Missing features

### 3.1 No undo-expansion
Nothing records what was just expanded. Every competing expander reverts to the trigger on
backspace within ~2 s. All the machinery exists: `ErasePlan` knows the trigger text and both unit
counts, and `restoreTriggerAfterFailedPaste` (`TextInjectionPipeline.swift:1035`) is *already* a
working "put the trigger back" implementation. It just isn't reachable by the user. Add a
`LastExpansion { erasePlan, injectedText, bundleID, timestamp }`.

### 3.2 Inject telemetry is a single overwritten variable
`PermissionCoordinator.swift:95` — `private var lastInjectOutcome: InjectOutcome?`. Five outcomes
and a dozen refuse reasons all collapse into one slot. You cannot answer "does expansion work in
Slack?", "how often does the paste hold time out?", or "which refuse reason dominates?"

`debugLogInject` already computes exactly these fields (`:612-623`, `:745-757`) but only writes them
under an opt-in `DebugTrace` default. Make it a bounded ring of
`(timestamp, bundleID, path, outcome, reason)`. Metrics the code already knows and throws away:
`PasteDeliveryResult` distribution per bundle, `AXReplaceOutcome.falseSuccess` counts,
`tapDisabledByTimeout` count, erase-precondition `.mismatch` vs `.unavailable` ratio.

### 3.3 `AXWriteCapabilityStore` learning is discarded at quit and keyed too coarsely
`AXWriteCapabilityStore.swift:23` — `private var learned: [String: Verdict] = [:]`, in-memory only.
Every relaunch re-pays the cost: for each unknown app the *first* expansion goes through the
false-success path — the one that duplicates or eats text. `AppMuteStore` next door already
implements the JSON persistence pattern.

Second issue: keyed on bundle ID alone, so a Chromium app's web view (AX lies) and its native
`NSTextField` (AX works) share one verdict. `performAXRangeReplace` already reads `role`
(`:1217-1220`) and passes it to the debug log but not to the store. `(bundleID, AXRole)` is nearly
free.

### 3.4 Every timing constant is fixed; none adapts
`calculateRestoreDelay` = `payloadBytes / 40_000` clamped `[0.15, 0.45]` (`:61-64`);
`pasteDeliverySettleDelay` 0.05; `pasteDeliveryHoldTimeout` 0.35; `pasteReverifyDelay` 0.25;
`erasePreconditionRetryDelay` 0.03; bare `0.015` pre-⌘V (`:1486`); bare `0.04` pre-arrow (`:1156`);
`count * 0.002 + 0.01` (`:1959`); `count * 0.0015 + 0.005` (`:2069`); two `usleep(15_000)`.

The system already **measures** the right quantity: `runPasteHoldLoop` knows `elapsed` at the moment
AX confirms delivery (`:1567`). A per-bundle p90 of that would make fast apps fast (they currently
pay the 0.15 s floor unconditionally) and slow Electron hosts reliable. Natural `InjectTimingStore`
sibling to `AXWriteCapabilityStore`.

Bug in passing: `calculateRestoreDelay` is misapplied to images — `pasteImageViaClipboard` (`:1720`)
feeds it TIFF+PNG byte counts, so a 1 MB image computes 25 s and clamps to 0.45 s. Image paste also
has **no** delivery verification or retry at all (compare the text path's hold loop) — it reports
`posted ? .succeeded : .failedSilent` at `:538`.

### 3.5 Macro gaps vs competitors
Absent from `MacroToken` (`MacroParser.swift:19-31`), `DateFormatLibrary.presets`, and
`DynamicTemplateEngine.resolve`:

| Capability | TextExpander | Espanso | Alfred | DevType |
|---|---|---|---|---|
| **Date arithmetic** (`%@+1D%`, `{date +1d}`) | yes | yes | yes | **no** |
| Shell / script output | yes | yes | yes | **no** |
| Clipboard history (`{clipboard:1}`) | yes | — | yes | **no** |
| Case transforms on fill values | yes | `propagate_case` | yes | **no** |
| Regex triggers | — | yes | — | **no** (import skips, `EspansoImporter.swift:231-234`) |
| **Per-app snippets** | yes | `apps:`/`exclude_apps:` | yes | **no** (only global mute) |
| Random / UUID / counter | yes | yes | yes | **no** |
| Nested with parameters | — | `vars` | — | **no** (refused at import, `:273-276`) |

Date arithmetic is the highest-value gap — the most-used TE macro after plain `%date%` — and
`DateFormatLibrary.format(_:now:locale:timeZone:)` already takes an injectable `now`.

### 3.6 Macro parser edge cases
- **`resolveNested` is lossy.** `:150-158` drops `width=`/`height=`; `literal(of:)` (`:205-223`)
  re-serializes from the lossy model, and `resolveNested` (`:183-203`) rebuilds the *whole* string
  through it whenever content contains `%snippet:`. Any snippet referencing another permanently
  loses fill-in sizing, and `%key:Enter%` normalizes to `%key:enter%` (`:136`).
- **`%` inside a macro body truncates.** `:122` — `firstIndex(of: "%")`, first wins. So
  `%filltext:name=Discount:default=50%%` truncates at `50`. No `%%` escape handling.
  `FillInBuilder.swift:8-14` works around it by stripping `%`.
- **`%clipboard` is a greedy prefix match** (`:88-92`) — `%clipboardless` renders `<clipboard>less`.
- **Cursor marker: last wins** (`:313-314`) while mustache takes *first* (`DynamicTemplateEngine:222`).
  Two engines, two rules, same pipeline.
- **`SafeMathParser` silently accepts malformed input** — `DynamicTemplateEngine.swift:46-59` has no
  `else`, so `{{calc:2--}}` renders `2`. Expressions over `maxExpressionLength`/`maxTokenCount`
  return `nil` and the tag becomes **empty string** (`:274-277`) — silent content deletion.

### 3.7 Images don't follow the library
`ImageAttachmentStore.swift:33-45` resolves to `defaultLocalSupportDirectory/Images` and never
consults `SnippetStore.activeLocationURL` (`:130`); being a singleton (`:12`), the directory is
frozen at first access. After `saveSnippetsAs(toDirectory:)` moves the library to iCloud (`:568-589`),
snippets sync but images do not — every image snippet is broken on the second Mac. `relocate`
(`:621-640`) doesn't migrate or notify.

Also: `url(forImagePath:)` (`:93-96`) appends without a traversal check, and `deleteImage` (`:103-106`)
only guards `hasPrefix("/")` — a hand-edited `imagePath: "../../../x"` escapes the store. And no
orphan collection: `SnippetEditorSheet.swift:918,932` deletes on *replace* only.

### 3.8 Import fidelity
- **TE** (`TEImporter.swift:109-138`): rich text flattened to `plainText`; `requireWordBoundary`
  never derived from TE data, so every import silently gets the `SnippetModel` default of `true`
  (`SnippetModel.swift:30`), changing TE's expand-immediately snippets; group enabled/mode/hotkeys
  dropped; `isCaseSensitive: mode == 0` (`:132`) is a magic number with no comment.
- **Espanso** (`EspansoImporter.swift:273-276`): `if replace.contains("{{")` rejects the match on
  *any* `{{` — including literal text the user wants. Combined with the blanket skips at `:231-261`,
  a typical config loses a large fraction of its matches. `propagate_case`, `force_mode`,
  `search_terms`, `apps`, `priority`, `label` all dropped.
- **Group collisions**: `makeGroupName` falls back to file basename (`:437`), so
  `match/work/base.yml` and `match/home/base.yml` silently merge — then §1.10 makes the collision
  destructive.

### 3.9 Trigger length silently capped at 64
`EventTapEngine.swift:156` `maxBufferCapacity = 64`, `LayoutBuffer.swift:19` `maxCount: Int = 64`.
`AbbreviationMatcher.maxLength` is computed from actual snippets (`:47`) with no clamp or warning. A
70-character trigger can never fire and nothing says so.

### 3.10 Bracketed paste is unconditional; terminal detection is a substring heuristic
`bracketPastePayload` (`TextInjectionPipeline.swift:951`) wraps in `ESC[200~`/`ESC[201~` whenever
`isFrontmostShellLikeContext()`. A plain `cat`, `read -p`, some REPLs, or SSH to an old system
receives the escapes literally. No capability probe, no learning.

`AXContextChecker.focusedElementLooksLikeTerminal` (`:455-468`) matches
`"terminal"/"console"/"shell"/"xterm"/"term"/"pty"` in the joined title/description/identifier — so
a VS Code tab named `terminal.ts` or an Xcode file named `Console.swift` routes a normal edit
through bracketed paste and injects visible escape sequences.

---

## Tier 4 — UX

### 4.1 No preferences window
Config is scattered across menu items in `AppDelegate.buildMenu()` (`:291-368`): Open at Login
(`:332`), Language (`:338-349`), Mute Frontmost (`:361`), Muted Apps (`:362`). Even ⌘, is bound to
"Manage Snippets" (`:313`), not settings.

### 4.2 Global hotkey is hardcoded and un-rebindable
`HotkeyManager.swift:63-64` hardcodes `kVK_ANSI_Slash` + `cmdKey`. No picker, no defaults key. ⌘/
collides with Comment Line in most editors. If `RegisterEventHotKey` fails it just logs (`:82`).

### 4.3 Hotkey macros exist in code with no UI
`HotkeyManager.swift:28` loads `HotkeyMacroAction`s from `UserDefaults` key `devtype.hotkeyMacros`
(`:39-53`), wired in `AppDelegate.swift:434-449` to `insertText`/`openURL`. Nothing in the app can
create, edit, or list them — a user must hand-craft JSON into defaults. Dead feature.

### 4.4 No tags, no nested folders, no app-scoped snippets
`SnippetGroup` (`SnippetModel.swift:123-147`) is a flat list. `SnippetModel` (`:4-18`) has no `tags`.
`AppMuteStore` is binary allow/deny per bundle — no analogue to Espanso's `filter_exec`/`filter_title`
or TE's per-group app scoping. You cannot have `:sig` mean one thing in Mail and another in Slack.

### 4.5 Statistics collected but never surfaced
`usageCount` is incremented at `SnippetStore.swift:424-430` (at the cost of a full library rewrite,
§1.5) and its only presentation is a `×N` label (`SnippetManagerViewController.swift:76`). No
characters-saved, no time-saved, no top-snippets, no sort-by-usage — TextExpander's headline
retention feature. No `lastUsedAt` field either, so "recently used" can't survive a restart
(`AppDelegate.swift:391-401` keeps 6 in memory).

`SnippetSearch` also ignores `usageCount` entirely for ranking, despite the store paying full
disk-rewrite cost to maintain it.

### 4.6 No sorting, no reordering, no undo
No `sortDescriptor` or `sorted(by` anywhere in `Sources/DevTypeApp/`. No `UndoManager`/`registerUndo`
anywhere in `Sources/`. Delete is a modal confirm (`SnippetManagerViewController.swift:663`) then
gone; "Reset Defaults" (`:851-866`) destroys the whole library behind one alert.
`AppDelegate.installEditMenu` (`:88-89`) installs ⌘Z that only reaches `NSTextView`'s field editor.

### 4.7 Inline search is substring-only
`SnippetSearch.score` (`:75-85`) is a fixed `==`/`hasPrefix`/`contains` ladder. `sgn` will not find
`:signature`. Not diacritic-insensitive (`résumé` ≠ `resume`) — should be
`folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive])`. No group-name
matching (`groupName` is display-only, `:8`). No multi-term AND. No match ranges, so no highlighting
(`InlineSearchPanel.swift:205-235` sets plain `stringValue`).

The ⌘1–9 jump handler (`InlineSearchPanel.swift:509-515`) parses
`Int(event.charactersIgnoringModifiers ?? "")`, which breaks on layouts where digits need a modifier.

### 4.8 Alert-driven UI
14 raw `NSAlert`s in `AppDelegate.swift` alone (`:553, 567, 583, 597, 608, 622, 829, 844, 871, 879,
886`) plus 3 in `SnippetManagerViewController`. `showMutedApps` (`:886-906`) builds one alert button
per muted app and decodes the choice by index arithmetic (`:902`) — breaks past ~3 apps.

---

## Tier 5 — Accessibility (the ironic one)

### 5.1 Zero accessibility API usage in the app's own UI
Grep for `setAccessibility|accessibilityLabel|accessibilityRole|NSAccessibility|isAccessibilityElement`
across `Sources/DevTypeApp/` → **no matches**. An app that requires AX permission and reads other
apps' AX trees exposes nothing over AX itself.

- `InlineSearchPanel.swift:158-236` `SearchHitCellView` — four bare `NSTextField`s + custom
  `PillBadgeView` in a plain `NSView`. `configure(with:jumpNumber:)` (`:205`) sets `stringValue`
  only. VoiceOver announces "row 1" with no content. This is the primary keyboard surface.
- `SnippetManagerViewController.swift:7-78` `SnippetRowView` — the `NSSwitch` (`:8`) has no label, so
  VO says "switch, on" with no indication of which snippet.
- `:84-141` `GroupRowView` — enabled state conveyed purely by `alphaValue = 0.72` (`:139`) and color.
- `AppDelegate.swift:231-234` — the `NSStatusItem` button sets only `image`/`imagePosition`. The
  app's only permanent affordance is unlabeled.
- `:245-289` `makeMenuHeaderView()` — custom `NSMenuItem.view`, AX-invisible unless labeled.
- `DevTypeTheme.swift:111,117` — `NSImage(systemSymbolName:accessibilityDescription: nil)` for every
  symbol in the app.

### 5.2 Status is color-only
`AppDelegate.swift:644-655` maps five engine states onto dot colors; `refreshStatusItemUI()`
(`:680-684`) sets `image` + `toolTip` but never `button.title`. Tooltips are unreliable under VO.

No `accessibilityDisplayShouldDifferentiateWithoutColor`, `...ShouldReduceMotion`, or
`...ShouldReduceTransparency` checks exist anywhere in `Sources/`.
`InlineSearchPanel.swift:130-141` `animateIn` runs an unconditional fade+scale; the whole theme is
`NSVisualEffectView` glass (`DevTypeTheme.swift:275+`) with no reduce-transparency fallback.

### 5.3 Dark mode is forced
`DevTypeTheme.swift:228,239` hardcode `NSAppearance(named: .darkAqua)` on every window and panel. The
palette (`:12-28`) is fixed `calibratedRed:` literals — no dynamic providers, no semantic colors. A
Light Mode user gets a black window; Increase Contrast does nothing.

`textTertiary` is `white @ 0.40` (`:24`) over `#0E0706` (`:17`) ≈ 3:1, below WCAG AA 4.5:1 for the
10–11pt fonts it's used at (`InlineSearchPanel.swift:162, 254, 341`).

### 5.4 No keyboard access to manager actions
`SnippetManagerViewController.swift:922-970` builds context menus with `keyEquivalent: ""` on every
item — Edit, Duplicate, Delete, Move to Group are **right-click only**. No `keyDown`/
`performKeyEquivalent` override in the file. Delete key doesn't delete; ⌘D doesn't duplicate.

---

## Tier 6 — Localization

### 6.1 The highest-stakes UI is 100% unlocalized
`LocalizationManager.swift:8-24` defines `system/en/ko/ja` with ~95 keys each at full parity, and a
correct fallback chain (`:50`). The gap is coverage:

| File | LOC | `loc.s` calls |
|---|---|---|
| `SnippetManagerViewController.swift` | 1120 | 37 |
| `SnippetEditorSheet.swift` | 957 | 30 |
| `AppDelegate.swift` | 916 | 16 |
| **`PermissionRecoveryController.swift`** | **1028** | **0** |
| **`PermissionOnboardingController.swift`** | **746** | **0** |
| **`TestExpansionLab.swift`** | **308** | **0** |
| `HotkeyManager.swift` | 162 | 0 |

~2,100 lines of first-run onboarding and permission recovery — the screens a Korean or Japanese user
hits *before the app works at all* — are hardcoded English (`PermissionOnboardingController.swift:58`
`"Step 1 of 5"`, `:229-231`, `:442`; `TestExpansionLab.swift:35-45, 74, 135, 283, 290`).
`PermissionCopy.swift` is English-only and *tested* as English (23 refs in `PermissionAuditTests`),
which will break under localization.

Also unlocalized: all 17 `NSAlert`s, all window titles (`AppDelegate.swift:715, 740, 776`), and the
Edit menu (`:88-96` uses English literals instead of AppKit's system-localized titles).

### 6.2 Structural limits
Strings live in Swift dictionaries (`:67-363`), not `.strings`/`.xcstrings`. No `xcloc` export for
translators, no `genstrings`, no pseudolocalization, **no plural rules** (`:116` literally says
`"%d snippet(s)"`), and no `CFBundleLocalizations` in `Info.plist` — macOS believes the app is
English-only (`CFBundleDevelopmentRegion = en`, line 5), so the language submenu
(`AppDelegate.swift:338-349`) is the only way to switch. `effectiveLanguageCode()` (`:55-65`) only
sniffs `ko`/`ja` prefixes, so a fourth language requires editing that switch. No RTL support.

---

## Tier 7 — Tests & tooling

### 7.1 `Sources/DevTypeApp` — 6,600 lines, 0 tests
`Package.swift:43-51` declares one test target depending only on `ExpanderEngine`. `DevTypeApp` is an
`executableTarget` (`:34-42`) and isn't even importable from tests.

Cheapest high-value fix: move `LocalizationManager` (imports only `Combine`/`Foundation`) and
`HotkeyManager` into `ExpanderEngine`, then assert `Set(en.keys) == Set(ko.keys) == Set(ja.keys)`
plus format-specifier parity. That one test prevents the entire class of
`String(format:arguments:)` crashes that `:52` can produce on a mismatched `%d`/`%@`.

### 7.2 Engine modules with zero test references
| Module | LOC | refs |
|---|---|---|
| `Sync/StoreWatcher.swift` | 52 | 0 |
| `Sync/MetadataQueryWatcher.swift` | 53 | 0 |
| `Sync/CompositeWatcher.swift` | 21 | 0 |
| `Sync/InputQuiescence.swift` | 65 | 0 |
| `Sync/TEImporter.swift` | 151 | 0 (indirect only) |
| `Engine/SecureInputMonitor.swift` | 84 | 0 |
| `Macros/FillInBuilder.swift` | 51 | 0 |
| `Layout/USKeyboardLayout.swift` | 54 | 0 |
| `Permissions/PermissionObserver.swift` | 105 | 0 |
| `Logging/DebugTrace.swift`, `DevTypeLog.swift` | 123 | 0 |

The `Sync/` cluster is the iCloud change-detection path feeding `externalChangeDetected()` and
`reloadFromDisk()` — a bug there silently loses snippets across devices. `SecureInputMonitor` is the
gate that stops DevType firing inside password fields; a false negative there means the expander
runs during password entry. Neither is tested.

### 7.3 Shallow coverage in "tested" modules
`SnippetSearch` — **1** reference in all of `Tests/`; 5 of 6 `score()` branches untested and
`conflictingTriggers` has none. `MacroPreview` — 1 ref, though it renders every row in the manager
*and* the palette. `MacroRenderer` — 3 refs vs `MacroParser`'s 20, and the renderer is what produces
the injected text. `AppMuteStore` — 2 refs, one round-trip test, nothing end-to-end.

Distribution is lopsided: `ProcessIdentity` alone accounts for 168 of ~600 type references — TCC
plumbing is heavily over-tested relative to the text-manipulation core users actually touch.

### 7.4 `ExpanderEngineTests.swift` is a 1,665-line / 100-test monolith
66 KB mixing math parser, template engine, erase counting, AX verification, settings URLs, display
status, injection planning, process identity, and store persistence. The named siblings
(`EraseSafetyTests`, `ExpandGateDecisionTests`, `PermissionAuditTests`) show the intended split.

### 7.5 No distribution pipeline
Grep across `Scripts/`, `Resources/`, `Sources/` for
`notariz|stapler|sparkle|appcast|dmg|--options runtime|sentry|crashlytics` → two *prose* mentions
only (`install-app.sh:175`, `README.md:54`).

- No hardened runtime — `package-app.sh:268` signs without `--options runtime`, so notarization
  would reject the bundle today.
- No entitlements file anywhere.
- No `xcrun notarytool` / `stapler`.
- No `.dmg`/`.zip` artifact — `install-app.sh` only does a local `cp`.
- No Sparkle: no `SUFeedURL` in `Info.plist`, no appcast. **Users have no update path at all.**
- No crash reporting, no `NSSetUncaughtExceptionHandler`.

### 7.6 Version numbers are frozen placeholders
`Resources/Info.plist:19-22` — `CFBundleShortVersionString = 1.0.0`, `CFBundleVersion = 1`. Nothing
bumps them. `AppDelegate.swift:246` renders that in the menu header and `DiagnosticReport.swift:141-142`
embeds it in diagnostics — so every bug report from every build reads "1.0.0 (1)". With no git tags
either, a user diagnostic cannot be mapped to a build. Derive both from `git describe` in
`package-app.sh`.

---

## Tier 8 — Structure

### 8.1 `TextInjectionPipeline.swift` is 2,071 lines doing six jobs
Natural seams, all along existing method boundaries:

| Extract | Lines | Contents |
|---|---|---|
| `HIDKeyPoster` | 327-350, 1078-1105, 1785-1863, 1924-1960, 2034-2070 | `postUnicodeKeyEvent`, `postTrailingKeys`, `makeTaggedEventSource`, `postCmdVKeyEvents`, `resolveVirtualKeyCodeForChar`, `sendBackspaces`, `sendLeftArrows`. Zero AX, zero pasteboard — and the single place to fix §1.2 and §1.6. |
| `PasteboardBroker` | 1429-1783 | `pasteViaClipboard`, `runPasteHoldLoop`, `pasteImageViaClipboard`, `restorePasteboard`, generation tokens. Owns the snapshot/restore invariant, currently spread across three sites — `1489-1506`, `1589-1605`, `1636-1652` are three copies of the same if/else. |
| `AXTextWriter` | 1163-1182, 1200-1388, 1409-1427, 1970-1999 | The only code that should touch `kAXSelectedText*`. |
| `DeliveryVerifier` | 1865-1922 | Already nearly pure. |
| `EraseExecutor` | 122-232, 2001-2032 | Pairs with `ErasePlan.swift`, which owns the pure half. |
| `InjectTiming` | 59-106, 168, 1075 | All the magic delays — see §3.4. |

What's left is the actual policy coordinator (~500 lines). `injectOnMain` alone spans 352-831.

### 8.2 Parameter tromboning
`swallowedFinalKey`, `swallowedUnicode`, `swallowedKeyCode`, `swallowedFlags` travel as four separate
parameters through `inject`, `injectOnMain`, `injectSecureClipboardPasteOnMain`,
`refuseInjectKeepingSwallow`, `finishPasteDelivery`, `restoreTriggerAfterFailedPaste`, and mirror
into `EventTapEngine.performDeferredExpand` / `finishDeferredInject` / `refuseAfterSwallow` — nine
signatures. A `SwallowedKey` struct (folding in `mustReinject`, which at `EventTapEngine.swift:323`
is literally `{ didSwallow }`) collapses ~36 parameters to 9.

There are **nine** near-identical `refuseInjectKeepingSwallow(reason:)` call sites in `injectOnMain`
differing only in the reason string.

### 8.3 Retry logic that only works on the main thread — by blocking it
`TextInjectionPipeline.swift:190-192`

```swift
guard retryOnMismatch, first.blocksErase, Thread.isMainThread else { return first }
Thread.sleep(forTimeInterval: Self.erasePreconditionRetryDelay)
```

`AXContextChecker.swift:159-162` has the identical shape. The condition is inverted from what you'd
want: the safety net is *only* available on main, and it's implemented by blocking main for 30 ms —
during which the tap callback can't run. Off-main callers get no retry at all, so behavior silently
differs by call site.

---

## Suggested order

1. `git init` + commit + tag + remote. Nothing else matters until this exists.
2. CI workflow (`swift build && swift test` on macOS 14).
3. Cache the `AbbreviationMatcher` in the `snippets` setter (§2.1) — biggest win, smallest diff.
4. Remove `writeGroupsToDisk(defaults, force: true)` from the corrupt/missing branches; add
   ubiquitous-item download; hard-fail UI state (§0.3).
5. Tag the two untagged event sources (§1.2) and add the inject watchdog (§1.3) — two small,
   high-severity fixes.
6. Move `usageCount` to a coalesced sidecar; stop firing `onExpansionSucceeded` on refuse (§1.5).
7. Ship JSON export + `NSSavePanel` (§0.4) — cheapest user-visible feature and the safety valve for
   everything above.
8. Accessibility labels on `SearchHitCellView`, `SnippetRowView`, `GroupRowView`, status item; add
   keyboard equivalents (§5.1, §5.4).
9. Versioning from `git describe`, hardened runtime, notarization, DMG, Sparkle (§7.5, §7.6).
10. Localize the permission/onboarding controllers; move `LocalizationManager` into `ExpanderEngine`
    with key-parity tests (§6.1, §7.1).
11. Move the tap off the main thread (§1.1), then the hot-path allocation work (§2.3, §2.4).
12. Date arithmetic + per-app snippets — the two highest-value feature gaps (§3.5, §4.4).
