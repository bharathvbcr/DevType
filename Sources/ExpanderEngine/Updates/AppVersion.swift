import Foundation

/// A parsed DevType version, ordered the way *this project's* version strings actually mean things.
///
/// This is deliberately **not** a plain SemVer comparator, because `Scripts/package-app.sh`
/// stamps `CFBundleShortVersionString` from `git describe --tags --always --dirty=+dirty`, and
/// git-describe's suffix inverts SemVer's meaning:
///
/// | String                    | git describe means      | SemVer would say        |
/// |---------------------------|-------------------------|-------------------------|
/// | `1.2.0`                   | exactly the v1.2.0 tag  | release 1.2.0           |
/// | `1.2.0-4-gabc1234`        | **4 commits AFTER** it  | *pre-release* of 1.2.0  |
/// | `1.2.0-beta.1`            | (a real pre-release)    | pre-release of 1.2.0    |
///
/// Reading `1.2.0-4-gabc1234` as SemVer makes it *older* than `1.2.0`, so a maintainer running a
/// build four commits past the tag would be told to "update" to the release they are already
/// ahead of — a permanent false nag on exactly the machines that do the releasing. So the
/// git-describe distance suffix (`-<N>-g<sha>`) is detected specifically and ordered *above* the
/// bare tag, while any other pre-release suffix keeps its SemVer meaning and orders *below* it.
///
/// Ordering within one `major.minor.patch` core, lowest to highest:
///
///     1.2.0-beta.1  <  1.2.0  <  1.2.0-4-gabc1234  <  1.2.0-9-gdef5678
///
/// Build metadata (`+dirty`) is ignored for ordering, per SemVer, but preserved on `isDirty`.
public struct AppVersion: Equatable, Comparable, CustomStringConvertible, Sendable {

    /// `major.minor.patch`. Missing trailing components parse as 0 (`1.2` → `1.2.0`).
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// Dot-separated SemVer pre-release identifiers (`beta.1` → `["beta", "1"]`).
    /// Empty when the version is a plain release or a git-describe build.
    public let prerelease: [String]

    /// Commits since the nearest tag, from git describe's `-<N>-g<sha>` suffix.
    /// `nil` when the build sits exactly on a tag (or the string had no such suffix).
    public let commitsAhead: Int?

    /// Short commit hash from the git-describe suffix, without the `g` prefix.
    public let commitHash: String?

    /// True when `+dirty` was present — the tree had uncommitted changes at package time.
    public let isDirty: Bool

    /// The exact string this was parsed from, for display and diagnostics.
    public let rawValue: String

    /// A build that is not exactly a tagged release: ahead of the tag, dirty, or pre-release.
    /// Update prompts are suppressed for these — a developer's working build should not be
    /// nagged to "downgrade" onto the release it was built past.
    public var isDevelopmentBuild: Bool {
        (commitsAhead ?? 0) > 0 || isDirty || !prerelease.isEmpty
    }

    /// `major.minor.patch` with no suffixes — what a user recognizes as "the version".
    public var releaseCore: String { "\(major).\(minor).\(patch)" }

    public var description: String { rawValue }

    // MARK: - Parsing

    /// Parses a version string, tolerating the forms this project actually produces:
    /// `1.2.0`, `v1.2.0`, `1.2.0+dirty`, `1.2.0-4-gabc1234`, `1.2.0-4-gabc1234+dirty`,
    /// `1.2.0-beta.1`, and short forms like `1.2` or `1`.
    ///
    /// Returns `nil` for anything without a numeric core — including the bare commit hash
    /// `git describe --always` emits in a repository with no tags at all. A `nil` here must
    /// never be treated as "up to date"; see `UpdateCheckOutcome.undeterminedLocalVersion`.
    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        rawValue = trimmed

        // Strip a leading `v` / `V` (git tags are `v1.2.0`; the plist stores `1.2.0`).
        var working = trimmed
        if let first = working.first, first == "v" || first == "V" {
            working.removeFirst()
        }

        // Split off build metadata (`+dirty`, `+20260829`). Ignored for ordering per SemVer.
        var dirty = false
        if let plus = working.firstIndex(of: "+") {
            let metadata = String(working[working.index(after: plus)...])
            dirty = metadata.contains("dirty")
            working = String(working[..<plus])
        }
        isDirty = dirty

        // Split core from the pre-release / git-describe suffix at the FIRST hyphen.
        let coreString: String
        var suffix: String?
        if let hyphen = working.firstIndex(of: "-") {
            coreString = String(working[..<hyphen])
            suffix = String(working[working.index(after: hyphen)...])
        } else {
            coreString = working
        }

