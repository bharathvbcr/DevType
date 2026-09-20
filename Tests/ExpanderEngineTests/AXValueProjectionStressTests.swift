import ApplicationServices
import Foundation
import XCTest
@testable import ExpanderEngine

/// Adversarial coverage for the §8.6 "is this AXValue the typed buffer?" classification.
///
/// The erase guard refuses an expansion when the field window disagrees with the trigger. That
/// is only sound while `AXValue` *is* the buffer the user typed into; for a host that reports a
/// rendered projection (combo-box selected item, terminal grid padded with NBSP, static row) the
/// disagreement is guaranteed and the refusal costs the user every expansion.
///
/// The recovery must not become a hole. These tests attack it from the other side: they fuzz
/// roles, settability answers, plans, carets and intents, and assert the invariants that keep a
/// genuine "your text changed" on the refusing path. A downgrade only ever authorises a
/// best-effort HID erase at the app's real insertion point — never an AX range write.
final class AXValueProjectionStressTests: XCTestCase {

    private final class Field {
        var value: String?
        var range: NSRange?
        var rangedText: String?
        var role: String?
        var acceptsTextMutation: Bool?

        func executor() -> EraseExecutor {
            EraseExecutor(textAccess: .init(
                value: { _ in self.value },
                selectedRange: { _ in self.range },
                stringForRange: { _, _ in self.rangedText },
                role: { _ in self.role },
                acceptsTextMutation: { _ in self.acceptsTextMutation }
            ))
        }

        func evaluate(
            plan: ErasePlan,
            vouched: Bool,
            intent: EraseExecutor.Intent
        ) -> ErasePreconditionResult {
            executor().evaluateErasePrecondition(
                plan: plan,
                element: AXUIElementCreateApplication(1234),
                retryOnMismatch: false,
                insertionPointFollowsExpectedText: vouched,
                intent: intent
            )
        }
    }

    /// Roles across every bucket: unstable, text-entry, container, static, unknown, junk.
    private let roles: [String?] = [
        nil, "", " ", "AXComboBox", "AXPopUpButton", "AXMenu", "AXMenuBar", "AXMenuButton",
        "AXList", "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField",
        "AXGroup", "AXStaticText", "AXWebArea", "AXScrollArea", "AXRow", "AXCell", "AXUnknown",
        "axtextfield", "AXTextField ", "AX\u{0000}TextField", String(repeating: "A", count: 4096)
    ]

    /// Padding shapes a projection host reports where the trigger should be.
    private let windows = [
        "\u{00A0}\u{00A0}\u{00A0}\u{00A0}\u{00A0}\u{00A0}",
        "a\u{00A0} \u{00A0} b",
        "      ",
        "\u{2007}\u{202F}\u{3000}\u{2000} x",
        "\u{200B}\u{200B}\u{200B}\u{200B}\u{200B}\u{200B}",
        "🎓🎓🎓",
        "e\u{0301}e\u{0301}e\u{0301}"
    ]

    private let triggers = [";addr1", "`x", "``", "sig", "🎓abc", "e\u{0301}abc", ";z"]

    // MARK: - Invariants under fuzz

    func testFuzzedProjectionClassificationNeverOpensAnAXWritePath() {
        var rng = SplitMix64(seed: 0x9_2026_0920)
        var downgrades = 0
        var refusals = 0

        for _ in 0..<20_000 {
            let field = Field()
            let trigger = triggers.randomElement(using: &rng)!
            let window = windows.randomElement(using: &rng)!
            let plan = ErasePlan(text: trigger, caseInsensitive: Bool.random(using: &rng))
            let prefix = String(repeating: "x", count: Int.random(in: 0...40, using: &rng))
            field.value = prefix + window
            let units = field.value?.utf16.count ?? 0
            field.range = NSRange(
                location: Int.random(in: 0...max(0, units), using: &rng),
                length: Bool.random(using: &rng) ? 0 : Int.random(in: 1...4, using: &rng)
            )
            field.rangedText = Bool.random(using: &rng) ? window : nil
            field.role = roles.randomElement(using: &rng)!
            field.acceptsTextMutation = [true, false, nil].randomElement(using: &rng)!

            let vouched = Bool.random(using: &rng)
            let intent: EraseExecutor.Intent = Bool.random(using: &rng)
                ? .expansion
                : .undo(inputEventsSinceExpansion: Int.random(in: 0...3, using: &rng))

            let result = field.evaluate(plan: plan, vouched: vouched, intent: intent)

            switch result {
            case .ok:
                // Only reachable when the window really does hold the trigger.
                XCTAssertFalse(result.requiresHID)
            case .unavailable(let reason):
                downgrades += 1
                XCTAssertTrue(
                    result.requiresHID,
                    "A field we could not verify must force HID, never an AX range write: \(reason)"
                )
                assertNoTextLeak(reason, trigger: trigger, window: window)
            case .mismatch(let reason):
                refusals += 1
                XCTAssertTrue(result.blocksErase)
                assertNoTextLeak(reason, trigger: trigger, window: window)
            }
        }

        XCTAssertGreaterThan(downgrades, 0, "The fuzz never exercised a downgrade")
        XCTAssertGreaterThan(refusals, 0, "The fuzz never exercised a refusal")
    }

