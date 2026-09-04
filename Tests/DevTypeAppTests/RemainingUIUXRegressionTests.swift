import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

@MainActor
final class RemainingUIUXRegressionTests: XCTestCase {
    private var previousLanguageValue: Any?

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    override func setUp() {
        super.setUp()
        previousLanguageValue = UserDefaults.standard.object(forKey: LocalizationManager.deviceKey)
    }

    override func tearDown() {
        if let previousLanguageValue {
            UserDefaults.standard.set(previousLanguageValue, forKey: LocalizationManager.deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
        }
        super.tearDown()
    }

    func testActivityRowPresentationKeepsEveryLongCharacterForTooltipAndVoiceOver() throws {
        let title = String(repeating: "Long activity title ", count: 20)
        let details = String(repeating: "Exact diagnostic detail 7F41 ", count: 80)
        let event = ActivityHistoryStore.ActivityEvent(
            category: .general,
            title: title,
            details: details
        )
        let presentation = ActivityEventRowPresentation(
            event: event,
            localization: LocalizationManager()
        )

        XCTAssertEqual(presentation.title, title)
        XCTAssertEqual(presentation.details, details)
        XCTAssertEqual(presentation.accessibilityLabel, title)
        XCTAssertEqual(presentation.accessibilityValue, details)

        let row = ActivityEventRowView(
            event: event,
            localization: LocalizationManager(),
            onAction: { _ in }
        )
        let labels = descendants(of: row).compactMap { $0 as? NSTextField }
        let renderedTitle = try XCTUnwrap(labels.first { $0.stringValue == title })
        let renderedDetails = try XCTUnwrap(labels.first { $0.stringValue == details })
        XCTAssertEqual(renderedTitle.toolTip, title)
        XCTAssertEqual(renderedTitle.accessibilityLabel(), title)
        XCTAssertEqual(renderedDetails.toolTip, details)
        XCTAssertEqual(renderedDetails.accessibilityLabel(), details)
        XCTAssertEqual(renderedDetails.accessibilityValue(), details)
    }

    func testActivityRowTimestampUsesTheSelectedAppLanguage() throws {
        _ = NSApplication.shared
        let localization = LocalizationManager()
        localization.language = .ja
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let event = ActivityHistoryStore.ActivityEvent(
            timestamp: timestamp,
            category: .general,
            title: "title",
            details: "details"
        )
        let expectedFormatter = DateFormatter()
        expectedFormatter.locale = Locale(identifier: localization.effectiveLanguageCode())
        expectedFormatter.timeStyle = .short
        expectedFormatter.dateStyle = .none
        let expected = expectedFormatter.string(from: timestamp)

        let presentation = ActivityEventRowPresentation(
            event: event,
            localization: localization
        )
        XCTAssertEqual(presentation.timestampText, expected)

        let row = ActivityEventRowView(
            event: event,
            localization: localization,
            onAction: { _ in }
        )
        XCTAssertTrue(descendants(of: row).contains {
            ($0 as? NSTextField)?.stringValue == expected
        })
    }

    func testRecoveredDictationTimestampUsesTheSelectedAppLanguage() {
        let localization = LocalizationManager()
        localization.language = .ja
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: localization.effectiveLanguageCode())
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let presentation = RecoveredDictationPresentation(
            characterCount: 42,
            recordedAt: timestamp,
            localization: localization
        )

        XCTAssertEqual(presentation.timestampText, formatter.string(from: timestamp))
        XCTAssertEqual(
            presentation.guidance,
            localization.s("activity.recovery.guidance", 42, presentation.timestampText)
        )
    }

    func testRecoveredDictationWindowProvidesStandardKeyboardActions() throws {
        _ = NSApplication.shared
        let localization = LocalizationManager.shared
        let snapshot = VoiceSessionSnapshot(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            speechProvider: SpeechProviderDescriptor(
                id: "test.speech",
                displayName: "Test Speech",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly
            ),
            correctionProvider: CorrectionProviderDescriptor(
                id: "test.correction",
                displayName: "Test Correction",
                modelVersion: "1",
                privacyRoute: .onDeviceOnly
            ),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: "com.example.target", processIdentifier: 42)
        )
        let session = RecoverableVoiceSession(
            snapshot: snapshot,
            directoryURL: FileManager.default.temporaryDirectory,
            audioFileURL: nil,
            rawTranscript: RawTranscript(
                text: "Exact recovered transcript",
                localeIdentifier: "en_US",
                providerID: "test.speech",
                modelVersion: "1"
            ),
            finalTranscript: nil,
            receipt: nil,
            isDelivered: false
        )
        let controller = RecoveredDictationWindowController(
            session: session,
            activityEventID: UUID()
        )
        let buttons = try XCTUnwrap(controller.window?.contentView).subviewsRecursive
            .compactMap { $0 as? NSButton }
        let copy = try XCTUnwrap(buttons.first { $0.title == localization.s("common.copy") })
        let close = try XCTUnwrap(buttons.first { $0.title == localization.s("common.close") })

