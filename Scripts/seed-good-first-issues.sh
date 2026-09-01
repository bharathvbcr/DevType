#!/usr/bin/env bash
# Seed the contributor-onboarding labels and starter issues on GitHub.
#
# This is a ONE-SHOT MAINTAINER ACTION, not part of the build. It creates public,
# externally-visible content on the repository, so it is **dry-run by default** and does nothing
# until you pass --apply. Read the output of a dry run before applying.
#
# Every issue below is scoped from what the code actually does today (verified against
# Sources/ExpanderEngine/Sync/ and Sources/ExpanderEngine/Macros/ at the time of writing):
#   - Importers exist for TextExpander and Espanso only  (SnippetImporter.SourceKind)
#   - Exporters exist for DevType JSON, Espanso YAML, CSV (SnippetExporter.Format)
#   - Macro transforms cover case/random/uuid/counter      (MacroTransforms.swift)
#   - UI strings ship in en / ko / ja                      (LocalizationManager.swift)
#
# Usage:
#   ./Scripts/seed-good-first-issues.sh              # dry run — prints, creates nothing
#   ./Scripts/seed-good-first-issues.sh --apply      # create labels and issues
#   ./Scripts/seed-good-first-issues.sh --apply --labels-only
set -euo pipefail

REPO="bharathvbcr/DevType"
APPLY=0
LABELS_ONLY=0

for arg in "$@"; do
  case "${arg}" in
    --apply)       APPLY=1 ;;
    --dry-run)     APPLY=0 ;;
    --labels-only) LABELS_ONLY=1 ;;
    -h|--help)     sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "error: unknown argument '${arg}'" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found (brew install gh)" >&2; exit 1; }

if [[ "${APPLY}" == "1" ]]; then
  gh auth status >/dev/null 2>&1 || { echo "error: not logged in — run 'gh auth login'" >&2; exit 1; }
  echo "==> APPLY mode: this will create public labels and issues on ${REPO}"
else
  echo "==> DRY RUN — nothing will be created. Re-run with --apply to act."
fi
echo

# --- labels -----------------------------------------------------------------
# `gh label create --force` is create-or-update, so re-running is safe.
seed_label() {
  local name="$1" color="$2" description="$3"
  if [[ "${APPLY}" == "1" ]]; then
    gh label create "${name}" --repo "${REPO}" --color "${color}" \
       --description "${description}" --force
  else
    echo "  label: ${name}  (#${color})  — ${description}"
  fi
}

echo "==> Labels"
seed_label "good first issue" "7057ff" "Self-contained, well-scoped work — a good place to start"
seed_label "help wanted"      "008672" "Ready to be picked up; maintainer is not actively on it"
seed_label "adapter"          "1d76db" "New speech / correction / AI provider adapter"
seed_label "importer"         "0e8a16" "Snippet import and export formats"
seed_label "macros"           "fbca04" "Template and macro engine"
seed_label "localization"     "c2e0c6" "UI string tables and translations"
seed_label "ui-polish"        "d4c5f9" "Visual and interaction refinement"
echo

if [[ "${LABELS_ONLY}" == "1" ]]; then
  echo "==> --labels-only: skipping issues"
  exit 0
fi

# --- issues -----------------------------------------------------------------
# Idempotent: skips a title that already has an open or closed issue, so re-running after a
# partial failure does not create duplicates on a public tracker.
seed_issue() {
  local title="$1" labels="$2" body="$3"

  if [[ "${APPLY}" == "1" ]]; then
    local existing
    existing="$(gh issue list --repo "${REPO}" --state all --search "\"${title}\" in:title" \
                  --json title,number --jq ".[] | select(.title == \"${title}\") | .number" | head -1)"
    if [[ -n "${existing}" ]]; then
      echo "  skip (exists as #${existing}): ${title}"
      return 0
    fi
    gh issue create --repo "${REPO}" --title "${title}" --label "${labels}" --body "${body}"
  else
    echo "  issue: ${title}"
    echo "         labels: ${labels}"
  fi
}

echo "==> Issues"

seed_issue "Import Alfred snippet collections (.alfredsnippets)" \
"good first issue,help wanted,importer" \
'## Background

DevType imports from TextExpander and Espanso today. The importers live in
`Sources/ExpanderEngine/Sync/`, and every source is registered through
`SnippetImporter.SourceKind` — there is one place to add a case, not a new pipeline to build.

