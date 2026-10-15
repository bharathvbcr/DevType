# Changelog

Curated notes for each tag live in `docs/releases/<tag>.md`. The publisher reads that file. This changelog matches it. Older tags are linked, not copied.

## [1.3.0]

**DevType 1.3.0 — Image snippets, library restore, and a stricter preview**

The GitHub artifact follows the project's existing ad-hoc signed, unnotarized distribution policy. Gatekeeper may reject it. Notarization stays off (9c73c04). Local packages use the available Apple Development identity.

These notes cover unpublished 1.2.1 and the work after it. The 1.2.1 tag exists on this clone and was not pushed to origin; its commit is already on the published branch. The original write-up remains in `docs/releases/v1.2.1.md`.

### Highlights

- **Image snippets keep their file bytes.** Expanding a stored PNG, JPEG, GIF, or TIFF publishes that file's own bytes under one native pasteboard type, within the import cap. Animated GIF is no longer flattened by re-encoding. bmp, webp, heic, unknown extensions, and unreadable or over-cap files still fall back to TIFF+PNG. Copy is unchanged (3e073cd).
- **Espanso image export round-trips.** A directory export writes `images/<safe name>` beside the match files with a relative path, and fails closed when the attachment is missing or leaves the store (6f4f1e9).
- **Restore from Backup.** Snippet saves keep the 20 newest library copies plus the newest per day for 30 days. Replace with Defaults, Restore from Backup, Save As / Move Library, and Stop Syncing write a safety backup first and fail closed when that backup cannot be written. Preferences → Snippets gains Restore from Backup…, with the date, snippet count, and trigger kind (a101f73).
- **`devtype://` opens a closed set of screens.** The allowlist is new, palette, preferences, dictation/toggle, and copy. Those URLs do not expand text and do not read a secret. The macro catalog used by the palette now lives in the engine (7f8ed1e).
- **Preview can format a table and show a word diff.** A bounded column-and-row result becomes Markdown. `toTable` is available to the local transform and the palette. Every transform kind uses one grapheme-safe word diff (7a434d0).

### Match Trigger Case (sig / Sig / SIG)

- **New snippet option:** case-insensitive snippets gain a **Match Trigger Case** switch in the editor (shown only while Case Sensitive is off). Typing the trigger Capitalized or in ALL CAPS shapes the expansion the same way (6ad2094).
- **Espanso-compatible shape rules:** only the first two letters of the typed trigger are read and non-letters are skipped. Upper+Upper or a lone capital means ALL CAPS, Upper+lower means first letter upper, and anything that starts lowercase (including mixed `sIG`) or has no letter stays as written.
- **Narrower than Espanso, on purpose:** only text written in the snippet template is reshaped. Fill-in values, clipboard text, dates and generated values keep their own case, as do spans an explicit `{{upper:…}}`-style transform already shaped. Cursor markers are remapped when uppercasing changes length (`ß` → `SS`).
- **Importer:** Espanso `propagate_case` matches now import with the option on. The old "output case adaptation is unavailable" note is gone; a new note counts matches that use `uppercase_style: capitalize | capitalize_words`, which DevType imports with the default case shapes.

### Selection reads no longer block the main thread

- **No beachball on AI hotkey, palette, or voice command:** selection reads run on a dedicated serial queue and hand their result back on main (e77b5bf).
- **Latest press wins:** the AI hotkey, palette AI actions, and the inline search panel only act on the most recent press. A second palette press while the first is still reading closes it instead of queueing a second panel, and a stale read cannot raise a stale alert.
- **AX retries never sleep on main:** focus-query retries and the Chromium accessibility rescue use one bounded policy (`AXSettleRetry`) that waits only off main and reports when a poll was skipped rather than passing it off as zero polls (c7e1400).
- **One focused element per expansion:** an expansion resolves the focused element once and threads it through the entry re-check, IME probe, erase guard, AX writes, delivery check, caret placement and trigger restore. No collaborator inside an inject queries focus through a default argument (68d4412).

### Local Lappi routing (opt-in, off by default)

- **Ask Lappi which tool fits:** when on-device palette routing runs, DevType can also ask a local Lappi agent over a Unix socket on this Mac (300 ms limit). An answer only annotates the routed row as agreeing or differing; it never inserts text or runs anything (24cc8d8).
- **Local routing records:** optionally records which tool routing chose and which row you picked, to `Application Support/Lappi/heldout` — the phrase's length and shape, never its text. Records are bounded per day and in total, stay on this Mac, and are never used for training. `LAPPI_COLLECT=0` disables collection.
- Nothing is sent or written while secure input is on. Both switches live in Preferences → AI and default off.

### UI strings move to resource tables

- English, Korean and Japanese UI strings ship as `.strings` resource tables (`Sources/ExpanderEngine/Localization/Resources/<lang>.lproj/`, eight tables per language) instead of Swift dictionary literals (3c50ecd).
- The user-chosen UI language still wins over the system language. Malformed tables, missing languages and keys defined twice are reported at load.
- **Pseudolocale for layout checks:** `DEVTYPE_PSEUDOLOCALE=1` (or `-devtype.debug.pseudolocale YES`) accents, brackets and pads every string by about 40%, keeping format specifiers intact.

### Engine internals

