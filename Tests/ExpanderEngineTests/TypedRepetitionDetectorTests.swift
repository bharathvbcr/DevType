import XCTest
@testable import ExpanderEngine

/// `TypedRepetitionDetector` — and specifically the privacy claims the consent prompt makes.
///
/// The prompt tells the user four things: it keeps a hash and a count rather than the text; the
/// key is random per launch and discarded on Forget; the text is held only after a phrase has
/// recurred three times; and nothing longer than the engine's 64-character buffer is considered.
/// Each of those is a testable statement, and a consent prompt that says something the code does
/// not do is worse than no prompt.
final class TypedRepetitionDetectorTests: XCTestCase {

    private var detector = TypedRepetitionDetector()

    override func setUp() {
        super.setUp()
        detector = TypedRepetitionDetector()
    }

    private let phrase = "thanks for getting back to me"

    // MARK: - The threshold

    func testNothingIsOfferedBeforeTheThreshold() {
        for _ in 1..<TypedRepetitionDetector.repeatThreshold {
            XCTAssertNil(detector.record(phrase: phrase))
        }
    }

    func testTheThresholdOccurrenceOffersTheCandidate() {
        var candidate: TypedRepetitionDetector.Candidate?
        for _ in 0..<TypedRepetitionDetector.repeatThreshold {
            candidate = detector.record(phrase: phrase) ?? candidate
        }
        XCTAssertEqual(candidate?.text, phrase)
        XCTAssertEqual(candidate?.occurrences, TypedRepetitionDetector.repeatThreshold)
    }

    /// Offered once, on the crossing. Otherwise the fourth, fifth and sixth repeat would each
    /// raise the same dialog and the feature would become an interruption.
    func testTheOfferIsNotRepeatedAfterTheThreshold() {
        for _ in 0..<TypedRepetitionDetector.repeatThreshold { _ = detector.record(phrase: phrase) }
        for _ in 0..<5 {
            XCTAssertNil(detector.record(phrase: phrase), "the offer must fire exactly once")
        }
    }

    func testTrivialFormattingDifferencesCountAsTheSamePhrase() {
        _ = detector.record(phrase: "thanks for  getting back to me")
        _ = detector.record(phrase: "  Thanks for getting back to me  ")
        let candidate = detector.record(phrase: "THANKS FOR GETTING BACK TO ME")
        XCTAssertNotNil(candidate, "case and spacing must not split one phrase into three")
    }

    func testDifferentPhrasesAreCountedSeparately() {
        // Drive one phrase all the way to its offer.
        var offered: TypedRepetitionDetector.Candidate?
        for _ in 0..<TypedRepetitionDetector.repeatThreshold {
            offered = detector.record(phrase: "the first phrase here") ?? offered
        }
        XCTAssertEqual(offered?.text, "the first phrase here")

        // A different phrase starts from zero rather than inheriting that progress.
        XCTAssertNil(detector.record(phrase: "a completely different phrase"))
        XCTAssertNil(detector.record(phrase: "a completely different phrase"))
        XCTAssertNotNil(detector.record(phrase: "a completely different phrase"))
    }

    // MARK: - What is never considered

    /// The space requirement is privacy work, not quality work: it keeps long unbroken tokens —
    /// the shape of a password or key typed into a field that does not raise Secure Input — out
    /// of the table entirely.
    func testAnUnbrokenTokenIsNeverCounted() {
        let secretish = "hunter2Tr0ub4dor&3xKcd"
        XCTAssertFalse(TypedRepetitionDetector.isEligible(secretish))
        for _ in 0..<10 { XCTAssertNil(detector.record(phrase: secretish)) }
        XCTAssertEqual(detector.trackedPhraseCount, 0, "nothing about it was retained at all")
    }

    func testMostlyNumericInputIsNeverCounted() {
        XCTAssertFalse(TypedRepetitionDetector.isEligible("4111 1111 1111 1111"))
        XCTAssertFalse(TypedRepetitionDetector.isEligible("123 456 789 01"))
    }

