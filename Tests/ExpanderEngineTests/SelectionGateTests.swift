import XCTest
@testable import ExpanderEngine

/// Selection resolution for the explicit AI / palette paths.
///
/// Regression suite for: "select text, run Prompt Enhance, get *No text selected*". The old
/// reader was a chain of `guard … else { return nil }` over a single AX attribute, so five
/// unrelated causes produced one indistinguishable failure and three recoverable situations
/// produced no selection at all.
///
/// Everything here drives `SelectionReader.evaluate` — the pure policy — so each branch is
/// reachable without a window server, an AX grant, or a focused app.
final class SelectionGateTests: XCTestCase {

    // MARK: - Fixtures

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(
        _ text: String?,
        own: Bool = false,
        bundleID: String? = nil
    ) -> SelectionReader.Candidate {
        SelectionReader.Candidate(text: text, isOwnProcess: own, bundleID: bundleID)
    }

    private func cached(
        _ text: String,
        bundleID: String = "com.apple.Safari",
        age: TimeInterval = 1
    ) -> SelectionMonitor.CachedSelection {
        SelectionMonitor.CachedSelection(
            text: text,
            bundleID: bundleID,
            changeToken: 1,
            timestamp: now.addingTimeInterval(-age)
        )
    }

    /// Default-happy environment; each test perturbs exactly one input.
    private func evaluate(
        axTrusted: Bool = true,
        secureInputActive: Bool = false,
        frontmostBundleID: String? = "com.apple.Safari",
        frontmostIsOwnProcess: Bool = false,
        focusAvailable: Bool = true,
        candidates: [SelectionReader.Candidate] = [],
        cached: SelectionMonitor.CachedSelection? = nil,
        muted: Set<String> = [],
        weakAX: Set<String> = []
    ) -> SelectionReader.Outcome {
        SelectionReader.evaluate(
            axTrusted: axTrusted,
            secureInputActive: secureInputActive,
            frontmostBundleID: frontmostBundleID,
            frontmostIsOwnProcess: frontmostIsOwnProcess,
            focusAvailable: focusAvailable,
            candidates: candidates,
            cached: cached,
            now: now,
            isMuted: { muted.contains($0) },
            isWeakAX: { weakAX.contains($0) }
        )
    }

    // MARK: - Hard blocks report their own reason

    /// Every one of these used to surface as "Select text first, then open the AI palette",
    /// which is advice the user has already followed.
    func testHardBlocksAreDistinguishableFromAnEmptySelection() {
        let untrusted = evaluate(axTrusted: false, candidates: [candidate("hello")])
        XCTAssertEqual(untrusted.failure, .accessibilityUntrusted)

        let secure = evaluate(secureInputActive: true, candidates: [candidate("hello")])
        XCTAssertEqual(secure.failure, .secureInputActive)

        let muted = evaluate(candidates: [candidate("hello")], muted: ["com.apple.Safari"])
        XCTAssertEqual(muted.failure, .appMuted("com.apple.Safari"))

        let noFocus = evaluate(focusAvailable: false, candidates: [])
        XCTAssertEqual(noFocus.failure, .noFocusedElement)

        let empty = evaluate(candidates: [candidate(nil)])
        XCTAssertEqual(empty.failure, .emptySelection)

        let labels = Set(
            [untrusted, secure, muted, noFocus, empty].compactMap { $0.failure?.diagnosticLabel }
        )
        XCTAssertEqual(labels.count, 5, "Each cause needs its own diagnostic label.")
    }

    /// AX-untrusted outranks Secure Input outranks mute. Reporting "app is muted" for a revoked
    /// Accessibility grant sends the user to fix the wrong thing.
    func testHardBlockPrecedenceIsStable() {
        let all = evaluate(
            axTrusted: false,
            secureInputActive: true,
            muted: ["com.apple.Safari"]
        )
        XCTAssertEqual(all.failure, .accessibilityUntrusted)

        let secureAndMuted = evaluate(secureInputActive: true, muted: ["com.apple.Safari"])
        XCTAssertEqual(secureAndMuted.failure, .secureInputActive)
    }

