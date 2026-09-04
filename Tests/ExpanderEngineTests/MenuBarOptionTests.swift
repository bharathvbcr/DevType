import XCTest
@testable import ExpanderEngine

/// The status-menu options added for failure recovery and feature toggles:
/// a Restart Engine item that appears only while the last expansion refused or failed,
/// a kill switch for every registered keyboard shortcut, and a switch for trigger-conflict
/// reporting.
final class MenuBarOptionTests: XCTestCase {

    func testOnlyConfirmedInjectionOutcomesCountAsExpansionSuccess() {
        XCTAssertTrue(PermissionCoordinator.InjectOutcome.succeeded.isConfirmedSuccess)
        XCTAssertTrue(PermissionCoordinator.InjectOutcome.degradedAXOnly.isConfirmedSuccess)
        XCTAssertFalse(PermissionCoordinator.InjectOutcome.postedUnverified.isConfirmedSuccess)
        XCTAssertFalse(PermissionCoordinator.InjectOutcome.refused("blocked").isConfirmedSuccess)
        XCTAssertFalse(PermissionCoordinator.InjectOutcome.failedSilent.isConfirmedSuccess)
    }

    private func appSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return SourceContractTests.strippingComments(
            try String(contentsOf: url, encoding: .utf8)
        )
    }

    // MARK: - Restart after a failed expansion

    /// The failure slot must be clearable: the restart action acknowledges the failure, and the
    /// status item keeps flagging urgent until the slot empties or a success overwrites it.
    func testClearingTheLastInjectOutcomeEmptiesOnlyTheOutcomeSlot() {
        let coordinator = PermissionCoordinator()
        coordinator.recordInjectOutcome(
            .refused("Erase precondition failed before paste — field no longer holds the trigger")
        )
        XCTAssertNotNil(coordinator.lastRecordedInjectOutcome)
        XCTAssertNotNil(
            coordinator.lastRecordedInjectRefuseProvenance,
            "A refuse records its provenance for the diagnostic report."
        )

        coordinator.clearLastInjectOutcome()
        XCTAssertNil(coordinator.lastRecordedInjectOutcome)
        XCTAssertNotNil(
            coordinator.lastRecordedInjectRefuseProvenance,
            "Clearing acknowledges the failure; it must not erase the evidence of what happened."
        )
    }

    /// The menu item's visibility must be bound to the recorded outcome, and the restart action
    /// must clear that outcome — otherwise the item either never appears or never disappears.
    func testRestartMenuItemIsWiredToTheFailureState() throws {
        let source = try appSource("Sources/DevTypeAppCore/AppDelegate.swift")
        XCTAssertTrue(
            source.contains("restartEngineMenuItem?.isHidden = !urgentInject"),
            "Restart must be visible exactly while the last expansion refused or failed."
        )
        XCTAssertTrue(
            source.contains("func restartEngine(_ sender: NSMenuItem)"),
            "The status menu needs the restart action itself."
        )
        XCTAssertTrue(
            source.contains("clearLastInjectOutcome()"),
            "Restart must clear the recorded failure, or the urgent state survives the restart."
        )
        XCTAssertTrue(
            source.contains("blocksDefaultEventTap"),
            "A restart with revoked permissions must route to recovery, not pretend it worked."
        )
    }

    // MARK: - Keyboard shortcuts kill switch

    func testHotkeyRegistrationIsGatedOnThePreference() throws {
        let source = try appSource("Sources/DevTypeAppCore/HotkeyManager.swift")
        XCTAssertTrue(
            source.contains("guard !HotkeyPreferences.shortcutsDisabled else"),
            "registerAll() is the single choke point; the kill switch must live there so a "
                + "rebind while disabled cannot silently re-register."
        )
    }

    /// A menu that advertises ⌘/ while the hotkey is unregistered is a lie users will report.
    func testDisabledShortcutsAlsoHideTheMenuKeyEquivalent() throws {
        let source = try appSource("Sources/DevTypeAppCore/AppDelegate.swift")
        XCTAssertTrue(
            source.contains("guard !HotkeyPreferences.shortcutsDisabled else { return \"\" }"),
            "hotkeyMenuKeyEquivalent must stop advertising a chord that no longer fires."
        )
    }

    // MARK: - Conflict detection switch

    func testConflictDetectionDefaultsOnAndRoundTrips() {
        let key = SnippetStore.conflictDetectionDisabledDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(
            SnippetStore.isConflictDetectionEnabled,
            "Warnings are on by default — silence is opt-in."
        )
        SnippetStore.isConflictDetectionEnabled = false
        XCTAssertFalse(SnippetStore.isConflictDetectionEnabled)
        SnippetStore.isConflictDetectionEnabled = true
        XCTAssertTrue(SnippetStore.isConflictDetectionEnabled)
    }

    /// The preference gates *reporting*, never the detector: the pure function stays honest so
    /// tests and internal callers see real collisions regardless of the switch.
    func testPureDetectorIgnoresThePreference() {
        let key = SnippetStore.conflictDetectionDisabledDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.set(true, forKey: key)

        let colliding = [
            SnippetGroup(name: "G", snippets: [
                SnippetModel(title: "A", triggerKeyword: ":x", replacementText: "1"),
                SnippetModel(title: "B", triggerKeyword: ":x", replacementText: "2"),
            ])
        ]
        XCTAssertFalse(
            SnippetStore.triggerConflicts(in: colliding).isEmpty,
            "triggerConflicts(in:) is the detector, not the reporter — it must not consult "
                + "the preference."
        )
    }

    /// Both reporting surfaces must consult the switch. Editor hosts may not substitute their own
    /// partial validator (or a permissive closure); one canonical owner applies the preference and
    /// delegates exact, case-folded, and prefix semantics to the pure store detector.
    func testReportingSurfacesConsultThePreference() throws {
        let transaction = try appSource("Sources/DevTypeAppCore/SnippetEditTransaction.swift")
        XCTAssertTrue(
            transaction.contains("detectionEnabled: Bool = SnippetStore.isConflictDetectionEnabled"),
            "The editor's canonical validator must honour the global switch."
        )
        let editor = try appSource("Sources/DevTypeAppCore/SnippetEditorSheet.swift")
        XCTAssertTrue(editor.contains("SnippetTriggerAuthoringValidator.conflict("))
        XCTAssertFalse(editor.contains("validate: @escaping"))

        for path in [
            "Sources/DevTypeAppCore/AppDelegate.swift",
            "Sources/DevTypeAppCore/HomeViewController.swift",
            "Sources/DevTypeAppCore/SnippetManagerViewController.swift",
        ] {
            XCTAssertFalse(
                try appSource(path).contains("validate: { _, _ in nil }"),
                "\(path) must not bypass canonical trigger validation."
            )
        }
        let store = try appSource("Sources/ExpanderEngine/Models/SnippetStore.swift")
        XCTAssertTrue(
            store.contains("guard Self.isConflictDetectionEnabled else { return [] }"),
            "The instance triggerConflicts() report must honour the switch."
        )
    }

    // MARK: - Localization

    /// Every new menu title ships in every language, or one locale gets a raw key in the menu.
    func testNewMenuTitlesAreLocalizedEverywhere() {
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for key in ["menu.restartEngine", "menu.hotkeys.toggle", "menu.conflicts.toggle"] {
                XCTAssertNotNil(
                    table[key],
                    "\(language.rawValue) is missing \(key)"
                )
            }
        }
    }
}