    func testShortPhrasesAreNotWorthASnippet() {
        XCTAssertFalse(TypedRepetitionDetector.isEligible("hi there"))
    }

    /// The consent prompt promises nothing longer than the engine's matching buffer is looked
    /// at. That number is `EventTapEngine.maxBufferCapacity`, not a second constant that could
    /// drift away from it.
    func testNothingLongerThanTheEngineBufferIsConsidered() {
        XCTAssertEqual(
            TypedRepetitionDetector.maximumPhraseLength,
            EventTapEngine.maxBufferCapacity
        )
        let tooLong = String(repeating: "a b ", count: 40)
        XCTAssertGreaterThan(tooLong.count, EventTapEngine.maxBufferCapacity)
        XCTAssertFalse(TypedRepetitionDetector.isEligible(tooLong))
    }

    func testControlCharactersAreRejected() {
        XCTAssertFalse(TypedRepetitionDetector.isEligible("some text\u{0007} with a bell"))
    }

    // MARK: - "A hash and a count, not the text"

    /// Nothing readable is retained before the threshold. Asserted by exhausting the type's own
    /// surface: there is no accessor that yields text, and the only count it exposes is a number.
    func testNoTextIsRetrievableBeforeTheThreshold() {
        _ = detector.record(phrase: phrase)
        _ = detector.record(phrase: phrase)
        XCTAssertEqual(detector.trackedPhraseCount, 1)
        // The candidate — the only thing carrying text — has not been produced yet.
        XCTAssertNil(detector.record(phrase: "another phrase entirely"))
    }

    /// The text in the candidate comes from the occurrence in hand, so it is the caller's own
    /// copy rather than something the detector had been holding.
    func testTheCandidateTextIsTheOccurrenceJustSeen() {
        _ = detector.record(phrase: "please find the report attached")
        _ = detector.record(phrase: "PLEASE FIND THE REPORT ATTACHED")
        let candidate = detector.record(phrase: "Please Find The Report Attached")
        XCTAssertEqual(
            candidate?.text,
            "Please Find The Report Attached",
            "the offer shows what was just typed, not a stored earlier casing"
        )
    }

    // MARK: - Forgetting

    func testForgetAllDropsEveryCount() {
        _ = detector.record(phrase: phrase)
        _ = detector.record(phrase: phrase)
        detector.forgetAll()
        XCTAssertEqual(detector.trackedPhraseCount, 0)
    }

    /// Forgetting re-salts, so the same text typed afterwards starts from zero rather than
    /// resuming a count that survived under the old key.
    func testForgetAllResetsTheCountForTheSameText() {
        _ = detector.record(phrase: phrase)
        _ = detector.record(phrase: phrase)
        detector.forgetAll()
        XCTAssertNil(detector.record(phrase: phrase), "the count must restart, not resume")
        XCTAssertNil(detector.record(phrase: phrase))
        XCTAssertNotNil(detector.record(phrase: phrase), "and reach the threshold from scratch")
    }

    /// The consent prompt says the key is thrown away on Forget. Clearing the table alone would
    /// satisfy every other test here, so this asserts the rotation directly.
    func testForgetAllRotatesTheKey() {
        let before = detector.saltFingerprintForTesting
        detector.forgetAll()
        XCTAssertNotEqual(
            before,
            detector.saltFingerprintForTesting,
            "Forget must discard the key, not merely empty the table"
        )
    }

    func testForgettingOnePhraseDoesNotRotateTheKey() {
        let before = detector.saltFingerprintForTesting
        detector.forget(phrase: phrase)
        XCTAssertEqual(
            before,
            detector.saltFingerprintForTesting,
            "dropping one phrase must not invalidate every other count"
        )
    }

    func testForgettingOnePhraseLeavesTheOthers() {
        _ = detector.record(phrase: "the first phrase here")
        _ = detector.record(phrase: "the second phrase here")
        detector.forget(phrase: "the first phrase here")
        XCTAssertEqual(detector.trackedPhraseCount, 1)
    }

