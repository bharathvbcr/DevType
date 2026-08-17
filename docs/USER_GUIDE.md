# DevType User Guide

Welcome to the comprehensive user manual for **DevType** — the fast, native macOS text expander and on-device AI writing assistant.

---

## 📑 Table of Contents
1. [Installation & First Launch](#1-installation--first-launch)
2. [Permissions Setup](#2-permissions-setup)
3. [Creating & Managing Snippets](#3-creating--managing-snippets)
4. [Using Dynamic Macros & Templates](#4-using-dynamic-macros--templates)
5. [On-Device AI Assistant (macOS 26+)](#5-on-device-ai-assistant-macos-26)
6. [Fuzzy Command Palette (`⌘/`)](#6-fuzzy-command-palette-)
7. [Secret Snippets & Touch ID](#7-secret-snippets--touch-id)
8. [Importing from TextExpander & Espanso](#8-importing-from-textexpander--espanso)
9. [Preferences & Customization](#9-preferences--customization)
10. [Troubleshooting & FAQs](#10-troubleshooting--faqs)

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
Click the **DevType icon** in your macOS menu bar and select **Snippet Manager…**, or press the global shortcut.

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

---

## 4. Using Dynamic Macros & Templates

DevType supports rich dynamic macros. You can mix and match Mustache tags or TextExpander syntax:

### Date & Time
- `{{date}}`: Inserts today's date in your system locale.
- `{{date:yyyy-MM-dd}}`: Custom date pattern (e.g. `2026-08-16`).
- `{{date:us}}` / `{{date:iso}}`: Preset formatting.
- `{{time}}`: Current time (e.g. `09:30 PM`).

### Dynamic Clipboard
- `{{clipboard}}`: Injects the text currently on your macOS clipboard.

### Safe Inline Calculations
- `{{calc: 15 * 4}}` → `60`
- `{{calc: (1200 / 12) * 1.08}}` → `108.0`

### Interactive Fill-in Fields
Need to prompt yourself for a variable before inserting? Use TextExpander fill-in tags:
```text
Hi %filltext:name=Client Name%,

Thank you for reaching out regarding %filltext:name=Project%. We will follow up by %date:full%.

Best,
Alex
```
When you type the trigger, a sleek popup dialog will prompt you for the field values before expanding!

### Caret Positioning & Nesting
- `{{cursor}}` or `%|`: Places your text insertion caret right at that position after expanding.
- `{{snippet:other_trigger}}`: Re-uses content from another snippet dynamically.

For the full list of tags and modifiers, see the [Macro Reference Guide](MACRO_REFERENCE.md).

---

## 5. On-Device AI Assistant (macOS 26+)

DevType comes with private, on-device AI writing tools powered by Apple Foundation Models:

1. **Highlight Text** in any application.
2. Press **`⌘⌥A`** (Command + Option + A).
3. Choose an AI Action:
   - ✍️ **Proofread**: Fix grammar, punctuation, and typos directly in place.
   - 🔄 **Rewrite**: Polish text for clarity and flow.
   - 📈 **Expand**: Elaborate on brief bullet points or ideas.
   - 📉 **Condense**: Shorten text while preserving key information.
   - 👔 **Tone Shift**: Make text more *Formal* or *Friendly*.
   - 📋 **Bulletize**: Transform paragraph text into clean bullet points.
   - 💡 **Custom Prompt**: Type your own instruction (e.g. `> Translate to Spanish`).

### Live Diff Preview
When using the AI Action panel, DevType displays a side-by-side or unified diff preview. Press `Enter` to accept or `Esc` to discard!

---

## 6. Fuzzy Command Palette (`⌘/`)

Press **`⌘/`** anywhere in macOS to bring up DevType's unified Command Palette:
- **Search Snippets**: Type fuzzy keywords to find and insert snippets without remembering abbreviations.
- **Math Calculator**: Type `= 45 * 12.5` to calculate and copy results instantly.
- **Date Offsets**: Type `tomorrow` or `+7d` to insert calculated dates.
- **Clipboard History**: Quickly recall recent clipboard items.

---

## 7. Secret Snippets & Touch ID

Need to store passwords, API keys, or recovery codes?
1. Open the Snippet Manager and mark the snippet as **Secret**.
2. DevType encrypts the snippet with **AES-GCM** using a master key kept in your macOS Keychain.
3. Secrets **never** expand from typed triggers (preventing accidental disclosure in chat windows or screen shares).
4. Access secrets via the menu bar (**Copy Secret ▸**) or the Command Palette.
5. DevType prompts for **Touch ID**, copies the secret to the clipboard with concealment flags (hiding it from clipboard managers), and auto-clears the clipboard after 90 seconds.

---

## 8. Importing from TextExpander & Espanso

Easily migrate your entire snippet library:
1. In DevType, go to **Preferences → Importers** or **File → Import Snippets…**.
2. Select your export file:
   - **TextExpander**: `.textexpander` or XML group files.
   - **Espanso**: `default.yml` or match YAML configurations.
3. DevType automatically translates triggers, macro tags, and image attachments.

---

## 9. Preferences & Customization

Under **DevType Preferences**:
- **General**: Toggle launch at login, menu bar icon visibility, and global shortcuts.
- **Expansion**: Configure trigger behavior, expansion latency, and sound effects.
- **Muted Apps**: Add sensitive applications (e.g. 1Password, Terminal, Banking apps) where DevType should automatically pause.
- **AI Settings**: Enable/disable on-device AI transforms and customize prompt templates.

---

## 10. Troubleshooting & FAQs

- **Text is not expanding**: Verify permissions under **Preferences → Permissions**.
- **Accidental expansion in games or terminals**: Add the app to your **Muted Apps** list.
- **Need help?**: Check our [Support Guide](../SUPPORT.md) or open an issue on GitHub.