    /// The safety invariant. A role that owns its text buffer must keep the strict refusal no
    /// matter what settability says — otherwise a real "the user's text moved" becomes a blind
    /// erase of six characters they typed.
    func testATextEntryRoleThatDisagreesIsNeverDowngraded() {
        var rng = SplitMix64(seed: 0x7E_47_B0_1E)
        for role in AXWriteCapabilityStore.textEntryRoles {
            for _ in 0..<500 {
                let field = Field()
                let trigger = triggers.randomElement(using: &rng)!
                let window = windows.randomElement(using: &rng)!
                let plan = ErasePlan(text: trigger)
                let prefix = String(repeating: "x", count: Int.random(in: 0...30, using: &rng))
                field.value = prefix + window
                field.range = NSRange(location: field.value?.utf16.count ?? 0, length: 0)
                field.rangedText = window
                field.role = role
                field.acceptsTextMutation = [true, false, nil].randomElement(using: &rng)!

                let result = field.evaluate(plan: plan, vouched: true, intent: .expansion)
                guard result != .ok else { continue }
                XCTAssertTrue(
                    result.blocksErase,
                    "role=\(role) must refuse a disagreeing window, got \(result)"
                )
            }
        }
    }

    /// Undo, voice and an active selection cannot borrow the vouch, for every projection shape.
    func testUnvouchedPathsNeverReachTheProjectionRecovery() {
        var rng = SplitMix64(seed: 0xB0_11_5EED)
        for _ in 0..<4_000 {
            let field = Field()
            let trigger = triggers.randomElement(using: &rng)!
            let window = windows.randomElement(using: &rng)!
            let plan = ErasePlan(text: trigger)
            field.value = String(repeating: "x", count: 30) + window
            field.rangedText = window
            field.role = roles.randomElement(using: &rng)!
            field.acceptsTextMutation = false

            // Three ways to lose the vouch, each of which must keep the refusal.
            let caretAtEnd = NSRange(location: field.value?.utf16.count ?? 0, length: 0)
            let cases: [(NSRange, Bool, EraseExecutor.Intent)] = [
                (caretAtEnd, false, .expansion),
                (caretAtEnd, true, .undo(inputEventsSinceExpansion: 1)),
                (NSRange(location: caretAtEnd.location, length: 2), true, .expansion)
            ]
            for (range, vouched, intent) in cases {
                field.range = range
                let result = field.evaluate(plan: plan, vouched: vouched, intent: intent)
                guard result != .ok else { continue }
                XCTAssertTrue(
                    result.blocksErase,
                    "vouched=\(vouched) intent=\(intent) role=\(field.role ?? "nil") got \(result)"
                )
            }
        }
    }

    /// Same inputs, same verdict — the classifier must not depend on call order or shared state.
    func testClassificationIsDeterministic() {
        var rng = SplitMix64(seed: 0xDE7E_121A)
        for _ in 0..<5_000 {
            let role = roles.randomElement(using: &rng)!
            let settable = [true, false, nil].randomElement(using: &rng)!
            let first = ErasePreconditionChecker.classifyAXValue(
                role: role, acceptsTextMutation: settable
            )
            for _ in 0..<3 {
                XCTAssertEqual(
                    ErasePreconditionChecker.classifyAXValue(
                        role: role, acceptsTextMutation: settable
                    ),
                    first,
                    "role=\(role ?? "nil") settable=\(String(describing: settable))"
                )
            }
        }
    }

    /// Hostile role strings must classify, not crash, and must never be mistaken for a
    /// text-entry role by a near-miss (case, padding, embedded NUL, unbounded length).
    func testHostileRoleStringsAreNeverMistakenForTextEntry() {
        let nearMisses = [
            "axtextfield", "AXTEXTFIELD", "AXTextField ", " AXTextField", "AXTextField\u{0000}",
            "AX\u{0000}TextField", "AXTextFieldExtra", "AXText", String(repeating: "A", count: 100_000),
            "AXComboBox ", "axcombobox", "\u{202E}AXTextField"
        ]
        for role in nearMisses {
            XCTAssertFalse(AXWriteCapabilityStore.isTextEntryRole(role), role.prefix(32).description)
            XCTAssertFalse(AXWriteCapabilityStore.isAXWriteUnstableRole(role), role.prefix(32).description)
            // Undetermined without settability evidence; a projection only with it.
            XCTAssertEqual(
                ErasePreconditionChecker.classifyAXValue(role: role, acceptsTextMutation: nil),
                .undetermined
            )
            XCTAssertEqual(
                ErasePreconditionChecker.classifyAXValue(role: role, acceptsTextMutation: true),
                .undetermined
            )
            XCTAssertEqual(
                ErasePreconditionChecker.classifyAXValue(role: role, acceptsTextMutation: false),
                .projection("readOnlyRole=\(role)")
            )
        }
    }

    /// The two named lists must stay disjoint, or a role would classify two ways at once.
    func testRoleListsAreDisjoint() {
        XCTAssertTrue(
            AXWriteCapabilityStore.axWriteUnstableRoles
                .isDisjoint(with: AXWriteCapabilityStore.textEntryRoles),
            "A role cannot be both a projection prior and its own text buffer"
        )
        for role in AXWriteCapabilityStore.axWriteUnstableRoles {
            XCTAssertEqual(
                ErasePreconditionChecker.classifyAXValue(role: role, acceptsTextMutation: true),
                .projection("unstableRole=\(role)"),
                "A settable combo box is still a combo box"
            )
        }
    }

    private func assertNoTextLeak(_ reason: String, trigger: String, window: String) {
        XCTAssertFalse(reason.contains(trigger), "Trigger leaked into a log line: \(reason)")
        if window.count > 2 {
            XCTAssertFalse(reason.contains(window), "Field text leaked into a log line: \(reason)")
        }
    }
}
