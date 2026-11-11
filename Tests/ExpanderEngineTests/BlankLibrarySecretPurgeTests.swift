import XCTest
@testable import ExpanderEngine

/// A blank `snippets.json` (zero bytes, or only whitespace) loads as an empty library with an
/// `.emptyFile` issue. That is the contract: it is not a read failure, and saving is allowed.
///
/// An empty library also means no snippet references any keychain secret, so orphan cleanup
/// used to delete every stored secret on the next launch or reload. A blank file is far more
/// often a truncated sync or an editor accident than a deliberate wipe, and a deleted secret
/// cannot be restored from a library backup. Cleanup therefore waits while the last library
/// read from disk was blank, and resumes once a load reads a real document.
///
/// Adapted from audit/ft-d612c083-blank-library, whose contract (blank = hard read failure)
/// was not taken. Its contract-neutral cases are kept unchanged.
final class BlankLibraryLoadTests: XCTestCase {
    private struct Fixture {
        let support: URL
        let file: URL
        let backing: InMemorySecretBackingStore
        let store: SnippetStore
        let snippetID: UUID
        let secretID: UUID
    }

    private func makeLoadedLibrary(
        components: [String] = [],
        fileName: String = "snippets.json"
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeBlankLibrary-\(UUID().uuidString)", isDirectory: true)
        var support = root
        for component in components {
            support = support.appendingPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let file = support.appendingPathComponent(fileName)
        let snippetID = UUID()
        let secretID = UUID()
        let snippet = SnippetModel(id: snippetID, title: "A", triggerKeyword: ":a", replacementText: "kept")
        let secret = SecretModel(id: secretID, title: "Work")
        let document = SnippetDocument(
            groups: [SnippetGroup(name: "General", snippets: [snippet])],
            secrets: [secret]
        )
        try JSONEncoder().encode(document).write(to: file)
        let backing = InMemorySecretBackingStore(seed: [secretID.uuidString: "synthetic"])
        let store = SnippetStore(
            location: .init(fileURL: file, expectsExistingLibrary: true),
            localSupportDirectory: support,
            watcherFactory: { _ in nil },
            secretStore: SecretStore(backing: backing),
            secretPurgeEnabled: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(store.loadSnippets().map(\.id).sorted(), [snippetID, secretID].sorted())
        XCTAssertFalse(store.isLibraryReadFailed)
        return Fixture(support: support, file: file, backing: backing, store: store,
                       snippetID: snippetID, secretID: secretID)
    }

    private func corruptedCopies(in support: URL) -> [URL] {
        let backups = support.appendingPathComponent("Backups", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        return names
            .filter { $0.contains("corrupted") }
            .map { backups.appendingPathComponent($0) }
    }

    private static let blankPayloads: [(String, Data)] = {
        let bom = Data([0xEF, 0xBB, 0xBF])
        return [
            ("empty", Data()),
            ("spaces", Data("   ".utf8)),
            ("newlines", Data("\n\r\n".utf8)),
            ("cr only", Data("\r".utf8)),
            ("lf only", Data("\n".utf8)),
            ("tabs", Data("\t\t".utf8)),
            ("mixed ascii", Data(" \t\r\n ".utf8)),
            ("bom plus whitespace", bom + Data(" \t\n".utf8)),
            ("bom only", bom),
            ("repeated bom", bom + bom + bom),
            ("unicode whitespace", Data("\u{00A0}\u{2003}\u{3000}\u{000B}\u{000C}\u{2028}\u{2029}".utf8)),
            ("nbsp only", Data("\u{00A0}".utf8)),
            ("ideographic space only", Data("\u{3000}".utf8)),
            ("line separator only", Data("\u{2028}".utf8)),
            ("paragraph separator only", Data("\u{2029}".utf8)),
            ("next line", Data("\u{0085}".utf8)),
            ("vertical tab", Data("\u{000B}".utf8)),
            ("form feed", Data("\u{000C}".utf8)),
            ("ogham space", Data("\u{1680}".utf8)),
            ("en quad", Data("\u{2000}".utf8)),
            ("narrow no-break space", Data("\u{202F}".utf8)),
            ("medium mathematical space", Data("\u{205F}".utf8)),
            ("zero width space", Data("\u{200B}".utf8)),
            ("bom inside whitespace", Data(" \u{FEFF}\t\n".utf8)),
            ("bom between spaces", Data("  \u{FEFF}  ".utf8)),
            ("several hundred kb of spaces", Data(repeating: 0x20, count: 256 * 1024)),
        ]
    }()

    /// A reload onto a blank file adopts the empty library, and cleanup keeps every secret.
    func testBlankAndWhitespaceLibrariesLoadEmptyAndDoNotPurgeSecrets() throws {
        for (label, payload) in Self.blankPayloads {
            let fixture = try makeLoadedLibrary()
            try payload.write(to: fixture.file)

            let loaded = SnippetStore.loadFrom(
                .init(fileURL: fixture.file, expectsExistingLibrary: true),
                backups: LibraryBackupStore(directory: fixture.support.appendingPathComponent("Backups"))
            )
            XCTAssertTrue(loaded.decodeSucceeded, label)
            XCTAssertNil(loaded.hardFailure, label)
            XCTAssertEqual(loaded.loadIssue, .emptyFile(path: fixture.file.path), label)
            XCTAssertTrue(loaded.groups.isEmpty, label)

            fixture.store.reloadFromDisk()
            fixture.store.reloadFromDisk()

            XCTAssertFalse(fixture.store.isLibraryReadFailed, label)
            XCTAssertTrue(fixture.store.loadSnippets().isEmpty, label)
            XCTAssertEqual(try Data(contentsOf: fixture.file), payload, label)
            XCTAssertTrue(corruptedCopies(in: fixture.support).isEmpty, label)

            let cleanup = fixture.store.retryOrphanSecretCleanup()
            XCTAssertEqual(cleanup.removed, 0, "a blank file must not purge secrets: \(label)")
            XCTAssertEqual(cleanup.attempted, 0, label)
            XCTAssertGreaterThan(cleanup.deferred, 0, "cleanup waits, it does not decide: \(label)")
            XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString], label)
        }
    }

    /// The UI consumes `lastLoadIssue` once it has shown the alert. Consuming it must not lift
    /// the cleanup hold: the file on disk is still blank.
    func testConsumingTheEmptyFileIssueDoesNotLiftTheHold() throws {
        let fixture = try makeLoadedLibrary()
        try Data(" \n".utf8).write(to: fixture.file)
        fixture.store.reloadFromDisk()
        XCTAssertEqual(fixture.store.consumeLastLoadIssue(), .emptyFile(path: fixture.file.path))
        XCTAssertNil(fixture.store.lastLoadIssue)

        XCTAssertEqual(fixture.store.retryOrphanSecretCleanup().removed, 0)
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString])
    }

    /// Where the hold ends. A save in the same session does not lift it, so a library restored
    /// from a backup later in that session still finds its secrets. The next load that reads a
    /// real document does lift it: from then on the saved library is what the user has, and a
    /// secret it does not reference is an orphan. A blank file is protected until then, not forever.
    func testASaveKeepsTheHoldAndTheNextRealLoadLiftsIt() throws {
        let fixture = try makeLoadedLibrary()
        try Data().write(to: fixture.file)
        fixture.store.reloadFromDisk()

        let kept = SnippetModel(title: "B", triggerKeyword: ":b", replacementText: "new")
        XCTAssertTrue(fixture.store.saveGroups([SnippetGroup(name: "General", snippets: [kept])]).didSave)
        XCTAssertEqual(fixture.store.retryOrphanSecretCleanup().removed, 0, "a save does not lift the hold")
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString])

        fixture.store.reloadFromDisk()
        let cleanup = fixture.store.retryOrphanSecretCleanup()
        XCTAssertEqual(cleanup.removed, 1, "a load of a real document lifts the hold")
        XCTAssertTrue(fixture.backing.accounts().isEmpty)
    }

    /// Restoring the library that references the secret, after a blank load, keeps it.
    func testRestoringTheLibraryAfterABlankLoadKeepsItsSecret() throws {
        let fixture = try makeLoadedLibrary()
        let original = try Data(contentsOf: fixture.file)
        try Data().write(to: fixture.file)
        fixture.store.reloadFromDisk()
        XCTAssertEqual(fixture.store.retryOrphanSecretCleanup().removed, 0)

        try original.write(to: fixture.file)
        fixture.store.reloadFromDisk()
        XCTAssertEqual(
            fixture.store.loadSnippets().map(\.id).sorted(),
            [fixture.snippetID, fixture.secretID].sorted()
        )
        let cleanup = fixture.store.retryOrphanSecretCleanup()
        XCTAssertEqual(cleanup.removed, 0)
        XCTAssertEqual(cleanup.deferred, 0)
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString])
    }

    func testBlankReloadAfterAHardFailureAddsNoCorruptedCopyAndPurgesNothing() throws {
        let fixture = try makeLoadedLibrary()
        try Data("{not-json".utf8).write(to: fixture.file)
        fixture.store.reloadFromDisk()
        XCTAssertEqual(corruptedCopies(in: fixture.support).count, 1)
        XCTAssertTrue(fixture.store.isLibraryReadFailed)

        try Data(" \t\r\n\u{00A0}\u{3000}".utf8).write(to: fixture.file)
        fixture.store.reloadFromDisk()
        fixture.store.reloadFromDisk()

        XCTAssertEqual(corruptedCopies(in: fixture.support).count, 1)
        XCTAssertEqual(fixture.store.retryOrphanSecretCleanup().removed, 0)
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString])
    }

    func testWellFormedEmptyDocumentStillAdoptsAndPurgesOrphans() throws {
        let documents = [
            Data("[]".utf8),
            Data(" \n\t[]\r\n".utf8),
            Data("[ ]".utf8),
            Data(" \t[\r\n] ".utf8),
            try JSONEncoder().encode(SnippetDocument(groups: [])),
            try JSONEncoder().encode(SnippetDocument(groups: [
                SnippetGroup(name: "General", snippets: [])
            ])),
            Data("\n{\"schemaVersion\":3,\"groups\":[],\"secrets\":[]}\n".utf8),
            Data("{\"groups\":[]}".utf8),
            Data(" \n{\"groups\":[{\"name\":\"General\"}]}\n".utf8),
            Data([0xEF, 0xBB, 0xBF]) + Data("[]".utf8),
            Data([0xEF, 0xBB, 0xBF]) + Data("{\"groups\":[],\"secrets\":[]}".utf8),
        ]
        for document in documents {
            let fixture = try makeLoadedLibrary()
            try document.write(to: fixture.file)
            let loaded = SnippetStore.loadFrom(
                .init(fileURL: fixture.file, expectsExistingLibrary: true),
                backups: LibraryBackupStore(directory: fixture.support.appendingPathComponent("Backups"))
            )
            XCTAssertTrue(loaded.decodeSucceeded, "bytes \(document as NSData)")
            XCTAssertNil(loaded.hardFailure)
            XCTAssertTrue(loaded.groups.flatMap(\.snippets).isEmpty)

            fixture.store.reloadFromDisk()
            XCTAssertFalse(fixture.store.isLibraryReadFailed)
            XCTAssertTrue(fixture.store.loadSnippets().isEmpty)
            let cleanup = fixture.store.retryOrphanSecretCleanup()
            XCTAssertEqual(cleanup.removed, 1, "a decoded empty library must drop orphaned secrets")
            XCTAssertEqual(cleanup.deferred, 0)
            XCTAssertTrue(fixture.backing.accounts().isEmpty)
            XCTAssertTrue(fixture.store.saveGroups([]).didSave)
        }
    }

    func testBrokenJSONKeepsThePreviousCacheAndWritesOneCorruptedCopy() throws {
        let fixture = try makeLoadedLibrary()
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: fixture.file)

        fixture.store.reloadFromDisk()
        let copies = corruptedCopies(in: fixture.support)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: copies[0]), corrupt)
        XCTAssertTrue(fixture.store.isLibraryReadFailed)
        XCTAssertEqual(
            fixture.store.loadSnippets().map(\.id).sorted(),
            [fixture.snippetID, fixture.secretID].sorted()
        )
        XCTAssertFalse(fixture.store.saveGroups([]).didSave)
        XCTAssertEqual(try Data(contentsOf: fixture.file), corrupt)

        fixture.store.reloadFromDisk()
        XCTAssertEqual(corruptedCopies(in: fixture.support).count, 1, "a repeated failed load must reuse the copy")
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString])

        let summary = fixture.store.secretStore.purgeOrphans(keepingLatest: { nil })
        XCTAssertEqual(summary.deferred, 1)
        XCTAssertEqual(summary.removed, 0)
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString])
    }

    func testObjectShapedGarbageAndNonUTF8DoNotAdoptAnEmptyLibrary() throws {
        let cases: [(String, Data)] = [
            ("brace then garbage", Data("{not-json".utf8)),
            ("whitespace then brace garbage", Data(" \n\t{not-json".utf8)),
            ("empty object", Data("{}".utf8)),
            ("whitespace then empty object", Data(" \n\t{}\r\n".utf8)),
            ("null", Data("null".utf8)),
            ("true", Data("true".utf8)),
            ("zero", Data("0".utf8)),
            ("json string", Data("\"\"".utf8)),
            ("array garbage", Data("[}".utf8)),
            ("nbsp then array", Data("\u{00A0}[]".utf8)),
            ("mongolian vowel separator", Data("\u{180E}".utf8)),
            ("spaces around mongolian vowel separator", Data(" \u{180E} ".utf8)),
            ("nul then brace", Data([0x00, 0x7B])),
            ("incomplete bom", Data([0xEF])),
            ("lone continuation", Data([0x80, 0x41])),
            ("invalid utf-8", Data([0xC3, 0x28])),
            ("latin-1 nbsp", Data([0xA0])),
            ("high bytes", Data([0xFF, 0xFE, 0x80])),
        ]
        for (label, payload) in cases {
            try assertCorruptKeepsLibrary(payload, label: label)
        }
    }

    func testUTF16LibraryRoundTripsAndInvalidUTF16StaysCorrupt() throws {
        let snippetID = UUID()
        let secretID = UUID()
        let snippet = SnippetModel(id: snippetID, title: "A", triggerKeyword: ":a", replacementText: "kept")
        let secret = SecretModel(id: secretID, title: "Work")
        let document = SnippetDocument(
            groups: [SnippetGroup(name: "General", snippets: [snippet])],
            secrets: [secret]
        )
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(document), encoding: .utf8))
        for (label, payload) in utf16BOMEncodings(of: json) {
            let support = FileManager.default.temporaryDirectory
                .appendingPathComponent("DevTypeUTF16-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: support) }
            let file = support.appendingPathComponent("snippets.json")
            try payload.write(to: file)

            let loaded = SnippetStore.loadFrom(
                .init(fileURL: file, expectsExistingLibrary: true),
                backups: LibraryBackupStore(directory: support.appendingPathComponent("Backups"))
            )
            XCTAssertTrue(loaded.decodeSucceeded, label)
            XCTAssertNil(loaded.hardFailure, label)
            XCTAssertEqual(
                Set(loaded.groups.flatMap(\.snippets).map(\.id)),
                [snippetID, secretID],
                label
            )

            let backing = InMemorySecretBackingStore(seed: [secretID.uuidString: "synthetic"])
            let store = SnippetStore(
                location: .init(fileURL: file, expectsExistingLibrary: true),
                localSupportDirectory: support,
                watcherFactory: { _ in nil },
                secretStore: SecretStore(backing: backing),
                secretPurgeEnabled: true
            )
            XCTAssertFalse(store.isLibraryReadFailed, label)
            XCTAssertEqual(Set(store.loadSnippets().map(\.id)), [snippetID, secretID], label)
            let cleanup = store.retryOrphanSecretCleanup()
            XCTAssertEqual(cleanup.removed, 0, label)
            XCTAssertEqual(cleanup.deferred, 0, label)
            XCTAssertEqual(backing.accounts(), [secretID.uuidString], label)
            XCTAssertTrue(corruptedCopies(in: support).isEmpty, label)
        }

        for (label, payload) in utf16BOMEncodings(of: "{not-json") {
            try assertCorruptKeepsLibrary(payload, label: label)
        }
    }

    func testBlankLibraryInUnicodeDirectoryLoadsEmptyAndKeepsTheSecret() throws {
        let fixture = try makeLoadedLibrary(components: [
            "空白 ライブラリ\u{0301}",
            "dir\u{00A0}name",
        ], fileName: "スニペット.json")
        let payload = Data(" \t\r\n\u{FEFF}\u{3000}".utf8)
        try payload.write(to: fixture.file)
        fixture.store.reloadFromDisk()
        XCTAssertFalse(fixture.store.isLibraryReadFailed)
        XCTAssertTrue(fixture.store.loadSnippets().isEmpty)
        XCTAssertTrue(corruptedCopies(in: fixture.support).isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.file), payload)
        XCTAssertEqual(fixture.store.retryOrphanSecretCleanup().removed, 0)
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString])
    }

    /// A launch onto a blank file, with secrets already in the keychain from an earlier session.
    func testColdInitOnBlankFileDoesNotPurgePreexistingSecrets() throws {
        let secretID = UUID()
        let payloads: [(String, Data, Bool)] = [
            ("empty", Data(), true),
            ("spaces", Data(" \t\r\n".utf8), true),
            ("nbsp", Data("\u{00A0}\u{3000}".utf8), true),
            ("local empty", Data(), false),
            ("hundreds of kb", Data(repeating: 0x20, count: 256 * 1024), true),
        ]
        for (label, payload, expectsExisting) in payloads {
            let support = FileManager.default.temporaryDirectory
                .appendingPathComponent("DevTypeColdBlank-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("空白\u{00A0}dir", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
            let file = support.appendingPathComponent("snippets.json")
            try payload.write(to: file)

            let probe = PurgeProbeBacking(seed: [secretID.uuidString: "synthetic"])
            let store = SnippetStore(
                location: .init(fileURL: file, expectsExistingLibrary: expectsExisting),
                localSupportDirectory: support,
                watcherFactory: { _ in nil },
                secretStore: SecretStore(backing: probe),
                secretPurgeEnabled: true
            )

            XCTAssertFalse(store.isLibraryReadFailed, label)
            XCTAssertEqual(store.lastLoadIssue, .emptyFile(path: file.path), label)
            XCTAssertTrue(store.loadSnippets().isEmpty, label)
            XCTAssertEqual(try Data(contentsOf: file), payload, label)
            XCTAssertTrue(corruptedCopies(in: support).isEmpty, label)

            probe.resetCounts()
            let summary = store.retryOrphanSecretCleanup()
            XCTAssertEqual(summary.removed, 0, label)
            XCTAssertEqual(summary.attempted, 0, label)
            XCTAssertGreaterThan(summary.deferred, 0, "a blank library must defer: \(label)")
            XCTAssertEqual(probe.conditionalDeletes, 0, "purge must not reach a delete: \(label)")
            XCTAssertEqual(probe.approvedDeletes, 0, label)
            XCTAssertEqual(probe.accounts(), [secretID.uuidString], label)
        }

        try assertColdInitOnBrokenJSONDefers(secretID: secretID)
    }

    /// A launch onto broken JSON latches the read failure. The cache stays unset rather than
    /// holding the loader's default `[]`, so the live-ID projection is nil (unknown), not empty.
    private func assertColdInitOnBrokenJSONDefers(secretID: UUID) throws {
        let label = "broken json"
        let payload = Data("{".utf8)
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeColdBlank-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("空白\u{00A0}dir", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
        let file = support.appendingPathComponent("snippets.json")
        try payload.write(to: file)

        let probe = PurgeProbeBacking(seed: [secretID.uuidString: "synthetic"])
        let store = SnippetStore(
            location: .init(fileURL: file, expectsExistingLibrary: true),
            localSupportDirectory: support,
            watcherFactory: { _ in nil },
            secretStore: SecretStore(backing: probe),
            secretPurgeEnabled: true
        )

        XCTAssertTrue(store.isLibraryReadFailed, label)
        XCTAssertEqual(try Data(contentsOf: file), payload, label)
        let copies = corruptedCopies(in: support)
        XCTAssertEqual(copies.count, 1, label)
        XCTAssertEqual(try Data(contentsOf: copies[0]), payload, label)
        XCTAssertNil(store.committedLiveSecretIDs(), "init must not publish an empty library: \(label)")
        _ = store.loadSnippets().count
        XCTAssertNil(store.committedLiveSecretIDs(), "a read must not publish an empty library: \(label)")

        probe.resetCounts()
        XCTAssertFalse(store.saveGroups([]).didSave, label)
        XCTAssertEqual(probe.accountReads, 0, "save must not call purgeOrphans: \(label)")

        let summary = store.retryOrphanSecretCleanup()
        XCTAssertEqual(summary.removed, 0, label)
        XCTAssertEqual(summary.attempted, 0, label)
        XCTAssertGreaterThan(summary.deferred, 0, "nil live IDs must defer: \(label)")
        XCTAssertEqual(probe.conditionalDeletes, 0, "purge must not be handed an empty set: \(label)")
        XCTAssertEqual(probe.accounts(), [secretID.uuidString], label)
        XCTAssertEqual(try Data(contentsOf: file), payload, label)
    }

    private func assertCorruptKeepsLibrary(_ payload: Data, label: String) throws {
        let fixture = try makeLoadedLibrary()
        try payload.write(to: fixture.file)
        let loaded = SnippetStore.loadFrom(
            .init(fileURL: fixture.file, expectsExistingLibrary: true),
            backups: LibraryBackupStore(directory: fixture.support.appendingPathComponent("Backups"))
        )
        XCTAssertFalse(loaded.decodeSucceeded, label)
        XCTAssertNotNil(loaded.hardFailure, label)
        if case .corrupted? = loaded.loadIssue {
        } else {
            XCTFail("decode failure must quarantine the bytes actually read: \(label) issue=\(String(describing: loaded.loadIssue))")
        }

        fixture.store.reloadFromDisk()
        fixture.store.reloadFromDisk()
        XCTAssertTrue(fixture.store.isLibraryReadFailed, label)
        XCTAssertEqual(
            fixture.store.loadSnippets().map(\.id).sorted(),
            [fixture.snippetID, fixture.secretID].sorted(),
            label
        )
        XCTAssertFalse(fixture.store.saveGroups([]).didSave, label)
        XCTAssertEqual(try Data(contentsOf: fixture.file), payload, label)
        let copies = corruptedCopies(in: fixture.support)
        XCTAssertEqual(copies.count, 1, label)
        XCTAssertEqual(try Data(contentsOf: copies[0]), payload, label)
        XCTAssertEqual(fixture.store.retryOrphanSecretCleanup().removed, 0, label)
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString], label)
    }

    private func utf16BOMEncodings(of text: String) -> [(String, Data)] {
        let units = Array(text.utf16)
        var le = Data()
        var be = Data()
        le.reserveCapacity(units.count * 2)
        be.reserveCapacity(units.count * 2)
        for unit in units {
            le.append(UInt8(unit & 0xFF))
            le.append(UInt8((unit >> 8) & 0xFF))
            be.append(UInt8((unit >> 8) & 0xFF))
            be.append(UInt8(unit & 0xFF))
        }
        return [
            ("utf16le-bom \(text.prefix(12))", Data([0xFF, 0xFE]) + le),
            ("utf16be-bom \(text.prefix(12))", Data([0xFE, 0xFF]) + be),
        ]
    }
}

