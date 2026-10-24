import Darwin
import XCTest
@testable import ExpanderEngine

/// Hostile cases for the library read ceiling. Exact ceiling-1 / ceiling / ceiling+1
/// JSON is already covered by `SnippetStoreReadBoundTests` and is not repeated.
/// A true concurrent append inside `readBounded` is not isolated: nothing in the
/// read loop yields, so growth is modeled by a file that is already past the ceiling
/// while `statedByteCount` reports a smaller size.
final class SnippetStoreReadBoundHostileTests: XCTestCase {

    private struct Fixture {
        let root: URL
        let library: URL
        let support: URL

        init(directoryName: String = "plain-\(UUID().uuidString)") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
            library = root.appendingPathComponent("snippets.json")
            support = root.appendingPathComponent("Support", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
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

        func backupDirectory() -> URL {
            support.appendingPathComponent("Backups", isDirectory: true)
        }

        func load(
            maximumBytes: Int = LibraryConflictRecovery.maximumCandidateBytes,
            statedByteCount: ((URL) -> Int?)? = nil
        ) -> SnippetStore.Loaded {
            SnippetStore.loadFrom(
                SnippetStore.Location(fileURL: library, expectsExistingLibrary: true),
                backups: LibraryBackupStore(directory: backupDirectory()),
                maximumBytes: maximumBytes,
                statedByteCount: statedByteCount
            )
        }
    }

    private func minorFaultBytes() -> UInt64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return UInt64(max(0, usage.ru_minflt)) * UInt64(vm_page_size)
    }

    private func extend(_ url: URL, to bytes: Int, file: StaticString = #filePath, line: UInt = #line) {
        let fd = open(url.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0, "open \(url.path) errno \(errno)", file: file, line: line)
        XCTAssertEqual(ftruncate(fd, off_t(bytes)), 0, "ftruncate errno \(errno)", file: file, line: line)
        close(fd)
    }

