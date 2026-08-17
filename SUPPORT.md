# Support & Community Guide

Welcome to the DevType support guide. Whether you are encountering an issue, have an idea for a feature, or want to learn how to get the most out of DevType, we are here to help!

---

## 📚 Documentation & Self-Help

Before submitting an issue, please check our documentation resources:

- **[User Guide](docs/USER_GUIDE.md)**: Complete guide to using DevType, creating snippets, using AI features, and managing shortcuts.
- **[Macro Reference](docs/MACRO_REFERENCE.md)**: Syntax reference for Mustache tags (`{{date}}`, `{{calc}}`, `{{clipboard}}`) and TextExpander tokens (`%filltext%`, `%|`, `%date%`).
- **[Permissions Guide](docs/PERMISSIONS_GUIDE.md)**: Resolving macOS Input Monitoring and Accessibility permission issues.
- **[Secret Snippets Guide](SECRETS.md)**: Details on Touch ID protected secret snippets and password storage.
- **[Architecture & Internals](docs/ARCHITECTURE.md)**: Deep dive into the internal engineering of DevType.

---

## ❓ Frequently Asked Questions (FAQ)

### 1. Snippets are not expanding when I type. What should I do?
1. Open **DevType Preferences → Permissions** to check your Accessibility and Input Monitoring status.
2. Verify that DevType is not paused (look for the pause indicator in the menu bar).
3. Ensure the active application is not in your **Muted Apps** list.
4. Try typing in standard macOS applications like TextEdit or Notes to verify system-level expansion.
5. If permissions appear granted in macOS System Settings but expansion still fails, see our [Permissions Guide](docs/PERMISSIONS_GUIDE.md) for steps on resetting the TCC cache.

### 2. How do I trigger On-Device AI text transforms?
Select any text in any macOS app and press **`⌘⌥A`** (Command + Option + A). You can also type assigned trigger abbreviations (e.g. `:fix`, `:rw`) when configured in **Preferences → AI**. Note that on-device AI requires macOS 26+ with Apple Foundation Models.

### 3. How do I migrate my snippets from TextExpander or Espanso?
Go to **DevType → Preferences → Importers** or use the menu bar option **File → Import Snippets…** and select your TextExpander XML group file or Espanso match YAML file.

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
