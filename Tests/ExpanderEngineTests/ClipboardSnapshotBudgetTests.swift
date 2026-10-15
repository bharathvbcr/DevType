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

    func testSnapshotConstantsStayLocked() {
        XCTAssertEqual(PasteboardBroker.snapshotMaxBytes, 4 * 1024 * 1024)
        XCTAssertEqual(PasteboardBroker.snapshotMaxItems, 8)
        XCTAssertEqual(
            PasteboardBroker.snapshotSkippedTypes,
            [
                "com.apple.pasteboard.promised-file-content-type",
                "com.apple.pasteboard.promised-file-url",
                "com.apple.pasteboard.promised-suggested-file-name",
                "com.apple.pasteboard.PasteboardName",
                "NSPromiseContentsPboardType",
            ]
        )
    }

    func testEverySkippedTypeIsNotRead() {
        let skipped = PasteboardBroker.snapshotSkippedTypes.sorted().map {
            NSPasteboard.PasteboardType($0)
        }
        let kept = NSPasteboard.PasteboardType("devtype.test.kept-beside-promises")
        let payload = Data([0x10])
        var reads: [NSPasteboard.PasteboardType] = []
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [skipped + [kept]],
            budget: 8,
            read: { _, type in
                reads.append(type)
                return payload
            }
        )
        XCTAssertEqual(skipped.count, 5)
        XCTAssertEqual(reads, [kept])
        XCTAssertEqual(snapshot, [[kept: payload]])
    }

    func testNearMissSkippedNamesAreStillRead() {
        let near = [
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url "),
            NSPasteboard.PasteboardType("nspromisecontentspboardtype"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.PasteboardName.extra"),
            NSPasteboard.PasteboardType("NSPromiseContentsPboardType "),
        ]
        for type in near {
            XCTAssertFalse(PasteboardBroker.snapshotSkippedTypes.contains(type.rawValue))
        }
        var reads: [NSPasteboard.PasteboardType] = []
        let payload = Data([0x21])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [near],
            budget: 16,
            read: { _, type in
                reads.append(type)
                return payload
            }
        )
        XCTAssertEqual(reads, near)
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot[0].count, near.count)
    }

    func testZeroAndNegativeBudgetsReadNothing() {
        for budget in [0, -1] {
            var reads = 0
            let snapshot = PasteboardBroker.snapshotRepresentations(
                itemTypes: [[.string, .png], [.tiff]],
                budget: budget,
                read: { _, _ in
                    reads += 1
                    return Data([0x01])
                }
            )
            XCTAssertEqual(reads, 0, "budget \(budget) must not read")
            XCTAssertEqual(snapshot, [])
        }
    }

    func testTwoOverBudgetReadsThenAFittingType() {
        let first = NSPasteboard.PasteboardType("devtype.test.over.a")
        let second = NSPasteboard.PasteboardType("devtype.test.over.b")
        let fit = NSPasteboard.PasteboardType("devtype.test.over.fit")
        var reads: [NSPasteboard.PasteboardType] = []
        let fitPayload = Data(repeating: 0x03, count: 3)
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[first, second, fit]],
            budget: 4,
            read: { _, type in
                reads.append(type)
                return type == fit ? fitPayload : Data(repeating: 0x09, count: 5)
            }
        )
        XCTAssertEqual(reads, [first, second, fit])
        XCTAssertEqual(reads.filter { $0 == first }.count, 1)
        XCTAssertEqual(reads.filter { $0 == second }.count, 1)
        XCTAssertEqual(snapshot, [[fit: fitPayload]])
        XCTAssertLessThanOrEqual(storedBytes(snapshot), 4)
    }

    func testLaterItemOverBudgetTypeIsReadOnceThenASmallerTypeIsStored() {
        let head = NSPasteboard.PasteboardType("devtype.test.partial.head")
        let over = NSPasteboard.PasteboardType("devtype.test.partial.over")
        let small = NSPasteboard.PasteboardType("devtype.test.partial.small")
        var reads: [(Int, NSPasteboard.PasteboardType)] = []
        let headPayload = Data(repeating: 0x11, count: 6)
        let smallPayload = Data(repeating: 0x22, count: 3)
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[head], [over, small]],
            budget: 10,
            read: { index, type in
                reads.append((index, type))
                if type == head { return headPayload }
                if type == over { return Data(repeating: 0x33, count: 5) }
                return smallPayload
            }
        )
        XCTAssertEqual(reads.map(\.0), [0, 1, 1])
        XCTAssertEqual(reads.map(\.1), [head, over, small])
        XCTAssertEqual(reads.filter { $0.1 == over }.count, 1)
        XCTAssertEqual(snapshot, [[head: headPayload], [small: smallPayload]])
        XCTAssertNil(snapshot.last?[over])
        XCTAssertLessThanOrEqual(storedBytes(snapshot), 10)
    }

    func testNilOnlyItemIsOmittedAndTheFollowingItemIsKept() {
        let missing = NSPasteboard.PasteboardType("devtype.test.nil.item")
        let kept = NSPasteboard.PasteboardType("devtype.test.kept.item")
        var reads: [Int] = []
        let payload = Data([0x07, 0x08])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[missing], [kept]],
            budget: 8,
            read: { index, _ in
                reads.append(index)
                return index == 0 ? nil : payload
            }
        )
        XCTAssertEqual(reads, [0, 1])
        XCTAssertEqual(snapshot, [[kept: payload]])
    }

    func testEmptyItemTypesReturnsAnEmptySnapshot() {
        var reads = 0
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [],
            budget: 8,
            read: { _, _ in
                reads += 1
                return Data([0x01])
            }
        )
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(snapshot, [])
    }

    func testSkippedOnlyItemIsOmittedAndDoesNotBlockTheNextItem() {
        let promised = NSPasteboard.PasteboardType("NSPromiseContentsPboardType")
        var reads: [NSPasteboard.PasteboardType] = []
        let payload = Data("ok".utf8)
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[promised], [.string]],
            budget: 8,
            read: { _, type in
                reads.append(type)
                return payload
            }
        )
        XCTAssertEqual(reads, [.string])
        XCTAssertEqual(snapshot, [[.string: payload]])
    }

    func testMaxItemsCountsLeadingSkippedItems() {
        let promised = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
        var reads = 0
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[promised], [.string]],
            budget: 16,
            maxItems: 1,
            read: { _, _ in
                reads += 1
                return Data([0x01])
            }
        )
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(snapshot, [])
    }

    func testMaxItemsZeroReadsNothing() {
        var reads = 0
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[.string], [.png], [.tiff]],
            budget: 32,
            maxItems: 0,
            read: { _, _ in
                reads += 1
                return Data([0x01])
            }
        )
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(snapshot, [])
    }

    func testEmptyDataIsStoredWithoutReducingTheBudget() {
        let empty = NSPasteboard.PasteboardType("devtype.test.empty")
        let later = NSPasteboard.PasteboardType("devtype.test.after.empty")
        var reads: [NSPasteboard.PasteboardType] = []
        let laterPayload = Data([0x01, 0x02, 0x03])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[empty, later]],
            budget: 3,
            read: { _, type in
                reads.append(type)
                return type == empty ? Data() : laterPayload
            }
        )
        XCTAssertEqual(reads, [empty, later])
        XCTAssertEqual(snapshot, [[empty: Data(), later: laterPayload]])
        XCTAssertEqual(storedBytes(snapshot), laterPayload.count)
    }

    func testZeroLengthTypeAfterTheBudgetIsSpentIsNotRead() {
        let fill = NSPasteboard.PasteboardType("devtype.test.fill.exact")
        let empty = NSPasteboard.PasteboardType("devtype.test.empty.after")
        var reads: [NSPasteboard.PasteboardType] = []
        let payload = Data([0x0A, 0x0B])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[fill, empty]],
            budget: payload.count,
            read: { _, type in
                reads.append(type)
                return type == fill ? payload : Data()
            }
        )
        XCTAssertEqual(reads, [fill])
        XCTAssertEqual(snapshot, [[fill: payload]])
    }

    func testTIFFBesidePublicJPEGIsReadBecauseTheMatchIsExact() {
        let notJPEG = NSPasteboard.PasteboardType("public.JPEG")
        XCTAssertNotEqual(notJPEG, jpeg)
        var reads: [NSPasteboard.PasteboardType] = []
        let tiff = Data([0x4D, 0x4D])
        let other = Data([0xFF, 0xD8])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[.tiff, notJPEG]],
            budget: 16,
            read: { _, type in
                reads.append(type)
                return type == .tiff ? tiff : other
            }
        )
        XCTAssertEqual(reads, [.tiff, notJPEG])
        XCTAssertEqual(snapshot, [[.tiff: tiff, notJPEG: other]])
    }

    func testNearMissLegacyTIFFBesidePNGIsRead() {
        let near = NSPasteboard.PasteboardType("NeXT TIFF v4.0 pasteboard type ")
        XCTAssertNotEqual(near, legacyTIFF)
        var reads: [NSPasteboard.PasteboardType] = []
        let payload = Data([0x01, 0x02])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[near, .png]],
            budget: 16,
            read: { _, type in
                reads.append(type)
                return payload
            }
        )
        XCTAssertEqual(reads, [near, .png])
        XCTAssertEqual(snapshot[0][near], payload)
        XCTAssertEqual(snapshot[0][.png], payload)
    }

    func testTIFFAndPNGOnDifferentItemsAreBothRead() {
        var reads: [(Int, NSPasteboard.PasteboardType)] = []
        let tiff = Data([0x49, 0x49])
        let png = Data([0x89, 0x50])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[.tiff], [.png]],
            budget: 16,
            read: { index, type in
                reads.append((index, type))
                return type == .tiff ? tiff : png
            }
        )
        XCTAssertEqual(reads.map(\.0), [0, 1])
        XCTAssertEqual(reads.map(\.1), [.tiff, .png])
        XCTAssertEqual(snapshot, [[.tiff: tiff], [.png: png]])
    }

    func testLegacyTIFFBesideGIFIsNotRead() {
        for types in [[legacyTIFF, gif], [gif, legacyTIFF]] {
            var reads: [NSPasteboard.PasteboardType] = []
            let payload = Data([0x47, 0x49])
            let snapshot = PasteboardBroker.snapshotRepresentations(
                itemTypes: [types],
                budget: 16,
                read: { _, type in
                    reads.append(type)
                    return payload
                }
            )
            XCTAssertEqual(reads, [gif], "order \(types.map(\.rawValue))")
            XCTAssertEqual(snapshot, [[gif: payload]])
            XCTAssertFalse(snapshot.contains { $0.keys.contains(legacyTIFF) })
        }
    }

    func testLegacyTIFFOnlyItemIsRead() {
        var reads: [NSPasteboard.PasteboardType] = []
        let payload = Data([0x4D, 0x4D, 0x00])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[legacyTIFF]],
            budget: 16,
            read: { _, type in
                reads.append(type)
                return payload
            }
        )
        XCTAssertEqual(reads, [legacyTIFF])
        XCTAssertEqual(snapshot, [[legacyTIFF: payload]])
    }

    func testTIFFListedAfterPNGIsNotRead() {
        var reads: [NSPasteboard.PasteboardType] = []
        let png = Data([0x89, 0x50, 0x4E])
        let snapshot = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[.png, .tiff]],
            budget: 16,
            read: { _, type in
                reads.append(type)
                return png
            }
        )
        XCTAssertEqual(reads, [.png])
        XCTAssertEqual(snapshot, [[.png: png]])
        XCTAssertFalse(snapshot.contains { $0.keys.contains(.tiff) })
    }

    func testNilPNGStillSkipsTIFFOnTheSameItem() {
        let orders: [[NSPasteboard.PasteboardType]] = [[.png, .tiff], [.tiff, .png]]
        for types in orders {
            var reads: [NSPasteboard.PasteboardType] = []
            let snapshot = PasteboardBroker.snapshotRepresentations(
                itemTypes: [types],
                budget: 16,
                read: { _, type in
                    reads.append(type)
                    return nil
                }
            )
            XCTAssertEqual(reads, [.png], "order \(types.map(\.rawValue))")
            XCTAssertEqual(snapshot, [])
        }
    }

    func testSequentialCallsDoNotShareRemainingBudget() {
        let fill = NSPasteboard.PasteboardType("devtype.test.seq.fill")
        let later = NSPasteboard.PasteboardType("devtype.test.seq.later")
        let payload = Data(repeating: 0x44, count: 3)
        var firstReads: [NSPasteboard.PasteboardType] = []
        let first = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[fill, later]],
            budget: 3,
            read: { _, type in
                firstReads.append(type)
                return payload
            }
        )
        var secondReads: [NSPasteboard.PasteboardType] = []
        let second = PasteboardBroker.snapshotRepresentations(
            itemTypes: [[fill, later]],
            budget: 6,
            read: { _, type in
                secondReads.append(type)
                return payload
            }
        )
        XCTAssertEqual(firstReads, [fill])
        XCTAssertEqual(first, [[fill: payload]])
        XCTAssertEqual(secondReads, [fill, later])
        XCTAssertEqual(second, [[fill: payload, later: payload]])
        XCTAssertLessThanOrEqual(storedBytes(second), 6)
    }

    func testConcurrentCallsWithDifferentBudgetsDoNotCrossResults() {
        let wide = NSPasteboard.PasteboardType("devtype.test.concurrent.wide")
        let narrow = NSPasteboard.PasteboardType("devtype.test.concurrent.narrow")
        let widePayload = Data(repeating: 0xA1, count: 4)
        let narrowPayload = Data(repeating: 0xB2, count: 2)
        let iterations = 16
        let group = DispatchGroup()
        let lock = NSLock()
        var wideResults: [PasteboardBroker.PasteboardSnapshot] = []
        var narrowResults: [PasteboardBroker.PasteboardSnapshot] = []
        wideResults.reserveCapacity(iterations)
        narrowResults.reserveCapacity(iterations)
        let queueA = DispatchQueue(label: "devtype.snapshot.budget.a")
        let queueB = DispatchQueue(label: "devtype.snapshot.budget.b")

        for _ in 0..<iterations {
            group.enter()
            queueA.async {
                let snapshot = PasteboardBroker.snapshotRepresentations(
                    itemTypes: [[wide, narrow]],
                    budget: 4,
                    read: { _, type in type == wide ? widePayload : narrowPayload }
                )
                lock.lock()
                wideResults.append(snapshot)
                lock.unlock()
                group.leave()
            }
            group.enter()
            queueB.async {
                let snapshot = PasteboardBroker.snapshotRepresentations(
                    itemTypes: [[wide, narrow]],
                    budget: 2,
                    read: { _, type in type == wide ? widePayload : narrowPayload }
                )
                lock.lock()
                narrowResults.append(snapshot)
                lock.unlock()
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(wideResults.count, iterations)
        XCTAssertEqual(narrowResults.count, iterations)
        for snapshot in wideResults {
            XCTAssertEqual(snapshot, [[wide: widePayload]])
            XCTAssertLessThanOrEqual(storedBytes(snapshot), 4)
        }
        for snapshot in narrowResults {
            XCTAssertEqual(snapshot, [[narrow: narrowPayload]])
            XCTAssertLessThanOrEqual(storedBytes(snapshot), 2)
        }
    }

    private func storedBytes(_ snapshot: PasteboardBroker.PasteboardSnapshot) -> Int {
        snapshot.reduce(0) { total, item in
            total + item.values.reduce(0) { $0 + $1.count }
        }
    }
}
