import AppKit
import XCTest
@testable import ExpanderEngine

/// Keychain-backed secrets: the guarantees, stated as tests.
///
/// The feature exists because a password kept in `snippets.json` is readable by anything running
/// as the user, rides along in every export and backup, and is on screen in the editor. So the
/// interesting assertions are all *negative* — what must never appear, never persist, never fire —
/// and each one is pinned here rather than left to the care of whoever edits next.
final class SecretSnippetTests: XCTestCase {

    private let fixedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func secretSnippet(
        trigger: String = ";pw",
        title: String = "Work login"
    ) -> SnippetModel {
        SnippetModel(
            id: fixedID,
            title: title,
            triggerKeyword: trigger,
            replacementText: "hunter2-should-never-survive",
            isSecret: true
        )
    }

    // MARK: - The value never lives in the model

    /// The initialiser drops it. Not "callers should not pass it" — they cannot, because a copy
    /// of the struct reaches every listener, the Recent menu, and the palette row.
    func testInitialiserRefusesToCarryASecretValue() {
        let snippet = secretSnippet()
        XCTAssertTrue(snippet.isSecret)
        XCTAssertEqual(
            snippet.replacementText, "",
            "A value handed to the initialiser must be dropped, or it travels in every copy of "
                + "the struct that the app passes around."
        )
    }

    /// Encoding is the chokepoint every writer shares — `saveSnippets`, `exportLibraryData`, the
    /// JSON/CSV/YAML exporters, the conflict snapshots. Redacting there means no future writer
    /// has to remember to.
    func testEncodingNeverWritesASecretValue() throws {
        // Force a value into the struct the way only a corrupted file or a future bug could.
        var smuggled = SnippetModel(
            id: fixedID,
            title: "Work login",
            triggerKeyword: ";pw",
            replacementText: ""
        )
        smuggled.replacementText = "hunter2-should-never-survive"
        smuggled.isSecret = true

        let data = try JSONEncoder().encode(smuggled)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(
            json.contains("hunter2"),
            "The encoder is the last gate before disk. Everything else is a convention; this is "
                + "the guarantee."
        )
        XCTAssertTrue(json.contains("\"isSecret\":true"))
        XCTAssertTrue(
            json.contains("\"replacementText\":\"\""),
            "Written as empty rather than omitted, so an older build still decodes a well-formed "
                + "snippet instead of failing on a missing required key."
        )
    }

    /// A library file edited by hand — or written by a build from before the redaction — must not
    /// be able to reintroduce the value at load time.
    func testDecodingStripsASmuggledValue() throws {
        let json = """
        {"id":"\(fixedID.uuidString)","title":"Work login","triggerKeyword":";pw",
         "replacementText":"hunter2-should-never-survive","isSecret":true}
        """
        let snippet = try JSONDecoder().decode(SnippetModel.self, from: Data(json.utf8))
        XCTAssertTrue(snippet.isSecret)
        XCTAssertEqual(snippet.replacementText, "")
    }

    /// Round-tripping a whole library keeps every ordinary snippet byte-for-byte. The redaction
    /// must be surgical — a bug here would quietly empty the user's real snippets.
    func testOrdinarySnippetsAreUntouchedByTheRedaction() throws {
        let plain = SnippetModel(title: "Address", triggerKeyword: ";addr", replacementText: "1 Main St\nApt 2")
        let data = try JSONEncoder().encode([plain, secretSnippet()])
        let decoded = try JSONDecoder().decode([SnippetModel].self, from: data)

        XCTAssertEqual(decoded[0].replacementText, "1 Main St\nApt 2")
        XCTAssertFalse(decoded[0].isSecret)
        XCTAssertEqual(decoded[1].replacementText, "")
        XCTAssertTrue(decoded[1].isSecret)
    }

    // MARK: - Never on the typed path

