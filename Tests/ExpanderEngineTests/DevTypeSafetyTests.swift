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

    func testOrderFrontRegardlessCatchingExceptionOnValidWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let exception = DTOrderFrontRegardlessCatchingException(window)
        XCTAssertNil(exception)
    }

    /// Toast and the voice HUD must order front without becoming key. A Swift
    /// subclass that raises would abort, so the raising window itself is ObjC
    /// (`DevTypeSafetyTestsRaisingWindow`). This locks the call sites.
    func testNonActivatingPanelsUseOrderFrontCatchOnly() throws {
        let toast = try source("Sources/DevTypeAppCore/ToastPanel.swift")
        let voice = try source("Sources/DevTypeAppCore/VoiceHUDPanel.swift")
        for (name, text) in [("ToastPanel.swift", toast), ("VoiceHUDPanel.swift", voice)] {
            XCTAssertFalse(
                text.contains("makeKeyAndOrderFront"),
                "\(name) must not become key"
            )
            XCTAssertTrue(
                text.contains("DTOrderFrontRegardlessCatchingException"),
                "\(name) must order front through the non-activating catch"
            )
        }
    }

    /// Every production Swift `makeKeyAndOrderFront` / `orderFrontRegardless` send
    /// goes through an ObjC `@catch`. The catch functions' names do not contain
    /// the raw selector followed by `(`.
    func testProductionSwiftOrderFrontSendsAreCaught() throws {
        let sources = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return XCTFail("Could not enumerate \(sources.path)")
        }
        var raw: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            let text = SourceContractTests.strippingComments(try String(contentsOf: url, encoding: .utf8))
            // The helper's own declaration and its call sites are the catch.
            // What remains is a direct AppKit send (`receiver.makeKeyAndOrderFront(`
            // or `orderFrontRegardless(`). The ObjC function names use a capital
            // `Order`, so they do not match the raw selector.
            let withoutHelper = text
                .replacingOccurrences(of: "WindowOrdering.makeKeyAndOrderFront(", with: "")
                .replacingOccurrences(of: "func makeKeyAndOrderFront(", with: "")
            if withoutHelper.contains("makeKeyAndOrderFront(") || text.contains("orderFrontRegardless(") {
                raw.append(relative)
            }
        }
        XCTAssertEqual(raw, [], "Raw window ordering must go through DevTypeSafety: \(raw)")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return SourceContractTests.strippingComments(text)
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
