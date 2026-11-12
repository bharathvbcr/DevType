import XCTest
@testable import ExpanderEngine

/// A blank `snippets.json` (zero bytes, or only whitespace) loads as an empty library with an
/// `.emptyFile` issue. That is the contract: it is not a read failure, and saving is allowed.
///
/// An empty library also means no snippet references any keychain secret, so orphan cleanup
/// used to delete every stored secret on the next launch or reload. A blank file is far more
/// often a truncated sync or an editor accident than a deliberate wipe, and a deleted secret
/// cannot be restored from a library backup. While the last library read from disk was blank,
/// cleanup therefore keeps every secret except those this session introduced and then
/// dropped, and resumes fully once a load reads a real document.
///
/// Adapted from audit/ft-d612c083-blank-library, whose contract (blank = hard read failure)
/// was not taken. Its contract-neutral cases are kept unchanged.
final class BlankLibrarySecretPurgeTests: XCTestCase {
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
            XCTAssertEqual(cleanup.deferred, 0, "a protected secret is retained, not left pending: \(label)")
            XCTAssertEqual(fixture.store.pendingSecretCleanupCount, 0, label)
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
    /// A save keeps the hold, and so does re-reading the file that save wrote: it is DevType's
    /// own. Only a real library DevType did not write lifts it.
    func testASaveKeepsTheHoldAndOnlyAForeignLibraryLiftsIt() throws {
        let fixture = try makeLoadedLibrary()
        try Data().write(to: fixture.file)
        fixture.store.reloadFromDisk()

        let kept = SnippetModel(title: "B", triggerKeyword: ":b", replacementText: "new")
        XCTAssertTrue(fixture.store.saveGroups([SnippetGroup(name: "General", snippets: [kept])]).didSave)
        XCTAssertEqual(fixture.store.retryOrphanSecretCleanup().removed, 0, "a save does not lift the hold")
        fixture.store.reloadFromDisk()
        XCTAssertEqual(fixture.store.retryOrphanSecretCleanup().removed, 0, "DevType's own file does not lift it")
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString])

        // Another Mac (or the user) puts a real library there.
        let foreign = SnippetModel(title: "Elsewhere", triggerKeyword: ":e", replacementText: "x")
        try JSONEncoder().encode(SnippetDocument(groups: [SnippetGroup(name: "General", snippets: [foreign])]))
            .write(to: fixture.file)
        fixture.store.reloadFromDisk()
        _ = fixture.store.retryOrphanSecretCleanup()
        XCTAssertTrue(fixture.backing.accounts().isEmpty, "a library DevType did not write lifts the hold")
    }

    /// A blank read followed by reads that are not a document — corrupt bytes, then the Retry
    /// the alert offers — must keep the hold. Retry clears the latch and serves the cached empty
    /// library without re-reading, so without the hold cleanup would confirm an empty set.
    func testACorruptReadAndRetryAfterABlankLoadKeepTheHold() throws {
        let fixture = try makeLoadedLibrary()
        try Data().write(to: fixture.file)
        fixture.store.reloadFromDisk()

        try Data("{not-json".utf8).write(to: fixture.file)
        fixture.store.reloadFromDisk()
        XCTAssertTrue(fixture.store.isLibraryReadFailed)
        fixture.store.clearLibraryReadFailure()
        _ = fixture.store.loadGroups()
        XCTAssertFalse(fixture.store.isLibraryReadFailed)

        let cleanup = fixture.store.retryOrphanSecretCleanup()
        XCTAssertEqual(cleanup.removed, 0)
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString])

        try FileManager.default.removeItem(at: fixture.file)
        fixture.store.reloadFromDisk()
        XCTAssertEqual(fixture.store.retryOrphanSecretCleanup().removed, 0, "a vanished file is not a document")
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString])
    }

    /// "Restore from Backup…" after a blank load brings back the library that references the
    /// secret, and the secret is still there to come back to.
    func testRestoringFromABackupAfterABlankLoadKeepsItsSecret() throws {
        let fixture = try makeLoadedLibrary()
        // A save keeps the bytes it replaces — the library holding the secret — as a backup.
        let groups = fixture.store.loadGroups()
        let extra = SnippetModel(title: "B", triggerKeyword: ":b", replacementText: "new")
        var edited = groups
        edited[0].snippets.append(extra)
        XCTAssertTrue(fixture.store.saveGroups(edited).didSave)
        let backup = try XCTUnwrap(fixture.store.libraryBackups().first { $0.kind == .save }).url

        try Data().write(to: fixture.file)
        fixture.store.reloadFromDisk()
        XCTAssertEqual(fixture.store.retryOrphanSecretCleanup().removed, 0)

        XCTAssertTrue(fixture.store.restoreLibrary(fromBackup: backup).didRestore)
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

        let summary = fixture.store.retryOrphanSecretCleanup()
        XCTAssertEqual(summary.removed, 0)
        XCTAssertEqual(summary.attempted, 0)
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
            XCTAssertEqual(summary.deferred, 0, "a protected secret is retained, not left pending: \(label)")
            XCTAssertEqual(probe.conditionalDeletes, 0, "purge must not reach a delete: \(label)")
            XCTAssertEqual(probe.approvedDeletes, 0, label)
            XCTAssertEqual(probe.accounts(), [secretID.uuidString], label)
        }

        try assertColdInitOnBrokenJSONDefers(secretID: secretID)
    }

    /// During the hold, a secret introduced and dropped in this session is purged; the secret
    /// that predates the blank load is not.
    func testASecretIntroducedAndDroppedAfterABlankLoadIsPurgedButTheOldOneIsKept() throws {
        let fixture = try makeLoadedLibrary()
        try Data().write(to: fixture.file)
        fixture.store.reloadFromDisk()

        let secrets = fixture.store.secretStore
        let keep = SnippetModel(title: "Keep", triggerKeyword: ";k", replacementText: "", isSecret: true)
        let drop = SnippetModel(title: "Drop", triggerKeyword: ";d", replacementText: "", isSecret: true)
        secrets.store("keep-me", for: keep.id)
        secrets.store("delete-me", for: drop.id)
        XCTAssertTrue(fixture.store.saveGroups([SnippetGroup(name: "General", snippets: [keep, drop])]).didSave)
        XCTAssertTrue(fixture.store.saveGroups([SnippetGroup(name: "General", snippets: [keep])]).didSave)

        let summary = fixture.store.retryOrphanSecretCleanup()
        XCTAssertNil(secrets.secret(for: drop.id))
        XCTAssertEqual(secrets.secret(for: keep.id), "keep-me")
        XCTAssertTrue(fixture.backing.accounts().contains(fixture.secretID.uuidString))
        XCTAssertEqual(summary.deferred, 0)
        XCTAssertEqual(fixture.store.pendingSecretCleanupCount, 0)
    }

    /// A restore during the hold brings back secrets that predate it. Dropping one of them again
    /// in the same session must not purge it: restores do not count as introducing a secret.
    func testARestoredSecretDroppedDuringTheHoldIsKept() throws {
        let fixture = try makeLoadedLibrary()
        let groups = fixture.store.loadGroups()
        var edited = groups
        edited[0].snippets.append(SnippetModel(title: "B", triggerKeyword: ":b", replacementText: "new"))
        XCTAssertTrue(fixture.store.saveGroups(edited).didSave)
        let backup = try XCTUnwrap(fixture.store.libraryBackups().first { $0.kind == .save }).url

        try Data().write(to: fixture.file)
        fixture.store.reloadFromDisk()
        XCTAssertTrue(fixture.store.restoreLibrary(fromBackup: backup).didRestore)
        XCTAssertTrue(fixture.store.loadSnippets().map(\.id).contains(fixture.secretID))

        let withoutSecret = fixture.store.loadGroups().map { group -> SnippetGroup in
            var group = group
            group.snippets.removeAll { $0.id == fixture.secretID }
            return group
        }
        XCTAssertTrue(fixture.store.saveGroups(withoutSecret).didSave)
        XCTAssertEqual(fixture.store.retryOrphanSecretCleanup().removed, 0)
        XCTAssertEqual(fixture.backing.accounts(), [fixture.secretID.uuidString])
    }

    /// The policy is asked again inside the conditional delete: a hold that starts between
    /// candidate selection and the delete still retains the secret.
    func testThePolicyIsCheckedAgainInsideTheConditionalDelete() {
        let orphan = UUID()
        let backing = InMemorySecretBackingStore(seed: [orphan.uuidString: "synthetic"])
        let store = SecretStore(backing: backing)
        var asked = 0
        let summary = store.purgeOrphans(
            keepingLatest: { [] },
            confirmingLatest: { [] },
            mayDelete: { _ in
                asked += 1
                return asked == 1
            }
        )
        XCTAssertEqual(asked, 2, "asked at selection and again inside the delete")
        XCTAssertEqual(summary.removed, 0)
        XCTAssertEqual(summary.deferred, 0)
        XCTAssertEqual(backing.accounts(), [orphan.uuidString])
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

/// A missing local `snippets.json` is seeded with the default snippets, none of them secret.
/// Secrets live in the keychain, outside the library directory, so they survive a deleted
/// library file, a lost library-location preference, or a launch pointed at a fresh directory.
/// Launch cleanup used to read the seeded defaults as "every secret is an orphan" and delete
/// them all. Under the same hold as a blank file, it now keeps them, across relaunches, until
/// a load decodes a real library that DevType did not write since the hold began.
final class MissingLibrarySecretPurgeTests: XCTestCase {
    private struct ColdStart {
        let support: URL
        let holds: URL
        let file: URL
        let probe: PurgeProbeBacking
        let store: SnippetStore
        let secretID: UUID
    }

    private func coldStartOnAMissingLibrary() throws -> ColdStart {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeMissingLibrary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("snippets.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let secretID = UUID()
        let probe = PurgeProbeBacking(seed: [secretID.uuidString: "synthetic"])
        let holds = root.appendingPathComponent("Holds", isDirectory: true)
        let store = launch(file, support: root, holds: holds, probe: probe, expectsExisting: false)
        return ColdStart(support: root, holds: holds, file: file, probe: probe, store: store, secretID: secretID)
    }

    /// A launch of the shared store's shape: purge on, the hold record kept in `holds`.
    private func launch(
        _ file: URL, support: URL, holds: URL, probe: PurgeProbeBacking,
        expectsExisting: Bool, defaults: UserDefaults = .standard
    ) -> SnippetStore {
        SnippetStore(
            location: .init(fileURL: file, expectsExistingLibrary: expectsExisting),
            deviceDefaults: defaults,
            localSupportDirectory: support,
            watcherFactory: { _ in nil },
            secretStore: SecretStore(backing: probe),
            secretPurgeEnabled: true,
            secretCleanupHoldDirectory: holds
        )
    }

    private func relaunch(_ start: ColdStart, at file: URL? = nil) -> SnippetStore {
        launch(file ?? start.file, support: start.support, holds: start.holds, probe: start.probe, expectsExisting: false)
    }

    func testLaunchCleanupAfterSeedingAMissingLibraryKeepsEverySecret() throws {
        let start = try coldStartOnAMissingLibrary()
        XCTAssertTrue(FileManager.default.fileExists(atPath: start.file.path), "the defaults are seeded")
        XCTAssertFalse(start.store.loadSnippets().isEmpty)
        XCTAssertFalse(start.store.isLibraryReadFailed)

        start.probe.resetCounts()
        let summary = start.store.retryOrphanSecretCleanup()
        XCTAssertEqual(summary.removed, 0)
        XCTAssertEqual(summary.attempted, 0)
        XCTAssertEqual(summary.deferred, 0, "a protected secret is retained, not left pending")
        XCTAssertEqual(start.store.pendingSecretCleanupCount, 0)
        XCTAssertEqual(start.probe.conditionalDeletes, 0, "purge must not reach a delete")
        XCTAssertEqual(start.probe.accounts(), [start.secretID.uuidString])
    }

    /// The second launch reads the seeded defaults DevType itself wrote. They are not the
    /// user's library coming back, so the hold stays on and the secret survives.
    func testTheNextLaunchOntoTheSeededDefaultsKeepsTheHold() throws {
        let start = try coldStartOnAMissingLibrary()
        XCTAssertEqual(start.store.retryOrphanSecretCleanup().removed, 0)

        for _ in 0..<3 {
            let relaunched = relaunch(start)
            XCTAssertTrue(relaunched.isSecretCleanupHeld)
            XCTAssertEqual(relaunched.retryOrphanSecretCleanup().removed, 0)
        }
        XCTAssertEqual(start.probe.accounts(), [start.secretID.uuidString])
    }

    /// Saves are DevType's own writes, so they carry the hold across relaunch too. A library
    /// DevType did not write is what ends it.
    func testASaveKeepsTheHoldAcrossRelaunchUntilAForeignLibraryArrives() throws {
        let start = try coldStartOnAMissingLibrary()
        let mine = SnippetModel(title: "Mine", triggerKeyword: ":mine", replacementText: "x")
        XCTAssertTrue(start.store.saveGroups([SnippetGroup(name: "General", snippets: [mine])]).didSave)

        let relaunched = relaunch(start)
        XCTAssertEqual(relaunched.loadSnippets().map(\.triggerKeyword), [":mine"])
        XCTAssertTrue(relaunched.isSecretCleanupHeld)
        XCTAssertEqual(relaunched.retryOrphanSecretCleanup().removed, 0)
        XCTAssertEqual(start.probe.accounts(), [start.secretID.uuidString])

        let foreign = SnippetModel(title: "Synced", triggerKeyword: ":s", replacementText: "y")
        try JSONEncoder().encode(SnippetDocument(groups: [SnippetGroup(name: "General", snippets: [foreign])]))
            .write(to: start.file)
        let afterSync = relaunch(start)
        XCTAssertFalse(afterSync.isSecretCleanupHeld, "a library DevType did not write lifts the hold")
        _ = afterSync.retryOrphanSecretCleanup()
        XCTAssertTrue(start.probe.accounts().isEmpty)
    }

    /// The user puts their original library back: it references the secret, the hold lifts,
    /// and the secret is live again.
    func testPuttingTheOriginalLibraryBackLiftsTheHoldAndKeepsItsSecret() throws {
        let start = try coldStartOnAMissingLibrary()
        let original = SnippetModel(id: start.secretID, title: "Work", triggerKeyword: ";w", replacementText: "", isSecret: true)
        try JSONEncoder().encode(SnippetDocument(groups: [SnippetGroup(name: "General", snippets: [original])]))
            .write(to: start.file)
        let relaunched = relaunch(start)
        XCTAssertFalse(relaunched.isSecretCleanupHeld)
        XCTAssertEqual(relaunched.retryOrphanSecretCleanup().removed, 0)
        XCTAssertEqual(start.probe.accounts(), [start.secretID.uuidString])
    }

    /// A record that exists but cannot be read keeps the hold (fail closed), and the next real
    /// load is taken as DevType's own.
    func testAnUnreadableRecordKeepsTheHold() throws {
        let start = try coldStartOnAMissingLibrary()
        let records = try FileManager.default.contentsOfDirectory(at: start.holds, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(records.count, 1)
        try Data("{torn".utf8).write(to: records[0])

        let first = relaunch(start)
        XCTAssertTrue(first.isSecretCleanupHeld)
        XCTAssertEqual(first.retryOrphanSecretCleanup().removed, 0)
        let second = relaunch(start)
        XCTAssertTrue(second.isSecretCleanupHeld, "the adopted file is DevType's own from now on")
        XCTAssertEqual(second.retryOrphanSecretCleanup().removed, 0)
        XCTAssertEqual(start.probe.accounts(), [start.secretID.uuidString])
    }

    /// The record is keyed by the resolved path: a symlinked folder or the `/private` spelling of
    /// a temporary path finds the same record. A miss here would read as "not held".
    func testTheRecordIsFoundThroughAnotherSpellingOfThePath() throws {
        let start = try coldStartOnAMissingLibrary()
        let link = start.support.deletingLastPathComponent()
            .appendingPathComponent("DevTypeMissingLink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: start.support)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }

        var spellings = [link.appendingPathComponent("snippets.json")]
        let path = start.file.path
        if path.hasPrefix("/private/") {
            spellings.append(URL(fileURLWithPath: String(path.dropFirst("/private".count))))
        } else if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") {
            spellings.append(URL(fileURLWithPath: "/private" + path))
        }
        for spelling in spellings {
            let relaunched = relaunch(start, at: spelling)
            XCTAssertTrue(relaunched.isSecretCleanupHeld, spelling.path)
            XCTAssertEqual(relaunched.retryOrphanSecretCleanup().removed, 0, spelling.path)
        }
        XCTAssertEqual(start.probe.accounts(), [start.secretID.uuidString])
    }

    /// An own-written file that vanishes and comes back — an iCloud file evicted at launch and
    /// materialized again — is still DevType's: the hold keeps the fingerprints of its writes
    /// through a missing load, so it stays on.
    func testAnOwnFileThatVanishesAndReturnsKeepsTheHold() throws {
        let start = try coldStartOnAMissingLibrary()
        let mine = SnippetModel(title: "Mine", triggerKeyword: ":mine", replacementText: "x")
        XCTAssertTrue(start.store.saveGroups([SnippetGroup(name: "General", snippets: [mine])]).didSave)
        let bytes = try Data(contentsOf: start.file)

        try FileManager.default.removeItem(at: start.file)
        start.store.reloadFromDisk()
        XCTAssertTrue(start.store.isSecretCleanupHeld)
        try bytes.write(to: start.file)
        start.store.reloadFromDisk()
        XCTAssertTrue(start.store.isSecretCleanupHeld)

        // The same across a relaunch whose first load finds the file missing.
        try FileManager.default.removeItem(at: start.file)
        let evicted = launch(start.file, support: start.support, holds: start.holds, probe: start.probe, expectsExisting: true)
        XCTAssertTrue(evicted.isSecretCleanupHeld)
        try bytes.write(to: start.file)
        evicted.reloadFromDisk()
        XCTAssertTrue(evicted.isSecretCleanupHeld)
        XCTAssertEqual(evicted.retryOrphanSecretCleanup().removed, 0)
        XCTAssertEqual(start.probe.accounts(), [start.secretID.uuidString])
    }

    /// The user's real library — loaded before any hold — that vanishes and comes back
    /// byte-for-byte was never DevType's write during the hold, so it lifts.
    func testAPreHoldLibraryThatVanishesAndReturnsLiftsTheHold() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeVanish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("snippets.json")
        let theirs = SnippetModel(title: "Theirs", triggerKeyword: ":t", replacementText: "z")
        let bytes = try JSONEncoder().encode(SnippetDocument(groups: [SnippetGroup(name: "General", snippets: [theirs])]))
        try bytes.write(to: file)
        let probe = PurgeProbeBacking(seed: [:])
        let store = launch(file, support: root, holds: root.appendingPathComponent("Holds"), probe: probe, expectsExisting: true)
        XCTAssertFalse(store.isSecretCleanupHeld)

        try FileManager.default.removeItem(at: file)
        store.reloadFromDisk()
        XCTAssertTrue(store.isSecretCleanupHeld)
        try bytes.write(to: file)
        store.reloadFromDisk()
        XCTAssertFalse(store.isSecretCleanupHeld)
    }

    /// The record key must not change between launches when the library's folder did not exist
    /// at the hold's start, nor with a symlinked ancestor, nor with a different letter case on a
    /// case-insensitive volume. The first launch quits without saving.
    func testTheRecordKeyIsStableWhenTheFolderDidNotExistYet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeFreshDir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeFreshLink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }
        let holds = root.appendingPathComponent("Holds", isDirectory: true)
        let secretID = UUID()
        let probe = PurgeProbeBacking(seed: [secretID.uuidString: "synthetic"])

        let viaLink = link.appendingPathComponent("not/yet/here/snippets.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: viaLink.deletingLastPathComponent().path))
        let first = launch(viaLink, support: root, holds: holds, probe: probe, expectsExisting: false)
        XCTAssertTrue(first.isSecretCleanupHeld)

        let direct = root.appendingPathComponent("not/yet/here/snippets.json")
        var spellings = [direct, viaLink]
        if direct.path.hasPrefix("/private/") {
            spellings.append(URL(fileURLWithPath: String(direct.path.dropFirst("/private".count))))
        } else if direct.path.hasPrefix("/var/") || direct.path.hasPrefix("/tmp/") {
            spellings.append(URL(fileURLWithPath: "/private" + direct.path))
        }
        let caseSensitive = (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames) ?? true
        if !caseSensitive {
            spellings.append(root.appendingPathComponent("NOT/Yet/here/SNIPPETS.json"))
        }
        for spelling in spellings {
            let relaunched = launch(spelling, support: root, holds: holds, probe: probe, expectsExisting: false)
            XCTAssertTrue(relaunched.isSecretCleanupHeld, spelling.path)
            XCTAssertEqual(relaunched.retryOrphanSecretCleanup().removed, 0, spelling.path)
        }
        XCTAssertEqual(probe.accounts(), [secretID.uuidString])
    }

    /// Save As writes the library somewhere new. That is DevType's own write: the hold moves
    /// with the library and survives a relaunch at the new path.
    func testSaveAsDuringTheHoldCarriesItToTheNewLocation() throws {
        let start = try coldStartOnAMissingLibrary()
        let suite = "DevTypeHoldSaveAs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = launch(start.file, support: start.support, holds: start.holds, probe: start.probe,
                           expectsExisting: true, defaults: defaults)
        XCTAssertTrue(store.isSecretCleanupHeld)

        let elsewhere = start.support.appendingPathComponent("Shared", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        XCTAssertTrue(store.saveSnippetsAs(toDirectory: elsewhere).success)
        XCTAssertTrue(store.isSecretCleanupHeld)
        XCTAssertEqual(store.retryOrphanSecretCleanup().removed, 0)

        let relaunched = launch(store.activeLocationURL, support: start.support, holds: start.holds,
                                probe: start.probe, expectsExisting: true)
        XCTAssertTrue(relaunched.isSecretCleanupHeld)
        XCTAssertEqual(relaunched.retryOrphanSecretCleanup().removed, 0)
        XCTAssertEqual(start.probe.accounts(), [start.secretID.uuidString])
    }

    /// Linking to a library DevType did not write is the user's library arriving: it lifts.
    func testLinkingToAnExistingLibraryLiftsTheHold() throws {
        let start = try coldStartOnAMissingLibrary()
        let suite = "DevTypeHoldLink-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = launch(start.file, support: start.support, holds: start.holds, probe: start.probe,
                           expectsExisting: true, defaults: defaults)
        let linked = start.support.appendingPathComponent("Linked/snippets.json")
        try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
        let theirs = SnippetModel(title: "Theirs", triggerKeyword: ":t", replacementText: "z")
        try JSONEncoder().encode(SnippetDocument(groups: [SnippetGroup(name: "General", snippets: [theirs])]))
            .write(to: linked)

        _ = store.linkToSnippets(at: linked)
        XCTAssertFalse(store.isSecretCleanupHeld)
        _ = store.retryOrphanSecretCleanup()
        XCTAssertTrue(start.probe.accounts().isEmpty)
    }

    /// A blank load after this session introduced a secret starts the session set over: the
    /// real library the blank read lost may still reference it, so it is kept.
    func testABlankLoadForgetsWhatTheSessionIntroduced() throws {
        let start = try coldStartOnAMissingLibrary()
        let x = SnippetModel(title: "X", triggerKeyword: ";x", replacementText: "", isSecret: true)
        start.store.secretStore.store("x-value", for: x.id)
        XCTAssertTrue(start.store.saveGroups([SnippetGroup(name: "General", snippets: [x])]).didSave)

        try Data().write(to: start.file)
        start.store.reloadFromDisk()
        XCTAssertTrue(start.store.loadSnippets().isEmpty)
        let plain = SnippetModel(title: "P", triggerKeyword: ";p", replacementText: "p")
        XCTAssertTrue(start.store.saveGroups([SnippetGroup(name: "General", snippets: [plain])]).didSave)

        XCTAssertEqual(start.store.retryOrphanSecretCleanup().removed, 0)
        XCTAssertEqual(start.store.secretStore.secret(for: x.id), "x-value", "X may still be in the lost library")
        XCTAssertTrue(start.probe.accounts().contains(start.secretID.uuidString))
    }

    /// During the hold, a secret this session introduced and then dropped is purged in-session;
    /// the secret that predates the hold is not. Nothing is left pending.
    func testASecretIntroducedAndDroppedDuringTheHoldIsPurgedButTheOldOneIsKept() throws {
        let start = try coldStartOnAMissingLibrary()
        let secrets = start.store.secretStore
        let keep = SnippetModel(title: "Keep", triggerKeyword: ";k", replacementText: "", isSecret: true)
        let drop = SnippetModel(title: "Drop", triggerKeyword: ";d", replacementText: "", isSecret: true)
        secrets.store("keep-me", for: keep.id)
        secrets.store("delete-me", for: drop.id)
        XCTAssertTrue(start.store.saveGroups([SnippetGroup(name: "General", snippets: [keep, drop])]).didSave)
        XCTAssertTrue(start.store.saveGroups([SnippetGroup(name: "General", snippets: [keep])]).didSave)

        let summary = start.store.retryOrphanSecretCleanup()
        XCTAssertNil(secrets.secret(for: drop.id), "the snippet this session deleted takes its value with it")
        XCTAssertEqual(secrets.secret(for: keep.id), "keep-me")
        XCTAssertTrue(start.probe.accounts().contains(start.secretID.uuidString), "the pre-existing secret stays")
        XCTAssertEqual(summary.deferred, 0)
        XCTAssertEqual(start.store.pendingSecretCleanupCount, 0)
    }

    /// A first session on a fresh install: one secret saved, nothing pending.
    func testAFreshInstallWithOneSecretShowsNothingPending() throws {
        let start = try coldStartOnAMissingLibrary()
        let mine = SnippetModel(title: "Mine", triggerKeyword: ";m", replacementText: "", isSecret: true)
        start.store.secretStore.store("v", for: mine.id)
        XCTAssertTrue(start.store.saveGroups([SnippetGroup(name: "General", snippets: [mine])]).didSave)
        let summary = start.store.retryOrphanSecretCleanup()
        XCTAssertEqual(summary.deferred, 0)
        XCTAssertEqual(summary.removed, 0)
        XCTAssertEqual(start.store.pendingSecretCleanupCount, 0)
    }

    /// Characterization: this passed before the missing-file hold existed. A configured
    /// (iCloud / linked) location that has not arrived yet blocks saves, so cleanup cannot
    /// confirm; the hold keeps it that way.
    func testAConfiguredLocationThatIsMissingKeepsEverySecret() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeMissingConfigured-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("snippets.json")
        let secretID = UUID()
        let probe = PurgeProbeBacking(seed: [secretID.uuidString: "synthetic"])
        let store = SnippetStore(
            location: .init(fileURL: file, expectsExistingLibrary: true),
            localSupportDirectory: root,
            watcherFactory: { _ in nil },
            secretStore: SecretStore(backing: probe),
            secretPurgeEnabled: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing is seeded over a configured location")
        XCTAssertEqual(store.retryOrphanSecretCleanup().removed, 0)
        XCTAssertEqual(probe.accounts(), [secretID.uuidString])
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
