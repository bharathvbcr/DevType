# DevType v1.3.0 release report

PUSH was no. Nothing was pushed, no tag was created, and the app was not published. HEAD is `a62df2f1a186fdbc3507f19b33ea04fdebf305f4` on `main`, 91 commits ahead of `origin/main`. This file and `BRANCH_REPORT.md` are untracked on purpose: the green `ci:local` ran on `a62df2f`, and a later commit would make that run stale.

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

No GitPulse task id is in those messages. The accessibility, alert, preview, and benchmark follow-ups are not named by a board card. `9c73c04` is the release-free workflow commit: it does not change the app.

`v1.3.0` does not exist locally or on origin. The local tag `v1.2.1` is an ancestor of HEAD. Its commit is on origin. The tag ref is not.

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

The packaged bundle is `com.devtype.app`, executable `DevType`, and `Contents/MacOS` contains only `DevType`. Stamped version `1.2.1-132-ga62df2f` (build 367). The source placeholder `0.1.7` / `2` was rejected by the new check; this stamp passed. The bundle says `1.3.0` only after `v1.3.0` is tagged on a clean tree.

Not run, and announced rather than passed:

- Step 2b, the release benchmark gate. `DEVTYPE_BENCH` was unset. `AuditBenchmarkTests` recorded 10 skips inside the debug suite for the same reason. The gate is `DEVTYPE_BENCH=1 ./ci:local`.
- Foundation Models linkage. `DEVTYPE_REQUIRE_FOUNDATION_MODELS` was unset. The tagged release workflow sets it.

This full suite was run once, on the final HEAD, after every commit above. The stamp script (9 tests) and the publication script (24 tests) had already passed on the uncommitted pipeline edits. There was not a separate full `ci:local` between `9652c98`, `9915186`, and `9c73c04`.

DevMap could not name callers for the reliability edits. `devmap_status` generation 613 had `source_freshness` true and `analyzer_freshness` false (`stored extraction payload is obsolete`). `devmap_affected_tests` failed closed with all three targets unmatched. The gap is `release-v1.3.0-reliability-blast`. Call sites were then read from the tree: `BenchmarkGate.measure` has one call, in its self-test, and the full suite compiled the other `BenchmarkGate` callers.

## Release pipeline

### Fixed

- A bundle that still has the source `Info.plist` pair `0.1.7` / `2` fails local CI and the hosted package job. The old guard looked for `1.0.0` / `1`. `9915186`.
- If the download after undraft does not match the built DMG, `publish-release.sh` puts the release back into draft. `/releases/latest` does not keep offering it. `9652c98`, covered by `test_public_verification_failure_returns_the_release_to_draft`. If the re-draft itself fails, the command still fails and the release stays public.
- `actions/checkout`, `actions/cache`, and `actions/upload-artifact` are pinned to the v4 commits resolved on 2026-10-15. Every checkout sets `persist-credentials: false`. Workflow `contents` is read, and only the publish job has `contents: write`. `9c73c04`. The repository is public, so `git ls-remote` in the publisher does not need the checkout token.
- The update alert Close path, preview main-queue order, benchmark clock, and one AXManualAccessibility retry. See the commits above.

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

Push order for this task, from the request itself: when you say yes, push `main`, then push only `v1.3.0`. Never `--tags`. Never force. Never move an existing tag.

`DEVTYPE_ALLOW_REPUBLISH=1` still replaces a public release in place and does not re-draft it. That path is unchanged on purpose.

There is no Windows or Linux bundle and no hook or MCP binary. The packaged app contains `DevType` only. Whisper is an external loopback server.

Clients learn about an update from `GET /repos/bharathvbcr/DevType/releases/latest`. A draft is not that endpoint. The app does not download the DMG and does not check a checksum. It opens the GitHub release page.

## Release notes

Publisher body: `docs/releases/v1.3.0.md`. `CHANGELOG.md` has the same claims; its section headings are one level deeper, and older tags are links. `docs/README.md` links 1.3.0 and 1.2.1.

# DevType 1.3.0 — Image snippets, library restore, and a stricter preview

The GitHub artifact follows the project's existing ad-hoc signed, unnotarized distribution policy. Gatekeeper may reject it. Notarization stays off (9c73c04). Local packages use the available Apple Development identity.

These notes cover the work after 1.2.1. The 1.2.1 tag exists on this clone and was not pushed to origin; its commit is already on the published branch. 1.2.1's own notes are in `docs/releases/v1.2.1.md`.

## Highlights

- **Image snippets keep their file bytes.** Expanding a stored PNG, JPEG, GIF, or TIFF publishes that file's own bytes under one native pasteboard type, within the import cap. Animated GIF is no longer flattened by re-encoding. bmp, webp, heic, unknown extensions, and unreadable or over-cap files still fall back to TIFF+PNG. Copy is unchanged (3e073cd).
- **Espanso image export round-trips.** A directory export writes `images/<safe name>` beside the match files with a relative path, and fails closed when the attachment is missing or leaves the store (6f4f1e9).
- **Restore from Backup.** Snippet saves keep the 20 newest library copies plus the newest per day for 30 days. Replace with Defaults, Restore from Backup, Save As / Move Library, and Stop Syncing write a safety backup first and fail closed when that backup cannot be written. Preferences → Snippets gains Restore from Backup…, with the date, snippet count, and trigger kind (a101f73).
- **`devtype://` opens a closed set of screens.** The allowlist is new, palette, preferences, dictation/toggle, and copy. Those URLs do not expand text and do not read a secret. The macro catalog used by the palette now lives in the engine (7f8ed1e).
- **Preview can format a table and show a word diff.** A bounded column-and-row result becomes Markdown. `toTable` is available to the local transform and the palette. Every transform kind uses one grapheme-safe word diff (7a434d0).

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

- A library that already opens is unchanged, and there is no settings migration.
- A corrupt typed-path allowlist now denies every app. It used to decode as an empty list, which meant every app (8951428).
- An undecodable or newer-schema timing or capability file is moved aside and kept, rather than overwritten (8951428).

## Known issues

- The published DMG is ad-hoc signed and not notarized. Gatekeeper may reject it (9c73c04). Developer ID signing is an open maintainer decision.
- The version string on an untagged build is still `git describe`, not 1.3.0. The bundle says 1.3.0 only when this commit is tagged `v1.3.0` on a clean tree.

## Commands to push and tag

Run these from this clone when you want `v1.3.0` published. Pushing the tag starts `.github/workflows/release.yml`. Do not push `v1.2.1` with these commands.

```bash
git tag -a v1.3.0 a62df2f1a186fdbc3507f19b33ea04fdebf305f4 -m "DevType 1.3.0"
git push origin main
git push origin refs/tags/v1.3.0
```

Do not use `git push --tags`. Do not force-push. If the release run fails, fix it in a new commit and do not move `v1.3.0`.
