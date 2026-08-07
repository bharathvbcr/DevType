import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// Adversarial suite for the AX selection read — the "Prompt Enhance says no text is selected"
/// path, hardened after a second field report.
///
/// `SelectionGateTests` covers the pure gate policy. This file covers the machinery *around* it:
/// the Chromium wake-up state machine, the attribute ladder's reach past the focused element,
/// the rate limiter that decides whether the monitor's cache is ever populated, and the budgets
/// that stop a hung app from turning an explicit gesture into a beachball.
///
/// The bug that prompted it, from a real report:
///
///     Last selection read: outcome=noFocus app=com.google.antigravity axCandidates=0 chars=0
///     Last selection AX probes: systemWide:noValue appScoped:noValue chain:noValue
///
/// Three probes, zero candidates, and — the tell — *no* mention of the manual-accessibility
/// rescue in the summary, even though the reader asks for it whenever the probes come back
/// empty. `SelectionMonitor` had already poked that pid on the app switch, the old `Bool` API
/// answered "no, I did not activate it *on this call*", and the rescue bailed out before its
/// settle poll. The wake-up worked; the code that waits for it never ran.
final class SelectionHardeningTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The regression: a memoized wake-up must not skip the wait

    /// The one-line root cause. `alreadyActive` is the state every Chromium app is in from the
    /// second hotkey press onward, and it *must* still earn the settle poll.
    func testAlreadyActiveStillWaitsForTheTree() {
        XCTAssertTrue(
            AXContextChecker.shouldSettlePollAfterManualAccessibility(.alreadyActive),
            "Skipping the wait here is the entire noFocus bug: the tree is up, or coming up, "
                + "and we gave the answer 'no focused element' without looking again."
        )
        XCTAssertTrue(AXContextChecker.shouldSettlePollAfterManualAccessibility(.activatedNow))
        XCTAssertTrue(
            AXContextChecker.shouldSettlePollAfterManualAccessibility(.unsupported),
            "An AppKit app that answered nothing to all three focus probes is abnormal — "
                + "mid-transition or still launching. The read is about to fail anyway."
        )
        XCTAssertTrue(
            AXContextChecker.shouldSettlePollAfterManualAccessibility(.failed),
            "A failed set is a busy app, not a permanently silent one."
        )
        XCTAssertFalse(
            AXContextChecker.shouldSettlePollAfterManualAccessibility(.invalidPID),
            "There is nothing to wait for without a target."
        )
    }

    /// A second `ensure` reports `alreadyActive` — not `activatedNow`, and not a bare `false`
    /// that a caller can mistake for "the tree is unavailable".
    func testEnsureReportsAlreadyActiveRatherThanFailure() {
        let checker = AXContextChecker()
        checker.resetManualAccessibilityMemoForTesting()
        checker.seedManualAccessibilityForTesting(pid: 4242, state: .activatedNow)

        XCTAssertEqual(checker.ensureManualAccessibility(pid: 4242), .alreadyActive)
        XCTAssertTrue(checker.ensureManualAccessibility(pid: 4242).isLive)
        XCTAssertFalse(
            checker.activateManualAccessibility(pid: 4242),
            "The legacy Bool shim still means 'did I flip it on this call' — which is why "
                + "nothing may branch on it anymore."
        )
    }

    /// A transient AX error must not be remembered. One `.cannotComplete` against an app that
    /// was still launching used to disable its wake-up for the rest of the session.
    func testTransientFailuresAreNotMemoized() {
        XCTAssertEqual(AXContextChecker.manualAccessibilityState(forSetStatus: .cannotComplete), .failed)
        XCTAssertEqual(AXContextChecker.manualAccessibilityState(forSetStatus: .apiDisabled), .failed)
        XCTAssertEqual(AXContextChecker.manualAccessibilityState(forSetStatus: .invalidUIElement), .failed)
        XCTAssertEqual(AXContextChecker.manualAccessibilityState(forSetStatus: .notImplemented), .failed)

        XCTAssertEqual(AXContextChecker.manualAccessibilityState(forSetStatus: .success), .activatedNow)
        XCTAssertEqual(
            AXContextChecker.manualAccessibilityState(forSetStatus: .attributeUnsupported),
            .unsupported,
            "'This app is not Chromium' is a settled answer and may be cached."
        )
        XCTAssertEqual(AXContextChecker.manualAccessibilityState(forSetStatus: .noValue), .unsupported)

        let checker = AXContextChecker()
        checker.resetManualAccessibilityMemoForTesting()
        checker.seedManualAccessibilityForTesting(pid: 5150, state: .failed)
        XCTAssertEqual(
            checker.ensureManualAccessibility(pid: 5150), .failed,
            "A seeded failure is reported as-is, never promoted to alreadyActive."
        )
    }

    /// macOS reuses pids. An Electron app that quits and hands its pid to an AppKit app —
    /// or, far worse, an AppKit app whose pid is recycled by an Electron one that then never
    /// gets its tree switched on — must not inherit the old verdict.
    func testMemoIsEvictedSoRecycledPIDsAreRePoked() {
        let checker = AXContextChecker()
        checker.resetManualAccessibilityMemoForTesting()
        checker.seedManualAccessibilityForTesting(pid: 7777, state: .unsupported)
        XCTAssertEqual(checker.ensureManualAccessibility(pid: 7777), .unsupported)

        checker.forgetManualAccessibility(pid: 7777)
        // With the memo cleared the next call has to make a real AX round-trip. Its outcome
        // depends on the (nonexistent) pid; what matters is that it is no longer the stale
        // `unsupported` verdict served from the dictionary.
        XCTAssertNotEqual(
            checker.ensureManualAccessibility(pid: 7777), .alreadyActive,
            "An evicted pid must be probed again, not answered from the memo."
        )

        // Evicting an unknown pid is a no-op, not a crash.
        checker.forgetManualAccessibility(pid: 31337)
    }

    func testInvalidPIDsAreRejectedWithoutARoundTrip() {
        let checker = AXContextChecker()
        checker.resetManualAccessibilityMemoForTesting()
        XCTAssertEqual(checker.ensureManualAccessibility(pid: 0), .invalidPID)
        XCTAssertEqual(checker.ensureManualAccessibility(pid: -1), .invalidPID)
        XCTAssertFalse(AXContextChecker.ManualAccessibilityState.invalidPID.isLive)
    }

    // MARK: - Settle poll is bounded by the caller's budget

    /// The poll may never outlive the overall read budget, or a Chromium app that never
    /// publishes a tree adds its full settle time on top of an already-spent budget.
    func testSettlePollNeverRunsPastTheReadBudget() {
        let natural = AXContextChecker.settlePollDeadline(now: now, budget: nil)
        XCTAssertEqual(
            natural.timeIntervalSince(now),
            AXContextChecker.manualAccessibilitySettleSeconds,
            accuracy: 0.001
        )

        let tight = AXContextChecker.settlePollDeadline(now: now, budget: now.addingTimeInterval(0.05))
        XCTAssertEqual(tight.timeIntervalSince(now), 0.05, accuracy: 0.001)

        let generous = AXContextChecker.settlePollDeadline(now: now, budget: now.addingTimeInterval(10))
        XCTAssertEqual(
            generous.timeIntervalSince(now),
            AXContextChecker.manualAccessibilitySettleSeconds,
            accuracy: 0.001
        )

        let expired = AXContextChecker.settlePollDeadline(now: now, budget: now.addingTimeInterval(-1))
        XCTAssertLessThan(expired, now, "An exhausted budget must not buy a fresh poll window.")
    }

    /// The whole explicit read has to stay inside a human-scale wait: the ladder runs on the
    /// main thread before any panel can appear.
    func testReadBudgetIsBoundedAndCoversTheSettlePoll() {
        XCTAssertGreaterThan(SelectionReader.readBudgetSeconds, 0)
        XCTAssertLessThanOrEqual(
            SelectionReader.readBudgetSeconds, 2.0,
            "Past a couple of seconds on the main thread this reads as a hang, not a read."
        )
        XCTAssertGreaterThan(
            SelectionReader.readBudgetSeconds,
            AXContextChecker.manualAccessibilitySettleSeconds,
            "The budget has to leave room for the wake-up wait plus at least one ladder pass."
        )
        XCTAssertGreaterThan(SelectionReader.maxAncestorHops, 0)
        XCTAssertLessThanOrEqual(
            SelectionReader.maxAncestorHops, 8,
            "The widening pass is a bounded look outward, not a tree crawl."
        )
    }

    // MARK: - Ancestor walk

    /// The widening pass exists because the focused node is often not the element that owns the
    /// selection. It must terminate on a real element, and it must never loop.
    func testAncestorWalkIsBoundedAndCycleSafe() {
        let systemWide = AXUIElementCreateSystemWide()

        XCTAssertTrue(
            SelectionReader.ancestors(of: systemWide, limit: 0).isEmpty,
            "A zero limit asks for nothing."
        )
        XCTAssertTrue(
            SelectionReader.ancestors(of: systemWide, limit: -3).isEmpty,
            "A negative limit must clamp, not trap."
        )
        XCTAssertLessThanOrEqual(
            SelectionReader.ancestors(of: systemWide, limit: 3).count, 3,
            "The walk must never return more hops than asked for."
        )
        // The system-wide element has no parent, so this is also the termination case: it has to
        // return promptly rather than spinning on a nil parent.
        XCTAssertTrue(SelectionReader.ancestors(of: systemWide).isEmpty)
    }

    // MARK: - UTF-16 range slicing

    /// AX ranges are UTF-16 offsets. Slicing with `String.Index` arithmetic would corrupt any
    /// selection containing an emoji, a flag, or a combining mark — and every one of those is
    /// ordinary content in the apps this path targets.
    func testValueSubstringUsesUTF16OffsetsNotCharacterOffsets() {
        let text = "a🙂b"   // UTF-16: a(1) 🙂(2) b(1)
        XCTAssertEqual(
            SelectionReader.substring(of: text, utf16Range: CFRange(location: 1, length: 2)),
            "🙂",
            "Character-index arithmetic would have sliced this into a lone surrogate."
        )
        XCTAssertEqual(
            SelectionReader.substring(of: text, utf16Range: CFRange(location: 0, length: 4)),
            text
        )

        let family = "👨‍👩‍👧"   // one grapheme, eight UTF-16 units
        XCTAssertEqual(
            SelectionReader.substring(of: family, utf16Range: CFRange(location: 0, length: 8)),
            family
        )
    }

    /// Apps hand back stale ranges — a range captured before the document shrank. `NSString`
    /// would trap outright on those, taking the app down on a hotkey press.
    func testOutOfBoundsAndMalformedRangesAreRefusedNotTrapped() {
        let text = "hello"
        let bad: [CFRange] = [
            CFRange(location: -1, length: 2),        // negative origin
            CFRange(location: 0, length: -5),        // negative length
            CFRange(location: 0, length: 0),         // caret, not a selection
            CFRange(location: 3, length: 99),        // runs off the end
            CFRange(location: 99, length: 1),        // starts off the end
            CFRange(location: 5, length: 1),         // starts at the end
            CFRange(location: Int.max, length: 1),   // overflow bait
        ]
        for range in bad {
            XCTAssertNil(
                SelectionReader.substring(of: text, utf16Range: range),
                "location=\(range.location) length=\(range.length) must be refused"
            )
        }
        XCTAssertNil(SelectionReader.substring(of: "", utf16Range: CFRange(location: 0, length: 1)))
    }

    // MARK: - Oversized selections

    /// A select-all in a large document is the pathological case: `AXStringForRange` drags the
    /// whole thing across AX IPC on the main thread, and the model then rejects it seconds later
    /// as `inputTooLarge`. Refuse it up front, and say so.
    func testOversizedSelectionIsRefusedWithItsOwnReason() {
        let huge = String(repeating: "x", count: SelectionReader.maxSelectionCharacters + 1)
        let outcome = SelectionReader.evaluate(
            axTrusted: true,
            secureInputActive: false,
            frontmostBundleID: "com.apple.TextEdit",
            frontmostIsOwnProcess: false,
            focusAvailable: true,
            candidates: [.init(text: huge, isOwnProcess: false, bundleID: "com.apple.TextEdit")],
            cached: nil,
            now: now,
            isMuted: { _ in false },
            isWeakAX: { _ in false }
        )
        XCTAssertEqual(outcome.failure, .selectionTooLarge(huge.count))
        XCTAssertEqual(SelectionReader.describe(outcome), "tooLarge")
        XCTAssertNil(outcome.result, "An oversized selection must not reach the model.")
    }

    /// Exactly at the limit is allowed — an off-by-one here refuses a legitimate selection.
    func testSelectionExactlyAtTheLimitIsAccepted() {
        let atLimit = String(repeating: "y", count: SelectionReader.maxSelectionCharacters)
        let outcome = SelectionReader.evaluate(
            axTrusted: true,
            secureInputActive: false,
            frontmostBundleID: "com.apple.TextEdit",
            frontmostIsOwnProcess: false,
            focusAvailable: true,
            candidates: [.init(text: atLimit, isOwnProcess: false, bundleID: "com.apple.TextEdit")],
            cached: nil,
            now: now,
            isMuted: { _ in false },
            isWeakAX: { _ in false }
        )
        XCTAssertEqual(outcome.result?.text.count, SelectionReader.maxSelectionCharacters)
    }

    /// The cache path goes through the same ceiling. It is fed by the monitor, which reads the
    /// same attributes, so it can hold an oversized entry just as easily.
    func testOversizedCachedSelectionIsAlsoRefused() {
        let huge = String(repeating: "z", count: SelectionReader.maxSelectionCharacters + 100)
        let outcome = SelectionReader.evaluate(
            axTrusted: true,
            secureInputActive: false,
            frontmostBundleID: "com.devtype.app",
            frontmostIsOwnProcess: true,
            focusAvailable: false,
            candidates: [],
            cached: SelectionMonitor.CachedSelection(
                text: huge,
                bundleID: "com.apple.Safari",
                changeToken: 1,
                timestamp: now
            ),
            now: now,
            isMuted: { _ in false },
            isWeakAX: { _ in false }
        )
        XCTAssertEqual(outcome.failure, .selectionTooLarge(huge.count))
    }

    /// A hard block still outranks the size check: telling the user their selection is too long
    /// when Accessibility is off sends them to fix the wrong thing.
    func testHardBlocksStillOutrankTheSizeCheck() {
        let huge = String(repeating: "x", count: SelectionReader.maxSelectionCharacters + 1)
        let outcome = SelectionReader.evaluate(
            axTrusted: false,
            secureInputActive: false,
            frontmostBundleID: "com.apple.TextEdit",
            frontmostIsOwnProcess: false,
            focusAvailable: true,
            candidates: [.init(text: huge, isOwnProcess: false)],
            cached: nil,
            now: now,
            isMuted: { _ in false },
            isWeakAX: { _ in false }
        )
        XCTAssertEqual(outcome.failure, .accessibilityUntrusted)
    }

    /// The value-slice rung has to pull the element's whole value across AX IPC to cut the
    /// selection out of it. The range guard bounds the selection; only this bounds the document.
    func testDocumentSliceCeilingIsAboveTheSelectionCeiling() {
        XCTAssertGreaterThan(
            SelectionReader.maxSliceableDocumentCharacters,
            SelectionReader.maxSelectionCharacters,
            "A document ceiling below the selection ceiling would refuse selections that are "
                + "themselves within limits."
        )
    }

    // MARK: - Attribute provenance

    /// `via` is the field that makes the next report diagnosable: it says whether an app answers
    /// the plain attribute, needs the range pair, or is marker-only.
    func testReadViaSurvivesIntoTheResult() {
        let outcome = SelectionReader.evaluate(
            axTrusted: true,
            secureInputActive: false,
            frontmostBundleID: "com.google.antigravity",
            frontmostIsOwnProcess: false,
            focusAvailable: true,
            candidates: [
                .init(text: nil, isOwnProcess: false, bundleID: "com.google.antigravity", via: .unknown),
                .init(
                    text: "improve this prompt",
                    isOwnProcess: false,
                    bundleID: "com.google.antigravity",
                    via: .textMarker
                ),
            ],
            cached: nil,
            now: now,
            isMuted: { _ in false },
            isWeakAX: { _ in true }
        )
        XCTAssertEqual(outcome.result?.text, "improve this prompt")
        XCTAssertEqual(outcome.result?.via, .textMarker)
        XCTAssertEqual(outcome.result?.via.rawValue, "textMarker")
    }

    /// A cache hit is labelled as such, never as whatever attribute originally produced it.
    func testCacheHitIsLabelledAsCache() {
        let outcome = SelectionReader.evaluate(
            axTrusted: true,
            secureInputActive: false,
            frontmostBundleID: "com.devtype.app",
            frontmostIsOwnProcess: true,
            focusAvailable: false,
            candidates: [],
            cached: SelectionMonitor.CachedSelection(
                text: "behind the panel",
                bundleID: "com.apple.Safari",
                changeToken: 1,
                timestamp: now
            ),
            now: now,
            isMuted: { _ in false },
            isWeakAX: { _ in false }
        )
        XCTAssertEqual(outcome.result?.via, .cache)
        XCTAssertEqual(outcome.result?.source, .cached)
    }

    /// Every rung needs a distinct, stable label — these strings end up in bug reports.
    func testEveryReadViaLabelIsDistinctAndStable() {
        let all: [SelectionReader.ReadVia] = [
            .selectedText, .selectedTextSlow, .stringForRange, .attributedStringForRange,
            .valueSubstring, .selectedTextRanges, .textMarker, .ancestor(1), .ancestor(2),
            .applicationElement, .cache, .clipboardCopy, .unknown,
        ]
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
        XCTAssertEqual(SelectionReader.ReadVia.ancestor(3).rawValue, "ancestor+3")
        XCTAssertEqual(SelectionReader.ReadVia.textMarker.rawValue, "textMarker")
    }

    // MARK: - Monitor cache: the rate-limited ladder

    /// The reason the cache fallback was empty in Electron apps: the monitor only ever read the
    /// primary attribute, which Chromium answers with nothing. Both AI paths were dead there at
    /// the same time — the live read via the skipped wake-up, the cache via this.
    func testFallbackLadderRunsWhenThePrimaryAttributeFindsNothing() {
        XCTAssertTrue(
            SelectionMonitor.shouldRunFallbackLadder(
                primaryFoundText: false, lastLadderAt: nil, now: now
            ),
            "First empty read on a new element must pay for the full ladder."
        )
        XCTAssertFalse(
            SelectionMonitor.shouldRunFallbackLadder(
                primaryFoundText: true, lastLadderAt: nil, now: now
            ),
            "The ladder cannot improve on a primary-attribute hit; paying for it is waste on "
                + "the keystroke path."
        )
    }

    /// The rate limit is what makes this affordable: the monitor runs from a notification many
    /// apps fire on every keystroke.
    func testFallbackLadderIsRateLimited() {
        let interval = SelectionMonitor.fallbackLadderMinInterval
        XCTAssertFalse(
            SelectionMonitor.shouldRunFallbackLadder(
                primaryFoundText: false,
                lastLadderAt: now.addingTimeInterval(-interval / 2),
                now: now
            ),
            "Two ladders inside one interval is the typing-path stall this guard exists for."
        )
        XCTAssertTrue(
            SelectionMonitor.shouldRunFallbackLadder(
                primaryFoundText: false,
                lastLadderAt: now.addingTimeInterval(-interval),
                now: now
            ),
            "Exactly one interval later must be allowed, or the limiter drifts."
        )
        XCTAssertGreaterThan(interval, 0)
        XCTAssertLessThanOrEqual(
            interval, 1.0,
            "Longer than this and a user who selects, pauses, and hits the hotkey finds an "
                + "empty cache."
        )
    }

    /// A backwards clock jump (NTP correction, sleep/wake) must not lock the ladder out until
    /// wall-clock catches up — that is minutes of a silently non-functioning cache.
    func testBackwardsClockJumpDoesNotWedgeTheRateLimiter() {
        XCTAssertTrue(
            SelectionMonitor.shouldRunFallbackLadder(
                primaryFoundText: false,
                lastLadderAt: now.addingTimeInterval(3600),
                now: now
            )
        )
    }

    // MARK: - Probe ordering rules the reader must not optimise away

    /// The reader must hand `evaluate` *every* candidate it read, not stop at the first one that
    /// answered. Mid app-switch the system-wide probe resolves into the app the user just left;
    /// stopping there makes a muted app's text the only option the gate ever sees — either
    /// walking around the mute or refusing while the real selection sits unread on the next
    /// probe. Both were live regressions during this change.
    func testGateStillSeesLaterCandidatesAfterAnEarlierOneAnswered() {
        let outcome = SelectionReader.evaluate(
            axTrusted: true,
            secureInputActive: false,
            frontmostBundleID: "com.apple.TextEdit",
            frontmostIsOwnProcess: false,
            focusAvailable: true,
            candidates: [
                .init(
                    text: "vault entry",
                    isOwnProcess: false,
                    bundleID: "com.1password.1password",
                    via: .selectedText
                ),
                .init(
                    text: "the real selection",
                    isOwnProcess: false,
                    bundleID: "com.apple.TextEdit",
                    via: .stringForRange
                ),
            ],
            cached: nil,
            now: now,
            isMuted: { $0 == "com.1password.1password" },
            isWeakAX: { _ in false }
        )
        XCTAssertEqual(outcome.result?.text, "the real selection")
        XCTAssertEqual(outcome.result?.via, .stringForRange)
    }

    /// Same rule for our own panel: an own-process candidate that answered must not be the last
    /// word while a foreign one is still unread behind it.
    func testOwnProcessCandidateDoesNotSuppressAForeignOne() {
        let outcome = SelectionReader.evaluate(
            axTrusted: true,
            secureInputActive: false,
            frontmostBundleID: "com.devtype.app",
            frontmostIsOwnProcess: true,
            focusAvailable: true,
            candidates: [
                .init(text: "palette query", isOwnProcess: true, bundleID: "com.devtype.app"),
                .init(text: "user paragraph", isOwnProcess: false, bundleID: "com.apple.Safari"),
            ],
            cached: nil,
            now: now,
            isMuted: { _ in false },
            isWeakAX: { _ in false }
        )
        XCTAssertEqual(
            outcome.result?.text, "user paragraph",
            "Transforming our own search field while the user's text sits behind the panel is "
                + "the exact failure the candidate ordering exists to prevent."
        )
    }

    /// The reader's widening pass is gated on the source shape, and those gates are load-bearing:
    /// widening past a stalled app spends latency on an answer that is not coming, and widening
    /// while DevType is frontmost would surface our own UI text as the user's selection.
    func testWideningGatesAreDocumentedInTheReader() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ExpanderEngine/AI/SelectionReader.swift")
        let source = SourceContractTests.strippingComments(
            try String(contentsOf: url, encoding: .utf8)
        )
        for gate in ["!stalling", "!frontmostIsOwnProcess", "budgetExhausted"] {
            XCTAssertTrue(
                source.contains(gate),
                "The widening pass must stay gated on \(gate)."
            )
        }
        XCTAssertFalse(
            source.contains("if !isBlankSelection(read.text) { break }"),
            "Breaking out of the candidate loop on the first answer hides later probes from "
                + "the gate, which is where the mute list and own-process ranking live."
        )
    }

    // MARK: - Diagnostics

    /// The report is the only artifact a user pastes. Everything needed to tell the failure
    /// modes apart has to survive into it.
    func testDiagnosticLineCarriesAttributeAndElapsedTime() {
        let store = AIDiagnosticsStore()
        store.recordSelectionRead(
            outcome: "live",
            bundleID: "com.google.antigravity",
            candidateCount: 2,
            characters: 42,
            probeSummary: "systemWide:noValue appScoped:available chain:available manualAX:alreadyActive polls:3",
            via: "textMarker",
            elapsedMilliseconds: 187
        )
        let lines = AIDiagnosticsStore.selectionReadLines(
            store.recentSelectionReads(), iso: ISO8601DateFormatter()
        )
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("via=textMarker"), joined)
        XCTAssertTrue(joined.contains("elapsedMs=187"), joined)
        XCTAssertTrue(joined.contains("manualAX:alreadyActive"), joined)
        XCTAssertTrue(joined.contains("polls:3"), joined)
    }

    /// The per-app histogram of *which attribute answered* is what turns a one-off report into
    /// "this app is marker-only" or "this app never answers anything".
    func testAttributeBreakdownAppearsWhenThereIsSomethingToBreakDown() {
        let store = AIDiagnosticsStore()
        store.recordSelectionRead(
            outcome: "live", bundleID: "a", candidateCount: 1, characters: 5, via: "textMarker"
        )
        store.recordSelectionRead(
            outcome: "live", bundleID: "a", candidateCount: 1, characters: 5, via: "textMarker"
        )
        store.recordSelectionRead(
            outcome: "live", bundleID: "b", candidateCount: 1, characters: 5, via: "selectedText"
        )
        let joined = AIDiagnosticsStore.selectionReadLines(
            store.recentSelectionReads(), iso: ISO8601DateFormatter()
        ).joined(separator: "\n")
        XCTAssertTrue(joined.contains("Selection read attributes: textMarker=2 selectedText=1"), joined)
    }

    /// A run of failures has no attribute to report; the line must be omitted rather than
    /// printed empty or full of `unknown`.
    func testAttributeBreakdownIsOmittedWhenNothingAnswered() {
        let store = AIDiagnosticsStore()
        store.recordSelectionRead(
            outcome: "noFocus", bundleID: "a", candidateCount: 0, characters: 0, via: "unknown"
        )
        let lines = AIDiagnosticsStore.selectionReadLines(
            store.recentSelectionReads(), iso: ISO8601DateFormatter()
        )
        XCTAssertFalse(lines.contains { $0.hasPrefix("Selection read attributes:") })
    }

    /// Privacy: the store records lengths and labels. A regression that started recording the
    /// selected text would leak it into every pasted report.
    func testSelectionReadNeverCarriesTheText() {
        let mirror = Mirror(reflecting: AIDiagnosticsStore.SelectionRead(
            at: now, outcome: "live", bundleID: "a", candidateCount: 1, characters: 9,
            probeSummary: "", via: "selectedText", elapsedMilliseconds: 3
        ))
        let fields = Set(mirror.children.compactMap(\.label))
        XCTAssertFalse(fields.contains("text"))
        XCTAssertTrue(fields.contains("characters"))
    }

    // MARK: - Messages

    /// The new failure needs a real, distinct message in every shipped language, with both
    /// numbers interpolated — a translation that drops one leaves the user with "past the
    /// -character limit".
    func testTooLargeMessageIsLocalizedEverywhereWithBothNumbers() {
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            guard let format = table["ai.selection.fail.tooLarge"] else {
                XCTFail("\(language.rawValue) is missing ai.selection.fail.tooLarge")
                continue
            }
            XCTAssertEqual(
                format.components(separatedBy: "%@").count, 3,
                "\(language.rawValue) must interpolate both the length and the limit"
            )
        }
        let rendered = SelectionReader.Failure.selectionTooLarge(250_000).message()
        XCTAssertTrue(rendered.contains("250000"), rendered)
        XCTAssertTrue(rendered.contains("\(SelectionReader.maxSelectionCharacters)"), rendered)
    }

    /// Every failure keeps its own diagnostic label — the report groups on these, so a collision
    /// would silently merge two different causes into one histogram bucket.
    func testAllFailureLabelsRemainDistinct() {
        let failures: [SelectionReader.Failure] = [
            .accessibilityUntrusted, .secureInputActive, .appMuted("x"),
            .noFocusedElement, .emptySelection, .selectionTooLarge(1),
        ]
        XCTAssertEqual(Set(failures.map(\.diagnosticLabel)).count, failures.count)
        XCTAssertEqual(Set(failures.map(\.messageKey)).count, failures.count)
    }
}
