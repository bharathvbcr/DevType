import XCTest
@testable import ExpanderEngine

/// Keystroke-level reachability: **can every trigger in a real library actually expand?**
///
/// The existing suites test the pieces — `AbbreviationMatcher` against a buffer, the prefix index
/// against a trigger list, `HeldExpansionState` against one keystroke. None of them answer the
/// question a user asks when a snippet does nothing: *I typed it, why did nothing happen?*
/// Answering that needs the pieces wired together in the same order the tap callback wires them,
/// then driven with whole typing sessions.
///
/// `TypedExpansionSimulator` below is that wiring. It deliberately mirrors the matching portion of
/// `EventTapEngine.handleTapEvent` — append, match, longer-trigger-wins cancel, ambiguity hold,
/// fire — so a divergence between it and the engine is a test bug, not a false alarm. It does not
/// model injection: everything downstream of the decision to expand is already covered by the
/// delivery suites, and the field reports show that half working.
final class TypedExpansionReachabilityTests: XCTestCase {

    // MARK: - Simulator

    /// One keystroke's effect on the expansion state machine.
    enum Outcome: Equatable {
        case nothing
        case held(trigger: String)
        case expanded(trigger: String, suffix: String)
        case holdCancelled(reason: String)
    }

    /// Mirror of the engine's matching loop, minus injection.
    final class TypedExpansionSimulator {
        let matcher: AbbreviationMatcher
        let prefixIndex: TriggerPrefixIndex
        let bundleID: String?
        private var ring = CharacterRingBuffer(capacity: 64)
        private let coordinator = HeldExpansionCoordinator<String>()

        /// Matches the engine: secrets are filtered at the single door into the matcher.
        init(snippets: [SnippetModel], bundleID: String? = "com.anthropic.claudefordesktop") {
            let matchable = snippets.filter(\.isTypedTriggerExpandable)
            self.matcher = AbbreviationMatcher(snippets: matchable)
            self.prefixIndex = TriggerPrefixIndex(snippets: matchable)
            self.bundleID = bundleID
        }

        var hasHold: Bool { coordinator.hasHold }
        var telemetry: HeldExpansionCoordinator<String>.Telemetry { coordinator.telemetry }

        /// One ordinary character key.
        @discardableResult
        func type(_ character: Character) -> Outcome {
            ring.append(character)
            return decide(typedNow: String(character), isDelete: false)
        }

        /// Distinct name from `type(_: Character)` on purpose: a `type("x")` call site would
        /// otherwise silently resolve to whichever overload the literal happened to prefer.
        @discardableResult
        func typeText(_ text: String) -> [Outcome] {
            text.map { type($0) }
        }

        /// Backspace.
        @discardableResult
        func backspace() -> Outcome {
            ring.removeLast()
            return decide(typedNow: "", isDelete: true)
        }

        /// A key the engine classifies as `clearBuffer` (arrows, escape) or a chorded key.
        @discardableResult
        func resetKey() -> Outcome {
            ring.removeAll()
            let cancelled = coordinator.cancelAll(reason: .bufferReset)
            return cancelled ? .holdCancelled(reason: "bufferReset") : .nothing
        }

        /// The debounce timer firing.
        @discardableResult
        func debounceTimeout() -> Outcome {
            guard let generation = coordinator.currentHoldGeneration else { return .nothing }
            guard let hold = coordinator.claimForTimeout(generation: generation) else { return .nothing }
            ring.removeAll()
            return .expanded(trigger: hold.state.trigger, suffix: hold.state.pendingSuffix)
        }

        private func decide(typedNow: String, isDelete: Bool) -> Outcome {
            let characters = ring.makeArray()
            guard let match = matcher.match(characters: characters, bundleID: bundleID) else {
                switch coordinator.resolveKeystroke(
                    typedNow: typedNow,
                    isDelete: isDelete,
                    prefixIndex: prefixIndex
                ) {
                case .noHold:
                    return .nothing
                case .cancelled(let reason):
                    return .holdCancelled(reason: reason.rawValue)
                case .rearmed(let hold):
                    return .held(trigger: hold.state.trigger)
                case .fire(let hold, let suffix):
                    ring.removeAll()
                    return .expanded(trigger: hold.state.trigger, suffix: suffix)
                }
            }

            coordinator.cancelAll(reason: .longerTriggerWon)

            if prefixIndex.isAmbiguous(
                trigger: match.matchedText,
                caseSensitive: match.snippet.isCaseSensitive
            ) {
                coordinator.arm(payload: match.matchedText, trigger: match.matchedText, focusPID: 1)
                return .held(trigger: match.matchedText)
            }

            ring.removeAll()
            return .expanded(trigger: match.matchedText, suffix: "")
        }
    }

