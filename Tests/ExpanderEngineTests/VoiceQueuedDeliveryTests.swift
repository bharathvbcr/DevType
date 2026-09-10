import XCTest
@testable import ExpanderEngine

final class VoiceQueuedDeliveryTests: XCTestCase {
    func testCancellationHandlersCanReadSessionStateWithoutDeadlocking() async {
        let bag = SessionTaskBag(sessionID: VoiceSessionID())
        let generation = bag.generation
        let entered = expectation(description: "task installed cancellation handler")
        let cancelled = expectation(description: "handler read retired state")
        let retired = expectation(description: "retirement completed")
        let task = Task {
            await withTaskCancellationHandler {
                entered.fulfill()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            } onCancel: {
                XCTAssertFalse(bag.isCurrentGeneration(generation))
                cancelled.fulfill()
            }
        }
        _ = bag.add(task)
        await fulfillment(of: [entered], timeout: 1)
        DispatchQueue.global().async {
            _ = bag.advanceGenerationAndCancelAll()
            retired.fulfill()
        }
        await fulfillment(of: [cancelled, retired], timeout: 1)
    }

    func testConcurrentGenerationReadsAndRetirement() {
        let bag = SessionTaskBag(sessionID: VoiceSessionID())
        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            if index.isMultiple(of: 2) { _ = bag.advanceGenerationAndCancelAll() }
            else { XCTAssertGreaterThan(bag.generation.rawValue, 0) }
        }
        XCTAssertEqual(bag.generation, SessionGeneration(rawValue: 5_001))
    }

    func testInjectionContinuationUsesTheCapturedSessionAtEveryPostingBoundary() {
        let bag = SessionTaskBag(sessionID: VoiceSessionID())
        let generation = bag.generation
        let operation = InjectCompletionGuard(shouldContinue: { bag.isCurrentGeneration(generation) })
        XCTAssertTrue(operation.allowsContinuation())
        _ = bag.advanceGenerationAndCancelAll()
        XCTAssertFalse(operation.allowsContinuation())
        XCTAssertFalse(operation.allowsContinuation(observationOnly: true))
    }

    func testBusyMainQueueCannotRetainUnboundedProviderPayloads() async {
        await MainActor.run {
            let bag = SessionTaskBag(sessionID: VoiceSessionID())
            let generation = bag.generation
            var accepted = 0
            for index in 0..<100 {
                if VoiceSessionCoordinator.enqueueLiveSegment(
                    SpeechSegment(segmentID: "\(index)", text: String(repeating: "x", count: 131_072)),
                    generation: generation, bag: bag, apply: { _ in }
                ) { accepted += 1 }
            }
            XCTAssertEqual(accepted, 7, "Pending text plus IDs must fit the 1 MiB delivery budget")
            _ = bag.advanceGenerationAndCancelAll()
        }
    }

    @MainActor private final class Received {
        var texts: [String] = []
    }

    func testCancellationWhileMainIsBusyDiscardsQueuedSegmentsAndPreservesNewSessionFIFO() async {
        let received = await MainActor.run { Received() }
        await MainActor.run {
            let old = SessionTaskBag(sessionID: VoiceSessionID())
            let new = SessionTaskBag(sessionID: VoiceSessionID())
            // Both bags may start at generation 1: identity is the captured bag, not a
            // comparison against a mutable coordinator's replacement generation.
            for index in 0..<2_000 {
                VoiceSessionCoordinator.enqueueLiveSegment(
                    SpeechSegment(segmentID: "old-\(index)", text: "old"),
                    generation: old.generation, bag: old
                ) { received.texts.append($0.text) }
            }
            _ = old.advanceGenerationAndCancelAll()
            for index in 0..<2_000 {
                VoiceSessionCoordinator.enqueueLiveSegment(
                    SpeechSegment(segmentID: "new-\(index)", text: "\(index)"),
                    generation: new.generation, bag: new
                ) { received.texts.append($0.text) }
            }
        }
        // A FIFO sentinel joins every queued callback; no scheduler sleeps or HID access.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let texts = await MainActor.run { received.texts }
        XCTAssertEqual(texts.count, 2_000)
        XCTAssertFalse(texts.contains("old"))
        XCTAssertEqual(texts.suffix(2_000), (0..<2_000).map(String.init)[...])
    }
}
