import XCTest
#if canImport(AppKit)
import AppKit
#endif
@testable import ExpanderEngine

/// Covers the parts of the shared sidecar writer that no test reached while the same code
/// was copied into `UsageStatsStore` and `CommandUsageStatsStore`: the terminate flush and
/// the file-URL resolution. `UsageStatsFlushRetryTests` already pins the retry ladder.
final class DebouncedSidecarWriterTests: XCTestCase {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeSidecarWriter-\(UUID().uuidString)", isDirectory: true)
    }

    private func persistedUsageCount(at url: URL, key: String) -> Int? {
        guard let raw = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let stats = object["stats"] as? [String: Any],
              let entry = stats[key] as? [String: Any] else {
            return nil
        }
        return entry["usageCount"] as? Int
    }

    #if canImport(AppKit)
    /// The terminate hook is the sidecars' only guarantee that a counter recorded inside
    /// the debounce window survives quitting the app. Both stores installed their own copy
    /// and neither copy was tested; a long debounce means nothing else would write.
    func testTerminateNotificationFlushesSnippetSidecarWithinDebounceWindow() throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent(UsageStatsStore.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Long enough that only the terminate hook can produce the file.
        let store = UsageStatsStore(fileURL: fileURL, flushInterval: 600, flushRetryDelay: 600)
        let id = UUID()
        store.recordUsage(for: id)

        XCTAssertNil(persistedUsageCount(at: fileURL, key: id.uuidString),
                     "the debounce window must still be open — otherwise this proves nothing")

        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification, object: nil
        )

        XCTAssertEqual(persistedUsageCount(at: fileURL, key: id.uuidString), 1,
                       "terminating must flush the pending counter synchronously")
    }

    func testTerminateNotificationFlushesCommandSidecarWithinDebounceWindow() throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent(CommandUsageStatsStore.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CommandUsageStatsStore(
            fileURL: fileURL, flushInterval: 600, flushRetryDelay: 600
        )
        store.recordUsage(for: "cmd.terminate")

        XCTAssertNil(persistedUsageCount(at: fileURL, key: "cmd.terminate"),
                     "the debounce window must still be open — otherwise this proves nothing")

        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification, object: nil
        )

        XCTAssertEqual(persistedUsageCount(at: fileURL, key: "cmd.terminate"), 1,
                       "terminating must flush the pending command counter synchronously")
    }
    #endif

    /// An explicit override is what every test and the migration tooling relies on; the
    /// default has to stay device-local, because the sidecars are per-device telemetry and
    /// a synced copy would produce a permanent iCloud conflict on the expansion hot path.
    func testFileURLResolutionPrefersOverrideAndOtherwiseStaysDeviceLocal() {
        let override = temporaryDirectory().appendingPathComponent("explicit.json")
        XCTAssertEqual(
            DebouncedSidecarWriter.resolveFileURL(override: override, fileName: "ignored.json"),
            override
        )

        let resolved = DebouncedSidecarWriter.resolveFileURL(
            override: nil, fileName: UsageStatsStore.fileName
        )
        XCTAssertEqual(resolved.lastPathComponent, UsageStatsStore.fileName)
        XCTAssertEqual(
            resolved.deletingLastPathComponent().standardizedFileURL,
            SnippetStore.defaultLocalSupportDirectory.standardizedFileURL,
            "usage counters live in the device-local support directory, never the synced library"
        )
    }

    /// The two sidecars share one writer implementation but must never share a file: command
    /// IDs are arbitrary strings and snippet IDs are UUIDs, so one document cannot hold both.
    func testTheTwoSidecarsResolveToDistinctFiles() {
        XCTAssertNotEqual(UsageStatsStore.fileName, CommandUsageStatsStore.fileName)
        XCTAssertNotEqual(
            DebouncedSidecarWriter.resolveFileURL(
                override: nil, fileName: UsageStatsStore.fileName
            ),
            DebouncedSidecarWriter.resolveFileURL(
                override: nil, fileName: CommandUsageStatsStore.fileName
            )
        )
    }
}