    // MARK: - The real library

    /// Every trigger from the field-report library, with its real flags.
    ///
    /// This is a fixture, not an example: the shape is what makes it valuable — 58 triggers that
    /// all start with a backtick, all set `requireWordBoundary`, most case-sensitive, four of them
    /// secret. Rules that look fine against `hello`/`hi` behave differently here.
    static let realTriggers: [(trigger: String, caseSensitive: Bool, secret: Bool)] = [
        ("`mdegree", true, false), ("`asu", false, false), ("`bme", true, false),
        ("`ece", true, false), ("`srm", true, false), ("`ttu", true, false),
        ("`elp", true, false), ("`bdegree", true, false), ("`sreejaclip", true, false),
        ("`slm", true, false),
        ("`mail", true, false), ("`amail", true, false), ("`smail", true, false),
        ("`imail", true, false), ("`vmail", true, false),
        ("`linkedin", true, false), ("`port", true, false), ("`github", true, false),
        ("`scholarlm", true, false), ("`spion", true, false), ("`calender", false, false),
        ("`orcid", true, false), ("`omsc", true, false), ("`slmabout", false, false),
        ("`slml", true, false), ("`gscholar", true, false),
        ("`pass", true, true), ("`jpass", true, true), ("`ipass", true, true),
        ("`apass", true, true),
        ("`iaddress", true, false), ("`txaddress", true, false), ("`azaddress", true, false),
        ("`psno", true, false), ("`azdl", true, false), ("`ssn", true, false),
        ("`asuid", true, false),
        ("`indate", true, false), ("`date", true, false), ("`usdate", true, false),
        ("`fdate", true, false), ("`mydate", true, false),
        ("`cdcode", true, false), ("`cdscholarlm", true, false), ("`cddevcouncil", true, false),
        ("`cdgeno", true, false), ("`cdgolf", true, false), ("`cdport", true, false),
        ("`cdchronicle", true, false),
        ("`fname", true, false), ("`fnum", true, false), ("`name", true, false),
        ("`num", true, false),
        ("`commit", true, false), ("`rtest", true, false), ("`push", true, false),
        ("`test", true, false), ("`gaps", true, false)
    ]

    static func realLibrary() -> [SnippetModel] {
        realTriggers.map { entry in
            SnippetModel(
                title: entry.trigger,
                triggerKeyword: entry.trigger,
                replacementText: entry.secret ? "" : "REPLACEMENT(\(entry.trigger))",
                isCaseSensitive: entry.caseSensitive,
                requireWordBoundary: true,
                isSecret: entry.secret
            )
        }
    }

    private static var expandableTriggers: [String] {
        realTriggers.filter { !$0.secret }.map(\.trigger)
    }

    private func makeSimulator(bundleID: String? = "com.anthropic.claudefordesktop")
        -> TypedExpansionSimulator {
        TypedExpansionSimulator(snippets: Self.realLibrary(), bundleID: bundleID)
    }

    /// Types `trigger` and lets any hold resolve, returning the final outcome.
    private func typeTriggerAndSettle(
        _ trigger: String,
        into simulator: TypedExpansionSimulator,
        prefix: String = ""
    ) -> Outcome {
        if !prefix.isEmpty { simulator.typeText(prefix) }
        var last = Outcome.nothing
        for character in trigger { last = simulator.type(character) }
        if case .held = last { last = simulator.debounceTimeout() }
        return last
    }

    // MARK: - 1. Every expandable trigger is reachable, in every typing context

