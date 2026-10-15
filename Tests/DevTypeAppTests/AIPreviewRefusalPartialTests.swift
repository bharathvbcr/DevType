import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

/// A streamed refusal must not stay insertable when generation fails as `.refusal`.
/// Any other failure still keeps a useful partial and leaves Replace enabled.
///
/// The panel's controller is private and `present` normally asks the on-device model,
/// so these drive `generationRunner` and never open a FoundationModels session.
@MainActor
final class AIPreviewRefusalPartialTests: XCTestCase {
    /// The selection `AIRefusalProseTests` uses for the documented openers. Unrelated
    /// to apologies, so "Sorry, I can't help…" is the model's words, not the author's.
    private let selection = "The quarterly revenue declined by four percent after the merger closed last spring."

    private var previousLanguage: AppLanguage = .system
    private var deliverPartial: (@Sendable (String?) -> Void)?
    private var deliverCompletion: (@Sendable (Result<String, AITransformError>) -> Void)?
    /// What Replace actually handed the insertion closure. Empty means it returned first.
    private var inserted: [String] = []
    /// What Copy / Replace-and-Copy handed the clipboard closure.
    private var copied: [String] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        previousLanguage = LocalizationManager.shared.language
        LocalizationManager.shared.language = .en
        AIPreviewPanel.close()
        deliverPartial = nil
        deliverCompletion = nil
        inserted = []
        copied = []
    }

    override func tearDown() {
        AIPreviewPanel.close()
        LocalizationManager.shared.language = previousLanguage
        deliverPartial = nil
        deliverCompletion = nil
        inserted = []
        copied = []
        super.tearDown()
    }

    func testRefusalFailureClearsStreamedTextAndDisablesReplace() throws {
        let refusal = "Sorry, I can't help with that."
        XCTAssertTrue(
            AIRefusalProse.detected(output: refusal, input: selection),
            "The fixture must be one AIRefusalProseTests already treats as a refusal"
        )
        try presentRewrite()
        try deliver(refusal, then: .failure(.refusal))

        let settled = try waitUntilFinished()
        XCTAssertEqual(settled.text, "", "A refusal must not remain in the text view")
        XCTAssertFalse(settled.showsText)
        XCTAssertFalse(settled.canReplace)
        XCTAssertFalse(try button("replaceAndCopyTapped").isEnabled)
        XCTAssertFalse(try button("copyTapped").isEnabled)
        XCTAssertEqual(settled.error, LocalizationManager.shared.s("ai.error.refusal"))
    }

    func testDecodingFailureKeepsUsefulPartialAndEnablesReplace() throws {
        let partial = "The quarterly revenue fell four percent after the merger closed last spring."
        XCTAssertFalse(AIRefusalProse.detected(output: partial, input: selection))
        try presentRewrite()
        try deliver(partial, then: .failure(.decodingFailure))

        let settled = try waitUntilFinished()
        XCTAssertEqual(settled.text, partial)
        XCTAssertTrue(settled.showsText)
        XCTAssertTrue(settled.canReplace)
        XCTAssertTrue(try button("replaceAndCopyTapped").isEnabled)
        XCTAssertTrue(try button("copyTapped").isEnabled)
        XCTAssertEqual(settled.error, LocalizationManager.shared.s("ai.error.decoding"))
    }

    /// The partial gate sees the stripped body. A fence is not a way past it, and the
    /// final screen still detects that body after sanitize and strip.
    func testStrippedFencedRefusalIsNotPublishable() {
        let fenced = "```\nSorry, I can't help with that.\n```"
        let stripped = AIMarkdownStripper.strip(fenced, policy: .strip, original: selection)
        XCTAssertNotEqual(stripped, fenced, "The fence markers have to come off before the gate sees the text")
        XCTAssertTrue(
            AIRefusalProse.detected(output: stripped, input: selection),
            "Stripping must leave a refusal AIRefusalProseTests would still catch"
        )
        XCTAssertFalse(AIStreamedPartial.isPublishable(stripped, input: selection))
    }

    /// "Sorry" is not yet a refusal. The finished sentence is. Refusal must wipe both,
    /// and the three insert actions must no-op even when invoked directly.
    func testShownPrefixThenFullRefusalClearsTextAndRejectsInsert() throws {
        let prefix = "Sorry"
        let refusal = "Sorry, I can't help with that."
        XCTAssertFalse(AIRefusalProse.detected(output: prefix, input: selection))
        XCTAssertTrue(AIRefusalProse.detected(output: refusal, input: selection))
        try presentRecording()
        try showPartial(prefix)
        try showPartial(refusal)

        let settled = try finish(.failure(.refusal))
        XCTAssertEqual(settled.text, "", "A refusal must wipe the text view, not only hide it")
        XCTAssertFalse(settled.showsText)
        XCTAssertFalse(settled.canReplace)
        XCTAssertFalse(try button("replaceAndCopyTapped").isEnabled)
        XCTAssertFalse(try button("copyTapped").isEnabled)
        XCTAssertEqual(settled.error, LocalizationManager.shared.s("ai.error.refusal"))

        try perform("replaceTapped")
        try perform("replaceAndCopyTapped")
        try perform("copyTapped")
        XCTAssertEqual(inserted, [], "replaceTapped must return before inserting the refusal")
        XCTAssertEqual(copied, [], "Copy must not write the refusal after it was cleared")
    }

    /// The same unflagged prefix, failed for a reason other than refusal, stays insertable.
    func testDecodingFailureKeepsSorryPrefixAndReplaceInsertsIt() throws {
        let prefix = "Sorry"
        let refusal = "Sorry, I can't help with that."
        XCTAssertFalse(AIRefusalProse.detected(output: prefix, input: selection))
        try presentRecording()
        try showPartial(prefix)

        let settled = try finish(.failure(.decodingFailure))
        XCTAssertEqual(settled.text, prefix)
        XCTAssertTrue(settled.canReplace)
        XCTAssertEqual(settled.error, LocalizationManager.shared.s("ai.error.decoding"))
        try perform("replaceTapped")
        XCTAssertEqual(inserted, [prefix], "Replace must insert the prefix, not a refusal")
        XCTAssertNotEqual(inserted.first, refusal)
        XCTAssertEqual(copied, [])
    }

    /// Guardrail and availability failures are not refusals. The useful partial stays.
    func testGuardrailAndUnavailableKeepUsefulPartial() throws {
        let partial = "The quarterly revenue fell four percent after the merger closed last spring."
        XCTAssertFalse(AIRefusalProse.detected(output: partial, input: selection))
        let failures: [AITransformError] = [
            .guardrailViolation,
            .unavailable(.unsupportedOS)
        ]
        for failure in failures {
            AIPreviewPanel.close()
            try presentRecording()
            try showPartial(partial)
            let settled = try finish(.failure(failure))
            XCTAssertEqual(settled.text, partial, "\(failure) must not clear a useful partial")
            XCTAssertTrue(settled.showsText)
            XCTAssertTrue(settled.canReplace)
            XCTAssertNotEqual(settled.error, LocalizationManager.shared.s("ai.error.refusal"))
            try perform("replaceTapped")
            XCTAssertEqual(inserted, [partial], "\(failure) must still insert the partial")
        }
    }

    /// A partial that arrives after the refusal clear must not repaint it, and the
    /// next panel must not inherit that generation's block.
    func testLatePartialAfterRefusalDoesNotReturnAndNextPanelDoesNotStick() throws {
        let refusal = "Sorry, I can't help with that."
        let useful = "The quarterly revenue fell four percent after the merger closed last spring."
        try presentRecording()
        try showPartial("Sorry")
        try showPartial(refusal)
        let cleared = try finish(.failure(.refusal))
        XCTAssertEqual(cleared.text, "")

        try XCTUnwrap(deliverPartial)(refusal)
        let late = try waitUntil(timeout: 0.5) { !$0.text.isEmpty || $0.canReplace }
        XCTAssertEqual(late.text, "", "A later partial on the same runner must not restore the refusal")
        XCTAssertFalse(late.showsText)
        XCTAssertFalse(late.canReplace)
        XCTAssertEqual(late.error, LocalizationManager.shared.s("ai.error.refusal"))
        try perform("replaceTapped")
        try perform("replaceAndCopyTapped")
        try perform("copyTapped")
        XCTAssertEqual(inserted, [])
        XCTAssertEqual(copied, [])

        AIPreviewPanel.close()
        try presentRecording()
        try showPartial(useful)
        let next = try finish(.failure(.decodingFailure))
        XCTAssertEqual(next.text, useful, "The previous refusalGeneration must not block the next panel")
        XCTAssertTrue(next.canReplace)
        XCTAssertEqual(next.error, LocalizationManager.shared.s("ai.error.decoding"))
        try perform("replaceTapped")
        XCTAssertEqual(inserted, [useful])
    }

    /// `.success` is not the refusal clear. The success text replaces the partial and Replace stays on.
    func testSuccessAfterRefusalLookingPartialShowsSuccessAndEnablesReplace() throws {
        let refusal = "Sorry, I can't help with that."
        let success = "The quarterly revenue fell four percent after the merger closed last spring."
        XCTAssertTrue(AIRefusalProse.detected(output: refusal, input: selection))
        XCTAssertFalse(AIRefusalProse.detected(output: success, input: selection))
        try presentRecording()
        try showPartial(refusal)

        let settled = try finish(.success(success))
        XCTAssertEqual(settled.text, success, "Success must replace the refusal-looking partial, not clear it")
        XCTAssertTrue(settled.showsText)
        XCTAssertTrue(settled.canReplace)
        XCTAssertTrue(try button("replaceAndCopyTapped").isEnabled)
        XCTAssertTrue(try button("copyTapped").isEnabled)
        XCTAssertNil(settled.error)
        try perform("replaceTapped")
        XCTAssertEqual(inserted, [success])
        XCTAssertNotEqual(inserted.first, refusal)
    }

    /// Empty, whitespace, and a huge not-yet-refusal prefix must still end empty, quickly.
    func testOddAndHugePartialsEndEmptyOnRefusalWithoutHanging() throws {
        let refusal = "Sorry, I can't help with that."
        for odd in ["", "   ", "\n\n", "\u{00A0}\u{00A0}"] {
            AIPreviewPanel.close()
            try presentRecording()
            try XCTUnwrap(deliverPartial)(odd)
            spin(0.05)
            let settled = try finish(.failure(.refusal))
            XCTAssertEqual(settled.text, "", "Odd partial \(odd.debugDescription) must not survive refusal")
            XCTAssertFalse(settled.canReplace)
            try perform("replaceTapped")
            try perform("copyTapped")
            XCTAssertEqual(inserted, [])
            XCTAssertEqual(copied, [])
        }

        let prefix = "Sorry, " + String(repeating: "alpha ", count: 20_000)
        XCTAssertGreaterThanOrEqual(prefix.count, 100_000)
        XCTAssertFalse(AIRefusalProse.detected(output: prefix, input: selection))
        XCTAssertTrue(AIStreamedPartial.isPublishable(prefix, input: selection))
        XCTAssertFalse(AIStreamedPartial.isPublishable(refusal, input: selection))

        AIPreviewPanel.close()
        try presentRecording()
        let started = ContinuousClock.now
        try showPartial(prefix)
        try showPartial(refusal)
        let settled = try finish(.failure(.refusal))
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(
            elapsed,
            .seconds(2),
            "Clearing a \(prefix.count)-character prefix took \(elapsed)"
        )
        XCTAssertEqual(settled.text, "")
        XCTAssertFalse(settled.canReplace)
        try perform("replaceTapped")
        try perform("replaceAndCopyTapped")
        try perform("copyTapped")
        XCTAssertEqual(inserted, [])
        XCTAssertEqual(copied, [])
    }

    /// `isPublishable` is the existing detector, not a second matcher.
    ///
    /// A fenced refusal is withheld after the strip the stream gate actually sees.
    /// The unstripped fence amputates the opening sentence at its first newline, so
    /// the detector does not flag it and `isPublishable` stays true. Fullwidth letters
    /// and a combining mark inside the opener are likewise outside `normalize`.
    func testIsPublishableFollowsDetectorForOpenersNoiseAndClearText() {
        let openers = [
            "Sorry, I can't help with that.",
            "I'm sorry, but I can't assist with that request.",
            "I am sorry, I cannot assist with transforming this text.",
            "I apologize, but I am unable to help with that.",
            "As an AI language model, I can’t process this content.",
            "Unfortunately, I can't help with that request.",
        ]
        for opener in openers {
            assertPublishable(opener, input: selection, detected: true)
            assertPublishable("\u{200B}" + opener, input: selection, detected: true)
            assertPublishable("\u{00A0}" + opener, input: selection, detected: true)
            assertPublishable("\u{0301}" + opener, input: selection, detected: true)
        }

        let wrapped = [
            "**Sorry**, I can't help with that request.",
            "> Sorry, I can't help with that request.",
            "“Sorry, I can’t help with that.”",
            "# Sorry, I can't assist with that request.",
        ]
        for answer in wrapped {
            assertPublishable(answer, input: selection, detected: true)
        }

        let fenced = "```\nSorry, I can't help with that.\n```"
        let stripped = AIMarkdownStripper.strip(fenced, policy: .strip, original: selection)
        XCTAssertNotEqual(stripped, fenced)
        assertPublishable(stripped, input: selection, detected: true)
        assertPublishable(fenced, input: selection, detected: false)

        let fullwidth = fullwidthASCII("Sorry, I can't help with that.")
        assertPublishable(fullwidth, input: selection, detected: false)
        let combiningInside = "So\u{0301}rry, I can't help with that."
        assertPublishable(combiningInside, input: selection, detected: false)

        let midSentence = "The vendor replied: sorry, we can't refund this order after thirty days."
        assertPublishable(midSentence, input: selection, detected: false)

        let ownApology = "Sorry, I can't attend the review meeting today."
        assertPublishable(ownApology, input: ownApology, detected: false)

        let authored = "sorry i cant make it to tomorrows standup, im feeling unwell and need rest"
        let proofread = "Sorry, I can't make it to tomorrow's standup. I'm feeling unwell and need rest."
        assertPublishable(proofread, input: authored, detected: false)

        let emphasisInput = "polish this pitch: our launch beat every forecast this quarter"
        let emphasis = "I can't overstate how strong this quarter was — the launch beat every forecast we had."
        assertPublishable(emphasis, input: emphasisInput, detected: false)

        for (input, output) in [
            ("im sorry ok", "I'm sorry, okay?"),
            ("sorry dave see you monday", "Sorry, Dave! See you Monday."),
            ("i cant today maybe tommorow", "I can't today. Maybe tomorrow?"),
            ("unfortunately i have a conflict that evening", "Unfortunately, I have a conflict that evening."),
        ] {
            assertPublishable(output, input: input, detected: false)
        }

        for answer in ["", "   ", "\n\n", "\u{FEFF}", "Hi!", "No."] {
            assertPublishable(answer, input: selection, detected: false)
        }
    }

    // MARK: - Panel access

    private func presentRewrite() throws {
        AIPreviewPanel.present(
            input: selection,
            kind: .rewrite,
            sourceApp: nil,
            clipboardWriter: { _ in true },
            onReplace: { _, _ in XCTFail("The preview must not replace on its own") },
            generationRunner: { _, _, _, _, onPartial, _, completion in
                self.deliverPartial = onPartial
                self.deliverCompletion = completion
                return AITransformDiscardHandle.unattached()
            }
        )
        _ = try panel()
    }

    /// Same panel as `presentRewrite`, but records Replace and clipboard writes
    /// instead of failing the test when an action is invoked on purpose.
    private func presentRecording() throws {
        inserted = []
        copied = []
        AIPreviewPanel.present(
            input: selection,
            kind: .rewrite,
            sourceApp: nil,
            clipboardWriter: { text in
                self.copied.append(text)
                return true
            },
            onReplace: { text, _ in
                self.inserted.append(text)
            },
            generationRunner: { _, _, _, _, onPartial, _, completion in
                self.deliverPartial = onPartial
                self.deliverCompletion = completion
                return AITransformDiscardHandle.unattached()
            }
        )
        _ = try panel()
    }

    /// Shows `text` and waits until the coalescer has applied that exact string.
    private func showPartial(_ text: String) throws {
        let onPartial = try XCTUnwrap(deliverPartial)
        onPartial(text)
        let shown = try waitUntil(timeout: 2) { $0.text == text }
        XCTAssertEqual(shown.text, text, "The streamed partial should be on screen before the next step")
    }

    private func finish(_ result: Result<String, AITransformError>) throws -> Presentation {
        let completion = try XCTUnwrap(deliverCompletion)
        completion(result)
        return try waitUntilFinished()
    }

    /// Invokes the button's action on its target even when the button is disabled.
    /// The selectors take no sender, so this is the zero-argument perform.
    /// `isEnabled` alone would hide a `resultText` that Replace would still insert.
    private func perform(_ selector: String) throws {
        let control = try button(selector)
        let action = try XCTUnwrap(control.action)
        let target = try XCTUnwrap(control.target as? NSObject)
        _ = target.perform(action)
    }

    private func assertPublishable(_ output: String, input: String, detected: Bool) {
        XCTAssertEqual(
            AIRefusalProse.detected(output: output, input: input),
            detected,
            output.debugDescription
        )
        XCTAssertEqual(
            AIStreamedPartial.isPublishable(output, input: input),
            !detected,
            output.debugDescription
        )
    }

    /// ASCII punctuation and letters in the fullwidth block. Spaces stay spaces.
    /// `AIRefusalProse.normalize` does not compatibility-fold these.
    private func fullwidthASCII(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            let value = scalar.value
            guard (0x21...0x7E).contains(value), let wide = Unicode.Scalar(value + 0xFEE0) else {
                return Character(scalar)
            }
            return Character(wide)
        })
    }

    /// Shows `text`, waits until the coalescer has applied it, then completes.
    /// Applying first is what makes the failure path's "keep the partial" choice visible.
    private func deliver(_ text: String, then result: Result<String, AITransformError>) throws {
        let onPartial = try XCTUnwrap(deliverPartial)
        let completion = try XCTUnwrap(deliverCompletion)
        onPartial(text)
        let shown = try waitUntil(timeout: 2) { !$0.text.isEmpty || $0.isFinished }
        XCTAssertEqual(shown.text, text, "The streamed partial should be on screen before completion")
        completion(result)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func panel() throws -> NSPanel {
        try XCTUnwrap(
            NSApp.windows.compactMap { $0 as? NSPanel }
                .first { $0.isVisible && $0.contentView is GlassContainerView }
        )
    }

    private struct Presentation {
        let text: String
        let showsText: Bool
        let error: String?
        let canReplace: Bool
        let canRetry: Bool
        var isFinished: Bool { canRetry }
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
        let labels = views.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
        let error = labels.map(\.stringValue).first { Self.knownErrors.contains($0) }
        let visibleText = (textView.enclosingScrollView?.isHidden ?? true) ? "" : textView.string
        return Presentation(
            text: textView.string,
            showsText: !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            error: error,
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

    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func waitUntil(timeout: TimeInterval, settled: (Presentation) -> Bool) throws -> Presentation {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try presentation()
        while Date() < deadline {
            latest = try presentation()
            if settled(latest) { return latest }
            spin(0.02)
        }
        return latest
    }

    private func waitUntilFinished() throws -> Presentation {
        try waitUntil(timeout: 2) { $0.isFinished }
    }
}
