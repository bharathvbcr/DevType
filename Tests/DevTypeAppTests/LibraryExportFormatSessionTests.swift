import AppKit
import XCTest
@testable import DevTypeAppCore

final class LibraryExportFormatSessionTests: XCTestCase {
    func testConcurrentFormatSessionsKeepIndependentCallbacks() {
        var firstChanges = 0
        var secondChanges = 0
        let first = LibraryExportFormatSession { firstChanges += 1 }
        let second = LibraryExportFormatSession { secondChanges += 1 }
        let popup = NSPopUpButton()

        first.changed(popup)
        second.changed(popup)
        first.changed(popup)

        XCTAssertEqual(firstChanges, 2)
        XCTAssertEqual(secondChanges, 1)
    }
}