- Text injection's undo policy, route choice, entry-gate refusals, swallowed-key and completion-guard types, the image-snippet path and text resolution each have their own owner. The inject/undo ledger owns its single lock (93a21d1).

### Fixes

- **Accessibility trees that time out get one more probe.** A cold Chromium launch often answers `.cannotComplete` inside the 50 ms write. DevType probes once more after the cooldown with the longer retry budget, and that follow-up does not schedule another (a8e00b9).
- **A refusal no longer sticks in the preview.** A streamed snapshot that already matches refusal prose is not published. A refusal failure clears insertable text and disables Replace, Copy, and Replace-and-Copy. Other failures keep a useful partial (6cc33d5). Partials and completions are applied on the main queue in call order, so a partial published just before completion still reaches the text view (f0488d8).
- **The update alert's Close button ends the modal** even when it runs before AppKit publishes `NSApp.modalWindow` (c77485c).
- **Secrets archive transactions wait with `sync`.** The body runs before the lease call returns, and it stays non-escaping. The main thread still refuses a busy lock without waiting. This does not widen who can read or write a secret (883fde5, 87f2303). A stalled clock does not take the lock (7f5c622).
- **An unclean exit is recorded** when the launch sentinel file is still there on the next launch (e628dd6). Crash-report thread indexes 0 and 1 are both read (7832f28).
- **Voice.** The link detector does not run on a transcript that cannot contain a link (79eb049). Protected-span extraction is bounded so a repeated-letter transcript cannot stall ICU (0376972), matches case-folded email letters without an overlap walk that does not stop (174640c), and skips duplicate dictionary terms (84c856e). Microphone buffers are copied before the tap reuses them (cd7eff5). A spawned whisper-server is probed on 127.0.0.1, and stop returns without sleeping out the SIGTERM grace (ad5396c). A dead child is not reported ready (442a65d), and a hung probe is cancelled (a487676). Gemini redirects are refused and a failed FLAC scratch file is removed (575548a).
- **Palette and correction.** A phrase neither date parser accepts does not insert today, and an unknown text-op id does not echo the input (9543de0). Macro ids match only after ASCII case-fold (cf43023). A local model that stops because it hit its length cap is not inserted (61d4350).
- **Selection and paste.** An oversized Accessibility selection is released and refused as too large (719f70d). Unrestorable pasteboard representations are not materialized (a839525). The windowed paste-hold count is trusted only for hosts that count UTF-16 (da22479).
- **Libraries.** An unreadable library stays in place until an overwrite commits (2af88a8, 0e0f561). Saves are refused while an unreadable settings file could not be quarantined (ee8b9cc). Undecodable persisted data is preserved and the failure is surfaced (94e8af0). Export destinations are checked, and a failed restore can be recovered (c3a4a15). A stale language resolution is not published (6fa1337).
- **Windows.** `makeKeyAndOrderFront` and `orderFrontRegardless` go through an Objective-C `@try`, so a leftover remote-view exception does not abort the process. The toast and the voice HUD still do not become key (a9df1a2).
- **Lappi.** A socket that is not mode 0600, not our uid, or not a socket is refused before any request bytes are written (94fedc6, e488aae).

### Hardening

- **A packaged bundle that still says 0.1.7 (build 2) fails CI.** That pair is the source `Info.plist` placeholder. The old gate looked for 1.0.0 / 1, which this repository does not stamp. Git-describe builds, including `+dirty`, still pass (9915186).
- **A release whose public download does not match the built DMG is put back into draft.** `/releases/latest` does not keep offering it. Replacing an already-public release with `DEVTYPE_ALLOW_REPUBLISH=1` does not re-draft that release (9652c98).
- **GitHub Actions are pinned to the current v4 commits, checkout does not persist credentials, and only the publish job has `contents: write`** (9c73c04).
- **The local Lappi socket and the secret archive lock stay narrow.** See the fixes above. Performance work caches hot-path scans, palette queries, voice transcripts, and the streaming HUD, and moves notification-driven Accessibility reads off the main thread (1418067, 90db0a7, 6cf3b8c, 6d84383, 1f5d176, 01d639d). The benchmark self-test uses an injected clock, so a slow scheduler cannot pass or fail the min-of-N rule (07a6b6e).

### Breaking changes

- A library that already opens is unchanged, and there is no settings migration. 1.2.1 adds no dependency, cloud service, permission grant, secret migration, or authentication change.
- A corrupt typed-path allowlist now denies every app. It used to decode as an empty list, which meant every app (8951428).
- An undecodable or newer-schema timing or capability file is moved aside and kept, rather than overwritten (8951428).

### Known issues

- The published DMG is ad-hoc signed and not notarized. Gatekeeper may reject it (9c73c04). Developer ID signing is an open maintainer decision.
- The version string on an untagged build is still `git describe`, not 1.3.0. The bundle says 1.3.0 only when this commit is tagged `v1.3.0` on a clean tree.

## [1.2.1]

See [docs/releases/v1.2.1.md](docs/releases/v1.2.1.md).

## [1.2.0]

See [docs/releases/v1.2.0.md](docs/releases/v1.2.0.md).

## [1.1.0]

See [docs/releases/v1.1.0.md](docs/releases/v1.1.0.md).
