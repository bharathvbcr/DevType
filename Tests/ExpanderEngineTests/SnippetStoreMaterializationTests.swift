import XCTest
@testable import ExpanderEngine

// §-audit hardening for the iCloud materialization path.
//
// `materializeIfNeeded` used to busy-wait up to two seconds on the calling
// thread — reachable synchronously from `SnippetStore.init`, so a launch with an
// evicted iCloud library stalled the main thread for the full timeout. The wait
// now runs on a background queue and reloads when the file lands; these tests
// pin that init returns promptly and that a library materializing after launch
// is picked up and announced to group listeners.

final class SnippetStoreMaterializationTests: XCTestCase {

    private func makePlaceholderDirectory() throws -> (directory: URL, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeMaterialize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("snippets.json")
        // The macOS placeholder for an evicted iCloud item: `.snippets.json.icloud`.
        // Its presence alone is what sent the old code into its blocking wait.
        try Data().write(to: directory.appendingPathComponent(".snippets.json.icloud"))
        return (directory, fileURL)
    }

    /// Init with an unmaterialized iCloud placeholder must not busy-wait: it
    /// proceeds immediately, treating the missing file as missing-library exactly
    /// as it always has, and the store remains fully usable.
    func testInitWithPendingICloudPlaceholderReturnsPromptlyAndStoreWorksEmpty() throws {
        let (directory, fileURL) = try makePlaceholderDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = Date()
        let store = SnippetStore(
            location: SnippetStore.Location(fileURL: fileURL, expectsExistingLibrary: false),
            watcherFactory: { _ in nil }
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(
            elapsed, 1.0,
            "init blocked \(elapsed)s waiting for iCloud; the bounded wait must run "
                + "on a background queue, never on the caller."
        )

        // Missing-as-empty semantics preserved: saves work, reads are consistent.
        let group = SnippetGroup(name: "General", snippets: [
            SnippetModel(title: "T", triggerKeyword: ":t", replacementText: "x")
        ])
        XCTAssertTrue(store.saveGroups([group]).didSave)
        XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword), [":t"])
    }

    /// A library that materializes *after* launch must be picked up by the
    /// background wait and announced to group listeners, and saving must resume
    /// once the configured library is readable.
    func testLibraryMaterializingAfterLaunchIsReloadedAndAnnounced() throws {
        let (directory, fileURL) = try makePlaceholderDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SnippetStore(
            location: SnippetStore.Location(fileURL: fileURL, expectsExistingLibrary: true),
            watcherFactory: { _ in nil }
        )
        // No watcher is installed, so any pickup below can only come from the
        // materialization wait itself.

        final class Recorder {
            let lock = NSLock()
            var names: [[String]] = []
        }
        let recorder = Recorder()
        _ = store.addGroupListener { groups in
            recorder.lock.lock()
            recorder.names.append(groups.map(\.name))
            recorder.lock.unlock()
        }

        // Simulate iCloud finishing the download.
        let arrived = SnippetGroup(name: "CloudArrived", snippets: [
            SnippetModel(title: "C", triggerKeyword: ":cloud", replacementText: "synced")
        ])
        try SnippetStore.encodeLibrary([arrived]).write(to: fileURL, options: .atomic)

        // Pump the main run loop so listener notifications (main queue) land while
        // we poll. The background wait polls every 100 ms within the 2 s budget;
        // give the whole chain 6 s of slack.
        let deadline = Date().addingTimeInterval(6)
        var announced = false
        while Date() < deadline {
            recorder.lock.lock()
            announced = recorder.names.contains { $0.contains("CloudArrived") }
            recorder.lock.unlock()
            if announced, store.loadGroups().contains(where: { $0.name == "CloudArrived" }) {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        recorder.lock.lock()
        let announcements = recorder.names.filter { $0.contains("CloudArrived") }.count
        recorder.lock.unlock()

        XCTAssertTrue(
            store.loadGroups().contains(where: { $0.name == "CloudArrived" }),
            "the in-memory groups must adopt the materialized library"
        )
        XCTAssertGreaterThanOrEqual(
            announcements, 1,
            "group listeners must be told the materialized library arrived"
        )
        XCTAssertTrue(
            store.saveGroups([arrived]).didSave,
            "once the configured library is readable, saves must be unblocked"
        )
    }
}
