import AppKit
import Foundation
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

@MainActor
final class UpdateFlowTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        DevTypeAlert.presenterOverride = nil
        DevTypeAlert.scrollablePresenterOverride = nil
        super.tearDown()
    }

    func testPresentSilentWhenNothingToReportSuppressesAlerts() {
        var alertPresented = false
        DevTypeAlert.presenterOverride = { _, _, _, _, _, _ in
            alertPresented = true
        }
        DevTypeAlert.scrollablePresenterOverride = { _, _, _, _, _, _, _, _ in
            alertPresented = true
        }

        let currentVersion = AppVersion("1.0.0")!
        let latestVersion = AppVersion("1.0.0")!
        let release = ReleaseInfo(
            version: latestVersion,
            tagName: "v1.0.0",
            name: "Release",
            notes: "Notes",
            releaseURL: URL(string: "https://github.com/bharathvbcr/DevType/releases/tag/v1.0.0")!,
            publishedAt: Date()
        )

        UpdateFlow.present(.skipped(release), window: nil, silentWhenNothingToReport: true)
        XCTAssertFalse(alertPresented)

        UpdateFlow.present(.upToDate(current: currentVersion, latest: latestVersion), window: nil, silentWhenNothingToReport: true)
        XCTAssertFalse(alertPresented)

        UpdateFlow.present(.undeterminedLocalVersion(raw: "custom-build"), window: nil, silentWhenNothingToReport: true)
        XCTAssertFalse(alertPresented)

        UpdateFlow.present(.failed(.timedOut), window: nil, silentWhenNothingToReport: true)
        XCTAssertFalse(alertPresented)
    }

    func testPresentUpdateAvailableWithNotesAndButtons() {
        let newerVersion = AppVersion("1.1.0")!
        let release = ReleaseInfo(
            version: newerVersion,
            tagName: "v1.1.0",
            name: "Release 1.1.0",
            notes: "Bug fixes and improvements",
            releaseURL: URL(string: "https://github.com/bharathvbcr/DevType/releases/tag/v1.1.0")!,
            publishedAt: Date()
        )

        var scrollableCapturedTitle: String?
        var scrollableCapturedNotes: String?
        var scrollableCapturedButtons: [String]?
        var scrollableCallback: ((Int) -> Void)?

        DevTypeAlert.scrollablePresenterOverride = { title, _, _, notes, _, buttons, _, handler in
            scrollableCapturedTitle = title
            scrollableCapturedNotes = notes
            scrollableCapturedButtons = buttons
            scrollableCallback = handler
        }

        UpdateFlow.present(.updateAvailable(release), window: nil, silentWhenNothingToReport: false)

        XCTAssertNotNil(scrollableCapturedTitle)
        XCTAssertEqual(scrollableCapturedNotes, "Bug fixes and improvements")
        XCTAssertEqual(scrollableCapturedButtons?.count, 3)

        // Exercise skip button callback (index 1)
        scrollableCallback?(1)
        XCTAssertTrue(UpdatePreferences.isSkipped(release.version))

        // Reset skip for isolation
        UserDefaults.standard.removeObject(forKey: "DevTypeSkippedUpdateVersion")
    }

    func testPresentUpdateAvailableWithEmptyNotes() {
        let newerVersion = AppVersion("1.2.0")!
        let emptyNotesRelease = ReleaseInfo(
            version: newerVersion,
            tagName: "v1.2.0",
            name: nil,
            notes: "",
            releaseURL: URL(string: "https://github.com/bharathvbcr/DevType/releases/tag/v1.2.0")!,
            publishedAt: nil
        )

        var scrollableCapturedNotes: String?
        DevTypeAlert.scrollablePresenterOverride = { _, _, _, notes, _, _, _, _ in
            scrollableCapturedNotes = notes
        }

        UpdateFlow.present(.updateAvailable(emptyNotesRelease), window: nil, silentWhenNothingToReport: false)

        XCTAssertEqual(scrollableCapturedNotes, LocalizationManager.shared.s("updates.releaseNotes.empty"))
    }

    func testPresentUpToDateNormalAndDevBuild() {
        let currentVersion = AppVersion("1.0.0")!
        let latestVersion = AppVersion("1.0.0")!

        var capturedStyle: NSAlert.Style?
        var capturedMessage: String?

        DevTypeAlert.presenterOverride = { _, message, style, _, _, _ in
            capturedMessage = message
            capturedStyle = style
        }

        UpdateFlow.present(
            .upToDate(current: currentVersion, latest: latestVersion),
            window: nil,
            silentWhenNothingToReport: false
        )

        XCTAssertEqual(capturedStyle, .informational)
        XCTAssertTrue(capturedMessage?.contains("1.0.0") == true)

        // Development build ahead of release
        let devVersion = AppVersion("2.0.0-dev")!
        UpdateFlow.present(
            .upToDate(current: devVersion, latest: latestVersion),
            window: nil,
            silentWhenNothingToReport: false
        )

        XCTAssertEqual(capturedStyle, .informational)
        XCTAssertTrue(capturedMessage?.contains("2.0.0-dev") == true)
    }

    func testPresentUndeterminedLocalVersionAndFailed() {
        var capturedStyle: NSAlert.Style?
        DevTypeAlert.presenterOverride = { _, _, style, _, _, _ in
            capturedStyle = style
        }

        UpdateFlow.present(.undeterminedLocalVersion(raw: nil), window: nil, silentWhenNothingToReport: false)
        XCTAssertEqual(capturedStyle, .warning)

        UpdateFlow.present(.failed(.offline), window: nil, silentWhenNothingToReport: false)
        XCTAssertEqual(capturedStyle, .warning)
    }

    func testCheckAutomaticallyIfDueSuppressedWhenDisabled() {
        let original = UpdatePreferences.automaticCheckEnabled
        defer { UpdatePreferences.automaticCheckEnabled = original }

        UpdatePreferences.automaticCheckEnabled = false
        UpdateFlow.checkAutomaticallyIfDue()
        // No crash, returns immediately
    }

    func testCheckAutomaticallyIfDueWhenEnabled() {
        let original = UpdatePreferences.automaticCheckEnabled
        defer { UpdatePreferences.automaticCheckEnabled = original }

        UpdatePreferences.automaticCheckEnabled = true
        UpdateFlow.checkAutomaticallyIfDue()
    }

    func testCheckManuallyAndConcurrency() {
        DevTypeAlert.presenterOverride = { _, _, _, _, _, _ in }
        UpdateFlow.checkManually()
        // Rapid second call tests the guard !isChecking else { return }
        UpdateFlow.checkManually()
    }

    func testPresentUpdateAvailableDefaultButtonBranch() {
        let release = ReleaseInfo(
            version: AppVersion("2.0.0")!,
            tagName: "v2.0.0",
            name: "V2",
            notes: "Notes",
            releaseURL: URL(string: "https://github.com/bharathvbcr/DevType/releases/tag/v2.0.0")!,
            publishedAt: Date()
        )

        var callback: ((Int) -> Void)?
        DevTypeAlert.scrollablePresenterOverride = { _, _, _, _, _, _, _, handler in
            callback = handler
        }

        UpdateFlow.present(.updateAvailable(release), window: nil, silentWhenNothingToReport: false)
        callback?(2) // exercises default: break
    }
}
