# Security & Privacy Policy

DevType is engineered from the ground up as a **privacy-first, offline-only** application. Because DevType operates as a system-wide text expansion utility with accessibility and input monitoring permissions, we treat user security, privacy, and data isolation with the highest priority.

---

## 🔒 Security Principles & Guarantees

### 1. 100% On-Device & Zero Telemetry
- DevType contains **zero** cloud telemetry, analytics trackers, or network reporting endpoints.
- AI transformations run locally on-device using Apple Foundation Models (on supported macOS versions) alongside deterministic offline local text transformations (e.g. Remove Markdown). No text or prompts are transmitted over the network.
- Speech dictation is local-first (Apple Speech, on-device Local AI, loopback Local Whisper) with an opt-in cloud engine (Gemini) that remains inactive until you supply your own API key.
- Update checks are off by default, opt-in only, run at most once a day, and transmit zero telemetry, device identifiers, or usage data.
- Your snippet database, usage statistics, audio recordings, and keystrokes never leave your Mac.

### 2. Keystroke Protection & Fail-Closed Safety
- **Volatile Ring Buffer**: Intercepted keystrokes are temporarily held in an in-memory ring buffer solely for abbreviation prefix matching. Keystrokes are never logged, written to disk, or retained.
- **Secure Text Fields**: Whenever a password field (`NSSecureTextField`) is active or macOS `IsSecureEventInputEnabled()` is true, DevType immediately pauses event tapping and prefix matching.
- **App Muting**: Users can specify sensitive applications (e.g. password managers, financial software, terminal sessions) where DevType is completely deactivated.

### 3. Secret Snippets Architecture
For sensitive text (e.g. passwords, API tokens), DevType provides dedicated **Secret Snippets**:
- Encrypted at rest using **AES-GCM** with a 256-bit key stored securely in the macOS login Keychain.
- Gated behind **Touch ID** or macOS local biometric/passcode authentication via `LocalAuthentication`.
- Secrets are excluded from standard typed trigger expansion, regular library files (`snippets.json`), and diagnostic export logs.
- When copied to the clipboard, secrets are marked with standard concealment flags (`org.nspasteboard.ConcealedType`, `com.agilebits.onepassword`) to prevent clipboard managers from capturing them, and are automatically purged from the clipboard after 90 seconds.

For full architectural details, see [SECRETS.md](SECRETS.md).

### 4. TCC Permissions & Code Identity
DevType strictly requests only the macOS permissions required for core expansion and voice features:
- `Input Monitoring` (`ListenEvent`): Required to intercept and swallow typed trigger keystrokes.
- `Accessibility` (`AXIsProcessTrusted`): Required for atomic range replacement via macOS Accessibility APIs.
- `Post Events` (`PostEvent`): Used for fallback keystroke injection.
- `Microphone` (`AVCaptureDevice`): On-demand permission required exclusively for Smart Voice Dictation (`⌘⌥V`).
- `Speech Recognition` (`SFSpeechRecognizer`): On-demand permission used for on-device Apple Speech transcription.

Local builds use the available signing identity, preferring Developer ID, then Apple Development, then a local certificate. The local v0.1.4 build uses Apple Development signing and is **not notarized**. A successful `codesign` verification is distinct from Gatekeeper approval: notarized distribution requires Developer ID signing and acceptance by Apple’s notary service. The installer compares designated requirements and handles a changed identity separately from a normal version update.

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
