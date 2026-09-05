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
| **Install Application** | `./Scripts/install-app.sh [release\|debug]` | Packages if needed, validates and recoverably swaps the canonical copy into `/Applications` (falls back to `~/Applications`), then quarantines stale build artifacts and a same-bundle copy at the other canonical path. |
| **Installer Regression** | `./Scripts/test-install-app.sh` | Hermetically exercises staged-bundle validation, rollback, quarantine uniqueness, and canonical-path cleanup entirely under a temporary directory. |
| **Local CI Verification** | `./Scripts/ci-local.sh` | Full validation pipeline: script syntax lint, plist lint, publication/installer fixtures, unit tests, debug + release builds, packaging, bundle-ID/version verification (fails if placeholder versions survive), and codesign verification. |
| **Release fixtures** | `./Scripts/ci-release-fixtures.sh` | Signing, installer, DMG/asset/preflight/version, trust-boundary and publication tests. Shared by local CI, GitHub hygiene, and the Release job. |
| **Reset Permissions** | `./Scripts/reset-tcc.sh` | Resets the macOS TCC database for `com.devtype.app` to test fresh onboarding flows. |
| **Release & Notarize** | `./Scripts/release.sh` | Build → Developer ID sign → notarize → staple → DMG. Takes no positional arguments; see configuration below. |
| **DMG Selection** | `./Scripts/select-release-dmg.sh` | Picks exactly one `DevType-<version>.dmg`; zero or multiple candidates is fatal. Has a stubbed self-test (`test-release-dmg-select.sh`). |
| **Release Preflight** | `./Scripts/release-preflight.sh` | Requires an existing exact tag at HEAD, a clean worktree, matching release notes, and disabled default voice tracing. Run local CI separately. |
| **Signing Preflight** | `./Scripts/release-signing-preflight.sh` | Validates that the active signing identity meets distribution requirements. |
| **Release Version Check** | `./Scripts/verify-release-version.sh` | Refuses to package a bundle whose stamped version differs from the exact release tag. |
| **Asset Verification** | `./Scripts/verify-release-asset-list.sh` | Verifies published GitHub release asset inventories to prevent missing or mismatched assets. |
| **Publish Verified Draft** | `GH_REPO=owner/repo ./Scripts/publish-release.sh <tag> <dist-dir>` | Requires the remote tag to match HEAD, uploads to a draft, verifies exact notes and downloaded bytes, then publishes and rechecks. Refuses to overwrite a public release. |
| **Seed Issues** | `./Scripts/seed-good-first-issues.sh` | Seeds curated, self-contained `good first issue` candidates for open-source contributors. |

The resolver and verification scripts have dedicated self-tests (`test-signing-identity.sh`, `test-release-dmg-select.sh`, `test-release-signing-preflight.sh`, `test-release-preflight.sh`, `test-release-asset-list.sh`, `test-release-guard.sh`, `test-release-version.sh`) that run inside local CI with stubbed environments.

---

## 🧪 Testing Guidelines

DevType maintains unit, fuzz, race, persistence, controller and stress tests across `Tests/ExpanderEngineTests/` and `Tests/DevTypeAppTests/`. Read the actual test summary for the selected SDK and filter; skipped tests are not passing checks. The five audit performance tests require `DEVTYPE_BENCH=1`. Isolated native pasteboard/file-version tests do not replace physical cross-application focus, Secure Input or live iCloud validation.

### Running Tests
```bash
# Run all tests
./Scripts/test.sh

# Include the five audit performance checks
DEVTYPE_BENCH=1 ./Scripts/test.sh

# Run with verbose output
./Scripts/test.sh -v

# Run a specific test class
./Scripts/test.sh --filter SecretSnippetStressTests

# Run a single test case
./Scripts/test.sh --filter testBiometricGateGating

# Check erase recovery, cancellation, Unicode handling, undo, and duplicate-insertion guards
./Scripts/test.sh --filter 'EraseSafetyTests|BackspaceIntegrityTests|DoubleInjectGuardTests|EraseUndoStressTests|WhitespaceFoldingStressTests|SourceContractTests'

# Show synthetic AppKit UI to check direct secret search and native status-button events
./Scripts/test.sh --filter SecretSearchWindowTests

# Check secure-input monitor lifecycle races with Thread Sanitizer
./Scripts/test.sh --scratch-path /tmp/devtype-secure-input-tsan --sanitize thread \
  --filter SecureInputMonitorLifecycleTests
```

Continuous integration (`.github/workflows/ci.yml`) runs `swift build` + `swift test` on macOS 14 plus a dedicated **macOS 26 job**, because `AITextTransformer` compiles against Apple Foundation Models only where `canImport(FoundationModels)` holds — the older runner guards the stub path, the newer one compiles and tests the real AI plumbing. Packaging jobs (`package` in `ci.yml` and the distribution job in `release.yml`) run **only on `macos-26` runners**, because the packaged artifact must be built by a toolchain that has the Foundation Models SDK — v0.1.7 shipped a DMG built on `macos-14`, and every guarded feature compiled to its fallback. The release job must therefore track the newest SDK the code targets, not the oldest one it supports. `Scripts/verify-release-capabilities.sh` (gated by `DEVTYPE_REQUIRE_FOUNDATION_MODELS=1`) asserts that `FoundationModels.framework` is linked *and weak* before a DMG is assembled or published: weak linkage is what lets a macOS 26 SDK build still launch on the macOS 14 deployment target.

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
- **Categories**: `Permission`, `EventTap`, `SecureInput`, `Inject`, `Identity`, `App`, `Store`, `Debounce`, `Voice`, `Selection`, `Updates`

