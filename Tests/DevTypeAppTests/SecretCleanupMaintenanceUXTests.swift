import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

@MainActor
final class SecretCleanupMaintenanceUXTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testMaintenancePresentationClearsAStaleFailureWhenDebtReachesZero() {
        let localization = LocalizationManager()

        for language in AppLanguage.concreteCases {
            localization.language = language

            let failed = SecretCleanupMaintenancePresentation.resolve(
                pendingCount: 3,
                localization: localization
            )
            XCTAssertEqual(
                failed.text,
                localization.s("prefs.advanced.secretCleanup.failed", 3)
            )
            XCTAssertTrue(failed.isWarning)

            let recovered = SecretCleanupMaintenancePresentation.resolve(
                pendingCount: 0,
                localization: localization
            )
            XCTAssertEqual(recovered.text, localization.s("prefs.advanced.secretCleanup.none"))
            XCTAssertFalse(recovered.isWarning)
        }
    }

    func testAutomaticCleanupCompletionRefreshesTheVisibleAdvancedPane() throws {
        let delegate = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/DevTypeAppCore/AppDelegate.swift"),
            encoding: .utf8
        )
        let preferences = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/DevTypeAppCore/PreferencesWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(delegate.contains("requestOrphanSecretCleanupRetry {"))
        XCTAssertTrue(delegate.contains("refreshMaintenanceState()"))
        XCTAssertTrue(preferences.contains("func refreshMaintenanceState()"))
        XCTAssertTrue(
            preferences.contains("SecretCleanupMaintenancePresentation.resolve("),
            "Every reload must render the zero-debt state instead of leaving earlier status copy behind."
        )
    }
}
