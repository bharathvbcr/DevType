# DevType v1.3.0 release report

PUSH is still no. Nothing was pushed, and the GitHub Release was not published. A local annotated tag `v1.3.0` exists and is moved onto the commit that contains this paragraph before that tag is pushed. `main` is 95 commits ahead of `origin/main` (`31773e8eb4416d2fc486a86631c6f98f6f16ccfe`) once this paragraph is committed.

`./ci:local` passed on `a62df2f1a186fdbc3507f19b33ea04fdebf305f4`. The commits after that are documentation. They were not followed by another `./ci:local`. `BRANCH_REPORT.md` and this file were committed in `187d160`.

The four release-pipeline auditors were read-only code-reader subagents. This session cannot pin Sonnet, Opus, or Fable. Findings were checked against the files before anything was changed.

## Commits made

| Commit | Subject |
| --- | --- |
| `a8e00b9` | fix(accessibility): retry one AXManualAccessibility timeout |
| `c77485c` | fix(ui): stop the update alert when Close runs before modalWindow is set |
| `f0488d8` | fix(ai): publish preview partials on the main queue in call order |
| `07a6b6e` | test(bench): prove min-of-N ignores warmup with an injected clock |
| `9652c98` | fix(release): return a release to draft when the public download check fails |
| `9915186` | fix(ci): reject a bundle that still has the source version |
| `9c73c04` | ci: pin actions and narrow the release token |
| `a62df2f` | docs(release): add v1.3.0 notes and a changelog |
| `187d160` | docs: record the branch and v1.3.0 release reports |
| `f3511a4` | docs(release): include unpublished 1.2.1 notes in 1.3.0 |

The refresh at `e440b44` followed `f3511a4`. This commit is the compiler fix described below, and the local tag `v1.3.0` is moved onto it before it is pushed. It has not been pushed. An earlier local tag object on `187d160` was deleted before `f3511a4` was tagged. Neither object was pushed.

No GitPulse task id is in those messages. The accessibility, alert, preview, and benchmark follow-ups are not named by a board card. `9c73c04` is the release-free workflow commit: it does not change the app.

`v1.2.1` (`c1b0a7ff7b87d3a6194d8140b2cfccb20098a33a`) is an ancestor of `v1.3.0`. Its commit is on `origin/main`. The `v1.2.1` tag ref is not on origin. `v1.3.0` is not on origin. `git log v1.3.0..v1.2.1` is empty, so there is no 1.2.1 commit left to merge. The 1.2.1 notes were copied into `docs/releases/v1.3.0.md` because 1.2.1 was never published. Two figures from `docs/releases/v1.2.1.md` were left out: `LocalizationManager.swift` is 287 lines, and `TextInjectionPipeline.swift` is 1,951.

## ci:local

`./ci:local` on `a62df2f`, exit 0, 653.57 s. Log: `tmp/ci-local-v130.log`.

Toolchain this machine reported: Swift 6.4 (`swiftlang-6.4.0.34.1`), Xcode 27.0 build `27A266a`. That is not a pin, and the release notes do not claim it.

SwiftPM tests, all three bundles, zero failures:

| Bundle | Executed | Skipped | Failures |
| --- | --- | --- | --- |
| ExpanderEngineTests | 3628 | 21 | 0 |
| DevTypeSafetyOrderFrontTests | 3 | 0 | 0 |
| DevTypeAppTests | 569 | 2 | 0 |
| Total | 4200 | 23 | 0 |

Publication fixtures inside the same run: `test-release-publication.py` 24 tests, `test-stress-productivity.py` 7 tests, and the shell fixture scripts (signing identity 11, install-app 15, release signing preflight 9, DMG select 8, asset list 7, version match 5, stamped version 9, preflight 9, capabilities 8, LCOV 18). All passed.

The packaged bundle in that run is `com.devtype.app`, executable `DevType`, and `Contents/MacOS` contains only `DevType`. Stamped version `1.2.1-132-ga62df2f` (build 367). The source placeholder `0.1.7` / `2` was rejected by the new check; this stamp passed.

Not run, and announced rather than passed:

- Step 2b, the release benchmark gate. `DEVTYPE_BENCH` was unset. `AuditBenchmarkTests` recorded 10 skips inside the debug suite for the same reason. The gate is `DEVTYPE_BENCH=1 ./ci:local`.
- Foundation Models linkage. `DEVTYPE_REQUIRE_FOUNDATION_MODELS` was unset. The tagged release workflow sets it.