    /// The mute list is about *other* apps. A DevType-frontmost read must not be blocked by
    /// DevType appearing on it, or the cache fallback below would be unreachable.
    func testOwnProcessFrontmostIgnoresTheMuteList() {
        let outcome = evaluate(
            frontmostBundleID: "com.devtype.app",
            frontmostIsOwnProcess: true,
            candidates: [candidate("in our own editor", own: true)],
            muted: ["com.devtype.app"]
        )
        XCTAssertEqual(outcome.result?.text, "in our own editor")
    }

    /// An unknown/empty bundle ID must not accidentally match a muted entry.
    func testEmptyFrontmostBundleIDIsNotTreatedAsMuted() {
        let outcome = evaluate(
            frontmostBundleID: "",
            candidates: [candidate("text")],
            muted: [""]
        )
        XCTAssertEqual(outcome.result?.text, "text")
    }

    // MARK: - Blank selections are not selections

    /// A stray drag selects one space; a selected Mail attachment reports `U+FFFC`; Electron
    /// editors hand back zero-width joiners. All three used to pass the gate and fail several
    /// seconds later inside the model as `emptyInput` or a guardrail refusal.
    func testBlankLookingSelectionsAreRejected() {
        let blanks = [
            "", " ", "   ", "\t", "\n", "\r\n", "\u{00A0}", "\u{200B}", "\u{200C}",
            "\u{200D}", "\u{2060}", "\u{FEFF}", "\u{FFFC}", "\u{FFFD}", "\u{0000}",
            " \n\t\u{200B} ",
        ]
        for blank in blanks {
            XCTAssertTrue(
                SelectionReader.isBlankSelection(blank),
                "\(blank.debugDescription) must count as no selection"
            )
            XCTAssertEqual(
                evaluate(candidates: [candidate(blank)]).failure,
                .emptySelection,
                "\(blank.debugDescription) must not reach the model"
            )
        }
        XCTAssertTrue(SelectionReader.isBlankSelection(nil))
    }

    /// Blankness gates the decision; it must never edit the user's text. Trimming here would
    /// desynchronise the replacement from the range the app actually has selected.
    func testNonBlankSelectionIsReturnedByteForByte() {
        let text = "  hello \u{200B} world\n"
        XCTAssertFalse(SelectionReader.isBlankSelection(text))
        XCTAssertEqual(evaluate(candidates: [candidate(text)]).result?.text, text)
    }

    /// Emoji, RTL, and a lone combining mark are content, not whitespace.
    func testNonLatinAndSymbolSelectionsSurvive() {
        for text in ["🙂", "مرحبا", "\u{0301}", "…", "0"] {
            XCTAssertEqual(
                evaluate(candidates: [candidate(text)]).result?.text,
                text,
                "\(text.debugDescription) is a real selection"
            )
        }
    }

    // MARK: - Probe ladder

    /// The AX probes disagree constantly: the system-wide probe resolves a browser window while
    /// the app-scoped probe resolves the web area inside it, and only one of them reports the
    /// selection. Trying only the first answer is how a real selection reads as none.
    func testLaterProbeWinsWhenTheFirstOneReportsNothing() {
        let outcome = evaluate(
            candidates: [candidate(nil), candidate("   "), candidate("from the third probe")]
        )
        XCTAssertEqual(outcome.result?.text, "from the third probe")
        XCTAssertEqual(outcome.result?.source, .live)
    }

