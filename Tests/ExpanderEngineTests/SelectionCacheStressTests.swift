import ApplicationServices
import Cocoa
import XCTest
@testable import ExpanderEngine

/// Randomised, model-based stress for the selection cache and the gate that reads it.
///
/// The hand-written suites (`SelectionGateTests`, `SelectionHardeningTests`) pin the branches that
/// field reports named. This file exists for the ones nobody has hit yet: it drives the same code
/// through tens of thousands of randomly ordered states and asserts the *invariants* rather than
/// individual outcomes.
///
/// Everything here is deterministic. The generator is a seeded SplitMix64 and every clock is
/// passed in, so a failure reproduces exactly from the seed printed in the assertion message —
/// a random suite that cannot be replayed is a flake generator, not a test.
final class SelectionCacheStressTests: XCTestCase {

    // MARK: - Deterministic generator

    /// SplitMix64 — small, fast, and identical on every machine and OS version.
    private struct Rng {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func int(_ upperBound: Int) -> Int {
            precondition(upperBound > 0)
            return Int(next() % UInt64(upperBound))
        }

        mutating func bool() -> Bool { next() & 1 == 0 }

        mutating func pick<T>(_ values: [T]) -> T { values[int(values.count)] }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private static let apps = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.apple.TextEdit",
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
    ]

    // MARK: - Model-based stress: the cache mutation funnel

    /// Reference implementation of `applySelectionRefresh`'s documented contract, kept
    /// deliberately naive so it cannot share a bug with the code under test.
    private struct CacheModel {
        var text: String?
        var bundleID: String?
        var element: AXUIElement?

        mutating func apply(text: String?, bundleID: String, element: AXUIElement?, ownFocus: Bool) {
            // Rule 0 (§8.8): evidence from our own process may neither store nor invalidate.
            if ownFocus { return }
            if let previous = element, let current = self.element, !CFEqual(previous, current) {
                self = CacheModel()
            } else if self.element != nil, element == nil {
                self = CacheModel()
                return
            }
            guard let text, !text.isEmpty else { return }
            self.text = text
            self.bundleID = bundleID
            self.element = element
        }
    }

    /// Thousands of randomly ordered refreshes, clears and seeds, compared against the model after
    /// every single step. Any divergence prints the seed and the step index.
    func testCacheFunnelMatchesItsContractUnderRandomEventOrders() {
        var rng = Rng(seed: 0xDEFA_0117_5E1E_C701)
        let foreignElements = [1, 2, 3].map { AXUIElementCreateApplication(pid_t($0)) }
        let ownElement = AXUIElementCreateApplication(ownPID)

        for round in 0..<40 {
            let monitor = SelectionMonitor(environment: .fixed())
            var model = CacheModel()

            for step in 0..<200 {
                let context = "round \(round) step \(step)"
                switch rng.int(10) {
                case 0:
                    monitor.clearCache()
                    model = CacheModel()
                case 1:
                    // Our own panel takes the focused element. Must be inert, both directions.
                    monitor.testingApplySelectionRefresh(
                        text: rng.bool() ? "palette query" : nil,
                        bundleID: "com.devtype.app",
                        element: ownElement
                    )
                    model.apply(text: nil, bundleID: "com.devtype.app", element: ownElement, ownFocus: true)
                case 2:
                    // Focus resolved to nothing at all.
                    let bundleID = rng.pick(Self.apps)
                    monitor.testingApplySelectionRefresh(text: nil, bundleID: bundleID, element: nil)
                    model.apply(text: nil, bundleID: bundleID, element: nil, ownFocus: false)
                default:
                    let element = foreignElements[rng.int(foreignElements.count)]
                    let bundleID = rng.pick(Self.apps)
                    let text: String? = {
                        switch rng.int(4) {
                        case 0: return nil
                        case 1: return ""
                        default: return "selection-\(rng.int(1000))"
                        }
                    }()
                    monitor.testingApplySelectionRefresh(
                        text: text,
                        bundleID: bundleID,
                        element: element
                    )
                    model.apply(text: text, bundleID: bundleID, element: element, ownFocus: false)
                }

                let live = monitor.rawCachedSelection()
                XCTAssertEqual(live?.text, model.text, "cache text diverged at \(context)")
                XCTAssertEqual(live?.bundleID, model.bundleID, "cache label diverged at \(context)")

                // Standing invariants, independent of the model.
                if let live {
                    XCTAssertFalse(
                        live.text.isEmpty,
                        "An empty entry is indistinguishable from no entry and would be offered "
                            + "to the model as a selection (\(context))."
                    )
                    XCTAssertNotEqual(
                        live.bundleID, "com.devtype.app",
                        "Our own UI text must never be stored as the user's selection (\(context))."
                    )
                }
            }
        }
    }

