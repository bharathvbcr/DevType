# Contributing to DevType

Thank you for your interest in contributing to **DevType**! DevType is a fast, native macOS text expander and on-device AI assistant built with Swift and AppKit. We are committed to maintaining a high standard of code quality, performance, rock-solid stability, and zero-telemetry privacy.

This guide provides everything you need to set up your development environment, understand the architecture, write tests, and submit contributions.

---

## 📜 Code of Conduct

By participating in this project, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md). Please read it to understand our community standards.

---

## 🛠️ Prerequisites & Setup

### Requirements

- **macOS 14.0 (Sonoma)** or later (macOS 26+ required for on-device Apple Foundation Models support).
- **Xcode 15.0+** (or Command Line Tools) with **Swift 5.9+**.
- Standard macOS developer utilities: `plutil`, `codesign`, `security`.

### 1. Clone the Repository

```bash
git clone https://github.com/bharathvbcr/DevType.git
cd DevType
```

### 2. Set Up Local Code Signing (Crucial for TCC Grants)

macOS TCC (Transparency, Consent, and Control) ties Accessibility and Input Monitoring permissions to code signing identities. If you build with ad-hoc signing, your permissions may be invalidated every time you recompile.

The build resolves an identity for you — check what it will use:

```bash
./Scripts/signing-identity.sh
```

**If you have an Apple ID, prefer an Apple Development certificate** (a free Apple ID is enough): in Xcode, **Settings → Accounts → Manage Certificates → + → Apple Development**. The build finds it automatically, and it gives keychain items a stable `teamid:` partition that the self-signed fallback cannot.

Otherwise, generate the self-signed fallback:

```bash
./Scripts/make-signing-cert.sh
```

This creates a certificate named `DevType Local Signing` in your login keychain. Either way, your TCC grants persist across rebuilds. See [docs/PERMISSIONS_GUIDE.md](docs/PERMISSIONS_GUIDE.md) for the full resolution order.

### 3. Build & Run Tests

```bash
# Run headless unit test suite
./Scripts/test.sh

# Run full local CI pipeline (checks syntax, plists, tests, and builds release bundle)
./Scripts/ci-local.sh
```

---

## 🏗️ Repository Architecture

The project is organized into modular SwiftPM targets:

```
DevType/
├── Sources/
│   ├── DevTypeApp/          # AppKit Application Layer (UI, Menus, Panels, ViewControllers)
│   │   ├── main.swift                     # App entry point
│   │   ├── AppDelegate.swift              # App lifecycle, status item, menus
│   │   ├── SnippetManagerViewController   # Snippet editor and list view
│   │   ├── InlineSearchPanel.swift        # Command palette (⌘/)
│   │   ├── AIActionPanel.swift            # AI quick transform palette (⌘⌥A)
│   │   ├── AIPreviewPanel.swift           # AI diff and review overlay
│   │   ├── DevTypeTheme.swift             # UI theme tokens and styling
│   │   └── ...
│   │
│   ├── ExpanderEngine/      # Core Business Logic & Expansion Engine
│   │   ├── Engine/                        # CGEventTap, text injection, type-ahead buffer
│   │   ├── Matching/                      # Prefix tree, abbreviation matching, fuzzy search
│   │   ├── Macros/                        # Mustache & TextExpander parser, math evaluation
│   │   ├── AI/                            # Apple Foundation Models, selection gates
│   │   ├── Voice/                         # Smart Dictation engines, correction pipeline, crash journaling
│   │   ├── Models/                        # Snippet models, SecretStore, usage stats
│   │   ├── Permissions/                   # TCC checks, AX verification, recovery
│   │   └── Sync/                          # Import/export (TextExpander bundles, Espanso YAML), search, palette catalog
│   │
│   └── DevTypeSafety/       # Objective-C Runtime Exception Trampoline
│       └── include/DevTypeSafety.h        # @try/@catch wrappers for unsafe AppKit/AX calls
│
├── Tests/
│   └── ExpanderEngineTests/ # Headless unit tests, fuzz tests, stress tests
│
├── Scripts/                 # Build, test, packaging, and helper scripts
├── Resources/               # App icon, Info.plist, entitlements
└── docs/                    # Architectural guides, user guides, reference docs
```

