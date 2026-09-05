import Foundation
import XCTest
@testable import ExpanderEngine

final class AppleSpeechAnalyzerAdapterTests: XCTestCase {
    func testProbeMapsAuthorizationAndEveryAssetStateWithoutStartingWork() async {
        let authorization = LockedValue(SpeechAuthorization.Status.denied)
        let assets = LockedValue(AppleSpeechAnalyzerRuntime.AssetState.installed)
        let probes = LockedCounter()
        let transcriptions = LockedCounter()
        let installations = LockedCounter()
        let runtime = AppleSpeechAnalyzerRuntime(
            isPlatformSupported: { true },
            assetState: { _ in
                probes.increment()
                return assets.value
            },
            transcribe: { _, _ in transcriptions.increment() },
            installAssets: { _ in installations.increment() }
        )
        let adapter = AppleSpeechAnalyzerAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { authorization.value },
            runtime: runtime
        )

        let deniedReadiness = await adapter.probe()
        XCTAssertEqual(deniedReadiness, .requiresPermission(.speechRecognition))
        XCTAssertEqual(probes.value, 0, "Authorization failure should not touch SpeechAnalyzer assets")

        authorization.value = .authorized
        let mappings: [(AppleSpeechAnalyzerRuntime.AssetState, ProviderReadiness)] = [
            (.unavailable, .temporarilyUnavailable(retryAfterSeconds: 2, reason: .endpointUnreachable)),
            (.unsupported, .unsupported(reason: .modelNotFound)),
            (.downloadable, .requiresConfiguration(.missingModelDownload)),
            (.downloading(progress: 0.4), .downloading(progress: 0.4)),
        ]
        for (state, expected) in mappings {
            assets.value = state
            let readiness = await adapter.probe()
            XCTAssertEqual(readiness, expected, "state=\(state)")
        }