/// Counts what orphan cleanup asked the backing to do, so a test can tell "deferred" from
/// "reached a delete that the confirmation then refused".
private final class PurgeProbeBacking: SecretBackingStore {
    let inner: InMemorySecretBackingStore
    private let lock = NSLock()
    private(set) var accountReads = 0
    private(set) var conditionalDeletes = 0
    private(set) var approvedDeletes = 0

    init(seed: [String: String]) {
        inner = InMemorySecretBackingStore(seed: seed)
    }

    func resetCounts() {
        lock.lock()
        accountReads = 0
        conditionalDeletes = 0
        approvedDeletes = 0
        lock.unlock()
    }

    func performExclusiveTransaction(_ body: () -> Void) -> Bool {
        inner.performExclusiveTransaction(body)
    }

    func set(_ value: String, account: String) -> OSStatus {
        inner.set(value, account: account)
    }

    func value(account: String) -> String? {
        inner.value(account: account)
    }

    func contains(account: String) -> Bool {
        inner.contains(account: account)
    }

    func delete(account: String) -> OSStatus {
        inner.delete(account: account)
    }

    func delete(account: String, if shouldDelete: () -> Bool) -> OSStatus? {
        lock.lock()
        conditionalDeletes += 1
        lock.unlock()
        return inner.delete(account: account, if: {
            let approved = shouldDelete()
            if approved {
                self.lock.lock()
                self.approvedDeletes += 1
                self.lock.unlock()
            }
            return approved
        })
    }

    func accounts() -> Set<String> {
        lock.lock()
        accountReads += 1
        lock.unlock()
        return inner.accounts()
    }
}
