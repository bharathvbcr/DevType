# Secret boundary audit — 2026-09-12

Scope: the follow-up to `docs/audits/2026-09-12-secret-isolation-hardening.md`. That audit
established the independent-secrets design (GitPulse task `528842ad-…`, commit `a60f7fd`); this
one removes the unreachable `.secrets` filter branch the review of it surfaced, then audits the
secret/snippet boundary for the same *class* of defect and hardens what it found.

Baseline: `27e33ab`, working tree clean, full suite **3168 tests / 0 failures** before any change.

Security impact: every change here **narrows** what can reach a secret. Nothing widens access,
no authentication, authorization, crypto, or key-handling code was touched, and no keychain item,
signing identity, or real secret value was read or modified.

## Findings and fixes

### 1. `.secrets` was an unreachable filter state, not just a dead branch

`SnippetManagerViewController` routed the `.secrets` chip to the Secrets manager at both entry
points (`filterChipTapped`, `showAllSnippets`), so `activeFilterChip` could never hold it — yet
the filter switch still carried `case .secrets: filtered.filter(\.isSecret)`. The table is fed by
`loadSnippetGroups()`, which strips secrets, so that branch could only ever have produced an empty
list. It was unreachable *and* wrong.

Deleting the branch alone would have left the impossible state representable. Instead the type was
split: `SnippetFilterChip` remains the chip row (all nine chips, including `.secrets`, which keeps
its label and its place), and the new `SnippetListFilter` is the set of narrowings the list can
actually be in — with no `secrets` case. `SnippetFilterChip.listFilter` returns `nil` for the
navigation chip and is the single place the distinction is written down. The filter switch is now
exhaustive over `SnippetListFilter` without pretending to handle secrets.

`AppDelegate.openSnippetManager(filteringBy:)` was also routing *after* opening the snippet
manager, so a `.secrets` argument would have raised both windows; it now routes first.

### 2. `NestedSnippetResolver` had a fail-open default on a security exclusion

`init(snippets:excludingSecrets: Bool = false)`. Both production callers passed `true`, so nothing
leaked — but the default was the unsafe one, and `NestedSnippetResolver(snippets: library)` (the
call a new site writes without thinking, and the exact shape of the existing
`testEmptyLibraryResolvesNothing`) silently inherited it.

The parameter is removed; secrets are always dropped. The flag predates isolation, when secrets
were snippets with triggers; a secret now carries no trigger at all, so indexing one could only
shadow the `""` key. `docs/ARCHITECTURE.md` already claimed secrets were "structurally excluded
from nesting lookups" — the documentation was ahead of the code, and is now true.

**Red/green proof:** the new tests were run against the pre-fix resolver and failed exactly as the
defect predicts — a secret answering `Optional("")` where the ordinary snippet behind it
(`body1`, `body2`) should have resolved. A secret shadowed real triggers.

### 3. `transactionGroups` could emit duplicate group IDs

`SnippetDocument.init` retained a group holding the reserved projection ID
(`00000000-…-0001`) whenever it also held real snippets — correctly refusing to drop user data,
but keeping the reserved identity. `transactionGroups` then appended the secret projection under
that same ID, producing two groups sharing one identifier in the projection every mutation walks
with `firstIndex(where: { $0.id == ... })`.

`encode` already refused such a document and `decode` already rejects the reserved ID arriving
from disk, so this could never reach or come from a file; the damage was confined to the in-memory
projection handed to mutations before that refusal — and the refusal itself blocked *every* save
while the group existed. The snippets are now re-homed under a fresh ID, so the reserved ID
belongs exclusively to the projection. The keep/drop condition is unchanged
(`contains(where: !isSecret)` ⟺ non-empty after removing secrets).

### 4. Backup and share were one undocumented word apart

`SnippetStore.exportLibraryData()` encodes `loadGroups()` and therefore carries secret metadata;
`LibraryExporter` encodes `loadSnippetGroups()` and carries no secret record at all. Both are
correct for their purpose — a restore that drops secrets is a data-loss bug — but nothing said so,
and the unwired `SnippetStore.exportLibrary(to:)` is exactly the method a future "Export Library"
implementation would reach for. Documented on both methods, in `SECRETS.md`, and in
`docs/UNWIRED_INVENTORY.md`; both halves are now pinned by a test.

### Correct behaviour confirmed, not changed

