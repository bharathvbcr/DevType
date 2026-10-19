import Foundation
import XCTest
import SourceTreeTestSupport

final class ClipboardClockWiringTests: XCTestCase {
    func testClipboardOperationalDeadlinesCannotReadWallTime() throws {
        let code = try SourceTree.text("Sources/ExpanderEngine/Engine/PasteboardBroker.swift")
        XCTAssertFalse(code.contains("Date()"))
        XCTAssertFalse(code.contains("timeIntervalSinceNow"))
        XCTAssertTrue(code.contains("InputClock.monotonicNow"))
    }
}
