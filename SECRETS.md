# Secret Snippets — Design & Security Model

DevType can store passwords and other sensitive strings as **secret snippets**: entries whose
value never appears in the snippet library, the editor, any export, or the diagnostic report.
This document is the complete record of how they work, what protects them, exactly when macOS
is allowed to show a dialog, and the measured keychain behaviour the design is built on.

---

## What a secret snippet is

- A snippet marked **Secret** in the editor. Its value is typed once into a secure field
  (never echoed back) and handed straight to encrypted storage — the snippet model itself
  carries an empty `replacementText`, enforced structurally in `SnippetModel.encode(to:)` and
  re-stripped on decode, so *every* writer (library JSON, exports, conflict snapshots) redacts
  by construction rather than by convention.
- Secrets are **mouse-only**. They are excluded from typed-trigger matching at the engine's
  setter (`isTypedTriggerExpandable == false`), for two independent reasons:
  1. Typed triggers cannot work where secrets are wanted: macOS **Secure Event Input**
     (TN2150) withholds keystrokes from every event tap *and* every registered hotkey while a
     password field has focus — the trigger would never be seen and `⌘/` never fires.
  2. Typed triggers are dangerous everywhere else: a trigger that fires on typing fires in
     chat windows and shared documents too. An explicit gesture cannot misfire.
- The paths to a secret: **status-bar menu → Copy Secret ▸**, **Search Secrets…**, or the
  command palette. Each copies the value to the clipboard (marked
  `org.nspasteboard.ConcealedType` so clipboard managers ignore it), shows a non-activating
  toast, and schedules an auto-clear (default **90 s**) that only fires if the clipboard still
  holds our write. The final keystroke — `⌘V` in the target app — is the user's own, which is
  what makes this work inside password fields where synthetic input paths are curtailed.

When macOS Secure Input is active, the menu-bar button shows a key and **Copy Secret**.
Clicking it opens **Search Secrets** directly, with the search field ready for typing.
Single-click a result, or select it with the arrow keys and press Return, to begin copying.
The authentication gate runs before the value is read; merely highlighting or filtering
results does not read or copy a secret.
Right-click or Control-click the button for the full DevType menu, including the existing
Copy Secret submenu, permission recovery, and engine diagnostics. Opening search does not
read or copy a secret; choosing a result uses the same authentication and clipboard
auto-clear flow. Typed expansion remains blocked in secure fields.

## Touch ID gate

Every secret read funnels through one resolver (`SecretMenuFlow.resolve`) that asks for
authorization first — pinned by a source-contract test so no future surface can bypass it.

- Policy starts at `.deviceOwnerAuthenticationWithBiometrics` wherever biometrics are
  enrolled, so the prompt is **Touch ID**, not the password sheet. A named *Use Password…*
  fallback escalates exactly once (user fallback, biometry lockout, sensor unavailable) and
  never on a cancel — answering "no" is respected, not retried.
- One successful check covers a **30 s reuse window**, so copying two secrets back-to-back
  asks once. The window is invalidated when DevType resigns active.
- The gate is a switch, on by default where the machine can evaluate one: **Preferences →
  Snippets → Secrets**, mirrored as a checkable item at the bottom of the **Copy Secret**
  menu.
- Scope, stated honestly: the gate stops someone at your unlocked Mac from lifting a secret
  out of a menu. It does not stop software already running as you — no macOS password
  manager's prompt does.

## Where the values actually live

```
~/Library/Application Support/DevType/secrets.enc     ← AES-GCM sealed values (0600, atomic)
login keychain, service com.devtype.app.secret.v2,
account com.devtype.masterkey                          ← ONE 256-bit master key
```

- Each value is sealed with **CryptoKit AES-GCM** (fresh random nonce per seal; nonce +
  ciphertext + tag stored as one base64 blob). Tampering — a flipped bit, truncation, the
  wrong key — fails the GCM tag and yields nothing, never plausible garbage.
- The archive is versioned JSON with sorted keys, written atomically, owner-only permissions.
  Bytes a build cannot vouch for (corruption, a *future* format version) are **quarantined
  aside, never overwritten** — forensics beat tidiness.
- The **master key** is the only keychain object. It is fetched at most once per process and
  **warmed into memory at launch**, while the keychain is still unlocked from login — so
  copies keep working even if the login keychain auto-locks later (see below).
- The key's keychain account is deliberately **not a UUID**: `SecretStore.orphanAccounts`
  refuses to purge non-UUID accounts, so snippet-cleanup can never collect the key that all
  sealed values depend on.

### Why an archive instead of one keychain item per secret

That is where this design started, and the file-based keychain defeated it in two measured
ways (details in the appendix):

1. For an app signed with a **self-signed certificate**, item access is partition-gated by
   the per-build binary hash — every rebuild invalidated "Always Allow" and re-summoned the
   login-password dialog. Healing exists but proved *unreliable* on items with certain ACL
   histories.
2. The user's login keychain **auto-locks mid-session**. A locked keychain fails every
   decrypt, so per-item storage resurfaces system dialogs forever, one per item, at
   unpredictable times — no migration can fix that.

With the archive, the entire keychain dialog surface is **one item**, touched **once per
launch**, at the moment it is most likely unlocked.

### Fail-safe rules (each pinned by a source-contract test)

- A keychain copy is dropped **only after** the sealed replacement is saved and then
  **re-read from disk and proven to decrypt** — a save that merely returned success is not
  proof. Every archive read-modify-write holds a cross-process `flock`.
- The master key is **never trusted without a read-back**: a keychain write can succeed
  against an item the app cannot read (open encrypt ACL, closed decrypt). No read-back → no
  key → per-item keychain fallback, which loses nothing.
