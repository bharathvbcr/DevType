# macOS Permissions & TCC Setup Guide

To provide seamless, low-latency text expansion, trigger-swallowing, and Smart Voice Dictation across macOS, **DevType** requires specific system permissions governed by Apple's Transparency, Consent, and Control (TCC) subsystem.

This guide explains why each permission is needed, how to grant and maintain them, and how to troubleshoot permission issues.

---

## 🔐 Permission Capability Matrix

| Permission | TCC Identifier | API Preflight Function | Why DevType Needs It |
|---|---|---|---|
| **Input Monitoring** | `kTCCServiceListenEvent` | `CGPreflightListenEventAccess()` | **Required** to intercept typed keystrokes and swallow trigger abbreviations before they render on screen. |
| **Accessibility** | `kTCCServiceAccessibility` | `AXIsProcessTrustedWithOptions()` | **Required** to perform atomic text range replacement directly inside focused text fields via macOS Accessibility APIs (`AXUIElement`). |
| **Post Events** | `kTCCServicePostEvent` | `CGPreflightPostEventAccess()` | *Optional / Fallback* to synthesize backspaces (`kVK_Delete`), `⌘V` paste events, and arrow navigation when Accessibility APIs are blocked. |
| **Microphone** | `kTCCServiceMicrophone` | `AVCaptureDevice.authorizationStatus(for: .audio)` | **Required for Voice Dictation** to capture audio via 16kHz PCM streaming. With Apple Speech, Local AI, or Local Whisper selected, no audio leaves your Mac; the opt-in Gemini cloud engine uploads audio only after you supply your own API key and separately grant cloud-audio consent. |
| **Speech Recognition** | `kTCCServiceSpeechRecognition` | `SFSpeechRecognizer.authorizationStatus()` | **Required** when Apple Speech supplies the final transcript. For Gemini or Local Whisper it is optional and used only for the live preview, which both "While you speak" modes other than *Show nothing, insert at the end* rely on. |

The capabilities are deliberately partitioned:
- Core text expansion requires **Input Monitoring + Accessibility** together.
- Post Events powers the synthetic-injection fallback without tearing down the tap.
- Voice Dictation requires **Microphone** permission on-demand when push-to-talk (`⌘⌥V`) is activated, with prompt dialogs governed by `NSMicrophoneUsageDescription` in `Info.plist`.
- Apple Speech and Local AI request **Speech Recognition** before recording because they use Apple Speech for the final transcript. Gemini and Local Whisper continue without that grant unless a "While you speak" mode that shows a live preview is selected.
- Selecting Gemini is not permission to upload audio: DevType also requires a separate, explicit cloud-audio consent in Preferences before capture can start.

---

## 🛠️ Step-by-Step Setup in macOS

When you first launch DevType, the **Permission Onboarding Wizard** will open automatically (Welcome → Input Monitoring → Accessibility + Post Events → Verify → Done). You can also manually configure permissions at any time:

### 1. Enable Accessibility
1. Open **System Settings** (`` → **System Settings…**).
2. Navigate to **Privacy & Security** → **Accessibility**.
3. Locate **DevType** in the list and toggle the switch to **ON** (Enter your macOS administrator password or Touch ID when prompted).
4. If DevType is not listed, click the **`+`** button and select `/Applications/DevType.app`.

### 2. Enable Input Monitoring
1. In **System Settings**, navigate to **Privacy & Security** → **Input Monitoring**.
2. Locate **DevType** and toggle the switch to **ON**.
3. If prompted to "Quit & Reopen", allow macOS to restart DevType so the event tap activates immediately.

### 3. Enable Microphone (for Smart Dictation)
1. Trigger Smart Dictation with `⌘⌥V` or open **Preferences** (`⌘,`) → **Voice** → **Request Access**.
2. When the macOS system modal appears (*"DevType would like to access the microphone"*), click **Allow**.
3. You can also view or change this in **System Settings** → **Privacy & Security** → **Microphone**.

### 4. Enable Speech Recognition (for Apple Speech or Local AI)
1. Select **Apple Speech** or **Local AI** in **Preferences** → **Voice**, then start Smart Dictation.
2. When macOS asks whether DevType may use Speech Recognition, click **Allow**.
3. You can review the grant in **System Settings** → **Privacy & Security** → **Speech Recognition**. Gemini and Local Whisper need this grant only when a "While you speak" mode that shows a live preview is selected.

---

## 💻 Local Development & Code Signing

macOS TCC binds permission grants directly to an application's **Code Signing Designated Requirement (DR)** and bundle identifier (`com.devtype.app`).

If you compile DevType locally using ad-hoc signing (`-`), Xcode or SwiftPM generates a new ephemeral ad-hoc signature on every build, causing macOS to invalidate your TCC permissions repeatedly.

### Which identity gets used

`./Scripts/package-app.sh` does not hardcode an identity. `./Scripts/signing-identity.sh` resolves one, best first, and you can run it yourself to see the answer:

| Order | Identity | Notes |
|---|---|---|
| 1 | `Developer ID Application: …` | Paid Apple Developer Program. The only identity that can be notarized for distribution. |
| 2 | `Apple Development: …` | **A free Apple ID is enough.** Preferred for everyday development. |
| 3 | `DevType Local Signing` | Self-signed fallback from `./Scripts/make-signing-cert.sh`. |
| 4 | ad-hoc (`-`) | Last resort. TCC grants reset on every rebuild. |

Any of the first three keeps the DR pinned to a certificate, so TCC grants survive rebuilds. Set `DEVTYPE_SIGN_IDENTITY` to override the choice, or to `-` to force ad-hoc.

### Preferred: an Apple Development certificate (free Apple ID)

In Xcode, go to **Settings → Accounts**, add your Apple ID, then **Manage Certificates → + → Apple Development**. Confirm it landed:

```bash
security find-identity -v -p codesigning
```

### Self-signed fallback: `DevType Local Signing`

If you do not have Xcode or an Apple ID configured, create a stable local self-signed certificate:

```bash
./Scripts/make-signing-cert.sh
```

---

## 🔍 Permission Diagnostics & Recovery

If text expansion or microphone capture stops responding:
1. Open **Preferences** (`⌘,`) → Check the status pill.
2. Click **Status Menu** → **Permission Diagnostics** for detailed CDHash, designated requirement, and TCC service states.
3. Reset permissions for a clean slate if needed:
   ```bash
   ./Scripts/reset-tcc.sh
   ```
   The script resets Input Monitoring, Accessibility, Post Events, Microphone, and Speech Recognition, and exits non-zero if any reset fails.
