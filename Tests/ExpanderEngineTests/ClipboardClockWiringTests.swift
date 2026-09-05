import Foundation
import XCTest

final class ClipboardClockWiringTests: XCTestCase {
    func testClipboardOperationalDeadlinesCannotReadWallTime() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("Sources/ExpanderEngine/Engine/PasteboardBroker.swift"), encoding: .utf8)
        XCTAssertFalse(code.contains("Date()"))
        XCTAssertFalse(code.contains("timeIntervalSinceNow"))
        XCTAssertTrue(code.contains("InputClock.monotonicNow"))
    }
}