This full suite was run once, on `a62df2f`, after the product and CI commits through that commit. The stamp script (9 tests) and the publication script (24 tests) had already passed on the uncommitted pipeline edits. There was not a separate full `ci:local` between `9652c98`, `9915186`, and `9c73c04`. The docs commits after `a62df2f` did not re-run it.

DevMap could not name callers for the reliability edits. `devmap_status` generation 613 had `source_freshness` true and `analyzer_freshness` false (`stored extraction payload is obsolete`). `devmap_affected_tests` failed closed with all three targets unmatched. The gap is `release-v1.3.0-reliability-blast`. Call sites were then read from the tree: `BenchmarkGate.measure` has one call, in its self-test, and the full suite compiled the other `BenchmarkGate` callers.

## Release pipeline

### Fixed

- A bundle that still has the source `Info.plist` pair `0.1.7` / `2` fails local CI and the hosted package job. The old guard looked for `1.0.0` / `1`. `9915186`.
- If the download after undraft does not match the built DMG, `publish-release.sh` puts the release back into draft. `/releases/latest` does not keep offering it. `9652c98`, covered by `test_public_verification_failure_returns_the_release_to_draft`. If the re-draft itself fails, the command still fails and the release stays public.
- `actions/checkout`, `actions/cache`, and `actions/upload-artifact` are pinned to the v4 commits resolved on 2026-10-15. Every checkout sets `persist-credentials: false`. Workflow `contents` is read, and only the publish job has `contents: write`. `9c73c04`. The repository is public, so `git ls-remote` in the publisher does not need the checkout token.
- The update alert Close path, preview main-queue order, benchmark clock, and one AXManualAccessibility retry. See the commits above.
- Hosted CI does not use this machine's Swift 6.4. Run 38434325302 (2026-10-13, `origin/main`) failed to compile: Swift 5.10 / Xcode 15.4 on `macos-14` could not type-check the backup retention tables in `LibraryBackupStoreTests`, and Swift 6.3.3 / Xcode 26.6 on `macos-26` rejected `LappiFakeAgent.init` because the bind closure captured a `listener` local declared later in that initializer. Local `./ci:local` on Swift 6.4 did not report either diagnostic. The tables are now separate expressions, and the accepted socket fd is `boundListener`, so those two runner compilers can build the tag.

The release job does not run a remote install script. `seed-good-first-issues.sh` mentions `brew install gh` and is not a release step. Notarization was not turned on.

### Filed

`ft-9291b0fa7c3466737d650505144a527e` (`release-v130-pipeline-decisions`, inbox). It asks for a decision on:

- an SBOM, and whether a checksum file becomes a release asset (the asset list rejects `checksums.txt` today; `shasum -a 256` is a log line)
- pinning Xcode on the macOS 14 and macOS 26 runners
- a yank procedure (deleting the git tag does not stop `/releases/latest`)
- whether to push the local `v1.2.1` tag by itself
- keeping the matrix as one macOS app

### Needing a decision

Already on `ft-3ca735f221ea890cbd7b033c1a8595af` (inbox, revision 2). That card does not settle push order. It still owns:

- Developer ID signing and notarization. `release.yml` still sets `DEVTYPE_SKIP_NOTARIZE`, `DEVTYPE_ALLOW_UNTRUSTED_RELEASE`, and `DEVTYPE_SKIP_AUTO_CERT`.
- Homebrew tap `bharathvbcr/homebrew-devtype` (the tap does not exist).
- Discussions and starter issues. Dead links in `SUPPORT.md` and `CONTRIBUTING.md` are inside this card.
- Shell output, regex triggers, nested snippets, and `{{shortcut:Name}}`: build, or document as a non-goal.
- A release-notes toolchain line and back-fill of v0.1.9 through v1.2.0. These notes omit the line. Local Xcode 27.0 is this machine, not a release log.
- Docs drift: `UNWIRED_INVENTORY`, the Fun-ASR dictionary entry, landing-page checks.

`ft-aa3086e6` is not on the board (`gitpulse_get_task` returned `not_found`) and it is not in the repository markdown.

Push order for this task, from the request itself: when you say yes, push `main`, then push only `v1.3.0`. Never `--tags`. Never force. The unpublished local tag was moved onto `f3511a4`, then onto this report. Do not move `v1.3.0` after it has been pushed.

