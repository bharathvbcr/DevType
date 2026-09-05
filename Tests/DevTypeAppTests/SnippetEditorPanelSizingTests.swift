import AppKit
import Carbon.HIToolbox
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

/// The snippet editor is a fixed-size borderless sheet. Nothing typed into it may change the
/// panel's frame: a window under Auto Layout holds its size at priority 500, so any label whose
/// intrinsic width is fed by user text and whose compression resistance is left at the default
/// 750 *widens the window* rather than truncating. `contentMaxSize` does not take part in that
/// solve — the shipped editor had it set and still grew. These tests drive the real panels with
/// real field editing and measure the frame.
@MainActor
final class SnippetEditorPanelSizingTests: XCTestCase {

    private struct Presented {
        let panel: NSPanel
        let root: NSView
        let triggerField: NSTextField
        let titleField: NSTextField
        let replacementView: NSTextView
        let cancelButton: NSButton
        let saveButton: NSButton
    }

    private var loc: LocalizationManager { .shared }
    private var guideWasDismissed = false

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        guideWasDismissed = SnippetEditorGuideView.isDismissed
    }

    override func tearDown() {
        SnippetEditorGuideView.isDismissed = guideWasDismissed
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A library whose triggers all start with the same punctuation, so a one- or two-character
    /// trigger typed into the editor prefix-shadows every one of them and the conflict message
    /// names them all — the longest message the editor can ever be asked to show.
    private func crowdedLibrary(count: Int = 30) -> [SnippetGroup] {
        var group = SnippetGroup(name: "Crowded")
        for index in 0..<count {
            group.snippets.append(
                SnippetModel(
                    title: "Snippet \(index)",
                    triggerKeyword: ":shadowed-trigger-number-\(index)",
                    replacementText: "body \(index)"
                )
            )
        }
        return [group]
    }

    private func panel(named className: String) throws -> NSPanel {
        try XCTUnwrap(
            NSApp.windows.compactMap { $0 as? NSPanel }.first {
                $0.isVisible && String(describing: type(of: $0)).contains(className)
            },
            "\(className) must be on screen after present()"
        )
    }

    private func present(existing: SnippetModel?, groups: [SnippetGroup]) throws -> Presented {
        SnippetEditorSheet.present(
            from: nil,
            existing: existing,
            draft: nil,
            groups: groups,
            currentGroupID: groups.first?.id,
            loc: loc,
            completion: { _, _ in .refused(.failed("test host never persists")) }
        )
        let panel = try panel(named: "EditorKeyablePanel")
        let contentView: NSView = try XCTUnwrap(panel.contentView)
        let views = descendants(of: contentView)
        let triggerLabel = loc.s("editor.trigger")
        let nameLabel = loc.s("editor.name")
        let replacementLabel = loc.s("ax.editor.replacement")
        let fields: [NSTextField] = views.compactMap { $0 as? NSTextField }
        let textViews: [NSTextView] = views.compactMap { $0 as? NSTextView }
        let buttons: [NSButton] = views.compactMap { $0 as? NSButton }
        let triggerField: NSTextField = try XCTUnwrap(
            fields.first(where: { $0.isEditable && $0.accessibilityLabel() == triggerLabel })
        )
        let titleField: NSTextField = try XCTUnwrap(
            fields.first(where: { $0.isEditable && $0.accessibilityLabel() == nameLabel })
        )
        let replacementView: NSTextView = try XCTUnwrap(
            textViews.first(where: { $0.accessibilityLabel() == replacementLabel })
        )
        let cancelButton: NSButton = try XCTUnwrap(
            buttons.first(where: { $0.action == NSSelectorFromString("cancelTapped") })
        )
        let saveButton: NSButton = try XCTUnwrap(
            buttons.first(where: { $0.action == NSSelectorFromString("saveTapped") })
        )
        settle(panel)
        return Presented(
            panel: panel,
            root: contentView,
            triggerField: triggerField,
            titleField: titleField,
            replacementView: replacementView,
            cancelButton: cancelButton,
            saveButton: saveButton
        )
    }

    /// Lets the window's own layout pass run — that is where Auto Layout resizes a window.
    private func settle(_ panel: NSWindow) {
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        panel.layoutIfNeeded()
    }

    /// Types through the real field editor so the delegate chain the app relies on
    /// (`controlTextDidChange` → live validation) runs exactly as it does for a user.
    private func typeText(_ text: String, into field: NSTextField, in panel: NSWindow) throws {
        XCTAssertTrue(panel.makeFirstResponder(field), "field must accept first responder")
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView, "field editor must be installed")
        let all = NSRange(location: 0, length: (editor.string as NSString).length)
        editor.insertText(text, replacementRange: all)
        settle(panel)
    }

    private func typeText(_ text: String, into textView: NSTextView, in panel: NSWindow) {
        panel.makeFirstResponder(textView)
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.insertText(text, replacementRange: all)
        settle(panel)
    }

    private func dismiss(_ presented: Presented) {
        dismiss(presented.panel, via: presented.cancelButton)
    }

    private func dismiss(_ panel: NSWindow, via cancelButton: NSButton) {
        guard panel.isVisible else { return }
        cancelButton.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(panel.isVisible, "Cancel must close the panel")
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    /// Recent AppKit builds a private text field inside every button for its title.
    private func isInsideButton(_ view: NSView) -> Bool {
        var current = view.superview
        while let candidate = current {
            if candidate is NSButton { return true }
            current = candidate.superview
        }
        return false
    }

    private func isInsideClipView(_ view: NSView) -> Bool {
        var current = view.superview
        while let candidate = current {
            if candidate is NSClipView { return true }
            current = candidate.superview
        }
        return false
    }

    private func assertFixedFrame(
        _ panel: NSWindow,
        expected: NSSize,
        footer: [NSButton],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            panel.frame.width, expected.width, accuracy: 0.5,
            "panel widened to \(panel.frame.width)", file: file, line: line
        )
        XCTAssertEqual(
            panel.frame.height, expected.height, accuracy: 0.5,
            "panel height changed to \(panel.frame.height)", file: file, line: line
        )
        guard let root = panel.contentView else {
            XCTFail("no content view", file: file, line: line)
            return
        }
        let bounds = root.bounds
        // Scrolled documents are clipped by design and may legitimately be wider than the panel.
        for view in descendants(of: root) where !view.isHiddenOrHasHiddenAncestor && !isInsideClipView(view) {
            let frame = view.convert(view.bounds, to: root)
            XCTAssertLessThanOrEqual(
                frame.maxX, bounds.maxX + 0.5,
                "\(Swift.type(of: view)) overflows the panel's right edge: \(frame)", file: file, line: line
            )
            XCTAssertGreaterThanOrEqual(
                frame.minX, bounds.minX - 0.5,
                "\(Swift.type(of: view)) overflows the panel's left edge: \(frame)", file: file, line: line
            )
        }
        // The footer must stay reachable: every action button inside the panel.
        for button in footer {
            let frame = button.convert(button.bounds, to: root)
            XCTAssertTrue(bounds.contains(frame), "\(button.title) left the panel: \(frame)", file: file, line: line)
        }
    }

    private func assertFixedFrame(_ presented: Presented, file: StaticString = #filePath, line: UInt = #line) {
        assertFixedFrame(
            presented.panel,
            expected: NSSize(width: SnippetEditorSheet.panelWidth, height: SnippetEditorSheet.panelHeight),
            footer: [presented.cancelButton, presented.saveButton],
            file: file,
            line: line
        )
    }

    /// A wrapping label whose frame is shorter than its own text is drawing a clipped second
    /// line — the quiet failure a fixed-height panel invites once widths are bounded.
    private func assertNotClipped(_ label: NSTextField, file: StaticString = #filePath, line: UInt = #line) {
        guard let cell = label.cell, !label.stringValue.isEmpty else { return }
        let needed = cell.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude
        )).height
        XCTAssertGreaterThanOrEqual(
            label.frame.height + 0.5, needed,
            "label “\(label.stringValue.prefix(40))…” is \(label.frame.height) tall but needs \(needed)",
            file: file, line: line
        )
    }

    private func escapeEvent(for panel: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: UInt16(kVK_Escape)
        ))
    }

    // MARK: - Snippet editor

    func testConflictMessageForACrowdedLibraryDoesNotWidenThePanelInAnyLanguage() throws {
        let previous = loc.language
        defer { loc.language = previous }
        for language in AppLanguage.concreteCases {
            loc.language = language
            let presented = try present(existing: nil, groups: crowdedLibrary())
            defer { dismiss(presented) }
            assertFixedFrame(presented)

            // ":" prefix-shadows all 30 stored triggers; the message names every one of them.
            try typeText(":", into: presented.triggerField, in: presented.panel)
            assertFixedFrame(presented)
            try typeText(":s", into: presented.triggerField, in: presented.panel)
            assertFixedFrame(presented)
            XCTAssertFalse(presented.saveButton.isEnabled, "a conflicting trigger must not be saveable")

            // Every visible label is still inside the panel, and the trigger column did not swallow
            // the group column: the popup keeps its half.
            let popups = descendants(of: presented.root).compactMap { $0 as? NSPopUpButton }
            XCTAssertEqual(popups.count, 2)
            for popup in popups {
                XCTAssertGreaterThan(popup.frame.width, 100, "\(language): popup collapsed to \(popup.frame.width)")
            }
        }
    }

    func testOverlongTriggerDoesNotWidenThePanelAndTheGuideSentenceWraps() throws {
        SnippetEditorGuideView.isDismissed = false
        let presented = try present(existing: nil, groups: [SnippetGroup(name: "Empty")])
        defer { dismiss(presented) }

        // Word-started so the rule sentence is the long "Expands after you type “…” then a
        // space…" form, with the whole trigger embedded in it.
        let long = String(repeating: "abcdefghij", count: 6) // 60 — under the 64 cap, still valid
        try typeText(long, into: presented.triggerField, in: presented.panel)
        assertFixedFrame(presented)
        XCTAssertTrue(presented.saveButton.isEnabled)

        let guide = try XCTUnwrap(
            descendants(of: presented.root).compactMap { $0 as? SnippetEditorGuideView }.first
        )
        XCTAssertFalse(guide.isHidden)
        let wrapping = descendants(of: guide).compactMap { $0 as? NSTextField }.filter {
            $0.cell?.wraps == true && !$0.stringValue.isEmpty && !isInsideButton($0)
        }
        XCTAssertFalse(wrapping.isEmpty, "the guide's rule sentence must be present")
        for label in wrapping {
            XCTAssertTrue(
                label.stringValue.contains(long),
                "the sentence quotes the typed trigger; wrapping labels: \(wrapping.map { "[\($0.stringValue.prefix(60))] frame=\($0.frame)" })"
            )
            assertNotClipped(label)
        }

        let tooLong = String(repeating: "abcdefghij", count: 30) // 300 — over the cap
        try typeText(tooLong, into: presented.triggerField, in: presented.panel)
        assertFixedFrame(presented)
        XCTAssertFalse(presented.saveButton.isEnabled)
    }

    func testLongTitleAndReplacementDoNotWidenThePanel() throws {
        let presented = try present(existing: nil, groups: [SnippetGroup(name: "Empty")])
        defer { dismiss(presented) }

        try typeText(String(repeating: "A very long snippet title ", count: 20), into: presented.titleField, in: presented.panel)
        assertFixedFrame(presented)

        typeText(String(repeating: "lorem ipsum dolor sit amet ", count: 200), into: presented.replacementView, in: presented.panel)
        assertFixedFrame(presented)
        // A pathological single "word" with no break opportunities.
        typeText(String(repeating: "x", count: 5000), into: presented.replacementView, in: presented.panel)
        assertFixedFrame(presented)
        // Macro syntax the preview has to resolve on every keystroke.
        typeText(String(repeating: "%date:iso% %filltext:name=Field:default=Value% ", count: 60), into: presented.replacementView, in: presented.panel)
        assertFixedFrame(presented)
    }

    func testLongGroupNamesDoNotWidenThePanelBeforeAnythingIsTyped() throws {
        let groups = [
            SnippetGroup(name: String(repeating: "An extraordinarily long group name ", count: 8)),
            SnippetGroup(name: "Short"),
        ]
        let presented = try present(existing: nil, groups: groups)
        defer { dismiss(presented) }
        assertFixedFrame(presented)
    }

    func testEditingAnExistingSnippetKeepsTheFrameThroughAConflict() throws {
        let groups = crowdedLibrary()
        let existing = groups[0].snippets[0]
        let presented = try present(existing: existing, groups: groups)
        defer { dismiss(presented) }
        assertFixedFrame(presented)

        try typeText(":", into: presented.triggerField, in: presented.panel)
        assertFixedFrame(presented)
        try typeText(":shadowed-trigger-number-1", into: presented.triggerField, in: presented.panel)
        assertFixedFrame(presented)
        XCTAssertFalse(presented.saveButton.isEnabled, "a duplicate trigger must not be saveable")
    }

    /// "Unable to close": with the panel at its proper size the Cancel button is on screen, and
    /// Escape reaches it even while the trigger field's editor owns the keyboard.
    func testEscapeClosesTheEditorWhileTheTriggerFieldHasFocus() throws {
        let presented = try present(existing: nil, groups: crowdedLibrary())
        try typeText(":", into: presented.triggerField, in: presented.panel)
        XCTAssertTrue(presented.panel.firstResponder is NSTextView, "the field editor should hold focus")

        let escape = try escapeEvent(for: presented.panel)
        XCTAssertTrue(presented.panel.performKeyEquivalent(with: escape), "Escape must be claimed by Cancel")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(presented.panel.isVisible, "Escape must close the editor")
    }

    /// The production path: the editor is a sheet on the Preferences window. A sheet is sized
    /// from the panel's own frame, so it has to hold there too.
    func testEditorPresentedAsASheetHoldsItsFrameThroughAConflict() throws {
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.makeKeyAndOrderFront(nil)
        defer { host.close() }

        SnippetEditorSheet.present(
            from: host,
            existing: nil,
            draft: nil,
            groups: crowdedLibrary(),
            currentGroupID: nil,
            loc: loc,
            completion: { _, _ in .refused(.failed("test host never persists")) }
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let panel = try XCTUnwrap(
            NSApp.windows.compactMap { $0 as? NSPanel }.first {
                String(describing: type(of: $0)).contains("EditorKeyablePanel")
            }
        )
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let triggerLabel = loc.s("editor.trigger")
        let triggerField: NSTextField = try XCTUnwrap(
            views.compactMap { $0 as? NSTextField }.first(where: { $0.isEditable && $0.accessibilityLabel() == triggerLabel })
        )
        let buttons: [NSButton] = views.compactMap { $0 as? NSButton }
        let cancel: NSButton = try XCTUnwrap(buttons.first(where: { $0.action == NSSelectorFromString("cancelTapped") }))
        let save: NSButton = try XCTUnwrap(buttons.first(where: { $0.action == NSSelectorFromString("saveTapped") }))
        defer {
            cancel.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertNil(host.attachedSheet, "Cancel must end the sheet")
        }
        let expected = NSSize(width: SnippetEditorSheet.panelWidth, height: SnippetEditorSheet.panelHeight)
        settle(panel)
        assertFixedFrame(panel, expected: expected, footer: [cancel, save])
        try typeText(":", into: triggerField, in: panel)
        assertFixedFrame(panel, expected: expected, footer: [cancel, save])
        try typeText(":s", into: triggerField, in: panel)
        assertFixedFrame(panel, expected: expected, footer: [cancel, save])
        XCTAssertFalse(save.isEnabled)
    }

    // MARK: - Sibling fixed-size panels share the lock

    func testGroupEditorHoldsItsFrameThroughALongNameAndValidationMessage() throws {
        let longMessage = String(
            repeating: "A group with that name already exists in this library; choose another. ",
            count: 4
        )
        GroupEditorSheet.present(
            from: nil,
            existing: nil,
            loc: loc,
            validate: { _ in longMessage },
            completion: { _ in }
        )
        let panel = try panel(named: "GroupEditorKeyablePanel")
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let nameLabel = loc.s("ax.groupeditor.name")
        let nameField: NSTextField = try XCTUnwrap(
            views.compactMap { $0 as? NSTextField }.first(where: { $0.isEditable && $0.accessibilityLabel() == nameLabel })
        )
        let buttons: [NSButton] = views.compactMap { $0 as? NSButton }
        let cancel: NSButton = try XCTUnwrap(buttons.first(where: { $0.action == NSSelectorFromString("cancelTapped") }))
        let save: NSButton = try XCTUnwrap(buttons.first(where: { $0.action == NSSelectorFromString("saveTapped") }))
        defer { dismiss(panel, via: cancel) }
        settle(panel)
        assertFixedFrame(panel, expected: GroupEditorSheet.panelSize, footer: [cancel, save])

        try typeText(String(repeating: "Extremely long group name ", count: 12), into: nameField, in: panel)
        assertFixedFrame(panel, expected: GroupEditorSheet.panelSize, footer: [cancel, save])

        save.performClick(nil)
        settle(panel)
        XCTAssertTrue(panel.isVisible, "a refused save keeps the sheet open")
        assertFixedFrame(panel, expected: GroupEditorSheet.panelSize, footer: [cancel, save])
        let error = try XCTUnwrap(
            views.compactMap { $0 as? NSTextField }.first(where: { $0.stringValue == longMessage })
        )
        XCTAssertFalse(error.isHidden)
        XCTAssertLessThanOrEqual(
            error.alignmentRect(forFrame: error.frame).width, GroupEditorSheet.panelSize.width - 40 + 0.5,
            "error label frame \(error.frame) in panel \(panel.frame)"
        )
        assertNotClipped(error)
    }

    func testAppScopeSheetHoldsItsFrameThroughLongBundleIdentifiers() throws {
        SnippetAppScopeSheet.present(from: nil, scope: .unscoped, loc: loc) { _ in }
        let panel = try panel(named: "AppScopeKeyablePanel")
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let placeholder = loc.s("appscope.bundleID.placeholder")
        let bundleField: NSTextField = try XCTUnwrap(
            views.compactMap { $0 as? NSTextField }.first(where: { $0.isEditable && $0.placeholderString == placeholder })
        )
        let buttons: [NSButton] = views.compactMap { $0 as? NSButton }
        let cancel: NSButton = try XCTUnwrap(buttons.first(where: { $0.action == NSSelectorFromString("cancelTapped") }))
        let done: NSButton = try XCTUnwrap(buttons.first(where: { $0.action == NSSelectorFromString("doneTapped") }))
        defer { dismiss(panel, via: cancel) }
        settle(panel)
        assertFixedFrame(panel, expected: SnippetAppScopeSheet.panelSize, footer: [cancel, done])

        for index in 0..<3 {
            let identifier = "com.example.\(String(repeating: "verylongsegment", count: 6)).app\(index)"
            try typeText(identifier, into: bundleField, in: panel)
            _ = bundleField.sendAction(bundleField.action, to: bundleField.target)
            settle(panel)
            assertFixedFrame(panel, expected: SnippetAppScopeSheet.panelSize, footer: [cancel, done])
        }
        // Adding one twice produces the duplicate feedback sentence.
        let duplicate = "com.example.\(String(repeating: "verylongsegment", count: 6)).app0"
        try typeText(duplicate, into: bundleField, in: panel)
        _ = bundleField.sendAction(bundleField.action, to: bundleField.target)
        settle(panel)
        assertFixedFrame(panel, expected: SnippetAppScopeSheet.panelSize, footer: [cancel, done])
        for label in views.compactMap({ $0 as? NSTextField }) where label.cell?.wraps == true && !label.isHidden {
            assertNotClipped(label)
        }
    }

    func testFillInPanelHoldsItsFrameForSnippetAuthoredTitlesAndFieldNames() throws {
        let fields = (0..<3).map { index in
            FillField(
                id: index,
                name: String(repeating: "An unreasonably long fill-in field name ", count: 5) + "\(index)",
                kind: .text,
                defaultValue: String(repeating: "default ", count: 40)
            )
        }
        let panel = FillInPanel.present(
            title: String(repeating: "A snippet-authored form title that goes on ", count: 6),
            fields: fields
        ) { _ in }
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let buttons: [NSButton] = views.compactMap { $0 as? NSButton }
        let cancel: NSButton = try XCTUnwrap(buttons.first(where: { $0.action == NSSelectorFromString("cancelTapped") }))
        let insert: NSButton = try XCTUnwrap(buttons.first(where: { $0.action == NSSelectorFromString("submitTapped") }))
        defer { dismiss(panel, via: cancel) }
        settle(panel)
        XCTAssertEqual(panel.frame.width, 460, accuracy: 0.5, "fill-in panel widened to \(panel.frame.width)")
        assertFixedFrame(panel, expected: panel.frame.size, footer: [cancel, insert])
    }

    func testTemplatePanelAndMacroPaletteHoldTheirFrames() throws {
        SnippetTemplatePanel.present(from: nil, loc: loc) { _ in }
        let templates = try panel(named: "KeyablePanel")
        settle(templates)
        XCTAssertEqual(templates.frame.size.width, SnippetTemplatePanel.panelSize.width, accuracy: 0.5)
        XCTAssertEqual(templates.frame.size.height, SnippetTemplatePanel.panelSize.height, accuracy: 0.5)
        // The picker routes Escape through its controller's `keyDown`, not a key equivalent.
        templates.sendEvent(try escapeEvent(for: templates))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(templates.isVisible, "Escape must close the template picker")

        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.makeKeyAndOrderFront(nil)
        defer { host.close() }
        XCTAssertTrue(MacroPalettePanel.present(from: host, loc: loc) { _ in })
        defer { MacroPalettePanel.dismiss() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        // Headless XCTest does not always finish attaching a sheet; the panel exists either way.
        let palette = try XCTUnwrap(
            NSApp.windows.compactMap { $0 as? NSPanel }.first { candidate in
                guard candidate !== templates, let content = candidate.contentView else { return false }
                return candidate.frame.size == MacroPalettePanel.panelSize
                    && descendants(of: content).contains { ($0 as? NSTextField)?.isEditable == true }
            },
            "the macro palette panel must exist after present()"
        )
        settle(palette)
        XCTAssertEqual(palette.frame.size.width, MacroPalettePanel.panelSize.width, accuracy: 0.5)
        XCTAssertEqual(palette.frame.size.height, MacroPalettePanel.panelSize.height, accuracy: 0.5)
        let search = try XCTUnwrap(
            descendants(of: try XCTUnwrap(palette.contentView)).compactMap { $0 as? NSTextField }.first { $0.isEditable }
        )
        try typeText(String(repeating: "date arithmetic clipboard ", count: 30), into: search, in: palette)
        XCTAssertEqual(palette.frame.size.width, MacroPalettePanel.panelSize.width, accuracy: 0.5)
        XCTAssertEqual(palette.frame.size.height, MacroPalettePanel.panelSize.height, accuracy: 0.5)
    }
}
