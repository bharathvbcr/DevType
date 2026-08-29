import XCTest
@testable import ExpanderEngine

/// Stress and property coverage for the voice pipeline as an assembled system.
///
/// The unit suites check each part; this one checks the seams — that the reducer, the
/// registries, the correction pipeline and the reconciler still hold their invariants when
/// driven with adversarial timing, hostile provider output, and concurrency.
///
/// Providers are stubs installed through the registries, so every case is deterministic and
/// nothing here touches a microphone, a server, or the user's document.
final class VoicePipelineStressTests: XCTestCase {

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 1. Privacy route is enforced at resolution
    // ═══════════════════════════════════════════════════════════════

    /// The route the user chose is a ceiling. A provider may be narrower, never wider —
    /// otherwise a stale preference could ship audio to a server the user excluded.
    func testProviderRouteCeilingIsNeverWidened() {
        let routes: [PrivacyRoute] = [.onDeviceOnly, .localNetworkOnly, .cloudPermitted]

        let expected: [PrivacyRoute: Set<PrivacyRoute>] = [
            .onDeviceOnly:     [.onDeviceOnly],
            .localNetworkOnly: [.onDeviceOnly, .localNetworkOnly],
            .cloudPermitted:   [.onDeviceOnly, .localNetworkOnly, .cloudPermitted],
        ]

        for session in routes {
            for provider in routes {
                XCTAssertEqual(
                    session.permits(provider),
                    expected[session]!.contains(provider),
                    "session=\(session) provider=\(provider)"
                )
            }
        }
    }

    func testCloudProviderIsRefusedOnDeviceOnlySession() async {
        let registry = SpeechProviderRegistry(providers: [
            StubSpeechRecognizer(id: "stub.cloud", privacyRoute: .cloudPermitted),
            StubSpeechRecognizer(id: "apple.speech.legacy", privacyRoute: .onDeviceOnly),
        ])

        let resolved = await registry.resolveActiveRecognizer(
            preferredID: "stub.cloud",
            privacyRoute: .onDeviceOnly
        )

        XCTAssertNotEqual(resolved.descriptor.id, "stub.cloud",
            "An on-device-only session must never resolve a cloud provider")
        XCTAssertEqual(resolved.descriptor.privacyRoute, .onDeviceOnly)
    }

