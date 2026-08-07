import XCTest
@testable import ExpanderEngine

/// Regression coverage for the "expansion deleted the previous N characters" class of bug.
///
/// Two independent defects produced it:
///  1. UTF-16 counts were handed to the HID backspace path, which deletes *grapheme clusters*.
///  2. A failed AX range replace left its widened selection behind, so backspace #1 consumed the
///     selection and the remaining backspaces ate the user's preceding text.
final class EraseSafetyTests: XCTestCase {

    // MARK: - §8.6 caret-geometry corroboration (Claude Desktop incident, 2026-08-07)

    /// The field incident, byte for byte: the user typed `` `rtes ``, and Electron returned a
    /// content-accurate AXValue with a caret indexing a different coordinate space — the 5-unit
    /// slice read "round" (the tail of "background") while the typed trigger sat elsewhere in
    /// the value. A mismatch is only trustworthy when the position-independent read agrees the
    /// trigger is absent; here it does not, so the gate must degrade to the AX-opaque
    /// best-effort baseline instead of refusing the expansion.
    func testMismatchedSliceWithTriggerPresentDegradesToUnavailable() {
        let value = "type `rtes in the background"
        let caret = value.utf16.count   // slice of the last 5 units reads "round"
        let result = ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: "`rtes"),
            value: value,
            caretLocation: caret,
            selectionLength: 0
        )
        guard case .unavailable(let why) = result else {
            return XCTFail("Geometry is the liar, not the field — expected .unavailable, got \(result)")
        }
        XCTAssertTrue(why.contains("geometry"), "The reason must name the untrusted caret geometry.")
    }

    /// The refusal this guard exists for must survive the corroboration: trigger nowhere in the
    /// value means the field genuinely changed — refuse, never blind-erase.
    func testMismatchWithTriggerAbsentStillRefuses() {
        let value = "completely different prose"
        let result = ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: "`rtes"),
            value: value,
            caretLocation: value.utf16.count,
            selectionLength: 0
        )
        guard case .mismatch = result else {
            return XCTFail("Trigger absent from the value — the refusal must stand, got \(result)")
        }
    }

    /// Case-insensitive plans corroborate with the same folding the slice comparison uses.
    func testCaseInsensitiveCorroborationFoldsCase() {
        let value = "note `RTES somewhere later words"
        let result = ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: "`rtes", caseInsensitive: true),
            value: value,
            caretLocation: value.utf16.count,
            selectionLength: 0
        )
        guard case .unavailable = result else {
            return XCTFail("Folded corroboration must see `RTES, got \(result)")
        }
    }

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
        XCTAssertEqual(
            AXWriteCapabilityStore.seedVerdict(bundleID: "net.whatsapp.WhatsApp"), .falseSuccess,
            "WhatsApp Desktop AXTextArea lies on selected-text write — seed HID paste"
        )
        XCTAssertEqual(
            AXWriteCapabilityStore.seedVerdict(bundleID: "net.whatsapp.WhatsApp.beta"), .falseSuccess
        )
        XCTAssertEqual(AXWriteCapabilityStore.seedVerdict(bundleID: "com.apple.Notes"), .unknown)
    }

    // MARK: - Chromium installed web apps (PWAs)

    /// The field report: a GitHub PWA installed from Chrome carries the fresh bundle ID
    /// `com.google.Chrome.app.<32-char id>` — same renderer, same lying AX, but unknown to every
    /// list. It took the AX write path, the write could not be verified, and the expand was
    /// refused. Canonicalization maps the wrapper back to its host browser.
    func testChromiumPWACollapsesToItsHostBrowser() {
        let pwa = "com.google.Chrome.app.mjoklplbddabcmpepnokjaffbmgbkkgg"
        XCTAssertEqual(AXWriteCapabilityStore.canonicalBundleID(pwa), "com.google.Chrome")
        XCTAssertEqual(
            AXWriteCapabilityStore.canonicalBundleID(
                "com.microsoft.edgemac.app.abcdefghijklmnopabcdefghijklmnop"
            ),
            "com.microsoft.edgemac"
        )
        // The canonical ID hits the seed list, so the store's verdict skips the AX write.
        XCTAssertEqual(AXWriteCapabilityStore().verdict(for: pwa), .falseSuccess)
        // And the raw static seed check agrees, for callers that do not canonicalize.
        XCTAssertEqual(AXWriteCapabilityStore.seedVerdict(bundleID: pwa), .falseSuccess)
        XCTAssertTrue(
            SelectionReader.isWeakAXApp(bundleID: pwa),
            "The selection paths share the verdict: a PWA's cached selection is as "
                + "untrustworthy as its parent browser's."
        )
    }

    /// The 32×[a–p] shape is what keeps ordinary reverse-DNS IDs out. A bundle ID that merely
    /// contains ".app." must pass through untouched.
    func testOrdinaryBundleIDsAreNotMisreadAsPWAs() {
        for id in [
            "com.example.app.metrics",                                   // suffix not 32 chars
            "com.example.app.abcdefghijklmnopabcdefghijklmnoz",          // 'z' outside a–p
            "com.example.app.ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP",          // uppercase
            ".app.abcdefghijklmnopabcdefghijklmnop",                     // nothing before marker
            "com.example.application",                                   // no ".app." segment
        ] {
            XCTAssertEqual(
                AXWriteCapabilityStore.canonicalBundleID(id), id,
                "\(id) must not be collapsed"
            )
        }
        XCTAssertEqual(
            AXWriteCapabilityStore.seedVerdict(bundleID: "com.example.app.metrics"), .unknown
        )
    }

    /// Safari's "Add to Dock" web apps use a different wrapper shape — `com.apple.Safari.WebApp.`
    /// + UUID — and must collapse to Safari's seeded verdict the same way Chromium PWAs collapse
    /// to their browser's.
    func testSafariWebAppsCollapseToSafari() {
        let webApp = "com.apple.Safari.WebApp.E1A2B3C4-D5E6-47F8-9A0B-C1D2E3F4A5B6"
        XCTAssertEqual(AXWriteCapabilityStore.canonicalBundleID(webApp), "com.apple.Safari")
        XCTAssertEqual(AXWriteCapabilityStore.seedVerdict(bundleID: webApp), .falseSuccess)
        XCTAssertTrue(SelectionReader.isWeakAXApp(bundleID: webApp))

        // The UUID requirement is the guard against collateral collapse.
        let notAWebApp = "com.apple.Safari.WebApp.Helper"
        XCTAssertEqual(AXWriteCapabilityStore.canonicalBundleID(notAWebApp), notAWebApp)
        XCTAssertEqual(AXWriteCapabilityStore.seedVerdict(bundleID: notAWebApp), .unknown)
    }

    /// The escalating self-heal for unverifiable-after-write refusals: strike one warns,
    /// strike two condemns (persisted via the normal falseSuccess path), and a condemned app
    /// reports as such instead of accumulating further strikes.
    func testUnverifiableStrikesEscalateToCondemnation() {
        let store = AXWriteCapabilityStore()
        let bundleID = "com.example.FreshWebShell"
        let role = "AXTextArea"

        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(bundleID: bundleID, role: role),
            .struck(count: 1),
            "One observation is not proof — a transient (focus stolen mid-inject) looks the same."
        )
        XCTAssertFalse(
            store.shouldSkipAXSelectedText(bundleID: bundleID, role: role),
            "A single strike must not change behaviour yet."
        )
        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(bundleID: bundleID, role: role),
            .condemned
        )
        XCTAssertTrue(
            store.shouldSkipAXSelectedText(bundleID: bundleID, role: role),
            "After condemnation every expansion skips the AX write and goes straight to HID."
        )
        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(bundleID: bundleID, role: role),
            .alreadyCondemned
        )
    }

    /// Strikes canonicalize like everything else: one refusal inside a web app plus one inside
    /// its host browser is two strikes against the same identity, not one each against two.
    func testStrikesAccumulateAcrossAWebAppFamily() {
        let store = AXWriteCapabilityStore()
        let role = "AXTextArea"
        // A Chromium-shaped browser that is NOT in the seed list — a seeded one would report
        // alreadyCondemned before any strike could accumulate.
        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(
                bundleID: "org.example.NewChromium.app.abcdefghijklmnopabcdefghijklmnop",
                role: role
            ),
            .struck(count: 1)
        )
        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(
                bundleID: "org.example.NewChromium.app.ppppoooonnnnmmmmllllkkkkjjjjiiii",
                role: role
            ),
            .condemned,
            "A sibling web app's refusal is the same renderer failing the same way."
        )
        // And a seeded family reports alreadyCondemned outright — no strikes needed.
        XCTAssertEqual(
            store.recordUnverifiableAfterWrite(
                bundleID: "com.brave.Browser.app.abcdefghijklmnopabcdefghijklmnop",
                role: role
            ),
            .alreadyCondemned
        )
    }

    /// A lesson learned inside one web app must cover the browser and every sibling web app —
    /// and a verdict learned before canonicalization existed (stored under the raw wrapper ID)
    /// must still be honoured.
    func testVerdictsLearnedInOnePWACoverTheWholeFamily() {
        let store = AXWriteCapabilityStore()
        let role = "AXTextArea"
        store.recordFalseSuccess(
            bundleID: "com.vivaldi.Vivaldi.app.abcdefghijklmnopabcdefghijklmnop",
            role: role
        )
        XCTAssertTrue(
            store.shouldSkipAXSelectedText(bundleID: "com.vivaldi.Vivaldi", role: role),
            "The web app's lie is the browser's lie."
        )
        XCTAssertTrue(
            store.shouldSkipAXSelectedText(
                bundleID: "com.vivaldi.Vivaldi.app.ppppoooonnnnmmmmllllkkkkjjjjiiii",
                role: role
            ),
            "A sibling web app installed later must not re-pay the first false success."
        )
    }

    /// Role-keyed condemnation must be visible to the inject preferHID check when the same role is
    /// focused — otherwise WhatsApp keeps taking AX direct after erase and can "succeed" empty.
    func testRoleKeyedFalseSuccessIsHonouredWhenRoleIsKnown() {
        let store = AXWriteCapabilityStore()
        let learnedBundle = "com.example.RoleKeyedMessenger"
        let role = "AXTextArea"
        XCTAssertFalse(store.shouldSkipAXSelectedText(bundleID: learnedBundle))
        store.recordFalseSuccess(bundleID: learnedBundle, role: role)
        XCTAssertTrue(
            store.shouldSkipAXSelectedText(bundleID: learnedBundle, role: role),
            "composite (bundle|role) verdict must skip AX"
        )
        XCTAssertFalse(
            store.shouldSkipAXSelectedText(bundleID: learnedBundle, role: nil),
            "bundle-only query must not inherit a role-only condemnation"
        )
        XCTAssertFalse(
            store.shouldSkipAXSelectedText(bundleID: learnedBundle, role: "AXTextField"),
            "a different role stays eligible for AX"
        )
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
