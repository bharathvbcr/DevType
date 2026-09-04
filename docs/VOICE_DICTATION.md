# Voice Smart Dictation in DevType

DevType integrates Smart Speech-to-Text and Dictation across four selectable engines — three of them fully local — paired with Google Gemini **Jot**-inspired thought revision and disfluency resolution, rendered in a floating dictation HUD that adopts Apple **Liquid Glass** on macOS 26+ (`NSGlassEffectView`) with a material fallback below.

---

## 🎙️ Architecture & Features

### 1. Four Selectable Speech Engines

Pick the recognizer in **Preferences $\to$ Voice**. Each engine reports its own readiness, so what is actually installed and reachable is visible before you hold the key.

* **Apple Speech (Rule-based)**:
  - On-device `SFSpeechRecognizer` recognition followed by DevType's deterministic cleanup rules.
  - Nothing to download, nothing to configure, no API key. This is where dictation lands when nothing else is set up.
* **Local AI (On-Device)**:
  - The same on-device Apple Speech recognition, with the transcript polished by a local language model.
  - Apple Intelligence Foundation Models on macOS 26+; otherwise a loopback endpoint — Ollama at `http://localhost:11434/v1/chat/completions` by default, or any OpenAI-compatible local server you point it at.
  - Audio never leaves the Mac; only the recognized text is handed to the local model.
  - Endpoint validation is enforced for local correction paths (loopback hosts only, no redirect fan-out, and operation-specific response-size limits).
* **Local Whisper (whisper.cpp)**:
  - A `whisper-server` on loopback (`http://127.0.0.1:8080/inference` by default), noticeably stronger than Apple Speech on technical vocabulary and fully offline.
  - DevType detects an installed binary, can fetch the default `ggml-base.en.bin` (~148 MB) into `~/.cache/whisper.cpp`, and can start the server for you — or defer to one you already have running and leave it under your control.
  - The local server path is guarded by the same transport policy used by other local providers.
* **Gemini 3.5 Transcribe (Cloud, opt-in)**:
  - Cloud transcription that handles disfluency removal, self-correction collapse, punctuation, and formatting natively in a single pass.
  - Requires a Google API key that you supply; it is held in the login keychain. With no key stored, Gemini remains selected and dictation fails closed with an actionable credential prompt rather than silently changing providers.

### 2. Jot Inspirations & Thought-Revision Polish
Inspired by Google Gemini's [Jot](https://github.com/google-gemini/jot-gemini-transcribe-macOS), DevType runs post-processing speech intelligence:
* **Thought Revisions & Self-Corrections**:
  - Automatically resolves mid-sentence corrections (e.g. *"Let's meet at 1:00 PM... actually, make it 2:00 PM"* $\to$ *"Let's meet at 2:00 PM"*).
* **Disfluency & Filler Stripping**:
  - Strips verbal hesitations (*"um"*, *"uh"*, *"er"*, *"ah"*, *"like"*, *"you know"*), Korean fillers (*"음"*, *"어"*, *"그"*), and Japanese fillers (*"えーと"*, *"あの"*, *"うーん"*).
* **Custom Vocabulary & Jargon**:
  - Dynamic phonetic replacement dictionary mapping spoken phrases to exact camelCase or custom brand casing (e.g., *"dev type"* $\to$ `DevType`, *"next js"* $\to$ `Next.js`).
* **Multi-Register Tone Styling**:
  - **Natural**: Balanced conversational register with polished punctuation.
  - **Email**: Professional register with formal sentence structuring.
  - **Chat**: Casual, modern chat messaging style with contractions.
  - **Code**: Automatic identifier and operator formatting (e.g. *"user profile manager"* $\to$ `userProfileManager`, *"fat arrow"* $\to$ `=>`, *"strict equal"* $\to$ `===`, *"constant case api url"* $\to$ `API_URL`).
  - **Verbatim**: Exact transcription without styling.

### 3. What Happens While You Speak

Recognizing speech and typing it into your document are separate decisions, chosen in
**Preferences → Voice → "While you speak"**:

* **Type into the document as I speak** (default) — recognized words are typed progressively and
  reconciled against the corrected transcript when the session ends. Fastest to read back, but the
  document is rewritten under the caret mid-sentence.
* **Show words in the bubble, insert at the end** — the dictation HUD shows the running transcript
  while your document is left untouched; the finished, proofread text arrives in a single insertion.
