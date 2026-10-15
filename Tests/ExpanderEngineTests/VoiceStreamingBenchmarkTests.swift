import XCTest
@testable import ExpanderEngine

/// Per-partial cost of live dictation over a long segment stream.
/// Set `DEVTYPE_BENCH=1` to run; skipped otherwise so CI is not timing-sensitive.
///
/// A is the pre-change shape: five full-transcript joins per partial, each copying the whole
/// prefix once per segment (`base + " " + next`). B is the real path: `VoiceInsertionService`
/// (assembler, diagnostics off) plus the reconciler sealing finals. `BenchmarkGate.interleaved`
/// alternates the two and keeps each side's minimum, so a noisy neighbour does not decide it.
final class VoiceStreamingBenchmarkTests: XCTestCase {

    private static let segmentCount = 500
    private static let revisionsPerSegment = 3

    private static func stream() -> [SpeechSegment] {
        var out: [SpeechSegment] = []
        for index in 0..<segmentCount {
            for revision in 1...revisionsPerSegment {
                let words = (0..<(4 * revision)).map { "w\(index)x\($0)" }.joined(separator: " ")
                out.append(SpeechSegment(
                    segmentID: "s\(index)", revision: UInt64(revision), text: words,
                    finality: revision == revisionsPerSegment ? .final : .volatile
                ))
            }
        }
        return out
    }

    /// The old join: a fresh string per segment.
    private static func legacyCombine(_ segments: [String], active: String) -> String {
        var result = ""
        for next in segments + [active] where !next.isEmpty {
            result = result.isEmpty ? next : result + " " + next
        }
        return result
    }

    /// Before: five quadratic joins per partial. After: insertion service + reconciler.
    /// Ceiling is 2 ms per partial for the after path (the pre-change join is the comparison,
    /// not a ceiling — it is expected to be slower). 500 segments × 3 revisions.
    @MainActor
    func testPerPartialCostLegacyVersusCurrent() throws {
        try BenchmarkGate.requireBenchMode()
        let stream = Self.stream()
        var sink = 0
        let tracingKey = VoicePreferences.voiceTracingKey
        let previousTracing = UserDefaults.standard.object(forKey: tracingKey)
        VoicePreferences.isVoiceTracingEnabled = false
        defer {
            if let previousTracing { UserDefaults.standard.set(previousTracing, forKey: tracingKey) }
            else { UserDefaults.standard.removeObject(forKey: tracingKey) }
        }

        let legacy = {
            var texts: [String] = []
            var active = ""
            for segment in stream {
                if segment.finality == .final { texts.append(segment.text); active = "" } else { active = segment.text }
                // settled + active + cumulative (diagnostics), cumulative + settled (target), cumulative (HUD)
                sink &+= Self.legacyCombine(texts, active: "").utf8.count
                sink &+= Self.legacyCombine(texts, active: active).utf8.count
                sink &+= Self.legacyCombine(texts, active: active).utf8.count
                sink &+= Self.legacyCombine(texts, active: "").utf8.count
                sink &+= Self.legacyCombine(texts, active: active).utf8.count
            }
        }
        let current = {
            let service = VoiceInsertionService(
                submit: { _, completion in completion(.succeeded) },
                liveMode: .previewInHUD
            )
            service.beginSession()
            let reconciler = VoiceTranscriptReconciler(maxOwnedLength: Int.max)
            for segment in stream {
                service.applyLiveSegment(segment)
                let target = service.recognizedText
                let edit = reconciler.reconcile(target: target)
                if segment.finality == .final {
                    reconciler.sealPrefix(target)
                }
                sink &+= edit.textToInject.utf8.count &+ target.utf8.count
            }
            sink &+= service.diagnosticsTextBuildCount
        }

        let times = BenchmarkGate.interleaved(warmup: 1, rounds: 5, legacy, current)
        XCTAssertGreaterThan(sink, 0)
        let partials = Double(stream.count)
        let ceilingMs = partials * 2
        print(String(format: "  legacy  (5 quadratic joins/partial)  %9.1f us/partial  total %8.2f ms",
                     times.a / partials * 1_000, times.a))
        print(String(format: "  current (service + reconciler)       %9.1f us/partial  total %8.2f ms",
                     times.b / partials * 1_000, times.b))
        let verdict = BenchmarkGate.verdict(measuredMs: times.b, ceilingMs: ceilingMs)
        if !verdict.passed {
            XCTFail(String(format: "current path %.2f ms exceeds ceiling %.0f ms (2 ms/partial)",
                           times.b, ceilingMs))
        }
        XCTAssertLessThan(times.b, times.a,
                          "The linear path must beat five quadratic joins per partial")
    }
}