- Publishing metadata for a secret whose value was never stored is **refused**
  (`SnippetStore.swift`, "A newly referenced secret has no stored value"). An adversarial test was
  written expecting the save to succeed; the refusal is right and the test premise was wrong. The
  guard is now pinned by `testPublishingASecretWithNoStoredValueIsRefused`.
- A secret that keeps a value in memory (`isSecret` set *after* `init`, so the initialiser's
  scrubbing never runs) cannot carry it to any durable surface: the document re-homes it through
  `SecretModel`, which has no field to hold one. Verified through a real save to disk, not only
  the in-memory projection.
- Imported snippets cannot collide with a secret's UUID: the importer handles TextExpander and
  Espanso only, neither carries DevType identifiers, and no `SnippetModel` in `Sources/…/Sync/` is
  constructed with an explicit `id:`.

### Identified, deliberately not changed

`SnippetRowView.configure`, the duplication planner branch, the thumbnail/sort helper and the
delete-confirmation message in `SnippetManagerViewController` all still special-case `isSecret`.
Removing them is a separate concern from the filter-state fix, so they are filed as follow-up
work rather than bundled here.

> **Correction, same day, after the follow-up landed in `8ce6538`.** The sentence that stood
> here — "the manager's table is fed only by `loadSnippetGroups()`, so none of it can run ... it
> is harmless display code for an impossible state" — was true of two of these four sites, and
> **wrong about a third**. Acting on it as written would have deleted live code. Site by site:
>
> - `SnippetRowView.configure` and the delete-confirmation message **were** unreachable, for
>   exactly the stated reason. Both are removed in `8ce6538`.
> - The duplication planner branch **is** unreachable in production, but not for the stated
>   reason. `SnippetDuplicationPlanner.duplicate` runs inside `mutateGroups`, whose `latest`
>   *does* carry secrets. It is the *source* that cannot be one: it comes from the manager's
>   table, and `validatedTargets` requires whole-model equality (`matches[0].snippet ==
>   expected`), which a secret can never satisfy against a non-secret row. Retained — it is the
>   generic type's own guard, and `SnippetManagerDuplicationTests` pins it.
> - `SnippetManagerMutationCommitter.resourceProjection` — the "thumbnail/sort helper" — **is
>   live and load-bearing. Do not remove it.** `mutateGroups` reads `loadGroupsUnlocked()`, the
>   whole library, and `resetToDefaults()` rebuilds `transactionGroups`, which appends the
>   secret projection group whose rows are `snippetAdapter`s with `isSecret: true`. Its
>   `isSecret` comparison is what drives `allowsModelOnlyUndo` to `false` when a mutation
>   changes the set of secrets — precisely the case where undo cannot restore a Keychain value.
>   `PreferencesWindowController.resetLibrary()` is a second caller, outside the snippet
>   manager entirely. `SecretModel.swift` says so directly: "Whole-library transactions still
>   use loadGroups/mutateGroups so secret edits share their digest guards, rollback and
>   cleanup."
>
> The general lesson: "the table is fed by `loadSnippetGroups()`" bounds what the *view* shows,
> not what the *mutation* path walks. Those are different corpora, and only the first is free
> of secrets.

## Verification

All results below are from completed commands in this session. Coverage is measured execution,
not proof of correctness.

| Check | Result |
|---|---|
| Full suite, before any change | 3168 tests, 6 skipped, 0 failures |
| Full suite, final | **3184 tests, 6 skipped, 0 failures**, `test.sh` exit 0 |
| ThreadSanitizer, secret-boundary suites | 109 tests, 0 failures, no diagnostics |
| AddressSanitizer, secret-boundary suites | 110 tests, 0 failures, no diagnostics |
| Scaled soak (`DEVTYPE_SECRET_STRESS=8`) | 128 seeds × 80 operations = **10,240 model operations**, 0 failures |
| Repeated runs | **20/20 passed**, 178 tests each = 3,560 executions, 0 failures |
| Release build | `swift build -c release` succeeded |
| Red/green on finding 2 | New tests fail against the pre-fix resolver, pass after |

The 6 skips are environment gates (whisper.cpp absent, opt-in benchmarks, WindowServer, non-root
fixtures); none is a secret test. The one secret test behind a macOS-26 availability gate
(`testSnippetRoutingCannotBeShadowedByASecretWithNoTrigger`) was confirmed to *run* on this host
(macOS 27.0), not skip.

