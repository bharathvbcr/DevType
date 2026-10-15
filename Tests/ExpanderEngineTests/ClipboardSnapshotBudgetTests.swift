import AppKit
import XCTest
@testable import ExpanderEngine

/// Bounded clipboard snapshots must not materialize representations that cannot be restored:
/// promised types, a TIFF beside a compressed image, and every type after the byte budget is spent.
final class ClipboardSnapshotBudgetTests: XCTestCase {
    private let jpeg = NSPasteboard.PasteboardType("public.jpeg")
    private let gif = NSPasteboard.PasteboardType("public.gif")
    private let legacyTIFF = NSPasteboard.PasteboardType("NeXT TIFF v4.0 pasteboard type")

    func testTIFFBesidePNGIsNotRead() {
        var reads: [NSPasteboard.PasteboardType] = []
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[.tiff, .png]],
            budget: 32,
            read: { _, type in
                reads.append(type)
                return type == .png ? png : Data([0x49, 0x49, 0x2A, 0x00])
            }
        )
        XCTAssertEqual(reads, [.png])
        XCTAssertEqual(snapshot, [[.png: png]])
        XCTAssertFalse(snapshot.contains { $0.keys.contains(.tiff) })
    }

    func testTIFFBesideJPEGOrGIFIsNotRead() {
        for compressed in [jpeg, gif] {
            var reads: [NSPasteboard.PasteboardType] = []
            let payload = Data([0x01, 0x02])
            let snapshot = PasteboardBroker.snapshotRepresentations(
                itemTypes: [[.tiff, compressed]],
                budget: 16,
                read: { _, type in
                    reads.append(type)
                    return payload
                }
            )
            XCTAssertEqual(reads, [compressed], "TIFF next to \(compressed.rawValue) must not be read")
            XCTAssertEqual(snapshot, [[compressed: payload]])
            XCTAssertFalse(snapshot.contains { $0.keys.contains(.tiff) })
        }
    }

    func testTIFFOnlyItemIsReadAndStored() {
        var reads: [NSPasteboard.PasteboardType] = []
        let tiff = Data([0x4D, 0x4D, 0x00, 0x2A])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[.tiff]],
            budget: 16,
            read: { _, type in
                reads.append(type)
                return tiff
            }
        )
        XCTAssertEqual(reads, [.tiff])
        XCTAssertEqual(snapshot, [[.tiff: tiff]])
    }

    func testLegacyTIFFBesidePNGIsNotRead() {
        var reads: [NSPasteboard.PasteboardType] = []
        let png = Data([0x89, 0x50])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[legacyTIFF, .png]],
            budget: 16,
            read: { _, type in
                reads.append(type)
                return png
            }
        )
        XCTAssertEqual(reads, [.png])
        XCTAssertFalse(snapshot.contains { $0.keys.contains(legacyTIFF) })
        XCTAssertEqual(snapshot, [[.png: png]])
    }

    func testPromisedTypeIsNotReadWhileNormalTypeIs() {
        let promised = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url")
        XCTAssertTrue(PasteboardBroker.snapshotSkippedTypes.contains(promised.rawValue))
        var reads: [NSPasteboard.PasteboardType] = []
        let text = Data("kept".utf8)
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[promised, .string]],
            budget: 16,
            read: { _, type in
                reads.append(type)
                return text
            }
        )
        XCTAssertEqual(reads, [.string])
        XCTAssertEqual(snapshot, [[.string: text]])
    }

    func testTypeThatFillsTheBudgetIsStoredAndTheNextTypeIsNotRead() {
        let first = NSPasteboard.PasteboardType("devtype.test.fill")
        let second = NSPasteboard.PasteboardType("devtype.test.next")
        var reads: [NSPasteboard.PasteboardType] = []
        let payload = Data(repeating: 0xAB, count: 4)
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[first, second]],
            budget: 4,
            read: { _, type in
                reads.append(type)
                return payload
            }
        )
        XCTAssertEqual(reads, [first])
        XCTAssertEqual(snapshot, [[first: payload]])
        XCTAssertNil(snapshot.first?[second])
    }

    func testOverBudgetTypeIsReadOnceAndDoesNotConsumeBudget() {
        let big = NSPasteboard.PasteboardType("devtype.test.big")
        let small = NSPasteboard.PasteboardType("devtype.test.small")
        var reads: [NSPasteboard.PasteboardType] = []
        let smallPayload = Data(repeating: 0x11, count: 4)
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[big, small]],
            budget: 4,
            read: { _, type in
                reads.append(type)
                return type == big ? Data(repeating: 0x22, count: 5) : smallPayload
            }
        )
        XCTAssertEqual(reads, [big, small])
        XCTAssertEqual(snapshot, [[small: smallPayload]])
        XCTAssertNil(snapshot.first?[big])
        XCTAssertLessThanOrEqual(storedBytes(snapshot), 4)
    }

    func testExhaustedBudgetSkipsLaterTypesOnTheNextItem() {
        let first = NSPasteboard.PasteboardType("devtype.test.item0")
        let later = NSPasteboard.PasteboardType("devtype.test.item0.later")
        let next = NSPasteboard.PasteboardType("devtype.test.item1")
        var reads: [(Int, NSPasteboard.PasteboardType)] = []
        let payload = Data(repeating: 0x7F, count: 3)
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[first, later], [next]],
            budget: 3,
            read: { index, type in
                reads.append((index, type))
                return payload
            }
        )
        XCTAssertEqual(reads.map(\.0), [0])
        XCTAssertEqual(reads.map(\.1), [first])
        XCTAssertEqual(snapshot, [[first: payload]])
        XCTAssertLessThanOrEqual(storedBytes(snapshot), 3)
    }

    func testNilDataDoesNotConsumeBudgetOrBlockTheNextType() {
        let missing = NSPasteboard.PasteboardType("devtype.test.missing")
        let present = NSPasteboard.PasteboardType("devtype.test.present")
        var reads: [NSPasteboard.PasteboardType] = []
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[missing, present]],
            budget: payload.count,
            read: { _, type in
                reads.append(type)
                return type == missing ? nil : payload
            }
        )
        XCTAssertEqual(reads, [missing, present])
        XCTAssertEqual(snapshot, [[present: payload]])
    }

    func testItemsPastMaxItemsAreNotRead() {
        var seenAtDefaultCap = Set<Int>()
        let nine: [[NSPasteboard.PasteboardType]] = (0..<9).map { _ in [.string] }
        let capped = PasteboardBroker.snapshotRepresentations(
            itemTypes: nine,
            budget: 64,
            maxItems: 8,
            read: { index, _ in
                seenAtDefaultCap.insert(index)
                return Data([UInt8(index)])
            }
        )
        XCTAssertFalse(seenAtDefaultCap.contains(8))
        XCTAssertEqual(capped.count, 8)
        XCTAssertEqual(Set(seenAtDefaultCap), Set(0..<8))

        var seenAtTwo = Set<Int>()
        _ = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[.string], [.string], [.png]],
            budget: 32,
            maxItems: 2,
            read: { index, _ in
                seenAtTwo.insert(index)
                return Data([0x01])
            }
        )
        XCTAssertEqual(seenAtTwo, [0, 1])
    }

    func testStoredBytesNeverExceedTheBudget() {
        let budget = 10
        let types = (0..<4).map { NSPasteboard.PasteboardType("devtype.test.size.\($0)") }
        let sizes = [6, 6, 4, 3]
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [types],
            budget: budget,
            read: { _, type in
                let index = types.firstIndex(of: type)!
                return Data(repeating: 0x05, count: sizes[index])
            }
        )
        XCTAssertEqual(storedBytes(snapshot), 10)
        XCTAssertLessThanOrEqual(storedBytes(snapshot), budget)
        XCTAssertEqual(snapshot.first?[types[0]]?.count, 6)
        XCTAssertNil(snapshot.first?[types[1]])
        XCTAssertEqual(snapshot.first?[types[2]]?.count, 4)
        XCTAssertNil(snapshot.first?[types[3]])
    }

    func testNamedBoardSnapshotKeepsPNGAndDropsTIFF() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let pixels = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        let png = try XCTUnwrap(pixels.representation(using: .png, properties: [:]))
        let tiff = try XCTUnwrap(pixels.representation(using: .tiff, properties: [:]))
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(png, forType: .png))
        XCTAssertTrue(item.setData(tiff, forType: .tiff))
        XCTAssertTrue(board.writeObjects([item]))
        let written = try XCTUnwrap(board.pasteboardItems?.first)
        XCTAssertTrue(written.types.contains(.png))
        XCTAssertTrue(written.types.contains(.tiff))

        let snapshot = try XCTUnwrap(PasteboardBroker.snapshotPasteboard(board))
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0][.png], png)
        XCTAssertFalse(snapshot[0].keys.contains(.tiff))
        XCTAssertFalse(snapshot[0].keys.contains(legacyTIFF))
        XCTAssertLessThanOrEqual(storedBytes(snapshot), PasteboardBroker.snapshotMaxBytes)
    }

    private func storedBytes(_ snapshot: PasteboardBroker.PasteboardSnapshot) -> Int {
        snapshot.reduce(0) { total, item in
            total + item.values.reduce(0) { $0 + $1.count }
        }
    }
}
