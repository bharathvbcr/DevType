import XCTest
@testable import ExpanderEngine

/// The palette's semantic-routing default, and the latency that decision rests on.
///
/// First paint is `CommandPaletteCatalog.buildRows`. It does not read the routing
/// flag. `route` returns before any model work when the flag is off. A live model
/// round trip is opt-in (`DEVTYPE_MEASURE_ROUTING=1`) so a missing or declining
/// model cannot fail the suite, and a skip is not reported as a pass.
final class SemanticRoutingDecisionTests: XCTestCase {

    private var savedAI = false
    private var savedRoutingObject: Any?

    override func setUp() {
        super.setUp()
        savedAI = AIPreferences.isEnabled
        savedRoutingObject = UserDefaults.standard.object(forKey: AIPreferences.semanticRoutingEnabledKey)
    }

    override func tearDown() {
        AIPreferences.isEnabled = savedAI
        if let savedRoutingObject {
            UserDefaults.standard.set(savedRoutingObject, forKey: AIPreferences.semanticRoutingEnabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AIPreferences.semanticRoutingEnabledKey)
        }
        super.tearDown()
    }

    func testSemanticRoutingDefaultsOffAndDebouncesFor250Milliseconds() {
        UserDefaults.standard.removeObject(forKey: AIPreferences.semanticRoutingEnabledKey)
        XCTAssertFalse(AIPreferences.isSemanticRoutingEnabled)
        XCTAssertEqual(PaletteToolRouter.debounceMilliseconds, 250)
        XCTAssertEqual(PaletteToolRouter.timeoutSeconds, 8)
    }

    func testAClosedGateReturnsBeforeTheEngine() async {
        AIPreferences.isEnabled = true
        AIPreferences.isSemanticRoutingEnabled = false
        let called = Sendable_Box()
        var best = Double.infinity
        for _ in 0..<7 {
            let start = DispatchTime.now().uptimeNanoseconds
            let routed = await PaletteToolRouter.route(query: "date next friday") { _ in
                called.set()
                return "2026-10-16"
            }
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            best = min(best, milliseconds)
            XCTAssertNil(routed)
        }
        XCTAssertFalse(called.value)
        print(String(format: "ROUTING_MEASURE gated_route_min_ms=%.4f", best))
        XCTAssertLessThan(best, 50, "A closed gate is a bool check, not a model call.")
    }

    func testFirstPaintDoesNotReadTheRoutingFlag() {
        AIPreferences.isEnabled = true
        let groups = library(40)
        let query = "format this note"
        _ = CommandPaletteCatalog.buildRows(query: query, groups: groups)
        var bestOff = Double.infinity
        var bestOn = Double.infinity
        for _ in 0..<7 {
            AIPreferences.isSemanticRoutingEnabled = false
            bestOff = min(bestOff, milliseconds {
                _ = CommandPaletteCatalog.buildRows(query: query, groups: groups)
            })
            AIPreferences.isSemanticRoutingEnabled = true
            bestOn = min(bestOn, milliseconds {
                _ = CommandPaletteCatalog.buildRows(query: query, groups: groups)
            })
        }
        print(String(format: "ROUTING_MEASURE buildRows_off_min_ms=%.4f buildRows_on_min_ms=%.4f", bestOff, bestOn))
        XCTAssertLessThan(bestOff, 1_000)
        XCTAssertLessThan(bestOn, 1_000)
    }

    func testLiveRoutingRoundTripWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["DEVTYPE_MEASURE_ROUTING"] == "1" else {
            throw XCTSkip("set DEVTYPE_MEASURE_ROUTING=1 to time a live routing round trip")
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            print("ROUTING_MEASURE model=unavailable reason=os")
            throw XCTSkip("Foundation Models requires macOS 26")
        }
        AIPreferences.isEnabled = true
        AIPreferences.isSemanticRoutingEnabled = true
        guard let engine = PaletteToolRouter.foundationModelsEngine(groupsProvider: { [] }) else {
            print("ROUTING_MEASURE model=unavailable reason=probe")
            throw XCTSkip("Apple Intelligence model is unavailable or the locale is unsupported")
        }
        // `route` returns at `timeoutSeconds` (8). `SingleFlightLatch` also caps
        // every caller at 60s and then cancels. Neither number is a finished
        // answer. This call is the engine closure, so the model can complete.
        let direct = await Self.directEngine("date next friday", engine: engine, limitSeconds: 180)
        switch direct.outcome {
        case .finished(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            print(String(
                format: "ROUTING_MEASURE direct_engine_ms=%.1f finished=1 nonempty=%d chars=%d",
                direct.milliseconds,
                trimmed.isEmpty ? 0 : 1,
                text.count
            ))
        case .failed(let message):
            print(String(
                format: "ROUTING_MEASURE direct_engine_ms=%.1f finished=1 failed=1 error=%@",
                direct.milliseconds,
                message
            ))
        case .unfinished:
            print(String(
                format: "ROUTING_MEASURE direct_engine_ms=%.1f finished=0 limit_s=180",
                direct.milliseconds
            ))
        }
        var samples: [Double] = []
        for index in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let routed = await PaletteToolRouter.route(query: "date next friday", engine: engine)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            print(String(
                format: "ROUTING_MEASURE model_sample i=%d ms=%.1f row=%@",
                index,
                milliseconds,
                routed.map { "text:\($0.text)" } ?? "nil"
            ))
            if index > 0 { samples.append(milliseconds) }
        }
        if let best = samples.min() {
            print(String(format: "ROUTING_MEASURE model_min_ms=%.1f", best))
        }
        #else
        print("ROUTING_MEASURE model=unavailable reason=no_foundation_models")
        throw XCTSkip("this toolchain cannot import Foundation Models")
        #endif
    }

    private func library(_ count: Int) -> [SnippetGroup] {
        let snippets = (0..<count).map { index in
            SnippetModel(
                title: "Snippet number \(index)",
                triggerKeyword: ";n\(index)",
                replacementText: "body \(index)",
                tags: ["tag\(index % 5)"]
            )
        }
        return [SnippetGroup(name: "All", snippets: snippets)]
    }

    private enum DirectOutcome {
        case finished(String)
        case failed(String)
        case unfinished
    }

    private struct DirectEngineResult {
        var milliseconds: Double
        var outcome: DirectOutcome
    }

    /// One claim, so the deadline and the engine cannot both resume the continuation.
    private actor ProbeClaim {
        private var claimed = false
        func claim() -> Bool {
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// Times `engine` without `PaletteToolRouter.route`. The product latch is not
    /// involved. A model that ignores cancellation is abandoned at `limitSeconds`
    /// and reported unfinished; that wait is not `timeoutSeconds`.
    private static func directEngine(
        _ query: String,
        engine: @escaping PaletteToolRouter.RoutingEngine,
        limitSeconds: Double
    ) async -> DirectEngineResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let claim = ProbeClaim()
        let outcome: DirectOutcome = await withCheckedContinuation { continuation in
            let engineTask = Task {
                let probe: DirectOutcome
                do {
                    probe = .finished(try await engine(query))
                } catch {
                    let message = String(describing: error)
                    probe = .failed(String(message.prefix(500)))
                }
                if await claim.claim() {
                    continuation.resume(returning: probe)
                }
            }
            Task {
                let nanos = UInt64(min(max(limitSeconds, 0), 180) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if await claim.claim() {
                    engineTask.cancel()
                    continuation.resume(returning: .unfinished)
                }
            }
        }
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return DirectEngineResult(milliseconds: milliseconds, outcome: outcome)
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
