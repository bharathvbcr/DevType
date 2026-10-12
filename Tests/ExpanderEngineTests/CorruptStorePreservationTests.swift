import XCTest
@testable import ExpanderEngine

/// A persisted settings file that cannot be read must survive the store's next save. Before the
/// shared `PersistedFileLoader`, each store loaded with `try?`, started empty, and its first
/// save overwrote the only copy of the user's data without a log line.
///
/// Every test works in a private temp directory; nothing here touches the real Application
/// Support folder.
final class CorruptStorePreservationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeCorruptStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PersistedFileLoader.observer = nil
    }

    override func tearDownWithError() throws {
        PersistedFileLoader.observer = nil
        // Restore access so cleanup can remove permission-denied fixtures.
        if let items = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for item in items {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent(item).path
                )
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private static let corruptBytes = Data("{ this is not json ::: user data".utf8)

    private func makeCorrupt(_ name: String, bytes: Data = CorruptStorePreservationTests.corruptBytes) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// True when some file in the directory holds exactly `bytes`.
    private func directoryPreserves(_ bytes: Data) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { (try? Data(contentsOf: directory.appendingPathComponent($0))) == bytes }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private func captureDiagnostics() -> () -> [String] {
        let lock = NSLock()
        var lines: [String] = []
        PersistedFileLoader.observer = { line in lock.lock(); lines.append(line); lock.unlock() }
        return { lock.lock(); defer { lock.unlock() }; return lines }
    }

    // MARK: Quarantine that cannot move the file

    private struct MoveRefused: Error {}

    func testSaveIsRefusedWhileTheUnreadableOriginalCannotBeMovedAside() throws {
        let url = try makeCorrupt("muted-apps.json")
        let lines = captureDiagnostics()
        let original = PersistedFileLoader.moveItem
        defer { PersistedFileLoader.moveItem = original }
        PersistedFileLoader.moveItem = { _, _ in throw MoveRefused() }

        let store = AppMuteStore(fileURL: url)
        store.mute("com.example.fresh")

        XCTAssertEqual(try Data(contentsOf: url), Self.corruptBytes,
                       "the only copy of the user's data was overwritten after a failed quarantine")
        XCTAssertTrue(lines().joined(separator: "\n").contains("save refused"), "the refusal must be logged")

        // Once the move can succeed, the next save preserves the original and then lands.
        PersistedFileLoader.moveItem = original
        store.mute("com.example.second")
        XCTAssertTrue(directoryPreserves(Self.corruptBytes))
        XCTAssertEqual(AppMuteStore(fileURL: url).allMuted(), ["com.example.fresh", "com.example.second"])
    }

    func testSidecarWriterRefusesToOverwriteAnUnpreservedUnreadableFileAndRetries() throws {
        let url = try makeCorrupt("usage-stats.json")
        let original = PersistedFileLoader.moveItem
        defer { PersistedFileLoader.moveItem = original }
        PersistedFileLoader.moveItem = { _, _ in throw MoveRefused() }

        let store = UsageStatsStore(fileURL: url, flushInterval: 0, flushRetryDelay: 0.01)
        store.recordUsage(for: UUID())
        store.flush()

        XCTAssertEqual(try Data(contentsOf: url), Self.corruptBytes)

        PersistedFileLoader.moveItem = original
        store.flush()
        XCTAssertTrue(directoryPreserves(Self.corruptBytes))
        XCTAssertNotEqual(try Data(contentsOf: url), Self.corruptBytes)
    }

    // MARK: Per-store preservation

    func testCorruptMutedAppsFileIsPreservedAfterNextSave() throws {
        let url = try makeCorrupt("muted-apps.json")
        let lines = captureDiagnostics()

        let store = AppMuteStore(fileURL: url)
        XCTAssertTrue(store.allMuted().isEmpty)
        store.mute("com.example.fresh")

        XCTAssertTrue(directoryPreserves(Self.corruptBytes), "corrupt muted-apps bytes were overwritten")
        XCTAssertEqual(AppMuteStore(fileURL: url).allMuted(), ["com.example.fresh"])
        let joined = lines().joined(separator: "\n")
        XCTAssertTrue(joined.contains("AppMuteStore"), joined)
        XCTAssertTrue(joined.contains("code="), "diagnostic should carry the error: \(joined)")
    }

    func testCorruptCommandUsageStatsFileIsPreservedAfterNextSave() throws {
        let url = try makeCorrupt("command-usage.json")
        let lines = captureDiagnostics()

        let store = CommandUsageStatsStore(fileURL: url)
        store.recordUsage(for: "cmd.one")
        store.flush()

        XCTAssertTrue(directoryPreserves(Self.corruptBytes))
        XCTAssertTrue(lines().joined().contains("CommandUsageStatsStore"))
    }

    func testCorruptSnippetUsageStatsFileIsPreservedAfterNextSave() throws {
        let url = try makeCorrupt("usage-stats.json")
        let lines = captureDiagnostics()

        let store = UsageStatsStore(fileURL: url)
        store.recordUsage(for: UUID())
        store.flush()

        XCTAssertTrue(directoryPreserves(Self.corruptBytes))
        XCTAssertTrue(lines().joined().contains("UsageStatsStore"))
    }

    func testCorruptAXWriteCapabilityFileIsPreservedAfterNextSave() throws {
        let url = try makeCorrupt("ax-write-capability.json")
        let lines = captureDiagnostics()

        let store = AXWriteCapabilityStore(fileURL: url, currentBuild: { _ in "1" })
        store.recordFalseSuccess(bundleID: "com.example.app")
        XCTAssertTrue(waitUntil {
            (try? Data(contentsOf: url)).map { $0 != Self.corruptBytes } ?? false
        }, "store never saved")

        XCTAssertTrue(directoryPreserves(Self.corruptBytes))
        XCTAssertTrue(lines().joined().contains("AXWriteCapabilityStore"))
    }

    // MARK: Adversarial inputs (loader contract)

    func testAbsentAndZeroByteFilesAreNotQuarantinedOrLogged() throws {
        let lines = captureDiagnostics()
        let missing = directory.appendingPathComponent("missing.json")
        let empty = try makeCorrupt("empty.json", bytes: Data())

        for url in [missing, empty] {
            let outcome = PersistedFileLoader.load(store: "T", fileURL: url) {
                try JSONDecoder().decode([String].self, from: $0)
            }
            guard case .absent = outcome else { return XCTFail("expected absent for \(url.lastPathComponent)") }
        }
        XCTAssertTrue(lines().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
    }

    func testTruncatedAndWrongTypeJSONAreQuarantined() throws {
        for (name, bytes) in [
            ("truncated.json", Data("[\"a\", \"b".utf8)),
            ("wrongtype.json", Data("{\"a\": 1}".utf8)),
        ] {
            let url = try makeCorrupt(name, bytes: bytes)
            let outcome = PersistedFileLoader.load(store: "T", fileURL: url) {
                try JSONDecoder().decode([String].self, from: $0)
            }
            guard case .unreadable(let aside?) = outcome else { return XCTFail("\(name): expected quarantine") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try Data(contentsOf: aside), bytes)
        }
    }

    func testNonUTF8AndDirectoryInPlaceOfFileAreQuarantinedByEveryStore() throws {
        try XCTSkipIf(getuid() == 0, "root ignores file modes")
        let nonUTF8 = Data([0xFF, 0xFE, 0x00, 0xC3, 0x28])
        let inputs: [(String, (URL) throws -> Void)] = [
            ("non-utf8", { try nonUTF8.write(to: $0) }),
            ("directory", { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) }),
            ("mode-000", { try Data("[\"x\"]".utf8).write(to: $0)
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: $0.path) }),
        ]
        for (label, make) in inputs {
            let url = directory.appendingPathComponent("\(label).json")
            try make(url)
            let store = AppMuteStore(fileURL: url)
            XCTAssertTrue(store.allMuted().isEmpty, label)
            store.mute("com.example.\(label)")
            XCTAssertEqual(AppMuteStore(fileURL: url).allMuted(), ["com.example.\(label)"], label)
            let aside = url.appendingPathExtension("unreadable")
            XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path), "\(label) not preserved")
        }
    }

    func testPermissionDeniedFileIsQuarantinedNotOverwritten() throws {
        let url = try makeCorrupt("denied.json", bytes: Data("[\"x\"]".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        try XCTSkipIf(getuid() == 0, "root ignores file modes")

        let outcome = PersistedFileLoader.load(store: "T", fileURL: url) {
            try JSONDecoder().decode([String].self, from: $0)
        }
        guard case .unreadable(let aside?) = outcome else { return XCTFail("expected quarantine") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))
    }

    func testExistingQuarantineTargetIsNeverReplaced() throws {
        let url = try makeCorrupt("again.json")
        let earlier = Data("earlier quarantined copy".utf8)
        let taken = url.appendingPathExtension("unreadable")
        try earlier.write(to: taken)

        let outcome = PersistedFileLoader.load(store: "T", fileURL: url) {
            try JSONDecoder().decode([String].self, from: $0)
        }
        guard case .unreadable(let aside?) = outcome else { return XCTFail("expected quarantine") }
        XCTAssertNotEqual(aside, taken)
        XCTAssertEqual(try Data(contentsOf: taken), earlier)
        XCTAssertEqual(try Data(contentsOf: aside), Self.corruptBytes)
    }

    func testFailedQuarantineIsLoggedAndOriginalStaysInPlace() throws {
        let url = try makeCorrupt("stuck.json")
        let lines = captureDiagnostics()
        try XCTSkipIf(getuid() == 0, "root ignores directory modes")
        // A read-only directory refuses the rename, so the move must fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let outcome = PersistedFileLoader.load(store: "StuckStore", fileURL: url) {
            try JSONDecoder().decode([String].self, from: $0)
        }
        guard case .unreadable(let aside) = outcome else { return XCTFail("expected unreadable") }
        XCTAssertNil(aside)
        XCTAssertEqual(try Data(contentsOf: url), Self.corruptBytes)
        let joined = lines().joined(separator: "\n")
        XCTAssertTrue(joined.contains("StuckStore"))
        XCTAssertTrue(joined.contains("quarantine failed"), joined)
        XCTAssertFalse(joined.contains(directory.path), "diagnostic leaked a raw path")
    }

    func testDefaultsQuarantineIsBoundedAndIdempotent() throws {
        let suite = "DevTypeCorruptStore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let validate: (Data) throws -> Void = { _ = try JSONDecoder().decode([String].self, from: $0) }

        defaults.set(Self.corruptBytes, forKey: "k")
        let first = PersistedFileLoader.preserveUndecodableDefaultsValue(
            store: "T", key: "k", defaults: defaults, validate: validate
        )
        let again = PersistedFileLoader.preserveUndecodableDefaultsValue(
            store: "T", key: "k", defaults: defaults, validate: validate
        )
        XCTAssertTrue(try XCTUnwrap(first).hasPrefix("k.unreadable."))
        XCTAssertEqual(again, first, "same bytes must reuse the existing copy")

        for index in 0..<(PersistedFileLoader.maximumQuarantinedCopies + 3) {
            defaults.set(Data("bad \(index)".utf8), forKey: "k")
            PersistedFileLoader.preserveUndecodableDefaultsValue(
                store: "T", key: "k", defaults: defaults, validate: validate
            )
        }
        let copies = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("k.unreadable") }
        XCTAssertEqual(copies.count, PersistedFileLoader.maximumQuarantinedCopies)

        defaults.set(Data("[\"ok\"]".utf8), forKey: "valid")
        XCTAssertNil(PersistedFileLoader.preserveUndecodableDefaultsValue(
            store: "T", key: "valid", defaults: defaults, validate: validate
        ))
    }
}