    /// Replace the library with `prefix` and a sparse hole out to `bytes`.
    private func plantSparse(at url: URL, prefix: Data, bytes: Int) throws {
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0, "open \(url.path) errno \(errno)")
        if !prefix.isEmpty {
            let wrote = prefix.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base, raw.count)
            }
            XCTAssertEqual(wrote, prefix.count, "short write errno \(errno)")
        }
        XCTAssertEqual(ftruncate(fd, off_t(bytes)), 0, "ftruncate errno \(errno)")
        close(fd)
    }

    private func assertNoSafetyCopy(under root: URL, library: URL, largerThan limit: Int) throws {
        let libraryPath = library.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else {
            return XCTFail("could not list \(root.path)")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if url.resolvingSymlinksInPath().path == libraryPath { continue }
            XCTAssertFalse(
                url.lastPathComponent.contains("corrupted"),
                "safety sibling \(url.path)"
            )
            let size = values.fileSize ?? 0
            XCTAssertLessThanOrEqual(size, limit, "copy \(url.path) is \(size) bytes")
        }
    }

    private func keptGroup() -> SnippetGroup {
        SnippetGroup(name: "Kept", snippets: [
            SnippetModel(title: "Kept", triggerKeyword: ":kept", replacementText: "still here")
        ])
    }

    /// Default production ceiling. The sparse file is one byte over it. Refusal must
    /// not leave a `.corrupted` sibling anywhere under the library root, must not mark
    /// the load as a successful decode, and must survive a second reload.
    func testDefaultCeilingSparseFileRefusesWithoutSiblingAndSecondReloadKeepsGroups() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let ceiling = LibraryConflictRecovery.maximumCandidateBytes
        let logical = ceiling + 1
        let store = fixture.makeStore()
        XCTAssertTrue(store.saveGroups([keptGroup()]).didSave)
        extend(fixture.library, to: logical)
        XCTAssertEqual(try fixture.library.resourceValues(forKeys: [.fileSizeKey]).fileSize, logical)

        let loaded = fixture.load()
        XCTAssertFalse(loaded.decodeSucceeded)
        XCTAssertNotNil(loaded.hardFailure)
        guard case .failed(let reason)? = loaded.hardFailure else {
            return XCTFail("expected hard failure, got \(String(describing: loaded.hardFailure))")
        }
        XCTAssertTrue(reason.contains("\(ceiling)"), "refusal omitted the ceiling: \(reason)")
        guard case .unreadable = loaded.loadIssue else {
            return XCTFail("over-ceiling file is unreadable, not \(String(describing: loaded.loadIssue))")
        }
        XCTAssertNotEqual(loaded.loadIssue, .emptyFile(path: fixture.library.path))
        XCTAssertTrue(loaded.groups.isEmpty, "refused read must not produce groups to adopt")

        store.reloadFromDisk()
        XCTAssertEqual(store.loadGroups().map(\.name), ["Kept"])
        XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword), [":kept"])
        XCTAssertTrue(store.isLibraryReadFailed)
        store.reloadFromDisk()
        XCTAssertEqual(store.loadGroups().map(\.name), ["Kept"])
        XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword), [":kept"])
        XCTAssertTrue(store.isLibraryReadFailed)
        XCTAssertTrue(store.libraryReadFailureReason?.contains("\(ceiling)") == true)
        XCTAssertEqual(try fixture.library.resourceValues(forKeys: [.fileSizeKey]).fileSize, logical)
        try assertNoSafetyCopy(under: fixture.root, library: fixture.library, largerThan: 1_000_000)
    }

    /// `statedByteCount` lies downward: 0, nil, and a value at or under the ceiling,
    /// while the sparse file is past the production ceiling. The injected ceiling is
    /// a few KiB so the capped read cannot allocate 64 MiB. `reloadFromDisk` has no
    /// stated-size parameter; the lie goes through `loadFrom`, and the live store
    /// must keep its groups across that call and a real reload.
    func testDownwardStatedSizeOnHugeSparseFileDoesNotAdoptOrBackUp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let production = LibraryConflictRecovery.maximumCandidateBytes
        let ceiling = 4 * 1024
        let logical = production + 1
        let store = fixture.makeStore()
        XCTAssertTrue(store.saveGroups([keptGroup()]).didSave)
        extend(fixture.library, to: logical)

        let lies: [(String, (URL) -> Int?)] = [
            ("zero", { _ in 0 }),
            ("nil", { _ in nil }),
            ("under", { _ in ceiling / 2 }),
            ("equal", { _ in ceiling })
        ]
        for (name, stated) in lies {
            let faultsBefore = minorFaultBytes()
            var refused: SnippetStore.OversizedLibraryRead?
            XCTAssertThrowsError(
                try SnippetStore.coordinatedRead(
                    at: fixture.library,
                    maximumBytes: ceiling,
                    statedByteCount: stated
                ),
                "stated \(name) returned bytes"
            ) { error in
                refused = error as? SnippetStore.OversizedLibraryRead
            }
            let faulted = minorFaultBytes() &- faultsBefore
            XCTAssertEqual(refused?.ceiling, ceiling, name)
            XCTAssertEqual(refused?.byteCount, ceiling + 1, "stated \(name) observed \(String(describing: refused?.byteCount))")
            XCTAssertLessThan(faulted, UInt64(production) / 2, "stated \(name) faulted \(faulted) bytes")

            let loaded = fixture.load(maximumBytes: ceiling, statedByteCount: stated)
            XCTAssertFalse(loaded.decodeSucceeded, name)
            XCTAssertNotNil(loaded.hardFailure, name)
            XCTAssertTrue(loaded.groups.isEmpty, name)
            guard case .unreadable(_, let reason)? = loaded.loadIssue else {
                return XCTFail("stated \(name) is unreadable, not \(String(describing: loaded.loadIssue))")
            }
            XCTAssertTrue(reason.contains("\(ceiling)"), "stated \(name) omitted the ceiling: \(reason)")
            XCTAssertNotEqual(loaded.loadIssue, .emptyFile(path: fixture.library.path), name)
            XCTAssertEqual(store.loadGroups().map(\.name), ["Kept"], "stated \(name) replaced the store")
        }

        store.reloadFromDisk()
        XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword), [":kept"])
        XCTAssertTrue(store.isLibraryReadFailed)
        XCTAssertEqual(try fixture.library.resourceValues(forKeys: [.fileSizeKey]).fileSize, logical)
        try assertNoSafetyCopy(under: fixture.root, library: fixture.library, largerThan: 1_000_000)
    }

    /// The stated size, not the one-byte body, is what is over the ceiling. A `{`
    /// body must not be decoded or quarantined just because the lie is large.
    func testStatedSizeAboveCeilingThrowsBeforeAcceptingOneByteBody() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let body = Data("{".utf8)
        try body.write(to: fixture.library)
        let ceiling = 100
        let stated = LibraryConflictRecovery.maximumCandidateBytes + 1
        XCTAssertThrowsError(try SnippetStore.coordinatedRead(
            at: fixture.library,
            maximumBytes: ceiling,
            statedByteCount: { _ in stated }
        )) { error in
            let refused = error as? SnippetStore.OversizedLibraryRead
            XCTAssertEqual(refused?.ceiling, ceiling)
            XCTAssertEqual(refused?.byteCount, stated)
            XCTAssertNotEqual(refused?.byteCount, body.count)
        }
        XCTAssertThrowsError(try SnippetStore.coordinatedRead(
            at: fixture.library,
            maximumBytes: ceiling,
            statedByteCount: { _ in Int.max }
        )) { error in
            let refused = error as? SnippetStore.OversizedLibraryRead
            XCTAssertEqual(refused?.byteCount, Int.max)
            XCTAssertEqual(refused?.ceiling, ceiling)
        }

        let loaded = fixture.load(maximumBytes: ceiling, statedByteCount: { _ in stated })
        XCTAssertFalse(loaded.decodeSucceeded)
        XCTAssertTrue(loaded.groups.isEmpty)
        guard case .failed(let reason)? = loaded.hardFailure else {
            return XCTFail("expected hard failure, got \(String(describing: loaded.hardFailure))")
        }
        XCTAssertTrue(reason.contains("\(ceiling)"))
        guard case .unreadable = loaded.loadIssue else {
            return XCTFail("stated over-ceiling read is unreadable, not \(String(describing: loaded.loadIssue))")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.library), body)
        try assertNoSafetyCopy(under: fixture.root, library: fixture.library, largerThan: 0)
    }

    /// Stat says the file is under the ceiling. The bytes past the ceiling are already
    /// in the file before `readBounded` runs. No second thread appends during the read.
    func testPreGrownFileWithLowStatedSizeDoesNotReturnOrBackUp() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let ceiling = 2 * 1024
        let stated = ceiling / 2
        let logical = LibraryConflictRecovery.maximumCandidateBytes + 1
        try plantSparse(at: fixture.library, prefix: Data("not-json".utf8), bytes: logical)
        let faultsBefore = minorFaultBytes()
        XCTAssertThrowsError(try SnippetStore.coordinatedRead(
            at: fixture.library,
            maximumBytes: ceiling,
            statedByteCount: { url in
                // Grow again inside the size callback. This still happens before the
                // read loop; it is not a concurrent append.
                self.extend(url, to: logical)
                return stated
            }
        )) { error in
            let refused = error as? SnippetStore.OversizedLibraryRead
            XCTAssertEqual(refused?.ceiling, ceiling)
            XCTAssertGreaterThan(refused?.byteCount ?? 0, stated)
            XCTAssertLessThanOrEqual(refused?.byteCount ?? Int.max, ceiling + 1)
        }
        let faulted = minorFaultBytes() &- faultsBefore
        XCTAssertLessThan(faulted, UInt64(logical) / 2, "pre-grown read faulted \(faulted) bytes")

        let loaded = fixture.load(maximumBytes: ceiling, statedByteCount: { _ in stated })
        XCTAssertFalse(loaded.decodeSucceeded)
        XCTAssertNotNil(loaded.hardFailure)
        XCTAssertTrue(loaded.groups.isEmpty)
        guard case .unreadable = loaded.loadIssue else {
            return XCTFail("pre-grown file is unreadable, not \(String(describing: loaded.loadIssue))")
        }
        XCTAssertEqual(try fixture.library.resourceValues(forKeys: [.fileSizeKey]).fileSize, logical)
        try assertNoSafetyCopy(under: fixture.root, library: fixture.library, largerThan: 1_000_000)
    }

    /// `{`, `[`, and leading whitespace are the shapes the blank/JSON paths look at.
    /// Over the production ceiling they are still a hard failure, and the previous
    /// groups and the live bytes stay.
    func testOverCeilingJSONOrWhitespacePrefixIsNotBlankAndDoesNotPurge() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let ceiling = LibraryConflictRecovery.maximumCandidateBytes
        let logical = ceiling + 1
        let store = fixture.makeStore()
        XCTAssertTrue(store.saveGroups([keptGroup()]).didSave)

        let prefixes = [Data("{".utf8), Data("[".utf8), Data(" \t\n".utf8)]
        for prefix in prefixes {
            try plantSparse(at: fixture.library, prefix: prefix, bytes: logical)
            let loaded = fixture.load()
            XCTAssertFalse(loaded.decodeSucceeded, "prefix \(prefix as NSData)")
            XCTAssertNotNil(loaded.hardFailure, "prefix \(prefix as NSData)")
            XCTAssertTrue(loaded.groups.isEmpty, "prefix \(prefix as NSData)")
            guard case .unreadable = loaded.loadIssue else {
                return XCTFail("prefix \(prefix as NSData) is unreadable, not \(String(describing: loaded.loadIssue))")
            }
            XCTAssertNotEqual(loaded.loadIssue, .emptyFile(path: fixture.library.path))

            store.reloadFromDisk()
            XCTAssertEqual(store.loadGroups().map(\.name), ["Kept"], "prefix \(prefix as NSData)")
            XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword), [":kept"])
            XCTAssertTrue(store.isLibraryReadFailed)
            XCTAssertEqual(try fixture.library.resourceValues(forKeys: [.fileSizeKey]).fileSize, logical)
            let head = try FileHandle(forReadingFrom: fixture.library)
            let leading = try head.read(upToCount: prefix.count)
            try head.close()
            XCTAssertEqual(leading, prefix, "live file was purged for prefix \(prefix as NSData)")
            try assertNoSafetyCopy(under: fixture.root, library: fixture.library, largerThan: 1_000_000)
        }
    }

    /// Directory name carries a space, a non-ASCII letter, and a combining mark.
    func testOddPathRefusesOverCeilingSparseFile() throws {
        let odd = "odd cafe\u{0301} \u{00E9}"
        XCTAssertTrue(odd.contains(" "))
        XCTAssertTrue(odd.unicodeScalars.contains { $0.value == 0x0301 })
        XCTAssertTrue(odd.unicodeScalars.contains { $0.value > 127 && $0.value != 0x0301 })
        let fixture = try Fixture(directoryName: odd)
        defer { fixture.cleanup() }
        let ceiling = LibraryConflictRecovery.maximumCandidateBytes
        let logical = ceiling + 1
        let store = fixture.makeStore()
        XCTAssertTrue(store.saveGroups([keptGroup()]).didSave)
        extend(fixture.library, to: logical)

        let loaded = fixture.load()
        XCTAssertFalse(loaded.decodeSucceeded)
        guard case .failed(let reason)? = loaded.hardFailure else {
            return XCTFail("odd path did not hard-fail: \(String(describing: loaded.hardFailure))")
        }
        XCTAssertTrue(reason.contains("\(ceiling)"), reason)
        guard case .unreadable = loaded.loadIssue else {
            return XCTFail("odd path load issue \(String(describing: loaded.loadIssue))")
        }

        store.reloadFromDisk()
        store.reloadFromDisk()
        XCTAssertEqual(store.loadGroups().map(\.name), ["Kept"])
        XCTAssertTrue(store.isLibraryReadFailed)
        XCTAssertEqual(try fixture.library.resourceValues(forKeys: [.fileSizeKey]).fileSize, logical)
        try assertNoSafetyCopy(under: fixture.root, library: fixture.library, largerThan: 1_000_000)
    }

    /// Mode 000 must not decode as a blank library. Skips when the sandbox will not
    /// clear the read bits or when this process can still read the file.
    func testUnreadableModeIsHardFailureNotBlankDecode() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let payload = Data("secret-looking".utf8)
        try payload.write(to: fixture.library)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.library.path)
        } catch {
            throw XCTSkip("chmod denied: \(error)")
        }
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.library.path)
        }
        if FileManager.default.isReadableFile(atPath: fixture.library.path) {
            throw XCTSkip("mode 000 is still readable")
        }

        XCTAssertThrowsError(try SnippetStore.coordinatedRead(at: fixture.library))
        let loaded = fixture.load()
        XCTAssertFalse(loaded.decodeSucceeded)
        XCTAssertNotNil(loaded.hardFailure)
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertNotEqual(loaded.loadIssue, .emptyFile(path: fixture.library.path))
        if case .emptyFile = loaded.loadIssue {
            XCTFail("unreadable file looked blank")
        }
        try assertNoSafetyCopy(under: fixture.root, library: fixture.library, largerThan: 0)
    }

    /// A zero ceiling refuses any byte, including whitespace that would otherwise be
    /// a blank library. A truly empty file still follows the blank path.
    func testZeroCeilingRefusesNonEmptyAndStillBlanksEmpty() throws {
        let nonEmpty = try Fixture()
        defer { nonEmpty.cleanup() }
        try Data(" ".utf8).write(to: nonEmpty.library)
        XCTAssertThrowsError(try SnippetStore.coordinatedRead(
            at: nonEmpty.library,
            maximumBytes: 0
        )) { error in
            let refused = error as? SnippetStore.OversizedLibraryRead
            XCTAssertEqual(refused?.ceiling, 0)
            XCTAssertGreaterThan(refused?.byteCount ?? 0, 0)
        }
        XCTAssertThrowsError(try SnippetStore.coordinatedRead(
            at: nonEmpty.library,
            maximumBytes: 0,
            statedByteCount: { _ in 0 }
        )) { error in
            let refused = error as? SnippetStore.OversizedLibraryRead
            XCTAssertEqual(refused?.ceiling, 0)
            XCTAssertEqual(refused?.byteCount, 1)
        }
        let refused = nonEmpty.load(maximumBytes: 0, statedByteCount: { _ in 0 })
        XCTAssertFalse(refused.decodeSucceeded)
        XCTAssertNotNil(refused.hardFailure)
        XCTAssertNotEqual(refused.loadIssue, .emptyFile(path: nonEmpty.library.path))
        guard case .unreadable(_, let reason)? = refused.loadIssue else {
            return XCTFail("zero ceiling is unreadable, not \(String(describing: refused.loadIssue))")
        }
        XCTAssertTrue(reason.contains("0"), reason)
        try assertNoSafetyCopy(under: nonEmpty.root, library: nonEmpty.library, largerThan: 0)

        let empty = try Fixture()
        defer { empty.cleanup() }
        try Data().write(to: empty.library)
        let loaded = empty.load(maximumBytes: 0)
        XCTAssertTrue(loaded.decodeSucceeded)
        XCTAssertNil(loaded.hardFailure)
        XCTAssertEqual(loaded.loadIssue, .emptyFile(path: empty.library.path))
        XCTAssertTrue(loaded.groups.isEmpty)
        XCTAssertEqual(try SnippetStore.coordinatedRead(at: empty.library, maximumBytes: 0), Data())
        try assertNoSafetyCopy(under: empty.root, library: empty.library, largerThan: 0)
    }
}
