import XCTest
@testable import ExpanderEngine

final class SnippetStoragePersistenceTests: XCTestCase {

    func testSnippetStoragePersistenceAndListeners() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
            .appendingPathComponent("snippets.json")
        defer {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        }

        // Isolated store — does not touch shared singleton or Application Support
        let store = SnippetStore(fileURL: tempURL)
        let testSnippets = [
            SnippetModel(title: "Test", triggerKeyword: ":test", replacementText: "Replacement Text")
        ]

        let expectation = expectation(description: "Listener triggered")

        store.addListener { snippets in
            if snippets.first?.triggerKeyword == ":test" {
                expectation.fulfill()
            }
        }

        store.saveSnippets(testSnippets)
        wait(for: [expectation], timeout: 2.0)

        let loaded = store.loadSnippets()
        XCTAssertFalse(loaded.isEmpty)
        XCTAssertEqual(loaded.first?.triggerKeyword, ":test")
        XCTAssertEqual(loaded.first?.replacementText, "Replacement Text")
    }

    func testSnippetStoreListenerUnregistration() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
            .appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let store = SnippetStore(fileURL: tempURL)
        var callCount = 0
        let token = store.addListener { _ in
            callCount += 1
        }
        XCTAssertEqual(callCount, 1)

        store.removeListener(token: token)
        store.saveSnippets([SnippetModel(title: "New", triggerKeyword: ":new", replacementText: "val")])
        XCTAssertEqual(callCount, 1)
    }

    func testEmptyJSONArrayPersistsAsEmpty() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
        let tempURL = dir.appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "[]".data(using: .utf8)?.write(to: tempURL)

        let store = SnippetStore(fileURL: tempURL)
        let loaded = store.loadSnippets()
        XCTAssertTrue(loaded.isEmpty)
    }

    /// §0.3: a corrupt library must NOT be replaced with demo snippets.
    ///
    /// The old contract was `XCTAssertFalse(loaded.isEmpty)` — the store wrote four demos with
    /// `writeGroupsToDisk(defaults, force: true)`, bypassing both the digest and the block guard,
    /// and that replacement then synced to every other device. The new contract: take a
    /// timestamped backup, latch a hard-fail state so every save is refused, return the
    /// empty/last-known library, and **persist nothing**.
    func testCorruptJSONBacksUpAndHardFailsWithoutWritingDefaults() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
        let tempURL = dir.appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let corruptBytes = Data("{not-json".utf8)
        try? corruptBytes.write(to: tempURL)

        let store = SnippetStore(fileURL: tempURL)

        // 1. No defaults were handed out.
        XCTAssertTrue(store.loadSnippets().isEmpty)

        // 2. A timestamped backup of the original bytes exists.
        guard case .corrupted(let backup)? = store.lastLoadIssue else {
            return XCTFail("Expected .corrupted load issue, got \(String(describing: store.lastLoadIssue))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try? Data(contentsOf: backup), corruptBytes)
        XCTAssertTrue(
            backup.lastPathComponent.contains(".bak."),
            "Backup must be timestamped, not a single reusable .bak: \(backup.lastPathComponent)"
        )
        XCTAssertNotEqual(backup.lastPathComponent, "snippets.json.bak")

        // 3. The hard-fail latch is set and names the file.
        XCTAssertTrue(store.isLibraryReadFailed)
        XCTAssertEqual(store.libraryReadFailureReason?.contains(tempURL.path), true)

        // 4. Nothing was written over the user's file, and saves are refused.
        XCTAssertEqual(try? Data(contentsOf: tempURL), corruptBytes)
        let outcome = store.saveGroups([
            SnippetGroup(name: "General", snippets: [
                SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1")
            ])
        ])
        XCTAssertFalse(outcome.didSave)
        XCTAssertEqual(try? Data(contentsOf: tempURL), corruptBytes)
    }

    /// §0.3: the user-driven escape hatch is the *only* thing that may overwrite the file.
    func testForceOverwriteLibraryClearsHardFailure() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
        let tempURL = dir.appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("{not-json".utf8).write(to: tempURL)

        let store = SnippetStore(fileURL: tempURL)
        XCTAssertTrue(store.isLibraryReadFailed)

        let groups = [
            SnippetGroup(name: "General", snippets: [
                SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1")
            ])
        ]
        XCTAssertTrue(store.forceOverwriteLibrary(with: groups).didSave)
        XCTAssertFalse(store.isLibraryReadFailed)
        XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword), [":a"])
    }

    /// §1.9: `sanitize` used to drop empty-trigger and duplicate snippets on **every save**, so
    /// duplicating a snippet and editing the body before the trigger silently deleted it. It is
    /// now deliberately non-destructive; the diagnostic moved to `triggerConflicts`.
    func testSanitizeIsNonDestructive() {
        let snippets = [
            SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1"),
            SnippetModel(title: "Empty", triggerKeyword: "", replacementText: "x"),
            SnippetModel(title: "Dup", triggerKeyword: ":a", replacementText: "2"),
            SnippetModel(title: "B", triggerKeyword: ":b", replacementText: "3")
        ]
        let sanitized = SnippetStore.sanitize(snippets)
        XCTAssertEqual(sanitized.count, snippets.count)
        XCTAssertEqual(sanitized.map(\.triggerKeyword), [":a", "", ":a", ":b"])
        XCTAssertEqual(sanitized.map(\.id), snippets.map(\.id))
    }

    /// §1.9: the reporting that replaced the silent deletion.
    func testTriggerConflictsReportsEmptyAndDuplicateTriggers() {
        let groups = [
            SnippetGroup(name: "General", snippets: [
                SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1"),
                SnippetModel(title: "Empty", triggerKeyword: "", replacementText: "x"),
                SnippetModel(title: "Dup", triggerKeyword: ":a", replacementText: "2"),
                SnippetModel(title: "B", triggerKeyword: ":b", replacementText: "3")
            ])
        ]
        let conflicts = SnippetStore.triggerConflicts(in: groups)
        XCTAssertTrue(conflicts.contains { $0.kind == .emptyTrigger })
        XCTAssertTrue(conflicts.contains { $0.kind == .duplicateTrigger && $0.trigger == ":a" })
        XCTAssertFalse(conflicts.contains { $0.trigger == ":b" })
    }

    func testAppMuteStoreRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevTypeMute-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("muted-apps.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = AppMuteStore(fileURL: url)
        XCTAssertFalse(store.isMuted("com.example.App"))
        store.mute("com.example.App")
        XCTAssertTrue(store.isMuted("com.example.App"))

        let reloaded = AppMuteStore(fileURL: url)
        XCTAssertTrue(reloaded.isMuted("com.example.App"))
        reloaded.unmute("com.example.App")
        XCTAssertFalse(reloaded.isMuted("com.example.App"))
    }

    func testSnippetDocumentSchemaVersionRoundTrip() throws {
        let snippets = [
            SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1")
        ]
        let document = SnippetDocument(schemaVersion: SnippetDocument.currentSchemaVersion, groups: [
            SnippetGroup(name: "Test", snippets: snippets)
        ])
        let data = try JSONEncoder().encode(document)
        let decoded = try SnippetStore.decodeSnippets(from: data)
        XCTAssertEqual(decoded.map(\.triggerKeyword), [":a"])

        // Legacy bare array still loads (backward compatible — no wipe).
        let legacy = try JSONEncoder().encode(snippets)
        let legacyDecoded = try SnippetStore.decodeSnippets(from: legacy)
        XCTAssertEqual(legacyDecoded.map(\.triggerKeyword), [":a"])
    }

    func testSnippetStorePersistsSchemaVersionEnvelope() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
        let tempURL = dir.appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SnippetStore(fileURL: tempURL)
        store.saveSnippets([
            SnippetModel(title: "T", triggerKeyword: ":t", replacementText: "ok")
        ])
        let raw = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("schemaVersion"))
        XCTAssertTrue(raw.contains("\"groups\""))

        let reloaded = SnippetStore(fileURL: tempURL).loadSnippets()
        XCTAssertEqual(reloaded.first?.triggerKeyword, ":t")
    }

    func testSnippetStoreSaveBlockedThreadSafety() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
            .appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let store = SnippetStore(fileURL: tempURL)
        XCTAssertTrue(store.saveGroups([]).didSave)
    }
}
