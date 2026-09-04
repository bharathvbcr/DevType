import XCTest
@testable import ExpanderEngine

final class PermissionRequesterGenericTests: XCTestCase {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _requestCount = 0
        private var _continuedOnMainActor = false

        func recordRequest() {
            lock.lock()
            _requestCount += 1
            lock.unlock()
        }

        func recordMainActorContinuation() {
            lock.lock()
            _continuedOnMainActor = true
            lock.unlock()
        }

        var requestCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _requestCount
        }

        var continuedOnMainActor: Bool {
            lock.lock(); defer { lock.unlock() }
            return _continuedOnMainActor
        }
    }

    func testMicrophoneRequestIsAsyncAndReportsTheFinalPreflightTruth() async {
        let state = State()
        let requester = PermissionRequester(
            microphoneRequest: {
                await Task.yield()
                await MainActor.run { state.recordMainActorContinuation() }
                return true
            },
            microphonePreflight: { false },
            speechRequest: { .authorized },
            speechStatus: { .authorized }
        )

        let result = await requester.request(kind: .microphone)

        XCTAssertTrue(state.continuedOnMainActor, "The caller must remain schedulable while TCC answers")
        XCTAssertTrue(result.apiReturnedTrue)
        XCTAssertFalse(result.preflightGranted, "An API callback is not permission proof")
    }

    func testDeniedSpeechNeverClaimsThePermissionWasGranted() async {
        let state = State()
        let requester = PermissionRequester(
            microphoneRequest: { false },
            microphonePreflight: { false },
            speechRequest: { state.recordRequest(); return .authorized },
            speechStatus: { .denied }
        )

        let result = await requester.request(kind: .speechRecognition)

        XCTAssertFalse(result.apiReturnedTrue)
        XCTAssertFalse(result.preflightGranted)
        XCTAssertEqual(state.requestCount, 0, "A decided denial must use Settings, not ask TCC again")
    }

    func testUndeterminedSpeechRequestsAndReportsTheActualDeniedOutcome() async {
        let state = State()
        let requester = PermissionRequester(
            microphoneRequest: { false },
            microphonePreflight: { false },
            speechRequest: { state.recordRequest(); return .denied },
            speechStatus: { .notDetermined }
        )

        let result = await requester.request(kind: .speechRecognition)

        XCTAssertEqual(state.requestCount, 1)
        XCTAssertFalse(result.apiReturnedTrue)
        XCTAssertFalse(result.preflightGranted)
    }

    func testAuthorizedSpeechDoesNotPromptAgain() async {
        let state = State()
        let requester = PermissionRequester(
            microphoneRequest: { false },
            microphonePreflight: { false },
            speechRequest: { state.recordRequest(); return .denied },
            speechStatus: { .authorized }
        )

        let result = await requester.request(kind: .speechRecognition)

        XCTAssertEqual(state.requestCount, 0)
        XCTAssertTrue(result.apiReturnedTrue)
        XCTAssertTrue(result.preflightGranted)
    }
}
