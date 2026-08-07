<p align="center">
  <img src="docs/assets/devtype_logo.png" alt="DevType Logo" width="128" height="128">
</p>

<h1 align="center">DevType</h1>

<p align="center">
  <strong>Native macOS Text Expander & On-Device AI Writing Assistant</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014.0%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/language-Swift%205.9-orange" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/AI-Apple%20Foundation%20Models-purple" alt="Apple Intelligence">
  <img src="https://img.shields.io/badge/architecture-Native%20LSUIElement-green" alt="Native LSUIElement">
</p>

---

<p align="center">
  <img src="docs/assets/devtype_social_preview.jpg" alt="DevType Social Preview" width="100%">
</p>

**DevType** is a high-performance, native macOS menu-bar text expander (`LSUIElement` accessory app) equipped with on-device AI text transformations powered by Apple Foundation Models. Designed for developers, writers, and power users, DevType delivers instant expand-on-match typing automation alongside intelligent text manipulation without sending a single byte of your data to the cloud.

---

## ✨ Features

- ⚡ **Instant Expand-on-Match**: Low-latency swallowing ring buffer that instantly replaces typed triggers using Accessibility range replacement (with fallback to HID clipboard paste).
- 🤖 **On-Device AI Transforms**: Built-in AI text actions (proofread, rewrite, paraphrase, expand, condense, tone shift, bulletize) using Apple Foundation Models (macOS 26+). 100% private, zero API keys required.
- 🔍 **Hybrid Command Palette** (`⌘/`): Lightning-fast fuzzy search for snippets, AI tools, date/time offsets, clipboard history, and quick app navigation.
- 🧩 **Dual Macro Engine**: Full support for both Mustache (`{{date:iso}}`, `{{clipboard}}`, `{{calc: 1+2}}`, `{{cursor}}`) and TextExpander (`%filltext:name=X%`, `%date:us%`, `%|`, `%key:enter%`) template syntaxes.
- 🖼️ **Rich Attachments**: Paste images directly from snippet triggers with full Espanso `image_path` import support.
- 📦 **Format Importers**: One-click import from TextExpander 4/5 XML groups and Espanso YAML match configs.
- 🛡️ **Privacy & Fail-Closed Security**: Automatic expansion pause during password entry (`NSSecureTextField`), Secure Event Input locks, IME composition, or in muted apps.
- 🔑 **Stable Identity TCC**: Packaged `.app` bundle with dedicated self-signed code identity (`com.devtype.app`) so macOS Accessibility & Input Monitoring permissions persist cleanly across updates.

---

## 🚀 Quick Start & Building

### Prerequisites
- macOS 14.0 or later (macOS 26+ required for Apple Intelligence AI features)
- Xcode 15+ or Swift 5.9+ Command Line Tools installed

### Build and Install

```bash
# 1. One-time setup: Create a stable local signing certificate so TCC grants survive rebuilds
./Scripts/make-signing-cert.sh

# 2. Build and package the application bundle (.build/DevType.app)
./Scripts/package-app.sh release

# 3. Install to /Applications (Preferred for stable TCC grants & login item management)
./Scripts/install-app.sh
open /Applications/DevType.app
```

> **Note on Signing & Permissions:**
> Running raw `swift build` produces a bare Mach-O binary that churns CDHash on every build, resetting macOS TCC permissions. Always use `./Scripts/install-app.sh` to install to `/Applications/DevType.app`.

---

## 🔐 Capability Matrix & TCC Permissions

DevType separates permission requirements cleanly to uphold macOS privacy boundaries.

| Capability | TCC Service | API Preflight | Required Role |
|---|---|---|---|
| **Input Monitoring** | `ListenEvent` | `CGPreflightListenEventAccess` | **Required** to create event tap for swallowing trigger keys |
| **Accessibility** | `Accessibility` | `AXIsProcessTrustedWithOptions` | **Required** for event tap swallowing & AX range text replacement |
| **Post Events** | `PostEvent` | `CGPreflightPostEventAccess` | *Optional* for HID backspace, `⌘V` paste, and arrow caret movement |

### Permission Setup Flow
1. Launch DevType and complete the **Setup Wizard** (or press `⌘⇧P` for **Permission Recovery**).
2. Click **Request** to trigger native macOS permission prompts.
3. If permissions remain denied, click **Open Settings** to enable DevType in `System Settings → Privacy & Security`.

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

## 🧪 Verification & Smoke Checklist

1. Run `./Scripts/install-app.sh` and launch `/Applications/DevType.app`.
2. Complete Setup Wizard or open **Permission Recovery** (`⌘⇧P`).
3. Ensure menu status displays **Active** once Input Monitoring & Accessibility are granted.
4. Open the in-app **Test Expansion** lab (`⌘⇧P` → *Test Expansion*) to test live injection.
5. Try typing `:test` (or your saved triggers) in TextEdit, Notes, or your code editor of choice.

---

## 📄 License & Attribution

DevType is licensed under the MIT License. See [NOTICE](NOTICE) forSnipKey Kit component attributions.