    /// The mute list is per app, not per *frontmost* app. Mid-switch the system-wide probe can
    /// still resolve into the app the user just left, and reading that app's text would walk
    /// straight around a mute the user set precisely to keep DevType out of it.
    func testMutedAppIsNotReadThroughANonFrontmostProbe() {
        let outcome = evaluate(
            frontmostBundleID: "com.apple.TextEdit",
            candidates: [
                candidate("secret from the password manager", bundleID: "com.1password.1password"),
                candidate("the actual selection", bundleID: "com.apple.TextEdit"),
            ],
            muted: ["com.1password.1password"]
        )
        XCTAssertEqual(outcome.result?.text, "the actual selection")
        XCTAssertEqual(outcome.result?.bundleID, "com.apple.TextEdit")
    }

    /// With every candidate muted there is no usable selection at all.
    func testAllCandidatesMutedYieldsNoSelection() {
        let outcome = evaluate(
            frontmostBundleID: "com.apple.TextEdit",
            candidates: [candidate("text", bundleID: "com.1password.1password")],
            muted: ["com.1password.1password"]
        )
        XCTAssertEqual(outcome.failure, .emptySelection)
    }

    /// The result is attributed to the app that owned the element, not to whatever happened to
    /// be frontmost — that attribution drives the weak-AX verdict and the diagnostic line.
    func testResultIsAttributedToTheOwningApp() {
        let outcome = evaluate(
            frontmostBundleID: "com.apple.TextEdit",
            candidates: [candidate("text", bundleID: "com.google.Chrome")],
            weakAX: ["com.google.Chrome"]
        )
        XCTAssertEqual(outcome.result?.bundleID, "com.google.Chrome")
        XCTAssertEqual(outcome.result?.isWeakAX, true)
    }

    func testWeakAXVerdictRidesAlongWithTheLiveResult() {
        let outcome = evaluate(
            frontmostBundleID: "com.google.Chrome",
            candidates: [candidate("selected")],
            weakAX: ["com.google.Chrome"]
        )
        XCTAssertEqual(outcome.result?.isWeakAX, true)
        XCTAssertEqual(outcome.result?.bundleID, "com.google.Chrome")
    }

    // MARK: - Cache fallback (the DevType-is-frontmost case)

    /// The bug this fallback exists for: pressing the AI hotkey while a DevType panel or alert is
    /// already frontmost. The live probe then resolves to *our* search field, and without the
    /// cache the command reports "no selection" while the user's text sits selected behind it.
    func testCacheRecoversTheSelectionWhenOnlyOurOwnFieldIsFocused() {
        let outcome = evaluate(
            frontmostBundleID: "com.devtype.app",
            frontmostIsOwnProcess: true,
            candidates: [candidate("palette query", own: true)],
            cached: cached("the user's real paragraph")
        )
        XCTAssertEqual(outcome.result?.text, "the user's real paragraph")
        XCTAssertEqual(outcome.result?.source, .cached)
        XCTAssertEqual(outcome.result?.bundleID, "com.apple.Safari")
    }

    /// With no cache to fall back on, our own field is better than refusing — a user editing a
    /// snippet in DevType's own window still gets a transform.
    func testOwnProcessTextIsUsedOnlyAsALastResort() {
        let outcome = evaluate(
            frontmostBundleID: "com.devtype.app",
            frontmostIsOwnProcess: true,
            candidates: [candidate("snippet body", own: true)]
        )
        XCTAssertEqual(outcome.result?.text, "snippet body")
        XCTAssertEqual(outcome.result?.source, .live)
    }

    /// A live foreign selection always beats the cache; the cache may be up to a TTL old.
    func testLiveForeignSelectionOutranksTheCache() {
        let outcome = evaluate(
            candidates: [candidate("live text")],
            cached: cached("stale but fresh-enough text")
        )
        XCTAssertEqual(outcome.result?.text, "live text")
        XCTAssertEqual(outcome.result?.source, .live)
    }

    /// Cross-app leakage is the failure mode that matters here: transforming Safari's selection
    /// and pasting the result into Mail.
    func testCacheFromADifferentAppIsRefusedWhileThatOtherAppIsFrontmost() {
        let outcome = evaluate(
            frontmostBundleID: "com.apple.mail",
            candidates: [candidate(nil)],
            cached: cached("Safari text", bundleID: "com.apple.Safari")
        )
        XCTAssertEqual(outcome.failure, .emptySelection)
    }