New tests: `Tests/ExpanderEngineTests/SecretBoundaryAdversarialTests.swift` (11), four navigation-chip
tests in `SnippetManagerFilterTests`, three in `NestedSnippetResolverTests`. The existing
model-based stress now also asserts, at every step, that no secret value appears in the library
bytes, that the transaction projection has no duplicate group IDs, and that no user group holds
the reserved ID.

## Limits

No live credential, keychain item, master key, signing identity, or installed app was touched.
Physical Touch ID, third-party password fields and clipboard managers, and the real
**Preferences → Advanced → Repair Secret Storage** flow remain manual verification gates. The
stress campaign exercises cooperating in-process stores with fault injection and lock contention;
it does not establish OS-level guarantees or power-loss atomicity across the separate metadata and
value files. No claim of completeness is made: this audit covers the secret/snippet boundary and
the filter-state defect, not the voice, model-provider, or undo subsystems.

---

## Addendum — secrets UI/UX pass

Scope decided with the user: a full redesign of the secrets surfaces, and a standard reveal
toggle in the editor (chosen over hold-to-reveal and over a confirm-value field).

### The security decision, stated plainly

`SECRETS.md` listed "shoulder-surfing the editor" as something the design protected against. A
reveal toggle trades that away deliberately, so the document now says what is actually true
rather than keeping a claim the code no longer honours. The narrowed guarantee: the field is
concealed by default, an existing value is still never prefilled (so opening the editor on a
stored secret shows nothing to read), revealing is explicit and per-sheet, and while it is in
effect the editor says so on screen. What was bought: a typo in a secret used to surface only
when a paste failed in a login form, and the usual fix was to retype it blind again.

The twins are swapped in place rather than both kept installed. The outgoing field is cleared as
the value moves, so no second copy of the value exists in the view tree, and the editor still
authors exactly three fields — the contract `SecretManagementTests` already pinned.

### What changed

| Surface | Change |
|---|---|
| Secrets manager | Header with icon badge; glass-card list matching the snippet manager; two-line rows showing tags and a disabled badge instead of one truncated line; distinct empty states for "no secrets yet" (offers Add) and "none matched" (does not); action bar with the same SF Symbols as the snippet manager's; keyboard operation; visible keyboard hint |
| Secret editor | Icon badge and subtitle; shared `makeFieldCaption` idiom; **Show/Hide** reveal toggle with an on-screen notice; a hint that says blank keeps the stored value (it previously repeated the placeholder verbatim); removed placeholders that duplicated their own captions |
| Copy Secret submenu | The submenu caps at 20 entries and said nothing about it — 20 of 25 read as "the other five are gone". It now names how many are not listed and points at Search Secrets |
| Search Secrets panel | Used the generic snippet-palette empty text; now distinguishes "no secrets yet" from "none matched" in the user's own terms |

Keyboard: Return copies and ⌫ deletes, both bound to the **list** rather than as button key
equivalents — a key equivalent fires wherever focus is, so ⌫ would have deleted the selected
secret while the user was typing in the search field. ⌘N and ⌘E are modifier-based and safe as
button equivalents. This is the accessibility gap the redesign was really for: every action in
this window previously required a mouse.

### Verification

- Full suite: **3189 tests, 6 skipped, 0 failures**, exit 0.
- `P1UICompletionTests` caught a real regression mid-pass: the first draft of the editor dropped
  `setAccessibilityTitleUIElement`, which is what links a field to its caption for VoiceOver. The
  association was restored for all three fields (both value twins share the one caption) rather
  than the contract being relaxed.
- `testSecretViewsFitTheirWindows` now lays out four states, not two: the empty manager and the
  revealed editor each add controls the populated states never render.
- Rendered snapshots of every state were inspected, which is how the duplicated placeholder text
  and the duplicated hint were found — neither shows up in a passing test.
- New localization keys are present in all three tables (`AppStringKeyCoverageTests` enforces it).

### Not done

`EmptyStateView` in `SnippetManagerViewController.swift` is the snippet manager's equivalent
component and is file-private there. The secrets empty state composes the same primitives
(`IconBadgeView`, `makeLabel`, `CapsuleButton`) rather than reusing it, because extracting it
would have edited a file a concurrently running task is already changing. Unifying the two into
one shared component is worth doing once that lands.