- A save that cannot reach the master key (locked keychain) falls back to a keychain item —
  and evicts any stale sealed copy so an edited value can never silently revert.
- Deleting a secret removes it from both homes. Keychain items whose creating build is gone
  (deletes are owner-pinned) are destroyed in place: value overwritten, marked
  `DevType retired secret`, invisible to every API.

## When macOS may show a dialog — the three doorways

Ordinary copies are **structurally incapable** of prompting: the silent read path reports
failure instead of ever reaching a system dialog, and a source contract counts exactly one
dialog-capable keychain call in the app. A dialog can appear in exactly three places, each of
which explains itself before anything happens:

| Doorway | When | What you see |
|---|---|---|
| **Touch ID** | Every gated secret copy (30 s reuse) | The system biometry sheet naming the snippet |
| **One-time migration** | Only if secrets from a pre-v2 install still exist | A DevType alert stating how many password dialogs follow (≤ 1 per old secret), then the batch, then never again |
| **Keychain unlock** | Only if the login keychain is locked at first use | A DevType alert, then the system's own unlock prompt |

## Diagnostics

The report's `-- Secrets --` section carries counts and capabilities only — never a title,
trigger, id, or value; the tests assert it:

```
Secret snippets: 4
Biometry: available (Touch ID)
Require authentication: on
Reuse window: 30s
Clipboard auto-clear: 90s
Keychain last read: ok
Secrets pending migration: 0
Keychain: unlocked
Storage: archive: 4 sealed, keychain-resident: 0, master key: present
  trail: item A: v2 fetch → -25300
  trail: item A: consolidated into archive
```

The `trail:` lines are a value-free step log of every fetch, heal, migration and
consolidation with its `OSStatus`; accounts are aliased (`item A`, `item B`) in first-seen
order. This is what turns "it prompted again" into a diagnosis.

## Threat model & limits

- **Protected against:** the library file, exports, backups of the library, and the
  diagnostic report carrying a value; shoulder-surfing the editor; clipboard managers
  retaining copies; another app reading the archive (ciphertext without the key) or the
  master key (ACL'd to DevType's signing identity); a casual user at an unlocked Mac
  (Touch ID gate).
- **Not protected against:** software already running as you with debugger rights, and the
  value being on the clipboard for the seconds a paste needs. These are the standard limits
  of every macOS password manager.
- **Device-only by design:** the master key is `ThisDeviceOnly`. The archive file may land in
  a backup, but restored to another Mac it cannot be decrypted — a secret is re-entered, not
  migrated. Deleting the master key in Keychain Access makes every sealed value permanently
  unreadable; the report will say so (`master key: MISSING with sealed secrets`).

---

## Appendix: measured macOS keychain behaviour

None of the following is documented by Apple (TN3137 explicitly scopes it out). It was
established with signed probe binaries against a live login keychain, with UI suppressed so
probes could never put dialogs on screen. These facts drove the design and may shift with a
macOS update.

- Reading a file-based keychain item passes **two** checks: the ACL application entry
  (cert-pinned for a certificate-signed app — stable across rebuilds) and the hidden
  **partition list**. For apps without an Apple-issued certificate, the partition records the
  per-build `cdhash` — so "Always Allow" (which edits that list; that's why the dialog wants
  the login password) authorizes **one build only**.
- A **metadata-only `SecItemUpdate`** by an app matching the item's cert-pinned ACL entry
  silently *appends* its partition — the heal that keeps same-identity rebuilds quiet. An app
  failing the ACL can overwrite the value (encrypt is open) but never read it, so healing
  leaks nothing. On items with certain ACL histories (ad-hoc creation plus Always-Allow
  surgery) the heal is unreliable: observed landing on one item and skipping its twin.
- A **value update replaces** the partition list outright, and resurrects tombstoned items.
  `SecItemUpdate` silently **ignores an empty `kSecValueData`** — destroying a value requires
  writing a non-empty one.
- **`SecItemDelete` is owner-pinned to the creating build** (`errSecInvalidOwnerEdit` from
  any other, even after healing) — hence tombstones.
- The **data protection keychain is closed** to self-signed apps: its entitlements must be
  authorized by a provisioning profile, and AMFI SIGKILLs a self-signed binary that claims
  them.
- A **locked login keychain** fails decrypts and writes while metadata queries keep
  answering — indistinguishable from "no item" unless `SecKeychainGetStatus` is consulted.
  Auto-lock ("lock after N minutes", "lock when sleeping") makes this a recurring state, and
  even `codesign` fails (`errSecInternalComponent`) when the signing key lives in a locked
  keychain.
- securityd can **stall, not just fail**, on cross-identity item access — measured at five
  minutes. Anything touching the keychain at launch runs off the main thread.

### Storage generations (migration history)

| Generation | Where values lived | Why it was replaced |
|---|---|---|
| §8.9 `com.devtype.app.secret` | One keychain item per secret, created by ad-hoc builds | Per-build partition pinning: every rebuild → password dialog; `change_acl` left empty → unhealable in place |
| §8.10 `com.devtype.app.secret.v2` | One item per secret, created by the stable cert identity | Healable across rebuilds — but per-item dialog risk remains, and a locked keychain still prompts per item |
| §8.11 `secrets.enc` + master key | AES-GCM archive; one keychain item total | Current. One dialog surface, once per launch, lock-tolerant |

Migration is automatic and lossless: legacy items move through the explained one-time batch
(the only dialogs), v2 items consolidate silently at launch, and a keychain copy is deleted
only after its sealed replacement is verified on disk.
