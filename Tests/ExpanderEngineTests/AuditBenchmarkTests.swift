import XCTest
@testable import ExpanderEngine

/// Measures the audit's headline paths against the *real* types, not standalone reproductions.
/// Set `DEVTYPE_BENCH=1` to run; skipped otherwise so CI is not timing-sensitive.
///
/// Each benchmark asserts a ceiling through `BenchmarkGate` (min-of-N, see BenchmarkGate.swift).
/// Ceilings are about 10x the release-build number measured on 2026-10-12 (Apple silicon,
/// Xcode 26 toolchain), rounded up, with a 15 ms floor for sub-millisecond paths where 10x would
/// sit inside scheduler noise. The measured value is recorded beside each constant. Smaller
/// sizes in a loop reuse the 2,000-size ceiling (they can only be faster).
/// Run the gate in release (`-DDEBUG` is needed because other test files use `#if DEBUG` hooks):
/// `DEVTYPE_BENCH=1 swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter AuditBenchmark`.
/// B1 (266 ms) is dominated by the save's I/O: whole-library encode, coordinated read-back, two
/// SHA-256 passes and an atomic write. It bounds the whole chain, not the snapshot rebuild alone.
final class AuditBenchmarkTests: XCTestCase {

    /// Ceilings in milliseconds; each comment is the release min-of-N the ceiling derives from.
    private enum Ceiling {
        static let p1TriggerConflicts2000: Double = 25            // release 2.20 ms; 180 ms before TriggerPrefixScan
        static let p2PrefixIndex2000: Double = 15                 // release 0.51 ms; 118 ms before TriggerPrefixScan
        static let p3Matcher20kKeystrokes: Double = 40            // release 3.39 ms
        static let p4CachedSearch1kKeystrokes2000: Double = 60    // release 5.57 ms (1,000) / 2.82 ms (2,000)
        static let p6Localization200k: Double = 1_500             // release 131.76 ms
        static let b1SaveToSnapshot2000: Double = 3_000           // release 266.12 ms
    }

    private func library(_ count: Int) -> [SnippetGroup] {
        let snippets = (0..<count).map { index in
            SnippetModel(
                title: "Snippet \(index)",
                triggerKeyword: ";trigger\(index)",
                replacementText: String(repeating: "Lorem ipsum dolor sit amet. ", count: 6),
                isCaseSensitive: false,
                requireWordBoundary: true
            )
        }
        return [SnippetGroup(name: "All", snippets: snippets)]
    }

    func testP1ConflictDetection() throws {
        try BenchmarkGate.requireBenchMode()
        for size in [500, 1_000, 2_000] {
            let groups = library(size)
            BenchmarkGate.assertWithin("P1 triggerConflicts @ \(size)", ceilingMs: Ceiling.p1TriggerConflicts2000) {
                _ = SnippetStore.triggerConflicts(in: groups)
            }
        }
    }

    func testP2PrefixIndexBuild() throws {
        try BenchmarkGate.requireBenchMode()
        for size in [500, 1_000, 2_000] {
            let snippets = library(size)[0].snippets
            BenchmarkGate.assertWithin("P2 TriggerPrefixIndex @ \(size)", ceilingMs: Ceiling.p2PrefixIndex2000) {
                _ = TriggerPrefixIndex(snippets: snippets)
            }
        }
    }

    func testP3MatcherKeystroke() throws {
        try BenchmarkGate.requireBenchMode()
        var snippets = library(500)[0].snippets
        snippets.append(SnippetModel(
            title: "Long",
            triggerKeyword: ";" + String(repeating: "z", count: 60),
            replacementText: "x",
            isCaseSensitive: false,
            requireWordBoundary: false
        ))
        let matcher = AbbreviationMatcher(snippets: snippets)
        let chars = Array("hello world this is what a user types while working ok now!")
        BenchmarkGate.assertWithin("P3 matcher x20k keystrokes (longest 61)", ceilingMs: Ceiling.p3Matcher20kKeystrokes) {
            for _ in 0..<20_000 { _ = matcher.match(characters: chars) }
        }
    }

    func testP4SearchPerKeystroke() throws {
        try BenchmarkGate.requireBenchMode()
        for size in [1_000, 2_000] {
            let groups = library(size)
            let libraryID = UUID()
            SnippetSearch.invalidateIndexCache()
            _ = SnippetSearch.run(query: "trigger1", in: groups, limit: 40, revision: 7, libraryID: libraryID)
            BenchmarkGate.assertWithin(
                "P4 cached search x1k keystrokes @ \(size)", ceilingMs: Ceiling.p4CachedSearch1kKeystrokes2000
            ) {
                for index in 0..<1_000 {
                    _ = SnippetSearch.run(
                        query: "trigger\(index % 50)", in: groups, limit: 40, revision: 7, libraryID: libraryID
                    )
                }
            }
        }
    }

    func testP6LocalizationLookup() throws {
        try BenchmarkGate.requireBenchMode()
        let loc = LocalizationManager()
        BenchmarkGate.assertWithin("P6 loc.s x200k", ceilingMs: Ceiling.p6Localization200k) {
            for _ in 0..<200_000 { _ = loc.s("common.cancel") }
        }
    }

    /// B1: a library save at 2,000 snippets, through the real store, with the production listener
    /// shape (`EventTapEngine.snippets` rebuilds `SnippetMatchSnapshot` synchronously inside the
    /// save). Measures write + listener fan-out + snapshot rebuild as one number.
    func testB1LibrarySaveToSnapshotRebuild() throws {
        try BenchmarkGate.requireBenchMode()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditBenchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "AuditBenchmark.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("snippets.json")
        let store = SnippetStore(
            location: .init(fileURL: file, expectsExistingLibrary: false),
            deviceDefaults: defaults, localSupportDirectory: directory,
            secretStore: SecretStore(backing: InMemorySecretBackingStore())
        )
        let engine = EventTapEngine()
        var rebuilds = 0
        store.addListener { snippets in
            engine.snippets = snippets
            rebuilds += 1
        }
        var groups = library(2_000)
        var toggle = false
        let ms = BenchmarkGate.assertWithin(
            "B1 save -> listener -> snapshot @ 2000", ceilingMs: Ceiling.b1SaveToSnapshot2000, runs: 7
        ) {
            toggle.toggle()
            groups[0].snippets[0].enabled = toggle
            let outcome = store.saveGroups(groups)
            XCTAssertTrue(outcome == .saved || { if case .savedWithoutBackup = outcome { return true }; return false }(),
                          "save must reach disk: \(outcome)")
        }
        XCTAssertGreaterThan(rebuilds, 1, "listener must have fired on save (took \(ms) ms)")
        XCTAssertEqual(engine.matchSnapshot.snippets.count, 2_000)
    }
}
