import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

private final class WeakReference<Object: AnyObject> {
    weak var value: Object?

    init(_ value: Object?) {
        self.value = value
    }
}

@MainActor
final class RuntimeLocalizationUXTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testEveryAIActionDescriptionAndBehaviorResolvesInEveryLanguage() {
        for kind in AITransformKind.allCases {
            let presentation = AIActionPresentation(kind: kind)
            for language in AppLanguage.concreteCases {
                let table = LocalizationManager.stringTable(for: language)
                XCTAssertNotNil(
                    table[presentation.descriptionKey],
                    "\(language.rawValue) is missing \(presentation.descriptionKey)"
                )
                XCTAssertNotNil(
                    table[presentation.behavior.localizationKey],
                    "\(language.rawValue) is missing \(presentation.behavior.localizationKey)"
                )
            }
        }
    }

    func testAIActionBehaviorClassificationCoversEveryKind() {
        let expected: [AITransformKind: AIActionBehavior] = [
            .proofread: .preserves,
            .rewrite: .rewrites,
            .paraphrase: .rewrites,
            .expand: .expands,
            .condense: .shortens,
            .mergeRewrite: .shortens,
            .formal: .rewrites,
            .friendly: .rewrites,
            .bulletize: .rewrites,
            .promptEnhance: .rewrites,
            .explainCode: .expands,
            .generateDocstring: .expands,
            .fixCode: .rewrites,
            .toJson: .rewrites,
            .generateUnitTests: .expands,
            .gitCommitMessage: .shortens,
            .explainRegex: .expands,
            .sqlQuery: .rewrites,
            .removeMarkdown: .shortens,
            .toMarkdown: .rewrites,
            .translate: .preserves,
            .translateTelugu: .preserves,
            .translateHindi: .preserves,
            .custom: .rewrites
        ]

        XCTAssertEqual(Set(expected.keys), Set(AITransformKind.allCases))
        for kind in AITransformKind.allCases {
            XCTAssertEqual(AIActionPresentation(kind: kind).behavior, expected[kind])
        }
    }

    func testAIActionFilterUsesLocalizedTitleDescriptionAndBehavior() {
        let strings = [
            "ai.kind.proofread": "Correct",
            "ai.kind.proofread.description": "Grammar and spelling",
            "ai.kind.condense": "Tighten",
            "ai.kind.condense.description": "Remove filler",
            "ai.badge.preserves": "Same size",
            "ai.badge.shortens": "Compact"
        ]
        let localize: (String) -> String = { strings[$0] ?? $0 }
        let actions: [AITransformKind] = [.proofread, .condense]

        XCTAssertEqual(
            AIActionPaletteProjection(actions: actions, query: "grammar", localize: localize).actions,
            [.proofread]
        )
        XCTAssertEqual(
            AIActionPaletteProjection(actions: actions, query: "compact", localize: localize).actions,
            [.condense]
        )
        XCTAssertEqual(
            AIActionPaletteProjection(actions: actions, query: "  ", localize: localize).actions,
            actions
        )
    }

    func testAIActionProjectionMakesNoResultsAnExplicitState() {
        let projection = AIActionPaletteProjection(
            actions: [.proofread, .condense],
            query: "definitely-not-present",
            localize: { $0 }
        )

        XCTAssertTrue(projection.actions.isEmpty)
        XCTAssertTrue(projection.showsEmptyState)
        XCTAssertNil(projection.initialSelection)
    }

    func testVisibleStatusPillsUseLocalizedKeys() throws {
        XCTAssertEqual(SnippetStore.ImportPreview.Status.isNew.localizationKey, "import.preview.status.new")
        XCTAssertEqual(SnippetStore.ImportPreview.Status.isUpdate.localizationKey, "import.preview.status.update")
        XCTAssertEqual(SnippetStore.ImportPreview.Status.isConflict.localizationKey, "import.preview.status.conflict")

        let requiredKeys = [
            "import.preview.status.new",
            "import.preview.status.update",
            "import.preview.status.conflict",
            "ai.palette.quick",
            "ai.palette.empty",
            "ai.palette.emptyHint",
            "manager.groups.caption",
            "manager.resources.cleanupFailed.title",
            "manager.resources.cleanupFailed.message",
            "manager.action.stale.message"
        ]
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for key in requiredKeys {
                XCTAssertNotNil(table[key], "\(language.rawValue) is missing \(key)")
            }
        }

        let appDelegate = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Sources/DevTypeAppCore/AppDelegate.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(appDelegate.contains("PillBadgeView(text: loc.s(\"status.active\")"))
        XCTAssertFalse(appDelegate.contains("PillBadgeView(text: \"Active\""))
    }

    func testImportModeSelectorRendersItsLocalizedLabelAndAccessibilityName() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/DevTypeAppCore/SnippetImportPreviewSheet.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("root.addSubview(modeRow)"),
            "The localized import-mode label must be attached with its popup, not constructed and discarded."
        )
        XCTAssertTrue(
            source.contains("modePopup.setAccessibilityLabel(loc.s(\"import.preview.mode\"))"),
            "VoiceOver needs the import-mode popup's purpose, not only its selected item."
        )
        XCTAssertFalse(source.contains("root.addSubview(modePopup)"))
    }

    func testLongLivedWindowLanguageRefreshPreservesUserState() throws {
        let preferences = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/DevTypeAppCore/PreferencesWindowController.swift"),
            encoding: .utf8
        )
        let manager = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/DevTypeAppCore/SnippetManagerViewController.swift"),
            encoding: .utf8
        )
        let delegate = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Sources/DevTypeAppCore/AppDelegate.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(preferences.contains("func refreshLocalization()"))
        XCTAssertTrue(preferences.contains("localizationState()"))
        XCTAssertTrue(preferences.contains("restorationState:"))
        XCTAssertTrue(manager.contains("struct SnippetManagerLocalizationState"))
        XCTAssertTrue(manager.contains("localizationState()"))
        XCTAssertTrue(manager.contains("snippetUndoManager:"))
        XCTAssertTrue(delegate.contains("refreshSnippetManagerLocalization()"))
        XCTAssertTrue(delegate.contains("PreferencesWindowController.shared.refreshLocalization()"))
    }

    func testPreferencesControllerRestoresEveryUncommittedEditorValue() {
        _ = NSApplication.shared
        let state = PreferencesLocalizationState(
            selectedTab: .general,
            macroArgument: "draft macro argument",
            aiAllowlistBundleID: "com.example.Draft",
            voiceDictionarySpoken: "spoken draft",
            voiceDictionaryReplacement: "replacement draft",
            voiceTriggerPhrase: "trigger draft",
            geminiAPIKey: "unsaved credential draft",
            localLLMEndpoint: "http://127.0.0.1:1234/v1/chat/completions",
            localLLMModel: "draft-model",
            scrollOrigins: Dictionary(
                uniqueKeysWithValues: PreferencesTab.visibleCases.map { ($0, NSPoint.zero) }
            )
        )
        let controller = PreferencesViewController(
            hotkeyManager: nil,
            restorationState: state
        )

        _ = controller.view

        XCTAssertEqual(controller.localizationState(), state)
    }

    func testSnippetManagerRebuildRebindsTheStableUndoTarget() {
        let undoManager = UndoManager()
        var original: SnippetManagerViewController? = SnippetManagerViewController(
            restorationState: nil,
            snippetUndoManager: undoManager
        )
        let target = original!.snippetUndoTarget
        let releasedOriginal = WeakReference(original)

        let replacement = SnippetManagerViewController(
            restorationState: nil,
            snippetUndoManager: undoManager,
            snippetUndoTarget: target
        )
        original = nil

        XCTAssertNil(releasedOriginal.value)
        XCTAssertTrue(target.owner === replacement)
        XCTAssertTrue(replacement.undoManager === undoManager)
    }

    func testRestoredAllSnippetsSelectionDoesNotBecomeTheFirstGroup() {
        _ = NSApplication.shared
        let state = SnippetManagerLocalizationState(
            selectedGroupID: nil,
            selectedSnippetIDs: [],
            filterText: "",
            filterChip: .all,
            isCompactDensity: false,
            sortMode: .manual,
            groupScrollOrigin: .zero,
            snippetScrollOrigin: .zero
        )
        let controller = SnippetManagerViewController(restorationState: state)

        _ = controller.view

        XCTAssertNil(controller.localizationState().selectedGroupID)
    }

    func testAIActionPanelNoLongerRendersOrFiltersWithEnglishLiterals() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("Sources/DevTypeAppCore/AIActionPanel.swift"),
            encoding: .utf8
        )
        let retired = [
            "Fix grammar, spelling, and typos",
            "Improve clarity, flow, and tone",
            "Preserves length",
            "Shortens",
            "Expands",
            "Rewrites",
            "\"Quick\"",
            "Custom instruction…"
        ]
        for literal in retired {
            XCTAssertFalse(source.contains(literal), "AI action UI still embeds English: \(literal)")
        }
        XCTAssertTrue(source.contains("emptyState.isHidden = !projection.showsEmptyState"))
        XCTAssertTrue(source.contains("tableView.deselectAll(nil)"))
    }
}
