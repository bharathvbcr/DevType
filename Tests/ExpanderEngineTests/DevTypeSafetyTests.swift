import AppKit
import DevTypeSafety
import Security
import XCTest

final class DevTypeSafetyTests: XCTestCase {
    func testMakeKeyAndOrderFrontCatchingExceptionOnValidWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let exception = DTMakeKeyAndOrderFrontCatchingException(window)
        XCTAssertNil(exception)
    }

    func testSetValueForKeyCatchingValidAndInvalidKeys() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let success = DTSetValueForKeyCatching(window, "Test Title", "title")
        XCTAssertTrue(success)
        XCTAssertEqual(window.title, "Test Title")

        let obj = NSObject()
        let failed = DTSetValueForKeyCatching(obj, "Value", "invalidNonexistentKey123")
        XCTAssertFalse(failed)
    }

    func testKeychainUserInteractionAllowedRoundTrip() {
        var original: DarwinBoolean = false
        let getStatus = DTKeychainGetUserInteractionAllowed(&original)
        if getStatus == errSecSuccess {
            let setStatus = DTKeychainSetUserInteractionAllowed(original.boolValue)
            XCTAssertEqual(setStatus, errSecSuccess)
        }
    }

    func testKeychainGetDefaultStatus() {
        var status: SecKeychainStatus = 0
        _ = DTKeychainGetDefaultStatus(&status)
    }
}