For detailed component interaction, data flow diagrams, and safety contracts, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## 💻 Coding Standards & Best Practices

When writing code for DevType, please keep the following core principles in mind:

### 1. Zero Telemetry & Absolute Privacy
- **No network calls**: DevType is strictly 100% offline. Never add third-party analytics, network logging, or cloud telemetry SDKs.
- **Fail-Closed Security**: Never capture or process keystrokes during password entry (`NSSecureTextField`), Secure Event Input locks, or in muted applications.
- **Secrets Protection**: Secret snippets are AES-GCM encrypted and gated behind Touch ID. Never log secrets, leak them to clipboard history, or expose them in diagnostic exports.

### 2. Thread Safety & Concurrency
- **UI Safety**: All AppKit UI operations, windows, and panels MUST execute on `@MainActor`.
- **Low-Latency Event Tap**: Keystroke interception runs on dedicated threads (`TapRunLoopThread`). Operations in the event tap callback must never block or perform heavy I/O.
- **Atomic State Access**: Use `UnfairLock` (or Swift Actors where appropriate) to protect shared mutable state in `ExpanderEngine`.

### 3. Error Handling & AppKit Resilience
- macOS Accessibility APIs (`AXUIElement`) and Cocoa event taps can throw uncatchable Objective-C exceptions or return undocumented error codes.
- Use `DevTypeSafety`'s `@try/@catch` trampolines for risky AX and pasteboard calls.
- Always provide graceful fallbacks (e.g. falling back from AX text replacement to HID keystroke paste).

---

## 🧪 Testing & Verification

Every fix and feature must be accompanied by comprehensive unit tests.

### Running Tests Locally

```bash
# Run all unit tests
./Scripts/test.sh

# Run specific test suite
swift test --filter SecretSnippetTests

# Run full local validation suite
./Scripts/ci-local.sh
```

### Writing Headless Tests
All tests in `Tests/ExpanderEngineTests/` are designed to run in a headless environment without requiring active window server sessions or interactive TCC prompts.

- Mock system interactions where necessary (`SelectionReader`, `BiometricGate`, `PasteboardBroker`).
- Test edge cases: empty strings, surrogate pairs, unicode grapheme clusters, rapid typing, and stress cases.

---

## 🔄 Submitting a Pull Request

### Step 1: Create a Feature Branch
```bash
git checkout -b feature/my-new-feature
```

### Step 2: Make Changes & Test Thoroughly
- Implement your changes following project conventions.
- Add or update relevant tests.
- Verify everything passes: `./Scripts/ci-local.sh`.

### Step 3: Commit Conventions
We follow clear, descriptive commit messages. Use prefixes where applicable:
- `feat:` New feature or capability
- `fix:` Bug fix
- `docs:` Documentation improvements
- `perf:` Performance optimization
- `refactor:` Code restructuring without functional changes
- `test:` Adding or updating tests

### Step 4: Open a Pull Request
- Push your branch: `git push origin feature/my-new-feature`.
- Open a PR against the `main` branch.
- Fill out the PR template completely, referencing any related issues.
- Ensure all CI checks pass.

---

## 💬 Getting Help & Reporting Issues

- **Bug Reports**: Open an issue using the [Bug Report template](.github/ISSUE_TEMPLATE/bug_report.yml).
- **Feature Requests**: Open an issue using the [Feature Request template](.github/ISSUE_TEMPLATE/feature_request.yml).
- **Security Inquiries**: See [SECURITY.md](SECURITY.md) for vulnerability reporting.
- **General Questions**: See [SUPPORT.md](SUPPORT.md) or visit GitHub Discussions.

Thank you for helping make DevType the best native text expander for macOS!
