import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// Suggested triggers for the built-in AI kinds.
///
/// These are offered to the user as ready-made snippet triggers, so two kinds proposing the
/// same one is a collision the user only discovers when the second snippet refuses to save.
/// Nothing checked this: the switch is exhaustive, so the compiler catches a *missing*
/// trigger, but a duplicated one compiles fine.
final class SnippetTemplateTriggerTests: XCTestCase {

    func testEveryKindProposesADistinctTrigger() {
        var seen: [String: AITransformKind] = [:]
        for kind in AITransformKind.allCases {
            let trigger = SnippetTemplateCatalog.defaultTrigger(for: kind)
            if let owner = seen[trigger] {
                XCTFail("\(kind.rawValue) and \(owner.rawValue) both propose \"\(trigger)\".")
            }
            seen[trigger] = kind
        }
        XCTAssertEqual(seen.count, AITransformKind.allCases.count)
    }

    /// A leading punctuation sigil is what makes a trigger fire instantly rather than
    /// waiting for a word boundary, which is the whole point of the suggestion.
    func testEveryProposedTriggerLeadsWithASigil() {
        for kind in AITransformKind.allCases {
            let trigger = SnippetTemplateCatalog.defaultTrigger(for: kind)
            XCTAssertTrue(trigger.hasPrefix(":"), "\(kind.rawValue) proposes \"\(trigger)\".")
            XCTAssertGreaterThan(trigger.count, 1, "\(kind.rawValue) proposes a bare sigil.")
        }
    }

    /// Every kind needs a label for the generated snippet, and a blank one would render as
    /// an unnamed row.
    func testEveryKindHasANonEmptyInstruction() {
        for kind in AITransformKind.allCases {
            XCTAssertFalse(
                SnippetTemplateCatalog.aiInstruction(for: kind)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(kind.rawValue) has no instruction label."
            )
        }
    }
}
