import Darwin
import XCTest
@testable import ExpanderEngine

/// A thrown activity-history load must move the original bytes aside. The next record may
/// replace the live path only after that move; a failed move must refuse the write.
final class ActivityHistoryQuarantineTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!
    /// `PersistedFileLoader.moveItem` is process-global. Restore it even when a test fails.
    private var savedMove: ((URL, URL) throws -> Void)?

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ActivityHistoryQuarantine-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("activity-history.json")
    }

    override func tearDown() {
        if let savedMove {
            PersistedFileLoader.moveItem = savedMove
            self.savedMove = nil
        }
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testCorruptHistoryIsQuarantinedAndTheNextRecordKeepsTheSibling() throws {
        let corrupt = Data("{\"invalid\": [not valid json".utf8)
        try corrupt.write(to: storeURL)

        let store = ActivityHistoryStore(fileURL: storeURL)
        let aside = storeURL.appendingPathExtension("unreadable")

        XCTAssertEqual(
            try Data(contentsOf: aside),
            corrupt,
            "corrupt history must be moved aside, not left as the live file"
        )
        XCTAssertNotEqual(try? Data(contentsOf: storeURL), corrupt)
        XCTAssertTrue(store.recentEvents().isEmpty)
        XCTAssertFalse(store.persistenceHealth.isHealthy)

        XCTAssertEqual(
            store.record(category: .expansion, title: "Recovered", details: "kept"),
            .persisted
        )
        let reloaded = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.recentEvents().count, 1)
        XCTAssertEqual(reloaded.recentEvents().first?.title, "Recovered")
        XCTAssertEqual(reloaded.recentEvents().first?.details, "kept")
        XCTAssertEqual(try Data(contentsOf: aside), corrupt)
    }

    func testOversizedHistoryIsQuarantinedWithoutReadingTheWholeFileInTheTest() throws {
        let marker = Data("AHQ-OVERSIZE\n".utf8)
        let logicalSize = ActivityHistoryStore.maximumPersistedBytes + 1
        try writeSparseFile(at: storeURL, prefix: marker, logicalSize: logicalSize)

        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertTrue(store.recentEvents().isEmpty)
        XCTAssertEqual(
            store.persistenceHealth.lastFailureKind,
            ActivityHistoryStore.PersistenceFailureKind.fileTooLarge.rawValue
        )

        let aside = storeURL.appendingPathExtension("unreadable")
        XCTAssertEqual(try logicalByteCount(aside), logicalSize)
        XCTAssertEqual(try readPrefix(aside, count: marker.count), marker)
        if FileManager.default.fileExists(atPath: storeURL.path) {
            XCTAssertNotEqual(try logicalByteCount(storeURL), logicalSize)
        }
    }

    func testFailedQuarantineLeavesTheLiveBytesAndRefusesRecordAndClear() throws {
        let corrupt = Data("[{not-json]".utf8)
        try corrupt.write(to: storeURL)
        let original = PersistedFileLoader.moveItem
        savedMove = original
        defer { PersistedFileLoader.moveItem = original }
        PersistedFileLoader.moveItem = { _, _ in throw MoveRefused() }

        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertEqual(try Data(contentsOf: storeURL), corrupt)
        XCTAssertFalse(store.persistenceHealth.isHealthy)
        let kind = store.persistenceHealth.lastFailureKind

        guard case .persistenceFailed = store.record(category: .general, title: "Nope", details: "x") else {
            return XCTFail("record must not overwrite an unpreserved history")
        }
        guard case .persistenceFailed = store.clear() else {
            return XCTFail("clear must not overwrite an unpreserved history")
        }
        XCTAssertEqual(try Data(contentsOf: storeURL), corrupt)
        XCTAssertEqual(store.persistenceHealth.lastFailureKind, kind)
        XCTAssertTrue(store.recentEvents().isEmpty)

        PersistedFileLoader.moveItem = original
        savedMove = nil
        let probeSource = tempDir.appendingPathComponent("probe-src")
        let probeDest = tempDir.appendingPathComponent("probe-dst")
        try Data("restored".utf8).write(to: probeSource)
        XCTAssertNoThrow(try PersistedFileLoader.moveItem(probeSource, probeDest))
        XCTAssertEqual(try Data(contentsOf: probeDest), Data("restored".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeSource.path))
    }

    func testMissingHistoryIsNotQuarantinedAndRecordPersists() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))

        let store = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertTrue(store.persistenceHealth.isHealthy)
        XCTAssertNil(store.persistenceHealth.lastFailureKind)
        XCTAssertEqual(
            store.record(category: .general, title: "First", details: "ok"),
            .persisted
        )

        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertFalse(names.contains { $0.contains("unreadable") })
        let reloaded = ActivityHistoryStore(fileURL: storeURL)
        XCTAssertEqual(reloaded.recentEvents().first?.title, "First")
        XCTAssertTrue(reloaded.persistenceHealth.isHealthy)
    }

    func testSecondCorruptLoadDoesNotReplaceTheFirstSibling() throws {
        let first = Data("{\"wave\":1}".utf8)
        let second = Data("{\"wave\":2}".utf8)
        try first.write(to: storeURL)
        _ = ActivityHistoryStore(fileURL: storeURL)
        let firstAside = storeURL.appendingPathExtension("unreadable")
        XCTAssertEqual(try Data(contentsOf: firstAside), first)

        try second.write(to: storeURL)
        _ = ActivityHistoryStore(fileURL: storeURL)

        XCTAssertEqual(try Data(contentsOf: firstAside), first)
        let copies = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("unreadable") }
        XCTAssertEqual(copies.count, 2)
        let other = try XCTUnwrap(copies.first { $0 != firstAside })
        XCTAssertEqual(try Data(contentsOf: other), second)
        XCTAssertNotEqual(try? Data(contentsOf: storeURL), second)
    }

    private struct MoveRefused: Error {}

    private func writeSparseFile(at url: URL, prefix: Data, logicalSize: Int) throws {
        let fd = open(url.path, O_CREAT | O_RDWR | O_TRUNC, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let written = prefix.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.write(fd, base, prefix.count)
        }
        XCTAssertEqual(written, prefix.count)
        XCTAssertEqual(ftruncate(fd, off_t(logicalSize)), 0)
    }

    private func logicalByteCount(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return try XCTUnwrap(values.fileSize)
    }

    private func readPrefix(_ url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }
}
