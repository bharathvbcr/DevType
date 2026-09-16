import XCTest
@testable import ExpanderEngine

/// The structured refusal vocabulary — and the guarantee that classifying a refusal did not
/// change what any refusal *says*.
///
/// `InjectRefusalKind.classify` replaced a switch inside `sanitizedRefusalReason` that produced
/// only prose. Two things must hold forever after:
///
///   1. **Nothing the user reads changed.** The sentence table below is the historical output,
///      transcribed from the pre-refactor switch. It is a characterization test: it fails if the
///      refactor altered a single sentence.
///   2. **Every refusal now carries a meaning.** A pipeline path that reaches a user without a
///      kind is a path whose guidance silently degrades to the generic sentence — the exact
///      defect this type exists to remove.
final class InjectRefusalKindTests: XCTestCase {

    /// (path, raw reason) → the sentence the pre-refactor `sanitizedRefusalReason` produced.
    private static let historicalSentences: [(path: String?, reason: String, sentence: String)] = [
        ("imagePaste", "attachment missing or unreadable at /tmp/x.png",
         "Image attachment missing or unreadable"),
        ("imagePaste", "some other trouble", "Image paste unavailable"),
        ("fillInRequired", "x", "Fill-in values are required before insertion"),
        ("shellNoPostEvents", "x",
         "Post Events permission is required for multi-line shell insertion"),
        ("eraseContextChanged", "x", "Input or target application changed before insertion"),
        ("eraseIncomplete", "x", "Trigger erase did not complete"),
        ("erasePrecondition", "x", "Erase precondition failed — the target text changed"),
        ("guardedErase", "x", "Erase precondition failed — the target text changed"),
        ("axOnlyRange", "x", "AX insertion failed — Post Events permission is required for fallback"),
        ("secureClipboardPaste", "cannot paste an image",
         "Secure clipboard insertion does not support images"),
        ("secureClipboardPaste", "board unavailable", "Secure clipboard insertion unavailable"),
        ("undoUnverifiable", "x", "Undo refused — target could not be read after intervening input"),
        ("undoOriginalPosition", "x",
         "Undo refused — original insertion position could not be verified"),
        ("undoSelection", "x", "Undo refused — a text selection is active"),
        ("undoContextChanged", "x", "Undo cancelled — input, target, or settings changed"),
        ("undo", "x", "Undo refused — safe reversal could not be verified"),
        ("undoAXRange", "x", "Undo refused — safe reversal could not be verified"),
        ("undoAXDirect", "x", "Undo refused — safe reversal could not be verified"),
        ("undoPaste", "x", "Undo refused — safe reversal could not be verified"),
        ("entryGate_superseded", "x", "Insertion superseded by a newer one"),
        ("entryGate_continuation", "x", "Target application changed before insertion"),
        ("entryGate_secureInput", "x", "Secure Input is active — expansion blocked"),
        ("entryGate_accessibility", "x", "Accessibility unavailable — expansion blocked"),
        ("entryGate_targetChanged", "x", "Target element or selection changed before insertion"),
        ("entryGate_unreproduced", "x", "Insertion context changed before insertion"),
        ("aiResultPlanRefused", "needs post events",
         "Post Events permission is required for insertion"),
        ("aiResultPlanRefused", "something else", "Accessibility unavailable — expansion blocked"),
        ("searchExpansionPlanRefused", "POST EVENTS missing",
         "Post Events permission is required for insertion"),
        // Unrecognised path → substring rules, in their original precedence order.
        (nil, "Secure Input is up", "Secure Input is active — expansion blocked"),
        (nil, "IME marked text present", "Active IME marked text — expansion blocked"),
        (nil, "accessibility is off", "Accessibility unavailable — expansion blocked"),
        (nil, "AXIsProcessTrusted false", "Accessibility unavailable — expansion blocked"),
        (nil, "needs Post Events", "Post Events permission is required for insertion"),
        (nil, "no focused element", "Focused text field unavailable — expansion blocked"),
        (nil, "erase precondition failed", "Erase precondition failed — the target text changed"),
        (nil, "target application changed", "Input or target application changed before insertion"),
        (nil, "input or target moved", "Input or target application changed before insertion"),
        (nil, "completely unrecognised", "Injection refused")
    ]

