import XCTest
@testable import ExpanderEngine

/// Regression coverage for the "expansion deleted the previous N characters" class of bug.
///
/// Two independent defects produced it:
///  1. UTF-16 counts were handed to the HID backspace path, which deletes *grapheme clusters*.
///  2. A failed AX range replace left its widened selection behind, so backspace #1 consumed the
///     selection and the remaining backspaces ate the user's preceding text.
final class EraseSafetyTests: XCTestCase {

    // MARK: - ErasePlan unit math

    func testASCIITriggerCountsAgreeInBothUnits() {
        let plan = ErasePlan(text: "addr")
        XCTAssertEqual(plan.utf16Count, 4)
        XCTAssertEqual(plan.backspaceCount, 4)
    }

    /// The original bug: an astral-plane trigger is 2 UTF-16 units but 1 backspace.
    /// Sending the UTF-16 count as backspaces deletes one character of the user's text.
    func testAstralTriggerSplitsUnits() {
        let plan = ErasePlan(text: "👍")
        XCTAssertEqual(plan.utf16Count, 2, "AX ranges are UTF-16")
        XCTAssertEqual(plan.backspaceCount, 1, "backspace removes one grapheme cluster")
    }

    func testCombiningMarksCountAsOneBackspace() {
        // "é" as e + U+0301 — two scalars, one grapheme.
        let plan = ErasePlan(text: "e\u{0301}")
        XCTAssertEqual(plan.utf16Count, 2)
        XCTAssertEqual(plan.backspaceCount, 1)
    }

    func testFlagEmojiTriggerIsOneBackspace() {
        let plan = ErasePlan(text: "🇯🇵")
        XCTAssertEqual(plan.utf16Count, 4)
        XCTAssertEqual(plan.backspaceCount, 1)
    }

    // MARK: - ErasePlan.forMatch

    func testTerminatorMatchErasesWholeTrigger() {
        let plan = ErasePlan.forMatch(
            matchedTrigger: "addr",
            terminator: " ",
            swallowedFinalKey: true,
            swallowedUnicode: " "
        )
        XCTAssertEqual(plan.expectedText, "addr")
        XCTAssertEqual(plan.utf16Count, 4)
        XCTAssertEqual(plan.backspaceCount, 4)
    }

    func testInstantMatchDropsSwallowedFinalKey() {
        // ";sig" fires on the final "g", which the tap swallowed — the field still holds ";si".
        let plan = ErasePlan.forMatch(
            matchedTrigger: ";sig",
            terminator: "",
            swallowedFinalKey: true,
            swallowedUnicode: "g"
        )
        XCTAssertEqual(plan.expectedText, ";si")
        XCTAssertEqual(plan.utf16Count, 3)
    }

    func testSingleCharacterInstantMatchErasesNothing() {
        let plan = ErasePlan.forMatch(
            matchedTrigger: "x",
            terminator: "",
            swallowedFinalKey: true,
            swallowedUnicode: "x"
        )
        XCTAssertTrue(plan.isEmpty)
    }

    func testMultiUnitSwallowedKeyIsTrimmedWhole() {
        let plan = ErasePlan.forMatch(
            matchedTrigger: "ab👍",
            terminator: "",
            swallowedFinalKey: true,
            swallowedUnicode: "👍"
        )
        XCTAssertEqual(plan.expectedText, "ab")
        XCTAssertEqual(plan.utf16Count, 2)
        XCTAssertEqual(plan.backspaceCount, 2)
    }

    func testCountedPlanHasNoExpectedText() {
        let plan = ErasePlan.counted(3)
        XCTAssertNil(plan.expectedText)
        XCTAssertEqual(plan.utf16Count, 3)
        XCTAssertEqual(plan.backspaceCount, 3)
    }

    // MARK: - Precondition guard

