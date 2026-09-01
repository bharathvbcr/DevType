# DevType User Guide

Welcome to the comprehensive user manual for **DevType** — the fast, native macOS text expander and on-device AI writing assistant.

---

## 📑 Table of Contents
1. [Installation & First Launch](#1-installation--first-launch)
2. [Permissions Setup](#2-permissions-setup)
3. [Creating & Managing Snippets](#3-creating--managing-snippets)
4. [Using Dynamic Macros & Templates](#4-using-dynamic-macros--templates)
5. [On-Device AI Assistant (macOS 26+)](#5-on-device-ai-assistant-macos-26)
6. [Smart Voice Dictation (`⌘⌥V`)](#6-smart-voice-dictation-v)
7. [Fuzzy Command Palette (`⌘/`)](#7-fuzzy-command-palette-)
8. [Secret Snippets & Touch ID](#8-secret-snippets--touch-id)
9. [Importing & Exporting Libraries](#9-importing--exporting-libraries)
10. [Preferences & Customization](#10-preferences--customization)
11. [Troubleshooting & FAQs](#11-troubleshooting--faqs)

---

## 1. Installation & First Launch

### Download Release
1. Download the latest `.dmg` from the [GitHub Releases Page](https://github.com/bharathvbcr/DevType/releases/latest).
2. Open the disk image and drag **DevType.app** to your `/Applications` folder.
3. Launch DevType from `/Applications` or Spotlight (`⌘Space`).

---

## 2. Permissions Setup

When you first launch DevType, the **Permissions Setup Wizard** will guide you through granting two standard macOS privacy permissions:

1. **Accessibility**: Allows DevType to perform fast, non-intrusive text replacement directly inside your active application.
2. **Input Monitoring**: Enables DevType to listen for your typed snippet triggers and swallow the trigger characters.

> [!TIP]
> For a detailed guide and troubleshooting tips for permissions, see the [Permissions Guide](PERMISSIONS_GUIDE.md).

---

## 3. Creating & Managing Snippets

### Opening the Snippet Manager
Click the **DevType icon** in your macOS menu bar and select **Snippet Manager…** (or press `⌘⇧M`).

### Creating a New Snippet
1. Click the **`+`** button in the bottom toolbar.
2. **Label / Title**: A descriptive name (e.g. `Work Email Signature`).
3. **Trigger / Abbreviation**: The keyword you type to activate the snippet (e.g. `;sig` or `:email`).
4. **Snippet Content**: The replacement text.

### Snippet Types
- **Plain Text**: Standard text expansion.
- **Dynamic Template**: Text containing Mustache (`{{...}}`) or TextExpander (`%...%`) macro tags.
- **Image Snippets**: Paste a rich image directly from a trigger keyword.
- **Secret Snippets**: Passwords and sensitive keys stored in AES-GCM encrypted storage behind Touch ID.
- **AI Action Snippets**: Triggers that run an on-device AI transform over your current text selection (created from the built-in template catalog or the editor).

---

## 4. Using Dynamic Macros & Templates

DevType supports rich dynamic macros. You can mix and match Mustache tags or TextExpander syntax:

### Date & Time
- `{{date}}`: Inserts today's date in your system locale.
- `{{date:yyyy-MM-dd}}`: Custom date pattern (e.g. `2026-08-16`).
- `{{date:us}}` / `{{date:iso}}`: Preset formatting.
- `{{date:iso:+1d}}` / `%@+1D%`: Date arithmetic — offset by days, weeks, months, hours, and more.
- `{{time}}`: Current time.

### Dynamic Clipboard & Caret
- `{{clipboard}}` / `%clipboard`: Injects the text currently on your macOS clipboard (sanitized so clipboard content can't fire further macros).
- `{{cursor}}` or `%|`: Places your text insertion caret right at that position after expanding.
- `{{snippet:other_trigger}}` / `%snippet:other_trigger%`: Re-uses content from another snippet dynamically.

### Safe Inline Calculations
- `{{calc: 15 * 4}}` → `60`
- `{{calc: (1200 / 12) + 8}}` → `108`

### Generated Values
- `{{uuid}}`, `{{random:1-100}}`, `{{random:hex:8}}`: Fresh values on every expansion.
- `{{counter:name}}` / `%counter:name%`: Persistent counters that bump on each expansion (optional step, e.g. `%counter:tickets:+5%`).

### Case Transforms
- `{{upper:…}}` / `{{lower:…}}` / `{{title:…}}` / `{{sentence:…}}`
- TextExpander block form: `%case:upper% … %caseend%`.

### Interactive Fill-in Fields
Need to prompt yourself for a variable before inserting? Use TextExpander fill-in tags:
```text
Hi %filltext:name=Client Name%,

Thank you for reaching out regarding %filltext:name=Project%. We will follow up by %date:full%.

Best,
Alex
```
When you type the trigger, a sleek popup dialog will prompt you for the field values before expanding! Multi-line (`%fillarea%`), drop-down (`%fillpopup%`), and optional sections (`%fillpart%…%fillpartend%`) are supported too.

For the full list of tags and modifiers, see the [Macro Reference Guide](MACRO_REFERENCE.md).

---

## 5. On-Device AI Assistant (macOS 26+)

DevType comes with private, on-device AI writing tools powered by Apple Foundation Models, alongside local offline text tools:

1. **Highlight Text** in any application.
2. Press **`⌘⌥A`** (Command + Option + A).
3. Choose an Action:
   - ✍️ **Proofread**: Fix grammar, punctuation, and typos directly in place.
   - 🔄 **Rewrite** / 🗣️ **Paraphrase**: Polish text for clarity, flow, or fresh wording.
   - 📈 **Expand** / 📉 **Condense**: Elaborate on ideas or tighten text while preserving meaning.
   - 👔 **Tone Shift**: Make text more *Formal* or *Friendly*.
   - 📋 **Bulletize**: Transform paragraph text into clean bullet points.
   - 💡 **Prompt Enhance**: Rewrite a draft into a sharper LLM prompt.
   - 🧑‍💻 **Code Engineering**:
     - **Explain Code**: Algorithmic and logic breakdown.
     - **Docstring Generator**: Generate language-idiomatic doc comments (SwiftDoc, JSDoc, PyDoc, RustDoc).
     - **Fix Code**: Detect and repair logic bugs and syntax issues.
     - **Unit Test Generator**: Comprehensive unit tests for your code.
     - **Explain Regex**: Plain-English token-by-token regular expression explanation.
     - **SQL Query Generator**: Generate optimized SQL queries from natural language requests.
   - 📦 **Git Commit Message**: Conventional commit summaries (`feat:`, `fix:`, `refactor:`) from diffs.
   - 🗂️ **JSON Converter**: Convert lists, tables, or unformatted data into clean JSON.
   - 🌐 **Translate**: To English from romanized Telugu/Hindi (or native script), or English → romanized Telugu / Hindi.
   - 📝 **Markdown Tools**:
     - **Convert to Markdown**: Format plain text into clean Markdown headings, lists, and code blocks.
     - **Remove Markdown** *(Offline on macOS 14+)*: Strip Markdown formatting into clean plain prose locally without requiring an AI model.
   - ⌨️ **Custom Prompt**: Type your own instruction (e.g. `> Translate to Spanish`) — also available directly from the Command Palette with a `>` prefix.

### Live Diff Preview
Proofread and Remove Markdown replace in place by default; every other action streams into a preview panel showing the result (with diff view). Press `Enter` to accept, `Esc` to discard, or use Retry to re-roll the result. Per-action delivery can be switched between direct replace and preview under **Preferences → AI**, and **Undo last AI** at the top of the Command Palette reverts the most recent transform.

---

## 6. Smart Voice Dictation (`⌘⌥V`)

DevType includes local-first, privacy-respecting speech-to-text dictation with thought-revision processing inspired by Google Gemini Jot:

- **Push-to-Talk or Toggle**: Press or hold **`⌘⌥V`** to dictate into whatever application has focus.
- **Selectable Recognizers** in **Preferences → Voice**:
  - 🍎 **Apple Speech**: Fully on-device `SFSpeechRecognizer` with deterministic formatting. Zero configuration.
  - 🧠 **Local AI**: On-device Apple Speech recognition polished by local Apple Intelligence Foundation Models (macOS 26+) or a local HTTP endpoint (Ollama / llama.cpp).
  - ⚡ **Local Whisper**: Talks to a local `whisper.cpp` server on loopback (`http://127.0.0.1:8080/inference`). Fully offline and detects or installs models seamlessly.
  - ☁️ **Gemini 3.5 Transcribe**: Opt-in cloud engine with native disfluency and punctuation handling. Inert until you store your own API key in your login Keychain.
- **Thought-Revision & Smart Polish**: Automatically handles mid-sentence self-corrections ("tomorrow at 3... actually make that 4 PM"), removes verbal fillers (*"um"*, *"uh"*, *"like"*), and applies custom vocabulary.
- **Multi-Register Tone**: Style transcripts for *Natural*, *Email*, *Chat*, *Code* (identifier formatting), or *Verbatim*.
- **Liquid Glass HUD**: Non-activating floating HUD using Apple Liquid Glass (`NSGlassEffectView`) on macOS 26+ (with `NSVisualEffectView` fallback on earlier systems) that meters microphone levels and streams live partial transcripts without stealing keyboard focus.

For complete voice architecture details, see [docs/VOICE_DICTATION.md](VOICE_DICTATION.md).

---

## 7. Fuzzy Command Palette (`⌘/`)

Press **`⌘/`** anywhere in macOS to bring up DevType's unified Command Palette:

- **Search Snippets**: Type fuzzy keywords to find and insert snippets without remembering abbreviations. Results highlight matches, honor diacritics, and are ranked by how often (and how recently) *you* use them — the top rows show `⌘1`–`⌘9` quick-insert hints.
- **Math Calculator**: Type `= 45 * 12.5` to evaluate inline and insert or copy the result.
- **Custom AI**: Type `> make this sound like a Slack message` to run a one-shot on-device AI instruction over your current selection.
- **Date Offsets & Tools**: Type `tomorrow`, `date+7`, `+3w`, `next friday`, or `epoch` to insert calculated dates; ISO and full formats included.
- **Clipboard Tools**: Insert the current clipboard contents as text, or run a live character/word/line count preview.
- **Text Operations**: UPPERCASE, lowercase, Title Case, Sentence case, sort/dedupe/trim/number lines, Base64 / URL / HTML encode–decode, JSON pretty/compact, SHA-256 and MD5 digests.
- **Generators**: UUIDs, lorem ipsum, and strong random passwords.
- **Quick Navigation**: Jump straight to Preferences, the Snippet Manager, or the Permission Recovery window.

---

## 8. Secret Snippets & Touch ID

Need to store passwords, API keys, or recovery codes?
1. Open the Snippet Manager (`⌘⇧M`) and mark the snippet as **Secret**.
2. DevType encrypts the snippet with **AES-GCM** into a sealed archive; the single master key lives in your macOS Keychain.
3. Secrets **never** expand from typed triggers (preventing accidental disclosure in chat windows or screen shares).
4. Access secrets via the menu bar (**Copy Secret ▸**) or **Search Secrets…** in the same submenu.
5. DevType prompts for **Touch ID** (password fallback available; one check covers 30 seconds of back-to-back copies), copies the secret to the clipboard with concealment flags (hiding it from clipboard managers), and auto-clears the clipboard after 90 seconds.
6. The Touch ID gate itself can be toggled under **Preferences → Snippets → Secrets** or from the bottom of the **Copy Secret** menu.

---

## 9. Importing & Exporting Libraries

Easily migrate your entire snippet library:
1. In DevType, open the menu bar icon and choose **Import Snippets…** (or use the button in Preferences → Snippets).
2. Select your export file or folder:
   - **TextExpander**: a settings bundle (`.textexpandersettings`) or backup (`.textexpanderbackup`) — DevType auto-detects common sync locations.
   - **Espanso**: a config folder, `match` directory, package, or any `.yml` match file.
3. DevType automatically translates triggers, macro tags, image attachments (`image_path`), per-app filters, and case propagation. Unsupported constructs are reported cleanly rather than silently dropped.

### Exporting
Use **Export…** in the menu bar (or Preferences → Snippets) to save your library as:
- **DevType JSON**: Full-fidelity backup preserving all settings and groups.
- **Espanso YAML**: Standard YAML configuration compatible with Espanso.
- **CSV**: Spreadsheet-friendly export with columns for title, trigger, replacement, and group.

Secret snippet *values* are structurally excluded from every export — at most an empty placeholder appears.

---

## 10. Preferences & Customization

Open **DevType Preferences** from the menu bar or press **`⌘,`**. The window features 7 dedicated tabs:

1. 🏠 **Home**: First-class getting started dashboard displaying engine status, quick actions (New Snippet, Templates, Import), live scratchpad test field, active shortcuts summary, and top/recent snippets.
2. ⚙️ **General**: Startup settings (Launch at login), application language (System, English, 한국어, 日本語), opt-in update check (at most once a day, zero telemetry), and the **Muted Apps** list (apps where DevType pauses expansion).
3. 📚 **Snippets**: Secret snippets security configuration (Touch ID requirement), library storage path, import/export buttons, trigger-conflict detection, and detailed usage statistics.
4. ⌨️ **Hotkeys**: Customizable shortcut recorders for Command Palette (`⌘/`), AI Action Palette (`⌘⌥A`), Smart Dictation (`⌘⌥V`), and hotkey macro actions.
5. 🎙️ **Voice**: Speech engine selector (Apple Speech, Local AI, Local Whisper, Gemini) with live readiness indicators, prompt tone styles, real-time typing options, custom phonetic vocabulary dictionary, voice action triggers, and microphone permissions.
6. ✨ **AI** (macOS 26+): Enable on-device transforms, configure per-action output delivery (direct replace vs diff preview), manage application allowlists, and toggle optional semantic search routing.
7. 🔧 **Advanced**: Engine options including dedicated event-tap thread toggle, memory logging, live diagnostic readout, and maintenance actions.

Muted apps are also reachable straight from the menu bar (**Mute Frontmost App**, **Muted Apps…**).

---

## 11. Troubleshooting & FAQs

- **Text is not expanding**: Verify permissions under **Preferences → Home** or press **`⌘⇧P`** to open Permission Recovery.
- **Accidental expansion in games or terminals**: Add the app to your **Muted Apps** list in Preferences → General or choose **Mute Frontmost App** from the menu bar.
- **Shortcut conflicts**: Re-record your global hotkeys in **Preferences → Hotkeys**.
- **Need help?**: Check our [Support Guide](../SUPPORT.md) or open an issue on GitHub.