    // MARK: - Nothing the user reads changed

    func testSentencesMatchPreRefactorOutput() {
        for row in Self.historicalSentences {
            XCTAssertEqual(
                PermissionCoordinator.sanitizedRefusalReason(row.reason, path: row.path),
                row.sentence,
                "sentence drifted for path=\(row.path ?? "nil") reason=\(row.reason)"
            )
        }
    }

    /// The sentence and the kind come from one switch; this proves the two entry points agree.
    func testSentenceAndKindComeFromTheSameClassification() {
        for row in Self.historicalSentences {
            let refusal = InjectRefusalKind.classify(row.reason, path: row.path)
            XCTAssertEqual(refusal.sentence,
                           PermissionCoordinator.sanitizedRefusalReason(row.reason, path: row.path))
            XCTAssertEqual(refusal.kind,
                           PermissionCoordinator.refusalKind(row.reason, path: row.path))
        }
    }

    // MARK: - Every refusal carries a meaning

    /// Every path the pipeline actually refuses through must classify to something specific.
    /// A path landing on `.unknown` is one whose Recovery guidance degrades to the generic
    /// "click into a normal text field" — which is how `erasePrecondition` used to be handled.
    func testEveryKnownPathClassifiesToASpecificKind() {
        let paths = Self.historicalSentences.compactMap(\.path)
        for path in Set(paths) {
            let kind = PermissionCoordinator.refusalKind("representative reason", path: path)
            XCTAssertNotEqual(
                kind, .unknown,
                "path \(path) has no structured kind — its guidance silently falls back to generic"
            )
        }
    }

    func testErasePreconditionIsNotGenericAndDoesNotOfferAnEngineRestart() {
        let kind = PermissionCoordinator.refusalKind(
            "Erase precondition failed — the target text changed", path: "erasePrecondition"
        )
        XCTAssertEqual(kind, .erasePrecondition)
        // The refusal this whole change came from: a guard that worked correctly must not be
        // presented as an engine fault.
        XCTAssertFalse(kind.warrantsEngineRestart)
        XCTAssertNotEqual(kind.guidanceKey, "recovery.refuse.generic")
    }

    /// Restarting the tap cannot fix a per-expansion safety decision. Only an unclassified
    /// refusal keeps the escape hatch, because only there do we not know the engine is fine.
    func testOnlyUnknownWarrantsAnEngineRestart() {
        for kind in InjectRefusalKind.allCases {
            XCTAssertEqual(
                kind.warrantsEngineRestart, kind == .unknown,
                "\(kind.rawValue) disagrees about offering Restart Engine"
            )
        }
    }

    // MARK: - Guidance strings exist and have the right arity

