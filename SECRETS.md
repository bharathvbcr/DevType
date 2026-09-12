# Secrets — Design & Security Model

DevType can store passwords and other sensitive strings as independent **secrets**: entries whose
stored value is never prefilled in the editor or included in the snippet library, exports, or diagnostics.
This document is the complete record of how they work, what protects them, exactly when macOS
is allowed to show a dialog, and the measured keychain behaviour the design is built on.

---

## What a secret is

- An independent `SecretModel`, created in **menu bar → Copy Secret → Manage Secrets…**.
  The editor asks for a name and secure value, with optional tags and an enabled setting.
  There is no trigger, keyboard shortcut, snippet group, replacement body, image, or AI action.
  Existing values are never prefilled. Leaving the value blank while editing keeps it unchanged.
  The value field is concealed by default; a **Show** button reveals what is being typed so a
  typo is caught before it is stored, and says so on screen while the value is visible. See
  the threat model below for what that does and does not change.
- Schema 3 stores secret metadata in a top-level `secrets` collection alongside ordinary
  snippet `groups` in the same atomic library document. Values stay in `SecretStore`.
  The snippet manager and its exports contain only snippets; resetting snippets retains secrets.
- **Sharing and backing up are different documents.** The user-facing export (`LibraryExporter`,
  Preferences → Export Library) reads `loadSnippetGroups()`, so a shared file contains no secret
  record at all — not even a title or a tag. The whole-library backup used for relocation and
  read-failure recovery (`SnippetStore.exportLibraryData()`) reads `loadGroups()`, so it *does*
  carry secret metadata: dropping it would mean a restore silently loses the user's secrets.
  Neither carries a value, and no export path of either kind can, because encoding a secret goes
  through `SecretModel`, which has no field to put one in.
- The chip labelled **Secrets** in the snippet manager's filter row is a signpost, not a filter:
  it opens the Secrets manager. `SnippetListFilter`, the type holding the manager's active
  filter, has no `secrets` case, so "show me the secrets in this list" is not a state the snippet
  list can be in rather than a state it has to keep answering "none" to.
- A secret is unreachable from `{{snippet:…}}` nesting by construction: `NestedSnippetResolver`
  drops them unconditionally, with no parameter a caller can get wrong.
- Older grouped, flat, and bare-array libraries are decoded into the independent collection.
  UUIDs, labels, timestamps, tags, and effective enable/app restrictions are preserved; old
  trigger text is discarded (used as the name only when an old entry has no other name).
  Loading does not write or access values. The next successful library save writes schema 3.
  Older builds that support only schema 2 refuse writes to this newer schema. Missing/null schema-3
  collections, ambiguous grouped/flat envelopes, and duplicate secret IDs fail closed. Their raw
  bytes remain intact; they cannot become an empty library that authorizes cleanup.
- Search, authenticated copy, and atomic resource edits reuse their existing owners through
  a value-free `snippetAdapter`. The internal transaction projection is never serialized as
  snippet records. Failed metadata writes retain the existing library and compensate staged values.
  An editor holds the archive transaction across value reads, staging, metadata publication, and
  compensation. Partial writes that report failure are compensated too. Retried compensation
  verifies its staged value before changing anything and keeps orphan protection until it finishes.
  Metadata queries remain available while a value transaction owns the archive lock.
- Secrets need **no trigger or shortcut**. They support deliberate mouse and palette actions. They are excluded from typed-trigger matching at the engine's
  setter (`isTypedTriggerExpandable == false`), for two independent reasons:
  1. Typed triggers cannot work where secrets are wanted: macOS **Secure Event Input**
     (TN2150) withholds keystrokes from every event tap *and* every registered hotkey while a
     password field has focus — the trigger would never be seen and `⌘/` never fires.
  2. Typed triggers are dangerous everywhere else: a trigger that fires on typing fires in
     chat windows and shared documents too. An explicit gesture cannot misfire.
