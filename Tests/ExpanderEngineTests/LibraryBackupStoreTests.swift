import XCTest
@testable import ExpanderEngine

/// The backup owner on its own: the name scheme, when a copy is (and is not) written, and the
/// retention promise — the 20 newest rolling backups plus the newest of each day for 30 days,
/// with safety copies never pruned.
final class LibraryBackupStoreTests: XCTestCase {

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private var root: URL!
    /// 2026-10-09 12:00:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_791_547_200)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devtype-backups-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func entry(_ kind: LibraryBackupStore.Kind, _ offset: TimeInterval, _ tag: String) -> LibraryBackupStore.Entry {
        LibraryBackupStore.Entry(
            url: URL(fileURLWithPath: "/backups/\(tag)"),
            createdAt: noon.addingTimeInterval(offset),
            kind: kind
        )
    }

    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    // MARK: - Retention table

    func testRetentionKeepsTheTwentyNewestPlusTheNewestOfEachDayWithinThirtyDays() {
        var entries: [LibraryBackupStore.Entry] = []
        // 25 edits this morning, newest first: only the 20 newest survive on count, and the
        // day rule adds nothing because the day's newest is already among them.
        for index in 0..<25 {
            entries.append(entry(.save, -Double(index) * minute, "today-\(index)"))
        }
        entries.append(entry(.save, -day - hour, "yesterday-newest"))
        entries.append(entry(.save, -day - 2 * hour, "yesterday-older"))
        entries.append(entry(.save, -29 * day, "day-29"))
        entries.append(entry(.save, -30 * day, "day-30-boundary"))
        entries.append(entry(.save, -31 * day, "day-31"))
        // Safety copies are outside the rolling rule entirely.
        entries.append(entry(.preOverwrite, -400 * day, "ancient-safety"))
        entries.append(entry(.corrupted, -1 * minute / 2, "fresh-safety"))

        let kept = LibraryBackupStore.retainedRollingBackups(entries.shuffled(), now: noon, calendar: utc)

        let expected = Set((0..<20).map { "today-\($0)" } + ["yesterday-newest", "day-29"])
        XCTAssertEqual(Set(kept.map(\.lastPathComponent)), expected)
    }

    func testRetentionTable() {
        struct Row {
            let name: String
            let offsets: [TimeInterval]
            let kept: Set<Int>
        }
        let rows = [
            Row(name: "empty", offsets: [], kept: []),
            Row(name: "one", offsets: [-hour], kept: [0]),
            Row(name: "exactly twenty, all old", offsets: (0..<20).map { -Double(100 + $0) * day }, kept: Set(0..<20)),
            Row(name: "twenty-one old: the oldest goes", offsets: (0..<21).map { -Double(100 + $0) * day }, kept: Set(0..<20)),
            Row(name: "daily newest survives past the count",
                offsets: (0..<20).map { -Double($0) * minute } + [-2 * day - hour, -2 * day - 2 * hour],
                kept: Set(0..<20).union([20])),
            Row(name: "one second inside the window", offsets: (0..<20).map { -Double($0) * minute } + [-30 * day + 1],
                kept: Set(0..<21)),
            Row(name: "exactly thirty days is outside", offsets: (0..<20).map { -Double($0) * minute } + [-30 * day],
                kept: Set(0..<20)),
        ]
        for row in rows {
            let entries = row.offsets.enumerated().map { entry(.save, $0.element, "\($0.offset)") }
            let kept = LibraryBackupStore.retainedRollingBackups(entries, now: noon, calendar: utc)
            XCTAssertEqual(Set(kept.map { Int($0.lastPathComponent)! }), row.kept, row.name)
        }
    }

    /// The promise, against real files: after a prune, exactly the promised rolling set and every
    /// safety copy remain, and a file outside the name scheme is never touched.
    func testPruneLeavesExactlyThePromisedSetOnDisk() throws {
        let clock = Clock(noon.addingTimeInterval(-40 * day))
        let store = LibraryBackupStore(directory: root, now: { clock.now }, calendar: utc)
        var expected = Set<String>()

        // One backup a day for 40 days: only the last 30 days' survive the daily rule.
        for dayIndex in 0..<40 {
            clock.now = noon.addingTimeInterval(Double(dayIndex - 40) * day)
            let url = try store.backUp(Data("day \(dayIndex)".utf8), kind: .save).url
            if dayIndex - 40 > -30 { expected.insert(url.lastPathComponent) }
        }
        // Then 25 saves this morning: the 20 newest survive; the day's newest is among them.
        for index in 0..<25 {
            clock.now = noon.addingTimeInterval(Double(index) * minute)
            let url = try store.backUp(Data("edit \(index)".utf8), kind: .save).url
            if index >= 5 { expected.insert(url.lastPathComponent) }
        }
        // The 20 newest overall are all from this morning, so yesterday back to day -29 are kept
        // by the daily rule alone (computed above).
        let safety = try store.backUp(Data("before overwrite".utf8), kind: .preOverwrite).url
        expected.insert(safety.lastPathComponent)
        let stranger = root.appendingPathComponent("notes.txt")
        try Data("not a backup".utf8).write(to: stranger)

        let report = store.prune()

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(remaining.subtracting(["notes.txt"]), expected)
        XCTAssertTrue(remaining.contains("notes.txt"), "a file outside the scheme was removed")
        XCTAssertEqual(report.removed, 40 + 25 + 1 - expected.count)
        XCTAssertEqual(report.failed, 0)

        // Idempotent: a second pass removes nothing.
        XCTAssertEqual(store.prune().removed, 0)
    }

    func testSafetyRetentionTable() {
        struct Row {
            let name: String
            let offsets: [TimeInterval]
            let kept: Set<Int>
        }
        let rows = [
            Row(name: "empty", offsets: [], kept: []),
            Row(name: "ancient newest of a kind is kept", offsets: [-400 * day], kept: [0]),
            Row(name: "twelve ancient: the ten newest stay",
                offsets: (0..<12).map { -Double(400 + $0) * day }, kept: Set(0..<10)),
            Row(name: "twelve recent are all inside the window",
                offsets: (0..<12).map { -Double($0) * hour }, kept: Set(0..<12)),
            Row(name: "window edge: 30 days is outside",
                offsets: (0..<10).map { -Double($0) * hour } + [-30 * day + 1, -30 * day], kept: Set(0..<11)),
        ]
        for kind in LibraryBackupStore.Kind.allCases where kind.isCappedSafety {
            for row in rows {
                let entries = row.offsets.enumerated().map { entry(kind, $0.element, "\($0.offset)") }
                let kept = LibraryBackupStore.retainedSafetyBackups(entries, now: noon, calendar: utc)
                XCTAssertEqual(Set(kept.map { Int($0.lastPathComponent)! }), row.kept, "\(kind) \(row.name)")
            }
        }
        // Kinds are capped independently, and the unprunable kinds are not this rule's.
        let mixed = (0..<11).map { entry(.preRestore, -Double(400 + $0) * day, "r\($0)") }
            + [entry(.preSaveAs, -500 * day, "s0"), entry(.corrupted, -500 * day, "c0"), entry(.save, -500 * day, "v0")]
        let keptMixed = Set(LibraryBackupStore.retainedSafetyBackups(mixed, now: noon, calendar: utc).map(\.lastPathComponent))
        XCTAssertEqual(keptMixed, Set((0..<10).map { "r\($0)" } + ["s0"]))
    }

    func testPruneCapsEachSafetyKindOnDiskButKeepsItsNewest() throws {
        let clock = Clock(noon.addingTimeInterval(-1_000 * day))
        let store = LibraryBackupStore(directory: root, now: { clock.now }, calendar: utc)
        var restores: [URL] = []
        for index in 0..<14 {
            clock.now = noon.addingTimeInterval(Double(index - 1_000) * day)
            restores.append(try store.backUp(Data("restore \(index)".utf8), kind: .preRestore).url)
        }
        let quarantine = try store.backUp(Data("torn".utf8), kind: .corrupted).url
        clock.now = noon

        let report = store.prune()

        XCTAssertEqual(report.removed, 4)
        for (index, url) in restores.enumerated() {
            XCTAssertEqual(FileManager.default.fileExists(atPath: url.path), index >= 4, "pre-restore \(index)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path), "a corrupted quarantine is never pruned")
        XCTAssertEqual(store.prune().removed, 0)
    }

    func testTheNewestSafetyCopyOfEachKindIsNeverPruned() throws {
        let clock = Clock(noon.addingTimeInterval(-1_000 * day))
        let store = LibraryBackupStore(directory: root, now: { clock.now }, calendar: utc)
        var safety: [URL] = []
        for kind in LibraryBackupStore.Kind.allCases where !kind.isRolling {
            safety.append(try store.backUp(Data("old \(kind.rawValue)".utf8), kind: kind).url)
        }
        clock.now = noon
        for index in 0..<30 { try store.backUp(Data("edit \(index)".utf8), kind: .save) }

        store.prune()

        for url in safety {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) was pruned")
        }
    }

    // MARK: - Writing

    func testIdenticalBytesAreNotCopiedTwiceButSafetyCopiesAreNotSatisfiedByRollingOnes() throws {
        let store = LibraryBackupStore(directory: root)
        let bytes = Data("library".utf8)

        let first = try store.backUp(bytes, kind: .save)
        XCTAssertTrue(first.created)
        let again = try store.backUp(bytes, kind: .save)
        XCTAssertFalse(again.created)
        XCTAssertEqual(again.url, first.url)

        // A rolling copy ages out; a safety copy must not depend on one.
        let safety = try store.backUp(bytes, kind: .preRestore)
        XCTAssertTrue(safety.created)
        XCTAssertNotEqual(safety.url, first.url)
        // ...while a rolling request is satisfied by any identical newest copy.
        XCTAssertFalse(try store.backUp(bytes, kind: .save).created)
        // And a repeated identical safety request reuses its own kind.
        XCTAssertFalse(try store.backUp(bytes, kind: .preRestore).created)

        XCTAssertTrue(try store.backUp(Data("changed".utf8), kind: .save).created)
        XCTAssertEqual(store.entries().count, 3)
    }

    /// A fresh store (a relaunch) must not copy bytes an earlier run already backed up.
    func testNewestDigestIsSeededFromDisk() throws {
        let bytes = Data("library".utf8)
        XCTAssertTrue(try LibraryBackupStore(directory: root).backUp(bytes, kind: .save).created)
        XCTAssertFalse(try LibraryBackupStore(directory: root).backUp(bytes, kind: .save).created)
    }

    func testBackupsAreOwnerOnlyAndNamedByTheScheme() throws {
        let clock = Clock(noon)
        let store = LibraryBackupStore(directory: root, now: { clock.now })
        let first = try store.backUp(Data("a".utf8), kind: .preSaveAs).url
        let second = try store.backUp(Data("b".utf8), kind: .preSaveAs).url

        XCTAssertEqual(first.lastPathComponent, "library-pre-save-as-20261009T120000.000Z.bak.json")
        XCTAssertEqual(second.lastPathComponent, "library-pre-save-as-20261009T120000.000Z-1.bak.json",
                       "a same-millisecond backup must not overwrite the first")
        let mode = try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        let entries = store.entries()
        XCTAssertEqual(entries.map(\.url), [second, first], "same-millisecond backups must list newest first")
        XCTAssertEqual(entries.first?.createdAt, noon)
    }

    func testParseRejectsNamesOutsideTheScheme() {
        XCTAssertNil(LibraryBackupStore.parse("snippets.json.bak.1791547200"))
        XCTAssertNil(LibraryBackupStore.parse("devtype-backup-pre-save-as-2026-10-09-120000-000.json"))
        XCTAssertNil(LibraryBackupStore.parse("library-unknown-20261009T120000.000Z.bak.json"))
        XCTAssertNil(LibraryBackupStore.parse("library-save-20261009T120000.000Z-x.bak.json"))
        XCTAssertNil(LibraryBackupStore.parse("library-save-2026.bak.json"))
        XCTAssertNil(LibraryBackupStore.parse("library-save-20261009T120000.000Z-0.bak.json"))
        XCTAssertEqual(LibraryBackupStore.parse("library-pre-save-as-20261009T120000.000Z.bak.json")?.kind, .preSaveAs)
        let suffixed = LibraryBackupStore.parse("library-save-20261009T120000.000Z-12.bak.json")
        XCTAssertEqual(suffixed?.kind, .save)
        XCTAssertEqual(suffixed?.sequence, 12)
    }

    func testEntryForRejectsFilesOutsideTheBackupDirectory() throws {
        let store = LibraryBackupStore(directory: root)
        let inside = try store.backUp(Data("a".utf8), kind: .save).url
        XCTAssertNotNil(store.entry(for: inside))
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent(inside.lastPathComponent)
        XCTAssertNil(store.entry(for: elsewhere))
    }

    /// A crash or cancellation between the safety copy and the overwrite must still find the
/// pre-overwrite bytes at the live path. Moving the file aside fails that: the only name left
/// is the backup. Spaces and non-ASCII in the library folder are part of the same path.
func testUnreadablePreserveKeepsTheLiveFileUntilOverwriteCommits() throws {
    let folder = root.appendingPathComponent("Library Folder 한글", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("my snippets.json")
    let original = Data("raw-bytes-\u{2603}".utf8)
    try original.write(to: file)
    defer {
        try? FilePermissions.setPOSIX(file, 0o600)
        if let backup = try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Backups", isDirectory: true),
            includingPropertiesForKeys: nil
        ) {
            for url in backup { try? FilePermissions.setPOSIX(url, 0o600) }
        }
    }
    try FilePermissions.setPOSIX(file, 0)
    if FileManager.default.isReadableFile(atPath: file.path) {
        throw XCTSkip("this process can read a mode-000 file")
    }

    let store = LibraryBackupStore(directory: root.appendingPathComponent("Backups", isDirectory: true))
    let preserved = try XCTUnwrap(try store.preserve(fileAt: file, bytes: nil, kind: .preOverwrite))

    XCTAssertTrue(
        FileManager.default.fileExists(atPath: file.path),
        "the live file was removed before the overwrite committed"
    )
    XCTAssertFalse(
        FileManager.default.isReadableFile(atPath: file.path),
        "preserving the backup changed the live file before the overwrite committed"
    )
    try FilePermissions.setPOSIX(file, 0o600)
    XCTAssertEqual(try Data(contentsOf: file), original)

    let replacement = Data("replaced".utf8)
    try replacement.write(to: file, options: .atomic)
    try FilePermissions.setPOSIX(preserved.url, 0o600)
    XCTAssertEqual(try Data(contentsOf: preserved.url), original,
                   "replacing the live path rewrote the only copy of the previous bytes")
    XCTAssertEqual(try Data(contentsOf: file), replacement)
}

func testSchedulePruneRunsOffTheCallerAndReports() throws {
        let clock = Clock(noon)
        let store = LibraryBackupStore(directory: root, now: { clock.now }, calendar: utc)
        for index in 0..<22 {
            clock.now = noon.addingTimeInterval(Double(index) * minute)
            try store.backUp(Data("\(index)".utf8), kind: .save)
        }
        let done = expectation(description: "prune")
        store.schedulePrune { report in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(report.removed, 2)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(store.entries().count, 20)
    }
}