    /// The headline property. A trigger that cannot fire from an empty field is dead on arrival.
    func testEveryExpandableTriggerFiresFromAnEmptyField() {
        for trigger in Self.expandableTriggers {
            let simulator = makeSimulator()
            let outcome = typeTriggerAndSettle(trigger, into: simulator)
            XCTAssertEqual(
                outcome, .expanded(trigger: trigger, suffix: ""),
                "\(trigger) did not expand when typed into an empty field."
            )
        }
    }

    /// The contexts a trigger is actually typed in. Each of these has broken an expander before:
    /// mid-sentence after a space, glued to a preceding word, after punctuation, on a new line,
    /// and deep enough into a paragraph that the 64-character ring buffer has wrapped.
    func testEveryExpandableTriggerFiresAfterEveryKindOfPrecedingText() {
        let prefixes: [(name: String, text: String)] = [
            ("after a space", "hello "),
            ("glued to a word", "hello"),
            ("after punctuation", "hello, "),
            ("after a newline", "hello\n"),
            ("after a tab", "hello\t"),
            ("after another backtick", "hello ` "),
            ("after a digit", "abc123"),
            ("after an emoji", "hello 👋 "),
            ("past the ring capacity", String(repeating: "filler text ", count: 12))
        ]
        for (name, prefix) in prefixes {
            for trigger in Self.expandableTriggers {
                let simulator = makeSimulator()
                let outcome = typeTriggerAndSettle(trigger, into: simulator, prefix: prefix)
                XCTAssertEqual(
                    outcome, .expanded(trigger: trigger, suffix: ""),
                    "\(trigger) did not expand \(name)."
                )
            }
        }
    }

    /// Case-sensitive triggers must fire on the exact spelling and, equally important, must NOT
    /// fire on a different one — a case-sensitive snippet quietly matching the wrong case is how
    /// an expansion lands where the user did not want it.
    func testCaseSensitivityIsHonouredInBothDirections() {
        for entry in Self.realTriggers where !entry.secret {
            let upper = entry.trigger.uppercased()
            guard upper != entry.trigger else { continue }
            let simulator = makeSimulator()
            let outcome = typeTriggerAndSettle(upper, into: simulator)
            if entry.caseSensitive {
                XCTAssertEqual(
                    outcome, .nothing,
                    "\(entry.trigger) is case-sensitive but fired for \(upper)."
                )
            } else {
                XCTAssertEqual(
                    outcome, .expanded(trigger: upper, suffix: ""),
                    "\(entry.trigger) is case-insensitive but did not fire for \(upper)."
                )
            }
        }
    }

    // MARK: - 2. Ambiguous triggers — both the short and the long one stay reachable

    /// `` `asu `` is a strict prefix of `` `asuid ``, and `` `slm `` of `` `slml `` /
    /// `` `slmabout ``. Both ends of each pair must remain typable.
    func testShorterAndLongerAmbiguousTriggersAreBothReachable() {
        for pair in [("`asu", "`asuid"), ("`slm", "`slml"), ("`slm", "`slmabout")] {
            let shortSimulator = makeSimulator()
            XCTAssertEqual(
                typeTriggerAndSettle(pair.0, into: shortSimulator),
                .expanded(trigger: pair.0, suffix: ""),
                "\(pair.0) unreachable — the debounce never resolved."
            )

            let longSimulator = makeSimulator()
            XCTAssertEqual(
                typeTriggerAndSettle(pair.1, into: longSimulator),
                .expanded(trigger: pair.1, suffix: ""),
                "\(pair.1) unreachable — the shorter trigger shadowed it."
            )
        }
    }

    /// Typing on past an ambiguous trigger into a non-trigger word must still expand the short
    /// one and re-append what was typed after it, exactly as immediate firing would have.
    func testAmbiguousTriggerFiresWithSuffixWhenTheWordDiverges() {
        let simulator = makeSimulator()
        simulator.typeText("`asu")
        XCTAssertTrue(simulator.hasHold, "`asu should be held — it is a prefix of `asuid.")
        let outcome = simulator.type(Character("r"))
        XCTAssertEqual(
            outcome, .expanded(trigger: "`asu", suffix: "r"),
            "A diverging keystroke must fire the held trigger with the typed suffix, not drop it."
        )
    }

