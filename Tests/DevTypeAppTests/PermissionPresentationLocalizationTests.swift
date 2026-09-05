import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

@MainActor
final class PermissionPresentationLocalizationTests: XCTestCase {
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

    func testEveryStatusTooltipAndNameUseTheSelectedLanguage() {
        let capable = PermissionSnapshot(
            canListenTap: true,
            canUseAX: true,
            canPostEvents: true
        )
        let missing = PermissionSnapshot(
            canListenTap: false,
            canUseAX: false,
            canPostEvents: false
        )
        let degraded = PermissionSnapshot(
            canListenTap: true,
            canUseAX: true,
            canPostEvents: false
        )

        for language in AppLanguage.concreteCases {
            let localization = LocalizationManager()
            localization.language = language
            let permissionCopy = PermissionCopy.localized(using: localization)

            let needs = EngineDisplayPresentation(
                display: .needsPermissions,
                snapshot: missing,
                urgentInject: false,
                loc: localization
            )
            XCTAssertEqual(needs.statusName, localization.s("status.needsPermissions"))
            XCTAssertEqual(
                needs.toolTip,
                localization.s(
                    "status.tooltip.needsPermissions",
                    permissionCopy.missingCapabilitiesSummary(missing)
                ) + " " + localization.s("status.tooltip.eventTapRequirements")
            )

            let tapFailed = EngineDisplayPresentation(
                display: .tapFailed,
                snapshot: capable,
                urgentInject: false,
                loc: localization
            )
            XCTAssertEqual(tapFailed.statusName, localization.s("status.tapFailed"))
            XCTAssertEqual(tapFailed.toolTip, permissionCopy.tapCreateFailedDespiteListenGuidance)

            let paused = EngineDisplayPresentation(
                display: .paused,
                snapshot: capable,
                urgentInject: false,
                loc: localization
            )
            XCTAssertEqual(paused.statusName, localization.s("status.paused"))
            XCTAssertEqual(paused.toolTip, localization.s("status.tooltip.paused"))

            let secure = EngineDisplayPresentation(
                display: .secure,
                snapshot: capable,
                urgentInject: false,
                loc: localization
            )
            XCTAssertEqual(secure.statusName, localization.s("status.secure"))
            XCTAssertEqual(
                secure.toolTip,
                localization.s("status.secure.copyHelp", localization.s("menu.copySecret"))
            )

            let active = EngineDisplayPresentation(
                display: .active,
                snapshot: capable,
                urgentInject: false,
                loc: localization
            )
            XCTAssertEqual(active.statusName, localization.s("status.active"))
            XCTAssertEqual(active.toolTip, localization.s("status.tooltip.active"))

            let degradedActive = EngineDisplayPresentation(
                display: .active,
                snapshot: degraded,
                urgentInject: false,
                loc: localization
            )
            XCTAssertEqual(
                degradedActive.toolTip,
                localization.s(
                    "status.tooltip.degraded",
                    permissionCopy.missingCapabilitiesSummary(degraded)
                )
            )

            let urgentActive = EngineDisplayPresentation(
                display: .active,
                snapshot: capable,
                urgentInject: true,
                loc: localization
            )
            XCTAssertEqual(urgentActive.statusName, localization.s("status.injectIssue"))
            XCTAssertEqual(urgentActive.toolTip, localization.s("status.tooltip.injectIssue"))
        }
    }

    func testStatusButtonReceivesTheLocalizedTooltipAndAccessibilityValue() {
        _ = NSApplication.shared
        let localization = LocalizationManager()
        localization.language = .ja
        let snapshot = PermissionSnapshot(
            canListenTap: true,
            canUseAX: true,
            canPostEvents: true
        )
        let subject = StatusItemPresentation(
            display: .paused,
            snapshot: snapshot,
            isSecureInputActive: false,
            urgentInject: false,
            libraryUnhealthy: false,
            differentiateWithoutColor: true,
            highlighted: false,
            loc: localization
        )
        let button = NSButton()

        subject.apply(to: button)

        XCTAssertEqual(button.toolTip, localization.s("status.tooltip.paused"))
        XCTAssertEqual(button.accessibilityValue() as? String, localization.s("status.paused"))
        XCTAssertFalse(button.toolTip?.contains("DevType is paused") == true)
    }

