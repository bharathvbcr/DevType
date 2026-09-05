import AppKit
import XCTest
@testable import ExpanderEngine

final class ClipboardMonotonicTests: XCTestCase {
    func testElapsedInjectedUptimeReleasesNamedBoardSynchronously() {
        let broker = PasteboardBroker(now: { 102 })
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let owned = board.clearContents()
        XCTAssertTrue(board.setString("payload", forType: .string))
        let ticket = PasteboardBroker.ClipboardTicket(
            pasteboard: board, oldItems: nil, generation: broker.currentRestoreGeneration(), targetChangeCount: owned
        )
        let residency = PasteboardBroker.PayloadResidency(
            postedAt: 100, unverifiedHold: 1, ceiling: 2, targetPID: nil,
            hostRespondedAtPaste: false, bundleID: nil
        )
        var released = false
        broker.releaseOwnership(ticket, result: .unavailable, residency: residency) { released = true }
        XCTAssertTrue(released)
        XCTAssertNil(board.string(forType: .string))
    }

    func testInjectedUptimeMustReachDeadlineBeforeRelease() {
        var uptime = 100.0
        let broker = PasteboardBroker(now: { uptime })
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let owned = board.clearContents()
        XCTAssertTrue(board.setString("payload", forType: .string))
        let ticket = PasteboardBroker.ClipboardTicket(
            pasteboard: board, oldItems: nil, generation: broker.currentRestoreGeneration(), targetChangeCount: owned
        )
        let residency = PasteboardBroker.PayloadResidency(
            postedAt: 100, unverifiedHold: 0.01, ceiling: 2, targetPID: nil,
            hostRespondedAtPaste: false, bundleID: nil
        )
        let done = expectation(description: "deadline reached")
        var released = false
        broker.releaseOwnership(ticket, result: .unavailable, residency: residency) {
            released = true
            done.fulfill()
        }
        XCTAssertFalse(released)
        XCTAssertEqual(board.string(forType: .string), "payload")
        uptime = 100.01
        wait(for: [done], timeout: 1)
        XCTAssertNil(board.string(forType: .string))
    }

    func testInvalidOverridesRefuseBeforeClipboardPublicationOrFocusLookup() {
        let broker = PasteboardBroker()
        for hold in [Double.nan, .infinity, -.infinity, -1, 9, Double.greatestFiniteMagnitude] {
            var result: PasteboardBroker.PasteDeliveryResult?
            broker.pasteViaClipboard(text: "must not publish", expectedText: nil, baseline: nil,
                                     bundleID: nil, holdTimeoutOverride: hold) { result = $0 }
            XCTAssertEqual(result, .notPosted)
        }
    }
}
