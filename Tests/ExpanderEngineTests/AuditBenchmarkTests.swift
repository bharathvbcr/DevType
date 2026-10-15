import XCTest
@testable import ExpanderEngine

/// Measures the audit's headline paths against the *real* types, not standalone reproductions.
/// Set `DEVTYPE_BENCH=1` to run; skipped otherwise so CI is not timing-sensitive.
///
/// Each benchmark asserts a ceiling through `BenchmarkGate` (min-of-N, see BenchmarkGate.swift).
/// Ceilings are about 10x a release-build number, rounded up, with a 15 ms floor for
/// sub-millisecond paths where 10x would sit inside scheduler noise. The constants below were
/// set from the 2026-10-12 sample. Re-measured 2026-10-14 in release on this worktree (min-of-N);
/// every constant still holds, and that sample is the number beside each constant. Smaller
/// sizes in a loop reuse the 2,000-size ceiling (they can only be faster).
/// Run the gate in release (`-DDEBUG` is needed because other test files use `#if DEBUG` hooks):
/// `DEVTYPE_BENCH=1 swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter AuditBenchmark`.
/// B1 re-measured 29.04 ms (min of 7). The 2026-10-12 sample was 266.12 ms, before the matcher
/// build moved off the main thread. The number still bounds the whole chain: encode, coordinated
/// read-back, two SHA-256 passes, the atomic write, and the waited snapshot. The digest stays.
final class AuditBenchmarkTests: XCTestCase {

    /// Ceilings in milliseconds; each comment is the release min-of-N the ceiling derives from.
    private enum Ceiling {
        static let p1TriggerConflicts2000: Double = 25            // 2026-10-14 release 0.88 ms @ 2000; 2026-10-12 was 2.20; 180 ms before TriggerPrefixScan
        static let p2PrefixIndex2000: Double = 15                 // 2026-10-14 release 0.34 ms @ 2000; 2026-10-12 was 0.51; 118 ms before TriggerPrefixScan
        static let p3Matcher20kKeystrokes: Double = 40            // 2026-10-14 release 1.69 ms; 2026-10-12 was 3.39
        static let p4CachedSearch1kKeystrokes2000: Double = 60    // 2026-10-14 release 0.20 ms at 1,000 and at 2,000; 2026-10-12 was 5.57 / 2.82
        static let p6Localization200k: Double = 1_500             // 2026-10-14 release 10.74 ms; 2026-10-12 was 131.76
        static let b1SaveToSnapshot2000: Double = 3_000           // 2026-10-14 release 29.04 ms (min of 7); 2026-10-12 was 266.12 before the off-main hop
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
    /// shape. `applySnippetSnapshot` builds the matcher off the main thread; this bench waits
    /// so the number still includes that build.
    ///
    /// The coordinated whole-file read and the SHA-256 digest are unchanged. They are the
    /// §1.13 race guard and the backup source. Skipping the hash on size and mtime would
    /// weaken that check. Release 2026-10-14 measured the whole chain at 29.04 ms (min of 7,
    /// ceiling 3000). That closes the I/O part of B1: it is not worth a weaker guard.
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
            let semaphore = DispatchSemaphore(value: 0)
            engine.applySnippetSnapshot(snippets) { semaphore.signal() }
            semaphore.wait()
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
        XCTAssertFalse(engine.lastSnippetSnapshotBuiltOnMain,
                       "the waited production hop must build the matcher off the main thread")
    }