    /// Only the two genuinely ambiguous triggers may pay debounce latency. If this regresses,
    /// every expansion in the library gets slower.
    func testOnlyGenuinelyAmbiguousTriggersAreHeld() {
        let index = TriggerPrefixIndex(snippets: Self.realLibrary())
        var ambiguous: [String] = []
        for entry in Self.realTriggers where !entry.secret {
            if index.isAmbiguous(trigger: entry.trigger, caseSensitive: entry.caseSensitive) {
                ambiguous.append(entry.trigger)
            }
        }
        XCTAssertEqual(
            Set(ambiguous), Set(["`asu", "`slm"]),
            "Exactly the prefixes of longer triggers may be held; everything else fires instantly."
        )
    }

    // MARK: - 3. Silent-drop hunt

    /// A held trigger followed by Return is dropped: the hold cancels rather than expanding.
    ///
    /// This is a deliberate safety choice (Return may have submitted the field, and firing then
    /// would erase from text that is already gone), and this test pins the behaviour so it cannot
    /// change silently. It is also a real, reachable "my snippet did nothing" path — which is why
    /// `EventTapEngine.silentNoExpandDiagnostics()` has to be able to explain it after the fact.
    func testHeldTriggerIsDroppedOnReturnAndThatIsRecorded() {
        let simulator = makeSimulator()
        simulator.typeText("`slm")
        XCTAssertTrue(simulator.hasHold)
        let outcome = simulator.type(Character("\n"))
        XCTAssertEqual(
            outcome, .holdCancelled(reason: "editOrCaretMove"),
            "Return during a hold must cancel rather than erase from a submitted field."
        )
        XCTAssertEqual(
            simulator.telemetry.cancelledByEdit, 1,
            "A dropped hold must be counted — an unrecorded drop is undiagnosable."
        )
    }

    /// Non-ambiguous triggers have no hold to lose, so Return right after them is harmless: they
    /// already expanded on their final character.
    func testUnambiguousTriggerIsUnaffectedByAnImmediateReturn() {
        let simulator = makeSimulator()
        var last = Outcome.nothing
        for character in "`name" { last = simulator.type(character) }
        XCTAssertEqual(last, .expanded(trigger: "`name", suffix: ""))
        XCTAssertFalse(simulator.hasHold, "`name is extended by nothing and must not be held.")
    }

    /// Secret triggers never expand by typing. Deliberate — but the point of this test is that
    /// the *engine* must be able to say so, because to the user it is indistinguishable from a
    /// broken snippet.
    func testSecretTriggersNeverExpandByTypingAndAreExplainable() {
        for entry in Self.realTriggers where entry.secret {
            let simulator = makeSimulator()
            let outcome = typeTriggerAndSettle(entry.trigger, into: simulator)
            XCTAssertEqual(
                outcome, .nothing,
                "\(entry.trigger) is secret and must never expand from a typed trigger."
            )
        }

        let engine = EventTapEngine()
        engine.snippets = Self.realLibrary()
        let explained = engine.silentNoExpandDiagnostics()
        for entry in Self.realTriggers where entry.secret {
            XCTAssertTrue(
                explained.contains { $0.contains(entry.trigger) },
                "\(entry.trigger) can never fire by typing and must be named in diagnostics."
            )
        }
    }

    /// A disabled snippet must not fire, and must be explainable for the same reason.
    func testDisabledSnippetsDoNotFire() {
        var library = Self.realLibrary()
        for index in library.indices where library[index].triggerKeyword == "`name" {
            library[index].enabled = false
        }
        let simulator = TypedExpansionSimulator(snippets: library)
        XCTAssertEqual(
            typeTriggerAndSettle("`name", into: simulator), .nothing,
            "A disabled snippet must not expand."
        )
    }

