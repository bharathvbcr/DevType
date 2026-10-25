import Carbon.HIToolbox
import XCTest
@testable import ExpanderEngine

/// Keys that reach the field without passing through matching must not leave behind a buffer or a
/// hold that no longer describes it. Each of these failed against the code before the fix:
/// the buffer kept the characters typed before the bypass, so one character after matching
/// resumed completed a trigger the field never contained — and the blind erase that follows
/// deletes whatever is actually there.
final class TapBypassedInputTests: TapEventTestCase {

    /// A panel or palette owns the keyboard while matching is suspended. What the user types
    /// there lands in a different text view, but the buffer still holds the `` `sl `` typed before
    /// the panel opened.
    func testTypingWhileMatchingIsSuspendedInvalidatesThePartialTrigger() {
        type("`sl")
        let suspension = engine.suspendMatching(reason: "test panel")
        type("abc")
        suspension.release()
        type("m")
        XCTAssertFalse(hasHold)
        XCTAssertEqual(ring, "m")
    }

    func testTypingWhileDisabledInvalidatesThePartialTrigger() {
        type("`sl")
        engine.lock.lock()
        engine._isEnabled = false
        engine.lock.unlock()
        type("abc")
        engine.lock.lock()
        engine._isEnabled = true
        engine.lock.unlock()
        type("m")
        XCTAssertFalse(hasHold)
    }

    /// Holding a key delivers repeats the matcher never sees. The field now holds text the buffer
    /// lacks, so the buffer is stale from the first repeat on.
    func testAutorepeatInvalidatesThePartialTrigger() {
        type("`sl")
        key("l", autorepeat: true)
        key("l", autorepeat: true)
        type("m")
        XCTAssertFalse(hasHold, "the field holds `sll…`, not `sl`, by the time `m` arrives")
        XCTAssertEqual(ring, "m")
    }

    func testMutingTheFrontmostAppDuringAHoldCancelsIt() {
        type("`slm")
        XCTAssertTrue(hasHold)
        setFrontmost(pid: 735, bundleID: "com.apple.Safari", muted: true)
        type("a")
        XCTAssertFalse(hasHold, "a key that bypasses the matcher is invisible to the hold's erase count")
    }

    // MARK: - Stale polled Secure Input flag

    /// `_isSecureInputActive` is refreshed from the main queue after a 350 ms poll. Matching must
    /// not stay dark for that whole window once the live system state says Secure Input is off.
    func testStalePolledSecureFlagDoesNotSilenceMatching() {
        engine.liveSecureInputProbe = { false }
        engine.lock.lock()
        engine._isSecureInputActive = true
        engine.lock.unlock()
        type("`slm")
        XCTAssertTrue(hasHold, "live Secure Input is off; the stale polled flag must not swallow the trigger")
        XCTAssertFalse(engine.isSecureInputActive, "the stale flag is corrected from the live read")
    }

    /// The live read overrules the polled flag only toward "not secure": while the system says
    /// Secure Input is on, a key that reaches the tap must still bypass matching.
    func testGenuineSecureInputStillBypassesMatching() {
        engine.liveSecureInputProbe = { true }
        engine.lock.lock()
        engine._isSecureInputActive = true
        engine.lock.unlock()
        type("`slm")
        XCTAssertFalse(hasHold)
        XCTAssertEqual(ring, "")
        XCTAssertTrue(engine.isSecureInputActive)
    }

    // MARK: - Fn / Globe

    /// Fn / Globe opens the emoji picker or dictation, which insert text with no key events.
    func testFunctionKeyPressInvalidatesThePartialTrigger() {
        type("`sl")
        modifierOnly(keyCode: Int64(kVK_Function), flags: .maskSecondaryFn)
        type("m")
        XCTAssertFalse(hasHold)
    }
}