    /// The token is what the typed path uses to tell one selection from the next. It must be
    /// strictly monotonic across every store — including after clears, which must not let a later
    /// entry reuse an earlier token.
    func testChangeTokenIsStrictlyMonotonicAcrossClears() {
        var rng = Rng(seed: 0x7112_3ADE_9001)
        let monitor = SelectionMonitor(environment: .fixed())
        let element = AXUIElementCreateApplication(1)
        var lastToken: UInt64 = 0

        for step in 0..<500 {
            if rng.int(5) == 0 { monitor.clearCache() }
            monitor.testingApplySelectionRefresh(
                text: "text-\(step)",
                bundleID: "com.apple.Safari",
                element: element
            )
            guard let token = monitor.rawCachedSelection()?.changeToken else {
                return XCTFail("A non-empty refresh on a stable element must produce an entry.")
            }
            XCTAssertGreaterThan(token, lastToken, "Token went backwards at step \(step).")
            lastToken = token
        }
    }

    // MARK: - Gate fuzz

    /// Twenty thousand random gate evaluations. Nothing here asserts *which* selection wins — that
    /// is the hand-written suite's job — only that the answers can never violate a safety rule.
    func testGateNeverViolatesItsSafetyInvariantsOnRandomInput() {
        var rng = Rng(seed: 0xBADC_0FFEE_0DDF00D & 0xFFFF_FFFF_FFFF)
        // A fuzz run that never reaches a state proves nothing about it. Counted and asserted at
        // the end so a future edit to the generator cannot quietly stop covering the cache path.
        var reached: [String: Int] = [:]

        for iteration in 0..<20_000 {
            let axTrusted = rng.int(8) != 0
            let secureInput = rng.int(8) == 0
            let frontmostIsOwn = rng.int(4) == 0
            let frontmostBundleID: String? = frontmostIsOwn
                ? "com.devtype.app"
                : (rng.int(10) == 0 ? nil : rng.pick(Self.apps))
            let muted = Set(Self.apps.filter { _ in rng.int(4) == 0 })

            // Candidate texts are unique per (iteration, index) so the winner can be identified
            // exactly. Reusing a small pool made two candidates share a string, and a *foreign*
            // win then read as an own-process one — the invariant below would have reported a
            // gate bug that did not exist.
            var candidates: [SelectionReader.Candidate] = []
            for index in 0..<rng.int(4) {
                let own = rng.int(3) == 0
                candidates.append(
                    SelectionReader.Candidate(
                        text: {
                            switch rng.int(5) {
                            case 0: return nil
                            case 1: return "   \u{200B}\n "
                            default: return "\(own ? "own" : "foreign")-\(iteration)-\(index)"
                            }
                        }(),
                        isOwnProcess: own,
                        bundleID: own ? "com.devtype.app" : (rng.int(8) == 0 ? nil : rng.pick(Self.apps))
                    )
                )
            }
            let weakAX = Set(Self.apps.filter { _ in rng.int(3) == 0 })

            let cachedAge = TimeInterval(rng.int(400))
            let cached: SelectionMonitor.CachedSelection? = rng.int(3) == 0
                ? nil
                : SelectionMonitor.CachedSelection(
                    text: rng.int(6) == 0 ? "  " : "cached-\(rng.int(100))",
                    bundleID: rng.pick(Self.apps),
                    changeToken: 1,
                    timestamp: now.addingTimeInterval(-cachedAge)
                )

            let outcome = SelectionReader.evaluate(
                axTrusted: axTrusted,
                secureInputActive: secureInput,
                frontmostBundleID: frontmostBundleID,
                frontmostIsOwnProcess: frontmostIsOwn,
                focusAvailable: rng.bool(),
                candidates: candidates,
                cached: cached,
                now: now,
                isMuted: { muted.contains($0) },
                // Deterministic: a closure that pulled from `rng` would let the code under test
                // reorder the generator, so a seed would no longer replay the same case.
                isWeakAX: { weakAX.contains($0) }
            )

            let context = "iteration \(iteration)"

            // 1. Exactly one of result / failure, always.
            XCTAssertEqual(
                outcome.result == nil, outcome.failure != nil,
                "Outcome must be a selection or a reason, never both or neither (\(context))."
            )

            guard let result = outcome.result else {
                let failure = outcome.failure!
                XCTAssertFalse(
                    failure.diagnosticLabel.isEmpty,
                    "Every failure needs a stable report label (\(context))."
                )
                reached[failure.diagnosticLabel, default: 0] += 1
                continue
            }
            reached[
                result.source == .live
                    ? (result.text.hasPrefix("own") ? "live.own" : "live.foreign")
                    : result.source.rawValue,
                default: 0
            ] += 1

            // 2. Hard blocks are hard. No selection may survive them, ever.
            XCTAssertTrue(axTrusted, "Selection returned without an AX grant (\(context)).")
            XCTAssertFalse(secureInput, "Selection returned under Secure Input (\(context)).")

            // 3. Never blank, never oversized.
            XCTAssertFalse(
                SelectionReader.isBlankSelection(result.text),
                "A blank selection reaches the model as an empty prompt (\(context))."
            )
            XCTAssertLessThanOrEqual(result.text.count, SelectionReader.maxSelectionCharacters)

            // 4. Never a muted app's text, by any route.
            if let bundleID = result.bundleID {
                XCTAssertFalse(
                    muted.contains(bundleID),
                    "Muted app \(bundleID) leaked through source=\(result.source.rawValue) (\(context))."
                )
            }

            // 5. Cached text is only ever offered to the app it came from — or to our own panel,
            //    which is the case the cache exists for.
            if result.source == .cached {
                let cached = try? XCTUnwrap(cached)
                XCTAssertEqual(result.text, cached?.text, context)
                if !frontmostIsOwn, let frontmostBundleID, !frontmostBundleID.isEmpty {
                    XCTAssertEqual(
                        result.bundleID, frontmostBundleID,
                        "Cross-app cache leak: \(result.bundleID ?? "nil") text offered in "
                            + "\(frontmostBundleID) (\(context))."
                    )
                }
                XCTAssertLessThanOrEqual(
                    cachedAge,
                    SelectionReader.cacheMaxAge(frontmostIsOwnProcess: frontmostIsOwn),
                    "Expired cache entry was used (\(context))."
                )
            }

            // 6. Our own UI text is the last resort, never a preemption of the user's.
            if result.source == .live,
               candidates.contains(where: { $0.isOwnProcess && $0.text == result.text }) {
                XCTAssertFalse(
                    candidates.contains {
                        !$0.isOwnProcess
                            && !SelectionReader.isBlankSelection($0.text)
                            && !($0.bundleID.map { muted.contains($0) } ?? false)
                    },
                    "Own-process text won while a usable foreign candidate was available "
                        + "(\(context))."
                )
            }
        }

        for state in [
            "live.foreign",     // the normal path
            "live.own",         // rule 4: our own editor, last resort
            "cached",           // rule 3: the palette / hotkey rescue
            "noFocus", "noSource", "emptySelection", "appMuted", "axUntrusted", "secureInput",
        ] {
            XCTAssertGreaterThan(
                reached[state, default: 0], 20,
                "The generator stopped reaching \(state) — the invariants above are no longer "
                    + "being tested against it. Coverage: \(reached.sorted { $0.key < $1.key })"
            )
        }
    }

