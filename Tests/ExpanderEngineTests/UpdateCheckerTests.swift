import XCTest
@testable import ExpanderEngine

/// Payload parsing, URL sanitization, and skip/interval policy for the update checker.
///
/// These drive `parseRelease` and the preference layer directly rather than the network: the
/// point is to pin down what DevType does with a *hostile or malformed* release payload, which is
/// not reproducible against the live GitHub API.
final class UpdateCheckerTests: XCTestCase {

    private var savedDefaults: [String: Any] = [:]

    private static let allKeys = [
        UpdatePreferences.automaticCheckEnabledKey,
        UpdatePreferences.lastCheckDateKey,
        UpdatePreferences.lastFoundVersionKey,
        UpdatePreferences.skippedVersionKey
    ]

    override func setUp() {
        super.setUp()
        // These write to `UserDefaults.standard`; snapshot and restore so the suite leaves the
        // developer's own preferences untouched.
        for key in Self.allKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                savedDefaults[key] = value
            }
        }
        UpdatePreferences.reset()
    }

    override func tearDown() {
        UpdatePreferences.reset()
        for (key, value) in savedDefaults {
            UserDefaults.standard.set(value, forKey: key)
        }
        savedDefaults = [:]
        super.tearDown()
    }

    // MARK: - Payload parsing

    private func payload(
        tag: String = "v1.3.0",
        htmlURL: String? = "https://github.com/bharathvbcr/DevType/releases/tag/v1.3.0",
        body: String? = "Fixed things.",
        name: String? = "DevType v1.3.0",
        publishedAt: String? = "2026-08-01T12:00:00Z"
    ) -> Data {
        var json: [String: Any] = ["tag_name": tag]
        if let htmlURL { json["html_url"] = htmlURL }
        if let body { json["body"] = body }
        if let name { json["name"] = name }
        if let publishedAt { json["published_at"] = publishedAt }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testParsesWellFormedRelease() throws {
        let release = try UpdateChecker.parseRelease(from: payload())
        XCTAssertEqual(release.tagName, "v1.3.0")
        XCTAssertEqual(release.version.releaseCore, "1.3.0")
        XCTAssertEqual(release.name, "DevType v1.3.0")
        XCTAssertEqual(release.notes, "Fixed things.")
        XCTAssertEqual(release.releaseURL.absoluteString,
                       "https://github.com/bharathvbcr/DevType/releases/tag/v1.3.0")
        XCTAssertNotNil(release.publishedAt)
    }

    func testRejectsNonObjectPayload() {
        XCTAssertThrowsError(try UpdateChecker.parseRelease(from: Data("[]".utf8)))
        XCTAssertThrowsError(try UpdateChecker.parseRelease(from: Data("not json".utf8)))
        XCTAssertThrowsError(try UpdateChecker.parseRelease(from: Data()))
    }

    func testRejectsMissingOrUnparseableTag() {
        let noTag = try! JSONSerialization.data(withJSONObject: ["body": "x"])
        XCTAssertThrowsError(try UpdateChecker.parseRelease(from: noTag)) { error in
            XCTAssertEqual(error as? UpdateCheckError, .malformedResponse(reason: "missing tag_name"))
        }
        XCTAssertThrowsError(try UpdateChecker.parseRelease(from: payload(tag: "nightly"))) { error in
            XCTAssertEqual(error as? UpdateCheckError, .malformedResponse(reason: "unparseable tag_name"))
        }
        XCTAssertThrowsError(try UpdateChecker.parseRelease(from: payload(tag: "   ")))
    }

    func testMissingBodyAndNameAreTolerated() throws {
        let release = try UpdateChecker.parseRelease(from: payload(body: nil, name: nil, publishedAt: nil))
        XCTAssertEqual(release.notes, "", "absent notes are empty, not a parse failure")
        XCTAssertNil(release.name)
        XCTAssertNil(release.publishedAt)
    }

    func testOversizedNotesAreTruncated() throws {
        let huge = String(repeating: "A", count: UpdateChecker.maximumNotesCharacters + 5_000)
        let release = try UpdateChecker.parseRelease(from: payload(body: huge))
        XCTAssertLessThanOrEqual(
            release.notes.count, UpdateChecker.maximumNotesCharacters + 5,
            "notes are bounded before they reach a fixed-size panel"
        )
        XCTAssertTrue(release.notes.hasSuffix("…"))
    }

    // MARK: - URL sanitization

    // `releaseURL` is handed to `NSWorkspace.open`. A payload must not be able to steer that
    // at a non-GitHub host, another repository, or a non-https scheme.

    func testRejectsForeignHostAndFallsBackToCanonicalTagURL() throws {
        let release = try UpdateChecker.parseRelease(
            from: payload(htmlURL: "https://evil.example.com/pwn")
        )
        XCTAssertEqual(release.releaseURL.host, "github.com")
        XCTAssertEqual(release.releaseURL.absoluteString,
                       "https://github.com/bharathvbcr/DevType/releases/tag/v1.3.0")
    }

    func testRejectsNonHTTPSSchemes() {
        for hostile in [
            "javascript:alert(1)",
            "file:///Applications/Calculator.app",
            "http://github.com/bharathvbcr/DevType/releases/tag/v1.3.0"
        ] {
            let url = UpdateChecker.sanitizedReleaseURL(from: hostile, tagName: "v1.3.0")
            XCTAssertEqual(url?.scheme, "https", "\(hostile) must not survive sanitization")
            XCTAssertEqual(url?.host, "github.com")
        }
    }

    func testRejectsOtherRepositoriesOnGitHub() {
        let url = UpdateChecker.sanitizedReleaseURL(
            from: "https://github.com/attacker/malware/releases/tag/v1.3.0",
            tagName: "v1.3.0"
        )
        XCTAssertEqual(url?.path, "/bharathvbcr/DevType/releases/tag/v1.3.0")
    }

    func testRejectsDotSegmentEscapeFromConfiguredRepository() {
        for hostile in [
            "https://github.com/bharathvbcr/DevType/releases/tag/../../attacker/repo",
            "https://github.com/bharathvbcr/DevType/releases/tag/%2e%2e/%2e%2e/attacker/repo"
        ] {
            let url = UpdateChecker.sanitizedReleaseURL(from: hostile, tagName: "v1.3.0")
            XCTAssertEqual(
                url?.absoluteString,
                "https://github.com/bharathvbcr/DevType/releases/tag/v1.3.0",
                "dot segments must not escape the configured release path: \(hostile)"
            )
        }
    }

    func testAcceptsLegitimateGitHubURL() {
        let legit = "https://github.com/bharathvbcr/DevType/releases/tag/v9.9.9"
        let url = UpdateChecker.sanitizedReleaseURL(from: legit, tagName: "v9.9.9")
        XCTAssertEqual(url?.absoluteString, legit)
    }

    func testNilCandidateFallsBackCleanly() {
        let url = UpdateChecker.sanitizedReleaseURL(from: nil, tagName: "v2.0.0")
        XCTAssertEqual(url?.absoluteString,
                       "https://github.com/bharathvbcr/DevType/releases/tag/v2.0.0")
    }

    func testRejectsTagsOutsideTheReleaseWorkflowContract() {
        for tag in ["1.3.0", "v1.3", "v1.3.0-rc.1", "v1.3.0/../../attacker"] {
            XCTAssertThrowsError(try UpdateChecker.parseRelease(from: payload(tag: tag)), tag)
            XCTAssertNil(UpdateChecker.sanitizedReleaseURL(from: nil, tagName: tag), tag)
        }
    }

    // MARK: - Skip policy

    func testSkippingSuppressesThatVersionOnly() {
        UpdatePreferences.skip(AppVersion("1.3.0")!)
        XCTAssertTrue(UpdatePreferences.isSkipped(AppVersion("1.3.0")!))
        XCTAssertTrue(UpdatePreferences.isSkipped(AppVersion("v1.3.0")!),
                      "skip compares versions, not strings")
        XCTAssertFalse(UpdatePreferences.isSkipped(AppVersion("1.4.0")!),
                       "skipping one version must not mute every future release")
        XCTAssertTrue(UpdatePreferences.isSkipped(AppVersion("1.2.0")!),
                      "an older release than the skipped one stays suppressed")
    }

    func testNothingIsSkippedByDefault() {
        XCTAssertFalse(UpdatePreferences.isSkipped(AppVersion("1.0.0")!))
    }

    func testGarbageSkipValueDoesNotSuppressUpdates() {
        // Fail open on unparseable state: a corrupt preference must not silently mute updates.
        UserDefaults.standard.set("garbage", forKey: UpdatePreferences.skippedVersionKey)
        XCTAssertFalse(UpdatePreferences.isSkipped(AppVersion("1.3.0")!))
    }

    // MARK: - Automatic check policy

    func testAutomaticCheckIsOffByDefault() {
        XCTAssertFalse(UpdatePreferences.automaticCheckEnabled,
                       "no network request until the user opts in")
        XCTAssertFalse(UpdatePreferences.isAutomaticCheckDue(),
                       "never due while disabled, regardless of elapsed time")
    }

    func testAutomaticCheckDueOnlyAfterInterval() {
        UpdatePreferences.automaticCheckEnabled = true
        XCTAssertTrue(UpdatePreferences.isAutomaticCheckDue(), "due when never checked")

        let now = Date()
        UpdatePreferences.lastSuccessfulCheck = now
        XCTAssertFalse(UpdatePreferences.isAutomaticCheckDue(now: now.addingTimeInterval(60)))
        XCTAssertTrue(UpdatePreferences.isAutomaticCheckDue(
            now: now.addingTimeInterval(UpdatePreferences.automaticCheckInterval + 1)
        ))
    }

    func testClockMovedBackwardsDoesNotBlockChecksForever() {
        UpdatePreferences.automaticCheckEnabled = true
        let now = Date()
        // A timezone edit or NTP correction can leave the stored timestamp in the future.
        UpdatePreferences.lastSuccessfulCheck = now.addingTimeInterval(90 * 24 * 60 * 60)
        XCTAssertTrue(UpdatePreferences.isAutomaticCheckDue(now: now),
                      "a future timestamp must not wedge checking for 90 days")
    }

    func testLastCheckRoundTripsAndClears() {
        XCTAssertNil(UpdatePreferences.lastSuccessfulCheck)
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        UpdatePreferences.lastSuccessfulCheck = stamp
        XCTAssertEqual(
            UpdatePreferences.lastSuccessfulCheck?.timeIntervalSince1970 ?? 0,
            stamp.timeIntervalSince1970,
            accuracy: 0.001
        )
        UpdatePreferences.lastSuccessfulCheck = nil
        XCTAssertNil(UpdatePreferences.lastSuccessfulCheck)
    }

    func testRecordingSuccessfulCheckPublishesOnlyAfterTimestampAndVersionAreCoherent() {
        let stamp = Date(timeIntervalSince1970: 1_800_000_123)
        let version = AppVersion("2.4.6")!
        let observed = expectation(
            forNotification: UpdatePreferences.didChangeNotification,
            object: nil
        ) { _ in
            XCTAssertEqual(
                UpdatePreferences.lastSuccessfulCheck?.timeIntervalSince1970 ?? 0,
                stamp.timeIntervalSince1970,
                accuracy: 0.001
            )
            XCTAssertEqual(UpdatePreferences.lastFoundVersion, version.rawValue)
            return true
        }

        UpdatePreferences.recordSuccessfulCheck(at: stamp, latestVersion: version)

        wait(for: [observed], timeout: 0.5)
    }

    // MARK: - Outcome distinctness

    func testFailureIsNeverEqualToUpToDate() {
        // The invariant that keeps a broken updater from reading as "no updates exist".
        let current = AppVersion("1.0.0")!
        let upToDate = UpdateCheckOutcome.upToDate(current: current, latest: current)
        for failure in [
            UpdateCheckOutcome.failed(.offline),
            .failed(.timedOut),
            .failed(.rateLimited),
            .failed(.notFound),
            .failed(.responseTooLarge),
            .undeterminedLocalVersion(raw: nil)
        ] {
            XCTAssertNotEqual(failure, upToDate)
        }
    }

    func testEveryErrorHasANonEmptyUserMessage() {
        for error: UpdateCheckError in [
            .offline, .timedOut, .rateLimited, .notFound,
            .httpError(status: 500), .malformedResponse(reason: "x"),
            .responseTooLarge, .cancelled
        ] {
            XCTAssertFalse(error.userMessage.isEmpty)
            XCTAssertFalse(error.userMessage.contains("http"),
                           "user-facing text carries no URLs or raw payload")
        }
    }
}