    /// Two independent reasons, either sufficient: Secure Input means the trigger is never seen
    /// where it would be wanted, and everywhere else a typed trigger would put a password into
    /// whatever the user happened to be typing in.
    func testSecretsAreNotTypedTriggerExpandable() {
        XCTAssertFalse(secretSnippet().isTypedTriggerExpandable)
        XCTAssertTrue(
            SnippetModel(title: "x", triggerKeyword: ";x", replacementText: "y")
                .isTypedTriggerExpandable
        )
    }

    /// Enforced at the engine's own door, so no caller can reintroduce it — not the app delegate,
    /// not an importer, not a test harness.
    func testEngineSetterFiltersSecretsOutOfTheMatcher() {
        let engine = EventTapEngine()
        let plain = SnippetModel(title: "Address", triggerKeyword: ";addr", replacementText: "1 Main St")
        engine.snippets = [plain, secretSnippet()]

        XCTAssertEqual(engine.snippets.map(\.triggerKeyword), [";addr"])
        XCTAssertFalse(
            engine.matchSnapshot.snippets.contains { $0.isSecret },
            "A secret inside the match snapshot is a password one keystroke from being typed "
                + "into the wrong window."
        )
    }

    // MARK: - Keychain store

    private func store() -> (SecretStore, InMemorySecretBackingStore) {
        let backing = InMemorySecretBackingStore()
        return (SecretStore(backing: backing), backing)
    }

    func testStoreRoundTripsAndOverwrites() {
        let (secrets, _) = store()
        XCTAssertTrue(secrets.store("first", for: fixedID).isSuccess)
        XCTAssertEqual(secrets.secret(for: fixedID), "first")
        XCTAssertTrue(secrets.hasSecret(for: fixedID))

        // Replace, not duplicate: `SecItemAdd` on an existing account returns duplicateItem.
        XCTAssertTrue(secrets.store("second", for: fixedID).isSuccess)
        XCTAssertEqual(secrets.secret(for: fixedID), "second")
    }

    /// An empty "secret" is indistinguishable from no secret at every read site, so accepting one
    /// would produce a snippet that looks configured and pastes nothing.
    func testEmptySecretIsRejected() {
        let (secrets, _) = store()
        XCTAssertEqual(secrets.store("", for: fixedID).failureValue, .emptyValue)
        XCTAssertFalse(secrets.hasSecret(for: fixedID))
    }

    func testRemoveIsIdempotent() {
        let (secrets, _) = store()
        secrets.store("value", for: fixedID)
        XCTAssertTrue(secrets.remove(for: fixedID).isSuccess)
        XCTAssertTrue(
            secrets.remove(for: fixedID).isSuccess,
            "Deleting what is already gone is the desired end state, not an error to report."
        )
        XCTAssertNil(secrets.secret(for: fixedID))
    }

    func testKeychainFailuresSurfaceTheStatus() {
        let backing = InMemorySecretBackingStore()
        backing.forcedStatus = errSecAuthFailed
        let secrets = SecretStore(backing: backing)

        XCTAssertEqual(secrets.store("value", for: fixedID).failureValue, .keychain(errSecAuthFailed))
        XCTAssertEqual(
            secrets.store("value", for: fixedID).failureStatus, errSecAuthFailed,
            "The editor tells the user *why* the save failed — a denied keychain prompt and a "
                + "signing-identity change need different advice."
        )
    }

    // MARK: - Orphan purge

    /// Deleting a secret snippet must delete the password. Otherwise the user removed it from
    /// every surface they can see, and it is still on the machine.
    func testOrphanedSecretsArePurged() {
        let (secrets, backing) = store()
        let keep = UUID(), drop = UUID()
        secrets.store("keep", for: keep)
        secrets.store("drop", for: drop)

        XCTAssertEqual(secrets.purgeOrphans(keeping: [keep]), 1)
        XCTAssertEqual(secrets.secret(for: keep), "keep")
        XCTAssertNil(secrets.secret(for: drop))
        XCTAssertEqual(backing.accounts(), [SecretStore.account(for: keep)])
    }

