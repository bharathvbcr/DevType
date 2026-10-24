import Darwin
import XCTest
@testable import ExpanderEngine

/// Coordinated library reads must stop at `LibraryConflictRecovery.maximumCandidateBytes`.
/// A file over that ceiling is a hard failure: no decode, no `.corrupted` safety copy, and the
/// previous in-memory library stays. Safety copies under the ceiling are unchanged.
final class SnippetStoreReadBoundTests: XCTestCase {

    private struct Scratch {
        let root: URL
        let library: URL
        let support: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("DevTypeReadBound-\(UUID().uuidString)", isDirectory: true)
            library = root.appendingPathComponent("snippets.json")
            support = root.appendingPathComponent("Support", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        func backups() -> [URL] {
            let directory = support.appendingPathComponent("Backups", isDirectory: true)
            return (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
        }

        func makeStore() -> SnippetStore {
            SnippetStore(
                location: SnippetStore.Location(fileURL: library, expectsExistingLibrary: false),
                localSupportDirectory: support,
                watcherFactory: { _ in nil },
                secretStore: SecretStore(backing: InMemorySecretBackingStore()),
                secretPurgeEnabled: false
            )
        }
    }

    private func minorFaultBytes() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return UInt64(usage.ru_minflt) * UInt64(vm_page_size)
    }

    /// A sparse file larger than the production ceiling must not be read into a second buffer
    /// or written out as an uncapped `.corrupted` sibling. The groups already in memory stay.
    func testOversizedSparseFileDoesNotReadOrBackUpAndKeepsGroups() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let ceiling = LibraryConflictRecovery.maximumCandidateBytes
        let store = scratch.makeStore()
        let kept = SnippetGroup(name: "Kept", snippets: [
            SnippetModel(title: "Kept", triggerKeyword: ":kept", replacementText: "still here")
        ])
        XCTAssertTrue(store.saveGroups([kept]).didSave)
        XCTAssertEqual(store.loadGroups().map(\.name), ["Kept"])

        let prefix: Data
        do {
            let handle = try FileHandle(forReadingFrom: scratch.library)
            prefix = try handle.read(upToCount: 64) ?? Data()
            try handle.close()
        }
        let beforeNames = Set(scratch.backups().map(\.lastPathComponent))
        let fd = open(scratch.library.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0, "open \(scratch.library.path) errno \(errno)")
        XCTAssertEqual(ftruncate(fd, off_t(ceiling) + 1), 0, "ftruncate errno \(errno)")
        close(fd)
        let logical = try scratch.library.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(logical, ceiling + 1)

        let faultsBefore = minorFaultBytes()
        store.reloadFromDisk()
        let faulted = minorFaultBytes() &- faultsBefore

