# Changelog

Curated notes for each tag live in `docs/releases/<tag>.md`. The publisher reads that file. This changelog matches it. Older tags are linked, not copied.

## [1.5.0]

**DevType 1.5.0 — Safari delivery hardening, voice dictation recovery, and verified replace**

The GitHub artifact follows the project's existing ad-hoc signed, unnotarized distribution policy. Gatekeeper may reject it. Notarization stays off (9c73c04). Local packages use the available Apple Development identity.

Safari delivery hardening (field report 2026-10-25, 1.3.0 build 389, macOS 27.0.1: a Safari proofread was refused because the paste target resolved to Safari's window, and typed expansions in Safari were mostly delivered unverified), voice dictation hardening on macOS 27, eager clipboard publication with marker precedence, and the live Safari test harness.

### Typed expansions

- **Input arriving mid-expansion is seen again.** A real event tap on Apple silicon delivers `CGEvent.timestamp` in mach ticks (build 438 logged `ratio=0.0240`), and the engine read it as nanoseconds, so the guard that aborts an expansion when you type after it armed could never fire. The input clock now measures the unit on the first real event, converts, and logs both ratios once per launch.
- **A field WebKit replaces is followed only when it is the same control.** One owner (`ControlIdentity`) decides for the erase, the paste, the delivery check and the AI confirm. Same process, text role and frame, and no contradicting host identity (`AXDOMIdentifier`, `AXIdentifier`, placeholder, parent role). A different control re-rendered at the same frame is refused.
- **Typing that outruns an expansion keeps its terminator.** If the type-ahead hold gives up on a key in the same app before anything was written, the expansion is abandoned and the swallowed key is posted back, then the held keys. Whether a post from the tap reaches the app before the key that ended the hold is not yet verified live. A click still drops the terminator rather than risk typing it where the caret went, and a hold that ends because focus left the app (a fill-in panel, another app) is left to the expansion's own checks. A wait for a previous unread paste is capped at half the hold (0.175 s), after which the expansion publishes over it, as every expansion did before the wait existed.
- **A partial erase is put back only where the field proves it.** The restore needs the field to equal its pre-erase state minus exactly the posted keys (one settle re-read for a mirror one key behind). An unreadable field or an overstated count gets the plain refusal.
- **A stale read right after an AX write is no longer a verdict.** It waits one settle before an app is condemned as lying, so a landed write is not erased into.
- **Fewer silent misses.** A Secure Input release is read live instead of waiting up to 350 ms for the poll; a key swallowed into type-ahead no longer aborts the expansion it waits on; paused, suspended and autorepeat input clear a half-typed trigger; Fn/Globe resets it; a key with no character (a dead key) counts as input.
- **Every abort is counted.** Matched-but-not-expanded now carries a reason for user input after arm, focus moved, gate refused, render failed, fill-in aborted, and AI refused (including the planner's refusal).

### AI rewrite (proofread and friends)

- **The source app's window is not a paste target.** Waiting for focus to return treats a window, sheet, drawer, popover or application element as focus that has not arrived. The selection's own element is kept from the read, focus is put back on it only when the host's answer confirms it and only if you have not acted since, and focus is read again before ⌘V. A refusal logs where the settle stopped and how long it took.
- **A replace is checked after it pastes.** If the field still holds the original after the miss window, the result stays on the clipboard with a "didn't land" notice and is never pasted twice. The result stays on the board for the whole window, and no miss is called once the clipboard has changed hands. In Safari the check uses its proven read mirror; Chromium/Electron mirrors that lag stay untrusted.
- **Autorepeat of the accept key does not cancel the delivery it started.**

### Clipboard

- **Snippets are published directly again.** A lazily provided payload (tried and reverted on this branch) made the reading app wait on DevType's main thread (1.57 s measured) and left nothing behind on a crash.
- **The clipboard markers come first.** Concealed/Transient markers now precede the payload inside one item, so a clipboard manager never sees a secret unmarked (2.4% of samples before).
- **Your clipboard comes back on quit.** A paste still holding the board when DevType quits is restored in `applicationWillTerminate`.
- **⌘V is found on Dvorak-QWERTY-⌘ and similar layouts** (the key is resolved under Command).
- **A copy you make while a paste is publishing is not lost**, and image snippets go through the same checked publication.

### Voice dictation

- **Dictation records again on macOS 27.** The microphone tap ignores the requested buffer size and delivers 100 ms (4,800 frames at 48 kHz); the capture pool refused every such buffer, so each session recorded nothing and said "No speech detected". The pool is now sized from the hardware format (verified on the built-in mic: 48,000 frames in 3 s).
- **A failed capture says what failed.** A refused buffer, a full ring, a switched or stalled microphone, and a missing input device each have their own message; "No audio was captured" is kept for a stop before the first buffer, and "No speech detected" only for audio that held no speech.
- **A microphone that goes quiet stops the session at once** — before or after its first buffer — after 2.5 s for wired inputs and 6 s for Bluetooth/AirPlay, instead of waiting for you to finish talking into nothing.
- **Switching or losing the microphone mid-dictation keeps recording.** The new default input is reopened into the same recording (at most twice per session) and the missing interval is measured from the tap's timestamps. Starting while the device is still settling (Core Audio -10868) is retried instead of reported as no microphone.
- **The end of every recording is kept.** The resampler's withheld tail is flushed for the recording and the Gemini upload, and clips shorter than one FLAC block are no longer uploaded as an empty file.
- **Apple Speech no longer asks to download a model that is installed.** The locale's asset is reserved before its status is read.
- **The live preview survives a pause**: only immediately failing recognition tasks count toward giving up.
- **Newer diagnostics no longer erase history.** Voice terminal records and activity history skip and count an entry they cannot read instead of discarding the file. Builds up to 1.3.0 still discard on first read of a file written by this version.
- The macOS 27 `installAudioTap` is used where available; `DEVTYPE_HARDWARE_MIC=1` and `DEVTYPE_HARDWARE_MIC_SWITCH=1` run the opt-in real-microphone tests (the latter briefly switches the default input and sample rate, and restores them).

### Diagnostics and tooling

- `Scripts/safari-harness.sh` drives the installed DevType against a local test page in Safari (plain input, textarea, contenteditable, node-swapping and SPA fields, fast typing, Secure Input, held modifiers, AI proofread) and reports field contents, clipboard restore and the relevant log lines. It types on your machine: run it yourself, `--dry-run` first.
- AX elements carried across threads go through one `AXElementHandle`, which clears the Swift 6 `Sendable` warnings.

## [1.3.0]

See [docs/releases/v1.3.0.md](docs/releases/v1.3.0.md).

## [1.2.1]

See [docs/releases/v1.2.1.md](docs/releases/v1.2.1.md).

## [1.2.0]

See [docs/releases/v1.2.0.md](docs/releases/v1.2.0.md).

## [1.1.0]

See [docs/releases/v1.1.0.md](docs/releases/v1.1.0.md).
