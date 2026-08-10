import XCTest
@testable import ExpanderEngine

/// Randomised typing against the real library, checking the two properties that matter and that
/// example-based tests cannot cover exhaustively:
///
///   * **soundness** — every expansion the engine decides on corresponds to text the user
///     actually just typed. A phantom expansion erases characters the user wants to keep, which
///     is the worst outcome this engine has (worse than not expanding at all).
///   * **completeness** — a trigger typed contiguously always expands, from any prior state the
///     fuzzer can reach. "It works unless you happened to be in state X" is precisely the shape
///     of the complaint that started this.
///
/// Seeded, so a failure is reproducible from the seed printed in the assertion message rather
/// than being a one-off no one can reproduce.
final class ExpansionFuzzTests: XCTestCase {

    /// Deterministic LCG. `SystemRandomNumberGenerator` would make failures unreproducible.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }
    }

    private typealias Simulator = TypedExpansionReachabilityTests.TypedExpansionSimulator
    private typealias Outcome = TypedExpansionReachabilityTests.Outcome

    private var expandableTriggers: [String] {
        TypedExpansionReachabilityTests.realTriggers.filter { !$0.secret }.map(\.trigger)
    }

    /// One fuzz step: what the simulated user does next.
    private enum Step {
        case character(Character)
        case wholeTrigger(String)
        case backspace
        case resetKey
        case debounceTimeout
    }

    private func randomStep(
        using generator: inout SeededGenerator,
        triggers: [String]
    ) -> Step {
        // Weighted so triggers and near-misses come up far more often than uniform text would
        // produce them — the interesting states are all around trigger boundaries.
        switch Int.random(in: 0..<100, using: &generator) {
        case 0..<22:
            return .wholeTrigger(triggers.randomElement(using: &generator) ?? "`name")
        case 22..<40:
            // Trigger fragments: the states where a hold is live or a match is one key away.
            let trigger = triggers.randomElement(using: &generator) ?? "`name"
            let cut = Int.random(in: 1...max(1, trigger.count - 1), using: &generator)
            return .wholeTrigger(String(trigger.prefix(cut)))
        case 40..<70:
            let alphabet: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCZ0123 .,;`~!@#$%^&*()_-\n\t")
            return .character(alphabet.randomElement(using: &generator) ?? "x")
        case 70..<82:
            return .backspace
        case 82..<92:
            return .debounceTimeout
        default:
            return .resetKey
        }
    }

    /// Soundness: the engine never decides to expand text the user did not type.
    ///
    /// The check is exact rather than statistical: a shadow copy of the match buffer is kept in
    /// the test, and every expansion must be backed by `trigger + suffix` sitting at the end of
    /// it. An expansion that is not is an erase aimed at the user's own characters.
    func testFuzzedTypingNeverFabricatesAnExpansion() {
        let triggers = expandableTriggers
        for seed in UInt64(1)...40 {
            var generator = SeededGenerator(seed: seed)
            let simulator = Simulator(snippets: TypedExpansionReachabilityTests.realLibrary())
            var shadow = ""

            for stepIndex in 0..<400 {
                let step = randomStep(using: &generator, triggers: triggers)
                var outcomes: [Outcome] = []

                switch step {
                case .character(let character):
                    shadow.append(character)
                    outcomes = [simulator.type(character)]
                case .wholeTrigger(let text):
                    for character in text {
                        shadow.append(character)
                        let outcome = simulator.type(character)
                        outcomes.append(outcome)
                        if case .expanded = outcome { break }
                    }
                case .backspace:
                    if !shadow.isEmpty { shadow.removeLast() }
                    outcomes = [simulator.backspace()]
                case .resetKey:
                    shadow = ""
                    outcomes = [simulator.resetKey()]
                case .debounceTimeout:
                    outcomes = [simulator.debounceTimeout()]
                }

                for outcome in outcomes {
                    guard case .expanded(let trigger, let suffix) = outcome else { continue }
                    XCTAssertTrue(
                        shadow.hasSuffix(trigger + suffix),
                        """
                        seed \(seed) step \(stepIndex): expanded \(trigger) + suffix \(suffix) \
                        but the buffer ended with \(String(shadow.suffix(24)).debugDescription). \
                        An expansion not backed by typed text erases the user's characters.
                        """
                    )
                    XCTAssertTrue(
                        triggers.contains(trigger),
                        "seed \(seed): expanded \(trigger), which is not an enabled trigger."
                    )
                    shadow = ""
                }
            }
        }
    }

    /// Completeness: whatever state the fuzzer leaves behind, typing a trigger still expands it.
    ///
    /// This is the property the field failure violated. The engine reached a state — matching
    /// suspended by a leaked panel token — in which no trigger could ever fire again, and nothing
    /// in the state was visibly wrong.
    func testATriggerAlwaysExpandsFromAnyFuzzedState() {
        let triggers = expandableTriggers
        for seed in UInt64(100)...140 {
            var generator = SeededGenerator(seed: seed)
            let simulator = Simulator(snippets: TypedExpansionReachabilityTests.realLibrary())

            for _ in 0..<120 {
                switch randomStep(using: &generator, triggers: triggers) {
                case .character(let character): simulator.type(character)
                case .wholeTrigger(let text): simulator.typeText(text)
                case .backspace: simulator.backspace()
                case .resetKey: simulator.resetKey()
                case .debounceTimeout: simulator.debounceTimeout()
                }
            }

            // Whatever state that left, a space settles any live hold, then every trigger must fire.
            for trigger in triggers {
                simulator.type(" ")
                var last = Outcome.nothing
                for character in trigger { last = simulator.type(character) }
                if case .held = last { last = simulator.debounceTimeout() }
                XCTAssertEqual(
                    last, .expanded(trigger: trigger, suffix: ""),
                    "seed \(seed): \(trigger) did not expand after fuzzing — the engine reached a state where it is unreachable."
                )
            }
        }
    }

    /// Ambiguous triggers are the ones with a state machine behind them, so they get a dedicated
    /// pass: however the hold is interrupted, the engine must end in a defined state — expanded,
    /// or cancelled with the text left literal — and never expand a trigger the user did not type.
    func testAmbiguousTriggerHoldsAlwaysResolveCleanly() {
        let interruptions: [(name: String, apply: (Simulator) -> Outcome)] = [
            ("space", { $0.type(" ") }),
            ("newline", { $0.type("\n") }),
            ("tab", { $0.type("\t") }),
            ("backspace", { $0.backspace() }),
            ("reset key", { $0.resetKey() }),
            ("timeout", { $0.debounceTimeout() }),
            ("diverging letter", { $0.type("z") }),
            ("completing letter", { $0.type("i") })
        ]

        for ambiguous in ["`asu", "`slm"] {
            for interruption in interruptions {
                let simulator = Simulator(snippets: TypedExpansionReachabilityTests.realLibrary())
                simulator.typeText(ambiguous)
                XCTAssertTrue(
                    simulator.hasHold,
                    "\(ambiguous) must be held — it is a strict prefix of a longer trigger."
                )

                let outcome = interruption.apply(simulator)
                switch outcome {
                case .expanded(let trigger, _):
                    XCTAssertEqual(
                        trigger, ambiguous,
                        "\(interruption.name) after \(ambiguous) expanded the wrong trigger."
                    )
                    XCTAssertFalse(simulator.hasHold, "An expanded hold must be consumed.")
                case .held:
                    // Still viable: the keystroke spelled further into a longer trigger
                    // (`` `asu `` + `i` is on the way to `` `asuid ``), so waiting is correct.
                    // It must then still be resolvable — a hold with no exit is a lost snippet.
                    let settled = simulator.type(" ")
                    if case .held = settled {
                        XCTFail("\(ambiguous) stayed held through a terminator after \(interruption.name).")
                    }
                    XCTAssertFalse(simulator.hasHold)
                case .holdCancelled, .nothing:
                    // Literal text left in the field is always an acceptable resolution.
                    XCTAssertFalse(
                        simulator.hasHold,
                        "\(interruption.name) left \(ambiguous) held with no way out."
                    )
                }
            }
        }
    }
}