        assets.value = .installed
        guard case .ready(let evidence) = await adapter.probe() else {
            return XCTFail("Installed assets must make the analyzer ready")
        }
        XCTAssertEqual(evidence.providerID, adapter.descriptor.id)
        XCTAssertEqual(evidence.modelVersion, adapter.descriptor.modelVersion)
        XCTAssertTrue(evidence.capabilities.contains("volatileRevisions"))
        XCTAssertTrue(evidence.capabilities.contains("offline"))
        XCTAssertEqual(transcriptions.value, 0, "Probe must not analyze audio")
        XCTAssertEqual(installations.value, 0, "Probe must not install or download assets")
    }

    func testProbeReportsUnsupportedPlatformBeforeAuthorizationOrAssetInspection() async {
        let probes = LockedCounter()
        let runtime = AppleSpeechAnalyzerRuntime(
            isPlatformSupported: { false },
            assetState: { _ in probes.increment(); return .installed },
            transcribe: { _, _ in },
            installAssets: { _ in }
        )
        let adapter = AppleSpeechAnalyzerAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .denied },
            runtime: runtime
        )

        let readiness = await adapter.probe()
        XCTAssertEqual(readiness, .unsupported(reason: .modelNotFound))
        XCTAssertEqual(probes.value, 0)
    }

    /// `isPlatformSupported()` is false for two unrelated reasons, and the copy the user
    /// sees has to name the right one. A Mac below macOS 26 is blocked by its OS whatever
    /// toolchain built the binary; only a Mac that could run the analyzer, running a build
    /// compiled without it, should be pointed at a newer download.
    ///
    /// Keying that off the compiler alone — as the first cut of this did — makes the macOS 14
    /// CI job disagree with the macOS 26 one about the very same input, which is how the test
    /// above starts failing on one runner only.
    func testPlatformUnsupportedReasonBlamesTheOSBeforeTheBuild() {
        XCTAssertEqual(
            AppleSpeechAnalyzerAdapter.platformUnsupportedReason(builtWithSpeechAnalyzer: false, isCompatibleOS: false),
            .modelNotFound,
            "A Mac below macOS 26 gains nothing from a newer DMG."
        )
        XCTAssertEqual(
            AppleSpeechAnalyzerAdapter.platformUnsupportedReason(builtWithSpeechAnalyzer: true, isCompatibleOS: false),
            .modelNotFound
        )
        XCTAssertEqual(
            AppleSpeechAnalyzerAdapter.platformUnsupportedReason(builtWithSpeechAnalyzer: false, isCompatibleOS: true),
            .buildLacksSpeechAnalyzer
        )
        XCTAssertEqual(
            AppleSpeechAnalyzerAdapter.platformUnsupportedReason(builtWithSpeechAnalyzer: true, isCompatibleOS: true),
            .modelNotFound
        )
    }

    /// The flag has to track the toolchain, not the host: it is the one input above that a
    /// released binary carries with it.
    func testBuiltWithSpeechAnalyzerTracksTheToolchain() {
        #if compiler(>=6.0)
        XCTAssertTrue(AppleSpeechAnalyzerAdapter.isBuiltWithSpeechAnalyzer)
        #else
        XCTAssertFalse(AppleSpeechAnalyzerAdapter.isBuiltWithSpeechAnalyzer)
        #endif
    }

    func testExplicitAssetInstallationIsTheOnlyDownloadPathAndReprobesInstalled() async throws {
        let assets = LockedValue(AppleSpeechAnalyzerRuntime.AssetState.downloadable)
        let installations = LockedCounter()
        let runtime = AppleSpeechAnalyzerRuntime(
            isPlatformSupported: { true },
            assetState: { _ in assets.value },
            transcribe: { _, _ in },
            installAssets: { _ in
                installations.increment()
                assets.value = .installed
            }
        )
        let adapter = AppleSpeechAnalyzerAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .authorized },
            runtime: runtime
        )

        let before = await adapter.probe()
        XCTAssertEqual(before, .requiresConfiguration(.missingModelDownload))
        XCTAssertEqual(installations.value, 0)
        let readiness = try await adapter.installAssets(
            for: Locale(identifier: "en-US"),
            deadline: Date().addingTimeInterval(1)
        )

        XCTAssertEqual(installations.value, 1)
        XCTAssertTrue(readiness.isReady)
    }

    func testAssetInstallationDeadlineReturnsPromptlyAndCancelsDownloadWork() async {
        let cancellations = LockedCounter()
        let runtime = AppleSpeechAnalyzerRuntime(
            isPlatformSupported: { true },
            assetState: { _ in .downloadable },
            transcribe: { _, _ in },
            installAssets: { _ in
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch is CancellationError {
                    cancellations.increment()
                    throw CancellationError()
                }
            }
        )
        let adapter = readyAdapter(runtime: runtime)
        let start = Date()
        var observed: VoiceFailure?
        do {
            _ = try await adapter.installAssets(
                for: Locale(identifier: "en-US"),
                deadline: Date().addingTimeInterval(0.05)
            )
            XCTFail("Expected the bounded installation to time out")
        } catch let failure as VoiceFailure {
            observed = failure
        } catch {
            XCTFail("Expected VoiceFailure, got \(error)")
        }

        XCTAssertEqual(observed?.code, .requestTimeout)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        await eventually { cancellations.value == 1 }
    }

    func testAssetInstallationCallerCancellationCancelsDownloadWork() async {
        let starts = LockedCounter()
        let cancellations = LockedCounter()
        let runtime = AppleSpeechAnalyzerRuntime(
            isPlatformSupported: { true },
            assetState: { _ in .downloadable },
            transcribe: { _, _ in },
            installAssets: { _ in
                starts.increment()
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch is CancellationError {
                    cancellations.increment()
                    throw CancellationError()
                }
            }
        )
        let adapter = readyAdapter(runtime: runtime)
        let installation = Task {
            try await adapter.installAssets(
                for: Locale(identifier: "en-US"),
                deadline: Date().addingTimeInterval(30)
            )
        }
        await eventually { starts.value == 1 }

        installation.cancel()

        do {
            _ = try await installation.value
            XCTFail("Expected caller cancellation to terminate installation")
        } catch is CancellationError {
            // Expected cooperative cancellation.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        await eventually { cancellations.value == 1 }
    }

    func testAssetInstallationDeadlineAlsoBoundsHangingPostInstallInspection() async {
        let inspections = LockedCounter()
        let postInspectionCancellations = LockedCounter()
        let runtime = AppleSpeechAnalyzerRuntime(
            isPlatformSupported: { true },
            assetState: { _ in
                inspections.increment()
                guard inspections.value > 1 else { return .downloadable }
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch is CancellationError {
                    postInspectionCancellations.increment()
                } catch {}
                return .downloading(progress: nil)
            },
            transcribe: { _, _ in },
            installAssets: { _ in }
        )
        let adapter = readyAdapter(runtime: runtime)
        let start = Date()
        var observed: VoiceFailure?

        do {
            _ = try await adapter.installAssets(
                for: Locale(identifier: "en-US"),
                deadline: Date().addingTimeInterval(0.05)
            )
            XCTFail("Expected the post-install inspection to share the installation deadline")
        } catch let failure as VoiceFailure {
            observed = failure
        } catch {
            XCTFail("Expected VoiceFailure, got \(error)")
        }

        XCTAssertEqual(observed?.code, .requestTimeout)
        XCTAssertEqual(inspections.value, 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        await eventually { postInspectionCancellations.value == 1 }
    }

    func testSystemContextualTermsAreNormalizedAndCappedAtAppleLimit() {
        let terms = ["", "  first  "] + (0..<150).map { "term-\($0)" }
        let contextual = AppleSpeechAnalyzerRuntime.contextualTerms(from: terms)

        XCTAssertEqual(contextual.count, 100)
        XCTAssertEqual(contextual.first, "first")
        XCTAssertFalse(contextual.contains(where: { $0.isEmpty }))
    }

    func testTranscriptionEmitsStableVolatileRevisionsAndTruthfulCompletionProvenance() async throws {
        let runtime = installedRuntime { request, emit in
            XCTAssertEqual(request.vocabulary.terms.count, 105, "The adapter boundary receives the immutable request")
            emit(.init(
                startSeconds: 0,
                durationSeconds: 0.8,
                text: "hello",
                alternatives: [SpeechAlternative(text: "hullo", confidence: nil)],
                confidence: 0.7,
                isFinal: false
            ))
            emit(.init(
                startSeconds: 0,
                durationSeconds: 1.1,
                text: "hello world",
                confidence: 0.8,
                isFinal: false
            ))
            emit(.init(
                startSeconds: 0,
                durationSeconds: 1.1,
                text: "hello world",
                confidence: 0.9,
                isFinal: true
            ))
            emit(.init(
                startSeconds: 1.2,
                durationSeconds: 0.5,
                text: "again",
                isFinal: true
            ))
        }
        let adapter = readyAdapter(runtime: runtime)
        let request = makeRequest(vocabulary: (0..<105).map { "term-\($0)" })

        var segments: [SpeechSegment] = []
        var completion: SpeechCompletion?
        for try await event in adapter.transcribe(request) {
            switch event {
            case .segment(let segment): segments.append(segment)
            case .completed(let value): completion = value
            case .metrics: break
            }
        }

        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(Array(segments.prefix(3).map(\.segmentID).uniqued()).count, 1)
        XCTAssertEqual(Array(segments.prefix(3).map(\.revision)), [1, 2, 3])
        XCTAssertEqual(Array(segments.prefix(3).map(\.finality)), [.volatile, .volatile, .final])
        XCTAssertNotEqual(segments[2].segmentID, segments[3].segmentID)
        XCTAssertEqual(segments[0].alternatives.map(\.text), ["hullo"])
        XCTAssertEqual(completion?.rawTranscript.text, "hello world again")
        XCTAssertEqual(completion?.rawTranscript.providerID, adapter.descriptor.id)
        XCTAssertEqual(completion?.rawTranscript.modelVersion, adapter.descriptor.modelVersion)
        XCTAssertEqual(completion?.rawTranscript.localeIdentifier, request.locale.identifier)
        XCTAssertEqual(completion?.rawTranscript.audioSHA256, "audio-digest")
        XCTAssertEqual(completion?.finalSegmentCount, 2)
        XCTAssertEqual(completion?.totalDurationSeconds, 1.75)
    }

    func testTranscriptAssemblyDoesNotInsertASpaceBetweenCJKChunks() async throws {
        let runtime = installedRuntime { _, emit in
            emit(.init(startSeconds: 0, durationSeconds: 0.4, text: "私", isFinal: true))
            emit(.init(startSeconds: 1, durationSeconds: 0.4, text: "は", isFinal: true))
        }
        let adapter = readyAdapter(runtime: runtime)

        let completion = try await completion(
            from: adapter.transcribe(makeRequest(locale: Locale(identifier: "ja-JP")))
        )

        XCTAssertEqual(completion?.rawTranscript.text, "私は")
    }

    func testTranscriptAssemblyDoesNotInsertASpaceBeforePunctuation() async throws {
        let runtime = installedRuntime { _, emit in
            emit(.init(startSeconds: 0, durationSeconds: 0.4, text: "hello", isFinal: true))
            emit(.init(startSeconds: 1, durationSeconds: 0.4, text: ", world", isFinal: true))
        }
        let adapter = readyAdapter(runtime: runtime)

        let completion = try await completion(from: adapter.transcribe(makeRequest()))

        XCTAssertEqual(completion?.rawTranscript.text, "hello, world")
    }

    func testTranscriptAssemblyPreservesExplicitFrameworkWhitespace() async throws {
        let runtime = installedRuntime { _, emit in
            emit(.init(startSeconds: 0, durationSeconds: 0.4, text: "hello  ", isFinal: true))
            emit(.init(startSeconds: 1, durationSeconds: 0.4, text: "world", isFinal: true))
        }
        let adapter = readyAdapter(runtime: runtime)

        let completion = try await completion(from: adapter.transcribe(makeRequest()))

        XCTAssertEqual(completion?.rawTranscript.text, "hello  world")
    }

    func testTranscriptAssemblyAddsLocaleAwareFallbackBetweenLatinWords() async throws {
        let runtime = installedRuntime { _, emit in
            emit(.init(startSeconds: 0, durationSeconds: 0.4, text: "hello", isFinal: true))
            emit(.init(startSeconds: 1, durationSeconds: 0.4, text: "world", isFinal: true))
        }
        let adapter = readyAdapter(runtime: runtime)

        let completion = try await completion(from: adapter.transcribe(makeRequest()))

        XCTAssertEqual(completion?.rawTranscript.text, "hello world")
    }

    func testEmptyVolatileResultRetractsPriorTextForTheSameRange() async throws {
        let runtime = installedRuntime { _, emit in
            emit(.init(startSeconds: 0, durationSeconds: 0.8, text: "withdrawn guess", isFinal: false))
            emit(.init(startSeconds: 0, durationSeconds: 0.8, text: "", isFinal: false))
            emit(.init(startSeconds: 0, durationSeconds: 0.8, text: "", isFinal: false))
            emit(.init(startSeconds: 1, durationSeconds: 0.6, text: "kept phrase", isFinal: true))
        }
        let adapter = readyAdapter(runtime: runtime)

        var segments: [SpeechSegment] = []
        var completion: SpeechCompletion?
        for try await event in adapter.transcribe(makeRequest()) {
            switch event {
            case .segment(let segment): segments.append(segment)
            case .completed(let value): completion = value
            case .metrics: break
            }
        }

        XCTAssertEqual(segments.map(\.text), ["withdrawn guess", "", "kept phrase"])
        let original = try XCTUnwrap(segments.first { $0.text == "withdrawn guess" })
        let retraction = try XCTUnwrap(segments.first { $0.text.isEmpty })
        XCTAssertEqual(original.segmentID, retraction.segmentID)
        XCTAssertGreaterThan(retraction.revision, original.revision)
        XCTAssertEqual(retraction.finality, .volatile)
        XCTAssertEqual(completion?.rawTranscript.text, "kept phrase")
        XCTAssertEqual(completion?.finalSegmentCount, 1)

        var reducerState = VoiceSessionState(
            snapshot: VoiceFixtures.snapshot(
                speechProviderID: adapter.descriptor.id,
                correctionProviderID: "deterministic.none"
            ),
            phase: .recognizing
        )
        for segment in segments {
            _ = try VoiceSessionReducer.reduce(
                state: &reducerState,
                event: .speechSegmentReceived(segment),
                eventGeneration: reducerState.snapshot.generation
            ).get()
        }
        _ = try VoiceSessionReducer.reduce(
            state: &reducerState,
            event: .speechCompleted(try XCTUnwrap(completion)),
            eventGeneration: reducerState.snapshot.generation
        ).get()
        XCTAssertEqual(reducerState.segments.first?.text, "")
        XCTAssertEqual(
            reducerState.rawTranscript?.text,
            "kept phrase",
            "Completion reconciliation must not resurrect the higher-revision retraction."
        )
    }

    func testEmptyResultDoesNotRetractFinalizedOrMerelyOverlappingRanges() async throws {
        let runtime = installedRuntime { _, emit in
            emit(.init(startSeconds: 0, durationSeconds: 0.8, text: "settled", isFinal: true))
            emit(.init(startSeconds: 0, durationSeconds: 0.8, text: "", isFinal: false))

            emit(.init(startSeconds: 2, durationSeconds: 2, text: "evolving", isFinal: false))
            emit(.init(startSeconds: 2.5, durationSeconds: 2, text: "", isFinal: false))
            emit(.init(startSeconds: 2, durationSeconds: 2, text: "evolving final", isFinal: true))
        }
        let adapter = readyAdapter(runtime: runtime)

        var segments: [SpeechSegment] = []
        var completion: SpeechCompletion?
        for try await event in adapter.transcribe(makeRequest()) {
            switch event {
            case .segment(let segment): segments.append(segment)
            case .completed(let value): completion = value
            case .metrics: break
            }
        }

        XCTAssertEqual(segments.map(\.text), ["settled", "evolving", "evolving final"])
        let evolving = try XCTUnwrap(segments.first { $0.text == "evolving" })
        let finalized = try XCTUnwrap(segments.first { $0.text == "evolving final" })
        XCTAssertEqual(evolving.segmentID, finalized.segmentID)
        XCTAssertEqual(completion?.rawTranscript.text, "settled evolving final")
        XCTAssertEqual(completion?.finalSegmentCount, 2)
    }

    func testRepeatedRevocationsReleaseTranscriptByteBudget() async throws {
        let largeVolatileResult = String(repeating: "x", count: 100_000)
        let runtime = installedRuntime { _, emit in
            // Twelve simultaneous results would exceed the 1 MiB transcript ceiling. Retracting
            // each before opening the next range must return its bytes to the bounded budget.
            for index in 0..<12 {
                let start = Double(index)
                emit(.init(
                    startSeconds: start,
                    durationSeconds: 0.5,
                    text: largeVolatileResult,
                    isFinal: false
                ))
                emit(.init(startSeconds: start, durationSeconds: 0.5, text: "", isFinal: false))
            }
            emit(.init(startSeconds: 20, durationSeconds: 0.5, text: "kept", isFinal: true))
        }
        let adapter = readyAdapter(runtime: runtime)

        let completion = try await completion(from: adapter.transcribe(makeRequest()))

        XCTAssertEqual(completion?.rawTranscript.text, "kept")
        XCTAssertEqual(completion?.finalSegmentCount, 1)
    }

    func testRepeatedRevocationsReleaseSegmentBudget() async throws {
        let runtime = installedRuntime { _, emit in
            // The accumulator permits 4,096 simultaneous segments. More than that many distinct
            // ranges may still pass through one session when every old range is first revoked.
            for index in 0..<4_100 {
                let start = Double(index)
                emit(.init(startSeconds: start, durationSeconds: 0.5, text: "guess", isFinal: false))
                emit(.init(startSeconds: start, durationSeconds: 0.5, text: "", isFinal: false))
            }
            emit(.init(startSeconds: 5_000, durationSeconds: 0.5, text: "kept", isFinal: true))
        }
        let adapter = readyAdapter(runtime: runtime)

        let completion = try await completion(from: adapter.transcribe(makeRequest()))

        XCTAssertEqual(completion?.rawTranscript.text, "kept")
        XCTAssertEqual(completion?.finalSegmentCount, 1)
    }

    func testEmptyArtifactFailsBeforeRuntimeAndNoResultsFailsAsNoSpeech() async {
        let starts = LockedCounter()
        let runtime = installedRuntime { _, _ in starts.increment() }
        let adapter = readyAdapter(runtime: runtime)

        let empty = makeRequest(frameCount: 0, duration: 0, byteCount: 0)
        let emptyFailure = await failure(from: adapter.transcribe(empty))
        XCTAssertEqual(emptyFailure?.code, .speechNoSpeech)
        XCTAssertEqual(starts.value, 0)

        let noResultFailure = await failure(from: adapter.transcribe(makeRequest()))
        XCTAssertEqual(noResultFailure?.code, .speechNoSpeech)
        XCTAssertEqual(starts.value, 1)
    }

    func testAudioReadFailureIsRedactedAndTyped() async {
        let runtime = installedRuntime { _, _ in
            throw AppleSpeechAnalyzerRuntime.RuntimeError.audioUnreadable
        }
        let adapter = readyAdapter(runtime: runtime)

        let failure = await failure(from: adapter.transcribe(makeRequest()))

        XCTAssertEqual(failure?.code, .audioEncodingFailed)
        XCTAssertEqual(failure?.artifactState, .durable)
        XCTAssertFalse(failure?.redactedDetail?.contains("/") == true)
    }

    func testTranscribeRechecksAuthorizationAndInstalledAssetsAfterProbe() async {
        let authorization = LockedValue(SpeechAuthorization.Status.authorized)
        let assets = LockedValue(AppleSpeechAnalyzerRuntime.AssetState.installed)
        let inspectionStarted = LockedCounter()
        let inspectionLatch = AsyncLatch()
        let starts = LockedCounter()
        let runtime = AppleSpeechAnalyzerRuntime(
            isPlatformSupported: { true },
            assetState: { _ in
                inspectionStarted.increment()
                await inspectionLatch.wait()
                return assets.value
            },
            transcribe: { _, _ in starts.increment() },
            installAssets: { _ in }
        )
        let adapter = AppleSpeechAnalyzerAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { authorization.value },
            runtime: runtime
        )
        let task = Task { await self.failure(from: adapter.transcribe(self.makeRequest())) }
        await eventually { inspectionStarted.value == 1 }
        authorization.value = .denied
        await inspectionLatch.release()

        let permissionFailure = await task.value
        XCTAssertEqual(permissionFailure?.code, .speechRecognitionPermissionDenied)
        XCTAssertEqual(starts.value, 0)

        authorization.value = .authorized
        assets.value = .downloadable
        let freshInspectionLatch = AsyncLatch(released: true)
        let assetsRuntime = AppleSpeechAnalyzerRuntime(
            isPlatformSupported: { true },
            assetState: { _ in await freshInspectionLatch.wait(); return assets.value },
            transcribe: { _, _ in starts.increment() },
            installAssets: { _ in }
        )
        let assetsAdapter = AppleSpeechAnalyzerAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { authorization.value },
            runtime: assetsRuntime
        )
        let assetsFailure = await failure(from: assetsAdapter.transcribe(makeRequest()))
        XCTAssertEqual(assetsFailure?.code, .modelNotFound)
        XCTAssertEqual(assetsFailure?.userAction, .downloadModel)
        XCTAssertEqual(starts.value, 0)
    }

    func testRuntimeErrorAfterResultsPreservesRecognizedEvidence() async throws {
        let runtime = installedRuntime { _, emit in
            emit(.init(startSeconds: 0, durationSeconds: 0.5, text: "preserve me", isFinal: false))
            throw AppleSpeechAnalyzerRuntime.RuntimeError.unavailable
        }
        let adapter = readyAdapter(runtime: runtime)

        var segments: [SpeechSegment] = []
        var completion: SpeechCompletion?
        for try await event in adapter.transcribe(makeRequest()) {
            switch event {
            case .segment(let segment): segments.append(segment)
            case .completed(let value): completion = value
            case .metrics: break
            }
        }

        XCTAssertEqual(segments.map(\.finality), [.volatile, .final])
        XCTAssertEqual(segments.map(\.revision), [1, 2])
        XCTAssertEqual(completion?.rawTranscript.text, "preserve me")
        XCTAssertEqual(completion?.rawTranscript.providerID, adapter.descriptor.id)
    }

    func testOversizedRuntimeResultFailsClosedInsteadOfReportingTruncatedCompletion() async {
        let runtime = installedRuntime { _, emit in
            emit(.init(
                startSeconds: 0,
                durationSeconds: 1,
                text: String(repeating: "x", count: 140_000),
                isFinal: true
            ))
        }
        let adapter = readyAdapter(runtime: runtime)

        let failure = await failure(from: adapter.transcribe(makeRequest()))

        XCTAssertEqual(failure?.code, .speechProtocolViolation)
        XCTAssertEqual(failure?.artifactState, .durable)
    }

    func testOversizedAlternativeTextCannotBypassResultStorageBound() async {
        let runtime = installedRuntime { _, emit in
            emit(.init(
                startSeconds: 0,
                durationSeconds: 1,
                text: "bounded primary",
                alternatives: [
                    SpeechAlternative(text: String(repeating: "private-alt", count: 20_000))
                ],
                isFinal: true
            ))
        }
        let adapter = readyAdapter(runtime: runtime)

        let failure = await failure(from: adapter.transcribe(makeRequest()))

        XCTAssertEqual(failure?.code, .speechProtocolViolation)
        XCTAssertEqual(failure?.artifactState, .durable)
    }

    func testAggregateAlternativeTextCannotBypassSessionStorageBound() async {
        let runtime = installedRuntime { _, emit in
            for index in 0..<9 {
                emit(.init(
                    startSeconds: Double(index),
                    durationSeconds: 0.5,
                    text: "p\(index)",
                    alternatives: [
                        SpeechAlternative(text: String(repeating: "a", count: 120_000))
                    ],
                    isFinal: true
                ))
            }
        }
        let adapter = readyAdapter(runtime: runtime)

        let failure = await failure(from: adapter.transcribe(makeRequest()))

        XCTAssertEqual(failure?.code, .speechProtocolViolation)
        XCTAssertEqual(failure?.artifactState, .durable)
    }

    func testExcessiveSegmentCountFailsClosedAtBoundedAccumulatorLimit() async {
        let runtime = installedRuntime { _, emit in
            for index in 0...4_096 {
                emit(.init(
                    startSeconds: Double(index),
                    durationSeconds: 0.5,
                    text: "word-\(index)",
                    isFinal: true
                ))
            }
        }
        let adapter = readyAdapter(runtime: runtime)

        let failure = await failure(from: adapter.transcribe(makeRequest(deadline: Date().addingTimeInterval(60))))

        XCTAssertEqual(failure?.code, .speechProtocolViolation)
        XCTAssertEqual(failure?.artifactState, .durable)
    }

    func testDeadlineFailsPromptlyAndCancelsAnalyzerWork() async {
        let cancellations = LockedCounter()
        let runtime = installedRuntime { _, _ in
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch is CancellationError {
                cancellations.increment()
                throw CancellationError()
            }
        }
        let adapter = readyAdapter(runtime: runtime)
        let start = Date()
        let failure = await failure(from: adapter.transcribe(
            makeRequest(deadline: Date().addingTimeInterval(0.05))
        ))

        XCTAssertEqual(failure?.code, .requestTimeout)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        await eventually { cancellations.value == 1 }
    }

    func testCancelIsScopedToExactSessionAndDoesNotLeakLateResults() async throws {
        let gate = RuntimeGate()
        let runtime = installedRuntime { request, emit in
            await gate.markStarted(request.sessionID)
            do {
                while !(await gate.isReleased(request.sessionID)) {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                emit(.init(startSeconds: 0, durationSeconds: 1, text: request.sessionID.description, isFinal: true))
            } catch is CancellationError {
                await gate.markCancelled(request.sessionID)
                throw CancellationError()
            }
        }
        let adapter = readyAdapter(runtime: runtime)
        let firstID = VoiceSessionID()
        let secondID = VoiceSessionID()
        let firstTask = Task { await self.failure(from: adapter.transcribe(self.makeRequest(sessionID: firstID))) }
        let secondTask = Task { () throws -> SpeechCompletion? in
            var completion: SpeechCompletion?
            for try await event in adapter.transcribe(self.makeRequest(sessionID: secondID)) {
                if case .completed(let value) = event { completion = value }
            }
            return completion
        }
        await eventually { await gate.startedCount == 2 }

        await adapter.cancel(sessionID: firstID)
        await gate.release(secondID)

        let first = await firstTask.value
        XCTAssertNil(first, "Explicit cancellation is cooperative, not a provider failure")
        let second = try await secondTask.value
        XCTAssertEqual(second?.rawTranscript.text, secondID.description)
        let firstWasCancelled = await gate.wasCancelled(firstID)
        let secondWasCancelled = await gate.wasCancelled(secondID)
        XCTAssertTrue(firstWasCancelled)
        XCTAssertFalse(secondWasCancelled)
    }

    func testConsumerAbandonmentCancelsExactRuntimeSession() async {
        let cancellations = LockedCounter()
        let started = LockedCounter()
        let runtime = installedRuntime { _, emit in
            started.increment()
            emit(.init(startSeconds: 0, durationSeconds: 0.2, text: "preview", isFinal: false))
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch is CancellationError {
                cancellations.increment()
                throw CancellationError()
            }
        }
        let adapter = readyAdapter(runtime: runtime)
        let request = makeRequest()
        let consumer = Task {
            do {
                for try await _ in adapter.transcribe(request) { break }
            } catch {
                XCTFail("Breaking iteration should abandon cooperatively: \(error)")
            }
        }

        await consumer.value
        await eventually { started.value == 1 && cancellations.value == 1 }
    }

    func testRegistrySelectsReadyAnalyzerAndFallsBackToReadyLegacyWhenAnalyzerNeedsAssets() async {
        let analyzer = StubSpeechRecognizer(
            id: VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer,
            privacyRoute: .onDeviceOnly
        )
        let legacy = StubSpeechRecognizer(
            id: VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy,
            privacyRoute: .onDeviceOnly
        )
        let readyRegistry = SpeechProviderRegistry(providers: [analyzer, legacy])

        let readyResolution = await readyRegistry.resolveActiveRecognizer(
            preferredID: analyzer.descriptor.id,
            privacyRoute: .onDeviceOnly
        )
        XCTAssertEqual(readyResolution.recognizer?.descriptor.id, analyzer.descriptor.id)

        let downloadableAnalyzer = StubSpeechRecognizer(
            id: VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer,
            privacyRoute: .onDeviceOnly,
            readiness: .requiresConfiguration(.missingModelDownload)
        )
        let fallbackRegistry = SpeechProviderRegistry(providers: [downloadableAnalyzer, legacy])
        let fallbackResolution = await fallbackRegistry.resolveActiveRecognizer(
            preferredID: downloadableAnalyzer.descriptor.id,
            privacyRoute: .onDeviceOnly
        )
        XCTAssertEqual(fallbackResolution.recognizer?.descriptor.id, legacy.descriptor.id)
    }

    func testProductionRegistryContainsShippingAnalyzerAdapter() async {
        let registry = SpeechProviderRegistry()

        let provider = await registry.provider(
            for: VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer
        )

        XCTAssertTrue(provider is AppleSpeechAnalyzerAdapter)
        XCTAssertEqual(provider?.descriptor.modelVersion, "system")
        XCTAssertEqual(provider?.descriptor.privacyRoute, .onDeviceOnly)
        XCTAssertFalse(provider?.descriptor.supportsStreaming ?? true)
    }

    func testSnapshotRoutesAppleRecognitionByPlatformCapability() {
        let analyzer = VoiceSessionSnapshotFactory.speechProvider(
            for: .appleSpeech,
            route: .onDeviceOnly,
            supportsSpeechAnalyzer: true
        )
        XCTAssertEqual(analyzer.id, VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer)
        XCTAssertFalse(analyzer.supportsStreaming)

        let legacy = VoiceSessionSnapshotFactory.speechProvider(
            for: .appleSpeech,
            route: .onDeviceOnly,
            supportsSpeechAnalyzer: false
        )
        XCTAssertEqual(legacy.id, VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy)
        XCTAssertTrue(legacy.supportsStreaming)

        let localAnalyzer = VoiceSessionSnapshotFactory.speechProvider(
            for: .localLLM,
            route: .localNetworkOnly,
            supportsSpeechAnalyzer: true
        )
        XCTAssertEqual(localAnalyzer.id, VoiceSessionSnapshotFactory.ProviderID.appleSpeechAnalyzer)

        let localLegacy = VoiceSessionSnapshotFactory.speechProvider(
            for: .localLLM,
            route: .localNetworkOnly,
            supportsSpeechAnalyzer: false
        )
        XCTAssertEqual(localLegacy.id, VoiceSessionSnapshotFactory.ProviderID.appleSpeechLegacy)
    }

    private func installedRuntime(
        transcribe: @escaping @Sendable (
            SpeechRequest,
            @escaping @Sendable (AppleSpeechAnalyzerRuntime.Result) -> Void
        ) async throws -> Void
    ) -> AppleSpeechAnalyzerRuntime {
        AppleSpeechAnalyzerRuntime(
            isPlatformSupported: { true },
            assetState: { _ in .installed },
            transcribe: transcribe,
            installAssets: { _ in }
        )
    }

    private func readyAdapter(runtime: AppleSpeechAnalyzerRuntime) -> AppleSpeechAnalyzerAdapter {
        AppleSpeechAnalyzerAdapter(
            locale: Locale(identifier: "en-US"),
            authorizationStatus: { .authorized },
            runtime: runtime
        )
    }

    private func makeRequest(
        sessionID: VoiceSessionID = VoiceSessionID(),
        frameCount: Int64 = 28_000,
        duration: Double = 1.75,
        byteCount: Int64 = 56_000,
        locale: Locale = Locale(identifier: "en-US"),
        vocabulary: [String] = [],
        deadline: Date = Date().addingTimeInterval(30)
    ) -> SpeechRequest {
        SpeechRequest(
            sessionID: sessionID,
            generation: SessionGeneration(rawValue: 7),
            audio: AudioArtifact(
                fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("private-recording.caf"),
                format: "caf",
                sampleRate: 16_000,
                channelCount: 1,
                frameCount: frameCount,
                durationSeconds: duration,
                byteCount: byteCount,
                sha256Hex: "audio-digest",
                gapCount: 0
            ),
            locale: locale,
            vocabulary: VocabularySnapshot(terms: vocabulary),
            deadline: deadline,
            privacyRoute: .onDeviceOnly
        )
    }

    private func completion(
        from stream: AsyncThrowingStream<SpeechEvent, Error>
    ) async throws -> SpeechCompletion? {
        var completion: SpeechCompletion?
        for try await event in stream {
            if case .completed(let value) = event {
                completion = value
            }
        }
        return completion
    }

    private func failure(
        from stream: AsyncThrowingStream<SpeechEvent, Error>
    ) async -> VoiceFailure? {
        do {
            for try await _ in stream {}
            return nil
        } catch is CancellationError {
            return nil
        } catch let failure as VoiceFailure {
            return failure
        } catch {
            XCTFail("Expected VoiceFailure, got \(error)")
            return nil
        }
    }

    private func eventually(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()), Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let succeeded = await condition()
        XCTAssertTrue(succeeded)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private actor RuntimeGate {
    private var started: Set<VoiceSessionID> = []
    private var released: Set<VoiceSessionID> = []
    private var cancelled: Set<VoiceSessionID> = []

    var startedCount: Int { started.count }
    func markStarted(_ id: VoiceSessionID) { started.insert(id) }
    func release(_ id: VoiceSessionID) { released.insert(id) }
    func isReleased(_ id: VoiceSessionID) -> Bool { released.contains(id) }
    func markCancelled(_ id: VoiceSessionID) { cancelled.insert(id) }
    func wasCancelled(_ id: VoiceSessionID) -> Bool { cancelled.contains(id) }
}

private actor AsyncLatch {
    private var released: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(released: Bool = false) {
        self.released = released
    }

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume() }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
