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

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        previousLanguage = LocalizationManager.shared.language
        LocalizationManager.shared.language = .en
        AIPreviewPanel.close()
        deliverPartial = nil
        deliverCompletion = nil
    }

    override func tearDown() {
        AIPreviewPanel.close()
        LocalizationManager.shared.language = previousLanguage
        deliverPartial = nil
        deliverCompletion = nil
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
