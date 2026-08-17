# macOS Permissions & TCC Setup Guide

To provide seamless, low-latency text expansion and swallow trigger keystrokes across macOS, **DevType** requires specific system permissions governed by Apple's Transparency, Consent, and Control (TCC) subsystem.

This guide explains why each permission is needed, how to grant and maintain them, and how to troubleshoot permission issues.

---

## 🔐 Permission Capability Matrix

| Permission | TCC Identifier | API Preflight Function | Why DevType Needs It |
|---|---|---|---|
| **Input Monitoring** | `kTCCServiceListenEvent` | `CGPreflightListenEventAccess()` | **Required** to intercept typed keystrokes and swallow trigger abbreviations before they render on screen. |
| **Accessibility** | `kTCCServiceAccessibility` | `AXIsProcessTrustedWithOptions()` | **Required** to perform atomic text range replacement directly inside focused text fields via macOS Accessibility APIs (`AXUIElement`). |
| **Post Events** | `kTCCServicePostEvent` | `CGPreflightPostEventAccess()` | *Optional / Fallback* to synthesize backspaces (`kVK_Delete`), `⌘V` paste events, and arrow navigation when Accessibility APIs are blocked. |

---

## 🛠️ Step-by-Step Setup in macOS

When you first launch DevType, the **Permission Onboarding Wizard** will open automatically. You can also manually configure permissions at any time:

### 1. Enable Accessibility
1. Open **System Settings** (`` → **System Settings…**).
2. Navigate to **Privacy & Security** → **Accessibility**.
3. Locate **DevType** in the list and toggle the switch to **ON** (Enter your macOS administrator password or Touch ID when prompted).
4. If DevType is not listed, click the **`+`** button and select `/Applications/DevType.app`.

### 2. Enable Input Monitoring
1. In **System Settings**, navigate to **Privacy & Security** → **Input Monitoring**.
2. Locate **DevType** and toggle the switch to **ON**.
3. If prompted to "Quit & Reopen", allow macOS to restart DevType so the event tap activates immediately.

---

## 💻 Local Development & Code Signing

macOS TCC binds permission grants directly to an application's **Code Signing Designated Requirement (DR)** and bundle identifier (`com.devtype.app`).

If you compile DevType locally using ad-hoc signing (`-`), Xcode or SwiftPM generates a new ephemeral ad-hoc signature on every build, causing macOS to invalidate your TCC permissions repeatedly.

### Which identity gets used

`./Scripts/package-app.sh` does not hardcode an identity. `./Scripts/signing-identity.sh` resolves one, best first, and you can run it yourself to see the answer:

| Order | Identity | Notes |
|---|---|---|
| 1 | `Developer ID Application: …` | Paid Apple Developer Program. The only identity that can be notarized for distribution. |
| 2 | `Apple Development: …` | **A free Apple ID is enough.** Preferred for everyday development. |
| 3 | `DevType Local Signing` | Self-signed fallback from `./Scripts/make-signing-cert.sh`. |
| 4 | ad-hoc (`-`) | Last resort. TCC grants reset on every rebuild. |

Any of the first three keeps the DR pinned to a certificate, so TCC grants survive rebuilds. Set `DEVTYPE_SIGN_IDENTITY` to override the choice, or to `-` to force ad-hoc.

### Preferred: an Apple Development certificate (free Apple ID)

In Xcode, go to **Settings → Accounts**, add your Apple ID, then **Manage Certificates → + → Apple Development**. Confirm it landed:

```bash
security find-identity -v -p codesigning
```

This is better than the self-signed fallback for a reason beyond TCC: keychain items created by an Apple-issued signature get a stable `teamid:` partition, whereas a self-signed signature falls back to a per-build `cdhash:` partition that DevType has to heal after every rebuild.

Apple Development certificates expire (unlike the 10-year self-signed one). The build warns 30 days ahead; renew in the same Xcode pane. A renewed certificate keeps its common name, so the DR — and your grants — survive the renewal.

### Fallback: a self-signed certificate

With no Apple ID, run this once instead:

```bash
./Scripts/make-signing-cert.sh
```

It creates a self-signed certificate named `DevType Local Signing` in your login keychain.

### Switching identities

Changing identity changes the DR, so existing Settings toggles authorize the old one and permissions silently stop working. `./Scripts/install-app.sh` detects this, prints both requirements, and runs `./Scripts/reset-tcc.sh` for you — re-grant Accessibility and Input Monitoring once afterwards.

---

## 🔧 Troubleshooting Permission Issues

### 1. Permissions Toggle Shows "ON", but Expansions Do Not Trigger
Occasionally, after updating macOS or rebuilding an app bundle, the macOS TCC daemon (`tccd`) may hold a stale cache entry.

**Fix**:
1. Quit DevType.
2. Open **System Settings** → **Privacy & Security** → **Accessibility**.
3. Select **DevType** and click the **`-`** (minus) button to remove it completely.
4. Do the same under **Input Monitoring**.
5. Relaunch DevType and allow the setup wizard to re-request access.

### 2. Resetting TCC Permissions via Terminal
You can quickly reset permission states for DevType using the `tccutil` CLI or DevType's reset helper:

```bash
# Reset using DevType helper script
./Scripts/reset-tcc.sh

# Or reset individual services manually via tccutil
tccutil reset Accessibility com.devtype.app
tccutil reset ListenEvent com.devtype.app
```

---

## 🛡️ Security & Privacy Guarantees

Because DevType requires Input Monitoring and Accessibility permissions, we enforce strict, verifiable privacy invariants:

1. **Zero Cloud Telemetry**: DevType is 100% offline. No network libraries or telemetry frameworks exist in the binary.
2. **Volatile Buffer Only**: Keystrokes are held in a short memory ring buffer strictly to match trigger abbreviations. Keystrokes are never logged to disk or persisted.
3. **Fail-Closed Password Protection**: The event tap automatically pauses whenever a secure text field (`NSSecureTextField`) or macOS Secure Event Input lock is detected.
4. **Open Source Auditability**: All source code for the event tap (`EventTapEngine.swift`), text injection (`TextInjectionPipeline.swift`), and permissions management (`PermissionAuditTests.swift`) is open source and open to public inspection.
