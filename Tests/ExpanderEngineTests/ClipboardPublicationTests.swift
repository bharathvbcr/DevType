import AppKit
import XCTest
@testable import ExpanderEngine

final class ClipboardPublicationTests: XCTestCase {
    func testEveryPublicationStepMustSucceed() {
        // Text plus three markers; image TIFF/PNG plus three markers.
        for stepCount in [4, 5] {
            for failure in 0..<stepCount {
                var count = 100
                var calls: [Int] = []
                let writes: [() -> Bool] = (0..<stepCount).map { index in {
                    calls.append(index)
                    return index != failure
                } }
                let result = PasteboardBroker.publishClipboard(
                    clearContents: { count += 1; return count },
                    currentChangeCount: { count }, writes: writes
                )
                XCTAssertEqual(result, .writeFailed(ownedChangeCount: 101))
                XCTAssertEqual(calls, Array(0...failure), "Nothing after a failed write may execute.")
            }
        }
    }

    func testExternalWriterAtEveryBoundaryIsNeverAdopted() {
        for stepCount in [4, 5] {
            for takeover in 0...stepCount {
                for writeSucceeds in [true, false] {
                    var count = 100
                    var calls = 0
                    let writes: [() -> Bool] = (0..<stepCount).map { index in {
                        calls += 1
                        if takeover == index + 1 { count += 1 }
                        return takeover == index + 1 ? writeSucceeds : true
                    } }
                    let result = PasteboardBroker.publishClipboard(
                        clearContents: {
                            count += 1
                            let owned = count
                            if takeover == 0 { count += 1 }
                            return owned
                        },
                        currentChangeCount: { count }, writes: writes
                    )
                    XCTAssertEqual(result, .ownershipLost)
                    XCTAssertEqual(calls, takeover)
                }
            }
        }
    }

    func testPreparedPublicationRetainsTheClearCount() {
        var count = 20
        let result = PasteboardBroker.publishClipboard(
            clearContents: { count += 1; return count },
            currentChangeCount: { count }, writes: [{ true }, { true }]
        )
        XCTAssertEqual(result, .published(ownedChangeCount: 21))
    }

    func testEmptyOrOversizedPublicationDoesNotClearClipboard() {
        for count in [0, 17] {
            let result = PasteboardBroker.publishClipboard(
                clearContents: { XCTFail("Unprepared publication must leave the clipboard intact."); return 0 },
                currentChangeCount: { 0 }, writes: Array(repeating: { true }, count: count)
            )
            XCTAssertEqual(result, .notPrepared)
        }
    }

    func testRestoreDoesNotOverwriteExternalCopyWithStandardMarkers() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let broker = PasteboardBroker()
        let generation = broker.beginRestoreGeneration()
        let owned = board.clearContents()
        XCTAssertTrue(board.setString("generated", forType: .string))
        let ticket = PasteboardBroker.ClipboardTicket(
            pasteboard: board, oldItems: [[.string: Data("original".utf8)]],
            generation: generation, targetChangeCount: owned
        )
        // Clipboard managers and password managers use these same public markers.
        board.clearContents()
        XCTAssertTrue(board.setString("external copy", forType: .string))
        XCTAssertTrue(board.setData(Data(), forType: PasteboardBroker.concealedType))
        broker.restore(ticket)
        XCTAssertEqual(board.string(forType: .string), "external copy")
    }
}
