import ExpanderEngine
import XCTest
@testable import SafariHarnessCore

final class KeyPlanTests: XCTestCase {
    func testUnshiftedCharacterIsADownUpPairWithNoFlags() throws {
        XCTAssertEqual(try KeyPlan.events(for: ";"), [
            KeyEvent(keyCode: 41, down: true), KeyEvent(keyCode: 41, down: false)
        ])
    }

    func testShiftedCharacterPressesShiftFirstAndReleasesItLast() throws {
        let events = try KeyPlan.events(for: ":")
        XCTAssertEqual(events.map(\.keyCode), [56, 41, 41, 56])
        XCTAssertEqual(events.map(\.down), [true, true, false, false])
        XCTAssertEqual(events.map(\.flags), [.shift, .shift, .shift, []])
    }

    func testUppercaseLetterUsesShiftOnTheLowercaseKey() throws {
        XCTAssertEqual(try KeyPlan.events(for: "A").map(\.keyCode), [56, 0, 0, 56])
    }

    func testUnmappableCharacterThrowsInsteadOfTypingSomethingElse() {
        XCTAssertThrowsError(try KeyPlan.events(for: "é")) { error in
            XCTAssertEqual(error as? KeyPlanError, .unmappableCharacter("é"))
        }
        XCTAssertFalse(KeyPlan.canType("ab\u{1F600}"))
    }

    func testDefaultTriggerAndExpansionAreTypeable() {
        XCTAssertTrue(KeyPlan.canType(HarnessConstants.defaultTrigger))
        XCTAssertTrue(KeyPlan.canType("proofread"))
    }

    func testChordOrdersModifiersDownThenKeyThenReverseUpAndCarriesHeldFlags() {
        let events = KeyPlan.chord(keyCode: 0, modifiers: [.option, .command])
        XCTAssertEqual(events.map(\.keyCode), [58, 55, 0, 0, 55, 58])
        XCTAssertEqual(events.map(\.down), [true, true, true, false, false, false])
        XCTAssertEqual(events[1].flags, [.option, .command])
        XCTAssertEqual(events[4].flags, [.option])
        XCTAssertEqual(events[5].flags, [])
    }

    func testOnlyUSLayoutsAreAccepted() {
        XCTAssertTrue(LayoutPolicy.isSupported(sourceID: "com.apple.keylayout.US"))
        XCTAssertTrue(LayoutPolicy.isSupported(sourceID: "com.apple.keylayout.ABC"))
        XCTAssertFalse(LayoutPolicy.isSupported(sourceID: "com.apple.keylayout.Dvorak"))
        XCTAssertFalse(LayoutPolicy.isSupported(sourceID: nil))
    }

    func testJitterIsDeterministicAndInsideThePaceBounds() {
        var a = JitterRNG(seed: 7), b = JitterRNG(seed: 7), c = JitterRNG(seed: 8)
        let first = (0..<50).map { _ in Pace.human.sampleGap(&a) }
        XCTAssertEqual(first, (0..<50).map { _ in Pace.human.sampleGap(&b) })
        XCTAssertNotEqual(first, (0..<50).map { _ in Pace.human.sampleGap(&c) })
        XCTAssertTrue(first.allSatisfy { Pace.human.gapMs.contains($0) })
        var d = JitterRNG(seed: 1)
        let holds = (0..<200).map { _ in Pace.fast.sampleHold(&d) }
        XCTAssertTrue(holds.allSatisfy { Pace.fast.holdMs.contains($0) })
    }