    /// The purge only ever deletes what it can identify as one of ours. An account under our
    /// service that does not parse as a snippet UUID is left alone — deleting what we do not
    /// understand is how a bug here becomes someone's lost credential.
    func testPurgeLeavesUnrecognisedAccountsAlone() {
        let live = UUID()
        let orphan = UUID()
        let stored: Set<String> = [
            SecretStore.account(for: live),
            SecretStore.account(for: orphan),
            "not-a-uuid",
            "",
        ]
        XCTAssertEqual(
            SecretStore.orphanAccounts(stored: stored, liveIDs: [live]),
            [SecretStore.account(for: orphan)]
        )
    }

    func testPurgeWithNoLiveSnippetsRemovesEveryKnownSecret() {
        let ids = (0..<5).map { _ in UUID() }
        let stored = Set(ids.map(SecretStore.account(for:)))
        XCTAssertEqual(SecretStore.orphanAccounts(stored: stored, liveIDs: []), stored)
    }

    // MARK: - Clipboard

    /// The clear timer must never wipe something the user copied afterwards. A missed clear leaves
    /// a secret around longer than intended; a wrong clear destroys what someone is mid-way
    /// through pasting.
    func testClipboardClearOnlyTouchesOurOwnWrite() {
        XCTAssertTrue(SecretClipboard.mayClear(ownedChangeCount: 42, currentChangeCount: 42))
        XCTAssertFalse(
            SecretClipboard.mayClear(ownedChangeCount: 42, currentChangeCount: 43),
            "A later change count means the user copied something else. Hands off."
        )
        XCTAssertFalse(SecretClipboard.mayClear(ownedChangeCount: nil, currentChangeCount: 42))
    }

    func testCopyMarksTheBoardConcealedAndSchedulesAClear() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("devtype.tests.secret.\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        let clipboard = SecretClipboard()
        var scheduledDelay: TimeInterval?
        var fire: (() -> Void)?
        let clearAt = clipboard.copy("hunter2", clearAfter: 30, pasteboard: pasteboard) { work, delay in
            fire = work
            scheduledDelay = delay
        }

        XCTAssertNotNil(clearAt)
        XCTAssertEqual(scheduledDelay, 30)
        XCTAssertEqual(pasteboard.string(forType: .string), "hunter2")
        XCTAssertNotNil(
            pasteboard.data(forType: PasteboardBroker.concealedType),
            "Clipboard managers key off ConcealedType to skip recording a value. Without it the "
                + "password lands in the user's clipboard history."
        )
        XCTAssertNotNil(pasteboard.data(forType: PasteboardBroker.transientType))
        XCTAssertTrue(clipboard.hasOutstandingSecret)

        fire?()
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertFalse(clipboard.hasOutstandingSecret)
    }

    func testClearIsSkippedWhenTheUserCopiedSomethingElse() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("devtype.tests.secret.\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        let clipboard = SecretClipboard()
        clipboard.copy("hunter2", clearAfter: 30, pasteboard: pasteboard) { _, _ in }

        // The user copies their own text afterwards.
        pasteboard.clearContents()
        pasteboard.setString("an address they are mid-paste with", forType: .string)

        XCTAssertEqual(clipboard.clearIfStillOurs(pasteboard: pasteboard), .supersededByUser)
        XCTAssertEqual(pasteboard.string(forType: .string), "an address they are mid-paste with")
    }

    func testCopyingNothingIsNotReportedAsSuccess() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("devtype.tests.secret.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("existing clipboard", forType: .string)

        let clipboard = SecretClipboard()
        XCTAssertNil(clipboard.copy("", pasteboard: pasteboard) { _, _ in })
        XCTAssertEqual(
            pasteboard.string(forType: .string), "existing clipboard",
            "An empty copy must leave the board alone rather than wiping what was there."
        )
    }

    func testClearWithNothingOutstandingIsANoOp() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("devtype.tests.secret.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertEqual(SecretClipboard().clearIfStillOurs(pasteboard: pasteboard), .nothingToClear)
    }
    // MARK: - Searching a large secret library

