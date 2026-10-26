import AppKit
import XCTest
@testable import ExpanderEngine

/// Everything that stops a paste before ⌘V goes out, driven through the real broker on the shared
/// harness's private board with every key recorded. Each refusal is its own condition — cancelled,
/// Post Events denied, Secure Input on, target moved — and each must leave the user's clipboard
/// untouched and post nothing. (That each also logs its own sentence rather than one combined
/// "Post Events denied" is pinned by `SourceContractTests`: os.Logger has no capture seam.)
final class PasteGateTests: XCTestCase {
    private let user = "the user's own clipboard"

    private func makeImage() -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.addRepresentation(rep)
        return image
    }

    private enum Kind: CaseIterable { case text, image }

    private func paste(
        _ kind: Kind, on harness: InjectionHarness,
        focusedRole: String? = nil,
        holdTimeoutOverride: TimeInterval? = nil,
        shouldContinue: @escaping () -> Bool = { true }
    ) -> PasteboardBroker.PasteDeliveryResult? {
        var result: PasteboardBroker.PasteDeliveryResult?
        switch kind {
        case .text:
            harness.broker.pasteViaClipboard(
                text: "PAYLOAD", expectedText: nil, baseline: nil, focus: .resolved(harness.field),
                focusedRole: focusedRole, holdTimeoutOverride: holdTimeoutOverride,
                completeBeforeRestore: true, shouldContinue: shouldContinue
            ) { result = $0 }
        case .image:
            harness.broker.pasteImageViaClipboard(
                image: makeImage(), imagePath: nil, bundleID: nil, focus: .resolved(harness.field),
                shouldContinue: shouldContinue
            ) { result = $0 }
        }
        harness.pump(in: self, timeout: 5, "the paste to answer") { result != nil }
        return result
    }

    /// A refusal before publication: nothing posted, and the board never written to at all.
    private func assertRefused(
        _ kind: Kind, _ harness: InjectionHarness, _ message: String,
        file: StaticString = #filePath, line: UInt = #line,
        shouldContinue: @escaping () -> Bool = { true }
    ) {
        let before = harness.board.changeCount
        let result = paste(kind, on: harness, shouldContinue: shouldContinue)
        XCTAssertEqual(result, .notPosted, "\(kind): \(message)", file: file, line: line)
        XCTAssertTrue(harness.log.isEmpty, "\(kind): a refused paste posted \(harness.log)", file: file, line: line)
        XCTAssertEqual(harness.board.changeCount, before, "\(kind): the board was written to", file: file, line: line)
        XCTAssertEqual(harness.board.string(forType: .string), user, file: file, line: line)
    }

    private func harness() throws -> InjectionHarness {
        let harness = try InjectionHarness()
        harness.seedUserClipboard(user)
        return harness
    }

    func testAnOperationThatWasCancelledNeverPastes() throws {
        for kind in Kind.allCases {
            assertRefused(kind, try harness(), "cancelled or superseded", shouldContinue: { false })
        }
    }

    func testPostEventsDeniedAtPasteTimeNeverPastes() throws {
        for kind in Kind.allCases {
            let harness = try harness()
            harness.canPostEvents = false
            assertRefused(kind, harness, "Post Events denied")
        }
    }

    func testSecureInputAtPasteTimeNeverPastes() throws {
        for kind in Kind.allCases {
            let harness = try harness()
            harness.secureInput = true
            assertRefused(kind, harness, "Secure Input active")
        }
    }

    func testATargetThatMovedBeforeThePasteNeverPastes() throws {
        for kind in Kind.allCases {
            let harness = try harness()
            harness.page.focused = harness.window
            harness.brokerRefusesTarget = true
            assertRefused(kind, harness, "target changed")
        }
    }

    func testAnInvalidHoldWindowRefusesInsteadOfCompletingSilently() throws {
        for bad in [TimeInterval.nan, -1, InjectTiming.secureClipboardPasteHoldTimeout + 1] {
            let harness = try harness()
            let result = paste(.text, on: harness, holdTimeoutOverride: bad)
            XCTAssertEqual(result, .notPosted, "hold \(bad)")
            XCTAssertTrue(harness.log.isEmpty)
            XCTAssertEqual(harness.board.string(forType: .string), user)
        }
    }

    /// The paste is decided before ⌘V and decided again at it: an operation that is cancelled in the
    /// settle between publishing the payload and posting the chord never posts, and the user's
    /// clipboard is given back.
    func testACancellationDuringTheSettleBetweenPublishAndChordNeverPosts() throws {
        for kind in Kind.allCases {
            let harness = try harness()
            var calls = 0
            let result = paste(kind, on: harness, shouldContinue: { calls += 1; return calls == 1 })
            XCTAssertEqual(result, .notPosted, "\(kind)")
            XCTAssertGreaterThan(calls, 1, "\(kind): the chord's own continuation consulted the operation again")
            XCTAssertEqual(harness.chords, 0, "\(kind)")
            XCTAssertFalse(harness.log.contains { if case .paste = $0 { true } else { false } }, "\(kind)")
            harness.pump(in: self, timeout: 3, "the user's clipboard to come back") {
                harness.board.string(forType: .string) == user
            }
        }
    }

    /// After the erase the paste does not hold the host to a stable selection range — AX
    /// `selectedRange` is not a same-caret signal once our own keys have changed the field — and
    /// does not hold an unstable node (a combo box) to element identity either.
    func testAfterAMutationThePasteHoldsNeitherTheRangeNorAnUnstableNode() throws {
        let stable = try harness()
        XCTAssertEqual(paste(.text, on: stable, focusedRole: "AXTextArea"), .unavailable)
        XCTAssertFalse(stable.targetChecks.isEmpty)
        XCTAssertTrue(stable.targetChecks.allSatisfy { !$0.checkRange }, "\(stable.targetChecks)")
        XCTAssertTrue(stable.targetChecks.allSatisfy { $0.checkElement }, "a text area is still held to identity")

        let combo = try harness()
        XCTAssertEqual(paste(.text, on: combo, focusedRole: "AXComboBox"), .unavailable)
        XCTAssertTrue(combo.targetChecks.allSatisfy { !$0.checkRange && !$0.checkElement }, "\(combo.targetChecks)")

        XCTAssertFalse(PasteboardBroker.verifySelectionRange(verdict: .unknown, bundleKnown: true, phase: .afterMutation))
    }
}
