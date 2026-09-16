import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

/// Replacing an AI request that is still running.
///
/// The reported bug: open a rewrite preview, pick a tone (or a different transform) while
/// it is still generating, and the result area goes blank — no spinner, no text, Replace
/// and Copy dead, and "Another AI transform is already running" pinned under it forever.
/// Three separate defects lined up to produce it:
///
///  1. `AITransformDiscardHandle.discard()` dropped the *result* without stopping the
///     *work*, so the abandoned generation kept `AITextTransformer`'s single-flight latch
///     and the replacement was refused `.busy` by the request it had just replaced.
///  2. `applyCompletion` hid the spinner and cleared the discard handle on its way to the
///     early return for `.discarded`, so the superseded request tore down the presentation
///     of the request that replaced it.
///  3. `applyPartial` only asked whether the panel was still open, never which request a
///     partial belonged to, so the replaced stream kept writing under the new title.
///
/// These drive the real on-device model, because the race only exists while a generation
/// is genuinely in flight. They skip with the actual reason when the model is unavailable —
/// a check that could not run must not look like a check that ran and passed.
@MainActor
final class AIPreviewSupersessionTests: XCTestCase {
    /// Long enough that generation outlives the interactions under test.
    private let selection = """
        we was discussing the api desing yesterday and it dont work as expcted, please take \
        a look at the retry logic and the timeout handling when you get a chance. also the \
        docs for the endpoint are out of date and the examples dont compile anymore, and the \
        staging cluster has been flaky since the migration landed last week.
        """

