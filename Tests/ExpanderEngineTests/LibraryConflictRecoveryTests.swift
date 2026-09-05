import XCTest
@testable import ExpanderEngine

final class LibraryConflictRecoveryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let file: URL
        let alternative: URL
        let recoveryRoot: URL
        let original = Data("original".utf8)
        let selected = Data("selected".utf8)
        let alternate = Data("alternate".utf8)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("library.json")
            alternative = root.appendingPathComponent("version.json")
            recoveryRoot = root.appendingPathComponent("recovery")
            try original.write(to: file)
            try alternate.write(to: alternative)
        }
    }

    func testFailureAtEveryWritePreservesAlternativesUntilVerifiedAdoption() throws {
        for failingWrite in 1...7 {
            let f = try Fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            var writes = 0
            var removed = 0
            var io = LibraryConflictRecovery.IO()
            io.write = { data, url in
                writes += 1
                if writes == failingWrite { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            }
            let outcome = LibraryConflictRecovery.resolve(
                fileURL: f.file, recoveryRoot: f.recoveryRoot, localCandidate: f.selected,
                versions: [.init(url: f.alternative, remove: {
                    removed += 1
                    XCTAssertEqual(try Data(contentsOf: f.file), f.selected)
                    try FileManager.default.removeItem(at: f.alternative)
                })], io: io, validate: { XCTAssertEqual($0, f.selected) }
            )
            switch outcome {
            case .adoptionFailed:
                XCTAssertLessThanOrEqual(failingWrite, 5)
                XCTAssertEqual(removed, 0)
                XCTAssertEqual(try Data(contentsOf: f.file), f.original)
                XCTAssertEqual(try Data(contentsOf: f.alternative), f.alternate)
            case .adopted(let data, let recoveryURL, let pending):
                XCTAssertGreaterThanOrEqual(failingWrite, 6)
                XCTAssertEqual(data, f.selected)
                XCTAssertNotNil(pending)
                XCTAssertEqual(try Data(contentsOf: recoveryURL.appendingPathComponent("current-before.json")), f.original)
                XCTAssertEqual(try Data(contentsOf: recoveryURL.appendingPathComponent("alternative-0.json")), f.alternate)
                XCTAssertEqual(removed, failingWrite == 7 ? 1 : 0)
            }
        }
    }

    func testSilentBackupOrJournalWriteFailureNeverAuthorizesCleanup() throws {
        for missingName in ["selected.json", "current-before.json", "alternative-0.json", "recovery.json"] {
            let f = try Fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            var removed = false
            var io = LibraryConflictRecovery.IO()
            io.write = { data, url in
                if url.lastPathComponent != missingName { try data.write(to: url, options: .atomic) }
            }
            let outcome = LibraryConflictRecovery.resolve(
                fileURL: f.file, recoveryRoot: f.recoveryRoot, localCandidate: f.selected,
                versions: [.init(url: f.alternative, remove: { removed = true })], io: io, validate: { _ in }
            )
            guard case .adoptionFailed = outcome else { return XCTFail("Unverified recovery copy cannot authorize adoption") }
            XCTAssertFalse(removed)
            XCTAssertEqual(try Data(contentsOf: f.file), f.original)
        }
    }

    func testCleanupFailureCanBeRetriedFromDiskAfterRestartWithoutLosingAnyCopy() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = LibraryConflictRecovery.resolve(
            fileURL: f.file, recoveryRoot: f.recoveryRoot, localCandidate: f.selected,
            versions: [.init(url: f.alternative, remove: { throw CocoaError(.fileWriteNoPermission) })], validate: { _ in }
        )
        guard case .adopted(_, let firstRecovery, let pending) = first else { return XCTFail() }
        XCTAssertNotNil(pending)
        let journal = try JSONDecoder().decode(LibraryConflictRecovery.Journal.self,
            from: Data(contentsOf: firstRecovery.appendingPathComponent("recovery.json")))
        XCTAssertEqual(journal.phase, "adopted")
        XCTAssertEqual(journal.versionCount, 1)
        XCTAssertEqual(try Data(contentsOf: f.alternative), f.alternate)

        // New invocation uses only persisted current bytes and the still-unresolved version.
        let second = LibraryConflictRecovery.resolve(
            fileURL: f.file, recoveryRoot: f.recoveryRoot, localCandidate: nil,
            versions: [.init(url: f.alternative, remove: { try FileManager.default.removeItem(at: f.alternative) })],
            validate: { XCTAssertEqual($0, f.selected) }
        )
        guard case .adopted(let data, _, let retryPending) = second else { return XCTFail() }
        XCTAssertEqual(data, f.selected)
        XCTAssertNil(retryPending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.alternative.path))
        XCTAssertEqual(try Data(contentsOf: firstRecovery.appendingPathComponent("current-before.json")), f.original)
        XCTAssertEqual(try Data(contentsOf: firstRecovery.appendingPathComponent("alternative-0.json")), f.alternate)
    }

    func testAdoptionVerificationFailureAndConcurrentWriterPreserveRecovery() throws {
        for changedAtRead in [2, 3] {
            let f = try Fixture()
            defer { try? FileManager.default.removeItem(at: f.root) }
            var targetReads = 0
            var removed = false
            var io = LibraryConflictRecovery.IO()
            io.read = { url in
                if url == f.file {
                    targetReads += 1
                    if targetReads == changedAtRead { try Data("external".utf8).write(to: f.file) }
                }
                return try LibraryConflictRecovery.boundedRead(url)
            }
            let result = LibraryConflictRecovery.resolve(
                fileURL: f.file, recoveryRoot: f.recoveryRoot, localCandidate: f.selected,
                versions: [.init(url: f.alternative, remove: { removed = true })], io: io, validate: { _ in }
            )
            XCTAssertFalse(removed)
            XCTAssertEqual(try Data(contentsOf: f.alternative), f.alternate)
            switch result {
            case .adoptionFailed: XCTAssertEqual(changedAtRead, 2)
            case .adopted(_, _, let pending):
                XCTAssertEqual(changedAtRead, 3)
                XCTAssertNotNil(pending)
            }
        }
    }

    func testNewUncapturedVersionSurvivesSuccessfulCleanup() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let newcomer = f.root.appendingPathComponent("new-version.json")
        let result = LibraryConflictRecovery.resolve(
            fileURL: f.file, recoveryRoot: f.recoveryRoot, localCandidate: f.selected,
            versions: [.init(url: f.alternative, remove: {
                try Data("new alternative".utf8).write(to: newcomer)
                try FileManager.default.removeItem(at: f.alternative)
            })], validate: { _ in }
        )
        guard case .adopted(_, _, nil) = result else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: newcomer), Data("new alternative".utf8))
    }

    func testVersionBudgetRefusesBeforeReadingOrWriting() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var io = LibraryConflictRecovery.IO()
        io.read = { _ in XCTFail(); return Data() }
        io.write = { _, _ in XCTFail() }
        let versions = (0...LibraryConflictRecovery.maximumVersions).map { _ in
            LibraryConflictRecovery.Version(url: f.alternative, remove: { XCTFail() })
        }
        guard case .adoptionFailed = LibraryConflictRecovery.resolve(
            fileURL: f.file, recoveryRoot: f.recoveryRoot, localCandidate: f.selected,
            versions: versions, io: io, validate: { _ in XCTFail() }
        ) else { return XCTFail() }
    }
}
