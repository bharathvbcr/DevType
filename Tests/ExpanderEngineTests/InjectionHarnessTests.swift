import XCTest
@testable import ExpanderEngine

/// The shared harness drives the real pipeline end to end, so the behavioural suites built on it
/// are only as good as this baseline: a typed expansion that nothing interferes with erases the
/// trigger with real backspaces, pastes through the broker, and leaves exactly the replacement.
final class InjectionHarnessTests: XCTestCase {

    func testATypedExpansionErasesTheTriggerAndPastesTheResult() throws {
        let harness = try InjectionHarness()
        harness.seedUserClipboard()
        let run = harness.typeExpansion(in: self)

        XCTAssertEqual(run.text, "say: Sincerely, Slim")
        XCTAssertEqual(harness.backspaces, 4, "one delete key per grapheme of the trigger")
        XCTAssertEqual(harness.chords, 1, "\(harness.log)")
        XCTAssertEqual(harness.page.value(of: harness.field), "say: Sincerely, Slim")
        XCTAssertNotNil(run.outcome)
    }
}