    private var previousLanguage: AppLanguage = .system

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        previousLanguage = LocalizationManager.shared.language
        LocalizationManager.shared.language = .en
        AIPreviewPanel.close()
    }

    override func tearDown() {
        AIPreviewPanel.close()
        LocalizationManager.shared.language = previousLanguage
        super.tearDown()
    }

    private func requireLiveModel() throws {
        if ProcessInfo.processInfo.environment["DEVTYPE_SKIP_LIVE_AI"] == "1" {
            throw XCTSkip("live model tests disabled by DEVTYPE_SKIP_LIVE_AI=1")
        }
        guard case .available = AITextTransformSupport.availability else {
            throw XCTSkip("model unavailable: \(AITextTransformSupport.availability)")
        }
    }

    // MARK: - Panel access

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func panel() throws -> NSPanel {
        try XCTUnwrap(
            NSApp.windows.compactMap { $0 as? NSPanel }
                .first { $0.isVisible && $0.contentView is GlassContainerView }
        )
    }

    /// Everything a user can see about "is this panel telling me anything".
    private struct Presentation {
        let text: String
        let showsText: Bool
        let showsSpinner: Bool
        let error: String?
        let title: String
        let canReplace: Bool
        /// Retry is enabled exactly once a generation ends, in success and in failure, so
        /// it — not the spinner — is what "this request is over" looks like. A streamed
        /// partial already hides the spinner while the answer is still arriving.
        let canRetry: Bool

        /// The panel is blank when it shows neither a result nor any sign of work.
        var isBlank: Bool { !showsText && !showsSpinner }
        var isFinished: Bool { canRetry }
    }

    private static func describe(_ presentation: Presentation) -> String {
        "spinner=\(presentation.showsSpinner) showsText=\(presentation.showsText) "
            + "finished=\(presentation.isFinished) error=\(presentation.error ?? "none") "
            + "title=\(presentation.title) canReplace=\(presentation.canReplace) "
            + "text=\(presentation.text.prefix(60).debugDescription)"
    }

    private func button(_ selector: String) throws -> NSButton {
        let views = descendants(of: try XCTUnwrap(panel().contentView))
        return try XCTUnwrap(views.compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString(selector) })
    }

    private func presentation() throws -> Presentation {
        let content = try XCTUnwrap(panel().contentView)
        content.layoutSubtreeIfNeeded()
        let views = descendants(of: content)
        let textView = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        let spinner = try XCTUnwrap(views.compactMap { $0 as? NSProgressIndicator }.first)
        let labels = views.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        let error = labels.map(\.stringValue).first { Self.knownErrors.contains($0) }
        let title = labels.map(\.stringValue).first { candidate in
            AITransformKind.builtInPalette
                .contains { kind in LocalizationManager.shared.s(kind.localizationKey) == candidate }
        } ?? ""

        let visibleText = (textView.enclosingScrollView?.isHidden ?? true) ? "" : textView.string
        return Presentation(
            text: textView.string,
            showsText: !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            showsSpinner: !spinner.isHidden,
            error: error,
            title: title,
            canReplace: try button("replaceTapped").isEnabled,
            canRetry: try button("retryTapped").isEnabled
        )
    }

    private static let knownErrors: Set<String> = {
        let loc = LocalizationManager.shared
        return Set([
            "ai.error.busy", "ai.error.emptyInput", "ai.error.missingInstructions",
            "ai.error.guardrail", "ai.error.contextWindow", "ai.error.rateLimited",
            "ai.error.language", "ai.error.assets", "ai.error.decoding", "ai.error.refusal",
            "ai.error.unsupportedGuide", "ai.error.languageDrift", "ai.error.unexpectedRewrite",
            "ai.error.promptEcho", "ai.error.discarded"
        ].map { loc.s($0) })
    }()

    private func popups() throws -> (tone: NSPopUpButton, kind: NSPopUpButton) {
        let found = descendants(of: try XCTUnwrap(panel().contentView)).compactMap { $0 as? NSPopUpButton }
        XCTAssertEqual(found.count, 2, "The preview header carries a tone menu and a kind menu")
        return (found[0], found[1])
    }

    private func pick(_ popup: NSPopUpButton, at index: Int) {
        popup.selectItem(at: index)
        _ = popup.target?.perform(popup.action, with: popup)
    }

    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Spins until `settled` holds, sampling the panel throughout so a transient blank
    /// frame is caught rather than averaged away.
    @discardableResult
    private func spinUntil(
        timeout: TimeInterval,
        samplingEvery interval: TimeInterval = 0.05,
        assertNeverBlank: Bool = true,
        settled: (Presentation) -> Bool
    ) throws -> Presentation {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try presentation()
        while Date() < deadline {
            latest = try presentation()
            if assertNeverBlank {
                XCTAssertFalse(
                    latest.isBlank,
                    "The preview showed neither a result nor any sign of work: "
                        + "error=\(latest.error ?? "none") text=\(latest.text.prefix(40).debugDescription)"
                )
            }
            if settled(latest) { return latest }
            spin(interval)
        }
        return latest
    }

    private func presentRewrite() {
        AIPreviewPanel.present(
            input: selection,
            kind: .rewrite,
            sourceApp: nil,
            clipboardWriter: { _ in true },
            onReplace: { _, _ in }
        )
    }

    // MARK: - The reported bug

    /// Picking a tone while the first generation is still in prefill used to leave the
    /// panel showing nothing at all, permanently.
    func testPickingAToneDuringGenerationNeverBlanksThePanel() throws {
        try requireLiveModel()
        presentRewrite()
        defer { AIPreviewPanel.close() }

        spin(0.25)
        let opening = try presentation()
        XCTAssertTrue(
            opening.showsSpinner || opening.showsText,
            "The first generation should be under way: \(Self.describe(opening))"
        )

        pick(try popups().tone, at: 1)  // Professional

        let settled = try spinUntil(timeout: 60) { $0.isFinished }
        XCTAssertTrue(settled.showsText, "The replacement generation has to produce a result")
        XCTAssertNil(settled.error, "A request that replaced its own predecessor is not busy")
        XCTAssertTrue(settled.canReplace)
    }

    /// The same race through the kind menu, which also has to end up showing the kind the
    /// user actually chose rather than the stream they replaced.
    func testPickingAnotherKindDuringGenerationShowsTheChosenKind() throws {
        try requireLiveModel()
        presentRewrite()
        defer { AIPreviewPanel.close() }

        spin(0.25)
        let kindPopup = try popups().kind
        let target = try XCTUnwrap(AITransformKind.builtInPalette.firstIndex(of: .condense))
        pick(kindPopup, at: target)

        let settled = try spinUntil(timeout: 60) { $0.isFinished }
        XCTAssertEqual(
            settled.title,
            LocalizationManager.shared.s(AITransformKind.condense.localizationKey),
            "The panel must be headed by the transform the user chose"
        )
        XCTAssertNil(settled.error)
        XCTAssertTrue(settled.showsText)
    }

    /// Switching to a transform DevType answers itself must not be poisoned by the model
    /// request it replaced: the local answer lands first and the abandoned stream's
    /// notifications arrive afterwards.
    func testSwitchingToALocalTransformMidGenerationKeepsItsOwnResult() throws {
        try requireLiveModel()
        AIPreviewPanel.present(
            input: "# Heading\n\nSome **bold** text that the model would happily rewrite.",
            kind: .rewrite,
            sourceApp: nil,
            clipboardWriter: { _ in true },
            onReplace: { _, _ in }
        )
        defer { AIPreviewPanel.close() }

        spin(0.25)
        let target = try XCTUnwrap(AITransformKind.builtInPalette.firstIndex(of: .removeMarkdown))
        pick(try popups().kind, at: target)

        let expected = "Heading\n\nSome bold text that the model would happily rewrite."
        XCTAssertEqual(try presentation().text, expected, "The local answer is synchronous")

        // Hold the panel open past the abandoned generation's own completion.
        try spinUntil(timeout: 20, assertNeverBlank: true) { _ in false }
        let after = try presentation()
        XCTAssertEqual(after.text, expected, "A superseded stream must not write into the panel")
        XCTAssertNil(after.error)
        XCTAssertTrue(after.canReplace)
    }

    /// Retry is offered as soon as a generation finishes; taking it immediately used to be
    /// refused by the generation that had only just stopped.
    func testRetryImmediatelyAfterAResultIsNotRefusedAsBusy() throws {
        try requireLiveModel()
        presentRewrite()
        defer { AIPreviewPanel.close() }

        try spinUntil(timeout: 60) { $0.isFinished }
        let retry = try XCTUnwrap(
            descendants(of: try XCTUnwrap(panel().contentView)).compactMap { $0 as? NSButton }
                .first { $0.action == NSSelectorFromString("retryTapped") }
        )
        XCTAssertTrue(retry.isEnabled)
        _ = retry.target?.perform(retry.action, with: retry)

        let settled = try spinUntil(timeout: 60) { $0.isFinished }
        XCTAssertNil(settled.error, "Retry must not be refused by the request it replaced")
        XCTAssertTrue(settled.showsText)
    }

    /// A second preview opened while the first is still generating — the same collision,
    /// across two panels rather than inside one.
    func testASecondPreviewOpenedDuringGenerationStillProducesAResult() throws {
        try requireLiveModel()
        presentRewrite()

        // Wait for the first request to be genuinely in flight — the collision only exists
        // once it holds the latch, so opening the second panel before that proves nothing.
        try spinUntil(timeout: 20) { $0.showsSpinner || $0.showsText }
        XCTAssertFalse(try presentation().isFinished, "The first generation must still be running")

        AIPreviewPanel.present(
            input: "fix the speling and grammer in this sentance please",
            kind: .proofread,
            sourceApp: nil,
            clipboardWriter: { _ in true },
            onReplace: { _, _ in }
        )
        defer { AIPreviewPanel.close() }

        let settled = try spinUntil(timeout: 60) { $0.isFinished }
        XCTAssertNil(settled.error, "A new preview must not be refused by the panel it replaced")
        XCTAssertTrue(settled.showsText)
    }

    /// A guard rather than a reproduction: Replace only becomes available once generation
    /// has finished, so the shipped `close(discard: false)` had nothing left to leak. It is
    /// kept because that is an invariant of the button's enablement, not of the close path —
    /// enable Replace on a partial and the leak is immediately reachable again.
    func testTransformRequestedRightAfterReplaceIsNotRefusedAsBusy() throws {
        try requireLiveModel()
        var replaced: String?
        AIPreviewPanel.present(
            input: selection,
            kind: .rewrite,
            sourceApp: nil,
            clipboardWriter: { _ in true },
            onReplace: { text, _ in replaced = text }
        )

        try spinUntil(timeout: 60) { $0.isFinished }
        let replace = try button("replaceTapped")
        XCTAssertTrue(replace.isEnabled)
        _ = replace.target?.perform(replace.action, with: replace)
        XCTAssertNotNil(replaced)

        AIPreviewPanel.present(
            input: "fix the speling and grammer in this sentance please",
            kind: .proofread,
            sourceApp: nil,
            clipboardWriter: { _ in true },
            onReplace: { _, _ in }
        )
        defer { AIPreviewPanel.close() }

        let settled = try spinUntil(timeout: 60) { $0.isFinished }
        XCTAssertNil(settled.error, "Accepting a result must release the model, not hold it")
        XCTAssertTrue(settled.showsText)
    }

    // MARK: - Stress

    /// Hammer the two menus while generation is in flight. Whatever the user does, the
    /// panel must never be left blank, and must always land on a result or an explanation.
    func testRapidMenuChangesUnderGenerationAlwaysLandOnSomething() throws {
        try requireLiveModel()
        presentRewrite()
        defer { AIPreviewPanel.close() }

        let kindTargets = [AITransformKind.condense, .formal, .friendly, .proofread, .rewrite]
            .compactMap { AITransformKind.builtInPalette.firstIndex(of: $0) }
        XCTAssertEqual(kindTargets.count, 5)

        for round in 0..<10 {
            spin(Double(round % 4) * 0.08 + 0.02)
            if round.isMultiple(of: 2) {
                pick(try popups().tone, at: round % 4)
            } else {
                pick(try popups().kind, at: kindTargets[round % kindTargets.count])
            }
            let now = try presentation()
            XCTAssertFalse(
                now.isBlank,
                "Round \(round): the panel went blank immediately after a menu change"
            )
        }

        // The last thing the user asked for was a real transform of a real selection, so the
        // storm has to end on that transform's answer — not on an error left behind by a
        // request they had already replaced.
        let settled = try spinUntil(timeout: 90) { $0.isFinished }
        XCTAssertTrue(settled.showsText, "After the storm: \(Self.describe(settled))")
        XCTAssertNil(settled.error, "After the storm: \(Self.describe(settled))")
        XCTAssertTrue(settled.canReplace, "After the storm: \(Self.describe(settled))")
    }

    /// Opening and closing preview after preview, each one abandoning the last mid-flight.
    func testRepeatedlyReplacingThePreviewNeverWedgesTheModel() throws {
        try requireLiveModel()
        for round in 0..<6 {
            AIPreviewPanel.present(
                input: selection,
                kind: round.isMultiple(of: 2) ? .rewrite : .proofread,
                sourceApp: nil,
                clipboardWriter: { _ in true },
                onReplace: { _, _ in }
            )
            spin(0.15)
            XCTAssertFalse(try presentation().isBlank, "Round \(round)")
        }
        defer { AIPreviewPanel.close() }

        let settled = try spinUntil(timeout: 90) { $0.isFinished }
        XCTAssertNil(settled.error, "Six preview swaps must not leave the model wedged")
        XCTAssertTrue(settled.showsText)
    }

    /// Cancelling mid-generation and immediately asking for another transform.
    func testCancellingMidGenerationFreesTheModelImmediately() throws {
        try requireLiveModel()
        presentRewrite()
        spin(0.3)

        let cancel = try XCTUnwrap(
            descendants(of: try XCTUnwrap(panel().contentView)).compactMap { $0 as? NSButton }
                .first { $0.action == NSSelectorFromString("cancelTapped") }
        )
        _ = cancel.target?.perform(cancel.action, with: cancel)

        AIPreviewPanel.present(
            input: "fix the speling and grammer in this sentance please",
            kind: .proofread,
            sourceApp: nil,
            clipboardWriter: { _ in true },
            onReplace: { _, _ in }
        )
        defer { AIPreviewPanel.close() }

        let settled = try spinUntil(timeout: 60) { $0.isFinished }
        XCTAssertNil(settled.error, "Cancel has to hand the model back")
        XCTAssertTrue(settled.showsText)
    }
}
