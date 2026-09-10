import AppKit
import ApplicationServices
import XCTest
@testable import ExpanderEngine

final class SelectionOwnershipRegressionTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func selection(_ text: String, token: UInt64 = 1) -> SelectionMonitor.CachedSelection {
        .init(text: text, bundleID: "com.apple.TextEdit", changeToken: token, timestamp: timestamp)
    }

    func testCacheRejectsFutureAndNonFiniteTimes() {
        let cached = selection("original")
        for time in [timestamp.addingTimeInterval(-1), Date(timeIntervalSince1970: -.infinity),
                     Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan)] {
            XCTAssertFalse(cached.isFresh(asOf: time), "An invalid age cannot authorize cached text")
        }
        for limit in [TimeInterval.infinity, .nan, -1] {
            XCTAssertFalse(cached.isFresh(asOf: timestamp, maxAge: limit))
        }
        XCTAssertTrue(cached.isFresh(asOf: timestamp, maxAge: 0))
        XCTAssertTrue(cached.isFresh(asOf: timestamp.addingTimeInterval(6), maxAge: 6))
        XCTAssertFalse(cached.isFresh(asOf: timestamp.addingTimeInterval(6.01), maxAge: 6))
    }

    func testReentrantConsumerCannotConsumeTheSameSelectionTwice() throws {
        var monitor: SelectionMonitor?
        defer { monitor = nil }
        var entered = false
        var inner: SelectionMonitor.CachedSelection?
        let environment = SelectionMonitor.Environment(
            isSecureInputActive: { false }, isOwnProcessFrontmost: { false }, isMuted: { _ in false },
            isTypedPathAllowed: { _ in
                if !entered {
                    entered = true
                    inner = monitor?.consumeSelection(asOf: self.timestamp,
                        rejectWeakAX: false, requireSameElement: false)
                }
                return true
            }
        )
        monitor = SelectionMonitor(environment: environment)
        let store = try XCTUnwrap(monitor)
        store.seedCacheForTesting(selection("once"))
        let outer = store.consumeSelection(asOf: timestamp, rejectWeakAX: false, requireSameElement: false)
        XCTAssertEqual(inner?.text, "once")
        XCTAssertNil(outer, "Only one caller may claim a published selection")
    }

    func testConsumptionCannotClearASelectionPublishedDuringValidation() throws {
        var monitor: SelectionMonitor?
        defer { monitor = nil }
        var replaced = false
        let newer = selection("new selection", token: 2)
        let environment = SelectionMonitor.Environment(
            isSecureInputActive: { false }, isOwnProcessFrontmost: { false }, isMuted: { _ in false },
            isTypedPathAllowed: { _ in
                if !replaced {
                    replaced = true
                    monitor?.seedCacheForTesting(newer)
                }
                return true
            }
        )
        monitor = SelectionMonitor(environment: environment)
        let store = try XCTUnwrap(monitor)
        store.seedCacheForTesting(selection("old selection"))
        XCTAssertNil(store.consumeSelection(asOf: timestamp, rejectWeakAX: false, requireSameElement: false))
        XCTAssertEqual(store.rawCachedSelection(), newer, "A stale consumer must preserve the newer selection")
    }

    func testCopyRejectsFocusLossAfterPostingWithoutRestoringOverTheNewOwner() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("original", forType: .string))
        var pid: pid_t = 42
        let result = PasteboardBroker().captureSelectionViaCopy(
            pasteboard: board, expectedFrontmostPID: 42, timeout: 0.05, pollInterval: 0.001,
            frontmostPIDProvider: { pid }, secureInputProvider: { false }, postCopy: {
                pid = 99
                board.clearContents()
                XCTAssertTrue(board.setString("another app's copy", forType: .string))
                return true
            })
        XCTAssertEqual(result, .sourceAppChanged)
        XCTAssertEqual(board.string(forType: .string), "another app's copy")
    }

    func testCopyRejectsSecureInputThatActivatesAfterPosting() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("original", forType: .string))
        var secure = false
        let result = PasteboardBroker().captureSelectionViaCopy(
            pasteboard: board, expectedFrontmostPID: 42, timeout: 0.05, pollInterval: 0.001,
            frontmostPIDProvider: { 42 }, secureInputProvider: { secure }, postCopy: {
                secure = true
                board.clearContents()
                XCTAssertTrue(board.setString("must not become AI input", forType: .string))
                return true
            })
        XCTAssertEqual(result, .secureInputActive)
    }

    func testCopyReportsFocusLossWhileWaitingForAnUnansweredCopy() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var posted = false
        var pid: pid_t = 42
        let broker = PasteboardBroker(now: {
            if posted { pid = 99 }
            return ProcessInfo.processInfo.systemUptime
        })
        let result = broker.captureSelectionViaCopy(
            pasteboard: board, expectedFrontmostPID: 42, timeout: 0.05, pollInterval: 0.001,
            frontmostPIDProvider: { pid }, secureInputProvider: { false },
            postCopy: { posted = true; return true })
        XCTAssertEqual(result, .sourceAppChanged)
    }

    func testLazyCopyReadRejectsEveryOwnershipAndOriginRace() {
        // Mutations occur inside the data-read boundary, not on a probabilistic timer.
        for stage in 0..<6 {
            var count = 10
            var failure: PasteboardBroker.CopyCaptureOutcome?
            var reads = 0
            if stage == 0 { count = 11 }
            if stage == 1 { failure = .sourceAppChanged }
            if stage == 2 { failure = .secureInputActive }
            let result = PasteboardBroker.readObservedCopy(
                expectedChangeCount: 10, currentChangeCount: { count },
                boundaryFailure: { failure }, readString: {
                    reads += 1
                    if stage == 3 { count = 11 }
                    if stage == 4 { failure = .sourceAppChanged }
                    if stage == 5 { failure = .secureInputActive }
                    return "untrusted candidate"
                })
            let expected: [PasteboardBroker.CopyCaptureOutcome] = [
                .clipboardChanged, .sourceAppChanged, .secureInputActive,
                .clipboardChanged, .sourceAppChanged, .secureInputActive
            ]
            XCTAssertEqual(result, expected[stage])
            XCTAssertEqual(reads, stage < 3 ? 0 : 1)
        }
    }

    func testStableCopyPreservesTextAndReportsMissingRepresentation() {
        for text in [String?.none, "", "  multi\nline 👨‍👩‍👧‍👦 العربية  "] {
            let result = PasteboardBroker.readObservedCopy(
                expectedChangeCount: 10, currentChangeCount: { 10 },
                boundaryFailure: { nil }, readString: { text })
            XCTAssertEqual(result, text.map(PasteboardBroker.CopyCaptureOutcome.captured) ?? .noStringOnBoard)
        }
    }

    func testConcurrentConsumersClaimExactlyOnceAcrossRepeatedPublications() {
        let store = SelectionMonitor(environment: .fixed())
        let resultLock = NSLock()
        for round in 0..<200 {
            store.seedCacheForTesting(selection("publication-\(round)", token: UInt64(round + 1)))
            var winners = 0
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                if let result = store.consumeSelection(asOf: timestamp, rejectWeakAX: false, requireSameElement: false) {
                    XCTAssertEqual(result.text, "publication-\(round)")
                    resultLock.lock()
                    winners += 1
                    resultLock.unlock()
                }
            }
            XCTAssertEqual(winners, 1, "Round \(round) must have one consumer")
        }
    }
}

