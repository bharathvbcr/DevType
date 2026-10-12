import AppKit
import XCTest
@testable import ExpanderEngine

/// The per-partial cost of live dictation must grow linearly with the transcript.
///
/// Every recognizer partial used to rebuild the settled, active and cumulative transcript
/// several times, each build copying the whole prefix once per segment. These tests pin the
/// shape (one rebuild per changed segment, none per read, linear join) and that the cached
/// text still equals the reference join for hostile inputs.
final class VoiceStreamingLinearityTests: XCTestCase {

    private func segment(_ id: String, _ revision: UInt64, _ text: String,
                         _ finality: Finality = .volatile) -> SpeechSegment {
        SpeechSegment(segmentID: id, revision: revision, text: text, finality: finality)
    }

    /// The straightforward definition the assembler's cached text must equal.
    private func referenceCumulative(_ texts: [String], active: String) -> String {
        VoiceTranscriptReconciler.combineUtterances(committed: texts, activePartial: active)
    }

    // MARK: - Assembler caching

    func testEmptyAssemblerHasEmptyTranscripts() {
        var assembler = LiveTranscriptAssembler()
        XCTAssertEqual(assembler.cumulativeText, "")
        XCTAssertEqual(assembler.settledText, "")
        XCTAssertEqual(assembler.activeText, "")
        let blank = assembler.ingest(segment("a", 1, "   "))
        XCTAssertTrue(blank)
        XCTAssertEqual(assembler.activeText, "")
        XCTAssertEqual(assembler.cumulativeText, "")
    }

    func testReadsNeverRebuildAndEachChangedSegmentRebuildsOnce() {
        var assembler = LiveTranscriptAssembler()
        let first = assembler.ingest(segment("a", 1, "hello"))
        XCTAssertTrue(first)
        XCTAssertEqual(assembler.rebuildCount, 1)
        for _ in 0..<50 {
            _ = assembler.cumulativeText
            _ = assembler.settledText
            _ = assembler.activeText
        }
        XCTAssertEqual(assembler.rebuildCount, 1, "Reading the transcript must not rebuild it")

        let second = assembler.ingest(segment("a", 2, "hello world"))
        XCTAssertTrue(second)
        XCTAssertEqual(assembler.rebuildCount, 2)
    }