    // MARK: - Concurrency

    /// The cache is written from the AX run-loop callback and read from whatever thread an
    /// explicit command lands on. Hammer both at once: this fails as a crash or a hang long before
    /// it fails as an assertion, which is the point.
    func testCacheSurvivesConcurrentReadersAndWriters() {
        let monitor = SelectionMonitor(environment: .fixed())
        let elements = (1...4).map { AXUIElementCreateApplication(pid_t($0)) }
        let known = Set((0..<32).map { "text-\($0)" })

        DispatchQueue.concurrentPerform(iterations: 12) { worker in
            var rng = Rng(seed: UInt64(worker) &* 0x9E37_79B9 &+ 1)
            for step in 0..<400 {
                switch rng.int(6) {
                case 0:
                    monitor.clearCache()
                case 1:
                    _ = monitor.hasWeakAXBlockedSelection(asOf: Date())
                case 2:
                    _ = monitor.cachedSelection(rejectWeakAX: false)
                case 3:
                    monitor.seedCacheForTesting(
                        SelectionMonitor.CachedSelection(
                            text: "text-\(rng.int(32))",
                            bundleID: "com.apple.Safari",
                            changeToken: UInt64(step),
                            timestamp: Date()
                        ),
                        element: elements[rng.int(elements.count)]
                    )
                default:
                    monitor.testingApplySelectionRefresh(
                        text: "text-\(rng.int(32))",
                        bundleID: "com.apple.Safari",
                        element: elements[rng.int(elements.count)]
                    )
                }

                // Any snapshot handed out must be internally whole — never a half-updated entry.
                if let snapshot = monitor.rawCachedSelection() {
                    XCTAssertTrue(
                        known.contains(snapshot.text),
                        "Torn read: \(snapshot.text) was never stored by any worker."
                    )
                    XCTAssertEqual(snapshot.bundleID, "com.apple.Safari")
                }
            }
        }
    }

