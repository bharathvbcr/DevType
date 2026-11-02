import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import ExpanderEngine

/// Three delivery bugs that share the post-erase path:
/// a pid-only continue must not finish an expansion in a different control of the same process,
/// a partial Unicode insert must fall through to the clipboard instead of recording the full
/// string, and a swallowed undo delete is posted only when freshness is the only thing that failed.
final class InjectionFocusAndUndoRecoveryTests: XCTestCase {

    private let cursorLikeBundle = "com.microsoft.vscode.injection-harness.\(UUID().uuidString)"
    private let heldDelete = SwallowedKey(
        didSwallow: true, unicode: "\u{7F}", keyCode: Int64(kVK_Delete), flags: []
    )

    // MARK: - Same-process focus

    /// AXComboBox skips CFEqual after the erase. A pid match is not permission to keep posting
    /// into whatever control of that process is focused now.
    func testADifferentControlInTheSameProcessDoesNotReceiveTheRestOfAComboBoxExpansion() throws {
        let harness = try InjectionHarness()
        let fieldKey = harness.page.key(harness.field)
        let elsewhereKey = harness.page.key(harness.elsewhere)
        harness.page.roles[fieldKey] = "AXComboBox"
        harness.page.frames[elsewhereKey] = CGRect(x: 900, y: 40, width: 180, height: 28)
        harness.page.roles[elsewhereKey] = "AXTextArea"
        harness.page.values[elsewhereKey] = "do not touch this field"
        harness.page.selections[elsewhereKey] = NSRange(location: 23, length: 0)
        harness.onBackspace = { harness, count in
            guard count == 1 else { return }
            harness.page.focused = harness.elsewhere
        }

        let run = harness.typeExpansion(in: self, trigger: "`slm", lead: "say: ", result: "Sincerely, Slim")

        XCTAssertEqual(harness.backspaces, 1, "only the key posted before focus moved: \(harness.timeline)")
        XCTAssertEqual(harness.page.value(of: harness.elsewhere), "do not touch this field", harness.timeline)
        XCTAssertEqual(harness.chords, 0, "the replacement must not be pasted into the other control")
        guard case .refused = run.outcome else {
            XCTFail("expected a refusal, got \(String(describing: run.outcome)) \(harness.timeline)")
            return
        }
        XCTAssertNil(harness.pipeline.lastExpansion)
    }

    /// The same combo box replacing its AX node, at the same frame, still gets the expansion.
    /// CFEqual is not required: the replacement's AXValue is the selected item, not the trigger.
    func testAComboBoxNodeAtTheSameFrameStillReceivesTheExpansion() throws {
        let harness = try InjectionHarness()
        let fieldKey = harness.page.key(harness.field)
        let replacementKey = harness.page.key(harness.replacementNode)
        harness.page.roles[fieldKey] = "AXComboBox"
        harness.page.roles[replacementKey] = "AXComboBox"
        harness.page.frames[replacementKey] = harness.frame
        harness.page.values[replacementKey] = "Apple\u{00A0}"
        harness.page.selections[replacementKey] = NSRange(location: 6, length: 0)
        harness.onBackspace = { harness, count in
            guard count == 1 else { return }
            harness.page.focused = harness.replacementNode
        }

        let run = harness.typeExpansion(in: self, trigger: "`slm", lead: "say: ", result: "Sincerely, Slim")

        if case .refused = run.outcome {
            XCTFail("a same-frame combo-box node must not refuse: \(harness.timeline)")
        }
        XCTAssertGreaterThan(harness.chords, 0, harness.timeline)
        XCTAssertTrue(
            harness.page.value(of: harness.replacementNode)?.contains("Sincerely, Slim") == true,
            "the expansion follows the replacement node: \(String(describing: harness.page.value(of: harness.replacementNode)))"
        )
    }

    // MARK: - Partial Unicode

