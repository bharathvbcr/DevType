import ApplicationServices
import XCTest
@testable import ExpanderEngine

final class PasteTargetTests: XCTestCase {
    func testSameApplicationDifferentFieldAndSelectionChangesInvalidatePaste() {
        let original = AXUIElementCreateApplication(getpid())
        let different = AXUIElementCreateApplication(1)
        let range = NSRange(location: 12, length: 3)
        let target = PasteboardBroker.PasteTarget(pid: getpid(), element: original, range: range)
        XCTAssertTrue(target.matches(pid: getpid(), element: original, range: range, checkRange: true))
        XCTAssertFalse(target.matches(pid: getpid(), element: different, range: range, checkRange: true))
        XCTAssertFalse(target.matches(pid: getpid(), element: original, range: NSRange(location: 0, length: 0), checkRange: true))
        XCTAssertFalse(target.matches(pid: getpid(), element: original, range: nil, checkRange: true))
        XCTAssertFalse(target.matches(pid: 1, element: original, range: range, checkRange: true))
        XCTAssertFalse(target.matches(pid: nil, element: original, range: range, checkRange: true))
        XCTAssertFalse(target.matches(pid: getpid(), element: nil, range: range, checkRange: true))
        // Delivery itself intentionally changes the range after the key has posted.
        XCTAssertTrue(target.matches(pid: getpid(), element: original, range: nil, checkRange: false))
    }
}
