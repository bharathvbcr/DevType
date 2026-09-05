import AppKit
import Carbon.HIToolbox
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

@MainActor
final class P1UICompletionTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var previousLanguage: AppLanguage?

    override func setUp() {
        super.setUp()
        previousLanguage = LocalizationManager.shared.language
    }

    override func tearDown() {
        if let previousLanguage {
            LocalizationManager.shared.language = previousLanguage
        }
        super.tearDown()
    }

    func testManagerUsesReachableOverflowControlsAtTheMinimumSupportedWidth() throws {
        _ = NSApplication.shared

        for language in AppLanguage.concreteCases {
            LocalizationManager.shared.language = language
            let loc = LocalizationManager.shared
            let controller = SnippetManagerViewController()
            controller.view.frame = NSRect(x: 0, y: 0, width: 700, height: 560)
            controller.view.layoutSubtreeIfNeeded()

            let views = descendants(of: controller.view)
            let filterOverflow = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first {
                $0.identifier?.rawValue == "manager.filterOverflow"
            })
            XCTAssertTrue(filterOverflow.hasHorizontalScroller)
            let filterTitles = Set(descendants(of: filterOverflow).compactMap { ($0 as? NSButton)?.title })
            XCTAssertEqual(
                filterTitles,
                Set(SnippetFilterChip.allCases.map { loc.s($0.localizationKey) }),
                "Every localized filter must remain reachable through the overflow strip"
            )

            let utilityOverflow = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first {
                $0.identifier?.rawValue == "manager.utilityOverflow"
            })
            XCTAssertEqual(
                Set(utilityOverflow.itemTitles.dropFirst()),
                Set([loc.s("manager.import"), loc.s("manager.export"), loc.s("manager.reset")])
            )
            for item in utilityOverflow.itemArray.dropFirst() {
                XCTAssertTrue(item.target === controller)
                XCTAssertNotNil(item.action)
            }

            let bulkOverflow = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first {
                $0.identifier?.rawValue == "manager.bulkOverflow"
            })
            XCTAssertEqual(
                Set(bulkOverflow.itemTitles.dropFirst()),
                Set([
                    loc.s("manager.bulk.enable"),
                    loc.s("manager.bulk.disable"),
                    loc.s("manager.bulk.moveToGroup"),
                    loc.s("manager.bulk.duplicate"),
                    loc.s("manager.bulk.prefixSuffix"),
                    loc.s("manager.bulk.export")
                ])
            )
            for item in bulkOverflow.itemArray.dropFirst() {
                XCTAssertTrue(item.target === controller)
                XCTAssertNotNil(item.action)
            }
        }
    }

    func testManagerAndAIPreviewInstallExplicitNonOverlapLayoutContracts() throws {
        let manager = try source("Sources/DevTypeAppCore/SnippetManagerViewController.swift")
        XCTAssertTrue(manager.contains(
            "primaryStack.trailingAnchor.constraint(lessThanOrEqualTo: utilityStack.leadingAnchor"
        ))
        XCTAssertTrue(manager.contains(
            "bulkLeftStack.trailingAnchor.constraint(lessThanOrEqualTo: bulkRightStack.leadingAnchor"
        ))

        let preview = try source("Sources/DevTypeAppCore/AIPreviewPanel.swift")
        XCTAssertTrue(preview.contains(
            "let secondaryActions = NSStackView(views: [diffButton, retryButton, copyButton])"
        ))
        XCTAssertTrue(preview.contains(
            "secondaryActions.bottomAnchor.constraint(equalTo: primaryActions.topAnchor"
        ))
        XCTAssertTrue(preview.contains(
            "cancel.trailingAnchor.constraint(lessThanOrEqualTo: primaryActions.leadingAnchor"
        ))
        XCTAssertFalse(preview.contains(
            "diffButton.trailingAnchor.constraint(equalTo: retryButton.leadingAnchor"
        ))
    }

    func testShortcutCatalogContainsOnlyWiredCommandsWithExactModifiers() {
        LocalizationManager.shared.language = .en
        let loc = LocalizationManager.shared
        let search = DevTypeShortcut(
            keyCode: UInt32(kVK_ANSI_S),
            carbonModifiers: UInt32(controlKey)
        )
        let ai = DevTypeShortcut(
            keyCode: UInt32(kVK_ANSI_A),
            carbonModifiers: UInt32(optionKey)
        )
        let voice = DevTypeShortcut(
            keyCode: UInt32(kVK_F9),
            carbonModifiers: UInt32(cmdKey)
        )

        let actual = ShortcutReferenceCatalog.make(
            loc: loc,
            inlineSearch: search,
            aiPalette: ai,
            voice: voice
        ).map { ($0.title, $0.keyCaps) }
        let expected: [(String, [String])] = [
            (loc.s("home.hotkeys.search"), search.keyCaps),
            (loc.s("home.hotkeys.ai"), ai.keyCaps),
            (loc.s("home.hotkeys.dictation"), voice.keyCaps),

            (loc.s("common.edit"), ["↩"]),
            (loc.s("manager.context.duplicate"), ["⌘", "D"]),
            (loc.s("manager.context.delete"), ["⌫"]),
            (loc.s("edit.undo"), ["⌘", "Z"]),
            (loc.s("edit.redo"), ["⇧", "⌘", "Z"]),
            (loc.s("manager.bulk.selectAll"), ["⌘", "A"]),

            (loc.s("search.hint.navigate"), ["↑", "↓"]),
            (loc.s("search.hint.expand"), ["↩"]),
            (loc.s("search.hint.jump"), ["⌘", "1…9"]),
            (loc.s("palette.section.commands"), [">"]),
            (loc.s("palette.math.title"), ["="]),
            (loc.s("search.hint.close"), ["⎋"]),

            (loc.s("ai.preview.action.replace"), ["↩"]),
            (loc.s("ai.preview.replaceAndCopy"), ["⌥", "↩"]),
            (loc.s("common.copy"), ["⌘", "C"]),
            (loc.s("common.retry"), ["⌘", "R"]),
            (loc.s("common.cancel"), ["⎋"]),

            (loc.s("editor.save"), ["⌘", "↩"]),
            (loc.s("editor.macroGuide"), ["⇧", "⌘", "/"])
        ]

        XCTAssertEqual(actual.count, expected.count)
        for (index, expectedEntry) in expected.enumerated() {
            XCTAssertEqual(actual[index].0, expectedEntry.0, "Wrong command at row \(index)")
            XCTAssertEqual(actual[index].1, expectedEntry.1, "Wrong shortcut at row \(index)")
        }
    }

    func testVoiceInputsAndPrivateEditorControlsHaveStableAccessibleNames() throws {
        _ = NSApplication.shared
        LocalizationManager.shared.language = .en
        let loc = LocalizationManager.shared
        let controller = PreferencesViewController(hotkeyManager: nil)
        _ = controller.view
        defer { controller.viewWillDisappear() }
        // Panes are built on first selection, so reach the Voice controls the way a user does.
        // The labels under test belong to that pane; nothing here inspects any other.
        controller.select(.voice)

        let views = descendants(of: controller.view)
        let secureField = try XCTUnwrap(views.compactMap { $0 as? NSSecureTextField }.first)
        XCTAssertEqual(secureField.accessibilityLabel(), loc.s("prefs.voice.gemini.keyLabel"))
        XCTAssertEqual(
            try textField(placeholder: "http://localhost:11434/v1/chat/completions", in: views)
                .accessibilityLabel(),
            loc.s("prefs.voice.localLLM.endpointLabel")
        )
        XCTAssertEqual(
            try textField(placeholder: loc.s("prefs.voice.localLLM.customPlaceholder"), in: views)
                .accessibilityLabel(),
            loc.s("prefs.voice.cleanupModels")
        )
        XCTAssertEqual(
            try textField(placeholder: loc.s("prefs.voice.dict.spokenPlaceholder"), in: views)
                .accessibilityLabel(),
            loc.s("prefs.voice.dict.column.spoken")
        )
        XCTAssertEqual(
            try textField(placeholder: loc.s("prefs.voice.dict.replacementPlaceholder"), in: views)
                .accessibilityLabel(),
            loc.s("prefs.voice.dict.column.replacement")
        )
        XCTAssertEqual(
            try textField(placeholder: loc.s("prefs.voice.triggers.phrasePlaceholder"), in: views)
                .accessibilityLabel(),
            loc.s("prefs.voice.triggers.column.phrase")
        )

        let preferencesSource = try source("Sources/DevTypeAppCore/PreferencesWindowController.swift")
        for contract in [
            "geminiAPIKeyField.setAccessibilityLabel(loc.s(\"prefs.voice.gemini.keyLabel\"))",
            "geminiAPIKeyField.setAccessibilityTitleUIElement(geminiLabel)",
            "localLLMEndpointField.setAccessibilityLabel(loc.s(\"prefs.voice.localLLM.endpointLabel\"))",
            "localLLMEndpointField.setAccessibilityTitleUIElement(localEndpointLabel)",
            "localLLMModelPopup.setAccessibilityLabel(loc.s(\"prefs.voice.cleanupModels\"))",
            "localLLMModelPopup.setAccessibilityTitleUIElement(localModelLabel)",
            "localLLMModelField.setAccessibilityLabel(loc.s(\"prefs.voice.cleanupModels\"))",
            "localLLMModelField.setAccessibilityTitleUIElement(localModelLabel)",
            "voiceDictSpokenField.setAccessibilityLabel(loc.s(\"prefs.voice.dict.column.spoken\"))",
            "voiceDictReplacementField.setAccessibilityLabel(loc.s(\"prefs.voice.dict.column.replacement\"))",
            "voiceTriggerPhraseField.setAccessibilityLabel(loc.s(\"prefs.voice.triggers.column.phrase\"))",
            "voiceTriggerActionPopup.setAccessibilityLabel(loc.s(\"prefs.voice.triggers.column.action\"))"
        ] {
            XCTAssertTrue(preferencesSource.contains(contract), "Missing accessibility contract: \(contract)")
        }

        let editor = try source("Sources/DevTypeAppCore/SnippetEditorSheet.swift")
        XCTAssertTrue(editor.contains(
            "secretField.setAccessibilityLabel(loc.s(\"editor.secret.toggle\"))"
        ))

        let preview = try source("Sources/DevTypeAppCore/AIPreviewPanel.swift")
        XCTAssertTrue(preview.contains(
            "tonePopup.setAccessibilityLabel(loc.s(\"ai.preview.tone.label\"))"
        ))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func textField(placeholder: String, in views: [NSView]) throws -> NSTextField {
        try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == placeholder
        })
    }
}