`DEVTYPE_ALLOW_REPUBLISH=1` still replaces a public release in place and does not re-draft it. That path is unchanged on purpose.

There is no Windows or Linux bundle and no hook or MCP binary. The packaged app contains `DevType` only. Whisper is an external loopback server.

Clients learn about an update from `GET /repos/bharathvbcr/DevType/releases/latest`. A draft is not that endpoint. The app does not download the DMG and does not check a checksum. It opens the GitHub release page.

## Release notes

Publisher body: `docs/releases/v1.3.0.md` at `f3511a4`. `CHANGELOG.md` has the same claims; its section headings are one level deeper, and older tags are links. `docs/README.md` links 1.3.0, says that file includes the unpublished 1.2.1 changes, and still links 1.2.1. The paste below is that file.

# DevType 1.3.0 — Image snippets, library restore, and a stricter preview

The GitHub artifact follows the project's existing ad-hoc signed, unnotarized distribution policy. Gatekeeper may reject it. Notarization stays off (9c73c04). Local packages use the available Apple Development identity.

These notes cover unpublished 1.2.1 and the work after it. The 1.2.1 tag exists on this clone and was not pushed to origin; its commit is already on the published branch. The original write-up remains in `docs/releases/v1.2.1.md`.

## Highlights

- **Image snippets keep their file bytes.** Expanding a stored PNG, JPEG, GIF, or TIFF publishes that file's own bytes under one native pasteboard type, within the import cap. Animated GIF is no longer flattened by re-encoding. bmp, webp, heic, unknown extensions, and unreadable or over-cap files still fall back to TIFF+PNG. Copy is unchanged (3e073cd).
- **Espanso image export round-trips.** A directory export writes `images/<safe name>` beside the match files with a relative path, and fails closed when the attachment is missing or leaves the store (6f4f1e9).
- **Restore from Backup.** Snippet saves keep the 20 newest library copies plus the newest per day for 30 days. Replace with Defaults, Restore from Backup, Save As / Move Library, and Stop Syncing write a safety backup first and fail closed when that backup cannot be written. Preferences → Snippets gains Restore from Backup…, with the date, snippet count, and trigger kind (a101f73).
- **`devtype://` opens a closed set of screens.** The allowlist is new, palette, preferences, dictation/toggle, and copy. Those URLs do not expand text and do not read a secret. The macro catalog used by the palette now lives in the engine (7f8ed1e).
- **Preview can format a table and show a word diff.** A bounded column-and-row result becomes Markdown. `toTable` is available to the local transform and the palette. Every transform kind uses one grapheme-safe word diff (7a434d0).

## Match Trigger Case (sig / Sig / SIG)

- **New snippet option:** case-insensitive snippets gain a **Match Trigger Case** switch in the editor (shown only while Case Sensitive is off). Typing the trigger Capitalized or in ALL CAPS shapes the expansion the same way (6ad2094).
- **Espanso-compatible shape rules:** only the first two letters of the typed trigger are read and non-letters are skipped. Upper+Upper or a lone capital means ALL CAPS, Upper+lower means first letter upper, and anything that starts lowercase (including mixed `sIG`) or has no letter stays as written.
- **Narrower than Espanso, on purpose:** only text written in the snippet template is reshaped. Fill-in values, clipboard text, dates and generated values keep their own case, as do spans an explicit `{{upper:…}}`-style transform already shaped. Cursor markers are remapped when uppercasing changes length (`ß` → `SS`).
- **Importer:** Espanso `propagate_case` matches now import with the option on. The old "output case adaptation is unavailable" note is gone; a new note counts matches that use `uppercase_style: capitalize | capitalize_words`, which DevType imports with the default case shapes.

## Selection reads no longer block the main thread

- **No beachball on AI hotkey, palette, or voice command:** selection reads run on a dedicated serial queue and hand their result back on main (e77b5bf).
- **Latest press wins:** the AI hotkey, palette AI actions, and the inline search panel only act on the most recent press. A second palette press while the first is still reading closes it instead of queueing a second panel, and a stale read cannot raise a stale alert.
- **AX retries never sleep on main:** focus-query retries and the Chromium accessibility rescue use one bounded policy (`AXSettleRetry`) that waits only off main and reports when a poll was skipped rather than passing it off as zero polls (c7e1400).
- **One focused element per expansion:** an expansion resolves the focused element once and threads it through the entry re-check, IME probe, erase guard, AX writes, delivery check, caret placement and trigger restore. No collaborator inside an inject queries focus through a default argument (68d4412).