- The paths to a secret: **status-bar menu → Copy Secret ▸**, **Search Secrets…**, or the
  command palette. Copy actions put the value on the clipboard (marked
  `org.nspasteboard.ConcealedType` to request exclusion from compatible clipboard managers), show a non-activating
  toast, and schedules an auto-clear (default **90 s**) that only fires if the clipboard still
  holds our write. The final keystroke — `⌘V` in the target app — is the user's own, which is
  what makes this work inside password fields where synthetic input paths are curtailed.

When macOS Secure Input is active, the menu-bar button shows a key and **Copy Secret**.
Clicking it opens **Search Secrets** directly, with the search field ready for typing.
Single-click a result, or select it with the arrow keys and press Return, to begin copying.
The authentication gate runs before the value is read; merely highlighting or filtering
results does not read or copy a secret. Disabled secrets are absent from the copy menu. Before
and after authorization/value retrieval, the resolver verifies that the selected metadata is still
current on disk. Deleted, edited, disabled, unreadable, or externally changed selections fail closed.
Right-click or Control-click the button for the full DevType menu, including the existing
Copy Secret submenu, permission recovery, and engine diagnostics. Opening search does not
read or copy a secret; choosing a result uses the same authentication and clipboard
auto-clear flow. Typed expansion remains blocked in secure fields.

If the master key cannot be read and values remain in Keychain fallback storage, metadata
migration leaves those values alone. Use **Preferences → Advanced → Repair Secret Storage**;
the Secrets manager links to that existing recovery page. Opening the manager does not run
repair or prompt for Keychain access. A failed value read or write never becomes a successful save.

Cleanup rechecks references after acquiring archive exclusion and verifies that the library's
cached snapshot still matches disk. An external edit, unreadable library, or competing mutation
defers deletion. Deferred items remain visible as pending cleanup in Advanced and the Secrets
manager; an unexamined item is never reported as a successful removal.

## Touch ID gate

User copy and insertion actions share one resolver (`SecretMenuFlow.resolve`) that applies the
authentication preference before reading values. Source-contract tests guard these UI routes;
internal storage operations also read values to verify writes and perform compensation.

- Policy starts at `.deviceOwnerAuthenticationWithBiometrics` wherever biometrics are
  enrolled, so the prompt is **Touch ID**, not the password sheet. A named *Use Password…*
  fallback escalates exactly once (user fallback, biometry lockout, sensor unavailable) and
  never on a cancel — answering "no" is respected, not retried.
- One successful check covers a **30 s reuse window**, so copying two secrets back-to-back
  asks once. The standing reuse window is invalidated when DevType resigns active; an already
  requested prompt may finish, but cannot reopen that retired window. Non-finite clocks/windows
  never authorize reuse. Duplicate authenticator callbacks finish the request only once, and
  releasing a gate owner cannot silently strand a requested completion.
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
  Every quarantine keeps a distinct recovery copy; at 32 copies, new quarantine attempts
  refuse instead of deleting earlier data. Reads and writes are capped at 64 MiB. An I/O
  failure, symbolic link, or special file is unavailable, never an empty archive. Diagnostics
  report an unknown archive count when the file cannot be examined.
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

With the archive, the keychain dialog surface for sealed values is **one master-key item**.
Launch consolidation warms it into memory when readable. Failed reads, diagnostics, and
explicit repair can probe it again; per-item fallback secrets still require their own reads.

### Fail-safe rules (covered by source-contract and behavioral tests)

- A keychain copy is dropped **only after** the sealed replacement is saved and then
  **re-read from disk and proven to decrypt** — a save that merely returned success is not
  proof. The cross-process `flock` covers the entire transaction: master-key discovery and
  creation, source-tier reads, archive read-modify-write and verification, and tier cleanup.
  Lazy reads and launch consolidation use the same boundary, so a delayed migration cannot
  replace a newer value or restore a deleted secret.
- Failure to open or acquire the archive lock **refuses the transaction**. Contention waits
  at most five seconds; saves/deletes return `errSecIO`, value reads return `nil`, and a
  consolidation pass reports its candidates as deferred (`remaining`). The value-free
  diagnostic trail records the refusal. No archive or keychain value is changed by a refused
  transaction, and a later operation can retry after the lock becomes available.