    func testIgnoredSegmentsDoNotRebuild() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.ingest(segment("a", 5, "newer"))
        let before = assembler.rebuildCount
        let stale = assembler.ingest(segment("a", 3, "older"))
        let duplicate = assembler.ingest(segment("a", 5, "newer"))
        XCTAssertFalse(stale, "Out-of-order revision is ignored")
        XCTAssertFalse(duplicate, "Duplicate revision is ignored")
        XCTAssertEqual(assembler.rebuildCount, before)
        XCTAssertEqual(assembler.cumulativeText, "newer")
    }

    func testCachedTextMatchesReferenceAcrossUnicodeAndSealing() {
        let utterances = ["こんにちは世界", "👨‍👩‍👧‍👦 family", "e\u{301}clair", "🇯🇵🇺🇸 flags", "العربية", "plain"]
        var assembler = LiveTranscriptAssembler()
        var finals: [String] = []
        for (index, text) in utterances.enumerated() {
            let id = "u\(index)"
            _ = assembler.ingest(segment(id, 1, String(text.prefix(3))))
            XCTAssertEqual(assembler.cumulativeText, referenceCumulative(finals, active: String(text.prefix(3))))
            _ = assembler.ingest(segment(id, 2, text))
            XCTAssertEqual(assembler.activeText, text)
            XCTAssertEqual(assembler.settledText, referenceCumulative(finals, active: ""))
            XCTAssertEqual(assembler.cumulativeText, referenceCumulative(finals, active: text))
            if index.isMultiple(of: 2) {
                _ = assembler.ingest(segment(id, 3, text, .final))
                finals.append(text)
                XCTAssertEqual(assembler.settledText, referenceCumulative(finals, active: ""))
                XCTAssertEqual(assembler.cumulativeText, assembler.settledText)
            } else {
                finals.append(text)   // sealed implicitly by the next segment id
            }
        }
    }

    func testResetClearsCachedText() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.ingest(segment("a", 1, "something"))
        assembler.reset()
        XCTAssertEqual(assembler.cumulativeText, "")
        XCTAssertEqual(assembler.settledText, "")
    }

    func testBoundedStreamAtMaxSegmentsStaysConsistent() {
        var assembler = LiveTranscriptAssembler()
        for index in 0..<(LiveTranscriptAssembler.maxSegments + 20) {
            _ = assembler.ingest(segment("s\(index)", 1, "word\(index)", .final))
        }
        XCTAssertEqual(assembler.segmentCount, LiveTranscriptAssembler.maxSegments)
        let expected = (0..<LiveTranscriptAssembler.maxSegments).map { "word\($0)" }.joined(separator: " ")
        XCTAssertEqual(assembler.cumulativeText, expected)
        XCTAssertEqual(assembler.settledText, expected)
    }

    // MARK: - Linear join

    private func bestOf(_ runs: Int, _ body: () -> Void) -> UInt64 {
        var best = UInt64.max
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, DispatchTime.now().uptimeNanoseconds - start)
        }
        return best
    }

    /// 512 segments is 8x the work of 64 if the join is linear and 64x if it is quadratic.
    /// The bound sits well between, so noise cannot fail a linear join but a per-segment
    /// copy of the growing prefix cannot pass.
    func testCombineUtterancesGrowsLinearlyWithSegments() {
        func texts(_ count: Int) -> [String] {
            (0..<count).map { _ in String(repeating: "x", count: 2_048) }
        }
        let small = texts(64)
        let large = texts(512)
        var sink = 0
        let tSmall = bestOf(9) { sink &+= VoiceTranscriptReconciler.combineUtterances(committed: small, activePartial: "tail").utf8.count }
        let tLarge = bestOf(9) { sink &+= VoiceTranscriptReconciler.combineUtterances(committed: large, activePartial: "tail").utf8.count }
        XCTAssertGreaterThan(sink, 0)
        let ratio = Double(tLarge) / Double(max(tSmall, 1))
        XCTAssertLessThan(ratio, 24, "8x the segments cost \(ratio)x: join is not linear")
    }

    // MARK: - Reconciler counts

    func testReconcileAndSealAgreeWithNaiveModelOnGraphemeEdges() {
        // Committed text ending in a base character, tail starting with a combining mark:
        // the joined string merges clusters, so cached per-part counts must not be trusted
        // for the combined string.
        let reconciler = VoiceTranscriptReconciler()
        _ = reconciler.reconcile(target: "caf")
        reconciler.sealPrefix("caf")
        XCTAssertEqual(reconciler.committedText, "caf")
        let edit = reconciler.reconcile(target: "cafe\u{301} 👍🏽 日本語")
        XCTAssertEqual(edit.resultingText, "cafe\u{301} 👍🏽 日本語")
        XCTAssertEqual(reconciler.ownedText, "cafe\u{301} 👍🏽 日本語")
        reconciler.sealPrefix("cafe\u{301} 👍🏽")
        XCTAssertEqual(reconciler.committedText, "cafe\u{301} 👍🏽")
        XCTAssertEqual(reconciler.volatileText, " 日本語")
        // A prefix that is not a real prefix, or not ahead of the barrier, is refused.
        reconciler.sealPrefix("cafe")
        reconciler.sealPrefix("completely different")
        XCTAssertEqual(reconciler.committedText, "cafe\u{301} 👍🏽")
    }

    func testOwnedCeilingCountsCharactersNotBytes() {
        // 3 CJK characters are 9 UTF-8 bytes; a ceiling of 5 characters must not trip on bytes.
        let reconciler = VoiceTranscriptReconciler(maxOwnedLength: 5)
        let first = reconciler.reconcile(target: "日本語")
        XCTAssertEqual(first.resultingText, "日本語")
        let second = reconciler.reconcile(target: "日本語です")
        XCTAssertEqual(second.resultingText, "日本語です", "5 characters reach the ceiling only after this edit")
        let third = reconciler.reconcile(target: "日本語です。")
        XCTAssertTrue(third.isNoop, "At the ceiling the reconciler degrades to append-only")
    }

    func testEmptyTargetsAndRollback() {
        let reconciler = VoiceTranscriptReconciler()
        XCTAssertTrue(reconciler.reconcile(target: "").isNoop)
        reconciler.sealPrefix("")
        XCTAssertEqual(reconciler.committedText, "")
        _ = reconciler.reconcile(target: "abc")
        reconciler.sealPrefix("ab")
        let rollback = reconciler.rollbackAll()
        XCTAssertEqual(rollback.eraseCount, 3)
        XCTAssertEqual(reconciler.ownedText, "")
        let after = reconciler.reconcile(target: "xyz")
        XCTAssertEqual(after.textToInject, "xyz")
    }

    // MARK: - Diagnostics are not built while tracing is off

    @MainActor
    func testNoDiagnosticTextIsBuiltWhileTracingIsOff() {
        let key = VoicePreferences.voiceTracingKey
        let previous = UserDefaults.standard.object(forKey: key)
        VoicePreferences.isVoiceTracingEnabled = false
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let service = VoiceInsertionService(submit: { _, completion in completion(.succeeded) },
                                            liveMode: .previewInHUD)
        service.beginSession()
        for index in 0..<200 {
            service.applyLiveSegment(segment("s", UInt64(index + 1), "word \(index)"))
        }
        XCTAssertEqual(service.diagnosticsTextBuildCount, 0,
                       "Settled/active/cumulative strings were built for a trace that is off")
        XCTAssertEqual(service.assemblerRebuildCount, 200, "One assembler rebuild per changed partial")
        XCTAssertEqual(service.recognizedText, "word 199")
        for _ in 0..<20 { _ = service.recognizedText }
        XCTAssertEqual(service.assemblerRebuildCount, 200, "Reading the HUD transcript must not rebuild")
    }

    // MARK: - HUD measurement

    func testHUDSizeIgnoresTextBeyondTheMeasuredTail() {
        let font = NSFont.systemFont(ofSize: 14.5)
        let sentence = "The quick brown fox jumps over the lazy dog and keeps on dictating. "
        let long = String(repeating: sentence, count: 400)
        let tail = String(long.suffix(LiquidBlobGeometry.measuredTailLimit))
        let max = CGSize(width: 500, height: 188)
        let full = LiquidBlobGeometry.hudSize(forText: long, font: font)
        XCTAssertEqual(full.height, max.height, "A long transcript is clamped to the maximum height")
        XCTAssertEqual(full, LiquidBlobGeometry.hudSize(forText: tail, font: font))
        XCTAssertEqual(full, LiquidBlobGeometry.hudSize(forText: "prefix that changes nothing " + long, font: font))
    }

    func testHUDTailKeepsCJKAndEmojiClustersWhole() {
        let long = String(repeating: "日本語👨‍👩‍👧‍👦🇯🇵", count: 2_000)
        let tail = LiquidBlobGeometry.measurableTail(of: long)
        XCTAssertLessThanOrEqual(tail.count, LiquidBlobGeometry.measuredTailLimit)
        XCTAssertEqual(String(tail).unicodeScalars.count, String(tail).unicodeScalars.count)
        XCTAssertEqual(LiquidBlobGeometry.measurableTail(of: "short"), "short")
        XCTAssertEqual(LiquidBlobGeometry.measurableTail(of: ""), "")
    }

    func testShortTextStillMeasuredExactly() {
        let font = NSFont.systemFont(ofSize: 14.5)
        let medium = "A moderately long dictated sentence that wraps onto a second line of the HUD."
        XCTAssertEqual(LiquidBlobGeometry.measurableTail(of: medium), Substring(medium))
        XCTAssertGreaterThan(LiquidBlobGeometry.hudSize(forText: medium, font: font).height, 68)
    }

    // MARK: - Compiled once

    func testProtectedSpanPatternsAreCompiledOnceAndStillMatch() {
        let first = ProtectedSpanExtractor.patterns.map { ObjectIdentifier($0.regex) }
        _ = ProtectedSpanExtractor.extract(from: "see ~/a/b --flag v1.2.3 5 ms $4.00")
        let second = ProtectedSpanExtractor.patterns.map { ObjectIdentifier($0.regex) }
        XCTAssertEqual(first.count, 6)
        XCTAssertEqual(first, second)
        let spans = ProtectedSpanExtractor.extract(from: "mail a@b.co at ~/x/y with --verbose on v1.2.3")
        let kinds = Set(spans.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.filePath, .shellFlag, .versionNumber]))
    }

    func testDeterministicCorrectorOutputUnchangedByCachedRules() async throws {
        let corrector = DeterministicCorrector()
        let raw = "um hello comma Tuesday, sorry, Thursday question mark   new line the result, you know, was fine period"
        let request = CorrectionRequest(
            sessionID: VoiceSessionID(),
            generation: SessionGeneration(rawValue: 1),
            rawTranscript: raw,
            policy: CorrectionPolicy(),
            protectedSpans: ProtectedSpanExtractor.extract(from: raw),
            deadline: Date().addingTimeInterval(5),
            privacyRoute: .onDeviceOnly
        )
        let candidate = try await corrector.correct(request)
        XCTAssertEqual(candidate.text, "Hello, Thursday?\nThe result, was fine.")
    }
}
