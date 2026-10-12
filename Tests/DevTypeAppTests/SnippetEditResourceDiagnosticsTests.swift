import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

final class SnippetEditResourceDiagnosticsTests: XCTestCase {
    func testImageImportFailureRecordsCauseBehindUnavailable() {
        let lock = NSLock()
        var lines: [String] = []
        PersistedFileLoader.observer = { lock.lock(); lines.append($0); lock.unlock() }
        defer { PersistedFileLoader.observer = nil }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-missing-\(UUID().uuidString).png")
        let result = SnippetEditResourceAccess.live.importImage(missing)

        guard case .failure(.unavailable) = result else { return XCTFail("expected .unavailable") }
        lock.lock(); defer { lock.unlock() }
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("[Editor] image import failed"), joined)
        XCTAssertTrue(joined.contains("code="), joined)
        XCTAssertFalse(joined.contains(missing.lastPathComponent), "diagnostic leaked a path")
    }
}
