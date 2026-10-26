import Carbon.HIToolbox
import XCTest
@testable import ExpanderEngine

/// Probes of the buffer-integrity seam in the real tap callback. Each of these was written to
/// break the engine and **passed against the unmodified code**: the seam holds, and these pin it.
/// The cases that did break it live in `TapBypassedInputTests` and `TapTypeAheadTests`.
final class TapKeystrokeIntegrityTests: TapEventTestCase {

    func testCompletingTheAmbiguousTriggerArmsAHold() {
        type("`slm")
        XCTAssertTrue(hasHold, "the harness must be able to observe a match decision")
        XCTAssertEqual(ring, "`slm")
    }

    // MARK: - Self-loop

    /// Events DevType posts carry the source marker; the callback must pass them through without
    /// touching the buffer, the hold, or the quiescence clock.
    func testSyntheticKeysAreInvisibleToTheBuffer() {
        type("`sl")
        let markBefore = engine.inputClock.lastInputAt
        key("m", synthetic: true)
        key("", keyCode: Int64(kVK_Delete), synthetic: true)
        XCTAssertEqual(ring, "`sl")
        XCTAssertFalse(hasHold)
        XCTAssertEqual(engine.inputClock.lastInputAt, markBefore)
        key("m")
        XCTAssertTrue(hasHold, "the real `m` still completes the trigger")
    }

    // MARK: - Keys that move or mutate text without extending the trigger

    func testCaretAndEditKeysInvalidateThePartialTrigger() {
        let cases: [(String, Int64, CGEventFlags)] = [
            ("left arrow", Int64(kVK_LeftArrow), []),
            ("right arrow", Int64(kVK_RightArrow), []),
            ("up arrow", Int64(kVK_UpArrow), []),
            ("down arrow", Int64(kVK_DownArrow), []),
            ("home", Int64(kVK_Home), []),
            ("end", Int64(kVK_End), []),
            ("page up", Int64(kVK_PageUp), []),
            ("page down", Int64(kVK_PageDown), []),
            ("forward delete", Int64(kVK_ForwardDelete), []),
            ("escape", Int64(kVK_Escape), []),
            ("cmd+z", Int64(kVK_ANSI_Z), .maskCommand),
            ("cmd+a", Int64(kVK_ANSI_A), .maskCommand),
            ("ctrl+a", Int64(kVK_ANSI_A), .maskControl),
            ("option+backspace", Int64(kVK_Delete), .maskAlternate),
            ("cmd+backspace", Int64(kVK_Delete), .maskCommand),
        ]
        for (name, keyCode, flags) in cases {
            engine.resetBuffer()
            type("`sl")
            key("", keyCode: keyCode, flags: flags)
            type("m")
            XCTAssertFalse(hasHold, "\(name) between trigger characters must break the trigger")
            XCTAssertEqual(ring, "m", "\(name) must leave a clean buffer")
        }
    }

    func testMouseClickBetweenTriggerCharactersBreaksTheTrigger() {
        type("`sl")
        click()
        type("m")
        XCTAssertFalse(hasHold)
        XCTAssertEqual(ring, "m")
    }

    func testBackspaceEditsTheBufferInStep() {
        type("`slx")
        key("", keyCode: Int64(kVK_Delete))
        type("m")
        XCTAssertTrue(hasHold, "a corrected typo is still a typed trigger")
        XCTAssertEqual(ring, "`slm")
    }

    /// Pressing Shift / Option / Command / Control alone changes no text and moves no caret.
    func testModifierOnlyEventsDoNotDisturbTheBuffer() {
        type("`sl")
        modifierOnly(keyCode: Int64(kVK_Shift), flags: .maskShift)
        modifierOnly(keyCode: Int64(kVK_Option), flags: .maskAlternate)
        modifierOnly(keyCode: Int64(kVK_Command), flags: .maskCommand)
        modifierOnly(keyCode: Int64(kVK_Control), flags: .maskControl)
        modifierOnly(keyCode: Int64(kVK_Shift), flags: [])
        type("m")
        XCTAssertTrue(hasHold)
    }

    func testTabMidTriggerLeavesNoTriggerAcrossFields() {
        type("`sl")
        key("\t", keyCode: Int64(kVK_Tab))
        type("m")
        XCTAssertFalse(hasHold, "a Tab (focus move in Safari) must sit between the halves")
    }

    // MARK: - Non-ASCII

    func testPrecomposedTypedTextMatchesADecomposedTrigger() {
        engine.snippets = [
            prefixTriggerSnippet("`cafe\u{0301}"), prefixTriggerSnippet("`cafe\u{0301}s")
        ]
        type("`caf\u{00E9}")
        XCTAssertTrue(hasHold, "canonically equivalent spellings are the same trigger")
    }

    // MARK: - Layout switch / app switch / secure input flap

    func testLayoutChangeMidTriggerResetsTheBuffer() {
        type("`sl")
        KeyboardLayoutState.shared.refresh()
        XCTAssertEqual(ring, "")
        type("m")
        XCTAssertFalse(hasHold)
    }

    func testAppSwitchDuringAHoldCancelsItAndClearsTheBuffer() {
        type("`slm")
        XCTAssertTrue(hasHold)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        XCTAssertFalse(hasHold, "the hold's erase would land in whichever app is frontmost when it fires")
        XCTAssertEqual(ring, "")
    }

    func testSecureInputFlapMidTriggerClearsBufferAndMatchingResumes() {
        type("`sl")
        engine.isSecureInputActive = true
        XCTAssertEqual(ring, "", "engaging Secure Input must drop the partial trigger")
        engine.isSecureInputActive = false
        type("m")
        XCTAssertFalse(hasHold, "the pre-flap `sl must not combine with the post-flap `m`")
        engine.resetBuffer()
        type("`slm")
        XCTAssertTrue(hasHold, "matching resumes once Secure Input is released")
    }

    func testSecureInputEngagingDuringAHoldCancelsIt() {
        type("`slm")
        XCTAssertTrue(hasHold)
        engine.isSecureInputActive = true
        XCTAssertFalse(hasHold)
        engine.isSecureInputActive = false
    }

    /// A suspension during which nothing was typed changes nothing.
    func testIdleSuspensionDoesNotDisturbTheBuffer() {
        type("`sl")
        let suspension = engine.suspendMatching(reason: "test panel")
        suspension.release()
        type("m")
        XCTAssertTrue(hasHold)
    }
}