    /// Cursor-class hosts type the expansion. A post that stops after the first character must
    /// not record `postedUnverified` for the whole string and skip the clipboard.
    func testAPartialUnicodeInsertDoesNotRecordTheFullString() throws {
        let harness = try InjectionHarness()
        harness.frontmostBundleID = cursorLikeBundle
        var unicodePosts = 0
        harness.onPostedKey = { harness, code in
            guard code == 0 else { return }
            unicodePosts += 1
            if unicodePosts == 1 { harness.canPostEvents = false }
        }

        let run = harness.typeExpansion(in: self, result: "Sincerely, Slim")

        XCTAssertGreaterThan(unicodePosts, 0, "the unicode path did not run: \(harness.timeline)")
        XCTAssertNotEqual(run.outcome, .postedUnverified, harness.timeline)
        XCTAssertNil(
            harness.pipeline.lastExpansion,
            "a partial post must not store the full expansion as undo"
        )
        XCTAssertNotEqual(harness.pipeline.lastExpansion?.injectedText, "Sincerely, Slim")
    }

    /// The characters that did post stay in the field. Recovery pastes the rest, not the whole
    /// expansion, so the prefix is not inserted a second time. Undo then names the expansion the
    /// field actually holds.
    func testAPartialUnicodeInsertPastesOnlyTheUnpostedSuffix() throws {
        let harness = try InjectionHarness()
        harness.frontmostBundleID = cursorLikeBundle
        harness.landUnicodeKeys = true
        var unicodePosts = 0
        harness.onPostedKey = { harness, code in
            guard code == 0 else { return }
            unicodePosts += 1
            if unicodePosts == 1 { harness.failTheNextPost = true }
        }

        let result = "Sincerely, Slim"
        let run = harness.typeExpansion(in: self, result: result)

        XCTAssertEqual(unicodePosts, 1, "the burst must stop after the first character: \(harness.timeline)")
        XCTAssertEqual(run.text, "say: \(result)", harness.timeline)
        XCTAssertEqual(harness.pipeline.lastExpansion?.injectedText, result)
    }

    /// Nothing posted is the existing fall-through. Disabling Post Events after the erase, and
    /// before any unicode key, must still not record a unicode success.
    func testAUnicodeInsertThatPostsNothingDoesNotRecordSuccess() throws {
        let harness = try InjectionHarness()
        harness.frontmostBundleID = cursorLikeBundle
        let triggerLength = ("`slm" as NSString).length
        harness.onFocusRead = { harness in
            if harness.backspaces >= triggerLength { harness.canPostEvents = false }
        }

        let run = harness.typeExpansion(in: self, trigger: "`slm", result: "Sincerely, Slim")

        XCTAssertFalse(harness.log.contains(.key(0)), "no unicode key should have been posted: \(harness.timeline)")
        XCTAssertNotEqual(run.outcome, .postedUnverified, harness.timeline)
        XCTAssertNil(harness.pipeline.lastExpansion)
    }

    /// A full unicode post stays `postedUnverified`. That outcome is out of scope for the partial-insert fix.
    func testACompleteUnicodeInsertMayStayPostedUnverified() throws {
        let harness = try InjectionHarness()
        harness.frontmostBundleID = cursorLikeBundle

        let run = harness.typeExpansion(in: self, result: "Sincerely, Slim")

        XCTAssertEqual(run.outcome, .postedUnverified, harness.timeline)
        XCTAssertEqual(harness.pipeline.lastExpansion?.injectedText, "Sincerely, Slim")
        XCTAssertEqual(harness.chords, 0, "a complete unicode post does not fall through to the clipboard")
    }

