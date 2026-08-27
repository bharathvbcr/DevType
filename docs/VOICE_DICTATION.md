# Voice Smart Dictation in DevType

DevType integrates local, on-device Smart Speech-to-Text and Dictation powered by **Mistral Voxtral Realtime (Mini 4B)** and **Fun-ASR-Nano**, paired with Google Gemini **Jot**-inspired thought revision and disfluency resolution, rendered in a floating dictation HUD that adopts Apple **Liquid Glass** on macOS 26+ (`NSGlassEffectView`) with a material fallback below.

---

## 🎙️ Architecture & Features

### 1. Dual High-Accuracy Models
* **Mistral Voxtral Realtime (Mini 4B)**:
  - 4.2B parameter multimodal audio-LLM providing rich semantic understanding, high punctuation accuracy, and contextual disambiguation.
  - Formatted as `voxtral-mini-4b-realtime.q4_k_m.gguf` (~2.2 GB).
* **Fun-ASR-Nano (0.8B)**:
  - Ultra-fast edge speech recognition model optimized for Apple Silicon Neural Engine with extreme low latency and robust multi-dialect support.
  - Formatted as `funasr-nano-q8_0.gguf` (~820 MB).
* **Apple Speech Framework (Fallback / Offline Zero-Download)**:
  - Native system-level speech analyzer ensuring 100% immediate availability before weights are downloaded.

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

### 3. Hardened Audio Pipeline & Crash Journaling
* **Audio Interruption Resilience**: Listens to `AVAudioEngineConfigurationChange` to handle headphones / AirPods switching without dropped taps or leaks.
* **Millisecond-1 Audio Journaling**: 16kHz mono 16-bit PCM streaming audio capture with continuous disk journaling (`active_session_*.pcm`) in `~/Library/Application Support/DevType/VoiceCache/`.
* **Single-Shot Watchdog Transcription**: Guaranteed non-blocking transcription execution with a 12-second watchdog guard preventing system stalls.

### 4. Voice Dictation HUD (`VoiceHUDPanel`)
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

* **100% Local / On-Device**: All speech capture and transcription happens on your Apple Silicon Mac. Zero audio or transcripts leave your machine.
* **Zero Cloud Network Telemetry**: Models are downloaded directly from open-weight repositories into your local Application Support directory and verified via SHA-256 checksums.

---

## 🤝 Acknowledgement

Special appreciation to the Google Gemini team for [Jot (`jot-gemini-transcribe-macOS`)](https://github.com/google-gemini/jot-gemini-transcribe-macOS), which pioneered thought-revision handling and millisecond-1 audio journaling on macOS.
