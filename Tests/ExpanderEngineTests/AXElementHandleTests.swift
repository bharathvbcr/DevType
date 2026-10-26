import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// `SelectionReplacement`'s synthesized equality now runs through the handle, so it must keep the
/// element's own identity: separately copied references to one element equal, different ones not.
final class AXElementHandleTests: XCTestCase {

    func testEqualityIsTheElementsOwn() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let one = AXElementHandle(AXUIElementCreateApplication(pid))
        let again = AXElementHandle(AXUIElementCreateApplication(pid))
        let other = AXElementHandle(AXUIElementCreateApplication(1))
        XCTAssertEqual(one, again)
        XCTAssertNotEqual(one, other)
    }

    func testASelectionReplacementComparesItsCapturedElement() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let a = try XCTUnwrap(SelectionReplacement(original: "x", capturedElement: AXUIElementCreateApplication(pid)))
        let b = try XCTUnwrap(SelectionReplacement(original: "x", capturedElement: AXUIElementCreateApplication(pid)))
        let elsewhere = try XCTUnwrap(SelectionReplacement(original: "x", capturedElement: AXUIElementCreateApplication(1)))
        let none = try XCTUnwrap(SelectionReplacement(original: "x"))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, elsewhere)
        XCTAssertNotEqual(a, none)
        XCTAssertEqual(none, SelectionReplacement(original: "x"))
        XCTAssertTrue(CFEqual(try XCTUnwrap(a.capturedElement), AXUIElementCreateApplication(pid)))
    }
}