    /// A flat submenu stops being usable long before it stops being buildable, so the copy
    /// palette can be narrowed to secrets. Narrowing happens *before* ranking: the palette caps
    /// snippet hits, so filtering afterwards would let ordinary snippets fill the cap and crowd
    /// out the very thing being searched for.
    func testSecretsOnlyFilterKeepsGroupsMeaningful() {
        let groups = [
            SnippetGroup(name: "General", snippets: [
                SnippetModel(title: "Address", triggerKeyword: ";a", replacementText: "1 Main St"),
                SnippetModel(title: "Work login", triggerKeyword: ";w", replacementText: "", isSecret: true),
            ]),
            SnippetGroup(name: "Plain only", snippets: [
                SnippetModel(title: "Sig", triggerKeyword: ";s", replacementText: "—B"),
            ]),
            SnippetGroup(name: "Vault", snippets: [
                SnippetModel(title: "Bank", triggerKeyword: ";b", replacementText: "", isSecret: true),
                SnippetModel(title: "Router", triggerKeyword: ";r", replacementText: "", isSecret: true),
            ]),
        ]

        let filtered = SecretLibraryFilter.secretsOnly(groups)

        XCTAssertEqual(filtered.map(\.name), ["General", "Vault"], "Empty groups are dropped.")
        XCTAssertEqual(filtered.flatMap(\.snippets).map(\.displayTitle), ["Work login", "Bank", "Router"])
        XCTAssertTrue(filtered.flatMap(\.snippets).allSatisfy(\.isSecret))
    }

    func testSecretsOnlyFilterIsEmptyWhenNothingIsSecret() {
        let groups = [SnippetGroup(name: "General", snippets: [
            SnippetModel(title: "Address", triggerKeyword: ";a", replacementText: "1 Main St"),
        ])]
        XCTAssertTrue(SecretLibraryFilter.secretsOnly(groups).isEmpty)
    }

