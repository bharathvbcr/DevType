import XCTest
@testable import ExpanderEngine

/// "Proofread every dictation before inserting it", built as the correction stage rather
/// than a pass bolted on after it.
///
/// That placement is the point: the stage already carries protected spans, the validator,
/// the deadline and fallback-to-raw. A second pass after insertion would have inherited none
/// of it — a model that decided to answer the transcript instead of proofreading it would
/// have gone straight into the document.
final class ProofreadModeTests: XCTestCase {

    private var previousMode = false

    override func setUp() {
        super.setUp()
        previousMode = VoicePreferences.isProofreadBeforeInsertEnabled
    }

    override func tearDown() {
        VoicePreferences.isProofreadBeforeInsertEnabled = previousMode
        super.tearDown()
    }

    // MARK: - Selection

    /// Off by default: it costs a round trip before the text lands, and the deterministic
    /// cleanup is enough for most dictation.
    func testProofreadModeIsOffByDefault() {
        UserDefaults.standard.removeObject(forKey: VoicePreferences.proofreadBeforeInsertKey)
        XCTAssertFalse(VoicePreferences.isProofreadBeforeInsertEnabled)
    }

    /// The mode applies whatever produced the transcript. Which recognizer was used does not
    /// change that the user asked for their words to be proofread.
    func testProofreadModeAppliesToEveryEngine() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Proofread mode needs macOS 26")
        }
        let previousEngine = VoicePreferences.transcriptionEngine
        defer { VoicePreferences.transcriptionEngine = previousEngine }

        VoicePreferences.isProofreadBeforeInsertEnabled = true

        for engine in TranscriptionEngine.allCases {
            VoicePreferences.transcriptionEngine = engine
            let snapshot = VoiceSessionSnapshotFactory.make(
                bundleIdentifier: "com.test",
                processIdentifier: 1,
                generation: SessionGeneration(rawValue: 1)
            )
            XCTAssertEqual(
                snapshot.correctionProvider.id,
                AITransformCorrector.id(for: .proofread),
                "\(engine) did not select the proofread corrector"
            )
        }
    }

    func testDisablingTheModeRestoresTheOrdinaryCorrector() {
        VoicePreferences.isProofreadBeforeInsertEnabled = false
        let snapshot = VoiceSessionSnapshotFactory.make(
            bundleIdentifier: "com.test",
            processIdentifier: 1,
            generation: SessionGeneration(rawValue: 1)
        )
        XCTAssertNotEqual(snapshot.correctionProvider.id, AITransformCorrector.id(for: .proofread))
    }

    /// On-device only, so it stays permitted under the strictest privacy route.
    func testProofreadCorrectorIsOnDeviceOnly() {
        let corrector = AITransformCorrector(kind: .proofread)
        XCTAssertEqual(corrector.descriptor.privacyRoute, .onDeviceOnly)
        XCTAssertTrue(PrivacyRoute.onDeviceOnly.permits(corrector.descriptor.privacyRoute))
    }

    func testProofreadCorrectorIsRegistered() async {
        let registry = CorrectionProviderRegistry()
        let corrector = await registry.corrector(for: AITransformCorrector.id(for: .proofread))
        XCTAssertNotNil(corrector, "The proofread corrector is not reachable from the registry")
    }

    // MARK: - Superseding the live text

    /// A proofread pass legitimately rewrites text the commit barrier has already sealed —
    /// the one case where replacing sealed text is correct rather than the defect this
    /// subsystem exists to prevent. The session identifies it by provider id.
    func testTransformProvidersAreIdentifiedAsSuperseding() {
        XCTAssertTrue(AITransformCorrector.isTransformProvider(AITransformCorrector.id(for: .proofread)))
        XCTAssertTrue(AITransformCorrector.isTransformProvider(AITransformCorrector.id(for: .rewrite)))

        // Ordinary correctors refine the live text and must stay behind the barrier.
        XCTAssertFalse(AITransformCorrector.isTransformProvider("deterministic.local"))
        XCTAssertFalse(AITransformCorrector.isTransformProvider("apple.foundation-models"))
        XCTAssertFalse(AITransformCorrector.isTransformProvider("ollama.corrector"))
    }

    /// The replacement is bounded by what dictation owns, so even a wholesale rewrite cannot
    /// reach the user's own text.
    func testSupersedingReplacementCannotReachPreexistingText() {
        let reconciler = VoiceTranscriptReconciler()
        let preexisting = "The user wrote this. "
        var document = preexisting

        // Live typing puts a dictation down and seals it.
        let typed = reconciler.reconcile(target: "their going tommorow")
        document += typed.textToInject
        reconciler.commitBoundary()
        XCTAssertEqual(document, preexisting + "their going tommorow")

        // The proofread pass supersedes it wholesale.
        let rollback = reconciler.rollbackAll()
        XCTAssertEqual(
            rollback.eraseCount, "their going tommorow".count,
            "The replacement must cover exactly the dictated text, no more"
        )
        document.removeLast(rollback.eraseCount)
        document += "They're going tomorrow."

        XCTAssertEqual(document, preexisting + "They're going tomorrow.")
        XCTAssertTrue(document.hasPrefix(preexisting), "The replacement reached the user's own text")
    }

    // MARK: - Failure behaviour

    /// The pass is an enhancement. If Apple Intelligence is unavailable or declines, the
    /// user still gets their words — cleaned deterministically, never lost.
    func testCorrectorFallsBackToDeterministicWhenUnavailable() async throws {
        let corrector = AITransformCorrector(kind: .proofread)
        let raw = "um so I need to fix the parser bug today"

        let candidate = try await corrector.correct(
            VoiceFixtures.correctionRequest(raw, deadlineSeconds: 5)
        )

        XCTAssertFalse(candidate.text.isEmpty, "A declined pass must never return nothing")
        for word in ["parser", "bug", "today"] {
            XCTAssertTrue(
                candidate.text.lowercased().contains(word),
                "Fallback lost \"\(word)\": \(candidate.text)"
            )
        }
    }

    /// An expired deadline must return immediately with the words intact, not stall the
    /// insertion waiting on a model.
    func testExpiredDeadlineReturnsTheWordsImmediately() async throws {
        let corrector = AITransformCorrector(kind: .proofread)
        let raw = "deploy the gateway at three"

        let started = Date()
        let candidate = try await corrector.correct(
            VoiceFixtures.correctionRequest(raw, deadlineSeconds: -1)
        )

        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "Expired deadline still waited")
        for word in ["deploy", "gateway", "three"] {
            XCTAssertTrue(candidate.text.lowercased().contains(word))
        }
    }

    /// Whatever the pass does, the validator still guards it — protected spans survive.
    func testProtectedSpansSurviveTheProofreadStage() async {
        let raw = "run kubectl apply --no-verify against v2.1.0"
        let spans = ProtectedSpanExtractor.extract(from: raw)
        XCTAssertFalse(spans.isEmpty)

        // A pass that mangles an identifier must be rejected in favour of the raw text.
        let final = await CorrectionPipeline.execute(
            rawTranscript: VoiceFixtures.rawTranscript(raw),
            corrector: StubCorrector(behavior: .returns("run kubectl apply no verify against version 2.1.0")),
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .onDeviceOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )
        XCTAssertEqual(final.text, raw, "A mangled identifier must fall back to the raw transcript")
    }
}