    /// Two detectors salt independently, which is what makes a hash meaningless outside the
    /// process that made it.
    func testTwoDetectorsDoNotShareCounts() {
        let a = TypedRepetitionDetector()
        let b = TypedRepetitionDetector()
        for _ in 0..<TypedRepetitionDetector.repeatThreshold { _ = a.record(phrase: phrase) }
        XCTAssertNil(b.record(phrase: phrase), "counts must not be comparable across instances")
    }

    // MARK: - Bounds

    func testTheTableIsBounded() {
        for index in 0..<(TypedRepetitionDetector.maximumTrackedPhrases + 50) {
            _ = detector.record(phrase: "phrase number \(index) here")
        }
        XCTAssertLessThanOrEqual(
            detector.trackedPhraseCount,
            TypedRepetitionDetector.maximumTrackedPhrases
        )
    }

    // MARK: - Consent gating

    func testTheFeatureIsInactiveWithoutBothSwitches() {
        let savedEnabled = UserDefaults.standard.object(forKey: TypedRepetitionPreferences.enabledKey)
        let savedConsent = UserDefaults.standard.object(forKey: TypedRepetitionPreferences.consentKey)
        defer {
            UserDefaults.standard.set(savedEnabled, forKey: TypedRepetitionPreferences.enabledKey)
            UserDefaults.standard.set(savedConsent, forKey: TypedRepetitionPreferences.consentKey)
        }

        UserDefaults.standard.removeObject(forKey: TypedRepetitionPreferences.enabledKey)
        UserDefaults.standard.removeObject(forKey: TypedRepetitionPreferences.consentKey)
        XCTAssertFalse(TypedRepetitionPreferences.isActive, "off by default")

        TypedRepetitionPreferences.isEnabled = true
        XCTAssertFalse(
            TypedRepetitionPreferences.isActive,
            "enabling without consent must not activate it"
        )

        TypedRepetitionPreferences.grantedConsentVersion =
            TypedRepetitionPreferences.currentConsentVersion
        XCTAssertTrue(TypedRepetitionPreferences.isActive)
    }

    /// A future prompt that describes different retention must not inherit the old agreement.
    func testStaleConsentDoesNotCount() {
        let saved = UserDefaults.standard.object(forKey: TypedRepetitionPreferences.consentKey)
        defer { UserDefaults.standard.set(saved, forKey: TypedRepetitionPreferences.consentKey) }
        TypedRepetitionPreferences.grantedConsentVersion =
            TypedRepetitionPreferences.currentConsentVersion - 1
        XCTAssertFalse(TypedRepetitionPreferences.hasCurrentConsent)
    }

    /// Revoking must switch the feature off too, or a later consent bump would resume it.
    func testRevokingConsentAlsoDisablesAndForgets() {
        let savedEnabled = UserDefaults.standard.object(forKey: TypedRepetitionPreferences.enabledKey)
        let savedConsent = UserDefaults.standard.object(forKey: TypedRepetitionPreferences.consentKey)
        defer {
            UserDefaults.standard.set(savedEnabled, forKey: TypedRepetitionPreferences.enabledKey)
            UserDefaults.standard.set(savedConsent, forKey: TypedRepetitionPreferences.consentKey)
        }
        TypedRepetitionPreferences.isEnabled = true
        TypedRepetitionPreferences.grantedConsentVersion =
            TypedRepetitionPreferences.currentConsentVersion
        _ = TypedRepetitionDetector.shared.record(phrase: phrase)

        TypedRepetitionPreferences.revokeConsent()

        XCTAssertFalse(TypedRepetitionPreferences.isEnabled)
        XCTAssertFalse(TypedRepetitionPreferences.hasCurrentConsent)
        XCTAssertEqual(TypedRepetitionDetector.shared.trackedPhraseCount, 0)
    }
}
