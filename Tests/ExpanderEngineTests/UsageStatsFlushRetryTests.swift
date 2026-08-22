import XCTest
@testable import ExpanderEngine

// §-audit hardening for the usage sidecars' flush retry.
//
// On a write failure both stores re-armed `dirty` but scheduled nothing, so the
// counters sat unflushed until some *later* mutation happened to schedule the
// next debounce tick — an indefinite data-loss window after a transient failure
// (full disk, iCloud eviction). The fix schedules exactly one bounded retry per
// failure, guarded by the existing flush-generation token.

final class UsageStatsFlushRetryTests: XCTestCase {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeFlushRetry-\(UUID().uuidString)", isDirectory: true)
    }

    func testUsageStatsFailedFlushIsRetriedUntilItPersists() throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent(UsageStatsStore.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = UsageStatsStore(fileURL: fileURL, flushInterval: 0, flushRetryDelay: 0.05)
        let id = UUID()

        let lock = NSLock()
        var attempts = 0
        store.writeInterceptor = { data in
            lock.lock()
            attempts += 1
            let attempt = attempts
            lock.unlock()
            if attempt <= 2 {
                throw NSError(domain: "devtype.tests.flush", code: attempt)
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        }

        store.recordUsage(for: id)
        // No manual flush: with flushInterval 0 the record itself schedules the
        // first write, which fails (attempt #1), re-arms dirty, and must schedule
        // the bounded retry chain (#2 fails, #3 writes). A manual flush here would
        // rescue the write and mask a missing retry.

        // Poll until the retried flush lands.
        let deadline = Date().addingTimeInterval(5)
        var persistedCount: Int?
        while Date() < deadline {
            if let raw = try? Data(contentsOf: fileURL),
               let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let stats = object["stats"] as? [String: Any],
               let entry = stats[id.uuidString] as? [String: Any] {
                persistedCount = entry["usageCount"] as? Int
                if persistedCount == 1 { break }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(persistedCount, 1,
                       "the retried flush must persist the recorded counter")

        lock.lock()
        let totalAttempts = attempts
        lock.unlock()
        XCTAssertEqual(totalAttempts, 3,
                       "two failures plus one successful retry — no more, no fewer")

        // No tight loop: once clean, nothing further is written.
        Thread.sleep(forTimeInterval: 0.3)
        lock.lock()
        let settledAttempts = attempts
        lock.unlock()
        XCTAssertEqual(settledAttempts, totalAttempts,
                       "a clean archive must not keep triggering writes")
    }

    func testCommandUsageStatsFailedFlushIsRetriedUntilItPersists() throws {
        let directory = temporaryDirectory()
        let fileURL = directory.appendingPathComponent(CommandUsageStatsStore.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = CommandUsageStatsStore(fileURL: fileURL, flushInterval: 0, flushRetryDelay: 0.05)

        let lock = NSLock()
        var attempts = 0
        store.writeInterceptor = { data in
            lock.lock()
            attempts += 1
            let attempt = attempts
            lock.unlock()
            if attempt <= 1 {
                throw NSError(domain: "devtype.tests.flush", code: attempt)
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        }

        store.recordUsage(for: "cmd.retry")
        // Same discipline as the snippet sidecar: the record schedules attempt #1;
        // only the retry chain may produce the persisted file.

        let deadline = Date().addingTimeInterval(5)
        var persistedCount: Int?
        while Date() < deadline {
            if let raw = try? Data(contentsOf: fileURL),
               let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let stats = object["stats"] as? [String: Any],
               let entry = stats["cmd.retry"] as? [String: Any] {
                persistedCount = entry["usageCount"] as? Int
                if persistedCount == 1 { break }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(persistedCount, 1,
                       "the retried flush must persist the recorded command counter")
    }
}
