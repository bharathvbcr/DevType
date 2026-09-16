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
- **Full Xcode** with a Swift 5.9+ toolchain; use an SDK containing Foundation Models for the macOS 26 AI paths. The test wrapper selects full Xcode when available.
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

# Same suite plus coverage/lcov.info for GitPulse
./Scripts/test.sh --coverage

# Run full local CI pipeline (checks syntax, plists, tests, and builds release bundle)
./Scripts/ci-local.sh
```

---

## 🏗️ Repository Architecture

The project is organized into modular SwiftPM targets:

| Target / directory | Ownership |
|---|---|
| `Sources/DevTypeApp/` | Executable entry point (`main.swift`) |
| `Sources/DevTypeAppCore/` | AppDelegate, windows, menus, preferences, and panels |
| `Sources/ExpanderEngine/` | Matching, macros, injection, AI, voice, storage, and platform adapters |
| `Sources/DevTypeSafety/` | Objective-C window/KVC exception boundaries and legacy Keychain bridge |
| `Tests/ExpanderEngineTests/` | Engine behavior and isolated platform tests |
| `Tests/DevTypeAppTests/` | AppKit controller and application integration tests |
| `Scripts/` | Build, validation, packaging, and release commands |
| `docs/` | Current guides, versioned records, and static website |

For detailed component interaction, data flow diagrams, and safety contracts, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## 💻 Coding Standards & Best Practices

When writing code for DevType, please keep the following core principles in mind:

### 1. Zero Telemetry & Absolute Privacy
- **Zero telemetry, always**: never add analytics, network logging, crash reporting, or usage-tracking SDKs. There is no exception to this one, and no setting that turns it on.
- **Offline by default; network only when the user asks**: core expansion and deterministic tools work without the internet; speech assets and local models must first be available. A handful of features *may* reach out, but only after the user explicitly enables them, and each is off until they do — cloud transcription (`GeminiTranscriptionClient`), local LLM servers on `localhost` (`OllamaCorrector`, `OpenAICompatibleCorrector`), Whisper model downloads (`WhisperServerController`), and the update check (`UpdateChecker`). If you add a network path, it must follow the same shape: opt-in, off by default, disclosed in the UI, and sending nothing about the user or their machine beyond what the feature strictly requires.
- **Fail-Closed Security**: Never capture or process keystrokes during password entry (`NSSecureTextField`), Secure Event Input locks, or in muted applications.
- **Secrets Protection**: Secrets are independent records with AES-GCM-protected values and a configurable authentication gate. Never expose values in logs or diagnostic exports. Clipboard markers request exclusion from compatible managers but cannot enforce another process’s retention policy.

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

# Same suite plus coverage/lcov.info for GitPulse
./Scripts/test.sh --coverage

# Run specific test suite
./Scripts/test.sh --filter SecretSnippetTests

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

- **Looking for something to work on?** Start with [`good first issue`](https://github.com/bharathvbcr/DevType/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) — those are scoped to be self-contained, with the relevant files and acceptance criteria named in the issue. [`help wanted`](https://github.com/bharathvbcr/DevType/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22) is work that is ready to pick up but assumes more context. Comment on an issue before starting so two people don't build the same thing.
- **Bug Reports**: Open an issue using the [Bug Report template](.github/ISSUE_TEMPLATE/bug_report.yml).
- **Feature Requests**: Open an issue using the [Feature Request template](.github/ISSUE_TEMPLATE/feature_request.yml).
- **New Model or Provider Adapter**: Use the [Model / Adapter Request template](.github/ISSUE_TEMPLATE/model_adapter_request.yml). Speech and correction backends plug into `SpeechProviderRegistry` and `CorrectionProviderRegistry` — add a case to the registry rather than a new call site.
- **Security Inquiries**: See [SECURITY.md](SECURITY.md) for vulnerability reporting.
- **General Questions**: See [SUPPORT.md](SUPPORT.md) or visit GitHub Discussions.

Thank you for helping make DevType the best native text expander for macOS!