        XCTAssertEqual(store.loadGroups().map(\.name), ["Kept"])
        XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword), [":kept"])
        XCTAssertTrue(store.isLibraryReadFailed)
        XCTAssertTrue(
            store.libraryReadFailureReason?.contains("\(ceiling)") == true,
            "refusal must name the ceiling, got \(String(describing: store.libraryReadFailureReason))"
        )
        guard case .unreadable(_, let reason)? = store.lastLoadIssue else {
            return XCTFail("oversized file is unreadable, not \(String(describing: store.lastLoadIssue))")
        }
        XCTAssertTrue(reason.contains("\(ceiling)"), "load issue omitted the ceiling: \(reason)")

        let created = scratch.backups().filter { !beforeNames.contains($0.lastPathComponent) }
        XCTAssertTrue(created.isEmpty, "refused read wrote \(created.map(\.lastPathComponent))")
        for url in scratch.backups() {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            XCTAssertLessThanOrEqual(size, ceiling, "backup \(url.lastPathComponent) exceeds the ceiling")
            XCTAssertFalse(url.lastPathComponent.contains("corrupted"))
        }
        XCTAssertLessThan(
            faulted, UInt64(ceiling) / 2,
            "read faulted \(faulted) bytes of a \(ceiling + 1)-byte sparse library"
        )
        XCTAssertEqual(try scratch.library.resourceValues(forKeys: [.fileSizeKey]).fileSize, ceiling + 1)
        let headHandle = try FileHandle(forReadingFrom: scratch.library)
        let head = try headHandle.read(upToCount: prefix.count)
        try headHandle.close()
        XCTAssertEqual(head, prefix, "live snippets.json was replaced")
    }

    func testNonJSONUnderCeilingWritesExactlyOneCorruptedCopy() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let payload = Data("not-json".utf8)
        try payload.write(to: scratch.library)
        let loaded = SnippetStore.loadFrom(
            SnippetStore.Location(fileURL: scratch.library, expectsExistingLibrary: true),
            backups: LibraryBackupStore(directory: scratch.support.appendingPathComponent("Backups"))
        )
        XCTAssertNotNil(loaded.hardFailure)
        XCTAssertFalse(loaded.decodeSucceeded)
        guard case .corrupted(let backup)? = loaded.loadIssue else {
            return XCTFail("expected one corrupted safety copy, got \(String(describing: loaded.loadIssue))")
        }
        let copies = scratch.backups().filter { $0.lastPathComponent.contains("corrupted") }
        XCTAssertEqual(copies.map(\.lastPathComponent), [backup.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: backup), payload)
        XCTAssertEqual(try Data(contentsOf: scratch.library), payload)
    }

    func testValidFileUnderCeilingDecodes() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let store = scratch.makeStore()
        XCTAssertTrue(store.saveGroups([
            SnippetGroup(name: "General", snippets: [
                SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1")
            ])
        ]).didSave)
        let again = SnippetStore.loadFrom(
            SnippetStore.Location(fileURL: scratch.library, expectsExistingLibrary: true),
            backups: LibraryBackupStore(directory: scratch.support.appendingPathComponent("Backups"))
        )
        XCTAssertTrue(again.decodeSucceeded)
        XCTAssertNil(again.hardFailure)
        XCTAssertEqual(again.groups.flatMap(\.snippets).map(\.triggerKeyword), [":a"])
        XCTAssertTrue(scratch.backups().filter { $0.lastPathComponent.contains("corrupted") }.isEmpty)
    }

    func testSmallBlankFileIsNotAnOversizedRead() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        try Data().write(to: scratch.library)
        let loaded = SnippetStore.loadFrom(
            SnippetStore.Location(fileURL: scratch.library, expectsExistingLibrary: true),
            backups: LibraryBackupStore(directory: scratch.support.appendingPathComponent("Backups"))
        )
        XCTAssertTrue(loaded.decodeSucceeded)
        XCTAssertNil(loaded.hardFailure)
        XCTAssertEqual(loaded.loadIssue, .emptyFile(path: scratch.library.path))
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertTrue(scratch.backups().isEmpty)
    }

    /// Exact `maximumCandidateBytes` is not materialized: that would allocate 64 MiB.
    /// Equality is the injected ceiling (real file size) and a stated size equal to the
    /// production constant. One byte past either ceiling is a thrown refusal, not a backup.
    func testCeilingEqualityLoadsAndOnePastThrowsWithoutBackup() throws {
        let base = try paddedLibrary(extraSpaces: 0)
        let step = try paddedLibrary(extraSpaces: 1)
        XCTAssertEqual(step.count, base.count + 1, "a space in replacement text must add one byte")
        let ceiling = base.count + 4
        let under = try paddedLibrary(extraSpaces: 3)
        let exact = try paddedLibrary(extraSpaces: 4)
        let over = try paddedLibrary(extraSpaces: 5)
        XCTAssertEqual(under.count, ceiling - 1)
        XCTAssertEqual(exact.count, ceiling)
        XCTAssertEqual(over.count, ceiling + 1)

        let underLoaded = try load(under, maximumBytes: ceiling)
        XCTAssertTrue(underLoaded.decodeSucceeded)
        XCTAssertNil(underLoaded.hardFailure)
        XCTAssertEqual(underLoaded.groups.flatMap(\.snippets).map(\.triggerKeyword), [":bound"])

        let exactLoaded = try load(exact, maximumBytes: ceiling)
        XCTAssertTrue(exactLoaded.decodeSucceeded)
        XCTAssertNil(exactLoaded.hardFailure)
        XCTAssertEqual(exactLoaded.groups.flatMap(\.snippets).map(\.triggerKeyword), [":bound"])
        XCTAssertEqual(try SnippetStore.coordinatedRead(at: try write(exact), maximumBytes: ceiling).count, ceiling)

        let overScratch = try Scratch()
        defer { overScratch.cleanup() }
        try over.write(to: overScratch.library)
        let overLoaded = SnippetStore.loadFrom(
            SnippetStore.Location(fileURL: overScratch.library, expectsExistingLibrary: true),
            backups: LibraryBackupStore(directory: overScratch.support.appendingPathComponent("Backups")),
            maximumBytes: ceiling
        )
        XCTAssertFalse(overLoaded.decodeSucceeded)
        XCTAssertNotNil(overLoaded.hardFailure)
        guard case .failed(let reason)? = overLoaded.hardFailure else {
            return XCTFail("expected a failed read, got \(String(describing: overLoaded.hardFailure))")
        }
        XCTAssertTrue(reason.contains("\(ceiling)"), "refusal omitted the ceiling: \(reason)")
        guard case .unreadable(_, let issue)? = overLoaded.loadIssue else {
            return XCTFail("one past the ceiling is unreadable, not \(String(describing: overLoaded.loadIssue))")
        }
        XCTAssertTrue(issue.contains("\(ceiling)"))
        XCTAssertTrue(overScratch.backups().isEmpty, "over-ceiling read must not write a safety copy")
        XCTAssertEqual(try Data(contentsOf: overScratch.library), over)

        XCTAssertThrowsError(
            try SnippetStore.coordinatedRead(at: overScratch.library, maximumBytes: ceiling)
        ) { error in
            let refused = error as? SnippetStore.OversizedLibraryRead
            XCTAssertEqual(refused?.ceiling, ceiling)
            XCTAssertEqual(refused?.byteCount, ceiling + 1)
            XCTAssertTrue(error.localizedDescription.contains("\(ceiling)"))
        }
    }

    /// The filesystem size is allowed to equal the production ceiling. The bytes here are
    /// small; the stated size is `maximumCandidateBytes` so the comparison is the real constant.
    func testStatedProductionCeilingStillLoads() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let payload = try paddedLibrary(extraSpaces: 0)
        try payload.write(to: scratch.library)
        let ceiling = LibraryConflictRecovery.maximumCandidateBytes
        let loaded = SnippetStore.loadFrom(
            SnippetStore.Location(fileURL: scratch.library, expectsExistingLibrary: true),
            backups: LibraryBackupStore(directory: scratch.support.appendingPathComponent("Backups")),
            statedByteCount: { _ in ceiling }
        )
        XCTAssertTrue(loaded.decodeSucceeded)
        XCTAssertNil(loaded.hardFailure)
        XCTAssertEqual(loaded.groups.flatMap(\.snippets).map(\.triggerKeyword), [":bound"])

        let read = try SnippetStore.coordinatedRead(
            at: scratch.library,
            statedByteCount: { _ in ceiling }
        )
        XCTAssertEqual(read, payload)
    }

    /// A stat that still says the file is within the ceiling must not keep a tail that
    /// arrives during the read, and must not quarantine that tail.
    func testUnderReportedSizeStillStopsAtTheCeiling() throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let ceiling = 64
        let payload = Data(repeating: UInt8(ascii: "x"), count: 8_000)
        try payload.write(to: scratch.library)
        XCTAssertThrowsError(try SnippetStore.coordinatedRead(
            at: scratch.library,
            maximumBytes: ceiling,
            statedByteCount: { _ in ceiling }
        )) { error in
            let refused = error as? SnippetStore.OversizedLibraryRead
            XCTAssertEqual(refused?.ceiling, ceiling)
            XCTAssertEqual(refused?.byteCount, ceiling + 1)
        }
        let loaded = SnippetStore.loadFrom(
            SnippetStore.Location(fileURL: scratch.library, expectsExistingLibrary: true),
            backups: LibraryBackupStore(directory: scratch.support.appendingPathComponent("Backups")),
            maximumBytes: ceiling,
            statedByteCount: { _ in ceiling }
        )
        XCTAssertFalse(loaded.decodeSucceeded)
        XCTAssertNotNil(loaded.hardFailure)
        guard case .unreadable? = loaded.loadIssue else {
            return XCTFail("grew-past-ceiling read is unreadable, not \(String(describing: loaded.loadIssue))")
        }
        XCTAssertTrue(scratch.backups().isEmpty)
        XCTAssertEqual(try Data(contentsOf: scratch.library), payload)
    }

    private func paddedLibrary(extraSpaces: Int) throws -> Data {
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let snippet = SnippetModel(
            title: "Bound",
            triggerKeyword: ":bound",
            replacementText: "v" + String(repeating: " ", count: extraSpaces),
            createdAt: fixed,
            updatedAt: fixed
        )
        let document = SnippetDocument(groups: [
            SnippetGroup(name: "General", snippets: [snippet])
        ])
        return try JSONEncoder().encode(document)
    }

    private func write(_ data: Data) throws -> URL {
        let scratch = try Scratch()
        try data.write(to: scratch.library)
        addTeardownBlock { scratch.cleanup() }
        return scratch.library
    }

    private func load(_ data: Data, maximumBytes: Int) throws -> SnippetStore.Loaded {
        let url = try write(data)
        return SnippetStore.loadFrom(
            SnippetStore.Location(fileURL: url, expectsExistingLibrary: true),
            backups: LibraryBackupStore(directory: url.deletingLastPathComponent().appendingPathComponent("Support/Backups")),
            maximumBytes: maximumBytes
        )
    }
}
