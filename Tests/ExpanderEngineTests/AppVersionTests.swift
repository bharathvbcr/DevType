import XCTest
@testable import ExpanderEngine

/// Ordering and parsing for `AppVersion`.
///
/// The load-bearing cases are the git-describe ones. `Scripts/package-app.sh` stamps
/// `CFBundleShortVersionString` from `git describe --tags --always --dirty=+dirty`, whose
/// `-<N>-g<sha>` suffix means "N commits *after* the tag" while SemVer reads the same characters
/// as a *pre-release of* that tag. A comparator that gets this backwards tells every maintainer
/// running a post-tag build to "update" to the release they are already ahead of.
final class AppVersionTests: XCTestCase {

    // MARK: - Parsing

    func testParsesPlainRelease() throws {
        let version = try XCTUnwrap(AppVersion("1.2.3"))
        XCTAssertEqual(version.major, 1)
        XCTAssertEqual(version.minor, 2)
        XCTAssertEqual(version.patch, 3)
        XCTAssertTrue(version.prerelease.isEmpty)
        XCTAssertNil(version.commitsAhead)
        XCTAssertFalse(version.isDirty)
        XCTAssertFalse(version.isDevelopmentBuild)
        XCTAssertEqual(version.releaseCore, "1.2.3")
    }

    func testStripsLeadingV() throws {
        // Release tags are `v1.2.0`; the plist stores `1.2.0`. They must compare equal.
        let tag = try XCTUnwrap(AppVersion("v1.2.0"))
        let plist = try XCTUnwrap(AppVersion("1.2.0"))
        XCTAssertEqual(AppVersion.compare(tag, plist), .orderedSame)
        XCTAssertEqual(tag.rawValue, "v1.2.0", "rawValue preserves what was actually parsed")
    }

    func testParsesShortForms() {
        XCTAssertEqual(AppVersion("1")?.releaseCore, "1.0.0")
        XCTAssertEqual(AppVersion("1.4")?.releaseCore, "1.4.0")
    }

    func testParsesGitDescribeSuffix() throws {
        let version = try XCTUnwrap(AppVersion("0.2.1-4-gabc1234"))
        XCTAssertEqual(version.releaseCore, "0.2.1")
        XCTAssertEqual(version.commitsAhead, 4)
        XCTAssertEqual(version.commitHash, "abc1234")
        XCTAssertTrue(version.prerelease.isEmpty, "a describe suffix is not a pre-release")
        XCTAssertTrue(version.isDevelopmentBuild)
    }

    func testParsesDirtyMarker() throws {
        let clean = try XCTUnwrap(AppVersion("1.2.0"))
        let dirty = try XCTUnwrap(AppVersion("1.2.0+dirty"))
        XCTAssertFalse(clean.isDirty)
        XCTAssertTrue(dirty.isDirty)
        XCTAssertTrue(dirty.isDevelopmentBuild)
        XCTAssertEqual(
            AppVersion.compare(clean, dirty), .orderedSame,
            "build metadata is excluded from ordering per SemVer"
        )
    }

    func testParsesDirtyGitDescribeCombination() throws {
        let version = try XCTUnwrap(AppVersion("0.2.1-4-gabc1234+dirty"))
        XCTAssertEqual(version.commitsAhead, 4)
        XCTAssertEqual(version.commitHash, "abc1234")
        XCTAssertTrue(version.isDirty)
    }

    func testParsesRealPrerelease() throws {
        let version = try XCTUnwrap(AppVersion("1.0.0-beta.1"))
        XCTAssertEqual(version.prerelease, ["beta", "1"])
        XCTAssertNil(version.commitsAhead, "beta.1 is not a git-describe distance")
        XCTAssertTrue(version.isDevelopmentBuild)
    }