    /// B6: folding newlines on a multi-megabyte clipboard, then taking 80 characters, scans the
    /// whole paste. The clipped window does not. Interleaved so load hits both sides.
    /// Release 2026-10-14, min of 5: clip window 0.01 ms vs full fold 27.91 ms. Ceiling 15 ms.
    func testB6ClipboardPreviewWindowVersusFullFold() throws {
        try BenchmarkGate.requireBenchMode()
        let text = String(repeating: "line\n", count: 400_000)
        let pair = BenchmarkGate.interleaved(rounds: 5, {
            _ = CommandPaletteCatalog.clippedClipboardPreview(text)
        }, {
            let folded = text.replacingOccurrences(of: "\n", with: " ")
            _ = folded.count > 80 ? String(folded.prefix(77)) + "…" : folded
        })
        print(String(format: "  B6 clip window %8.2f ms vs full fold %8.2f ms", pair.a, pair.b))
        XCTAssertLessThan(pair.a, pair.b, "clipping the window should beat folding the whole paste")
        let result = BenchmarkGate.verdict(measuredMs: pair.a, ceilingMs: 15)
        if !result.passed {
            XCTFail(String(format: "B6 clip window %.2f ms exceeds 15 ms", pair.a))
        }
    }

    /// B8: the conflict chip used to run the whole-library scan inside the per-row filter.
    /// One scan versus a per-row repeat. The once-side ceiling is the regression gate.
    /// Release 2026-10-14, min of 3: one scan 0.16 ms vs 40 scans 6.44 ms. Ceiling 50 ms.
    func testB8ConflictScanOnceVersusPerRow() throws {
        try BenchmarkGate.requireBenchMode()
        let groups = library(400)
        let pair = BenchmarkGate.interleaved(rounds: 3, {
            _ = SnippetStore.triggerConflicts(in: groups)
        }, {
            for _ in 0..<40 { _ = SnippetStore.triggerConflicts(in: groups) }
        })
        print(String(format: "  B8 one scan %8.2f ms vs 40 scans %8.2f ms", pair.a, pair.b))
        XCTAssertLessThan(pair.a, pair.b)
        let result = BenchmarkGate.verdict(measuredMs: pair.a, ceilingMs: 50)
        if !result.passed {
            XCTFail(String(format: "B8 one scan %.2f ms exceeds 50 ms", pair.a))
        }
    }

    /// B11 stand-in. This is not the CGEvent tap callback. It is seven uncontended locks plus
    /// one capped ring copy, which is the shape of a no-match key after the ring rewrite.
    /// Restructuring the tap's locks is a separate card; this number says the stand-in is small.
    /// Release 2026-10-14, min of 5: 0.14 ms. Ceiling 20 ms.
    func testB11UncontendedLockAndRingStandIn() throws {
        try BenchmarkGate.requireBenchMode()
        let locks = (0..<7).map { _ in UnfairLock() }
        var ring = CharacterRingBuffer(capacity: 64)
        for character in "abcdefghijklmnopqrstuvwxyz0123456789" {
            ring.append(character)
        }
        BenchmarkGate.assertWithin("B11 7 locks + ring copy x1000 (stand-in)", ceilingMs: 20) {
            for _ in 0..<1_000 {
                for lock in locks {
                    lock.lock()
                    lock.unlock()
                }
                _ = ring.makeArray()
            }
        }
    }

    /// B5: one usage dictionary per sort, against a comparator that locks once per comparison.
    /// The manager already hoists the read. This is the measured gap, not a second sort implementation.
    /// Release 2026-10-14, min of 3: hoisted 0.18 ms vs per-compare 0.31 ms. Ceiling 50 ms.
    func testB5UsageSortHoistsTheStatsRead() throws {
        try BenchmarkGate.requireBenchMode()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditBenchmark-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SnippetStore(fileURL: directory.appendingPathComponent("library.json"))
        let snippets = library(2_000)[0].snippets
        let pair = BenchmarkGate.interleaved(rounds: 3, {
            let counts = store.usageCountsByID()
            _ = snippets.sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
        }, {
            _ = snippets.sorted { store.usageCount(for: $0) > store.usageCount(for: $1) }
        })
        print(String(format: "  B5 hoisted sort %8.2f ms vs per-compare %8.2f ms", pair.a, pair.b))
        XCTAssertLessThan(pair.a, pair.b)
        let result = BenchmarkGate.verdict(measuredMs: pair.a, ceilingMs: 50)
        if !result.passed {
            XCTFail(String(format: "B5 hoisted sort %.2f ms exceeds 50 ms", pair.a))
        }
    }
}