    /// A trigger longer than the buffer can hold can never fire. The engine already surfaces
    /// these; this pins that they are genuinely unreachable so the diagnostic is not cosmetic.
    func testOverlongTriggerIsUnreachableAndReported() {
        let overlong = "`" + String(repeating: "x", count: AbbreviationMatcher.matchableTriggerLimit)
        var library = Self.realLibrary()
        library.append(
            SnippetModel(
                title: overlong,
                triggerKeyword: overlong,
                replacementText: "x",
                isCaseSensitive: true,
                requireWordBoundary: true
            )
        )
        let simulator = TypedExpansionSimulator(snippets: library)
        XCTAssertEqual(
            typeTriggerAndSettle(overlong, into: simulator), .nothing,
            "A trigger longer than the ring buffer cannot ever match."
        )

        let engine = EventTapEngine()
        engine.snippets = library
        let explained = engine.silentNoExpandDiagnostics()
        XCTAssertTrue(
            explained.contains { $0.contains("can never fire") },
            "An unreachable overlong trigger must be named in diagnostics: \(explained)"
        )
        XCTAssertTrue(
            explained.contains { $0.contains(overlong) },
            "The diagnostics must name the offending trigger itself, not just a count."
        )
    }

    // MARK: - 4. App scoping

    /// An `excludeApps` snippet must not fire in the excluded app — and must still fire elsewhere.
    /// A snippet silently scoped out of the app the user is in is a prime "it didn't expand".
    func testAppScopedSnippetFiresOnlyWhereItApplies() {
        var library = Self.realLibrary()
        for index in library.indices where library[index].triggerKeyword == "`commit" {
            library[index].excludeApps = ["com.anthropic.claudefordesktop"]
        }

        let excluded = TypedExpansionSimulator(
            snippets: library, bundleID: "com.anthropic.claudefordesktop"
        )
        XCTAssertEqual(
            typeTriggerAndSettle("`commit", into: excluded), .nothing,
            "`commit is excluded from this app and must not fire here."
        )

        let allowed = TypedExpansionSimulator(snippets: library, bundleID: "com.apple.dt.Xcode")
        XCTAssertEqual(
            typeTriggerAndSettle("`commit", into: allowed),
            .expanded(trigger: "`commit", suffix: ""),
            "`commit must still fire in apps it is not excluded from."
        )
    }

    // MARK: - 5. Long typing sessions

    /// Types a realistic paragraph with triggers scattered through it and asserts every one of
    /// them fired. Catches state that leaks between expansions — a ring buffer that is not
    /// cleared, a hold that survives its expansion, a generation that stops advancing.
    func testTriggersStillFireAfterALongMixedTypingSession() {
        let simulator = makeSimulator()
        let filler = "the quick brown fox jumps over the lazy dog. "
        var fired: [String] = []

        for (index, trigger) in Self.expandableTriggers.enumerated() {
            simulator.typeText(String(filler.prefix(index % filler.count + 1)))
            var last = Outcome.nothing
            for character in trigger { last = simulator.type(character) }
            if case .held = last { last = simulator.debounceTimeout() }
            if case .expanded(let expandedTrigger, _) = last { fired.append(expandedTrigger) }
        }

        XCTAssertEqual(
            fired, Self.expandableTriggers,
            "Every trigger must still fire after a long session; state is leaking between expansions."
        )
    }

    /// Backspacing over a trigger and retyping it must expand — a stale ring buffer would either
    /// miss the match or match against text that is no longer there.
    func testRetypingAfterBackspaceStillExpands() {
        for trigger in Self.expandableTriggers {
            let simulator = makeSimulator()
            simulator.typeText(String(trigger.dropLast()))
            for _ in 0..<(trigger.count - 1) { simulator.backspace() }
            XCTAssertEqual(
                typeTriggerAndSettle(trigger, into: simulator),
                .expanded(trigger: trigger, suffix: ""),
                "\(trigger) did not expand after backspacing over a partial attempt."
            )
        }
    }

    /// An arrow key / escape / chorded key clears the buffer. The trigger must still be typable
    /// immediately afterwards.
    func testTriggersFireAfterABufferResetKey() {
        for trigger in Self.expandableTriggers {
            let simulator = makeSimulator()
            simulator.typeText("partial`na")
            simulator.resetKey()
            XCTAssertEqual(
                typeTriggerAndSettle(trigger, into: simulator),
                .expanded(trigger: trigger, suffix: ""),
                "\(trigger) did not expand after a buffer-reset key."
            )
        }
    }
}