        XCTAssertEqual(copy.keyEquivalent, "\r")
        XCTAssertEqual(close.keyEquivalent, "\u{1b}")
    }

    func testActivityPersistenceFailureIsNotPresentedAsGenuinelyEmpty() {
        _ = NSApplication.shared
        for language in AppLanguage.concreteCases {
            let localization = LocalizationManager()
            localization.language = language
            let healthy = ActivityHistoryEmptyPresentation(
                persistenceHealth: .init(lastFailureKind: nil),
                localization: localization
            )
            let failed = ActivityHistoryEmptyPresentation(
                persistenceHealth: .init(lastFailureKind: "private/path/sentinel"),
                localization: localization
            )

            XCTAssertEqual(healthy.title, localization.s("activity.empty"))
            XCTAssertNil(healthy.details)
            XCTAssertEqual(failed.title, localization.s("activity.unavailable"))
            XCTAssertEqual(failed.details, localization.s("activity.unavailable.hint"))
            XCTAssertFalse(failed.title.contains("sentinel"))
            XCTAssertFalse(failed.details?.contains("sentinel") == true)

            let view = ActivityHistoryEmptyStateView(presentation: failed)
            XCTAssertEqual(view.accessibilityLabel(), failed.title)
            XCTAssertEqual(view.accessibilityHelp(), failed.details)
        }
    }

    func testShortcutProjectionMakesNoMatchesExplicitAndSearchesEveryVisibleField() {
        let entries = [
            ShortcutReferenceEntry(
                section: "Global",
                title: "Open Palette",
                keyCaps: ["⌘", "K"],
                note: "Everywhere"
            ),
            ShortcutReferenceEntry(
                section: "Editor",
                title: "Save",
                keyCaps: ["⌘", "S"],
                note: nil
            )
        ]

        XCTAssertEqual(
            ShortcutReferenceProjection(entries: entries, query: "everywhere").entries,
            [entries[0]]
        )
        XCTAssertEqual(
            ShortcutReferenceProjection(entries: entries, query: "⌘ s").entries,
            [entries[1]]
        )
        XCTAssertEqual(
            ShortcutReferenceProjection(entries: entries, query: "  ").entries,
            entries
        )
        let empty = ShortcutReferenceProjection(entries: entries, query: "no-such-shortcut")
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertTrue(empty.showsEmptyState)
    }

    func testShortcutReferenceRefreshesVisibleChromeForTheCurrentLanguage() throws {
        _ = NSApplication.shared
        let localization = LocalizationManager()
        localization.language = .en
        let controller = ShortcutReferenceViewController(localization: localization)
        let window = NSWindow(contentViewController: controller)
        _ = controller.view
        controller.viewWillAppear()
        defer { controller.viewWillDisappear() }

        XCTAssertEqual(window.title, localization.s("shortcuts.window.title"))
        XCTAssertTrue(descendants(of: controller.view).contains {
            ($0 as? NSTextField)?.stringValue == localization.s("shortcuts.window.title")
        })
        XCTAssertEqual(
            descendants(of: controller.view).compactMap { $0 as? NSSearchField }.first?.placeholderString,
            localization.s("shortcuts.search")
        )

        localization.language = .ja

        XCTAssertEqual(window.title, localization.s("shortcuts.window.title"))
        XCTAssertTrue(descendants(of: controller.view).contains {
            ($0 as? NSTextField)?.stringValue == localization.s("shortcuts.window.title")
        })
        XCTAssertTrue(descendants(of: controller.view).contains {
            ($0 as? NSButton)?.title == localization.s("prefs.tab.hotkeys")
        })
    }

    func testShortcutNoResultsIsVisibleAndExposesAnAccessibleExplanation() throws {
        _ = NSApplication.shared
        let localization = LocalizationManager()
        localization.language = .en
        let controller = ShortcutReferenceViewController(localization: localization)
        _ = controller.view
        let search = try XCTUnwrap(
            descendants(of: controller.view).compactMap { $0 as? NSSearchField }.first
        )

        search.stringValue = "no-such-shortcut-7F41"
        _ = search.sendAction(search.action, to: search.target)

        let expectedTitle = localization.s("shortcuts.empty")
        let expectedHint = localization.s("shortcuts.emptyHint")
        let accessibleEmptyState = try XCTUnwrap(descendants(of: controller.view).first {
            !$0.isHidden && $0.accessibilityLabel() == expectedTitle
        })
        XCTAssertEqual(accessibleEmptyState.accessibilityHelp(), expectedHint)
        XCTAssertTrue(descendants(of: accessibleEmptyState).contains {
            ($0 as? NSTextField)?.stringValue == expectedTitle
        })
        XCTAssertTrue(descendants(of: accessibleEmptyState).contains {
            ($0 as? NSTextField)?.stringValue == expectedHint
        })
        XCTAssertEqual(controller.numberOfRows(in: NSTableView()), 0)
    }

    func testShortcutAndScopeFeedbackKeysExistInEveryLanguage() {
        let keys = [
            "shortcuts.empty",
            "shortcuts.emptyHint",
            "appscope.bundleID.duplicate",
            "common.choose"
        ]
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for key in keys {
                XCTAssertNotNil(table[key], "\(language.rawValue) is missing \(key)")
            }
        }
    }

    func testAppScopeEntryPlanRejectsCaseInsensitiveAndInBatchDuplicates() {
        let plan = SnippetAppScopeEntryPlan(
            rawValues: [
                " COM.Example.App ",
                "com.example.New",
                "COM.EXAMPLE.NEW",
                "  ",
                "com.example.Other"
            ],
            existing: ["  com.example.app\n"]
        )

        XCTAssertEqual(plan.additions, ["com.example.New", "com.example.Other"])
        XCTAssertEqual(plan.duplicateCount, 2)
    }

    func testDuplicateAppScopeEntryProducesVisibleAndAccessibilityFeedback() {
        _ = NSApplication.shared
        let localization = LocalizationManager()
        localization.language = .en
        var announcements: [String] = []
        let controller = AppScopeController(
            scope: SnippetAppScope(includeApps: ["com.example.App"], excludeApps: []),
            loc: localization,
            announcement: { announcements.append($0) },
            feedbackSound: {},
            onFinish: { _ in }
        )
        _ = controller.view

        controller.addEntries([" COM.EXAMPLE.APP "])

        let expected = localization.s("appscope.bundleID.duplicate")
        XCTAssertEqual(announcements, [expected])
        let feedbackLabel = descendants(of: controller.view)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == expected }
        XCTAssertNotNil(feedbackLabel)
        XCTAssertEqual(feedbackLabel?.accessibilityLabel(), expected)
        XCTAssertEqual(feedbackLabel?.accessibilityHelp(), expected)
        XCTAssertEqual(controller.scope.includeApps, ["com.example.App"])
    }

    func testImagePickerPromptUsesLocalizedChrome() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/DevTypeAppCore/SnippetEditorSheet.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("panel.prompt = loc.s(\"common.choose\")"))
        XCTAssertFalse(source.contains("panel.prompt = \"Choose\""))
    }

    func testVisibleEditorFallbacksAndPlaceholdersAreLocalized() {
        let localization = LocalizationManager()
        for language in AppLanguage.concreteCases {
            localization.language = language
            let table = LocalizationManager.stringTable(for: language)
            XCTAssertNotNil(table["editor.untitled"])
            XCTAssertNotNil(table["editor.trigger.placeholder"])
            XCTAssertEqual(
                SnippetEditorSheet.derivedTitle(from: " \n\t", localization: localization),
                localization.s("editor.untitled")
            )
        }
    }

    func testEditorTriggerPlaceholderUsesTheLocalizedKey() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/DevTypeAppCore/SnippetEditorSheet.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "placeholder(loc.s(\"editor.trigger.placeholder\"))"
        ))
        XCTAssertFalse(source.contains("placeholder(\"e.g. :eml\")"))
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

private extension NSView {
    var subviewsRecursive: [NSView] {
        [self] + subviews.flatMap(\.subviewsRecursive)
    }
}
