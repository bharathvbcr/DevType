# Documentation accuracy audit — 2026-10-02

Scope: the documentation and landing-page changes made on 2026-10-02 (Recent Activity, AI
cancellation and system deferrals, refusal classification, Reliability section, FAQ), plus a drift
check of shortcuts, platform requirements, defaults and links in `README.md`, `docs/`, and
`docs/index.html`. Baseline: `381679e`, with the 2026-10-02 documentation edits uncommitted.

Method: each claim was compared with the source named below. `devmap` was not installed in the
shell used, so checks were `grep` and file reads. Nothing was built, run, or tested, and the
rendered page was not viewed in a browser.

## Verified

- **AI cancellation:** `AITransformDiscardHandle.discard()` and `settled()` exist; the preview panel
  tags requests with a generation token and `isCurrent` rejects stale ones.
- **Blank preview result:** `AIPreviewPanel.normalized` turns a whitespace-only success into
  `.decodingFailure`.
- **Refusal kinds:** `warrantsEngineRestart` is true only for `.unknown`.
- **Recent Activity:** Return/Enter, Delete/forward-delete and Escape are handled; the window is
  `.miniaturizable`; Clear History is disabled when history is empty and healthy and asks for
  confirmation otherwise; action and category lists match `ActivityHistoryStore`.
- **ErrorGraph:** default caps are depth 8 and 64 nodes; non-framework domains are salted
  fingerprints in `DevTypeLog.errorMetadata`.
- **Drift check:** macOS 14 deployment target; menu shortcuts `⌘,`, `⌘⇧M`, `⌘⇧P`; seven Preferences
  tabs; automatic update check is opt-in; secret clipboard clears after 90 s; secret submenu limit
  is 20. All relative links, local asset references and `blob/main` links in the site resolve.

## Findings and fixes

1. **Over-claim: Unicode paste fallback scope.** The landing page and FAQ said the fallback applies to
   "Cursor, VS Code, and other Electron editors". `swallowsSyntheticPaste` matches only Cursor's
   exact bundle ID and the VS Code, Insiders and OSS prefixes. Copy now names those editors and
   says other Chromium/Electron apps use normal paste. `ARCHITECTURE.md` now documents the exact
   match rule.
2. **Unverified claim removed earlier the same day:** "deferrals are not counted in AI
   diagnostics". `deferredBySystem` is recorded under its own label; cancelled requests are
   classified `.discarded` and not recorded as failures. The user guide now says that.

## Not verified

- Default global shortcut values (`⌘/`, `⌘⌥A`, `⌘⌥V`): their definition was not located in the
  files searched. The values are unchanged from the existing README and guides.
- Whether a published release contains the 1.2.0 fixes; `docs/releases/v1.2.0.md` describes them,
  and GitHub Releases determines availability.
- Landing-page rendering at desktop and mobile widths, and with JavaScript disabled.
- `UNWIRED_INVENTORY.md` still describes `FillInBuilder` as exercised only by tests; it is a dated
  historical analysis and was left as is.
