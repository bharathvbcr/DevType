import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

/// Word-level preview diff. The panel's button calls this type; the controller is private.
final class AIPreviewWordDiffTests: XCTestCase {

    func testInsertKeepsTheSurroundingWords() {
        let changes = AIPreviewWordDiff.changes(from: "red fox", to: "red quick fox")
        XCTAssertTrue(changes.contains(.insert("quick")))
        assertRoundTrip("red fox", "red quick fox", changes)
    }

    func testDeleteDropsOnlyTheRemovedWord() {
        let changes = AIPreviewWordDiff.changes(from: "red quick fox", to: "red fox")
        XCTAssertTrue(changes.contains(.delete("quick")))
        assertRoundTrip("red quick fox", "red fox", changes)
    }

    func testReplacePairsTheRemovedWordWithTheInsertedWord() {
        let changes = AIPreviewWordDiff.changes(from: "red fox", to: "blue fox")
        XCTAssertTrue(changes.contains(.replace(old: "red", new: "blue")))
        assertRoundTrip("red fox", "blue fox", changes)
    }

    func testAstralGraphemesStayInsideOneToken() {
        let ideograph = "\u{2000B}"
        let flag = "\u{1F1FA}\u{1F1F8}"
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        XCTAssertEqual(ideograph.count, 1)
        XCTAssertGreaterThan(ideograph.utf16.count, 1)
        XCTAssertEqual(flag.count, 1)
        XCTAssertGreaterThan(flag.utf16.count, 1)
        XCTAssertEqual(family.count, 1)
        XCTAssertGreaterThan(family.utf16.count, 1)

        XCTAssertEqual(AIPreviewWordDiff.tokens(in: "x\(flag)y"), ["x\(flag)y"])
        XCTAssertEqual(AIPreviewWordDiff.tokens(in: "x\(flag)y").first?.count, 3)
        XCTAssertEqual(AIPreviewWordDiff.tokens(in: ideograph), [ideograph])

        let original = "see \(ideograph) and \(flag) \(family) now"
        let updated = "saw \(ideograph) and \(flag) \(family) then"
        let changes = AIPreviewWordDiff.changes(from: original, to: updated)
        assertRoundTrip(original, updated, changes)
        for mark in [ideograph, flag, family] {
            let holders = changes.filter { change in
                if case .equal(let text) = change { return text.contains(mark) }
                return false
            }
            XCTAssertEqual(holders.count, 1, mark)
        }
    }

    func testANewlineIsItsOwnWhitespaceToken() {
        XCTAssertEqual(AIPreviewWordDiff.tokens(in: "a\nb"), ["a", "\n", "b"])
    }

    func testRenderedDiffMarksTheEditInline() {
        let rendered = AIPreviewWordDiff.attributed(from: "alpha beta", to: "alpha gamma")
        XCTAssertEqual(rendered.string, "alpha betagamma")
        XCTAssertFalse(rendered.string.contains("\u{2212}"))
        XCTAssertFalse(rendered.string.contains("\n"))

        let full = rendered.string as NSString
        let beta = full.range(of: "beta")
        var struck = false
        rendered.enumerateAttribute(.strikethroughStyle, in: beta) { value, _, _ in
            if let style = value as? Int, style == NSUnderlineStyle.single.rawValue {
                struck = true
            }
        }
        XCTAssertTrue(struck)

        let gamma = full.range(of: "gamma")
        var inserted = false
        rendered.enumerateAttribute(.foregroundColor, in: gamma) { value, _, _ in
            if value != nil { inserted = true }
        }
        XCTAssertTrue(inserted)
    }

    func testEveryKindIsOfferedTheDiffWhenTheTextChanges() {
        let rewrite = AITransformKind.allCases.filter(\.isRewriteStyle)
        XCTAssertFalse(rewrite.isEmpty)
        for kind in AITransformKind.allCases {
            XCTAssertTrue(
                AIPreviewWordDiff.offersDiff(kind: kind, input: "alpha beta", result: "alpha gamma"),
                kind.rawValue
            )
            XCTAssertFalse(AIPreviewWordDiff.offersDiff(kind: kind, input: "same", result: "same"))
            XCTAssertFalse(AIPreviewWordDiff.offersDiff(kind: kind, input: "alpha", result: ""))
        }
        for kind in rewrite {
            XCTAssertTrue(
                AIPreviewWordDiff.offersDiff(kind: kind, input: "one two", result: "one three"),
                "rewrite-style \(kind.rawValue)"
            )
        }
        XCTAssertTrue(AIPreviewWordDiff.offersDiff(kind: .proofread, input: "teh", result: "the"))
        XCTAssertTrue(AIPreviewWordDiff.offersDiff(kind: .toTable, input: "a, b", result: "| a | b |"))
    }

    private func assertRoundTrip(
        _ original: String,
        _ updated: String,
        _ changes: [AIPreviewWordDiff.Change],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(AIPreviewWordDiff.originalText(of: changes), original, file: file, line: line)
        XCTAssertEqual(AIPreviewWordDiff.updatedText(of: changes), updated, file: file, line: line)
    }
}