        // The core must be numeric. `abc1234` (no-tags git describe) fails here by design.
        let components = coreString.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 3 else { return nil }
        var numbers: [Int] = []
        for component in components {
            // `Int("1_000")` and `Int("+1")` both parse; require plain digits so a
            // malformed core is rejected rather than silently reinterpreted.
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(component) else { return nil }
            numbers.append(value)
        }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0

        // Classify the suffix: git-describe distance, or a genuine SemVer pre-release.
        if let suffix, !suffix.isEmpty {
            if let (distance, hash) = Self.parseGitDescribeSuffix(suffix) {
                commitsAhead = distance
                commitHash = hash
                prerelease = []
            } else {
                commitsAhead = nil
                commitHash = nil
                prerelease = suffix.split(separator: ".").map(String.init)
            }
        } else {
            commitsAhead = nil
            commitHash = nil
            prerelease = []
        }
    }

    /// Matches git describe's `<N>-g<sha>` tail (the leading hyphen is already consumed).
    ///
    /// Anchored on both ends: `4-gabc1234` matches, but `beta.1`, `rc-1`, and `4-gzzz` do not,
    /// so a real pre-release is never mistaken for "ahead of the tag".
    private static func parseGitDescribeSuffix(_ suffix: String) -> (Int, String)? {
        guard let separator = suffix.range(of: "-g", options: .backwards) else { return nil }
        let distancePart = String(suffix[..<separator.lowerBound])
        let hashPart = String(suffix[separator.upperBound...])

        guard !distancePart.isEmpty,
              distancePart.allSatisfy({ $0.isASCII && $0.isNumber }),
              let distance = Int(distancePart) else { return nil }
        // Git's abbreviated hashes are >= 4 hex chars; require hex so `-glorious` is not a hash.
        guard hashPart.count >= 4,
              hashPart.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return (distance, hashPart)
    }

    // MARK: - Ordering

    /// Rank of the suffix class within one `major.minor.patch`, per the table above.
    /// Pre-release sorts below the bare tag; git-describe distance sorts above it.
    private var suffixRank: Int {
        if let commitsAhead, commitsAhead > 0 { return 1 }
        if !prerelease.isEmpty { return -1 }
        return 0
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    /// Total ordering. Build metadata (`+dirty`) is excluded, so `1.2.0` and `1.2.0+dirty`
    /// compare `.orderedSame` — a dirty tree is not a different *version*.
    public static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> ComparisonResult {
        if lhs.major != rhs.major { return lhs.major < rhs.major ? .orderedAscending : .orderedDescending }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor ? .orderedAscending : .orderedDescending }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch ? .orderedAscending : .orderedDescending }

        if lhs.suffixRank != rhs.suffixRank {
            return lhs.suffixRank < rhs.suffixRank ? .orderedAscending : .orderedDescending
        }

        switch lhs.suffixRank {
        case 1:
            let left = lhs.commitsAhead ?? 0
            let right = rhs.commitsAhead ?? 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
            return .orderedSame
        case -1:
            return comparePrerelease(lhs.prerelease, rhs.prerelease)
        default:
            return .orderedSame
        }
    }

    /// SemVer §11.4 pre-release ordering: numeric identifiers compare numerically and rank
    /// below alphanumeric ones; a shorter identifier list ranks below a longer one that shares
    /// its prefix (`1.0.0-beta` < `1.0.0-beta.1`).
    private static func comparePrerelease(_ lhs: [String], _ rhs: [String]) -> ComparisonResult {
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            if left == right { continue }

            let leftNumber = left.allSatisfy { $0.isASCII && $0.isNumber } ? Int(left) : nil
            let rightNumber = right.allSatisfy { $0.isASCII && $0.isNumber } ? Int(right) : nil

            switch (leftNumber, rightNumber) {
            case let (l?, r?):
                return l < r ? .orderedAscending : .orderedDescending
            case (_?, nil):
                return .orderedAscending   // numeric ranks below alphanumeric
            case (nil, _?):
                return .orderedDescending
            case (nil, nil):
                return left < right ? .orderedAscending : .orderedDescending
            }
        }
        if lhs.count == rhs.count { return .orderedSame }
        return lhs.count < rhs.count ? .orderedAscending : .orderedDescending
    }

    // MARK: - Current build

    /// The running app's version, read from `CFBundleShortVersionString`.
    ///
    /// `nil` when the key is missing or unparseable — which is the real situation for
    /// `swift run` builds (no bundle) and for a no-tags `git describe`. Callers must surface
    /// that as its own outcome rather than defaulting to a version and comparing against it.
    public static func current(bundle: Bundle = .main) -> AppVersion? {
        guard let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return AppVersion(raw)
    }
}
