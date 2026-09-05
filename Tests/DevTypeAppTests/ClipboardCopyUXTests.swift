import AppKit
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

@MainActor
final class ClipboardCopyUXTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func button(action: String, in panel: NSPanel) throws -> NSButton {
        try XCTUnwrap(
            descendants(of: try XCTUnwrap(panel.contentView))
                .compactMap { $0 as? NSButton }
                .first { $0.action == NSSelectorFromString(action) }
        )
    }

    private func visibleToast(message: String, excluding excluded: NSPanel? = nil) -> NSPanel? {
        NSApp.windows.compactMap { $0 as? NSPanel }.first { panel in
            guard panel !== excluded, panel.isVisible, let content = panel.contentView else { return false }
            return descendants(of: content)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == message }
        }
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        ToastPanel.dismiss()
        AIPreviewPanel.close()
    }

    override func tearDown() {
        ToastPanel.dismiss()
        AIPreviewPanel.close()
        super.tearDown()
    }

    func testAIPreviewCopyFailureShowsTruthfulNonActivatingFeedback() throws {
        var attemptedText: String?
        AIPreviewPanel.present(
            input: "**result**",
            kind: .removeMarkdown,
            sourceApp: nil,
            clipboardWriter: { text in
                attemptedText = text
                return false
            },
            onReplace: { _, _ in XCTFail("Copy must not replace") }
        )

        let preview = try XCTUnwrap(
            NSApp.windows.compactMap { $0 as? NSPanel }.first { panel in
                guard panel.isVisible, let content = panel.contentView else { return false }
                return self.descendants(of: content)
                    .compactMap { $0 as? NSButton }
                    .contains { $0.action == NSSelectorFromString("copyTapped") }
            }
        )
        try button(action: "copyTapped", in: preview).performClick(nil)

        XCTAssertEqual(attemptedText, "result")
        let toast = try XCTUnwrap(
            visibleToast(
                message: LocalizationManager.shared.s("clipboard.write.failed"),
                excluding: preview
            )
        )
        XCTAssertFalse(toast.canBecomeKey)
        XCTAssertFalse(toast.canBecomeMain)
        XCTAssertTrue(preview.isVisible, "A failed Copy must leave the reviewable result available.")
    }

    func testAIPreviewReplaceAndCopyReportsTheCopyFailureAfterReplacing() throws {
        var replacedText: String?
        AIPreviewPanel.present(
            input: "**result**",
            kind: .removeMarkdown,
            sourceApp: nil,
            clipboardWriter: { _ in false },
            onReplace: { text, _ in replacedText = text }
        )

        let preview = try XCTUnwrap(
            NSApp.windows.compactMap { $0 as? NSPanel }.first { panel in
                guard panel.isVisible, let content = panel.contentView else { return false }
                return self.descendants(of: content)
                    .compactMap { $0 as? NSButton }
                    .contains { $0.action == NSSelectorFromString("replaceAndCopyTapped") }
            }
        )
        try button(action: "replaceAndCopyTapped", in: preview).performClick(nil)

        XCTAssertEqual(replacedText, "result", "The Replace half remains successful and explicit.")
        let toast = try XCTUnwrap(
            visibleToast(message: LocalizationManager.shared.s("clipboard.write.failed"))
        )
        XCTAssertFalse(toast.canBecomeKey)
        XCTAssertFalse(toast.canBecomeMain)
        let labels = descendants(of: try XCTUnwrap(toast.contentView))
            .compactMap { $0 as? NSTextField }
            .map(\.stringValue)
        XCTAssertFalse(
            labels.contains(LocalizationManager.shared.s("ai.preview.undoToast")),
            "The copy failure must be the final visible result rather than the intermediate replace toast."
        )
    }

    func testAQueuedToastStaysBehindTheMinimumReplacementWindow() throws {
        ToastPanel.dismiss()
        ToastPanel.show("First outcome")
        ToastPanel.show("Second outcome")
        XCTAssertNotNil(visibleToast(message: "First outcome"))
        XCTAssertNil(
            visibleToast(message: "Second outcome"),
            "A second success in the same beat must wait, not erase the first unread line."
        )
    }

    func testAFailureToastPreemptsAnUnreadSuccessToast() throws {
        ToastPanel.dismiss()
        let failure = LocalizationManager.shared.s("clipboard.write.failed")
        ToastPanel.show("AI transform applied")
        ToastPanel.show(failure, symbol: "xmark.circle.fill", preempt: true)
        XCTAssertNotNil(
            visibleToast(message: failure),
            "A terminal failure must appear immediately rather than wait behind the unread success."
        )
    }

    func testVoiceHUDCopyFailureDoesNotClaimCopied() throws {
        var attemptedText: String?
        let hud = VoiceHUDPanel(clipboardWriter: { text in
            attemptedText = text
            return false
        })
        defer { hud.hide() }
        hud.updateState(.success(text: "verbatim transcript"))

        try button(action: "copyTranscript", in: hud).performClick(nil)

        XCTAssertEqual(attemptedText, "verbatim transcript")
        let toast = try XCTUnwrap(
            visibleToast(
                message: LocalizationManager.shared.s("clipboard.write.failed"),
                excluding: hud
            )
        )
        XCTAssertFalse(toast.canBecomeKey)
        XCTAssertFalse(toast.canBecomeMain)
        let labels = descendants(of: try XCTUnwrap(toast.contentView))
            .compactMap { $0 as? NSTextField }
            .map(\.stringValue)
        XCTAssertFalse(labels.contains(LocalizationManager.shared.s("voice.hud.copied")))
    }
}