- `Sources/ExpanderEngine/Sync/SnippetImporter.swift` — `SourceKind`, `DetectedSource`, `ImportResult`
- `Sources/ExpanderEngine/Sync/EspansoImporter.swift` — closest existing model to copy from
- `Sources/ExpanderEngine/Sync/TEImporter.swift` — the bundle-parsing example

## The task

Add Alfred as an import source. An `.alfredsnippets` file is a **zip archive** containing one
JSON file per snippet plus an optional `info.plist`. Each snippet JSON looks roughly like:

```json
{ "alfredsnippet": { "snippet": "expanded text", "uid": "...", "name": "Title", "keyword": "trigger" } }
```

Map `keyword` → trigger and `snippet` → replacement. Alfred `{cursor}` should map to DevType''s
`{{cursor}}`; note anything else you cannot map in `ImportResult.notes` rather than dropping it
silently.

## Acceptance criteria

- [ ] `SourceKind.alfred` added and surfaced in the import UI
- [ ] Oversized triggers/replacements go through the existing `Limits.isOversized` check
- [ ] A fixture archive under `Tests/ExpanderEngineTests/Fixtures/` plus tests covering: a normal
      collection, an empty archive, a malformed JSON entry, and a duplicate trigger
- [ ] Containment: an entry path must not escape the extraction directory — see
      `EspansoImportContainmentTests.swift` for the standard this repo holds imports to

## Getting started

`./Scripts/test.sh` runs the suite. See [CONTRIBUTING.md](../blob/main/CONTRIBUTING.md).'

seed_issue "Import Raycast snippet exports (JSON)" \
"good first issue,help wanted,importer" \
'## Background

See `Sources/ExpanderEngine/Sync/SnippetImporter.swift` — sources are registered as cases on
`SnippetImporter.SourceKind`, so this is an additive change alongside the existing TextExpander
and Espanso importers.

## The task

Raycast exports snippets as a flat JSON array:

```json
[ { "name": "Signature", "text": "Best,\nBharath", "keyword": "sig" } ]
```

Map `keyword` → trigger, `text` → replacement, `name` → title. Raycast placeholders such as
`{clipboard}`, `{date}`, and `{cursor}` have direct DevType equivalents (`{{clipboard}}`,
`{{date}}`, `{{cursor}}`) — translate the ones that map cleanly and record the rest in
`ImportResult.notes`.

## Acceptance criteria

- [ ] `SourceKind.raycast` added and surfaced in the import UI
- [ ] Placeholder translation is table-driven, not a chain of string replacements
- [ ] Tests for: a normal export, an empty array, a missing `keyword` field, and an unmapped
      placeholder appearing in the notes
- [ ] Snippets exceeding `Limits` are reported, not silently truncated'

seed_issue "Export the snippet library as a TextExpander CSV / JSON bundle" \
"good first issue,help wanted,importer" \
'## Background

DevType exports to DevType JSON, Espanso YAML, and CSV — see `SnippetExporter.Format` in
`Sources/ExpanderEngine/Sync/SnippetExporter.swift` and the UI side in
`Sources/DevTypeAppCore/LibraryExporter.swift`. Import from TextExpander already works
(`TEImporter.swift`), so the round trip is currently one-way.

## The task

Add a TextExpander-compatible export format so a user can leave DevType as easily as they
arrived. Adding a case to `SnippetExporter.Format` is the whole integration point.

## Acceptance criteria

- [ ] New `Format` case, wired into the existing export UI
- [ ] Mustache macros that have no TextExpander equivalent are reported to the user, never
      emitted as broken literal text
- [ ] **Secret snippets are excluded** — this is a hard invariant: secret values never appear in
      exports. See [SECRETS.md](../blob/main/SECRETS.md) and the existing exporter tests
- [ ] A round-trip test: export a library, re-import it through `TEImporter`, assert triggers and
      replacements survive'

seed_issue "Add regex find/replace transformation to the macro engine" \
"help wanted,macros" \
'## Background

`Sources/ExpanderEngine/Macros/MacroTransforms.swift` implements case transforms, random values,
UUIDs, and persistent counters. There is no regex transform, which is the most common request
from users coming off Espanso.

## The task

Add a regex transform usable inside a template, e.g.:

```
{{regex: {{clipboard}} | s/foo/bar/g }}
```

Exact syntax is open — propose it in the issue before implementing, and keep it consistent with
the existing transform grammar rather than inventing a second one.

## Why this is `help wanted` and not `good first issue`

User-supplied regexes are an untrusted, unbounded input on the expansion hot path. A
catastrophically backtracking pattern would hang the event tap, which is exactly the thing
`CLAUDE.md` and the engine''s design forbid blocking.

