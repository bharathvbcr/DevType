import ExpanderEngine
import Foundation
import XCTest
@testable import DevTypeAppCore

private actor CorrectionDiffSuspensionGate {
    private var entered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class CorrectionDiffAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var latestAttempt: UInt64
    private var requestedGenerations: [SessionGeneration] = []

    init(latestAttempt: UInt64) {
        self.latestAttempt = latestAttempt
    }

    func supersede(with attempt: UInt64) {
        lock.lock()
        latestAttempt = attempt
        lock.unlock()
    }

    func isLatest(_ attempt: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestAttempt == attempt
    }

    func recordLookup(_ generation: SessionGeneration) {
        lock.lock()
        requestedGenerations.append(generation)
        lock.unlock()
    }

    var lookups: [SessionGeneration] {
        lock.lock()
        defer { lock.unlock() }
        return requestedGenerations
    }
}

final class VoiceCorrectionDiffRaceTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The terminal callback is attempt-scoped, but its nested correction-diff task crosses an
    /// actor hop. Keep this wiring assertion alongside the behavioral race below so a future
    /// refactor cannot silently return to the unscoped `transcripts()` accessor.
    func testControllerCarriesAttemptThroughGenerationScopedTranscriptLookup() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(
                "Sources/DevTypeAppCore/VoiceDictationController.swift"
            ),
            encoding: .utf8
        )
        let coordinatorSource = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(
                "Sources/ExpanderEngine/Voice/Session/VoiceSessionCoordinator.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("showCorrectionDiff(for: text, attempt: attempt)"))
        XCTAssertTrue(source.contains(
            "private func showCorrectionDiff(for finalText: String, attempt: UInt64)"
        ))
        XCTAssertTrue(source.contains("transcripts(for: generation)"))
        XCTAssertTrue(coordinatorSource.contains("for generation: SessionGeneration"))
        XCTAssertTrue(coordinatorSource.contains("state.snapshot.generation == generation"))
    }

    /// Reproduces the original ordering without a real microphone or HUD: the old request enters
    /// its transcript actor hop, attempt two begins, and the old lookup then resumes with a valid
    /// generation-one result. The post-await freshness check must still discard that result.
    func testSupersededRequestCannotPrepareDiffForNewerHUD() async {
        let state = CorrectionDiffAttemptState(latestAttempt: 1)
        let gate = CorrectionDiffSuspensionGate()
        let request = VoiceCorrectionDiffRequest(
            attempt: 1,
            finalText: "ship the release"
        )

        let task = Task {
            await request.prepare(
                transcriptLookup: { generation in
                    state.recordLookup(generation)
                    await gate.enterAndWait()
                    return (
                        raw: "please ship the release",
                        final: "ship the release"
                    )
                },
                isLatestAttempt: { state.isLatest($0) }
            )
        }

        await gate.waitUntilEntered()
        state.supersede(with: 2)
        await gate.open()

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(state.lookups, [SessionGeneration(rawValue: 1)])
    }

    func testCurrentRequestProducesCutSegmentsFromItsOwnGeneration() async throws {
        let state = CorrectionDiffAttemptState(latestAttempt: 7)
        let request = VoiceCorrectionDiffRequest(
            attempt: 7,
            finalText: "ship the release"
        )

        let segments = await request.prepare(
            transcriptLookup: { generation in
                state.recordLookup(generation)
                return (
                    raw: "please ship the release",
                    final: "ship the release"
                )
            },
            isLatestAttempt: { state.isLatest($0) }
        )

        let result = try XCTUnwrap(segments)
        XCTAssertTrue(result.contains(where: { $0.isCut && $0.text == "please" }))
        XCTAssertEqual(state.lookups, [SessionGeneration(rawValue: 7)])
    }
}
