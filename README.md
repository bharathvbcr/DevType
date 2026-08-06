# DevType

Native macOS text expander (menu-bar / `LSUIElement` accessory app). Use a proper `.app` bundle so TCC grants stick to a stable identity (`com.devtype.app`) instead of a bare SPM Mach-O that churns on every rebuild.

Instant expand-on-match is intentional: when the ring buffer’s suffix matches a trigger, the final key is swallowed and the snippet is injected (AX range replace, then clipboard paste fallback when Post Events is granted).

## Build & run

```bash
# One-time: stable signing identity so TCC grants survive rebuilds
./Scripts/make-signing-cert.sh

# Debug binary only
swift build

# App bundle → .build/DevType.app  (dev package)
./Scripts/package-app.sh          # debug (default)
./Scripts/package-app.sh release  # release
# Scripts/build_app.sh is a thin wrapper around package-app.sh

# Install to Applications (preferred for TCC + Open at Login + Launchpad)
./Scripts/install-app.sh          # quits other copies → /Applications/DevType.app (or ~/Applications)
open /Applications/DevType.app

# Tests (sets DEVELOPER_DIR to Xcode.app when unset)
./Scripts/test.sh
```

Requires Xcode (or a full toolchain). `./Scripts/test.sh` prefers `/Applications/Xcode.app/Contents/Developer` when `DEVELOPER_DIR` is unset (CLT-only `xcode-select` breaks `swift test`).

### One identity (important)

**Daily driver:** `/Applications/DevType.app` via `./Scripts/install-app.sh`. That script quits other DevType processes, installs atomically, quarantines stale `build/DevType.app` / `*.stale` leftovers, and **moves `.build/DevType.app` aside** after install so TCC / Launchpad see a single driver. Prefer one identity — Launchpad uses the Applications icon (`CFBundleIconFile` = `AppIcon`).

```bash
./Scripts/install-app.sh
pkill -x DevType || true
open /Applications/DevType.app
```

Re-run `./Scripts/package-app.sh` when you need a fresh `.build/DevType.app` for iteration. Do not leave both Applications and `.build` copies running — Recovery/Setup warn when both exist on disk. Grant capabilities only for `com.devtype.app` on the Applications path.

### Signing identity (why grants used to reset)

TCC stores the bundle's **designated requirement**, so what that requirement pins to decides whether grants survive a rebuild:

| Signing | Designated requirement | Grants after rebuild |
|---|---|---|
| Ad-hoc (`codesign --sign -`) | `cdhash H"…"` | Reset — every binary change is a new CDHash |
| `DevType Local Signing` cert | `identifier "com.devtype.app" and certificate root = H"…"` | Persist — cert is stable |

Run `./Scripts/make-signing-cert.sh` once. It generates a self-signed `codeSigning` certificate in the login keychain and is idempotent; `package-app.sh` then picks it up automatically (override the name with `DEVTYPE_SIGN_IDENTITY`) and falls back to ad-hoc with a warning when it is missing. `package-app.sh` prints the requirement on every run, so a CDHash-pinned bundle is obvious. No trust settings or `sudo` are needed — codesign only needs the private key, and `security find-identity -p codesigning` reporting *0 valid identities* for an untrusted self-signed root is expected and harmless.

The first install after switching identity changes the CDHash one last time, so clear stale records once with `./Scripts/reset-tcc.sh`. Developer ID + notarization remains the path for distribution.

**Symptom of a stale record:** a Settings toggle is ON but the app still preflights denied, no prompt appears on **Request**, and `log show --predicate 'process == "tccd"'` shows *no* request for the service at all — the stored row still authorizes the previous CDHash. `./Scripts/reset-tcc.sh` clears it (`tccutil reset ListenEvent|Accessibility|PostEvent com.devtype.app`), then grant again.

**Active taps need Accessibility.** `defaultTap` (the swallowing tap) cannot be created while Accessibility is denied, even when Input Monitoring reads granted — only listen-only taps get by on Input Monitoring alone. Missing Listen or AX is **Needs Permissions**; Tap Failed is reserved for Listen+AX granted but `tapCreate` still nil.

## Capability matrix (TCC)

DevType splits three capabilities. A swallowing **`defaultTap` needs Input Monitoring and Accessibility**. Post Events is inject-only; missing it degrades HID paste / cursor and does not tear down a running tap.

| Capability | TCC service | Check | Request | Runtime role |
|---|---|---|---|---|
| `canListenTap` | ListenEvent → **Input Monitoring** | `CGPreflightListenEventAccess` | `CGRequestListenEventAccess` + short `.listenOnly` probe | Required for event tap |
| `canUseAX` | Accessibility | `AXIsProcessTrustedWithOptions(false)` | `AXIsProcessTrustedWithOptions(true)` | Required for `.defaultTap` + AX inject (**fail-closed** if false) |
| `canPostEvents` | PostEvent (UI may sit under Accessibility) | `CGPreflightPostEventAccess` | `CGRequestPostEventAccess` | HID backspace / ⌘V / arrow cursor |