    func testAppPermissionSurfacesCallTheLocalizedPresentationSeams() throws {
        let appDelegate = try source("Sources/DevTypeAppCore/AppDelegate.swift")
        let recovery = try source("Sources/DevTypeAppCore/PermissionRecoveryController.swift")
        let onboarding = try source("Sources/DevTypeAppCore/PermissionOnboardingController.swift")

        XCTAssertTrue(appDelegate.contains("permissionCopy.tapCreateFailedDespiteListenGuidance"))
        XCTAssertFalse(appDelegate.contains("message: EngineDisplayStatus.tapFailedRecoveryGuidance"))
        XCTAssertTrue(appDelegate.contains("recovery.refreshLocalization()"))
        XCTAssertTrue(appDelegate.contains("onboarding.refreshLocalization()"))
        XCTAssertTrue(recovery.contains("func refreshLocalization()"))
        XCTAssertTrue(onboarding.contains("func refreshLocalization()"))
        XCTAssertTrue(recovery.contains("EngineDisplayPresentation.statusName"))
        XCTAssertTrue(recovery.contains("permissionCopy.settingsToggleMismatchGuidance"))
        XCTAssertTrue(onboarding.contains("permissionCopy.settingsToggleMismatchGuidance"))
        XCTAssertTrue(
            appDelegate.contains("diagnosticsMenuItem?.title = \"\\(loc.s(\"menu.diagnostics\")) ⚠\""),
            "The status-item attention glyph belongs on Diagnostics"
        )
        XCTAssertFalse(
            appDelegate.contains("permissionRecoveryMenuItem?.title = \"\\(loc.s(\"menu.recovery\")) ⚠\""),
            "Permission Recovery must not carry the attention glyph; that misdirects the user away from Diagnostics"
        )
        for source in [recovery, onboarding] {
            XCTAssertTrue(source.contains("permissionCopy.unpackagedBinaryWarning"))
            XCTAssertTrue(source.contains("permissionCopy.duplicateProcessWarning"))
            XCTAssertFalse(source.contains("ProcessIdentity.unpackagedBinaryWarning"))
            XCTAssertFalse(source.contains("ProcessIdentity.duplicateProcessWarning"))
            XCTAssertFalse(source.contains("ProcessIdentity.settingsToggleMismatchGuidance"))
        }
    }

    func testMenuWarningShowsOnDiagnosticsAndNotOnPermissionRecoveryWhenAttentionNeeded() throws {
        _ = NSApplication.shared
        let originalLanguage = LocalizationManager.shared.language
        defer {
            LocalizationManager.shared.language = originalLanguage
        }

        for language in AppLanguage.concreteCases {
            LocalizationManager.shared.language = language
            let appDelegate = AppDelegate()
            appDelegate.rebuildMenuForTesting()
            appDelegate.refreshStatusItemUIForTesting()

            let loc = LocalizationManager.shared
            let recoveryTitle = appDelegate.permissionRecoveryMenuItemForTesting?.title ?? ""
            let diagnosticsTitle = appDelegate.diagnosticsMenuItemForTesting?.title ?? ""
            let cleanDiagnostics = loc.s("menu.diagnostics")
            let attentionDiagnostics = "\(cleanDiagnostics) ⚠"

            XCTAssertEqual(
                recoveryTitle,
                loc.s("menu.recovery"),
                "[\(language.rawValue)] Permission recovery title should remain the localized label"
            )
            XCTAssertFalse(
                recoveryTitle.contains("⚠"),
                "[\(language.rawValue)] Permission recovery must not show the attention glyph"
            )
            XCTAssertTrue(
                diagnosticsTitle == cleanDiagnostics || diagnosticsTitle == attentionDiagnostics,
                "[\(language.rawValue)] Diagnostics title must be the localized label, with ⚠ only when attention is needed; got \(diagnosticsTitle)"
            )
        }
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
