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
| **Run Unit Tests** | `./Scripts/test.sh [-v]` | Runs the SwiftPM engine and AppKit-core tests (`ExpanderEngineTests`, `DevTypeAppTests`). Pins `DEVELOPER_DIR` to full Xcode — Command Line Tools-only toolchains break `swift test`. |
| **Package Application** | `./Scripts/package-app.sh [release\|debug]` | Compiles binaries, bundles resources, stamps version from Git, and signs `.build/DevType.app`. Skips wipe+resign when nothing changed to preserve the CDHash. |
| **Build Application** | `./Scripts/build_app.sh [release\|debug]` | Thin wrapper delegating to `package-app.sh`. |
| **Install Application** | `./Scripts/install-app.sh [release\|debug]` | Packages if needed, installs one daily-driver copy into `/Applications` (falls back to `~/Applications`), quits other DevType processes, and quarantines stale `build/` artifacts. |
| **Local CI Verification** | `./Scripts/ci-local.sh` | Full validation pipeline: script syntax lint, plist lint, script self-tests, unit tests, debug + release builds, packaging, bundle-ID/version verification (fails if placeholder versions survive), and codesign verification. Mirrors GitHub CI. |
| **Reset Permissions** | `./Scripts/reset-tcc.sh` | Resets the macOS TCC database for `com.devtype.app` to test fresh onboarding flows. |
| **Release & Notarize** | `./Scripts/release.sh` | Build → Developer ID sign → notarize → staple → DMG. Takes no positional arguments; see configuration below. |
| **DMG Selection** | `./Scripts/select-release-dmg.sh` | Picks exactly one `DevType-<version>.dmg`; zero or multiple candidates is fatal. Has a stubbed self-test (`test-release-dmg-select.sh`). |
| **Release Preflight** | `./Scripts/release-preflight.sh` | Requires an existing exact tag at HEAD, a clean worktree, matching release notes, and disabled default voice tracing. Run local CI separately. |
| **Signing Preflight** | `./Scripts/release-signing-preflight.sh` | Validates that the active signing identity meets distribution requirements. |
| **Release Version Check** | `./Scripts/verify-release-version.sh` | Refuses to package a bundle whose stamped version differs from the exact release tag. |
| **Asset Verification** | `./Scripts/verify-release-asset-list.sh` | Verifies published GitHub release asset inventories to prevent missing or mismatched assets. |
| **Seed Issues** | `./Scripts/seed-good-first-issues.sh` | Seeds curated, self-contained `good first issue` candidates for open-source contributors. |

The resolver and verification scripts have dedicated self-tests (`test-signing-identity.sh`, `test-release-dmg-select.sh`, `test-release-signing-preflight.sh`, `test-release-preflight.sh`, `test-release-asset-list.sh`, `test-release-guard.sh`, `test-release-version.sh`) that run inside local CI with stubbed environments.

---

## 🧪 Testing Guidelines

DevType maintains **1,900+ unit, fuzz, and stress tests** across `Tests/ExpanderEngineTests/` and `Tests/DevTypeAppTests/`. The v0.1.4 follow-up suite contains 1,936 tests. Seven live-AI tests and seven native AppKit window tests require explicit opt-in; the latter briefly display synthetic UI.

### Running Tests
```bash
# Run all tests
./Scripts/test.sh

# Run with verbose output
./Scripts/test.sh -v

# Run a specific test class
./Scripts/test.sh --filter SecretSnippetStressTests

# Run a single test case
./Scripts/test.sh --filter testBiometricGateGating

# Show synthetic AppKit UI to check direct secret search and native status-button events
DEVTYPE_RUN_APPKIT_SMOKE=1 ./Scripts/test.sh --filter SecretSearchWindowTests

# Check secure-input monitor lifecycle races with Thread Sanitizer
./Scripts/test.sh --scratch-path /tmp/devtype-secure-input-tsan --sanitize thread \
  --filter SecureInputMonitorLifecycleTests
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
- **`UpdateChecker`** asks the GitHub Releases API for the latest release, and does nothing else — it never downloads or installs. Acting on a result opens the release page in the browser. The current GitHub workflow publishes an explicitly marked development-signed, unnotarized DMG because this project does not have Developer ID/notarization credentials; Gatekeeper may reject it and users must approve it manually. An in-place updater remains disabled until trusted distribution is available.
- **Off by default.** Nothing contacts the network until the user enables *Preferences → General → Updates*; automatic checks then run at most once a day. "Check for Updates…" in the menu bar is an explicit request and always works.
- **Failure is never silence.** `UpdateCheckOutcome` keeps `.failed` and `.undeterminedLocalVersion` distinct from `.upToDate`, so a check that could not run never renders as one that ran and found nothing.
- The request carries no version, machine, or install identifier — a static `User-Agent`, an ephemeral session with no cookie or credential storage, and a bounded response read.

### Creating a Release
```bash
# One-time: notarytool credentials (paid Apple Developer Program + Developer ID certificate required)
xcrun notarytool store-credentials DevTypeNotary \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

# Commit, validate, then tag the release. The tag must point at the same clean
# commit whose local CI passed.
git commit -m "your release changes"
./Scripts/ci-local.sh
git tag -a v0.1.4 -m "Release v0.1.4"
./Scripts/release-preflight.sh v0.1.4

# Local release installation using the available signing identity
./Scripts/install-app.sh release
./Scripts/verify-release-version.sh v0.1.4 \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/DevType.app/Contents/Info.plist)"

# Build, sign, notarize, staple, and produce dist/DevType-<version>.dmg
DEVTYPE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/release.sh

# Dry run without notarization (local-only DMG; never upload this artifact)
DEVTYPE_SKIP_NOTARIZE=1 ./Scripts/release.sh

# Explicit untrusted tagged publication when Developer ID/notarization is unavailable
DEVTYPE_RELEASE_TAG=v0.1.4 \
  DEVTYPE_SKIP_AUTO_CERT=1 \
  DEVTYPE_SKIP_NOTARIZE=1 \
  DEVTYPE_ALLOW_UNTRUSTED_RELEASE=1 \
  ./Scripts/release.sh
```

Environment knobs: `DEVTYPE_SIGN_IDENTITY` (Developer ID identity), `DEVTYPE_NOTARY_PROFILE` (default `DevTypeNotary`), and `DEVTYPE_SKIP_NOTARIZE=1` for local-only dry runs. A tagged unnotarized release must additionally set `DEVTYPE_ALLOW_UNTRUSTED_RELEASE=1`; this is an explicit trust downgrade, not a default. The GitHub workflow runs `ci:local`, checks exact tag/version agreement, requires curated notes and one matching DMG with no residue assets, and compares the published download byte-for-byte. The workflow’s explicit untrusted-release policy permits the unnotarized artifact and warns users accordingly.

---

## 🔒 Security & Privacy Review

Before submitting changes, ensure:
1. No external network dependencies or telemetry SDKs are included.
2. `SecureInputMonitor` and `NSSecureTextField` fail-closed protection remain fully tested.
3. Sensitive credentials are only handled via `SecretStore` with AES-GCM encryption.