## Local Lappi routing (opt-in, off by default)

- **Ask Lappi which tool fits:** when on-device palette routing runs, DevType can also ask a local Lappi agent over a Unix socket on this Mac (300 ms limit). An answer only annotates the routed row as agreeing or differing; it never inserts text or runs anything (24cc8d8).
- **Local routing records:** optionally records which tool routing chose and which row you picked, to `Application Support/Lappi/heldout` — the phrase's length and shape, never its text. Records are bounded per day and in total, stay on this Mac, and are never used for training. `LAPPI_COLLECT=0` disables collection.
- Nothing is sent or written while secure input is on. Both switches live in Preferences → AI and default off.

## UI strings move to resource tables

- English, Korean and Japanese UI strings ship as `.strings` resource tables (`Sources/ExpanderEngine/Localization/Resources/<lang>.lproj/`, eight tables per language) instead of Swift dictionary literals (3c50ecd).
- The user-chosen UI language still wins over the system language. Malformed tables, missing languages and keys defined twice are reported at load.
- **Pseudolocale for layout checks:** `DEVTYPE_PSEUDOLOCALE=1` (or `-devtype.debug.pseudolocale YES`) accents, brackets and pads every string by about 40%, keeping format specifiers intact.

## Engine internals

- Text injection's undo policy, route choice, entry-gate refusals, swallowed-key and completion-guard types, the image-snippet path and text resolution each have their own owner. The inject/undo ledger owns its single lock (93a21d1).

## Fixes

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

## Hardening

- **A packaged bundle that still says 0.1.7 (build 2) fails CI.** That pair is the source `Info.plist` placeholder. The old gate looked for 1.0.0 / 1, which this repository does not stamp. Git-describe builds, including `+dirty`, still pass (9915186).
- **A release whose public download does not match the built DMG is put back into draft.** `/releases/latest` does not keep offering it. Replacing an already-public release with `DEVTYPE_ALLOW_REPUBLISH=1` does not re-draft that release (9652c98).
- **GitHub Actions are pinned to the current v4 commits, checkout does not persist credentials, and only the publish job has `contents: write`** (9c73c04).
- **The local Lappi socket and the secret archive lock stay narrow.** See the fixes above. Performance work caches hot-path scans, palette queries, voice transcripts, and the streaming HUD, and moves notification-driven Accessibility reads off the main thread (1418067, 90db0a7, 6cf3b8c, 6d84383, 1f5d176, 01d639d). The benchmark self-test uses an injected clock, so a slow scheduler cannot pass or fail the min-of-N rule (07a6b6e).

## Breaking changes

- A library that already opens is unchanged, and there is no settings migration. 1.2.1 adds no dependency, cloud service, permission grant, secret migration, or authentication change.
- A corrupt typed-path allowlist now denies every app. It used to decode as an empty list, which meant every app (8951428).
- An undecodable or newer-schema timing or capability file is moved aside and kept, rather than overwritten (8951428).

## Known issues

- The published DMG is ad-hoc signed and not notarized. Gatekeeper may reject it (9c73c04). Developer ID signing is an open maintainer decision.
- The version string on an untagged build is still `git describe`, not 1.3.0. The bundle says 1.3.0 only when this commit is tagged `v1.3.0` on a clean tree.

## Local install

`./Scripts/install-app.sh release` installed `/Applications/DevType.app` as 1.3.0. The package is signed `Apple Development: bharath.vbcr@gmail.com (SV7KQ26548)`. Hardened Runtime is disabled. The designated requirement is the certificate, so the version restamp did not reset TCC. Source sha256 of the Mach-O before signing is `6270fdd8ae6c12a8c00d029967067bcf06403cf6790a3b101b4a2608c6bcbdac`, the same binary `./ci:local` packaged. `Scripts/verify-release-version.sh` accepted `v1.3.0` → `1.3.0` on that bundle. The build number is the commit count of the tagged commit. The `./ci:local` package remains `1.2.1-132-ga62df2f` (build 367).

## Commands to push

The local tag already exists. Do not create it again, and do not point it at `a62df2f`. Pushing the tag starts `.github/workflows/release.yml`. Do not push `v1.2.1`.

```bash
git push origin main
git push origin refs/tags/v1.3.0
```

Do not use `git push --tags`. Do not force-push. If the release run fails, fix it in a new commit and do not move `v1.3.0`.