Filter logs in Terminal:
```bash
# Stream live logs from DevType
log stream --predicate 'subsystem == "com.devtype.app"' --level debug
```

Two retention aids exist beyond logd, which evicts aggressively:

- **`DevLogMirror`** keeps an in-process ring of the app's own log output, capped independently at 4,000 lines and 1 MiB, so a diagnostic report generated later still contains the story; it is embedded in diagnostics and reports observed/retained/evicted counts.
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

For a local rebuild requested under an existing version, check whether the tag is published
before assigning that release name. Preserve an unpublished tag's original object under
`refs/archive/` and record its old and new targets alongside the build archive. Do not move a
published tag. Keep the build number derived from the new commit count, and verify the
packaged version with `Scripts/verify-release-version.sh` before installation.

Before removing old build outputs, inventory the ignored `.build/`, `build/`, and `dist/`
directories and preserve a recoverable copy of the installed app. `install-app.sh` packages
again, so carry the same configuration, Xcode toolchain, and signing identity into installation.
It validates the staged signature and both identifiers before displacing the destination, keeps the
old bundle available for rollback until the replacement verifies in place, and archives displaced
copies under unique quarantine paths. It checks the two canonical Applications paths only; it does
not claim to discover every DevType copy elsewhere on the machine. Compare the old and new
designated requirements before replacing the app: the installer resets TCC if those requirements
differ. Verify deep/strict codesign and Gatekeeper separately.

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

# Commit and tag locally, then validate that exact clean release commit.
# If the tag already exists, inspect its local and remote state first; never
# move a published tag. Preserve an unpublished tag object before replacing it.
git commit -m "your release changes"
git tag -a v0.1.4 -m "Release v0.1.4"
./ci:local
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

Environment knobs: `DEVTYPE_SIGN_IDENTITY` (Developer ID identity), `DEVTYPE_NOTARY_PROFILE` (default `DevTypeNotary`), and `DEVTYPE_SKIP_NOTARIZE=1` for local-only dry runs. A tagged unnotarized release must additionally set `DEVTYPE_ALLOW_UNTRUSTED_RELEASE=1`; this is an explicit trust downgrade, not a default. The workflow's existing opt-in permits an ad-hoc signed, unnotarized GitHub artifact.

Push `main` and verify its CI before pushing the release tag. The tag-triggered Release workflow calls the full CI workflow from the same commit and waits for macOS 14, macOS 26, packaging, and hygiene (including publication fixtures). It does not re-run `ci-local.sh` or the Swift engine suite after that reusable CI has passed. CI uses a distinct concurrency group so the reusable workflow cannot cancel its caller. Direct `v*` tag pushes do not start a second CI suite. Each job has a timeout.

After `ci:local` and DMG construction, `publish-release.sh` creates or resumes a draft. It verifies remote tag provenance, exact title and notes (including trailing newlines), the complete asset inventory, and a byte-identical download before publication. It repeats verification after publication. API errors fail the job; downloads retry at most five times. Upload or draft-verification failures leave a draft for inspection and retry. Extra assets must be inspected and removed deliberately before retrying. An already published release is never overwritten by a rerun; inspect its state and use a new version for changed artifacts. `python3 Scripts/test-release-publication.py` exercises these paths locally without contacting GitHub.

---

## 🔒 Security & Privacy Review

Before submitting changes, ensure:
1. No external network dependencies or telemetry SDKs are included.
2. `SecureInputMonitor` and `NSSecureTextField` fail-closed protection remain fully tested.
3. Sensitive credentials are only handled via `SecretStore` with AES-GCM encryption.

## Local v0.1.7 installation and release verification

Commit the complete merged source and version notes, then run `DEVTYPE_BENCH=1 DEVTYPE_SKIP_AUTO_CERT=1 ./Scripts/ci-local.sh` against that clean commit. The script validates shell/plist inputs, release/installer fixtures, all tests, debug/release builds and the packaged signature. Create the annotated `v0.1.7` tag at the verified commit, run `./Scripts/release-preflight.sh v0.1.7`, and package/install with `./Scripts/install-app.sh release`. Export `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for these commands when the selected toolchain is Command Line Tools.

The installer validates the new package, swaps the canonical application recoverably, quarantines the displaced app and duplicate package, and compares designated signing requirements before deciding whether TCC needs a reset. Verify the installed bundle is exactly `0.1.7` using `./Scripts/verify-release-version.sh v0.1.7 0.1.7`, plus the bundle plist, executable hash, strict codesign and running process path. The version checker accepts version strings; callers must read the actual installed plist value rather than assume it.

Inventory old builds before packaging: the packager removes known legacy bundles. Move old build directories and installers to a dated recoverable archive with their original paths recorded. Keep the running application until the validated replacement is ready; move the installer's quarantine to the same archive afterward. Keep release logs and a Git bundle separately from active build outputs.

An Apple Development signature supports local installation and stable identity; it does not establish notarized distribution. Run `spctl --assess --type execute` separately and report its result. A local tag/install does not publish a GitHub release. Pushing a `v*.*.*` tag triggers the repository's publication workflow and is a separate distribution action.
