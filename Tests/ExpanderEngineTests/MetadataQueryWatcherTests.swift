import AppKit
import XCTest
@testable import ExpanderEngine

final class MetadataQueryWatcherTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metadata-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testMetadataQueryWatcherStartsWithExpectedScopesAndPredicate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("DevType-snippets.json")
        let watcher = MetadataQueryWatcher(fileURL: target)

        watcher.start()
        defer { watcher.stop() }

        XCTAssertEqual(watcher.query.searchScopes.count, 3)
        let hasDocumentsScope = watcher.query.searchScopes.contains {
            String(describing: $0) == NSMetadataQueryUbiquitousDocumentsScope
        }
        let hasDataScope = watcher.query.searchScopes.contains {
            String(describing: $0) == NSMetadataQueryUbiquitousDataScope
        }
        XCTAssertTrue(hasDocumentsScope)
        XCTAssertTrue(hasDataScope)
        XCTAssertTrue(
            watcher.query.searchScopes.contains(where: {
                guard let scope = $0 as? URL else { return false }
                return scope.standardizedFileURL == root.standardizedFileURL
            })
        )
        XCTAssertNotNil(watcher.query.predicate)
        XCTAssertTrue(watcher.query.predicate is NSCompoundPredicate)
    }

    func testMetadataQueryWatcherIgnoresNotificationsWhenNoTrackedResultMatches() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = MetadataQueryWatcher(fileURL: root.appendingPathComponent("DevType-snippets.json"))
        var changeCount = 0
        watcher.onChange = { changeCount += 1 }

        watcher.start()
        NotificationCenter.default.post(name: .NSMetadataQueryDidUpdate, object: watcher.query)
        runLoopDelay()
        watcher.stop()

        XCTAssertEqual(changeCount, 0)
    }

    func testMetadataQueryWatcherStartsFromBackgroundThread() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = MetadataQueryWatcher(fileURL: root.appendingPathComponent("DevType-snippets.json"))

        let started = expectation(description: "watcher started from background")
        DispatchQueue.global().async {
            watcher.start()
            for _ in 0..<100 {
                if watcher.query.isStarted {
                    started.fulfill()
                    return
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            started.fulfill()
        }

        wait(for: [started], timeout: 2)
        XCTAssertTrue(watcher.query.isStarted)

        watcher.stop()
        XCTAssertTrue(watcher.query.isStopped)
    }

    private func runLoopDelay() {
        let end = Date().addingTimeInterval(0.05)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: end)
        }
    }
}
