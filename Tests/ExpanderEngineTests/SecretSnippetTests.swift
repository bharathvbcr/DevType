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