    func testRejectsNonNumericCore() {
        // `git describe --always` in a repo with no tags emits a bare short hash. That is not a
        // version, and must not silently parse as one.
        XCTAssertNil(AppVersion("abc1234"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("   "))
        XCTAssertNil(AppVersion("v"))
        XCTAssertNil(AppVersion("1.2.3.4"), "four components is not a version this project emits")
        XCTAssertNil(AppVersion("1.x.0"))
        XCTAssertNil(AppVersion("1..0"))
        XCTAssertNil(AppVersion("+1.2.0"))
    }

    func testParsesNoTagFallbackFormAsPrerelease() throws {
        // package-app.sh's no-tag fallback: `0.0.0-<shorthash>`.
        let version = try XCTUnwrap(AppVersion("0.0.0-abc1234"))
        XCTAssertEqual(version.releaseCore, "0.0.0")
        XCTAssertTrue(version.isDevelopmentBuild)
    }

    // MARK: - Ordering: core

    func testOrdersByCore() {
        assertAscending("1.0.0", "1.0.1")
        assertAscending("1.0.9", "1.1.0")
        assertAscending("1.9.0", "2.0.0")
        assertAscending("0.2.1", "0.10.0", "minor is numeric, not lexicographic")
        assertAscending("1.0.2", "1.0.10", "patch is numeric, not lexicographic")
    }

    // MARK: - Ordering: the git-describe trap

    func testGitDescribeBuildIsNewerThanItsTag() {
        // The whole reason this type exists. Naive SemVer returns the opposite.
        assertAscending("1.2.0", "1.2.0-4-gabc1234",
                        "4 commits past v1.2.0 is NEWER than v1.2.0")
    }

    func testGreaterDistanceIsNewer() {
        assertAscending("1.2.0-4-gabc1234", "1.2.0-9-gdef5678")
    }

    func testRealPrereleaseIsOlderThanItsRelease() {
        assertAscending("1.0.0-beta.1", "1.0.0", "a real pre-release keeps its SemVer meaning")
    }

    func testFullOrderingWithinOneCore() throws {
        // 1.2.0-beta.1  <  1.2.0  <  1.2.0-4-gabc  <  1.2.0-9-gdef
        let ordered = ["1.2.0-beta.1", "1.2.0", "1.2.0-4-gabc1234", "1.2.0-9-gdef5678"]
            .map { AppVersion($0)! }
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            XCTAssertEqual(
                AppVersion.compare(lower, higher), .orderedAscending,
                "\(lower.rawValue) should sort below \(higher.rawValue)"
            )
        }
        XCTAssertEqual(ordered.sorted().map(\.rawValue), ordered.map(\.rawValue))
    }

    func testDevBuildAheadOfTagIsNotOfferedTheTagAsAnUpdate() throws {
        // The false-nag scenario, stated as the behavior that matters.
        let localDevBuild = try XCTUnwrap(AppVersion("1.2.0-4-gabc1234+dirty"))
        let latestRelease = try XCTUnwrap(AppVersion("v1.2.0"))
        XCTAssertEqual(
            AppVersion.compare(latestRelease, localDevBuild), .orderedAscending,
            "the published release is older than the local build; no update should be offered"
        )
    }

    func testDevBuildIsStillOfferedAGenuinelyNewerRelease() throws {
        let localDevBuild = try XCTUnwrap(AppVersion("1.2.0-4-gabc1234"))
        let newerRelease = try XCTUnwrap(AppVersion("v1.3.0"))
        XCTAssertEqual(AppVersion.compare(newerRelease, localDevBuild), .orderedDescending)
    }

    // MARK: - Ordering: SemVer pre-release rules

    func testPrereleaseIdentifierOrdering() {
        assertAscending("1.0.0-alpha", "1.0.0-alpha.1", "shorter prefix sorts lower")
        assertAscending("1.0.0-alpha.1", "1.0.0-alpha.beta", "numeric ranks below alphanumeric")
        assertAscending("1.0.0-alpha", "1.0.0-beta")
        assertAscending("1.0.0-beta.2", "1.0.0-beta.11", "numeric identifiers compare numerically")
    }

    // MARK: - Suffixes that only look like git describe

    func testAmbiguousSuffixesAreNotMistakenForDistance() throws {
        // Must NOT parse as a distance, or they would sort above their release.
        for raw in ["1.0.0-rc-1", "1.0.0-4-gzzzz", "1.0.0-x-gabc1234", "1.0.0-4-gabc"] {
            let version = try XCTUnwrap(AppVersion(raw), "\(raw) should still parse")
            XCTAssertNil(version.commitsAhead, "\(raw) must not parse as a git-describe distance")
        }
        // `-4-gabc` has only 3 hex chars after `g`; git abbreviates to at least 4.
        assertAscending("1.0.0-4-gabc", "1.0.0", "an unrecognized suffix stays a pre-release")
    }

    func testEqualityAndSameness() throws {
        let a = try XCTUnwrap(AppVersion("1.2.3"))
        let b = try XCTUnwrap(AppVersion("1.2.3"))
        XCTAssertEqual(a, b)
        XCTAssertEqual(AppVersion.compare(a, b), .orderedSame)
        XCTAssertFalse(a < b)
    }

    // MARK: - Helper

    private func assertAscending(
        _ lower: String,
        _ higher: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let low = AppVersion(lower), let high = AppVersion(higher) else {
            return XCTFail("failed to parse \(lower) or \(higher)", file: file, line: line)
        }
        XCTAssertEqual(
            AppVersion.compare(low, high), .orderedAscending,
            message.isEmpty ? "\(lower) should sort below \(higher)" : message,
            file: file, line: line
        )
        XCTAssertEqual(
            AppVersion.compare(high, low), .orderedDescending,
            "ordering must be antisymmetric", file: file, line: line
        )
    }
}
