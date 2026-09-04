import XCTest
@testable import ExpanderEngine

final class PermissionIdentityLocalizationTests: XCTestCase {
    private var previousLanguageValue: Any?

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

    func testIdentityWarningsKeepTechnicalValuesButTranslateTheirInstructions() throws {
        let binaryPath = "/tmp/private-build/DevType"
        let siblingPaths = ["/Applications/DevType Beta.app", "/tmp/DevType.app"]
        let hash = "ABCDEF1234"

        for language in AppLanguage.concreteCases {
            let localization = LocalizationManager()
            localization.language = language
            let copy = PermissionCopy.localized(using: localization)

            let unpackaged = try XCTUnwrap(copy.unpackagedBinaryWarning(bundlePath: binaryPath))
            XCTAssertTrue(unpackaged.contains(binaryPath))
            XCTAssertTrue(unpackaged.contains(ProcessIdentity.preferredInstalledAppPath))
            XCTAssertTrue(unpackaged.contains(ProcessIdentity.expectedBundleIdentifier))

            let duplicate = try XCTUnwrap(copy.duplicateProcessWarning(siblingPaths: siblingPaths))
            XCTAssertTrue(duplicate.contains(siblingPaths[0]))
            XCTAssertTrue(duplicate.contains(siblingPaths[1]))

            let mismatch = copy.settingsToggleMismatchGuidance(
                executablePath: binaryPath,
                cdHash: hash
            )
            XCTAssertTrue(mismatch.contains(binaryPath))
            XCTAssertTrue(mismatch.contains(hash))
            XCTAssertTrue(mismatch.contains(ProcessIdentity.expectedBundleIdentifier))

            let stale = try XCTUnwrap(copy.staleLegacyBundleWarning(
                runningBundleIDs: [ProcessIdentity.legacyStaleBundleIdentifier]
            ))
            XCTAssertTrue(stale.contains(ProcessIdentity.legacyStaleBundleIdentifier))
            XCTAssertTrue(stale.contains(ProcessIdentity.expectedBundleIdentifier))

            let developmentRunning = try XCTUnwrap(copy.dualInstallWarning(
                runningPath: "/tmp/DevType.app",
                applicationsExists: true,
                buildBundleExists: true
            ))
            XCTAssertTrue(developmentRunning.contains(ProcessIdentity.preferredInstalledAppPath))
            XCTAssertTrue(developmentRunning.contains(ProcessIdentity.developmentAppPathHint))

            if language != .en {
                XCTAssertFalse(unpackaged.contains("This process is not a packaged"))
                XCTAssertFalse(duplicate.contains("Other DevType copies are running"))
                XCTAssertFalse(mismatch.contains("If Settings shows DevType enabled"))
                XCTAssertFalse(stale.contains("A process still uses the stale bundle id"))
                XCTAssertFalse(developmentRunning.contains("Both /Applications"))
            }
        }
    }

    func testLocalizedIdentityWarningPredicatesMatchTheLegacyDiagnosticContract() {
        let copy = PermissionCopy.localized(using: LocalizationManager())

        XCTAssertNil(copy.unpackagedBinaryWarning(bundlePath: "/tmp/DevType.app"))
        XCTAssertNil(copy.duplicateProcessWarning(siblingPaths: []))
        XCTAssertNil(copy.staleLegacyBundleWarning(runningBundleIDs: [
            ProcessIdentity.expectedBundleIdentifier
        ]))
        XCTAssertNil(copy.dualInstallWarning(
            runningPath: "/tmp/DevType.app",
            applicationsExists: false,
            buildBundleExists: true
        ))
    }

    func testNotListedGuidanceUsesLocalizedIdentityWarnings() throws {
        let localization = LocalizationManager()
        localization.language = .ko
        let copy = PermissionCopy.localized(using: localization)
        let path = "/tmp/private-build/DevType"
        let sibling = "/tmp/DevType Other.app"

        let guidance = copy.notListedInSettingsGuidance(
            for: .inputMonitoring,
            bundleID: ProcessIdentity.expectedBundleIdentifier,
            appPath: path,
            siblingPaths: [sibling],
            binaryPath: path
        )

        XCTAssertTrue(guidance.contains(path))
        XCTAssertTrue(guidance.contains(sibling))
        XCTAssertFalse(guidance.contains("This process is not a packaged"))
        XCTAssertFalse(guidance.contains("Other DevType copies are running"))
    }
}