Missing Listen or AX is **Needs Permissions** (not Tap Failed). Tap Failed is reserved for Listen+AX granted but `tapCreate` still returning nil (duplicate process / stale TCC identity).

Deep links (macOS 13+/27): `Privacy_ListenEvent` / `Privacy_Accessibility`. **No** `Privacy_PostEvent` pane. **No IOHID** for permission registration (CG only).

### Request then Open (not auto-Settings)

1. Click **Request** — DevType temporarily activates as a regular app, presents the macOS TCC prompt, and (for Input Monitoring) may run a short listen-only registration probe.
2. Answer the system prompt.
3. Click **Open Settings** only if still denied / not listed — Open is explicit and never auto-fires after Request (avoids racing the Allow sheet).

On first launch, the **Setup** wizard walks Welcome → Input Monitoring → Accessibility+Post → Verify/Relaunch → Done. Recovery is always available via **Permission Recovery** (`⌘⇧P`).

**TCC grants stick across launches** for the same packaged app when signed with `DevType Local Signing`. They **reset** under ad-hoc resign (new CDHash). Cosmetic-only resource changes do **not** force resign. Prefer **`/Applications/DevType.app`** (`./Scripts/install-app.sh`). Use `.build/DevType.app` only while iterating. Do not run the raw `.build/.../DevType` Mach-O or a stale `build/` copy. `install-app.sh` auto-resets TCC when the designated requirement changes (e.g. first switch from ad-hoc to cert). Onboarding identity tracking keys off path + designated requirement (not CDHash alone), so cert-signed rebuilds no longer force Permission Recovery.

Setup can **Finish when Accessibility is granted** (CDHash load finished). **Post Events** is optional (degraded AX-only inject, including multi-line + AX caret in non-shell apps). **Input Monitoring + Accessibility + a running tap** are required for menu **Active** / live swallowing expand; incomplete Listen/AX/tap is warned in Setup and recoverable via Permission Recovery. Post remains recommended for terminals / HID paste / HID cursor fallback. While Setup is open, DevType uses a temporary `.regular` activation policy so TCC prompts work reliably, then restores menu-bar `.accessory` when Setup closes.

## Smoke checklist

1. `./Scripts/install-app.sh` (packages + copies + quarantines `.build` dual identity), quit all DevType processes, then `open /Applications/DevType.app`.
2. Complete Setup (or open Permission Recovery `⌘⇧P`) and grant capabilities for `com.devtype.app`. Finish stays disabled while **Accessibility** is Denied (or CDHash is still loading) — that is not a persistence bug. Listen/tap incomplete does not block Finish.
3. Confirm menu status shows **Active** when Listen + Accessibility are granted and the tap is running (Post missing shows degraded tooltips, not a forced stop). Missing AX is Needs Permissions, not Tap Failed.
4. In Setup Done or Permission Recovery, click **Test Expansion** — opens an in-app **NSTextView inject lab** and runs a real inject (not a plan-only alert). Lab success ≠ Notes/Chrome live expand.
5. In TextEdit or Notes, type `:test` (or another saved trigger) and confirm live expansion. Hard apps (Chrome / Slack / Electron) may need the HID paste path — see Notes below.

## Menu extras

- **Open at Login** — `SMAppService` login item (packaged `.app` only)
- **Mute Frontmost App** / **Muted Apps…** — per-app expansion denylist
- **Manage Snippets…** — add / edit (double-click, multi-line replacement editor) / delete with confirm; case & word-boundary toggles; case-insensitive duplicate triggers blocked when matching is case-insensitive
- **Permission Recovery…** (`⌘⇧P`) — identity, capabilities, inject/tap health, Request / Open / Relaunch / Test Expansion (lab inject) / **Copy Logs** (clipboard diagnostic + selectable OSLog preview)
- **Diagnose Secure Input** — reports lock on/off; on macOS 27+ the holder is unknown (frontmost PID is context only, not the Secure Input owner)

## Snippet templates (dual macro syntax)

DevType keeps mustache `{{…}}` and adds TextExpander-compatible `%…%`. `MacroRenderer` expands TE first (nested snippets, fill-ins, `%clipboard` / `%date:` / `%|` / `%key:`), then remaining mustache via `DynamicTemplateEngine`.

### Mustache (`{{…}}`)

| Tag | Meaning |
|---|---|
| `{{date}}` / `{{date:yyyy-MM-dd}}` / `{{date:us}}` | Current date — raw pattern or named preset |
| `{{time}}` | Current time |
| `{{clipboard}}` | Current pasteboard string — read only when this tag is present (privacy: no always-on pasteboard scrape; advanced — not used in default `:hello`) |
| `{{calc: 1+2}}` | Safe arithmetic |
| `{{cursor}}` | Post-expand caret position (AX caret when possible; HID arrows need Post Events) |
| `{{snippet:trigger}}` | Nested snippet (depth &lt; 10) |

### TextExpander (`%…%`)