    /// `LocalizationManager.s` ends in `String(format:)`. A guidance key whose string contains a
    /// `%@` while `guidanceTakesReason` is false formats a missing argument; the reverse drops the
    /// reason silently. Both are caught here, in every shipped language.
    func testGuidanceKeysResolveWithMatchingArityInEveryLanguage() {
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for kind in InjectRefusalKind.allCases {
                guard let raw = table[kind.guidanceKey] else {
                    XCTFail("\(language.rawValue) is missing \(kind.guidanceKey)")
                    continue
                }
                XCTAssertFalse(raw.isEmpty, "\(language.rawValue) \(kind.guidanceKey) is empty")
                let specifiers = raw.components(separatedBy: "%@").count - 1
                XCTAssertEqual(
                    specifiers, kind.guidanceTakesReason ? 1 : 0,
                    "\(language.rawValue) \(kind.guidanceKey) has \(specifiers) %@ but "
                        + "guidanceTakesReason=\(kind.guidanceTakesReason)"
                )
            }
        }
    }

    /// Distinct kinds should not all collapse onto one sentence — that would be the old
    /// behaviour wearing a new type.
    func testGuidanceIsActuallyDifferentiated() {
        let keys = Set(InjectRefusalKind.allCases.map(\.guidanceKey))
        XCTAssertGreaterThanOrEqual(
            keys.count, 10,
            "kinds collapsed onto \(keys.count) guidance strings — refusals are not differentiated"
        )
    }

    // MARK: - End-to-end threading

    /// The kind has to survive `recordInjectOutcome`, or the UI is back to guessing from prose.
    func testRecordingARefusalStoresItsKindInProvenance() {
        let coordinator = PermissionCoordinator()
        coordinator.recordInjectOutcome(
            .refused("field window differs from expected erase text"),
            refuseContext: nil,
            path: "erasePrecondition"
        )
        XCTAssertEqual(
            coordinator.lastRecordedInjectRefuseProvenance?.kind, .erasePrecondition,
            "the structured kind was dropped between classification and provenance"
        )
        XCTAssertEqual(
            coordinator.lastRecordedInjectOutcome,
            .refused("Erase precondition failed — the target text changed")
        )
    }

    /// A caller that supplies its own provenance must still get the classified kind stamped on
    /// it — otherwise the capture path silently keeps `.unknown` and re-offers Restart Engine.
    func testSuppliedProvenanceStillReceivesTheClassifiedKind() {
        let coordinator = PermissionCoordinator()
        let supplied = PermissionCoordinator.InjectRefuseProvenance(
            reason: "raw internal prose", frontmostBundleID: "com.example.app"
        )
        XCTAssertEqual(supplied.kind, .unknown)
        coordinator.recordInjectOutcome(
            .refused("raw internal prose"), refuseContext: supplied, path: "entryGate_secureInput"
        )
        let stored = coordinator.lastRecordedInjectRefuseProvenance
        XCTAssertEqual(stored?.kind, .secureInput)
        XCTAssertEqual(stored?.frontmostBundleID, "com.example.app",
                       "stamping the kind must not discard the caller's captured context")
        XCTAssertEqual(stored?.reason, "Secure Input is active — expansion blocked",
                       "provenance must carry the sanitised sentence, never the raw prose")
    }

    /// Non-refusal outcomes must not fabricate provenance or a kind.
    func testNonRefusalOutcomesRecordNoRefusalKind() {
        let coordinator = PermissionCoordinator()
        coordinator.recordInjectOutcome(.succeeded)
        XCTAssertNil(coordinator.lastRecordedInjectRefuseProvenance)
        coordinator.recordInjectOutcome(.postedUnverified)
        XCTAssertNil(coordinator.lastRecordedInjectRefuseProvenance)
    }

    // MARK: - Concurrency

    /// `PermissionCoordinator` documents (§1.11) that the outcome slot is written from
    /// `injectQueue` and read from main. Stamping the kind added a second field to that slot, so
    /// the pair must move together: an observer must never see one refusal's sentence next to a
    /// different refusal's kind. That torn pair would be worse than the bug this replaced — the
    /// guidance would confidently name the wrong remedy.
    func testSentenceAndKindNeverTearUnderConcurrentRefusals() {
        let coordinator = PermissionCoordinator()
        let pairs: [(path: String, sentence: String, kind: InjectRefusalKind)] = [
            ("erasePrecondition", "Erase precondition failed — the target text changed", .erasePrecondition),
            ("entryGate_secureInput", "Secure Input is active — expansion blocked", .secureInput),
            ("undoSelection", "Undo refused — a text selection is active", .undoSelectionActive),
            ("fillInRequired", "Fill-in values are required before insertion", .fillInRequired),
            ("entryGate_superseded", "Insertion superseded by a newer one", .superseded)
        ]
        let valid = Dictionary(uniqueKeysWithValues: pairs.map { ($0.sentence, $0.kind) })

        let writers = DispatchQueue(label: "refusal.writers", attributes: .concurrent)
        let group = DispatchGroup()
        let torn = UnfairLock()
        var tornPairs: [String] = []

        for worker in 0..<8 {
            writers.async(group: group) {
                // Each record does a real permission probe, so the loop is sized for contention
                // rather than volume: 8 writers interleaving is what exercises the lock.
                for iteration in 0..<60 {
                    let pick = pairs[(worker &+ iteration) % pairs.count]
                    coordinator.recordInjectOutcome(
                        .refused("raw prose \(worker)-\(iteration)"),
                        refuseContext: nil,
                        path: pick.path
                    )
                    // Read back a live pair; it may be any writer's, but must be *some* writer's.
                    if let seen = coordinator.lastRecordedInjectRefuseProvenance {
                        if valid[seen.reason] != seen.kind {
                            torn.withLock {
                                tornPairs.append("\(seen.reason) :: \(seen.kind.rawValue)")
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success, "concurrent refusals deadlocked")
        XCTAssertTrue(tornPairs.isEmpty, "sentence/kind pair tore: \(tornPairs.prefix(3))")

        // The slot still holds a coherent, classified refusal once the storm settles.
        let final = coordinator.lastRecordedInjectRefuseProvenance
        XCTAssertNotNil(final)
        XCTAssertEqual(valid[final?.reason ?? ""], final?.kind)
        XCTAssertNotEqual(final?.kind, .unknown)
    }

    // MARK: - Hostile input

    /// Classification runs on refusal prose that can contain attacker-influenced field text.
    /// It must terminate, never crash, and never leak the raw reason into the sentence.
    func testClassificationIsTotalOverHostileInput() {
        let hostilePaths: [String?] = [
            nil, "", "erasePrecondition", "ERASEPRECONDITION", " erasePrecondition ",
            "undo", "unknown-path", String(repeating: "p", count: 4096)
        ]
        let hostileReasons = [
            "", " ", "\u{0}", "%@ %d %@", String(repeating: "x", count: 100_000),
            "🧨🧨🧨", "\u{202E}reversed", "secure input\u{0}", "AXIsProcessTrusted false",
            String(repeating: "erase precondition ", count: 500)
        ]
        for path in hostilePaths {
            for reason in hostileReasons {
                let refusal = InjectRefusalKind.classify(reason, path: path)
                XCTAssertFalse(refusal.sentence.isEmpty,
                               "empty sentence for path=\(path ?? "nil")")
                // The sentence must be one of the finite, curated set — never the raw reason.
                // `selectionSourceUnavailable` is the one deliberate passthrough, and it is only
                // reachable from the three panel-delivery paths, none of which are exercised here.
                XCTAssertNotEqual(refusal.kind, .selectionSourceUnavailable)
                XCTAssertLessThan(
                    refusal.sentence.count, 200,
                    "sentence looks like leaked raw prose for path=\(path ?? "nil")"
                )
            }
        }
    }

    /// A long or hostile reason must not smuggle field contents past the sanitiser.
    func testSanitizerNeverEchoesAnUnrecognisedReason() {
        let secret = "SECRET-FIELD-CONTENTS-9F3A"
        let sentence = PermissionCoordinator.sanitizedRefusalReason(secret, path: "totally-unknown")
        XCTAssertEqual(sentence, "Injection refused")
        XCTAssertFalse(sentence.contains(secret))
    }

    /// Classification is deterministic: the same input cannot yield different advice run to run.
    func testClassificationIsDeterministic() {
        var generator = SplitMix64(seed: 0x5EED_1234)
        let alphabet = Array("abcdefg secure input ime focus post events erase precondition")
        for _ in 0..<500 {
            let length = Int(generator.next() % 60)
            let reason = String((0..<length).map { _ in
                alphabet[Int(generator.next() % UInt64(alphabet.count))]
            })
            let first = InjectRefusalKind.classify(reason, path: nil)
            let second = InjectRefusalKind.classify(reason, path: nil)
            XCTAssertEqual(first, second)
        }
    }
}
