<p align="center">
  <img src="docs/assets/devtype_logo.png" alt="DevType macOS Text Expander Logo" width="128" height="128">
</p>

<h1 align="center">DevType</h1>

<p align="center">
  <strong>Native macOS Text Expander & On-Device AI Writing Assistant</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014.0%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/language-Swift%205.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/AI-Apple%20Foundation%20Models-purple" alt="Apple Intelligence">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="MIT License"></a>
</p>

---

<p align="center">
  <img src="docs/assets/devtype_social_preview.jpg" alt="DevType macOS Text Expander Social Preview Banner" width="100%">
</p>

**DevType** is a fast, lightweight, native macOS text expander and snippet manager built with Swift & AppKit. Equipped with on-device AI text transformations powered by Apple Foundation Models, DevType offers sub-millisecond keyword expansion and offline writing tools with zero cloud telemetry.

Looking for a **privacy-first TextExpander alternative** or an **Espanso GUI for Mac**? DevType combines instant expand-on-match typing automation with local AI proofreading, rewriting, and dynamic mustache/TextExpander macro rendering.

---

## ⚔️ Comparison: DevType vs. Other Mac Text Expanders

| Feature | **DevType** | **TextExpander** | **Espanso** | **Alfred Snippets** |
|---|:---:|:---:|:---:|:---:|
| **License** | **Free & MIT Open Source** | Subscription ($40+/yr) | Free (GPL) | Paid Powerpack |
| **Native macOS App** | ✅ Swift / AppKit | ❌ Electron / Web | ❌ Rust / Cross-platform | ✅ Native |
| **On-Device AI Transforms** | ✅ Apple Foundation Models | ❌ None | ❌ None | ❌ Cloud Extensions |
| **Mustache & TE Syntax** | ✅ Dual Engine | ⚠️ TE Only | ⚠️ Espanso YAML | ⚠️ Alfred Tags |
| **100% Offline & Private** | ✅ No Cloud Telemetry | ❌ Cloud Sync Mandatory | ✅ Offline | ✅ Offline |
| ** Espanso / TE Importers** | ✅ Built-in XML & YAML | ❌ Manual | ⚠️ Manual | ❌ Manual |
| **Command Palette (`⌘/`)** | ✅ Snippets, AI, Math, Dates | ❌ None | ❌ Search Only | ⚠️ Palette |

---

## ✨ Features

- ⚡ **Instant Expand-on-Match**: Low-latency swallowing ring buffer that instantly replaces typed triggers using Accessibility range replacement (with fallback to HID clipboard paste).
- 🤖 **On-Device AI Transforms**: Built-in AI text actions (proofread, rewrite, paraphrase, expand, condense, tone shift, bulletize) using Apple Foundation Models (macOS 26+). 100% private, zero API keys required.
- 🔍 **Hybrid Command Palette** (`⌘/`): Lightning-fast fuzzy search for snippets, AI tools, date/time offsets, clipboard history, and quick app navigation.
- 🧩 **Dual Macro Engine**: Full support for both Mustache (`{{date:iso}}`, `{{clipboard}}`, `{{calc: 1+2}}`, `{{cursor}}`) and TextExpander (`%filltext:name=X%`, `%date:us%`, `%|`, `%key:enter%`) template syntaxes.
- 🖼️ **Rich Image Snippets**: Paste images directly from snippet triggers with full Espanso `image_path` import support.
- 📦 **One-Click Importers**: Seamlessly import existing snippet libraries from TextExpander 4/5 XML groups and Espanso YAML match configs.
- 🛡️ **Privacy & Fail-Closed Security**: Automatic expansion pause during password entry (`NSSecureTextField`), Secure Event Input locks, IME composition, or in muted apps.
- 🔑 **Stable Identity TCC**: Packaged `.app` bundle with dedicated code identity (`com.devtype.app`) so macOS Accessibility & Input Monitoring permissions persist cleanly across updates.

---

## 🚀 Quick Start & Building

