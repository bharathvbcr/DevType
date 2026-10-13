import AppKit
import XCTest
@testable import DevTypeAppCore

/// Runtime edges the source scan cannot see: a nil window, and log text that is
/// empty, huge, or not ASCII. `WindowOrdering` is internal to DevTypeAppCore.
final class DevTypeSafetyTestsOrderingEdges: XCTestCase {
    func testNilWindowMakeKeyAndOrderFrontDoesNotTrap() {
        WindowOrdering.makeKeyAndOrderFront(nil, context: "nil")
        WindowOrdering.makeKeyAndOrderFront(nil, context: oddContext)
    }

    func testLogCaughtAcceptsEmptyNameNilReasonAndOddContexts() {
        let emptyName = NSException(name: NSExceptionName(""), reason: nil, userInfo: nil)
        let emptyReason = NSException(name: NSExceptionName("DTEmptyReason"), reason: "", userInfo: nil)
        let oddReason = String(repeating: "理由\u{0000}\u{202E}%@ %n {public}", count: 40)
        let longName = NSException(
            name: NSExceptionName(String(repeating: "名", count: 200)),
            reason: oddReason,
            userInfo: nil
        )
        let contexts = [
            "",
            "\u{0000}",
            oddContext,
            String(repeating: "a", count: 4_096),
            "line\nbreak\r\n\t",
            "quotes \" \\ and slash /",
            String(repeating: "\u{0301}", count: 32),
        ]
        for context in contexts {
            WindowOrdering.logCaught(nil, context: context)
            WindowOrdering.logCaught(emptyName, context: context)
            WindowOrdering.logCaught(emptyReason, context: context)
            WindowOrdering.logCaught(longName, context: context)
            WindowOrdering.makeKeyAndOrderFront(nil, context: context)
        }
    }

    private var oddContext: String {
        "toast \u{1F600} \u{0301}e\u{0301} \u{202E}rtl \u{2066}isolate"
    }
}