    /// The manual-accessibility memo is read on the hotkey path and written from app-switch
    /// notifications. Same treatment; `forgetManualAccessibility` runs concurrently with both so
    /// the eviction path is covered too.
    func testManualAccessibilityMemoIsThreadSafe() {
        let checker = AXContextChecker()
        checker.resetManualAccessibilityMemoForTesting()

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            var rng = Rng(seed: UInt64(worker) &+ 0xA11C_E)
            for _ in 0..<300 {
                let pid = pid_t(rng.int(16) + 1000)
                switch rng.int(3) {
                case 0:
                    checker.seedManualAccessibilityForTesting(
                        pid: pid,
                        state: rng.bool() ? .activatedNow : .unsupported
                    )
                case 1:
                    checker.forgetManualAccessibility(pid: pid)
                default:
                    // Seeded pids answer from the memo; unseeded ones make a real (failing)
                    // round-trip against a pid that does not exist. Neither may crash.
                    _ = checker.ensureManualAccessibility(pid: pid)
                }
            }
        }
    }

    // MARK: - Crash-safety of the read primitives

    /// `substring(of:utf16Range:)` slices a document with a range the *app* supplied, which may be
    /// stale, negative, past the end, or land inside a surrogate pair. `NSString.substring` traps
    /// on all of those. Fuzz it against strings built from emoji, combining marks and CJK.
    func testSelectionSubstringNeverTrapsOnHostileRanges() {
        var rng = Rng(seed: 0x5B5_71_6C_ED)
        let alphabets = ["a", "é", "👩‍👩‍👧‍👦", "が", "\u{0301}", "🇯🇵", "\r\n", "𝄞"]

        for _ in 0..<5_000 {
            var string = ""
            for _ in 0..<rng.int(12) { string += rng.pick(alphabets) }
            let span = string.utf16.count

            let location = rng.int(3) == 0 ? -rng.int(8) : rng.int(max(1, span + 8))
            let length = rng.int(4) == 0 ? -rng.int(8) : rng.int(max(1, span + 8))
            let range = CFRange(location: location, length: length)

            let slice = SelectionReader.substring(of: string, utf16Range: range)
            if let slice {
                XCTAssertGreaterThanOrEqual(location, 0)
                XCTAssertGreaterThan(length, 0)
                XCTAssertLessThanOrEqual(location + length, span)
                XCTAssertEqual((slice as NSString).length, length)
            }
        }
    }

    /// Blankness decides whether a "selection" reaches the model at all. Any composition of
    /// whitespace, control characters and the placeholder scalars must read as blank; adding one
    /// real character must flip it.
    func testBlankDetectionIsStableUnderRandomCompositions() {
        var rng = Rng(seed: 0x8_1A_11_C0DE)
        let blanks = [" ", "\t", "\n", "\r\n", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}",
                      "\u{FEFF}", "\u{FFFC}", "\u{FFFD}", "\u{0000}", "\u{001B}"]

        for _ in 0..<5_000 {
            var blank = ""
            for _ in 0..<rng.int(10) { blank += rng.pick(blanks) }
            XCTAssertTrue(
                SelectionReader.isBlankSelection(blank),
                "\(blank.unicodeScalars.map { String($0.value, radix: 16) }) must read as blank."
            )

            let real = blank + "x" + blank
            XCTAssertFalse(SelectionReader.isBlankSelection(real))
        }
        XCTAssertTrue(SelectionReader.isBlankSelection(nil))
        XCTAssertTrue(SelectionReader.isBlankSelection(""))
    }

    // MARK: - Budgets

    /// The settle poll may never outlive the caller's read budget, whatever the clock does.
    func testSettlePollNeverOutlivesTheReadBudget() {
        var rng = Rng(seed: 0xB0_1E_7)
        for _ in 0..<2_000 {
            let start = now.addingTimeInterval(TimeInterval(rng.int(1000)) - 500)
            let budget = start.addingTimeInterval(TimeInterval(rng.int(4000) - 2000) / 1000)
            let deadline = AXContextChecker.settlePollDeadline(now: start, budget: budget)
            XCTAssertLessThanOrEqual(deadline, budget, "The poll ran past the caller's budget.")
            XCTAssertLessThanOrEqual(
                deadline,
                start.addingTimeInterval(AXContextChecker.manualAccessibilitySettleSeconds)
            )
        }
        // No budget at all still bounds the poll by the settle window.
        let unbounded = AXContextChecker.settlePollDeadline(now: now, budget: nil)
        XCTAssertEqual(
            unbounded.timeIntervalSince(now),
            AXContextChecker.manualAccessibilitySettleSeconds,
            accuracy: 0.001
        )
    }

    /// The diagnostic ring is the only thing the user pastes back. It must stay bounded no matter
    /// how many reads a long-running session records, and it must survive concurrent recording.
    func testDiagnosticRingStaysBoundedUnderFlood() {
        let store = AIDiagnosticsStore()
        DispatchQueue.concurrentPerform(iterations: 6) { worker in
            for step in 0..<500 {
                store.recordSelectionRead(
                    outcome: "noFocus",
                    bundleID: "com.google.Chrome",
                    candidateCount: 0,
                    characters: 0,
                    probeSummary: "systemWide:noValue manualAX:ownProcess",
                    via: "unknown",
                    elapsedMilliseconds: worker * step
                )
            }
        }
        XCTAssertLessThanOrEqual(store.recentSelectionReads().count, AIDiagnosticsStore.capacity)
        XCTAssertFalse(store.recentSelectionReads().isEmpty)
    }
}

