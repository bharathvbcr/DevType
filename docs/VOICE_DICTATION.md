# Voice dictation

[Documentation](README.md) · [Permissions](PERMISSIONS_GUIDE.md) · [Privacy](../SECURITY.md)

Press `⌘⌥V` to use push-to-talk or toggle dictation. Configure the shortcut in **Preferences → Hotkeys** and choose the engine and delivery behavior in **Preferences → Voice**. Check readiness before starting: a selected engine is not necessarily ready to record or transcribe.

## Choose an engine

| Engine | Recognition and correction | Setup and data route |
|---|---|---|
| Apple Speech | On-device Apple recognition plus deterministic cleanup | Default. Needs microphone and Speech Recognition grants and a supported, ready locale |
| Local AI | Apple recognition, then local model correction | Prefers available Apple Foundation Models on macOS 26+; can use a configured loopback correction server |
| Local Whisper | A local `whisper.cpp` server plus deterministic cleanup | Needs an installed server and verified model; audio goes to the configured loopback endpoint |
| Gemini | Cloud transcription with built-in formatting, followed by local cleanup | Requires your API key and separate cloud-audio consent; audio and steering instructions go to Google |

On macOS 26+, Apple recognition prefers **SpeechAnalyzer** when its locale assets and service are ready. Older systems use the legacy `SFSpeechRecognizer` path with on-device recognition required. The registry can fall back to the legacy provider only after that provider independently reports ready. An unavailable cloud provider is refused rather than silently changing the selected route.

Speech assets may need installation. **Preferences → Voice** offers readiness and setup actions; checking readiness itself does not authorize a download. Local Whisper setup can download the pinned `base.en` model from Hugging Face. Once assets are installed, local recognition does not require an internet connection. A local server remains a separate process responsible for the data it receives.

The default Whisper endpoint is `http://127.0.0.1:8080/inference`. The default correction endpoint is `http://localhost:11434/v1/chat/completions`. DevType accepts loopback hosts only, rejects URL credentials and redirects, and bounds responses. Correction routing supports Ollama-native and OpenAI-compatible endpoints; a configured URL is not proof that a model is loaded.

## Decide when words arrive

**Preferences → Voice → While you speak** controls delivery separately from the recognizer:

| Mode | While recording | At the end |
|---|---|---|
| Type into the document as I speak | Inserts live words | Reconciles with the corrected transcript when safe |
| Show words in the bubble, insert at the end | Shows live words in the HUD | Inserts the finished text |
| Show nothing, insert at the end | Shows listening status without live recognition | Inserts the finished text |

Insertion is automatic; these modes do not add an approval step. Apple final transcription needs Speech Recognition permission. Gemini and Whisper also need that permission when using Apple live previews; the no-preview mode avoids that additional requirement.

Keep the intended document focused. Delivery rechecks the target and session before changing text. It can refuse when focus, selection, permissions, or the session changes. A final correction that would remove too much visible dictated text is refused so the existing words remain. If delivery is **posted, unverified**, inspect the destination before retrying: posting a paste is not proof that the editor accepted it.

## Correction and vocabulary

The correction pipeline supports filler cleanup, self-correction handling, custom vocabulary, and Natural, Email, Chat, Code, or Verbatim styling. Use vocabulary entries for names or identifiers that recognition repeatedly misses. Model output can still change meaning; review dictated text, especially names, numbers, and code.

Local AI captures the correction provider plan at session start. Apple Foundation Models can fall back through the configured local correction routes; deterministic cleanup remains a bounded fallback. Optional **proofread before insert** uses the on-device proofreading path on supported macOS versions. Verbatim mode bypasses model cleanup.

## Recordings and recovery

Audio is journaled to `capture.caf` inside a per-session folder at:

```text
~/Library/Application Support/DevType/VoiceSessions/
```

These local records can contain your voice and transcript. They support recovery when recording, transcription, or delivery is interrupted; local processing does not mean nothing is saved. Use the application's voice history/recovery controls to inspect saved sessions.

The session coordinator owns capture, recognition, correction, and delivery. Generation checks reject retired work; a watchdog bounds the overall session. Recovery writes use atomic replacement and size limits. A transcript existing on disk does not prove it reached the target app.

Detailed voice tracing is **off by default** and can include dictated text when enabled. Review local recordings and traces before sharing them. Ordinary diagnostic summaries use bounded, redacted outcomes; do not attach your entire application-support folder to a bug report.

## Troubleshooting

- **Not ready:** read the selected engine's reason in Voice preferences. Resolve its permission, asset, model, or endpoint requirement before recording again.
- **No microphone:** check the selected input device and Microphone grant; reconnecting headphones can change the active device.
- **Local server unavailable:** start the configured server and confirm its model is loaded. Readiness of the server and installation of its model are separate checks.
- **Cloud refuses before capture:** both the API key and the explicit cloud-audio consent must be present. Choosing Gemini alone grants neither.
- **Words did not arrive:** inspect the target, delivery outcome, and saved session before retrying. Refocus the intended field; avoid replaying an ambiguous paste.

See [Architecture](ARCHITECTURE.md) for lifecycle details and [Support](../SUPPORT.md) for reporting an issue. The workflow draws inspiration from [Google Gemini Jot](https://github.com/google-gemini/jot-gemini-transcribe-macOS).