    func testCloudCorrectorIsRefusedOnDeviceOnlySession() async {
        let registry = CorrectionProviderRegistry(providers: [
            StubCorrector(id: "stub.cloud", privacyRoute: .cloudPermitted),
            DeterministicCorrector(),
        ])

        let resolved = await registry.resolveActiveCorrector(
            preferredID: "stub.cloud",
            privacyRoute: .onDeviceOnly
        )

        XCTAssertNotEqual(resolved?.descriptor.id, "stub.cloud")
        XCTAssertEqual(resolved?.descriptor.privacyRoute, .onDeviceOnly)
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 2. Unready providers fall through, they do not fail the session
    // ═══════════════════════════════════════════════════════════════

    func testUnreadyProviderFallsBackToOnDeviceFloor() async {
        let registry = SpeechProviderRegistry(providers: [
            StubSpeechRecognizer(
                id: "stub.down",
                readiness: .temporarilyUnavailable(retryAfterSeconds: 5, reason: .endpointUnreachable)
            ),
            StubSpeechRecognizer(id: "apple.speech.legacy", privacyRoute: .onDeviceOnly),
        ])

        let resolved = await registry.resolveActiveRecognizer(
            preferredID: "stub.down",
            privacyRoute: .onDeviceOnly
        )
        XCTAssertNotEqual(resolved.descriptor.id, "stub.down",
            "A provider that is not ready must not be selected")
    }

    /// The unimplemented SpeechAnalyzer adapter must never be handed out.
    func testUnimplementedAnalyzerAdapterIsNeverResolved() async {
        let registry = SpeechProviderRegistry(providers: [
            AppleSpeechAnalyzerAdapter(),
            StubSpeechRecognizer(id: "apple.speech.legacy", privacyRoute: .onDeviceOnly),
        ])
        let resolved = await registry.resolveActiveRecognizer(
            preferredID: "apple.speech.analyzer",
            privacyRoute: .onDeviceOnly
        )
        XCTAssertNotEqual(resolved.descriptor.id, "apple.speech.analyzer")
    }

    func testCorrectionAlwaysResolvesOrIsExplicitlyDisabled() async {
        let registry = CorrectionProviderRegistry(providers: [
            DeterministicCorrector(),
            StubCorrector(id: "ollama.corrector", privacyRoute: .localNetworkOnly),
            StubCorrector(id: "apple.foundation-models", privacyRoute: .onDeviceOnly),
        ])

        // Disabled is explicit, and distinct from "nothing available".
        let disabled = await registry.resolveActiveCorrector(
            preferredID: CorrectionProviderRegistry.disabledID,
            privacyRoute: .onDeviceOnly
        )
        XCTAssertNil(disabled)

        // Anything else always yields a corrector — there is always a deterministic floor.
        for id in ["does.not.exist", "ollama.corrector", "apple.foundation-models"] {
            let resolved = await registry.resolveActiveCorrector(
                preferredID: id,
                privacyRoute: .onDeviceOnly
            )
            XCTAssertNotNil(resolved, "No corrector resolved for \(id)")
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 3. Correction pipeline never returns worse than raw
    // ═══════════════════════════════════════════════════════════════

    /// Whatever a model does — refuse, hallucinate, wrap, empty, echo the prompt — the
    /// pipeline must deliver either a validated improvement or the raw transcript. It must
    /// never deliver the model's misbehaviour.
    func testPipelineNeverDeliversModelMisbehaviour() async {
        let raw = "lets deploy the api gateway at 3pm and check the v2.1.0 release"

        let hostileOutputs: [(name: String, output: String)] = [
            ("refusal",        "I'm sorry, I cannot help with that."),
            ("ai-preamble",    "As an AI language model, here is the text: deploy it"),
            ("empty",          ""),
            ("whitespace",     "   \n\t  "),
            ("answer-mode",    "The API gateway is a service that routes requests to backends."),
            ("explosion",      String(repeating: "padding words that were never spoken ", count: 20)),
            ("collapse",       "ok"),
            ("span-mangled",   "lets deploy the api gateway at 3pm and check the version 2.1.0 release"),
            ("json",           "{\"text\": \"deploy it\"}"),
            ("prompt-echo",    "Transcript:\nlets deploy the api gateway\n\nCleaned:"),
        ]

        for hostile in hostileOutputs {
            let corrector = StubCorrector(behavior: .returns(hostile.output))
            let final = await CorrectionPipeline.execute(
                rawTranscript: VoiceFixtures.rawTranscript(raw),
                corrector: corrector,
                policy: CorrectionPolicy(),
                vocabulary: VocabularySnapshot(),
                deadline: Date().addingTimeInterval(5),
                privacyRoute: .onDeviceOnly,
                sessionID: VoiceSessionID(),
                generation: SessionGeneration(rawValue: 1)
            )

            XCTAssertFalse(
                final.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(hostile.name): pipeline produced empty text"
            )
            XCTAssertFalse(
                final.text.lowercased().contains("as an ai"),
                "\(hostile.name): refusal text reached the document"
            )
            XCTAssertFalse(
                final.text.contains("```"),
                "\(hostile.name): markdown fence reached the document"
            )
            // Protected spans must survive whatever happened.
            XCTAssertTrue(
                final.text.contains("v2.1.0") || final.text == raw,
                "\(hostile.name): version span lost — got \(final.text)"
            )
        }
    }

    /// A corrector that throws must not take the session down with it.
    func testPipelineSurvivesCorrectorThrowing() async {
        let raw = "the deployment finished"
        let corrector = StubCorrector(behavior: .throws_(
            VoiceFailure(stage: .correction, code: .endpointUnreachable)
        ))

        let final = await CorrectionPipeline.execute(
            rawTranscript: VoiceFixtures.rawTranscript(raw),
            corrector: corrector,
            policy: CorrectionPolicy(),
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .onDeviceOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )
        XCTAssertEqual(final.text, raw, "A throwing corrector must fall back to raw")
    }

    /// Fuzz: for arbitrary raw text and arbitrary model output, the delivered text is
    /// either the validated candidate or exactly the raw transcript. There is no third
    /// outcome, and in particular never a partial or mangled one.
    func testPipelineOutputIsAlwaysCandidateOrRaw() async {
        var rng = SplitMix64(seed: 0x5EED)
        let words = ["deploy", "api", "gateway", "um", "v2.1.0", "--force", "3pm", "bharath@example.com"]
        let noise = ["```", "<think>x</think>", "Cleaned:", "\"", "As an AI", ""]

        for _ in 0..<300 {
            let rawWords = (0..<Int(rng.next() % 10 + 1)).map { _ in words[Int(rng.next() % UInt64(words.count))] }
            let raw = rawWords.joined(separator: " ")
            let prefix = noise[Int(rng.next() % UInt64(noise.count))]
            let output = prefix + rawWords.shuffled(using: &rng).joined(separator: " ")

            let final = await CorrectionPipeline.execute(
                rawTranscript: VoiceFixtures.rawTranscript(raw),
                corrector: StubCorrector(behavior: .returns(output)),
                policy: CorrectionPolicy(),
                vocabulary: VocabularySnapshot(),
                deadline: Date().addingTimeInterval(5),
                privacyRoute: .onDeviceOnly,
                sessionID: VoiceSessionID(),
                generation: SessionGeneration(rawValue: 1)
            )

            let sanitized = CorrectionOutputSanitizer.sanitize(output)
            XCTAssertTrue(
                final.text == raw || final.text == sanitized || final.text == output,
                "Delivered text was neither raw nor the candidate.\n  raw: \(raw)\n  out: \(final.text)"
            )
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 4. Verbatim policy is honoured all the way through
    // ═══════════════════════════════════════════════════════════════

    /// Verbatim is the one mode where a "helpful" correction is a bug. The policy must
    /// reach the model as an instruction *and* be enforced after it answers.
    func testVerbatimPolicyReachesThePromptAndIsEnforced() async {
        let policy = CorrectionPolicy(
            tone: .exact,
            allowDisfluencyRemoval: false,
            allowFalseStartRemoval: false,
            allowSpokenPunctuation: false,
            allowNumberFormatting: false
        )

        let prompt = CorrectionPromptBuilder.systemPrompt(policy: policy)
        XCTAssertTrue(prompt.uppercased().contains("VERBATIM"),
            "Verbatim policy must be stated in the prompt, not just checked afterwards")

        // And a model that rewrites anyway is caught.
        let raw = "um so I like coffee"
        let corrector = StubCorrector(behavior: .returns("I like coffee."))
        let final = await CorrectionPipeline.execute(
            rawTranscript: VoiceFixtures.rawTranscript(raw),
            corrector: corrector,
            policy: policy,
            vocabulary: VocabularySnapshot(),
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .onDeviceOnly,
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1)
        )
        XCTAssertEqual(final.text, raw, "Verbatim mode must not accept a rewritten transcript")
    }

    /// Protected spans must be named in the prompt, not merely checked after the fact.
    func testProtectedSpansAreNamedInThePrompt() {
        let text = "run kubectl apply --no-verify against v2.1.0"
        let spans = ProtectedSpanExtractor.extract(from: text)
        XCTAssertFalse(spans.isEmpty)

        let prompt = CorrectionPromptBuilder.systemPrompt(
            policy: CorrectionPolicy(),
            protectedSpans: spans
        )
        for span in spans {
            XCTAssertTrue(
                prompt.contains(span.canonicalForm),
                "Protected span \(span.canonicalForm) missing from the prompt"
            )
        }
    }

    /// A pathological transcript must not produce an unbounded prompt.
    func testPromptIsBoundedForPathologicalInput() {
        let text = (0..<500).map { "v1.0.\($0)" }.joined(separator: " ")
        let spans = ProtectedSpanExtractor.extract(from: text)
        XCTAssertGreaterThan(spans.count, 40)

        let prompt = CorrectionPromptBuilder.systemPrompt(
            policy: CorrectionPolicy(),
            protectedSpans: spans
        )
        XCTAssertLessThan(prompt.count, 4000, "Prompt grew without bound: \(prompt.count) chars")
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 5. Reducer: exhaustive event × phase sweep
    // ═══════════════════════════════════════════════════════════════

    /// Every event applied in every phase. The reducer must either transition or refuse —
    /// never crash, never leave a terminal phase, never emit commands after terminating.
    func testEveryEventInEveryPhaseIsSafe() {
        let artifact = VoiceFixtures.audioArtifact()
        let raw = VoiceFixtures.rawTranscript("hello")
        let finalTranscript = FinalTranscript(
            text: "Hello.", rawTranscript: raw,
            correctionCandidate: nil, validationOutcome: .notApplicable
        )
        let receipt = DeliveryReceipt(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            targetLease: TargetLease(bundleIdentifier: "x", processIdentifier: 1),
            deliveredTextLength: 6,
            evidenceQuality: .settledUnverifiedPaste,
            deliveredAt: Date(),
            latencyMs: 1
        )

        let events: [VoiceSessionEvent] = [
            .startCapture(mode: .hold), .startCapture(mode: .handsFree), .lockInHandsFree,
            .liveSegmentReceived(SpeechSegment(segmentID: "l0", text: "hi", finality: .volatile)),
            .liveSegmentReceived(SpeechSegment(segmentID: "l0", text: "Hi.", finality: .final)),
            .stopCapture, .audioFinalized(artifact),
            .speechSegmentReceived(SpeechSegment(segmentID: "s0", text: "hi", finality: .final)),
            .speechCompleted(SpeechCompletion(rawTranscript: raw, finalSegmentCount: 1, totalDurationSeconds: 1)),
            .rawValidationPassed(raw),
            .correctionCandidateReceived(CorrectionCandidate(text: "Hello.", providerID: "t", modelVersion: "1")),
            .correctionValidationPassed(finalTranscript),
            .correctionValidationFailedFallbackRaw(finalTranscript),
            .deliveryCompleted(receipt),
            .targetLeaseInvalidated(reason: "test"),
            .deliveryIntercepted(command: "rewrite this"),
            .cancel,
            .failureOccurred(VoiceFailure(stage: .recognition, code: .requestTimeout)),
        ]

        let phases: [SessionPhase] = [
            .preparing, .capturing(mode: .hold), .capturing(mode: .handsFree),
            .finalizingAudio, .recognizing, .validatingRaw, .correcting,
            .validatingCorrection, .readyForDelivery, .delivering,
            .completed(.inserted(receipt)),
            .failed(VoiceFailure(stage: .recognition, code: .requestTimeout)),
            .cancelled,
        ]

        let generation = SessionGeneration(rawValue: 1)

        for phase in phases {
            for event in events {
                var state = VoiceSessionState(
                    snapshot: VoiceFixtures.snapshot(generation: 1),
                    phase: phase
                )
                let result = VoiceSessionReducer.reduce(
                    state: &state, event: event, eventGeneration: generation
                )

                if Self.isTerminal(phase) {
                    XCTAssertEqual(state.phase, phase,
                        "Terminal phase \(phase) was reopened by \(event)")
                    if case .success = result {
                        XCTFail("Terminal phase \(phase) accepted \(event)")
                    }
                }
            }
        }
    }

    /// Stale generations are the defence against a previous dictation's callbacks landing
    /// on the current one. No event from an old generation may change state.
    func testStaleGenerationCanNeverMutateState() {
        let current = SessionGeneration(rawValue: 7)
        var rng = SplitMix64(seed: 99)

        for _ in 0..<500 {
            var state = VoiceSessionState(
                snapshot: VoiceFixtures.snapshot(generation: current.rawValue),
                phase: .capturing(mode: .hold)
            )
            let before = state

            let staleValue = rng.next() % 7   // strictly less than current
            let result = VoiceSessionReducer.reduce(
                state: &state,
                event: .stopCapture,
                eventGeneration: SessionGeneration(rawValue: staleValue)
            )

            XCTAssertEqual(state.phase, before.phase, "Stale generation mutated the phase")
            if case .success = result {
                XCTFail("Stale generation \(staleValue) was accepted against \(current.rawValue)")
            }
        }
    }

    /// Live segments are the high-frequency path — many per second, revised out of order.
    /// Older revisions of a segment must never overwrite newer ones.
    func testOutOfOrderLiveRevisionsAreIgnored() {
        var state = VoiceSessionState(
            snapshot: VoiceFixtures.snapshot(generation: 1),
            phase: .capturing(mode: .handsFree)
        )
        let generation = SessionGeneration(rawValue: 1)

        _ = VoiceSessionReducer.reduce(
            state: &state,
            event: .liveSegmentReceived(SpeechSegment(segmentID: "l0", revision: 5, text: "newest", finality: .volatile)),
            eventGeneration: generation
        )
        _ = VoiceSessionReducer.reduce(
            state: &state,
            event: .liveSegmentReceived(SpeechSegment(segmentID: "l0", revision: 2, text: "older", finality: .volatile)),
            eventGeneration: generation
        )

        XCTAssertEqual(state.segments.first?.text, "newest",
            "An older revision overwrote a newer one")
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 6. Snapshot factory invariants
    // ═══════════════════════════════════════════════════════════════

    /// A session's providers must always be permitted by its own route. If the factory can
    /// ever emit an inconsistent snapshot, the registries are the only thing standing
    /// between the user and an unwanted upload.
    func testFactoryNeverEmitsAProviderWiderThanItsRoute() {
        let originalEngine = VoicePreferences.transcriptionEngine
        defer { VoicePreferences.transcriptionEngine = originalEngine }

        for engine in TranscriptionEngine.allCases {
            VoicePreferences.transcriptionEngine = engine
            let snapshot = VoiceSessionSnapshotFactory.make(
                bundleIdentifier: "com.test",
                processIdentifier: 1,
                generation: SessionGeneration(rawValue: 1)
            )

            XCTAssertTrue(
                snapshot.privacyRoute.permits(snapshot.speechProvider.privacyRoute),
                "\(engine): speech provider route \(snapshot.speechProvider.privacyRoute) exceeds session route \(snapshot.privacyRoute)"
            )
            XCTAssertTrue(
                snapshot.privacyRoute.permits(snapshot.correctionProvider.privacyRoute),
                "\(engine): correction provider route exceeds session route"
            )
            XCTAssertGreaterThan(snapshot.timeoutSeconds, 0)
        }
    }

    /// Verbatim mode must disable every rewriting permission, whatever the tone.
    func testVerbatimPreferenceDisablesAllRewrites() {
        let original = VoicePreferences.isVerbatimModeEnabled
        defer { VoicePreferences.isVerbatimModeEnabled = original }

        VoicePreferences.isVerbatimModeEnabled = true
        for tone in ToneCategory.allCases {
            let policy = VoiceSessionSnapshotFactory.correctionPolicy(tone: tone)
            XCTAssertEqual(policy.tone, .exact, "\(tone) did not map to exact under verbatim")
            XCTAssertFalse(policy.allowDisfluencyRemoval)
            XCTAssertFalse(policy.allowFalseStartRemoval)
            XCTAssertFalse(policy.allowSpokenPunctuation)
            XCTAssertFalse(policy.allowNumberFormatting)
            XCTAssertTrue(policy.preserveProtectedSpans, "Spans stay protected even verbatim")
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 7. Recovery store retention
    // ═══════════════════════════════════════════════════════════════

    /// Every dictation writes a directory containing audio. Without retention the store
    /// grows without bound, so pruning is a correctness property, not housekeeping.
    func testPruneRemovesDeliveredSessionsAndBoundsTheStore() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceRecovery_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let now = Date()
        let service = VoiceRecoveryService()

        // 3 delivered and old, 2 delivered and fresh, 3 undelivered and old.
        try writeSession(in: base, age: 30 * 86400, delivered: true, now: now)
        try writeSession(in: base, age: 20 * 86400, delivered: true, now: now)
        try writeSession(in: base, age: 10 * 86400, delivered: true, now: now)
        try writeSession(in: base, age: 1 * 3600, delivered: true, now: now)
        try writeSession(in: base, age: 2 * 3600, delivered: true, now: now)
        for age in [40, 41, 42] {
            try writeSession(in: base, age: Double(age) * 86400, delivered: false, now: now)
        }

        XCTAssertEqual(service.scanRecoverableSessions(baseDirectory: base).count, 8)

        let removed = service.prune(
            olderThan: 7 * 86400, keepingAtMost: 50, baseDirectory: base, now: now
        )
        XCTAssertEqual(removed, 3, "Only the three old delivered sessions should go")

        let remaining = service.scanRecoverableSessions(baseDirectory: base)
        XCTAssertEqual(remaining.count, 5)
        XCTAssertEqual(
            remaining.filter { !$0.isDelivered }.count, 3,
            "Undelivered sessions are the only copy of the user's words and must survive age-based pruning"
        )
    }

    func testPruneEnforcesTheHardCap() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceRecoveryCap_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let now = Date()
        for index in 0..<30 {
            try writeSession(in: base, age: Double(index) * 60, delivered: false, now: now)
        }

        let service = VoiceRecoveryService()
        _ = service.prune(olderThan: 365 * 86400, keepingAtMost: 10, baseDirectory: base, now: now)

        XCTAssertEqual(service.scanRecoverableSessions(baseDirectory: base).count, 10,
            "Even undelivered sessions are bounded")
    }

    func testRecoverableUndeliveredIgnoresEmptyAndDeliveredSessions() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceRecoveryPick_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let now = Date()
        try writeSession(in: base, age: 60, delivered: true, now: now, text: "delivered text")
        try writeSession(in: base, age: 60, delivered: false, now: now, text: "")
        try writeSession(in: base, age: 60, delivered: false, now: now, text: "  \n ")
        try writeSession(in: base, age: 60, delivered: false, now: now, text: "real recovered words")

        let service = VoiceRecoveryService()
        let recoverable = service.recoverableUndelivered(baseDirectory: base)

        XCTAssertEqual(recoverable.count, 1)
        XCTAssertEqual(VoiceRecoveryService.recoveredText(recoverable[0]), "real recovered words")
    }

    /// A corrupt or partially-written session directory must be skipped, not crash the scan.
    func testScanSurvivesCorruptSessionDirectories() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceRecoveryCorrupt_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // No manifest at all.
        let empty = base.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        // Manifest that is not JSON.
        let garbage = base.appendingPathComponent("garbage")
        try FileManager.default.createDirectory(at: garbage, withIntermediateDirectories: true)
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: garbage.appendingPathComponent("manifest.json"))

        // Manifest that is JSON but not a snapshot.
        let wrong = base.appendingPathComponent("wrong")
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
        try Data("{\"unexpected\":true}".utf8).write(to: wrong.appendingPathComponent("manifest.json"))

        // One good session so we know the scan still works.
        try writeSession(in: base, age: 60, delivered: false, now: Date(), text: "survivor")

        let recovered = VoiceRecoveryService().scanRecoverableSessions(baseDirectory: base)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(VoiceRecoveryService.recoveredText(recovered[0]), "survivor")
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - 8. Concurrency
    // ═══════════════════════════════════════════════════════════════

    /// Registries are actors reached from the session actor and from Preferences. Concurrent
    /// registration and resolution must not deadlock or hand back a route-violating provider.
    func testConcurrentRegistryAccessIsSafe() async {
        let registry = SpeechProviderRegistry(providers: [
            StubSpeechRecognizer(id: "apple.speech.legacy", privacyRoute: .onDeviceOnly)
        ])

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    await registry.register(StubSpeechRecognizer(id: "stub.\(index)"))
                }
                group.addTask {
                    let resolved = await registry.resolveActiveRecognizer(
                        preferredID: "stub.\(index)",
                        privacyRoute: .onDeviceOnly
                    )
                    XCTAssertEqual(resolved.descriptor.privacyRoute, .onDeviceOnly)
                }
            }
        }

        let all = await registry.availableProviders(for: .cloudPermitted)
        XCTAssertGreaterThanOrEqual(all.count, 32)
    }

    /// The reducer is a pure function over `inout` state, so many sessions can be reduced
    /// at once. Each must be independent.
    func testConcurrentReducerSessionsDoNotInterfere() {
        DispatchQueue.concurrentPerform(iterations: 64) { iteration in
            let generation = SessionGeneration(rawValue: UInt64(iteration + 1))
            var state = VoiceSessionState(
                snapshot: VoiceFixtures.snapshot(generation: UInt64(iteration + 1)),
                phase: .preparing
            )

            _ = VoiceSessionReducer.reduce(state: &state, event: .startCapture(mode: .handsFree), eventGeneration: generation)
            _ = VoiceSessionReducer.reduce(state: &state, event: .stopCapture, eventGeneration: generation)
            _ = VoiceSessionReducer.reduce(state: &state, event: .audioFinalized(VoiceFixtures.audioArtifact()), eventGeneration: generation)

            XCTAssertEqual(state.phase, .recognizing,
                "Session \(iteration) ended in \(state.phase)")
            XCTAssertEqual(state.snapshot.generation, generation)
        }
    }

    // MARK: - Helpers

    private static func isTerminal(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    private func writeSession(
        in base: URL,
        age: TimeInterval,
        delivered: Bool,
        now: Date,
        text: String = "some transcript"
    ) throws {
        let sessionID = VoiceSessionID()
        let dir = base.appendingPathComponent(sessionID.rawValue.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let snapshot = VoiceSessionSnapshot(
            sessionID: sessionID,
            generation: SessionGeneration(rawValue: 1),
            createdAt: now.addingTimeInterval(-age),
            speechProvider: SpeechProviderDescriptor(
                id: "t", displayName: "t", modelVersion: "1",
                privacyRoute: .onDeviceOnly, supportsStreaming: true, supportsContextualStrings: false
            ),
            correctionProvider: CorrectionProviderDescriptor(
                id: "t", displayName: "t", modelVersion: "1",
                privacyRoute: .onDeviceOnly, supportsStructuredOutput: false
            ),
            privacyRoute: .onDeviceOnly,
            targetLease: TargetLease(bundleIdentifier: "com.test", processIdentifier: 1)
        )
        try JSONEncoder().encode(snapshot).write(to: dir.appendingPathComponent("manifest.json"))

        let raw = RawTranscript(text: text, localeIdentifier: "en_US", providerID: "t", modelVersion: "1")
        try JSONEncoder().encode(raw).write(to: dir.appendingPathComponent("raw-transcript.json"))

        if delivered {
            let receipt = DeliveryReceipt(
                sessionID: sessionID,
                generation: SessionGeneration(rawValue: 1),
                targetLease: snapshot.targetLease,
                deliveredTextLength: text.count,
                evidenceQuality: .settledUnverifiedPaste,
                deliveredAt: now.addingTimeInterval(-age),
                latencyMs: 1
            )
            try JSONEncoder().encode(receipt).write(to: dir.appendingPathComponent("delivery-receipt.json"))
        }
    }
}