final class SelectionRangeBoundaryRegressionTests: XCTestCase {
    func testExtremeAXRangeIsRefusedWithoutIntegerOverflow() {
        XCTAssertNil(SelectionReader.substring(of: "abc", utf16Range: CFRange(location: 1, length: Int.max)))
        XCTAssertNil(SelectionReader.substring(of: "abc", utf16Range: CFRange(location: Int.max, length: 1)))
        XCTAssertNil(SelectionReader.substring(of: "abc", utf16Range: CFRange(location: Int.min, length: Int.max)))
    }

    func testRangeBoundaryMatrixIncludesExtremeIntegersAndUnicode() {
        let inputs = ["", "abc", "😀x", "e\u{301}", "👨‍👩‍👧‍👦\nالعربية"]
        for input in inputs {
            let length = (input as NSString).length
            let boundaries = [Int.min, -1, 0, 1, length, length + 1, Int.max - 1, Int.max]
            for start in boundaries {
                for count in boundaries {
                    let result = SelectionReader.substring(of: input, utf16Range: CFRange(location: start, length: count))
                    let fits = start >= 0 && start <= length && count > 0 && count <= length - start
                    XCTAssertEqual(result != nil, fits)
                    if let result { XCTAssertEqual((result as NSString).length, count) }
                }
            }
        }
    }
}
