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

All common workflows are automated via shell scripts in the `Scripts/` directory (`./ci:local` at the repo root is a shortcut for `Scripts/ci-local.sh`):

| Script | Command | Purpose |
|---|---|---|
| **Signing Identity** | `./Scripts/signing-identity.sh` | Prints the identity builds will use: Developer ID → Apple Development → self-signed → ad-hoc. Read-only. |
| **Local Signing Certificate** | `./Scripts/make-signing-cert.sh` | Generates the `DevType Local Signing` self-signed cert so TCC permissions survive rebuilds. Only needed when you have no Apple Development certificate. |
| **Run Unit Tests** | `./Scripts/test.sh [-v]` | Runs the headless SwiftPM test suite (`ExpanderEngineTests`). Pins `DEVELOPER_DIR` to full Xcode — Command Line Tools-only toolchains break `swift test`. |
| **Package Application** | `./Scripts/package-app.sh [release\|debug]` | Compiles binaries, bundles resources, stamps version from Git, and signs `.build/DevType.app`. Skips wipe+resign when nothing changed to preserve the CDHash. |
| **Build Application** | `./Scripts/build_app.sh [release\|debug]` | Thin wrapper delegating to `package-app.sh`. |
| **Install Application** | `./Scripts/install-app.sh` | Packages if needed, installs one daily-driver copy into `/Applications` (falls back to `~/Applications`), quits other DevType processes, and quarantines stale `build/` artifacts. |
| **Local CI Verification** | `./Scripts/ci-local.sh` | Full validation pipeline: script syntax lint, plist lint, script self-tests, unit tests, debug + release builds, packaging, bundle-ID/version verification (fails if placeholder versions survive), and codesign verification. Mirrors GitHub CI. |
| **Reset Permissions** | `./Scripts/reset-tcc.sh` | Resets the macOS TCC database for `com.devtype.app` to test fresh onboarding flows. |
| **Release & Notarize** | `./Scripts/release.sh` | Build → Developer ID sign → notarize → staple → DMG. Takes no positional arguments; see configuration below. |
| **DMG Selection** | `./Scripts/select-release-dmg.sh` | Picks exactly one `DevType-<version>.dmg`; zero or multiple candidates is fatal. Has a stubbed self-test (`test-release-dmg-select.sh`). |

The two resolver scripts have self-tests (`test-signing-identity.sh`, `test-release-dmg-select.sh`) that run inside local CI with stubbed `security`/`codesign`.

---

## 🧪 Testing Guidelines

DevType maintains **1,200+ unit, fuzz, and stress tests** across 83 suites in `Tests/ExpanderEngineTests/`.

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

Continuous integration (`.github/workflows/ci.yml`) runs `swift build` + `swift test` on macOS 14 plus a dedicated **macOS 26 job**, because `AITextTransformer` compiles against Apple Foundation Models only where `canImport(FoundationModels)` holds — the older runner guards the stub path, the newer one compiles and tests the real AI plumbing.

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
- **Categories**: `Permission`, `EventTap`, `SecureInput`, `Inject`, `Identity`, `App`, `Store`, `Debounce`, `Selection`

Filter logs in Terminal:
```bash
# Stream live logs from DevType
log stream --predicate 'subsystem == "com.devtype.app"' --level debug
```

Two retention aids exist beyond logd, which evicts aggressively:

- **`DevLogMirror`** keeps an in-process ring (4,000 lines) of the app's own log output so a diagnostic report generated later still contains the story; it is embedded in diagnostics.
- **`DebugTrace`** is opt-in JSONL tracing (UserDefaults keys `DevTypeDebugTrace`, `DevTypeDebugTracePath`) for deep inject-path debugging; it is off in normal use and size-capped.

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

DevType avoids hardcoded version strings. `Resources/Info.plist` ships placeholders (`0.0.1` / build `1`) that are overwritten at packaging time from Git:

- **`CFBundleShortVersionString`** = nearest tag from `git describe --tags` (v-prefix stripped; e.g. `0.0.9`, or `0.0.9-3-gabc1234` when ahead of the tag, with `+dirty` appended for an unclean tree).
- **`CFBundleVersion`** = monotonic commit count — the number macOS compares when deciding which of two bundles is newer.

Outside a Git checkout, packaging falls back to the plist values. Local CI fails the build if a placeholder version survives stamping, so field diagnostics always map to an exact commit.

### Update Checking

DevType checks for updates itself (`Sources/ExpanderEngine/Updates/`); Sparkle is not embedded, and the inert `SUFeedURL` / `SUEnableInstallerLauncherService` keys that used to sit in `Info.plist` have been removed — they configured a framework that was never present, and pointed at an account that is not this project's.

- **`AppVersion`** parses and orders version strings. It is deliberately not a plain SemVer comparator: `git describe`'s `-<N>-g<sha>` suffix means *N commits **after*** the tag, while SemVer reads the same characters as a *pre-release **of*** it. Reading it the SemVer way tells anyone running a post-tag build to "update" to the release they are already ahead of, so the distance suffix is detected specifically and ordered above the bare tag. `AppVersionTests` pins the full ordering.
- **`UpdateChecker`** asks the GitHub Releases API for the latest release, and does nothing else — it never downloads or installs. Acting on a result opens the release page in the browser. That is a constraint, not an omission: `release.yml` publishes with `DEVTYPE_SKIP_NOTARIZE=1`, so CI DMGs are signed but not notarized, and silently installing a non-notarized bundle is precisely what Gatekeeper exists to stop. An in-place updater has to enable notarization in CI first.
- **Off by default.** Nothing contacts the network until the user enables *Preferences → General → Updates*; automatic checks then run at most once a day. "Check for Updates…" in the menu bar is an explicit request and always works.
- **Failure is never silence.** `UpdateCheckOutcome` keeps `.failed` and `.undeterminedLocalVersion` distinct from `.upToDate`, so a check that could not run never renders as one that ran and found nothing.
- The request carries no version, machine, or install identifier — a static `User-Agent`, an ephemeral session with no cookie or credential storage, and a bounded response read.

### Creating a Release
```bash
# One-time: notarytool credentials (paid Apple Developer Program + Developer ID certificate required)
xcrun notarytool store-credentials DevTypeNotary \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

# Tag the release
git tag -a v0.1.0 -m "Release v0.1.0"

# Build, sign, notarize, staple, and produce dist/DevType-<version>.dmg
DEVTYPE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/release.sh

# Dry run without notarization (local-signing DMG only)
DEVTYPE_SKIP_NOTARIZE=1 ./Scripts/release.sh
```

Environment knobs: `DEVTYPE_SIGN_IDENTITY` (Developer ID identity), `DEVTYPE_NOTARY_PROFILE` (default `DevTypeNotary`), `DEVTYPE_SKIP_NOTARIZE=1`. The DMG selector refuses to guess if zero *or* multiple `DevType-<expected-version>.dmg` files exist.

---

## 🔒 Security & Privacy Review

Before submitting changes, ensure:
1. No external network dependencies or telemetry SDKs are included.
2. `SecureInputMonitor` and `NSSecureTextField` fail-closed protection remain fully tested.
3. Sensitive credentials are only handled via `SecretStore` with AES-GCM encryption.
