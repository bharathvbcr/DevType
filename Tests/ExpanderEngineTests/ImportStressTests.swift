import XCTest
@testable import ExpanderEngine

// Stress over the import path now running off the main thread in the app layer:
// large synthetic libraries must stay time-bounded, and concurrent merges into a
// single store must serialize without corruption or lost groups.

final class ImportStressTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-stress-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// 200 files × 50 matches = 10 000 snippets. The app-layer refactor moved this
    /// work off-main; the engine path itself must stay comfortably bounded.
    func testLargeEspansoLibraryImportsBoundedAndComplete() throws {
        let matchDir = directory.appendingPathComponent("match", isDirectory: true)
        try FileManager.default.createDirectory(at: matchDir, withIntermediateDirectories: true)
        let files = 200
        let perFile = 50
        for file in 0..<files {
            var yaml = "matches:\n"
            for s in 0..<perFile {
                yaml += "  - trigger: \":f\(file)s\(s)\"\n    replace: \"value \(file)-\(s)\"\n"
            }
            try yaml.write(
                to: matchDir.appendingPathComponent("group_\(String(format: "%03d", file)).yml"),
                atomically: true,
                encoding: .utf8
            )
        }

        let started = Date()
        let result = try EspansoImporter.importFrom(matchDir)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.snippetCount, files * perFile, "every match must survive")
        XCTAssertEqual(result.groups.count, files, "one group per file")
        XCTAssertLessThan(elapsed, 30.0, "10k-snippet import took \(elapsed)s")
    }

    /// Eight threads merging distinct groups into one store concurrently. The
    /// app layer serializes flows with an in-flight guard, but the store must
    /// hold even if callers do not: every group lands exactly once and the
    /// library on disk stays loadable.
    func testConcurrentMergeImportsSerializeWithoutCorruption() throws {
        let store = SnippetStore(fileURL: directory.appendingPathComponent("snippets.json"))
        let threads = 8
        let groupsPerThread = 5

        let expectation = expectation(description: "concurrent merges")
        expectation.expectedFulfillmentCount = threads
        let queue = DispatchQueue(label: "stress", attributes: .concurrent)
        for t in 0..<threads {
            queue.async {
                defer { expectation.fulfill() }
                for g in 0..<groupsPerThread {
                    let group = SnippetGroup(name: "thread-\(t)-group-\(g)", snippets: [
                        SnippetModel(
                            title: "t\(t)g\(g)",
                            triggerKeyword: ";t\(t)g\(g)",
                            replacementText: "payload \(t)-\(g)"
                        ),
                    ])
                    _ = store.importGroups([group], mode: .merge)
                }
            }
        }
        wait(for: [expectation], timeout: 30)

        let loaded = store.loadGroups()
        let names = loaded.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "no duplicate groups")
        // A fresh local store seeds its default group before the merges land.
        XCTAssertEqual(names.count, threads * groupsPerThread + 1, "every merged group survived")
        for t in 0..<threads {
            for g in 0..<groupsPerThread {
                XCTAssertTrue(names.contains("thread-\(t)-group-\(g)"), "missing thread-\(t)-group-\(g)")
            }
        }

        // And the on-disk library reopens cleanly.
        let reloaded = SnippetStore(fileURL: directory.appendingPathComponent("snippets.json"))
        XCTAssertEqual(
            reloaded.loadGroups().count,
            threads * groupsPerThread + 1,
            "the library on disk reflects every concurrent merge"
        )
    }
}