### Download Pre-built Release
Download the latest macOS disk image (`.dmg`) directly from the [DevType GitHub Releases Page](https://github.com/bharathvbcr/DevType/releases/latest).

### Building from Source

```bash
# 1. One-time setup: Create a stable local signing certificate so TCC grants survive rebuilds
./Scripts/make-signing-cert.sh

# 2. Build and package the application bundle (.build/DevType.app)
./Scripts/package-app.sh release

# 3. Install to /Applications (Preferred for stable TCC grants & login item management)
./Scripts/install-app.sh
open /Applications/DevType.app
```

---

## 🔐 Capability Matrix & TCC Permissions

DevType separates permission requirements cleanly to uphold macOS privacy boundaries.

| Capability | TCC Service | API Preflight | Required Role |
|---|---|---|---|
| **Input Monitoring** | `ListenEvent` | `CGPreflightListenEventAccess` | **Required** to create event tap for swallowing trigger keys |
| **Accessibility** | `Accessibility` | `AXIsProcessTrustedWithOptions` | **Required** for event tap swallowing & AX range text replacement |
| **Post Events** | `PostEvent` | `CGPreflightPostEventAccess` | *Optional* for HID backspace, `⌘V` paste, and arrow caret movement |

---

## 🤖 On-Device AI Transforms (macOS 26+)

Run Apple Foundation Models text transformations on-device with zero cloud telemetry.

- **Enable**: Go to **Preferences → AI** and turn on `Enable on-device AI transforms`.
- **Action Palette** (`⌘⌥A`): Highlight text in any application and press `⌘⌥A` to bring up the AI action menu.
- **Typed Triggers**: Assign AI actions directly to triggers (e.g. typing `:fix` or `:rw` over selected text automatically replaces or previews the transformed text).
- **Available Actions**: Proofread (Direct replace), Rewrite, Paraphrase, Expand, Condense, Tone Shift (Formal/Friendly), Bulletize, Prompt Enhance, and Freeform Prompting (`> custom prompt`).

---

## 🧩 Template Engine Reference

DevType parses Mustache `{{...}}` tags and TextExpander `%...%` tags seamlessly.

### Mustache (`{{...}}`)
| Tag | Description |
|---|---|
| `{{date}}` / `{{date:yyyy-MM-dd}}` | Insert current date (supports standard patterns or named presets like `us`, `iso`, `eu`) |
| `{{time}}` | Insert current time |
| `{{clipboard}}` | Insert current pasteboard text (read on-demand only) |
| `{{calc: 12 * 4}}` | Perform safe inline arithmetic evaluation |
| `{{cursor}}` | Position the caret after snippet expansion |
| `{{snippet:trigger_name}}` | Nest another snippet recursively (max depth 10) |

### TextExpander (`%...%`)
| Tag | Description |
|---|---|
| `%filltext:name=Field%` | Display fill-in dialog before expanding |
| `%date:FORMAT%` | Format date with `DateFormatter` pattern or preset (`%date:us%`, `%date:full%`) |
| `%clipboard` | Insert pasteboard text |
| `%|` | Position caret marker |
| `%key:enter%` / `%key:tab%` | Post trailing keystroke after injection |

---

## ❓ Frequently Asked Questions (FAQ)

### Is DevType free and open source?
Yes! DevType is completely free and open-source under the MIT License.

### Does DevType collect or send my keystrokes to the cloud?
No. DevType operates 100% offline. Keystrokes are processed locally in a memory ring buffer for matching triggers. When AI features are used, text is processed locally on-device via Apple Foundation Models without network requests.

### Can I import my existing snippets from TextExpander or Espanso?
Yes. DevType includes built-in importers for TextExpander 4/5 XML export files and Espanso YAML config files, preserving your triggers, replacements, and image attachments.

### How does DevType handle passwords and secure fields?
DevType automatically pauses keyword expansion whenever a secure text field (`NSSecureTextField`) is active or when macOS Secure Event Input is locked.

---

## 📄 License & Attribution

DevType is licensed under the [MIT License](LICENSE). See [NOTICE](NOTICE) for SnipKey Kit component attributions.
