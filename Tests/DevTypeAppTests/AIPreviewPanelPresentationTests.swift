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

    // MARK: - The result is actually drawn

    /// The union of the laid-out text, in the text view's own coordinates.
    ///
    /// Reads TextKit 2 first and only falls back to `layoutManager`: touching
    /// `layoutManager` on a TextKit 2 view forces a permanent downgrade to TextKit 1, so
    /// asking in the wrong order would measure a different text system than the one the
    /// panel actually draws with.
    private func laidOutTextRect(_ textView: NSTextView) -> NSRect {
        if let layout = textView.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
            var union = NSRect.null
            layout.enumerateTextLayoutFragments(
                from: layout.documentRange.location,
                options: [.ensuresLayout]
            ) { fragment in
                union = union.union(fragment.layoutFragmentFrame)
                return true
            }
            return union.isNull ? .zero : union
        }
        guard let manager = textView.layoutManager, let container = textView.textContainer else {
            return .zero
        }
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container)
    }

    /// A result the user cannot see is not a preview.
    ///
    /// `textView.string` and `enclosingScrollView.isHidden` were the only things asserted
    /// about the result, and both stay correct when the text is never drawn: the panel
    /// builds its text view with a bare `NSTextView()`, whose frame and text container are
    /// zero-sized, and hands it straight to `scrollView.documentView` without the six
    /// document-view sizing properties every other text view in this app sets
    /// (`AlertPresenter`, `TestExpansionLab`, `PermissionDiagnosticsController`,
    /// `SnippetEditorSheet`). The string reaches the text storage, VoiceOver reads it and
    /// Replace inserts it — nothing lays it out, so the panel renders an empty box.
    func testCompletedResultIsLaidOutAndNotJustStored() throws {
        let panel = try present("""
            # Heading

            Some **bold** body text that runs on for long enough to wrap onto more than one \
            line inside the preview's text area.
            """)
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let textView = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        panel.contentView?.layoutSubtreeIfNeeded()

        let viewport = scrollView.contentView.bounds.width
        XCTAssertGreaterThan(viewport, 0, "precondition: the scroll view must have a viewport")

        XCTAssertEqual(
            textView.frame.width,
            viewport,
            accuracy: 1,
            "The document view must fill its viewport, not keep its zero init frame"
        )

        let drawn = laidOutTextRect(textView)
        XCTAssertGreaterThan(
            drawn.width,
            0,
            "The result is stored but never laid out — text view frame \(textView.frame), "
                + "container \(String(describing: textView.textContainer?.size))"
        )
        XCTAssertGreaterThan(drawn.height, 0, "The result has no drawn height: \(drawn)")
        XCTAssertTrue(
            drawn.intersects(textView.bounds),
            "The text lays out at \(drawn), outside the text view's own bounds \(textView.bounds)"
        )
    }

    /// The result text view must be *configured* to fill its viewport, not merely happen to.
    ///
    /// A document view is not sized by its scroll view; it fills the viewport only if it is
    /// told to. The panel builds its text view with a bare `NSTextView()` — a zero frame —
    /// and assigns it as `documentView` without any of the document-view sizing that
    /// `AlertPresenter`, `TestExpansionLab`, `PermissionDiagnosticsController` and
    /// `SnippetEditorSheet` all set, so its width is whatever AppKit gave it at birth and
    /// nothing ever corrects it. In this process that is the viewport width and the text
    /// draws; on the shipped 1.2.0 build it is zero, and the panel's accessibility tree
    /// reads `AXScrollArea [632x277]` wrapping `AXTextArea [0x277]` carrying the full
    /// result — present, announced to VoiceOver, insertable by Replace, and drawn nowhere.
    ///
    /// Asserting the geometry at one instant cannot tell those two apart, so assert the
    /// contract that makes the width correct at *every* instant.
    func testResultTextViewIsConfiguredToFillItsViewport() throws {
        let panel = try present("# Heading\n\nbody text long enough to need a real width")
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let textView = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        panel.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            textView.autoresizingMask.contains(.width),
            "The document view must follow its viewport's width; mask is \(textView.autoresizingMask)"
        )
        XCTAssertTrue(textView.isVerticallyResizable, "must grow downwards as the answer arrives")
        XCTAssertFalse(textView.isHorizontallyResizable, "the preview wraps, it does not scroll sideways")
        XCTAssertEqual(
            textView.maxSize.width,
            CGFloat.greatestFiniteMagnitude,
            "A maxSize captured from the viewport at birth caps the width forever: \(textView.maxSize)"
        )
        // `minSize` is deliberately not asserted: AppKit overwrites it with the clip view's
        // size when the document view is installed, so its value reports what the scroll
        // view did, not what the panel asked for. `maxSize` above is the one that binds.
        XCTAssertLessThanOrEqual(
            textView.minSize.width,
            AIPreviewPanel.panelSize.width,
            "minSize must never demand more width than the panel has"
        )
        XCTAssertEqual(
            textView.textContainer?.widthTracksTextView,
            true,
            "the text container has to follow the text view, or the glyphs wrap to the old width"
        )
    }

    /// The result text view must track the width of its viewport.
    ///
    /// This is the defect behind "the preview shows no text". Measured on the shipped
    /// 1.2.0 build, the panel's accessibility tree reads:
    ///
    ///     AXScrollArea [632x277]
    ///       AXTextArea  [0x277]  VALUE(134)="we were talking about the api design…"
    ///
    /// — the full result is in the text view and the text view is zero points wide, so
    /// there is nowhere for it to draw. The panel builds it with a bare `NSTextView()`
    /// (a zero frame) and assigns it as `documentView` without the document-view sizing
    /// every other text view in this app sets, so nothing ever ties its width to the clip
    /// view's. Whether the initial layout happens to give it a width depends on when the
    /// scroll view is first tiled; the panel animates its frame in from a smaller size,
    /// so the width it is given at birth is not the width it must end up with.
    func testResultTextViewTracksItsViewportWidth() throws {
        let panel = try present("# Heading\n\nbody text long enough to need a real width")
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let textView = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        let scrollView = try XCTUnwrap(textView.enclosingScrollView)
        panel.contentView?.layoutSubtreeIfNeeded()

        // `FloatingPanelChrome.animateIn` starts the panel 24pt narrower than its final
        // size and grows it, so the viewport width genuinely changes after the text view
        // is installed. Drive the same change directly.
        for width in [AIPreviewPanel.panelSize.width - 90, AIPreviewPanel.panelSize.width] {
            panel.setContentSize(NSSize(width: width, height: AIPreviewPanel.panelSize.height))
            panel.contentView?.layoutSubtreeIfNeeded()
            scrollView.layoutSubtreeIfNeeded()

            XCTAssertEqual(
                textView.frame.width,
                scrollView.contentView.bounds.width,
                accuracy: 1,
                "At panel width \(width) the document view is \(textView.frame.width)pt wide "
                    + "inside a \(scrollView.contentView.bounds.width)pt viewport — text cannot draw"
            )
            XCTAssertGreaterThan(
                laidOutTextRect(textView).width,
                0,
                "Nothing is laid out at panel width \(width): frame \(textView.frame)"
            )
        }
    }

    /// The same guarantee while the answer is still streaming: partials go down the
    /// `applyPartial` path, which is a different assignment from the completion's.
    func testStreamingPartialIsLaidOutTheSameWayAFinalResultIs() throws {
        let panel = try present("# Heading\n\n**bold** body")
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let textView = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        panel.contentView?.layoutSubtreeIfNeeded()

        textView.string = "a streamed partial answer arriving one chunk at a time"
        panel.contentView?.layoutSubtreeIfNeeded()

        let drawn = laidOutTextRect(textView)
        XCTAssertGreaterThan(drawn.width, 0, "A partial must lay out too: frame \(textView.frame)")
        XCTAssertGreaterThan(drawn.height, 0, "A partial must lay out too: \(drawn)")
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