    func testPreflightUndoReturnsTheHeldKeyOnlyForAFreshnessFailure() {
        XCTAssertEqual(
            ExpansionUndoPolicy.preflightUndo(
                fresh: true, attemptCurrent: true, targetCurrent: true,
                processTrusted: true, secureInputActive: false
            ),
            .proceed
        )
        XCTAssertEqual(
            ExpansionUndoPolicy.preflightUndo(
                fresh: false, attemptCurrent: true, targetCurrent: true,
                processTrusted: true, secureInputActive: false
            ),
            .refuse(returnHeldBackspace: true)
        )
        let blocked: [(Bool, Bool, Bool, Bool, Bool)] = [
            (false, false, true, true, false),
            (false, true, false, true, false),
            (false, true, true, false, false),
            (false, true, true, true, true),
            (true, false, true, true, false),
            (true, true, false, true, false),
            (true, true, true, false, false),
            (true, true, true, true, true),
        ]
        for row in blocked {
            XCTAssertEqual(
                ExpansionUndoPolicy.preflightUndo(
                    fresh: row.0, attemptCurrent: row.1, targetCurrent: row.2,
                    processTrusted: row.3, secureInputActive: row.4
                ),
                .refuse(returnHeldBackspace: false),
                "\(row)"
            )
        }
    }

    // MARK: - Freshness-only undo

    func testAFreshnessOnlyUndoPostsTheSwallowedDelete() throws {
        let harness = try InjectionHarness()
        let attempt = try staleAttempt(in: harness)
        harness.resetLog()

        harness.pipeline.performUndo(attempt, heldBackspace: heldDelete)

        XCTAssertGreaterThan(harness.backspaces, 0, "the swallowed delete is owed when only freshness failed: \(harness.timeline)")
    }

    func testAContextChangeDoesNotReplayTheSwallowedUndoDelete() throws {
        let cases: [(String, (InjectionHarness) -> Void)] = [
            ("input revision", { $0.pipeline.noteInputAfterExpansion() }),
            ("other process", { $0.frontmostPID = InjectionHarness.hostPID + 1 }),
            ("untrusted", { $0.trusted = false }),
            ("secure input", { $0.secureInput = true }),
        ]
        for (name, mutate) in cases {
            let harness = try InjectionHarness()
            let attempt = try staleAttempt(in: harness)
            mutate(harness)
            harness.resetLog()
            harness.pipeline.performUndo(attempt, heldBackspace: heldDelete)
            XCTAssertEqual(harness.backspaces, 0, "\(name) must not replay the delete: \(harness.timeline)")
        }

        let harness = try InjectionHarness()
        let attempt = try staleAttempt(in: harness)
        harness.resetLog()
        harness.pipeline.performUndo(
            attempt,
            heldBackspace: SwallowedKey(didSwallow: false, unicode: "\u{7F}", keyCode: Int64(kVK_Delete))
        )
        XCTAssertEqual(harness.backspaces, 0, "a key that was not swallowed is not posted")
    }

    // MARK: - Helpers

    /// A claimed undo whose generation, revision and target are still current, with a record
    /// older than the undo window. `takeUndoAttempt` itself refuses a stale record, so the
    /// staleness is applied after the claim — the same shape as a record that expires on the
    /// way to the main queue.
    private func staleAttempt(in harness: InjectionHarness) throws -> TextInjectionPipeline.UndoAttempt {
        harness.pipeline.recordUndoExpansion(
            .init(
                erasePlan: ErasePlan(text: "ab"),
                injectedText: "expanded",
                triggerText: "abc",
                bundleID: harness.frontmostBundleID
            ),
            target: .init(pid: InjectionHarness.hostPID, element: harness.field, range: nil)
        )
        let claimed = try XCTUnwrap(
            harness.pipeline.takeUndoAttempt(now: Date(), frontmostPID: InjectionHarness.hostPID)
        )
        let stale = TextInjectionPipeline.LastExpansion(
            erasePlan: claimed.record.erasePlan,
            injectedText: claimed.record.injectedText,
            triggerText: claimed.record.triggerText,
            bundleID: claimed.record.bundleID,
            timestamp: Date().addingTimeInterval(-(InjectTiming.undoWindowCeiling + 1))
        )
        return TextInjectionPipeline.UndoAttempt(
            record: stale,
            target: claimed.target,
            inputEvents: claimed.inputEvents,
            inputRevision: claimed.inputRevision,
            generation: claimed.generation
        )
    }
}
