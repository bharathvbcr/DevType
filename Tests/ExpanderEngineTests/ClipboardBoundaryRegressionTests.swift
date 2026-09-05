import AppKit
import XCTest
@testable import ExpanderEngine

final class ClipboardBoundaryRegressionTests: XCTestCase {
    func testImageCopyRequiresCheckedPublicationBeforeReportingSuccess() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/DevTypeAppCore/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("guard PasteboardBroker.shared.writeUserClipboardImage(image) else"))
        XCTAssertFalse(source.contains("NSPasteboard.general.writeObjects([image])"))
    }

    func testInvalidCopyTimingRefusesBeforePosting() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let broker = PasteboardBroker()
        for (timeout, poll) in [(0.0, 0.005), (-1, 0.005), (.nan, 0.005), (.infinity, 0.005),
                                (6, 0.005), (0.1, .nan), (0.1, .infinity), (0.1, 0), (0.1, 1)] {
            var posted = false
            let result = broker.captureSelectionViaCopy(
                pasteboard: board, expectedFrontmostPID: 123, timeout: timeout, pollInterval: poll,
                frontmostPIDProvider: { 123 }, secureInputProvider: { false },
                postCopy: { posted = true; return false })
            XCTAssertEqual(result, .postFailed)
            XCTAssertFalse(posted, "Invalid timing must fail before an effect")
        }
    }

    func testImageRepresentationsPublishOnNamedPasteboardAndEmptyImagePreservesClipboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("original", forType: .string))
        let broker = PasteboardBroker()
        XCTAssertFalse(broker.writeUserClipboardImage(NSImage(), pasteboard: board))
        XCTAssertEqual(board.string(forType: .string), "original")
        let pixels = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.addRepresentation(pixels)
        XCTAssertTrue(broker.writeUserClipboardImage(image, pasteboard: board))
        XCTAssertNotNil(board.data(forType: .png))
        XCTAssertNotNil(board.data(forType: .tiff))
        XCTAssertNil(board.string(forType: .string))
    }

    func testPartialPublicationRecoveryRestoresOnlyThePriorItemsOnNamedBoard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let broker = PasteboardBroker()
        let prior: PasteboardBroker.PasteboardSnapshot = [[.string: Data("original".utf8)]]
        let partialType = NSPasteboard.PasteboardType("devtype.test.partial")
        let outcome = broker.performUserClipboardWrite(priorSnapshot: prior,
            clearContents: { board.clearContents() }, currentChangeCount: { board.changeCount },
            writes: [{ board.setData(Data([1, 2]), forType: partialType) }, { false }],
            restoreSnapshot: { snapshot, owned in
                PasteboardBroker.restoreUserClipboardSnapshot(snapshot, ownedChangeCount: owned,
                    clearContents: { board.clearContents() },
                    currentChangeCount: { board.changeCount }, writeObjects: { board.writeObjects($0) })
            })
        XCTAssertEqual(outcome, .writeFailedPriorRestored)
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertNil(board.data(forType: partialType))
        XCTAssertEqual(board.pasteboardItems?.count, 1)
    }

    func testStalledInjectedCopyClockStillHasFinitePollBudget() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let broker = PasteboardBroker(now: { 100 })
        let started = ProcessInfo.processInfo.systemUptime
        let result = broker.captureSelectionViaCopy(pasteboard: board, expectedFrontmostPID: 123,
            timeout: 0.01, pollInterval: 0.001, frontmostPIDProvider: { 123 },
            secureInputProvider: { false }, postCopy: { true })
        XCTAssertEqual(result, .boardUnchanged)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
    }

}