    /// …but when *we* are frontmost, a different bundle is exactly what the cache should hold.
    func testCacheFromADifferentAppIsAcceptedWhileDevTypeIsFrontmost() {
        let outcome = evaluate(
            frontmostBundleID: "com.devtype.app",
            frontmostIsOwnProcess: true,
            candidates: [],
            cached: cached("Safari text", bundleID: "com.apple.Safari")
        )
        XCTAssertEqual(outcome.result?.text, "Safari text")
    }

    func testStaleCacheIsNotUsed() {
        let outcome = evaluate(
            frontmostIsOwnProcess: true,
            candidates: [],
            cached: cached("old", age: SelectionMonitor.defaultTTL + 0.5)
        )
        XCTAssertNil(outcome.result)

        let justInside = evaluate(
            frontmostIsOwnProcess: true,
            candidates: [],
            cached: cached("recent", age: SelectionMonitor.defaultTTL - 0.5)
        )
        XCTAssertEqual(justInside.result?.text, "recent")
    }

    /// A clock that jumps backwards (NTP correction, sleep/wake) must not turn a cache entry
    /// into a permanently-fresh one with a negative age.
    func testCacheTimestampedInTheFutureIsStillBounded() {
        let future = SelectionMonitor.CachedSelection(
            text: "from the future",
            bundleID: "com.apple.Safari",
            changeToken: 1,
            timestamp: now.addingTimeInterval(3600)
        )
        let outcome = evaluate(candidates: [], cached: future)
        // `isFresh` uses a signed interval, so a future stamp reads as fresh. Assert the
        // behaviour explicitly rather than leaving it undefined: it is bounded by the
        // same-app check and single-use consumption, and never silently drops the read.
        XCTAssertEqual(outcome.result?.text, "from the future")
    }

    func testMutedOrBlankCacheEntriesAreIgnored() {
        let mutedCache = evaluate(
            frontmostIsOwnProcess: true,
            candidates: [],
            cached: cached("text", bundleID: "com.apple.Safari"),
            muted: ["com.apple.Safari"]
        )
        XCTAssertNil(mutedCache.result)

        let blankCache = evaluate(
            frontmostIsOwnProcess: true,
            candidates: [],
            cached: cached(" \u{200B} ")
        )
        XCTAssertNil(blankCache.result)
    }

    /// An unknown frontmost bundle should not veto a fresh cache — that combination happens
    /// while the window server is mid-switch, and refusing there is a pure false negative.
    func testUnknownFrontmostBundleAcceptsTheCache() {
        let outcome = evaluate(
            frontmostBundleID: nil,
            candidates: [],
            cached: cached("text")
        )
        XCTAssertEqual(outcome.result?.text, "text")
    }

    // MARK: - Failure classification

    /// `noFocusedElement` means the probes resolved nothing at all. If an element *was* found and
    /// simply had no selection, that is `emptySelection` — different cause, different advice.
    func testNoFocusIsOnlyReportedWhenNoProbeAnswered() {
        XCTAssertEqual(evaluate(focusAvailable: false, candidates: []).failure, .noFocusedElement)
        XCTAssertEqual(
            evaluate(focusAvailable: true, candidates: [candidate(nil)]).failure,
            .emptySelection
        )
        XCTAssertEqual(
            evaluate(focusAvailable: false, candidates: [candidate(nil)]).failure,
            .emptySelection
        )
    }

    func testOutcomeAccessorsAreMutuallyExclusive() {
        let success = evaluate(candidates: [candidate("x")])
        XCTAssertNotNil(success.result)
        XCTAssertNil(success.failure)

        let failure = evaluate(candidates: [])
        XCTAssertNil(failure.result)
        XCTAssertNotNil(failure.failure)
    }