/// The editor stage's preview clamp. Pure, so the rule that keeps a fixed-size panel fixed is
/// testable without a window server.
final class MacroPreviewClampTests: XCTestCase {

    func testShortPreviewsAreReturnedUntouched() {
        XCTAssertEqual(MacroPreview.clampedForStage("hello"), "hello")
        XCTAssertEqual(MacroPreview.clampedForStage(""), "")
        let exact = String(repeating: "a", count: MacroPreview.stagePreviewLimit)
        XCTAssertEqual(
            MacroPreview.clampedForStage(exact), exact,
            "Exactly at the limit is not over it — an off-by-one here adds an ellipsis to text "
                + "that fits."
        )
    }

    func testLongPreviewsAreClampedWithAnEllipsis() {
        let long = String(repeating: "b", count: MacroPreview.stagePreviewLimit + 40)
        let clamped = MacroPreview.clampedForStage(long)
        XCTAssertEqual(clamped.count, MacroPreview.stagePreviewLimit + 1)
        XCTAssertTrue(clamped.hasSuffix("…"))
    }

    /// Counted in characters, not UTF-16 units: slicing a family emoji or a flag through the
    /// middle produces replacement glyphs in the one place the user is watching their text.
    ///
    /// Asserted against `text.count` rather than the repeat count on purpose — a run of bare
    /// combining marks coalesces into a *single* grapheme, so "170 copies" is not 170 characters
    /// and such a string needs no clamping at all. Assuming otherwise was this test's own bug.
    func testClampNeverSplitsAGrapheme() {
        for unit in ["👩‍👩‍👧‍👦", "🇯🇵", "é", "が", "\u{0301}", "a\u{0301}"] {
            let text = String(repeating: unit, count: MacroPreview.stagePreviewLimit + 10)
            let clamped = MacroPreview.clampedForStage(text)

            XCTAssertFalse(
                clamped.unicodeScalars.contains("\u{FFFD}"),
                "\(unit.debugDescription) was sliced through a cluster."
            )
            if text.count > MacroPreview.stagePreviewLimit {
                XCTAssertEqual(clamped.count, MacroPreview.stagePreviewLimit + 1)
                XCTAssertTrue(clamped.hasSuffix("…"))
                XCTAssertEqual(
                    String(clamped.dropLast()),
                    String(text.prefix(MacroPreview.stagePreviewLimit)),
                    "The kept portion must be a grapheme-wise prefix of the input."
                )
            } else {
                XCTAssertEqual(clamped, text, "Nothing over the limit, nothing to clamp.")
            }
        }
    }

    func testZeroLimitIsHandledRatherThanTrapping() {
        XCTAssertEqual(MacroPreview.clampedForStage("anything", limit: 0), "")
        XCTAssertEqual(MacroPreview.clampedForStage("anything", limit: -5), "")
    }
}
