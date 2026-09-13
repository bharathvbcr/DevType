# Security & Privacy Policy

DevType is engineered from the ground up as a **privacy-first, local-by-default** application. Because DevType operates as a system-wide text expansion utility with accessibility and input monitoring permissions, we treat user security, privacy, and data isolation with the highest priority.

Local-by-default means nothing leaves this Mac unless you turn on a feature that says it will. Three things can send data off the machine, all of them off until you act: the opt-in Gemini dictation engine, the opt-in update check, and a snippet library you choose to store in a synced folder. Each is described precisely below — we would rather tell you exactly where the edges are than claim there are none.

---

## 🔒 Security Principles & Guarantees

### 1. On-Device by Default & Zero Telemetry
- DevType contains **zero** cloud telemetry, analytics trackers, or network reporting endpoints. Nothing about your usage is ever reported anywhere.
- AI transformations run on this Mac: Apple Foundation Models on supported macOS versions, plus deterministic offline transformations (e.g. Remove Markdown). Neither reaches the network.
- Speech dictation is local-first — Apple Speech, Local AI, and Local Whisper all keep audio on this Mac.
- Keystrokes and usage statistics never leave this Mac under any configuration. Recorded audio leaves only through the opt-in Gemini engine described below, and never otherwise.
- Your snippet database stays on this Mac unless you move it (see below).

#### Where data *can* leave this Mac

Exhaustively, and only if you choose it:

| Path | Default | What is sent, and to whom |
|---|---|---|
| **Gemini dictation** | Off | Your recorded audio and steering text go to Google (`generativelanguage.googleapis.com`). Requires selecting the Gemini engine, supplying your own API key, **and** granting a separate explicit cloud-audio consent — selecting the engine and saving a key are not by themselves consent. |
| **Update check** | Off | An unauthenticated request to the GitHub releases API. No telemetry, device identifiers, or usage data. Automatic checks are spaced at least 24 hours apart; a check you trigger yourself from the menu runs when you ask it to. DevType never downloads or installs an update — it opens the release page in your browser. |
| **Synced snippet library** | Off | If you point your library at a folder your sync client watches (iCloud Drive, Dropbox, and similar), that provider handles your snippet text, metadata, and attached images like any other file in that folder. DevType does not sync anything on its own; this is entirely a consequence of where you put the file. |

#### Local network services

Local Whisper and the Local AI correction service are *local*, not *offline*. They are ordinary HTTP requests to a server on this machine — `127.0.0.1` for Whisper, `localhost:11434` for correction by default — so your audio and transcript text cross a loopback socket in plaintext to whatever process is listening on that port.

DevType restricts these requests to loopback addresses, refuses redirects, ignores system proxies, and bounds every response. It cannot verify *which* process answers: a program running under a different account on this Mac that claims an unused configured port before your real server does would receive what is sent there. If you enable a local engine, treat the port you configure as trusted.

### 2. Keystroke Protection & Fail-Closed Safety
- **Volatile Ring Buffer**: Intercepted keystrokes are temporarily held in an in-memory ring buffer solely for abbreviation prefix matching. Keystrokes are never logged, written to disk, or retained.
- **Secure Text Fields**: Whenever a password field (`NSSecureTextField`) is active or macOS `IsSecureEventInputEnabled()` is true, DevType immediately pauses event tapping and prefix matching.
- **App Muting**: Users can specify sensitive applications (e.g. password managers, financial software, terminal sessions) where DevType is completely deactivated.

### 3. Secrets Architecture
For sensitive text (e.g. passwords, API tokens), DevType provides an independent **Secrets** manager:
- Encrypted at rest using **AES-GCM** with a 256-bit key stored securely in the macOS login Keychain.
- An app-level **Touch ID/login password** gate uses `LocalAuthentication`, enabled by default where available and controlled by the existing user preference.
- `SecretModel` has no trigger or value field. Metadata occupies its own `secrets` collection in library schema 3; values are absent from library JSON, snippet exports, and diagnostic logs. Legacy UUIDs are preserved without accessing stored values during metadata migration.
- The Secrets manager reuses the existing authentication and clipboard owners. Storage repair remains the explicit Preferences → Advanced → Repair Secret Storage action; an unreadable master key is never replaced during metadata migration.
- Secret reads revalidate the selected metadata against the current library on disk. Disabled, deleted, edited, or unverifiable selections are refused, including changes made while authentication is pending.
- Complete value-edit transactions share archive exclusion. Failed and partial writes are compensated conditionally; orphan deletion rechecks current references under that exclusion and reports deferred cleanup explicitly.
- Clipboard writes carry concealed, transient, and auto-generated markers to request exclusion from compatible clipboard managers. A 90-second timer clears only the write DevType still owns; these markers cannot force another application to honor them.

For full architectural details, see [SECRETS.md](SECRETS.md).

### 4. TCC Permissions & Code Identity
DevType strictly requests only the macOS permissions required for core expansion and voice features:
- `Input Monitoring` (`ListenEvent`): Required to intercept and swallow typed trigger keystrokes.
- `Accessibility` (`AXIsProcessTrusted`): Required for atomic range replacement via macOS Accessibility APIs.
- `Post Events` (`PostEvent`): Used for fallback keystroke injection.
- `Microphone` (`AVCaptureDevice`): On-demand permission required exclusively for Smart Voice Dictation (`⌘⌥V`).
- `Speech Recognition` (`SFSpeechRecognizer`): On-demand permission used for on-device Apple Speech transcription.

Local builds use the available signing identity, preferring Developer ID, then Apple Development, then a local certificate. The local v0.1.7 build uses Apple Development signing and is **not notarized**. A successful `codesign` verification is distinct from Gatekeeper approval: notarized distribution requires Developer ID signing and acceptance by Apple’s notary service. The installer compares designated requirements and handles a changed identity separately from a normal version update.

---

## 🛡️ Supported Versions

We provide security updates and patches for the following versions of DevType:

| Version | Supported |
|---|:---:|
| Current Release (Latest) | ✅ Yes |
| Previous Minor Versions | ⚠️ Best effort / critical fixes only |
| Pre-release / Betas | ❌ Please update to latest |

---

## 🚨 Reporting a Vulnerability

If you discover a security vulnerability or privacy concern in DevType, please report it responsibly:

1. **Do NOT open a public GitHub issue.**
2. Report the vulnerability privately via GitHub's **Private Vulnerability Reporting** feature on the repository:
   - Navigate to the **Security** tab of the DevType repository.
   - Click on **Advisories** → **Report a vulnerability**.
3. Alternatively, contact the repository maintainers directly through GitHub profiles or project security contacts.

### What to Include in Your Report
To help us triage and resolve the issue quickly, please provide:
- A clear description of the vulnerability and its potential impact.
- Step-by-step reproduction instructions or a proof-of-concept.
- Affected macOS versions and DevType release versions.
- Any suggested mitigations or patches (if available).

### Response Timeline
- **Initial Acknowledgment**: Within 48 hours.
- **Triage & Assessment**: Within 5 business days.
- **Resolution & Release**: A fix will be developed, tested, and published as a high-priority patch.

We appreciate the security community's efforts in keeping open-source software safe and private for everyone.
