import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

/// What the AI preview panel is allowed to look like, measured on the real panel.
///
/// Everything here runs the local `removeMarkdown` transform, which answers synchronously
/// with no model in the loop, so these cases hold on every machine and in CI. The
/// model-driven behaviour lives in `AIPreviewSupersessionTests`.
@MainActor
final class AIPreviewPanelPresentationTests: XCTestCase {
    private var previousLanguage: AppLanguage = .system

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        previousLanguage = LocalizationManager.shared.language
        AIPreviewPanel.close()
    }

    override func tearDown() {
        AIPreviewPanel.close()
        LocalizationManager.shared.language = previousLanguage
        super.tearDown()
    }

    // MARK: - Fixtures

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func openPanel() throws -> NSPanel {
        try XCTUnwrap(
            NSApp.windows
                .compactMap { $0 as? NSPanel }
                .first { $0.isVisible && $0.contentView is GlassContainerView }
        )
    }

    private func present(_ input: String, kind: AITransformKind = .removeMarkdown) throws -> NSPanel {
        AIPreviewPanel.present(
            input: input,
            kind: kind,
            sourceApp: nil,
            clipboardWriter: { _ in true },
            onReplace: { _, _ in XCTFail("Presenting a preview must never replace on its own") }
        )
        let panel = try openPanel()
        panel.contentView?.layoutSubtreeIfNeeded()
        return panel
    }

    private func button(action selector: String, in panel: NSPanel) throws -> NSButton {
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        return try XCTUnwrap(views.compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString(selector) })
    }

    private func pillTexts(in panel: NSPanel) throws -> [String] {
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        return views.compactMap { $0 as? PillBadgeView }
            .filter { !$0.isHidden }
            .flatMap { descendants(of: $0).compactMap { ($0 as? NSTextField)?.stringValue } }
            .filter { !$0.isEmpty }
    }

    // MARK: - Declared size

    /// `panelSize` is the number `positionNearTop` centres on and the number the error
    /// label sizes its wrap width from, so a panel that lays out wider than it declares
    /// makes both of them wrong. The header used to push it to 652pt against a declared
    /// 560, in every shipped language.
    func testPanelNeverExceedsItsDeclaredSizeInAnyLanguage() throws {
        for language in AppLanguage.allCases where language != .system {
            LocalizationManager.shared.language = language
            for kind in AITransformKind.builtInPalette {
                let panel = try present("# Heading\n\n**bold** body", kind: kind)
                let content = try XCTUnwrap(panel.contentView)
                XCTAssertLessThanOrEqual(
                    content.frame.width,
                    AIPreviewPanel.panelSize.width,
                    "\(language.rawValue)/\(kind.rawValue): content is wider than the declared panel"
                )
                XCTAssertLessThanOrEqual(
                    content.frame.height,
                    AIPreviewPanel.panelSize.height,
                    "\(language.rawValue)/\(kind.rawValue): content is taller than the declared panel"
                )
                AIPreviewPanel.close()
            }
        }
    }

    /// The panel is placed by `FloatingPanelChrome.positionNearTop`, which centres it using
    /// the size it has *before* layout. A panel that then grows is left off-centre by half
    /// of whatever it grew — 46pt, in the shipped build.
    func testPanelIsHorizontallyCentredOnTheScreenItOpensOn() throws {
        let panel = try present("# Heading\n\nbody")
        let screen = try XCTUnwrap(
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
        )
        XCTAssertEqual(
            panel.frame.midX,
            screen.visibleFrame.midX,
            accuracy: 1,
            "The preview must be centred on the width it actually has"
        )
    }

    /// Every action stays inside the panel — the failure this guards is a footer that
    /// leaves the frame once the header stops being allowed to widen it.
    func testEveryActionStaysInsideThePanel() throws {
        let panel = try present("# Heading\n\n**bold** body")
        let content = try XCTUnwrap(panel.contentView)
        let buttons = descendants(of: content).compactMap { $0 as? NSButton }
            .filter { !$0.isHidden && !($0 is NSPopUpButton) }
        XCTAssertGreaterThanOrEqual(buttons.count, 5)
        for button in buttons {
            let frame = button.convert(button.bounds, to: content)
            XCTAssertTrue(
                content.bounds.contains(frame),
                "\(button.title) at \(frame) escapes the panel \(content.bounds)"
            )
        }
    }

    // MARK: - What a result is

    /// `AITransformFlow.runDirect` refuses to inject a blank answer and `generateRaw`
    /// refuses to return one, but the preview runs `AILocalTransform` itself — ahead of
    /// both — so a whitespace-only selection arrived as a `.success` with Replace live,
    /// offering to overwrite the selection with nothing.
    func testWhitespaceOnlyResultIsReportedAsAFailureRatherThanOfferedForReplace() throws {
        let panel = try present("   \n\t  \n ")
        let content = try XCTUnwrap(panel.contentView)

        for selector in ["replaceTapped", "replaceAndCopyTapped", "copyTapped"] {
            XCTAssertFalse(
                try button(action: selector, in: panel).isEnabled,
                "\(selector) must not be offered for a blank result"
            )
        }
        let errorLabels = descendants(of: content).compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden && $0.stringValue == LocalizationManager.shared.s("ai.error.decoding") }
        XCTAssertEqual(errorLabels.count, 1, "A blank answer has to say it failed")
    }

    /// A real result enables the three actions that consume it and stops the spinner.
    func testCompletedLocalTransformShowsItsTextAndEnablesTheActions() throws {
        let panel = try present("# Heading\n\nSome **bold** body text.")
        let content = try XCTUnwrap(panel.contentView)
        let views = descendants(of: content)
        let textView = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        let spinner = try XCTUnwrap(views.compactMap { $0 as? NSProgressIndicator }.first)

        XCTAssertEqual(textView.string, "Heading\n\nSome bold body text.")
        XCTAssertFalse(textView.enclosingScrollView?.isHidden ?? true)
        XCTAssertTrue(spinner.isHidden)
        for selector in ["replaceTapped", "replaceAndCopyTapped", "copyTapped", "retryTapped"] {
            XCTAssertTrue(try button(action: selector, in: panel).isEnabled, selector)
        }
    }

    // MARK: - Delta pills

    /// The pills report a change. `%d` signs a loss and not a gain, so a result that grew
    /// read "8 chars" — indistinguishable from a result that *is* 8 characters long.
    ///
    /// Only a lengthening transform exercises the gain, and every transform that lengthens
    /// text needs the model, so the rule is checked directly as well as through the panel.
    func testDeltaPillLabelsCarryASignInBothDirections() {
        LocalizationManager.shared.language = .en
        let loc = LocalizationManager.shared

        XCTAssertEqual(AIPreviewDelta.label(8, key: "ai.preview.delta.chars", loc: loc), "+8 chars")
        XCTAssertEqual(AIPreviewDelta.label(1, key: "ai.preview.delta.words", loc: loc), "+1 words")
        XCTAssertEqual(AIPreviewDelta.label(0, key: "ai.preview.delta.chars", loc: loc), "0 chars")
        XCTAssertEqual(AIPreviewDelta.label(-6, key: "ai.preview.delta.chars", loc: loc), "-6 chars")

        // The sign goes in front of the number in every shipped table, so prefixing holds.
        for language in AppLanguage.allCases where language != .system {
            LocalizationManager.shared.language = language
            let gained = AIPreviewDelta.label(3, key: "ai.preview.delta.words", loc: loc)
            let lost = AIPreviewDelta.label(-3, key: "ai.preview.delta.words", loc: loc)
            XCTAssertTrue(gained.hasPrefix("+3"), "\(language.rawValue): \(gained)")
            XCTAssertTrue(lost.hasPrefix("-3"), "\(language.rawValue): \(lost)")
        }
    }

    func testDeltaPillsRenderAgainstTheSelectionTheTransformWasGiven() throws {
        LocalizationManager.shared.language = .en

        let shorter = try present("# Heading\n\n**bold**")
        let shortened = try pillTexts(in: shorter)
        XCTAssertTrue(
            shortened.allSatisfy { $0.hasPrefix("-") },
            "A shortened result must read as a loss: \(shortened)"
        )
        AIPreviewPanel.close()

        // No Markdown to remove: the transform is the identity, so both deltas are zero.
        let same = try present("plain body text")
        XCTAssertEqual(try pillTexts(in: same).sorted(), ["0 chars", "0 words"])
    }

    func testDeltaWordCountIgnoresRunsOfWhitespaceAndNewlines() {
        XCTAssertEqual(AIPreviewDelta.words(in: ""), 0)
        XCTAssertEqual(AIPreviewDelta.words(in: "   \n\t "), 0)
        XCTAssertEqual(AIPreviewDelta.words(in: "one"), 1)
        XCTAssertEqual(AIPreviewDelta.words(in: "  one   two \n\n three\t"), 3)
    }

    // MARK: - Reopening

    /// Presenting again replaces the panel rather than stacking a second one.
    func testPresentingTwiceLeavesExactlyOnePreviewPanel() throws {
        _ = try present("# One\n\nbody one")
        _ = try present("# Two\n\nbody two")

        let panels = NSApp.windows
            .compactMap { $0 as? NSPanel }
            .filter { $0.isVisible && $0.contentView is GlassContainerView }
        XCTAssertEqual(panels.count, 1)

        let textView = try XCTUnwrap(
            descendants(of: try XCTUnwrap(panels[0].contentView))
                .compactMap { $0 as? NSTextView }.first
        )
        XCTAssertEqual(textView.string, "Two\n\nbody two")
    }
}