| Tag | Meaning |
|---|---|
| `%filltext:name=X%` / `%fillarea:` / `%fillpopup:` / `%fillpart:` | Fill-in panel before expand |
| `%snippet:ABBREV%` | Nested snippet (depth &lt; 10) |
| `%clipboard` | Pasteboard (no trailing `%` — TE quirk) |
| `%date:FORMAT%` | `DateFormatter` pattern **or named preset** (`%date:us%`, `%date:full%`, …) |
| `%\|` | Cursor marker |
| `%key:enter%` / `%key:tab%` | Trailing key after inject |

Unknown `%xx` sequences (URL encoding) stay literal. Mustache is never parsed as TE.

### Date presets

`DateFormatLibrary` presets work in both `%date:NAME%` and `{{date:NAME}}`, with live examples in the editor's Insert Macro → Date / Time submenu:

| Preset | Output (en_US) |
|---|---|
| `us` | 08/02/2026 |
| `uslong` | August 2, 2026 |
| `iso` | 2026-08-02 |
| `eu` | 02/08/2026 |
| `full` / `long` / `medium` / `short` | Locale date styles |
| `datetime` | Aug 2, 2026 at 3:04 PM |
| `time` / `timeshort` / `time24` | Clock formats |
| `weekday` / `monthyear` / `day` / `year` | Single components |

Any spec that isn't a preset name is treated as a raw `DateFormatter` pattern (unchanged behavior).

### Image snippets

A snippet can paste an image instead of text: attach one in the editor (photo button beside Insert Macro) or import Espanso `image_path` matches. Images are copied into `ImageAttachmentStore` (`~/Library/Application Support/DevType/Images`), referenced by `SnippetModel.imagePath`, and expanded via clipboard image paste (HID backspaces + ⌘V — requires Post Events).

## Matching & layout

- **Punctuation-leading triggers** (`;sig`, `:eml`) expand immediately.
- **Bare-word triggers** (`sig`) need a non-word terminator (space/punct/Return/Tab) unless `requireWordBoundary` is false.
- Return/Tab may **terminate + swallow** (DevType `defaultTap`); Escape/arrows still clear the buffer.
- Under **2-Set Korean** only, physical QWERTY matching runs via `LayoutBuffer` + `HangulComposer` (3-Set disabled).
- HID paste uses **physical ⌘V** (Command down/up); AX range replace never posts ⌘V.

## Search, import, sync

- **Inline search** — `⌘/` palette with sigil-stripped ranking (`SnippetSearch`)
- **Import Snippets…** — one unified picker (`SnippetImporter`) that auto-detects the format: TextExpander 4/5 group XML (`TEImporter`, plain text only) or Espanso config/match/package/YAML (`EspansoImporter`; trigger/replace, `$|$` → `{{cursor}}`, `image_path` → image snippets; dynamic vars, forms, HTML/markdown, regex skipped)
- **Schema v2** — `{ schemaVersion, groups }` with v1 → default “General” group migrate (no wipe); Save As / Link / Don’t Sync + directory watchers

See root `NOTICE` for SnipKey Kit (MIT) attribution.

## Notes

- Expansions are **refused** when Accessibility is unavailable (fail-closed — never treat a nil focused element as a safe password/IME check).
- Expansions are also muted in secure text fields, while Secure Event Input is locked, during IME composition, and in muted apps.
- Secure Input holder PID attribution is unavailable on macOS 27+ — Diagnose reports **unknown holder**. Frontmost app/PID shown for context is **not** the Secure Input lock owner.
- **Hard-app matrix (brief):** Chrome, Slack, Messages, and many Electron apps expose weak/missing AX focus or selected-text. With Post Events granted and Secure Input off, missing AX focus allows HID expand (not IDE-only). Known weak selected-text apps prefer HID paste over AX range replace; AX sets are value-verified before trusting success. Always verify live expand in the target app — the inject lab only proves the pipeline against DevType’s own NSTextView.
- Snippet data lives at `~/Library/Application Support/DevType/snippets.json` as a versioned `{ schemaVersion, groups }` envelope (v1 `{ snippets }` and legacy bare arrays still load; corrupt files are backed up to `.bak`).
- **Swallow contract:** the trigger key is swallowed only after sync-safe planner allow. Async refuse (password / IME / IDE-shell / inject-time) reinjects the swallowed key (HID post when available, else AX insert). Holding a key (autorepeat) does not append or match.
- **AX-only (Finish without Post):** multi-line and `{{cursor}}` use AX selected-text replace + AX caret in non-shell apps. Terminals / bracket-paste still need Post Events.
- **Clipboard:** `NSPasteboard` is read only when a snippet template contains `{{clipboard}}`.
- **Inject honesty:** `CGEvent.post` success is not delivery proof; settle delays before ⌘V / arrows are fixed heuristics. Chrome / Slack / Electron often expose weak AX selected-text — expect AX-only failure → refuse (or HID paste when Post is granted).
- AX messaging timeout is ~50ms on system-wide / focused elements so hung apps cannot stall gates or inject.