- The master key is **never trusted without a read-back**: a keychain write can succeed
  against an item the app cannot read (open encrypt ACL, closed decrypt). No read-back → no
  key → per-item keychain fallback, which loses nothing.
- A successful fallback read returns the secret even when optional consolidation fails.
  Following copies defer automatic consolidation for five seconds after that failure.
  Explicit saves, repair, and reads requiring decryption of an existing archive retry
  immediately. The launch sweep does not repeat a failed master-key probe merely to warm it.
- The master key is **never overwritten**. If the item exists but this identity cannot read
  it, creation refuses rather than minting a replacement over it: those bytes are the only
  way back into every sealed secret, including after the user answers "Always Allow" and the
  ACL heals. Refusing costs one launch on keychain fallback; overwriting costs every sealed
  secret, permanently. (Existence is checked with a metadata-only query — no decrypt.)
- A save that cannot reach the master key (locked keychain) falls back to a keychain item —
  and evicts any stale sealed copy so an edited value can never silently revert.
  If eviction fails, the save reports `errSecIO` and keeps the copies for retry. The shared
  atomic writer establishes `0600` before writing, synchronizes the staged file, then replaces
  the destination with one rename; a failure before publication preserves the old destination.
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
| **One-time repair** | Only if a secret cannot be read silently — a pre-v2 install, or a v2 item whose ACL a rebuild re-partitioned | A DevType alert stating how many password dialogs follow (≤ 1 per affected secret), then the batch, then never again |
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
Secret retrieval: returned a value
Keychain last read: ok
Secrets pending migration: 0
Keychain accounts needing authorization (including master key): 0
Secret cleanup pending: 0
Keychain: unlocked
Storage: archive: 4 sealed, keychain-resident: 0, master key: present
  trail: item A: v2 fetch → -25300
  trail: item A: consolidated into archive
```

The `trail:` lines are a value-free step log of every fetch, heal, migration and
consolidation with its `OSStatus`; accounts are aliased (`item A`, `item B`) in first-seen
order. This is what turns "it prompted again" into a diagnosis.

Secret retrieval and Keychain probe outcomes are independent: a fallback secret can be
returned successfully while the master-key probe fails. Storage inspection preserves the
preceding read result in the report. The authorization count includes the master key even
when no snippet needs migration, and points to **Preferences → Advanced → Repair Secret
Storage** when authorization is pending. Repair retains the existing explicit system-dialog
flow. Unreadable keys are never replaced; malformed keys and unavailable sealed secrets are
reported explicitly.

## Threat model & limits

- **Protected against:** the library file, exports, backups of the library, and the
  diagnostic report carrying a value; clipboard managers retaining copies; another app reading
  the archive (ciphertext without the key) or the master key (ACL'd to DevType's signing
  identity); a casual user at an unlocked Mac (Touch ID gate).
- **Shoulder-surfing the editor — qualified, and deliberately so.** The value field is
  concealed by default and an existing value is *never* prefilled, so opening the editor on a
  stored secret still shows nothing to read. But the editor now has a **Show** button that
  reveals what is currently typed, because the previous guarantee had a cost paid silently:
  with no way to check a typed value, a typo was only discovered later, when a paste failed in
  a login form — and the user's fix was usually to retype the secret blind again. Revealing is
  explicit, per-editor, never the default, announced on screen while it is in effect ("The
  value is visible on screen."), and applies only to the value being authored in that sheet.
  It cannot reveal a stored value, because the editor never loads one.
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

The batch is **epoch-neutral**. A v2 item can also become unreadable without the dialog — a
rebuild under a development certificate re-partitions its ACL, and the silent read then ends
in `errSecAuthFailed` no amount of healing clears. Walking only the legacy service left those
items a dead end: the read knew a dialog would fix them, nothing in the app could show one,
and the UI reported "no secret stored" about a secret that was stored and one dialog away.
The repair pass now covers both epochs — still through exactly one dialog-capable call, still
counted by the source contract — and the epoch only decides which service the fetch reads.
