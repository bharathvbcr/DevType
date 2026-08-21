import XCTest
@testable import ExpanderEngine

/// §3.1d delivery-input window: policy units, then two concurrency stresses.
///
/// The window's state lives behind `lastExpansionLock` and is written from three threads (tap
/// callback, processing queue, main). These tests cannot observe the private counters directly;
/// what they *can* prove is that the public surface survives a hostile interleaving without
/// deadlock, crash, or corruption of the operations it does expose — and that the pure unit
/// policy behind the wiring behaves for every input class.
final class DeliveryWindowStressTests: XCTestCase {

    // MARK: - Contamination unit policy

    func testFieldTouchingKeyCountsOneUnit() {
        XCTAssertEqual(TextInjectionPipeline.deliveryInputUnits(keyContaminates: true, flushReplayCount: 0), 1)
    }

    func testInertKeyAloneCountsNothing() {
        XCTAssertEqual(TextInjectionPipeline.deliveryInputUnits(keyContaminates: false, flushReplayCount: 0), 0)
    }

    /// The regression: an inert trigger (F-key keyDown) that still forces a flush must charge
    /// its replayed characters — uncounted, they broke the blind-undo premise invisibly.
    func testInertTriggerWithFlushedReplayCountsTheReplay() {
        XCTAssertEqual(TextInjectionPipeline.deliveryInputUnits(keyContaminates: false, flushReplayCount: 3), 3)
    }

    func testTouchingTriggerWithFlushCountsBoth() {
        XCTAssertEqual(TextInjectionPipeline.deliveryInputUnits(keyContaminates: true, flushReplayCount: 4), 5)
    }

    func testNegativeReplayCountIsClamped() {
        XCTAssertEqual(TextInjectionPipeline.deliveryInputUnits(keyContaminates: true, flushReplayCount: -2), 1)
    }

    /// Exhaustive-ish sweep: units are exactly `key + max(0, replay)` for every combination.
    func testUnitPolicyUnderFuzz() {
        var rng = SplitMix64(seed: 0xDE11A5)
        for _ in 0..<2000 {
            let key = rng.next() % 2 == 0
            let replay = Int(rng.next() % 20) - 4   // includes negatives
            XCTAssertEqual(
                TextInjectionPipeline.deliveryInputUnits(keyContaminates: key, flushReplayCount: replay),
                (key ? 1 : 0) + max(0, replay)
            )
        }
    }

    // MARK: - Decision.replayCount

    func testReplayCountExtractsFlushPayload() {
        let decision = TypeAheadBuffer.Decision.flushThenPassThrough(replay: "abc")
        XCTAssertEqual(decision.replayCount, 3)
        XCTAssertEqual(TypeAheadBuffer.Decision.swallow.replayCount, 0)
        XCTAssertEqual(TypeAheadBuffer.Decision.passThrough.replayCount, 0)
    }

    // MARK: - Concurrency: pipeline delivery-window surface

    /// Hammer the window/record APIs from eight threads. Nothing here can assert internal
    /// counters; what it proves is lock discipline — no deadlock, no crash, and the exposed
    /// record accessors stay consistent under churn. A run that trips either lock-order rule
    /// this codebase relies on hangs or traps here.
    func testDeliveryWindowAPIsSurviveConcurrentHammering() {
        let pipeline = TextInjectionPipeline()
        let queue = DispatchQueue(label: "stress", attributes: .concurrent)
        let group = DispatchGroup()

        for _ in 0..<8 {
            group.enter()
            queue.async {
                defer { group.leave() }
                for iteration in 0..<4000 {
                    pipeline.beginDeliveryWindow()
                    pipeline.noteDeliveryInput(units: 1)
                    pipeline.noteInputAfterExpansion(units: 1)
                    if iteration % 7 == 0 { pipeline.clearLastExpansion() }
                    if iteration % 11 == 0 { pipeline.clearLastExpansion(ifInjectedTextIs: "nope") }
                    _ = pipeline.lastExpansion
                    _ = pipeline.canUndoLastExpansion()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success, "hammer deadlocked or stalled")
    }

    // MARK: - Concurrency: DevLogMirror

    /// Concurrent polls (each fetching overlapping batches) racing direct merges. Final state
    /// must still hold every ring invariant: bounded, duplicate-free, arrival-ordered relative
    /// to everything that was fed.
    func testMirrorSurvivesConcurrentPollsAndMerges() {
        let capacity = 300
        let now = Date()
        let fedLock = NSLock()
        var fed: [DevLogMirror.Line] = []

        func makeBatch(seed: Int) -> [DevLogMirror.Line] {
            (0..<6).map { index in
                DevLogMirror.Line(
                    date: now.addingTimeInterval(-Double((seed + index) % 50)),
                    category: "Inject",
                    level: "info",
                    message: "stress-\((seed + index) % 40)"
                )
            }
        }

        let mirror = DevLogMirror(capacity: capacity) { since in
            let batch = makeBatch(seed: Int(since.timeIntervalSince1970) % 40)
            fedLock.lock()
            fed.append(contentsOf: batch)
            fedLock.unlock()
            return batch
        }

        let queue = DispatchQueue(label: "mirror-stress", attributes: .concurrent)
        let group = DispatchGroup()
        for thread in 0..<6 {
            group.enter()
            queue.async {
                defer { group.leave() }
                for iteration in 0..<300 {
                    if thread % 2 == 0 {
                        _ = mirror.poll(now: now.addingTimeInterval(Double(iteration)))
                    } else {
                        let batch = makeBatch(seed: iteration % 40)
                        fedLock.lock()
                        fed.append(contentsOf: batch)
                        fedLock.unlock()
                        _ = mirror.mergeLocked(batch)
                    }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success, "mirror stress deadlocked")

        let snapshot = mirror.storedLines
        XCTAssertLessThanOrEqual(snapshot.count, capacity)
        let identities = snapshot.map(\.identity)
        XCTAssertEqual(identities.count, Set(identities).count, "duplicate identities under concurrency")

        fedLock.lock()
        let allFed = fed
        fedLock.unlock()
        var cursor = allFed.startIndex
        for element in snapshot {
            guard let found = allFed[cursor...].firstIndex(of: element) else {
                return XCTFail("stored a line that was never fed, or arrival order broke")
            }
            cursor = allFed.index(after: found)
        }
    }
}
