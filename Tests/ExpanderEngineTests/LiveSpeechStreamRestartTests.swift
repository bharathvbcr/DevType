import AVFoundation
import Foundation
import XCTest
@testable import ExpanderEngine

/// The live preview must survive a pause. A silence-timeout task ends with no text after living
/// for a while; only an immediate-error loop (tasks that die at once) may make the stream give up.
final class LiveSpeechStreamRestartTests: XCTestCase {
    private struct SilenceTimeout: Error {}

    private func makeStream(
        harness: Harness,
        segments: SegmentSink = SegmentSink()
    ) -> LiveSpeechStream {
        LiveSpeechStream(
            runtime: harness.runtime,
            clock: { [harness] in harness.now },
            onSegment: { segments.append($0) },
            onFailure: { _ in }
        )
    }

    func testEmptyEndingsThatLivedLongAreSilenceEndpointsAndNeverStopThePreview() {
        let harness = Harness()
        let stream = makeStream(harness: harness)
        let endings = LiveSpeechStream.maxConsecutiveEmptyRestarts + 4

        for _ in 0..<endings {
            harness.advance(by: 3)
            harness.endCurrentTask(with: SilenceTimeout())
        }

        XCTAssertEqual(
            harness.startCount, 1 + endings,
            "every silence endpoint must be followed by a fresh task"
        )
        stream.cancel()
    }

    func testEmptyEndingsThatDieImmediatelyStillGiveUp() {
        let harness = Harness()
        let stream = makeStream(harness: harness)

        for _ in 0..<(LiveSpeechStream.maxConsecutiveEmptyRestarts + 4) {
            harness.advance(by: 0.01)
            harness.endCurrentTask(with: SilenceTimeout())
        }

        XCTAssertEqual(
            harness.startCount, LiveSpeechStream.maxConsecutiveEmptyRestarts,
            "an immediate-error loop must stop after the cap, as it always did"
        )
        stream.cancel()
    }

    func testALongEmptyTaskBreaksARunOfImmediateFailures() {
        let harness = Harness()
        let stream = makeStream(harness: harness)
        let cap = LiveSpeechStream.maxConsecutiveEmptyRestarts

        for _ in 0..<(cap - 1) {
            harness.advance(by: 0.01)
            harness.endCurrentTask(with: SilenceTimeout())
        }
        harness.advance(by: 30)
        harness.endCurrentTask(with: SilenceTimeout())   // proves the recognizer is alive
        for _ in 0..<(cap - 1) {
            harness.advance(by: 0.01)
            harness.endCurrentTask(with: SilenceTimeout())
        }

        XCTAssertEqual(harness.startCount, 1 + 2 * (cap - 1) + 1, "the run restarts after a long task")
        stream.cancel()
    }

    func testTheBoundaryIsTheNamedConstant() {
        let harness = Harness()
        let stream = makeStream(harness: harness)
        let threshold = LiveSpeechStream.minimumProductiveTaskLifetimeSeconds

        // Just under the threshold counts; at the threshold does not.
        for _ in 0..<LiveSpeechStream.maxConsecutiveEmptyRestarts {
            harness.advance(by: threshold - 0.001)
            harness.endCurrentTask(with: SilenceTimeout())
        }
        XCTAssertEqual(harness.startCount, LiveSpeechStream.maxConsecutiveEmptyRestarts)

        let atThreshold = Harness()
        let second = makeStream(harness: atThreshold)
        for _ in 0..<(LiveSpeechStream.maxConsecutiveEmptyRestarts + 2) {
            atThreshold.advance(by: threshold)
            atThreshold.endCurrentTask(with: SilenceTimeout())
        }
        XCTAssertEqual(atThreshold.startCount, 1 + LiveSpeechStream.maxConsecutiveEmptyRestarts + 2)
        stream.cancel()
        second.cancel()
    }

    func testGivingUpReleasesBufferedAudioAndStopsBuffering() {
        let harness = Harness()
        let stream = makeStream(harness: harness)
        for _ in 0..<LiveSpeechStream.maxConsecutiveEmptyRestarts {
            harness.advance(by: 0.01)
            harness.endCurrentTask(with: SilenceTimeout())
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        stream.append(buffer)

        XCTAssertTrue(
            stream.pendingPCMBuffersForTesting().isEmpty,
            "a stream that gave up has no recipient for audio"
        )
        stream.cancel()
    }

    func testFinishWithNoActiveRequestReleasesPendingAudio() {
        let harness = Harness(available: false)
        let stream = makeStream(harness: harness)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        stream.append(buffer)
        XCTAssertEqual(stream.pendingPCMBuffersForTesting().count, 1)

        stream.finish()

        XCTAssertTrue(stream.pendingPCMBuffersForTesting().isEmpty)
    }

    // MARK: stream.taskEnded evidence

    func testTaskEndedNoteCarriesLifetimeTextAndErrorIdentity() {
        let error = NSError(domain: "kAFAssistantErrorDomain", code: 1110)

        let note = LiveSpeechStream.taskEndedNote(
            segment: 3, taskGeneration: 4, lifetime: 12.3456, textLength: 0,
            endedBy: "error", error: error, countedAsEmptyRestart: false
        )

        XCTAssertTrue(note.contains("lifetimeMs=12346"), note)
        XCTAssertTrue(note.contains("produced=false"), note)
        XCTAssertTrue(note.contains("endedBy=error"), note)
        XCTAssertTrue(note.contains("errorDomain=kAFAssistantErrorDomain"), note)
        XCTAssertTrue(note.contains("errorCode=1110"), note)
        XCTAssertTrue(note.contains("countedAsEmptyRestart=false"), note)
    }

    func testTaskEndedNoteForAFinalResultHasNoErrorAndReportsText() {
        let note = LiveSpeechStream.taskEndedNote(
            segment: 0, taskGeneration: 1, lifetime: 0.5, textLength: 17,
            endedBy: "final", error: nil, countedAsEmptyRestart: false
        )

        XCTAssertTrue(note.contains("produced=true"), note)
        XCTAssertTrue(note.contains("textLength=17"), note)
        XCTAssertFalse(note.contains("errorDomain"), note)
    }

    // MARK: Doubles

    private final class SegmentSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SpeechSegment] = []
        func append(_ segment: SpeechSegment) { lock.withLock { storage.append(segment) } }
    }

    /// Scripted recognizer plus a manual clock. Tasks never end on their own: the test ends the
    /// current one, after advancing the clock by however long it should have lived.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 1_000
        private var handlers: [AppleOnDeviceSpeechRuntime.ResultHandler] = []
        private let available: Bool

        init(available: Bool = true) { self.available = available }

        var now: TimeInterval { lock.withLock { time } }
        var startCount: Int { lock.withLock { handlers.count } }

        func advance(by seconds: TimeInterval) { lock.withLock { time += seconds } }

        func endCurrentTask(with error: Error) {
            let handler = lock.withLock { handlers.last }
            handler?(nil, error)
        }

        var runtime: AppleOnDeviceSpeechRuntime {
            AppleOnDeviceSpeechRuntime(
                isAvailable: { [available] in available },
                supportsOnDeviceRecognition: { true },
                startRecognition: { [self] _, handler in
                    lock.withLock { handlers.append(handler) }
                    return AppleSpeechTaskHandle(cancel: {})
                }
            )
        }
    }
}
