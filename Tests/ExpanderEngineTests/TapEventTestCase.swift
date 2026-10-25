import Carbon.HIToolbox
import XCTest
@testable import ExpanderEngine

/// Drives the real `EventTapEngine.handleTapEvent` with constructed `CGEvent`s.
///
/// Every other suite exercises a piece (matcher, prefix index, hold coordinator) or a mirror of
/// the tap callback. None calls the callback, so a gate-ordering or bookkeeping fault *between*
/// the pieces — a key that bypasses matching without invalidating the buffer, a bookkeeping call
/// made before the decision that should gate it — was untestable. Subclasses close that.
///
/// Observability without injection: the library is `` `slm `` + `` `slmabout ``, so completing
/// `` `slm `` is an *ambiguous* match. The engine answers it by arming a hold (never swallowing,
/// never injecting), and `heldCoordinator.hasHold` is the observable "a match was decided". No
/// test may type a key sequence that fires an expansion: the callback would try to inject.
class TapEventTestCase: XCTestCase {
    var engine: EventTapEngine!

    override func setUp() {
        super.setUp()
        // The undo path reads `EventTapEngine.shared`; its first use runs a layout refresh whose
        // listeners include every live engine. Pay that now rather than in the middle of a test.
        _ = EventTapEngine.shared
        engine = EventTapEngine()
        engine.snippets = [prefixTriggerSnippet("`slm"), prefixTriggerSnippet("`slmabout")]
        // No test may post a keystroke to the machine it runs on.
        engine.typeAheadReplayPoster = { _ in }
        // The engine's initialiser queues a layout refresh and app-context priming on main; each
        // ends in `resetBuffer()`. Let them land now so none arrives in the middle of a test.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        setFrontmost(pid: 735, bundleID: "com.apple.Safari")
    }

    override func tearDown() {
        // A live hold schedules a main-queue debounce timer. Cancel it so a later run-loop spin in
        // another test cannot claim it and attempt a real injection.
        engine.heldCoordinator.cancelAll(reason: .bufferReset)
        engine = nil
        super.tearDown()
    }

    // MARK: - Harness

    func setFrontmost(pid: pid_t?, bundleID: String?, muted: Bool = false) {
        engine.contextLock.lock()
        engine._frontmostContext = EventTapEngine.FrontmostContext(
            bundleID: bundleID, processID: pid, isMuted: muted, isTerminal: false
        )
        engine.contextLock.unlock()
    }

    /// A constructed event has timestamp 0 until the system stamps it on delivery. Stamp it the way
    /// the tap documents it ("roughly, nanoseconds since startup") so the quiescence clock sees it.
    private func stamp(_ event: CGEvent) {
        event.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
    }

    @discardableResult
    func key(
        _ text: String,
        keyCode: Int64 = 0,
        flags: CGEventFlags = [],
        autorepeat: Bool = false,
        synthetic: Bool = false
    ) -> Unmanaged<CGEvent>? {
        let source = CGEventSource(stateID: .privateState)
        if synthetic { source?.userData = SyntheticEventMarker.magicUserData }
        guard let event = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true
        ) else {
            XCTFail("could not construct a key event")
            return nil
        }
        event.flags = flags
        if !text.isEmpty {
            let units = Array(text.utf16)
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress)
            }
        }
        event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
        stamp(event)
        return engine.handleTapEvent(type: .keyDown, event: event)
    }

    func type(_ text: String) {
        for character in text { key(String(character)) }
    }

    func click() {
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: .zero, mouseButton: .left
        ) else { return XCTFail("could not construct a mouse event") }
        stamp(event)
        _ = engine.handleTapEvent(type: .leftMouseDown, event: event)
    }

    func modifierOnly(keyCode: Int64, flags: CGEventFlags) {
        guard let event = CGEvent(source: nil) else { return XCTFail("no event") }
        event.type = .flagsChanged
        event.flags = flags
        event.setIntegerValueField(.keyboardEventKeycode, value: keyCode)
        stamp(event)
        _ = engine.handleTapEvent(type: .flagsChanged, event: event)
    }

    var ring: String {
        engine.lock.lock()
        defer { engine.lock.unlock() }
        return String(engine.ringBuffer.makeArray())
    }

    var hasHold: Bool { engine.heldCoordinator.hasHold }

    /// Ends an in-flight expansion claimed through `tryBeginExpansion()` *without* the HID replay
    /// `endExpansion()` performs — a test must never post keystrokes to the machine it runs on.
    @discardableResult
    func abandonExpansion() -> String {
        engine.lock.lock()
        defer { engine.lock.unlock() }
        engine._isExpanding = false
        return engine._typeAhead.endExpansion()
    }
}