    /// The submenu is capped and ordered most-recent-first, so a freshly added secret is at the
    /// top and a long library still produces a menu that opens instantly.
    func testSubmenuEntriesAreCappedAndMostRecentFirst() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let many = (0..<40).map { index in
            SnippetModel(
                title: "secret-\(index)",
                triggerKeyword: ";s\(index)",
                replacementText: "",
                updatedAt: base.addingTimeInterval(TimeInterval(index)),
                isSecret: true
            )
        }
        let entries = SecretMenuEntryPolicy.entries(from: many, limit: 20)
        XCTAssertEqual(entries.count, 20)
        XCTAssertEqual(entries.first?.displayTitle, "secret-39")
        XCTAssertTrue(entries.allSatisfy(\.isSecret))
    }

    // MARK: - Not losing the secret to the expansion pipeline

    /// The bug this pins: an expansion schedules a clipboard restore, the user copies a secret
    /// inside that window, and the restore puts the pre-expansion clipboard back over it. The
    /// concealed markers make it worse rather than better — `holdsOurPayload` reads a deliberate
    /// concealed write as *our* payload, so the restore considers overwriting it safe. Under
    /// Secure Input the hold is 8 s, which is exactly when secrets are copied.
    func testCopyingASecretAbandonsAnyPendingExpansionRestore() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("devtype.tests.secret.\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        let broker = PasteboardBroker()
        let before = broker.currentRestoreGeneration()

        SecretClipboard().copy("hunter2", clearAfter: 60, pasteboard: pasteboard, broker: broker) { _, _ in }

        XCTAssertGreaterThan(
            broker.currentRestoreGeneration(), before,
            "A bumped generation is what makes an already-scheduled restore a no-op. Without it "
                + "the user pastes the pre-expansion clipboard into a password field."
        )
    }

    /// The other direction: a later expansion must not adopt a concealed payload as "the user's
    /// clipboard" and faithfully restore it afterwards — that resurrects a password onto the
    /// board after `SecretClipboard` cleared it, with nothing left to clear it again.
    func testAConcealedBoardIsNeverAdoptedAsTheUsersClipboard() {
        XCTAssertFalse(
            PasteboardBroker.mayAdoptAsUserClipboard(types: [.string, PasteboardBroker.concealedType])
        )
        XCTAssertTrue(PasteboardBroker.mayAdoptAsUserClipboard(types: [.string]))
        XCTAssertTrue(
            PasteboardBroker.mayAdoptAsUserClipboard(types: [.string, PasteboardBroker.transientType]),
            "Transient alone is not a secret marker — ordinary expansion payloads carry it."
        )
        XCTAssertTrue(
            PasteboardBroker.mayAdoptAsUserClipboard(types: nil),
            "An empty board has nothing to protect and nothing to restore."
        )
    }

    /// `writeUserClipboardString` and `SecretClipboard` must share one invalidation, so a future
    /// deliberate-write path cannot be added without it.
    func testInvalidatingTheRestoreBumpsTheGeneration() {
        let broker = PasteboardBroker()
        let first = broker.currentRestoreGeneration()
        broker.invalidatePendingRestore()
        let second = broker.currentRestoreGeneration()
        broker.invalidatePendingRestore()

        XCTAssertGreaterThan(second, first)
        XCTAssertGreaterThan(broker.currentRestoreGeneration(), second)
    }

    // MARK: - Unrepresentable states

    /// A secret carries no AI transform. Nothing routes one to the model today; the field merely
    /// existing on a secret is an invitation for some future path to send a password off to be
    /// rewritten.
    func testSecretsCarryNoAITransformOrImage() throws {
        var snippet = SnippetModel(
            title: "pw",
            triggerKeyword: ";pw",
            replacementText: "value",
            imagePath: "shot.png",
            aiTransform: "proofread",
            isSecret: true
        )
        XCTAssertEqual(snippet.aiTransform, "")
        XCTAssertEqual(snippet.imagePath, "")
        XCTAssertEqual(snippet.replacementText, "")
        XCTAssertFalse(snippet.isImageSnippet)

        // Forced back in the way a hand-edited library would, then round-tripped.
        snippet.aiTransform = "proofread"
        snippet.imagePath = "shot.png"
        snippet.replacementText = "value"
        let decoded = try JSONDecoder().decode(
            SnippetModel.self,
            from: JSONEncoder().encode(snippet)
        )
        XCTAssertEqual(decoded.aiTransform, "")
        XCTAssertEqual(decoded.imagePath, "")
        XCTAssertEqual(decoded.replacementText, "")
    }

    // MARK: - Triggers a secret can never use

    /// A secret is reachable only by an explicit gesture, so its trigger can never fire. It must
    /// therefore neither shadow another trigger nor be reported as an unusable empty one — both
    /// were warnings the user could do nothing about.
    func testSecretsAreExcludedFromTriggerConflicts() {
        let shared = ";pw"
        let groups = [SnippetGroup(name: "General", snippets: [
            SnippetModel(title: "Real", triggerKeyword: shared, replacementText: "text"),
            SnippetModel(title: "Secret", triggerKeyword: shared, replacementText: "", isSecret: true),
            SnippetModel(title: "No trigger", triggerKeyword: "", replacementText: "", isSecret: true),
        ])]

        let conflicts = SnippetStore.triggerConflicts(in: groups)

        XCTAssertTrue(
            conflicts.isEmpty,
            "A secret cannot fire, so it collides with nothing and its empty trigger is "
                + "intentional. Got: \(conflicts)"
        )

        // The detector still works for snippets that *can* fire.
        let real = [SnippetGroup(name: "General", snippets: [
            SnippetModel(title: "A", triggerKeyword: shared, replacementText: "one"),
            SnippetModel(title: "B", triggerKeyword: shared, replacementText: "two"),
        ])]
        XCTAssertFalse(SnippetStore.triggerConflicts(in: real).isEmpty)
    }

}

private extension Result where Success == Void, Failure == SecretStore.Failure {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var failureValue: SecretStore.Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }

    var failureStatus: OSStatus? { failureValue?.status }
}
