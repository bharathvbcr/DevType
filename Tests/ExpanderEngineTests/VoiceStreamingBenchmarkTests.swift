import XCTest
@testable import ExpanderEngine

/// Per-partial cost of live dictation over a long segment stream.
/// Set `DEVTYPE_BENCH=1` to run; skipped otherwise so CI is not timing-sensitive.
///
/// A is the pre-change shape: five full-transcript joins per partial, each copying the whole
/// prefix once per segment (`base + " " + next`). B is the real assembler -> reconciler path
/// (and the real `VoiceInsertionService`). The runs are interleaved and the minimum of N is
/// reported, so a noisy neighbour does not decide the answer.
final class VoiceStreamingBenchmarkTests: XCTestCase {

    private func requireBenchMode() throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_BENCH"] == "1" else {
            throw XCTSkip("set DEVTYPE_BENCH=1 to run benchmarks")
        }
    }

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

    private func nanos(_ body: () -> Void) -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return DispatchTime.now().uptimeNanoseconds - start
    }

    func testPerPartialCostLegacyVersusCurrent() throws {
        try requireBenchMode()
        let stream = Self.stream()
        var sink = 0

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
            var assembler = LiveTranscriptAssembler()
            let reconciler = VoiceTranscriptReconciler(maxOwnedLength: Int.max)
            for segment in stream {
                guard assembler.ingest(segment) else { continue }
                let edit = reconciler.reconcile(target: assembler.cumulativeText)
                reconciler.sealPrefix(assembler.settledText)
                sink &+= edit.textToInject.utf8.count + assembler.cumulativeText.utf8.count
            }
        }

        var bestLegacy = UInt64.max
        var bestCurrent = UInt64.max
        for _ in 0..<7 {
            bestLegacy = min(bestLegacy, nanos(legacy))
            bestCurrent = min(bestCurrent, nanos(current))
        }
        XCTAssertGreaterThan(sink, 0)
        let partials = Double(stream.count)
        print(String(format: "  legacy  (5 quadratic joins/partial)  %9.1f us/partial  total %8.2f ms",
                     Double(bestLegacy) / partials / 1_000, Double(bestLegacy) / 1_000_000))
        print(String(format: "  current (assembler + reconciler)     %9.1f us/partial  total %8.2f ms",
                     Double(bestCurrent) / partials / 1_000, Double(bestCurrent) / 1_000_000))
        XCTAssertLessThan(Double(bestCurrent) / partials / 1_000, 2_000, "per-partial ceiling: 2 ms")
    }

    @MainActor
    func testInsertionServicePerPartialCost() throws {
        try requireBenchMode()
        let stream = Self.stream()
        var best = UInt64.max
        for _ in 0..<5 {
            let service = VoiceInsertionService(submit: { _, completion in completion(.succeeded) },
                                                liveMode: .previewInHUD)
            service.beginSession()
            best = min(best, nanos {
                for segment in stream {
                    service.applyLiveSegment(segment)
                    _ = service.recognizedText
                }
            })
        }
        let perPartial = Double(best) / Double(stream.count) / 1_000
        print(String(format: "  VoiceInsertionService.applyLiveSegment %9.1f us/partial (%d partials)",
                     perPartial, stream.count))
        XCTAssertLessThan(perPartial, 2_000, "per-partial ceiling: 2 ms")
    }
}
