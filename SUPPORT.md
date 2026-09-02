# Support & Community Guide

Welcome to the DevType support guide. Whether you are encountering an issue, have an idea for a feature, or want to learn how to get the most out of DevType, we are here to help!

---

## 📚 Documentation & Self-Help

Before submitting an issue, please check our documentation resources:

- **[User Guide](docs/USER_GUIDE.md)**: Complete guide to using DevType, creating snippets, using AI features, Smart Dictation, and managing shortcuts.
- **[Voice Dictation Guide](docs/VOICE_DICTATION.md)**: Details on Smart Voice Dictation, speech engines, and thought-revision processing.
- **[Macro Reference](docs/MACRO_REFERENCE.md)**: Syntax reference for Mustache tags (`{{date}}`, `{{calc}}`, `{{clipboard}}`) and TextExpander tokens (`%filltext%`, `%|`, `%date%`).
- **[Permissions Guide](docs/PERMISSIONS_GUIDE.md)**: Resolving macOS Input Monitoring and Accessibility permission issues.
- **[Secret Snippets Guide](SECRETS.md)**: Details on Touch ID protected secret snippets and password storage.
- **[Architecture & Internals](docs/ARCHITECTURE.md)**: Deep dive into the internal engineering of DevType.

---

## ❓ Frequently Asked Questions (FAQ)

### 1. Snippets are not expanding when I type. What should I do?
1. Press **`⌘⇧P`** (or choose **Permission Recovery** from the menu bar) to see the live status of Accessibility and Input Monitoring with one-click fixes.
2. Check the menu-bar status. A pause indicator means expansion is paused. A key with **Copy Secret** means macOS Secure Input is active: click it to open Search Secrets, choose a saved secret, then paste with `⌘V` in the password field. Right-click or Control-click the button for the full menu. Typed triggers stay paused there.
3. Ensure the active application is not in your **Muted Apps** list.
4. Try typing in standard macOS applications like TextEdit or Notes to verify system-level expansion.
5. Check **Last inject** in the diagnostic report. An **Erase precondition failed** message means the replacement reached its safety check; resetting permissions does not address the reported text/cursor disagreement. In v0.1.4, a zero or near-zero reported cursor can recover through keyboard deletion and paste when the trigger is found and no selection is reported.
6. If the report says **input or target application changed**, place the cursor in the intended field and retype the trigger. DevType cancels instead of erasing or replaying a key into a changed target.
7. If the diagnostic report identifies a permission failure, follow the [Permissions Guide](docs/PERMISSIONS_GUIDE.md). For an erase refusal, include the target app and the diagnostic report with the bug report. `expectedTextInScan` records whether the trigger was found; `scan=caretWindow` means only part of a large field was searched.

### 2. How do I trigger On-Device AI text transforms?
Select any text in any macOS app and press **`⌘⌥A`** (Command + Option + A). You can also type assigned trigger abbreviations (e.g. `:fix`, `:rw`) when configured in **Preferences → AI**. Note that on-device Apple Foundation Models require macOS 26+, while **Remove Markdown** runs offline locally on all supported macOS versions (macOS 14+).

### 3. How do I use Smart Voice Dictation?
Press or hold **`⌘⌥V`** to activate push-to-talk or toggle dictation. You can configure your speech recognition engine (Apple Speech, Local AI, Local Whisper, or Gemini) and custom vocabulary under **Preferences → Voice**.

### 4. How do I migrate my snippets from TextExpander or Espanso?
Open the DevType menu bar icon and choose **Import Snippets…** (or go to Preferences → Snippets), then select your TextExpander settings bundle (`.textexpandersettings` / `.textexpanderbackup`) or an Espanso config folder / match YAML file. Your library can be exported again as DevType JSON, Espanso YAML, or CSV via **Export…**.

---

## 🐛 Reporting Bugs

If you find a bug:
1. Search existing [GitHub Issues](https://github.com/bharathvbcr/DevType/issues) to see if it has already been reported.
2. If not, open a new issue using our [Bug Report Form](.github/ISSUE_TEMPLATE/bug_report.yml).
3. Include your macOS version, DevType version, the application where the bug occurred, and reproduction steps.

---

## 💡 Requesting Features

Have an idea to make DevType better?
1. Check existing issues or discussions to see if a similar request exists.
2. Open a feature request using our [Feature Request Form](.github/ISSUE_TEMPLATE/feature_request.yml).
3. Explain your use case, the proposed behavior, and why it benefits users.

---

## 💬 Community Discussions & Questions

For open-ended discussions, sharing snippet libraries, or general questions:
- Use [GitHub Discussions](https://github.com/bharathvbcr/DevType/discussions) on the repository.
- Join conversations on best practices, macro formulas, and workflow optimizations.

---

## 🔒 Security Vulnerabilities

For security-sensitive issues or vulnerability reports, please follow our [Security Policy](SECURITY.md) and do not post sensitive details in public issues.