* **Show nothing, insert at the end** — no live recognition at all. The HUD shows only that it is
  listening, and the finished text arrives in one insertion. This is the only mode that does not
  need the Speech Recognition grant for a preview.

Insertion is automatic in every mode — there is no confirm step. Delivery goes through
`TextInjectionPipeline`, which writes via the Accessibility API and a synthetic paste, snapshotting
and restoring your clipboard around it. The one exception is a password field under macOS Secure
Input, where a synthetic paste can be dropped; DevType holds the text on the clipboard longer there
so you can paste it yourself.

Whatever the mode, a finished transcript may only *replace* on-screen dictated text while it stays
inside the same deletion ceiling the correction policy declares (`maxDeletionRatio`). A transcript
that accounts for materially less than what you can see is refused, and the words already on screen
are kept — losing formatting is recoverable, losing the sentences is not.

### 4. Hardened Audio Pipeline & Crash Journaling
* **Audio Interruption Resilience**: Listens to `AVAudioEngineConfigurationChange` to handle headphones / AirPods switching without dropped taps or leaks.
* **Millisecond-1 Audio Journaling**: 16kHz mono 16-bit PCM capture written continuously to `capture.caf` in a per-session directory under `~/Library/Application Support/DevType/VoiceSessions/`, so a crash mid-sentence leaves a recoverable recording rather than nothing.
* **Single-Shot Watchdog Transcription**: Each session is armed with a watchdog sized from the snapshot it started with (the configured local-model timeout plus headroom, never under 5 seconds), so a wedged recognizer or corrector ends the session instead of stalling dictation.

### 5. Voice Dictation HUD (`VoiceHUDPanel`)
* Floating non-activating AppKit HUD that never steals key focus from the target field:
  - **Legible Liquid Glass on macOS 26+**: runtime `NSGlassEffectView` regular style with a restrained crimson tint; `NSVisualEffectView` material fallback with a crimson hairline on older macOS.
  - **Minimal content hierarchy**: one small SF Symbol/status line and the live transcript — no duplicate title, badge, cursor, or decorative waveform row.
  - **Inset organic silhouette**: DevType-owned Bezier geometry (`LiquidBlobGeometry`) that stays inside the panel bounds and breathes subtly with live mic RMS.
  - **Transcript-driven expansion**: the transparent surface eases wider and then taller as live STT tokens arrive (coalesced, not one animation per token), capped at 500×188 points.
  - **Compact fluid metering**: an original two-harmonic meter shares the status line (Apple does not ship Siri orb / Liquid Glass shader assets for application embedding).
  - **Fast transient motion**: 140 ms entrance/exit fades; successful insertions hold for 750 ms while errors retain a longer 2 s reading window.
  - **Accessibility**: Reduce Transparency → solid fill; Reduce Motion → frozen silhouette; localized status strings and live accessibility values.

---

## ⌨️ Shortcuts & Hotkey Controls

* **Global Push-to-Talk / Toggle**: Default `⌘⌥V` (configurable in **Preferences $\to$ Voice**).
* **Command Palette**: Type `> voice` or `voice` in Inline Search (`⌘/`) to trigger smart dictation.
* **Status Bar Menu**: Quick access via the menu bar icon $\to$ **Smart Dictation (Voice)**.

---

## 🔒 Privacy & Security

* **Local by default**: With **Apple Speech**, **Local AI**, or **Local Whisper** selected, no audio leaves your Mac — Apple Speech and Local AI recognize on-device, and Local Whisper talks only to a `whisper.cpp` server on loopback. Local AI additionally sends the *recognized text* (never the audio) to your local model endpoint.
* **Cloud requires two explicit choices**: **Gemini 3.5 Transcribe** is the one engine that uploads audio, to Google. It remains inert until you both store your own API key in the login keychain and grant the separate cloud-audio consent in Preferences. If either prerequisite is missing, DevType refuses before capture rather than silently changing providers or routes.
* **Routes are enforced, not merely documented**: every session is stamped with the privacy route its engine implies (`onDeviceOnly`, `localNetworkOnly`, `cloudPermitted`), and the speech provider registry will not hand back a provider whose own route that session does not permit.

---

## 🤝 Acknowledgement

Special appreciation to the Google Gemini team for [Jot (`jot-gemini-transcribe-macOS`)](https://github.com/google-gemini/jot-gemini-transcribe-macOS), which pioneered thought-revision handling and millisecond-1 audio journaling on macOS.