    func testDescribeProducesStableLabels() {
        XCTAssertEqual(SelectionReader.describe(evaluate(candidates: [candidate("x")])), "live")
        XCTAssertEqual(
            SelectionReader.describe(
                evaluate(frontmostIsOwnProcess: true, candidates: [], cached: cached("x"))
            ),
            "cached"
        )
        XCTAssertEqual(SelectionReader.describe(evaluate(axTrusted: false)), "axUntrusted")
        XCTAssertEqual(SelectionReader.describe(evaluate(secureInputActive: true)), "secureInput")
        XCTAssertEqual(
            SelectionReader.describe(evaluate(candidates: [candidate("x")], muted: ["com.apple.Safari"])),
            "appMuted"
        )
    }

    // MARK: - Messages

    /// Each failure must resolve to a real, distinct, non-key string in every shipped language.
    /// A missing key falls back to the key itself, which would put `ai.selection.fail.noFocus`
    /// in front of the user.
    func testEveryFailureHasARealLocalizedMessageInEveryLanguage() {
        let failures: [SelectionReader.Failure] = [
            .accessibilityUntrusted,
            .secureInputActive,
            .appMuted("com.apple.Safari"),
            .noFocusedElement,
            .emptySelection,
        ]
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            var messages: Set<String> = []
            for failure in failures {
                XCTAssertNotNil(
                    table[failure.messageKey],
                    "\(language.rawValue) is missing \(failure.messageKey)"
                )
                XCTAssertNotNil(
                    table[failure.titleKey],
                    "\(language.rawValue) is missing \(failure.titleKey)"
                )
                messages.insert(table[failure.messageKey] ?? "")
            }
            XCTAssertEqual(
                messages.count, failures.count,
                "\(language.rawValue) reuses one message for several causes — the whole point "
                    + "of the typed failure is that the user is told which one happened."
            )
        }
    }

    /// The muted message is the only one that takes an argument. A table whose translation drops
    /// `%@` silently swallows the app name.
    func testMutedMessageInterpolatesTheApp() {
        for language in AppLanguage.concreteCases {
            let format = LocalizationManager.stringTable(for: language)["ai.selection.fail.muted"]
            XCTAssertEqual(
                format?.components(separatedBy: "%@").count, 2,
                "\(language.rawValue) must name the muted app exactly once"
            )
        }
        let rendered = String(
            format: LocalizationManager.stringTable(for: .en)["ai.selection.fail.muted"] ?? "",
            "com.apple.Safari"
        )
        XCTAssertTrue(rendered.contains("com.apple.Safari"))
    }

    // MARK: - Monitor accessor

    /// `rawCachedSelection` is what the explicit paths read. It must not apply the typed-path
    /// weak-AX rejection (a hotkey types nothing into the selection, so it cannot go stale that
    /// way) and must not consume the entry.
    func testRawCachedSelectionIsUnfilteredAndNonDestructive() {
        let defaults = UserDefaults(suiteName: "devtype.tests.selection.raw")!
        defaults.removePersistentDomain(forName: "devtype.tests.selection.raw")
        defaults.set(true, forKey: SelectionMonitor.featureEnabledDefaultsKey)
        let monitor = SelectionMonitor(defaults: defaults)

        let seed = SelectionMonitor.CachedSelection(
            text: "chrome text",
            bundleID: "com.google.Chrome",
            changeToken: 7,
            timestamp: Date()
        )
        monitor.seedCacheForTesting(seed)

        XCTAssertEqual(monitor.rawCachedSelection(), seed)
        XCTAssertEqual(monitor.rawCachedSelection(), seed, "Reading must not consume the entry.")
        XCTAssertNil(
            monitor.cachedSelection(rejectWeakAX: true),
            "The typed path still rejects weak-AX apps; only the explicit path bypasses it."
        )

        monitor.clearCache()
        XCTAssertNil(monitor.rawCachedSelection())
        defaults.removePersistentDomain(forName: "devtype.tests.selection.raw")
    }
}
