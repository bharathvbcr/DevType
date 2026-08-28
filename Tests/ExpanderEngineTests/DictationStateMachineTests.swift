import XCTest
@testable import ExpanderEngine

final class DictationStateMachineTests: XCTestCase {

    func testHappyPathHoldMode() {
        var state: DictationState = .idle

        // 1. User presses and holds hotkey
        state = DictationStateMachine.transition(state, on: .hotkeyDown)
        XCTAssertEqual(state, .recording(mode: .hold))

        // 2. User releases hotkey
        state = DictationStateMachine.transition(state, on: .hotkeyUp)
        XCTAssertEqual(state, .encoding)

        // 3. Audio encoding completes
        let tempURL = URL(fileURLWithPath: "/tmp/test.flac")
        state = DictationStateMachine.transition(state, on: .encodingComplete(tempURL))
        XCTAssertEqual(state, .transcribing)

        // 4. Transcript is received
        state = DictationStateMachine.transition(state, on: .transcriptReady("Hello world"))
        XCTAssertEqual(state, .inserting)

        // 5. Text insertion completes
        state = DictationStateMachine.transition(state, on: .insertionComplete(.inserted))
        XCTAssertEqual(state, .success(text: "", outcome: .inserted))

        // 6. User initiates new dictation from success state
        state = DictationStateMachine.transition(state, on: .hotkeyDown)
        XCTAssertEqual(state, .recording(mode: .hold))
    }

    func testHandsFreeLockInMode() {
        var state: DictationState = .idle

        // 1. User presses hotkey
        state = DictationStateMachine.transition(state, on: .hotkeyDown)
        XCTAssertEqual(state, .recording(mode: .hold))

        // 2. Quick tap converts to hands-free lock-in
        state = DictationStateMachine.transition(state, on: .lockIn)
        XCTAssertEqual(state, .recording(mode: .handsFree))

        // 3. Second hotkey press stops hands-free recording
        state = DictationStateMachine.transition(state, on: .hotkeyDown)
        XCTAssertEqual(state, .encoding)
    }

    func testCancellationFromRecording() {
        var state: DictationState = .idle
        state = DictationStateMachine.transition(state, on: .hotkeyDown)
        XCTAssertEqual(state, .recording(mode: .hold))

        state = DictationStateMachine.transition(state, on: .cancel)
        XCTAssertEqual(state, .cancelled)

        // Can start new session after cancel
        state = DictationStateMachine.transition(state, on: .hotkeyDown)
        XCTAssertEqual(state, .recording(mode: .hold))
    }

    func testGlobalErrorTransition() {
        var state: DictationState = .transcribing
        state = DictationStateMachine.transition(state, on: .error(.auth))
        XCTAssertEqual(state, .failed(.auth))

        // Can restart from failed state
        state = DictationStateMachine.transition(state, on: .hotkeyDown)
        XCTAssertEqual(state, .recording(mode: .hold))
    }

    func testInvalidTransitionsAreNoOps() {
        let state: DictationState = .idle
        // hotkeyUp while idle should be ignored
        let nextState = DictationStateMachine.transition(state, on: .hotkeyUp)
        XCTAssertEqual(nextState, .idle)
    }
}
