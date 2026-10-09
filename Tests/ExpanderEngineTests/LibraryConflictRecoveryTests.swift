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

/// Retention for the recovery folders `resolve` leaves behind: the newest 10 and anything younger
/// than 30 days, never a folder an adoption with pending cleanup still refers to, and never a
/// folder whose age or journal cannot be read.
final class LibraryConflictRecoveryPruneTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_791_547_200)
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-recovery-prune-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in walker {
                try? FilePermissions.setPOSIX(root.appendingPathComponent(relative), 0o700)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func folder(_ name: String, age: TimeInterval, phase: String? = "complete") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let phase {
            let journal = LibraryConflictRecovery.Journal(
                libraryPath: "/library.json", versionCount: 1, selectedLocal: true, phase: phase
            )
            try JSONEncoder().encode(journal).write(to: url.appendingPathComponent("recovery.json"))
        }
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func remaining() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    }

    func testRetentionTable() throws {
        struct Row {
            let name: String
            let agesInDays: [Double]
            let kept: Set<Int>
        }
        let rows = [
            Row(name: "none", agesInDays: [], kept: []),
            Row(name: "ten old folders all stay", agesInDays: (0..<10).map { 100 + Double($0) }, kept: Set(0..<10)),
            Row(name: "eleven old: the oldest goes", agesInDays: (0..<11).map { 100 + Double($0) }, kept: Set(0..<10)),
            Row(name: "anything younger than 30 days stays past ten",
                agesInDays: (0..<15).map { Double($0) }, kept: Set(0..<15)),
            Row(name: "young plus old: young stay, old beyond the newest ten go",
                agesInDays: (0..<12).map { Double($0) } + [40, 50], kept: Set(0..<12)),
            Row(name: "exactly 30 days is not younger",
                agesInDays: (0..<10).map { Double($0) } + [30], kept: Set(0..<10)),
        ]
        for row in rows {
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (index, age) in row.agesInDays.enumerated() {
                try folder("\(index)", age: age * day)
            }
            let report = LibraryConflictRecovery.prune(recoveryRoot: root, now: now)
            XCTAssertEqual(try remaining(), Set(row.kept.map(String.init)), row.name)
            XCTAssertEqual(report.retained, row.kept.count, row.name)
            XCTAssertEqual(report.removed, row.agesInDays.count - row.kept.count, row.name)
        }
    }

    func testFoldersReferencedByAPendingCleanupSurvive() throws {
        for index in 0..<12 { try folder("old-\(index)", age: Double(100 + index) * day) }
        try folder("pending", age: 500 * day, phase: "adopted")

        let report = LibraryConflictRecovery.prune(recoveryRoot: root, now: now)

        XCTAssertTrue(try remaining().contains("pending"), "a folder an adoption still refers to was removed")
        XCTAssertEqual(report.referenced, 1)
        XCTAssertEqual(report.removed, 2)
        XCTAssertEqual(report.retained, 11)
    }

    func testAnUnreadableFolderIsSkippedWithoutAbortingThePass() throws {
        for index in 0..<12 { try folder("old-\(index)", age: Double(100 + index) * day) }
        let locked = try folder("locked", age: 900 * day)
        try FilePermissions.setPOSIX(locked, 0)
        try folder("no-journal", age: 900 * day, phase: nil)
        let garbled = try folder("garbled", age: 900 * day, phase: nil)
        try Data("{not json".utf8).write(to: garbled.appendingPathComponent("recovery.json"))
        if FileManager.default.isReadableFile(atPath: locked.appendingPathComponent("recovery.json").path) {
            throw XCTSkip("this process can read inside a mode-000 directory")
        }

        let report = LibraryConflictRecovery.prune(recoveryRoot: root, now: now)

        let left = try remaining()
        XCTAssertTrue(left.isSuperset(of: ["locked", "no-journal", "garbled"]), "an unreadable folder was removed")
        XCTAssertEqual(report.skipped, 3)
        XCTAssertEqual(report.removed, 2, "the pass must carry on past unreadable folders")
        XCTAssertFalse(left.contains("old-10"))
        XCTAssertFalse(left.contains("old-11"))
        XCTAssertEqual(report.retained, 13)
        XCTAssertTrue(report.enumerationComplete)
    }

    func testAMissingRootIsAnEmptyCompletePass() {
        let report = LibraryConflictRecovery.prune(recoveryRoot: root.appendingPathComponent("absent"), now: now)
        XCTAssertEqual(report, LibraryConflictRecovery.PruneReport())
    }

    /// The store owns the trigger and reports the count diagnostics print.
    func testStorePruneRecordsTheRetainedCountForDiagnostics() throws {
        let support = root.appendingPathComponent("support", isDirectory: true)
        let recovery = support.appendingPathComponent("ConflictRecovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let store = SnippetStore(
            location: .init(fileURL: support.appendingPathComponent("snippets.json"), expectsExistingLibrary: false),
            localSupportDirectory: support
        )
        XCTAssertNil(store.conflictRecoveryRetainedFolderCount, "no pass has run; zero would be a guess")
        for index in 0..<3 {
            let url = recovery.appendingPathComponent("f\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let journal = LibraryConflictRecovery.Journal(libraryPath: "/x", versionCount: 0, selectedLocal: false, phase: "complete")
            try JSONEncoder().encode(journal).write(to: url.appendingPathComponent("recovery.json"))
        }

        let done = expectation(description: "prune")
        store.scheduleConflictRecoveryPrune { _ in done.fulfill() }
        wait(for: [done], timeout: 5)

        XCTAssertEqual(store.conflictRecoveryRetainedFolderCount, 3)
        let line = DiagnosticReport.libraryRecoveryDiagnosticLine(
            retainedConflictFolders: store.conflictRecoveryRetainedFolderCount,
            backupCount: store.libraryBackupCount
        )
        XCTAssertTrue(line.contains("Conflict recovery folders retained: 3"), line)
    }
}
