# DevType Developer Guide

This guide covers everything you need to know to build, test, debug, package, and release **DevType**.

---

## 🛠️ Environment & Prerequisites

- **macOS 14.0 (Sonoma)** or later (macOS 26+ for Apple Foundation Models AI testing).
- **Xcode 15+** or Apple Command Line Tools (`xcode-select --install`).
- **Swift 5.9+** toolchain.
- Standard developer tools (`codesign`, `plutil`, `security`, `hdiutil`).

---

## 📜 Development Scripts & Tooling

All common workflows are automated via shell scripts in the `Scripts/` directory:

| Script | Command | Purpose |
|---|---|---|
| **Signing Identity** | `./Scripts/signing-identity.sh` | Prints the identity builds will use: Developer ID → Apple Development → self-signed → ad-hoc. Read-only. |
| **Local Signing Certificate** | `./Scripts/make-signing-cert.sh` | Generates the `DevType Local Signing` self-signed cert so TCC permissions survive rebuilds. Only needed when you have no Apple Development certificate. |
| **Run Unit Tests** | `./Scripts/test.sh` | Runs headless SwiftPM test suite (`ExpanderEngineTests`). |
| **Package Application** | `./Scripts/package-app.sh [release\|debug]` | Compiles binaries, bundles resources, stamps version from Git, and signs `.build/DevType.app`. |
| **Install Application** | `./Scripts/install-app.sh` | Packages and installs `DevType.app` to `/Applications` for day-to-day dogfooding. |
| **Local CI Verification** | `./Scripts/ci-local.sh` | Full validation pipeline: script syntax, plists, tests, debug build, release build, and bundle verification. |
| **Reset Permissions** | `./Scripts/reset-tcc.sh` | Resets macOS TCC database for `com.devtype.app` to test fresh onboarding flows. |
| **Release & DMG** | `./Scripts/release.sh <version>` | Creates signed, packaged `.dmg` disk image for distribution. |

---

## 🧪 Testing Guidelines

DevType maintains over **1,000+ unit, fuzz, and stress tests** in `Tests/ExpanderEngineTests/`.

### Running Tests
```bash
# Run all tests
./Scripts/test.sh

# Run with verbose output
./Scripts/test.sh -v

# Run a specific test class
swift test --filter SecretSnippetStressTests

# Run a single test case
swift test --filter testBiometricGateGating
```

### Headless Test Isolation Rule
`ExpanderEngineTests` is designed to be completely **headless**:
- Tests must never require an interactive user session, window server focus, or real TCC prompts.
- All hardware/system interactions (event taps, pasteboard, biometrics, selection reader) must use mock adapters or test-isolated boundaries.
- Any test that would require interactive accessibility focus belongs in manual integration tests, not the automated headless suite.

---

## 🐞 Debugging & Logging

### Console.app & Unified Logging
DevType logs important runtime events using `os.Logger`:

- **Subsystem**: `com.devtype.app`
- **Categories**: `Engine`, `EventTap`, `AI`, `Secrets`, `Permissions`, `Importers`

Filter logs in Terminal:
```bash
# Stream live logs from DevType
log stream --predicate 'subsystem == "com.devtype.app"' --level debug
```

### Debugging with LLDB
To debug the running app or event tap:

```bash
# Build debug bundle and run under lldb
./Scripts/package-app.sh debug
lldb .build/DevType.app/Contents/MacOS/DevType
```

> [!NOTE]
> When attached to a debugger, `CGEventTap` callbacks may occasionally time out if a breakpoint pauses execution. The engine handles `kCGEventTapDisabledByTimeout` automatically, but you may need to resume execution in LLDB.

---

## 📦 Version Stamping & Releases

DevType avoids hardcoded version strings. The version is dynamically derived from Git tags:

```bash
git describe --tags --always --dirty
```

When building via `package-app.sh`, the version and build numbers are automatically stamped into `Info.plist` using `PlistBuddy`.

### Creating a Release
```bash
# Tag a new version
git tag -a v1.2.0 -m "Release v1.2.0"

# Build DMG and package
./Scripts/release.sh v1.2.0
```

---

## 🔒 Security & Privacy Review

Before submitting changes, ensure:
1. No external network dependencies or telemetry SDKs are included.
2. `SecureInputMonitor` and `NSSecureTextField` fail-closed protection remain fully tested.
3. Sensitive credentials are only handled via `SecretStore` with AES-GCM encryption.