## Acceptance criteria

- [ ] Execution is **time-bounded**; a pattern that exceeds the budget fails the transform
      loudly rather than hanging or silently emitting the input unchanged
- [ ] An invalid pattern produces a clear preview error — see `MacroPreview.swift`
- [ ] Tests including a catastrophic-backtracking pattern asserting the bound actually fires,
      plus empty input, no-match, and unicode/grapheme-cluster cases
- [ ] `docs/MACRO_REFERENCE.md` updated'

seed_issue "Extend the date format library with named presets" \
"good first issue,macros" \
'## Background

`Sources/ExpanderEngine/Macros/DateFormatLibrary.swift` backs `{{date:...}}`, with tests in
`Tests/ExpanderEngineTests/DateFormatLibraryTests.swift`. It is a self-contained, pure-function
file — no event tap, no AppKit, no permissions — which makes it a good first change.

## The task

Add named presets so users do not have to remember format strings: `{{date:rfc2822}}`,
`{{date:http}}`, `{{date:week}}` (ISO week number), `{{date:quarter}}`, `{{date:unix}}`.

## Acceptance criteria

- [ ] Presets resolve through the existing lookup rather than a parallel `switch` added elsewhere
- [ ] Offsets keep working with presets (`{{date:rfc2822:+1d}}`)
- [ ] Tests pinning each preset against a **fixed** date — no `Date()` in assertions, or the test
      fails at midnight
- [ ] Locale-independent where the format demands it (RFC 2822 and HTTP dates are English/GMT by
      specification, not by the user''s locale)
- [ ] `docs/MACRO_REFERENCE.md` updated'

seed_issue "Add a new UI language to the string tables" \
"good first issue,help wanted,localization" \
'## Background

DevType ships English, Korean, and Japanese UI strings, all in
`Sources/ExpanderEngine/Localization/LocalizationManager.swift` as in-code tables (no `.lproj`
bundles — the SPM executable cannot rely on `Bundle.module`).

`Tests/ExpanderEngineTests/LocalizationParityTests.swift` enforces that every language covers
every English key **and** that format specifiers match, because handing an `Int` to a `%@` is a
crash in the user''s language that no English-speaking developer will ever see.

## The task

Add a language: German, French, Spanish, Portuguese, Hindi, and Simplified Chinese are all
welcome. Pick one and say so in the issue so two people do not duplicate work.

## Steps

1. Add a case to `AppLanguage` with its endonym
2. Add the table, following the shape of the existing `ko` / `ja` ones
3. Add the language code to `CFBundleLocalizations` in `Resources/Info.plist`
4. Run `./Scripts/test.sh` — the parity test tells you exactly which keys you missed

## One thing the parity test cannot catch

It verifies that specifier *types* match, not their *order*. If an English string reads
`"%@ ahead of %@"` as (current, latest), your translation must pass those two arguments in the
same order even when the target language''s natural word order differs — otherwise the values
appear swapped. Restructure the sentence rather than reordering the placeholders.

## Acceptance criteria

- [ ] `LocalizationParityTests` passes
- [ ] Argument order matches English for every multi-argument string
- [ ] Native or fluent review — machine translation alone is not enough for UI copy'

seed_issue "Preferences: show which snippets a trigger conflict actually involves" \
"help wanted,ui-polish" \
'## Background

DevType detects trigger conflicts (`SnippetStore.isConflictDetectionEnabled`, surfaced through
`Sources/DevTypeAppCore/LibraryHealth.swift` and `SnippetConflictResolverSheet.swift`). The
underlying detection already knows which snippets collide.

## The task

Make the conflict presentation actionable: show the conflicting snippets side by side with their
groups, and let the user jump straight to either one instead of searching the library manually.

## Acceptance criteria

- [ ] Reuses the existing conflict data — no second detection path (see `CLAUDE.md`: one
      canonical owner per behavior)
- [ ] All AppKit work on `@MainActor`
- [ ] Accessibility: the pairing is announced as one labelled unit, matching how
      `dtApplyAccessibility` is used elsewhere in the app
- [ ] Behaves correctly with a three-way conflict, not just a pair

## Before you start

Post a screenshot or sketch on the issue — this is a design change, and agreeing the shape first
avoids a rewrite in review.'

echo
if [[ "${APPLY}" == "1" ]]; then
  echo "==> Done. Review at https://github.com/${REPO}/issues"
else
  echo "==> Dry run complete. Nothing was created."
  echo "    Re-run with --apply once the wording above looks right."
fi