    func testAIHotkeyDefaultsWhenAbsentOrUnreadableAndDecodesCarbonMasks() throws {
        XCTAssertEqual(AIHotkey.decode(nil), .default)
        XCTAssertEqual(AIHotkey.decode(Data("not json".utf8)), .default)
        // No modifier is rejected the way DevType rejects it.
        XCTAssertEqual(AIHotkey.decode(Data(#"{"keyCode":0,"carbonModifiers":0}"#.utf8)), .default)
        let custom = AIHotkey.decode(Data(#"{"keyCode":35,"carbonModifiers":4864}"#.utf8)) // control+shift+command
        XCTAssertEqual(custom.keyCode, 35)
        XCTAssertEqual(custom.modifiers, [.control, .shift, .command])
        XCTAssertFalse(custom.isDefault)
        XCTAssertEqual(AIHotkey.default.modifiers, [.option, .command])
    }

    func testSyntheticMarkerCopyMatchesTheEngine() {
        XCTAssertEqual(HarnessConstants.devTypeSyntheticMarker, SyntheticEventMarker.magicUserData)
    }
}

final class AbortControllerTests: XCTestCase {
    private final class Inputs: @unchecked Sendable {
        var time = 0.0
        var escape = false
        var signalled = false
    }

    private func make(timeout: Double = 100) -> (AbortController, Inputs) {
        let inputs = Inputs()
        let controller = AbortController(
            timeoutSeconds: timeout,
            now: { inputs.time },
            escapeDown: { inputs.escape },
            signalled: { inputs.signalled }
        )
        return (controller, inputs)
    }

    func testQuietRunDoesNotAbort() throws {
        let (controller, inputs) = make()
        inputs.time = 50
        XCTAssertNoThrow(try controller.check())
    }

    func testEscapeAbortsAndLatchesEvenAfterTheKeyIsReleased() {
        let (controller, inputs) = make()
        inputs.escape = true
        XCTAssertThrowsError(try controller.check()) { XCTAssertEqual(($0 as? HarnessAbort)?.reason, .escapePressed) }
        inputs.escape = false
        XCTAssertEqual(controller.poll(), .escapePressed)
    }

    func testDeadlineAborts() {
        let (controller, inputs) = make(timeout: 10)
        inputs.time = 10
        XCTAssertEqual(controller.poll(), .timeout(seconds: 10))
    }

    func testSignalAbortsAndOutranksEscape() {
        let (controller, inputs) = make()
        inputs.signalled = true
        inputs.escape = true
        XCTAssertEqual(controller.poll(), .interrupted)
    }

    func testHarnessOwnEscapeIsIgnoredOnlyInsideTheSuppressWindow() {
        let (controller, inputs) = make()
        controller.suppressEscape(forSeconds: 0.5)
        inputs.escape = true
        XCTAssertNil(controller.poll())
        inputs.time = 0.6
        XCTAssertEqual(controller.poll(), .escapePressed)
    }

    func testExternalTripWinsFirstAndStays() {
        let (controller, _) = make()
        controller.trip(.unsafeFocus("x"))
        controller.trip(.interrupted)
        XCTAssertEqual(controller.tripped, .unsafeFocus("x"))
    }
}

final class FocusSafetyTests: XCTestCase {
    private let fixture = "/repo/Tests/Fixtures/SafariHarness/safari-harness.html"

    private func page(_ patch: (inout FocusSnapshot) -> Void = { _ in }) -> FocusSnapshot {
        var s = FocusSnapshot(frontBundleID: "com.apple.Safari", frontPID: 10, focusedPID: 10,
                              focusedDOMID: "dth-plain", focusedRole: "AXTextField", webAreaPath: fixture)
        patch(&s)
        return s
    }

    func testHarnessControlInSafariOnTheFixtureIsAllowed() {
        XCTAssertEqual(FocusSafety.decide(page(), policy: .harnessPage(fixturePath: fixture)), .allow)
    }

    func testEveryBrokenLegRefusesTheKeystroke() {
        let policy = FocusPolicy.harnessPage(fixturePath: fixture)
        let cases: [(String, (inout FocusSnapshot) -> Void)] = [
            ("another app", { $0.frontBundleID = "com.apple.Terminal" }),
            ("no front app", { $0.frontBundleID = nil }),
            ("not a harness id", { $0.focusedDOMID = "search-box" }),
            ("no id", { $0.focusedDOMID = nil }),
            ("other process", { $0.focusedPID = 11 }),
            ("other page", { $0.webAreaPath = "/Users/me/other.html" }),
            ("unreadable page", { $0.webAreaPath = nil }),
            ("reset button", { $0.focusedDOMID = "dth-reset" })
        ]
        for (name, patch) in cases {
            XCTAssertFalse(FocusSafety.decide(page(patch), policy: policy).isAllowed, name)
        }
    }

    func testPaletteIsAllowedOnlyForTheCheckedDevTypeProcessAndATextField() {
        let palette = FocusSnapshot(frontBundleID: "com.devtype.app", frontPID: 77, focusedPID: 77, focusedRole: "AXTextField")
        XCTAssertEqual(FocusSafety.decide(palette, policy: .devTypePalette(devTypePID: 77)), .allow)
        XCTAssertFalse(FocusSafety.decide(palette, policy: .devTypePalette(devTypePID: 78)).isAllowed)
        var button = palette; button.focusedRole = "AXButton"
        XCTAssertFalse(FocusSafety.decide(button, policy: .devTypePalette(devTypePID: 77)).isAllowed)
        var safari = palette; safari.frontBundleID = "com.apple.Safari"
        XCTAssertFalse(FocusSafety.decide(safari, policy: .devTypePalette(devTypePID: 77)).isAllowed)
        var elsewhere = palette; elsewhere.focusedPID = 5
        XCTAssertFalse(FocusSafety.decide(elsewhere, policy: .devTypePalette(devTypePID: 77)).isAllowed)
    }

    func testHarnessPolicyNeverAllowsThePalette() {
        let palette = FocusSnapshot(frontBundleID: "com.devtype.app", frontPID: 77, focusedPID: 77,
                                    focusedDOMID: nil, focusedRole: "AXTextField")
        XCTAssertFalse(FocusSafety.decide(palette, policy: .harnessPage(fixturePath: fixture)).isAllowed)
    }
}
