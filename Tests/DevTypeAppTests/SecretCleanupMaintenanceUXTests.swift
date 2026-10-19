import AppKit
import ExpanderEngine
import XCTest
import SourceTreeTestSupport
@testable import DevTypeAppCore

@MainActor
final class SecretCleanupMaintenanceUXTests: XCTestCase {
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
        let delegate = try SourceTree.text("Sources/DevTypeAppCore/AppDelegate.swift")
        let preferences = try PreferencesSource.read()

        XCTAssertTrue(delegate.contains("requestOrphanSecretCleanupRetry {"))
        XCTAssertTrue(delegate.contains("refreshMaintenanceState()"))
        XCTAssertTrue(preferences.contains("func refreshMaintenanceState()"))
        XCTAssertTrue(
            preferences.contains("SecretCleanupMaintenancePresentation.resolve("),
            "Every reload must render the zero-debt state instead of leaving earlier status copy behind."
        )
    }
}