    func testPreconditionPassesWhenTriggerIsLeftOfCaret() {
        let plan = ErasePlan(text: "addr")
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "my addr",
            caretLocation: 7,
            selectionLength: 0
        )
        XCTAssertEqual(result, .ok)
    }

    /// The load-bearing test: caret is not after the trigger, so erasing would eat user text.
    func testPreconditionBlocksWhenFieldHoldsSomethingElse() {
        let plan = ErasePlan(text: "addr")
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "hello world",
            caretLocation: 11,
            selectionLength: 0
        )
        XCTAssertTrue(result.blocksErase)
    }

    /// Field is long enough to hold the trigger, but the caret sits too close to the start — the
    /// field is readable and genuinely disagrees with us, so block.
    func testPreconditionBlocksWhenCaretLeavesNoRoom() {
        let plan = ErasePlan(text: "addr")
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "abcdefgh",
            caretLocation: 2,
            selectionLength: 0
        )
        XCTAssertTrue(result.blocksErase)
    }

    /// Chromium / Electron contenteditable hosts report an empty AXValue with a caret at 0. That is
    /// a virtualised snapshot, not a disagreement — blocking here would kill expansion in exactly
    /// the apps the seed list targets.
    func testEmptyReportedValueDegradesRatherThanBlocking() {
        let plan = ErasePlan(text: "addr")
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "",
            caretLocation: 0,
            selectionLength: 0
        )
        XCTAssertFalse(result.blocksErase)
    }

    /// A caret past the end of the reported value means AX gave us a partial snapshot (Chromium /
    /// Electron virtualised text views). That is not evidence of wrong text — degrade, do not block,
    /// or expansions would stop working entirely in those apps.
    func testCaretBeyondValueDegradesRatherThanBlocking() {
        let plan = ErasePlan(text: "addr")
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "my addr",
            caretLocation: 99,
            selectionLength: 0
        )
        XCTAssertFalse(result.blocksErase)
    }

    func testPreexistingUserSelectionIsAllowed() {
        let plan = ErasePlan(text: "addr")
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "my addr and more",
            caretLocation: 7,
            selectionLength: 5
        )
        XCTAssertEqual(result, .ok)
    }

    func testPreconditionHonoursCaseInsensitiveSnippets() {
        let plan = ErasePlan(text: "addr", caseInsensitive: true)
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "my ADDR",
            caretLocation: 7,
            selectionLength: 0
        )
        XCTAssertEqual(result, .ok)
    }

    func testPreconditionIsStrictForCaseSensitiveSnippets() {
        let plan = ErasePlan(text: "addr", caseInsensitive: false)
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "my ADDR",
            caretLocation: 7,
            selectionLength: 0
        )
        XCTAssertTrue(result.blocksErase)
    }

    /// AX-opaque hosts must not be blocked — degrade to best-effort, as before.
    func testPreconditionDegradesWhenAXCannotRead() {
        let plan = ErasePlan(text: "addr")
        XCTAssertFalse(
            ErasePreconditionChecker.evaluate(
                plan: plan, value: nil, caretLocation: 4, selectionLength: 0
            ).blocksErase
        )
        XCTAssertFalse(
            ErasePreconditionChecker.evaluate(
                plan: plan, value: "my addr", caretLocation: nil, selectionLength: nil
            ).blocksErase
        )
    }

    /// Physical-Hangul matches carry no comparable text — never block them.
    func testPreconditionDegradesForCountOnlyPlans() {
        let result = ErasePreconditionChecker.evaluate(
            plan: .counted(3),
            value: "안녕하세요",
            caretLocation: 5,
            selectionLength: 0
        )
        XCTAssertFalse(result.blocksErase)
    }

    func testEmptyErasePlanAlwaysPasses() {
        let result = ErasePreconditionChecker.evaluate(
            plan: .empty,
            value: nil,
            caretLocation: nil,
            selectionLength: nil
        )
        XCTAssertEqual(result, .ok)
    }

    func testPreconditionUsesUTF16OffsetsNotCharacterOffsets() {
        // "👍" occupies units 0..<2, so a caret at 6 sits right after "addr".
        let plan = ErasePlan(text: "addr")
        let result = ErasePreconditionChecker.evaluate(
            plan: plan,
            value: "👍addr",
            caretLocation: 6,
            selectionLength: 0
        )
        XCTAssertEqual(result, .ok)
    }

    // MARK: - AX write capability learning

    func testSeededChromiumAppsSkipAXWrites() {
        XCTAssertEqual(
            AXWriteCapabilityStore.seedVerdict(bundleID: "com.google.Chrome"), .falseSuccess
        )
        XCTAssertEqual(
            AXWriteCapabilityStore.seedVerdict(bundleID: "com.todesktop.230313mzl4w4u92"), .falseSuccess
        )
        XCTAssertEqual(
            AXWriteCapabilityStore.seedVerdict(bundleID: "com.github.githubapp"), .falseSuccess
        )
        XCTAssertEqual(AXWriteCapabilityStore.seedVerdict(bundleID: "com.apple.Notes"), .unknown)
    }

    /// An unknown app that lies once is condemned for the rest of the session — this is what makes
    /// the fix general instead of a growing allowlist.
    func testUnknownAppIsLearnedAfterOneFalseSuccess() {
        let store = AXWriteCapabilityStore()
        let bundleID = "com.example.SomeNewElectronApp"
        XCTAssertFalse(store.shouldSkipAXSelectedText(bundleID: bundleID))
        store.recordFalseSuccess(bundleID: bundleID)
        XCTAssertTrue(store.shouldSkipAXSelectedText(bundleID: bundleID))
    }

    func testVerifiedAppStaysTrusted() {
        let store = AXWriteCapabilityStore()
        let bundleID = "com.example.WellBehavedApp"
        store.recordTrusted(bundleID: bundleID)
        XCTAssertEqual(store.verdict(for: bundleID), .trusted)
        XCTAssertFalse(store.shouldSkipAXSelectedText(bundleID: bundleID))
    }

    func testCondemnedAppNeedsAStreakToBeRehabilitated() {
        let store = AXWriteCapabilityStore()
        let bundleID = "com.example.FlakyApp"
        store.recordFalseSuccess(bundleID: bundleID)
        for _ in 0..<(AXWriteCapabilityStore.trustedStreakToRehabilitate - 1) {
            store.recordTrusted(bundleID: bundleID)
            XCTAssertTrue(store.shouldSkipAXSelectedText(bundleID: bundleID))
        }
        store.recordTrusted(bundleID: bundleID)
        XCTAssertFalse(store.shouldSkipAXSelectedText(bundleID: bundleID))
    }

    func testResetClearsLearnedVerdicts() {
        let store = AXWriteCapabilityStore()
        store.recordFalseSuccess(bundleID: "com.example.App")
        store.reset()
        XCTAssertEqual(store.verdict(for: "com.example.App"), .unknown)
    }

    // MARK: - Matched text threading

    func testMatcherCarriesUserTypedCasing() {
        let snippet = SnippetModel(
            title: "Address",
            triggerKeyword: "addr",
            replacementText: "1 Main St",
            isCaseSensitive: false,
            requireWordBoundary: false
        )
        let matcher = AbbreviationMatcher(snippets: [snippet])
        let match = matcher.match(buffer: "ADDR")
        XCTAssertEqual(match?.matchedText, "ADDR", "must reflect the field, not the stored keyword")
    }

    func testMatcherMatchedTextExcludesTerminator() {
        let snippet = SnippetModel(
            title: "Signature",
            triggerKeyword: "sig",
            replacementText: "Best,",
            isCaseSensitive: false,
            requireWordBoundary: true
        )
        let matcher = AbbreviationMatcher(snippets: [snippet])
        let match = matcher.match(buffer: "sig ")
        XCTAssertEqual(match?.matchedText, "sig")
        XCTAssertEqual(match?.terminator, " ")
    }
}
