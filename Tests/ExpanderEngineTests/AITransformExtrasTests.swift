import XCTest
@testable import ExpanderEngine

/// Perf-sweep item 9: chunk budgets are computed once per chunk, the static token cache is
/// bounded, and the transform flow no longer fires a prewarm in front of the transform.
final class AITransformExtrasTests: XCTestCase {

    // MARK: - Chunk planning

    func testEveryChunkIsEvaluatedExactlyOnceAndKeepsItsBudget() async throws {
        let segments = (0..<5).map { AITransformText.Segment(body: "para \($0)", separator: "\n\n") }
        var evaluated: [String] = []
        let planned = try await AIChunkPlanner.plan(segments) { body in
            evaluated.append(body)
            return body.count * 10
        }
        XCTAssertEqual(evaluated, segments.map(\.body), "One budget evaluation per chunk, none repeated")
        XCTAssertEqual(planned.map(\.segment), segments)
        XCTAssertEqual(planned.map(\.maxResponseTokens), segments.map { $0.body.count * 10 })
    }

    func testAnOversizedSegmentIsSplitAndEachPieceCountedOnce() async throws {
        let big = AITransformText.Segment(body: String(repeating: "word ", count: 40), separator: "\n")
        var evaluated: [String] = []
        let planned = try await AIChunkPlanner.plan([big]) { body in
            evaluated.append(body)
            if body.count > 60 { throw AITransformError.inputTooLarge(estimatedTokens: 999, contextSize: 100) }
            return 7
        }
        XCTAssertGreaterThan(planned.count, 1)
        XCTAssertTrue(planned.allSatisfy { $0.maxResponseTokens == 7 && $0.segment.body.count <= 60 })
        // Rejected parents are evaluated (they must be) but every *accepted* chunk exactly once.
        for plan in planned {
            XCTAssertEqual(evaluated.filter { $0 == plan.segment.body }.count, 1)
        }
        XCTAssertEqual(
            AITransformText.joined(planned.map(\.segment), bodies: planned.map(\.segment.body)),
            big.body + big.separator
        )
    }

    func testANonSizeErrorPropagatesAndAnUnsplittableSegmentFails() async {
        let one = AITransformText.Segment(body: "x", separator: "")
        do {
            _ = try await AIChunkPlanner.plan([one]) { _ in
                throw AITransformError.inputTooLarge(estimatedTokens: 9, contextSize: 1)
            }
            XCTFail("A single character that cannot fit has no smaller input")
        } catch {
            XCTAssertEqual(error as? AITransformError, .inputTooLarge(estimatedTokens: 9, contextSize: 1))
        }
        do {
            _ = try await AIChunkPlanner.plan([one]) { _ in throw AITransformError.busy }
            XCTFail("Other errors are not a reason to split")
        } catch {
            XCTAssertEqual(error as? AITransformError, .busy)
        }
    }

    // MARK: - Bounded cache

    func testTheCacheNeverExceedsItsCapacity() {
        var cache = AIBoundedCache<Int>(capacity: 4)
        for index in 0..<1_000 { cache.insert(index, forKey: "custom-\(index)") }
        XCTAssertEqual(cache.count, 4)
        XCTAssertNil(cache.value(forKey: "custom-0"))
        XCTAssertEqual(cache.value(forKey: "custom-999"), 999)
    }

    func testTheCacheEvictsTheLeastRecentlyUsedEntry() {
        var cache = AIBoundedCache<Int>(capacity: 2)
        cache.insert(1, forKey: "a")
        cache.insert(2, forKey: "b")
        XCTAssertEqual(cache.value(forKey: "a"), 1)   // a is now the most recent
        cache.insert(3, forKey: "c")                  // evicts b
        XCTAssertNil(cache.value(forKey: "b"))
        XCTAssertEqual(cache.value(forKey: "a"), 1)
        XCTAssertEqual(cache.value(forKey: "c"), 3)
        cache.insert(30, forKey: "c")                 // overwrite does not grow it
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.value(forKey: "c"), 30)
    }

    // MARK: - Source contracts (the transformer actor and flow need a live model / AppKit)

    private func source(_ relative: String) throws -> String {
        SourceContractTests.strippingComments(try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(relative),
            encoding: .utf8
        ))
    }

    func testTheTransformFlowDoesNotPrewarmInFrontOfTheTransform() throws {
        let flow = try source("Sources/DevTypeAppCore/AITransformFlow.swift")
        XCTAssertFalse(flow.contains("prewarm("), "The panel prewarms on open; the flow only transforms")
    }

    func testTheEarlierPrewarmOnPanelOpenRemains() throws {
        let panel = try source("Sources/DevTypeAppCore/AIActionPanel.swift")
        XCTAssertTrue(panel.contains("prewarm(kind: .proofread)"))
    }

    /// The preview panel starts generating in the same `open` call, so a prewarm there is the
    /// same back-to-back race the flow had.
    func testThePreviewPanelDoesNotPrewarmInFrontOfItsTransform() throws {
        let preview = try source("Sources/DevTypeAppCore/AIPreviewPanel.swift")
        XCTAssertFalse(preview.contains("prewarm("))
        XCTAssertTrue(preview.contains("controller.startGeneration()"))
    }

    func testTheTransformerReleasesTheSpentWarmSessionAndBoundsItsCache() throws {
        let transformer = try source("Sources/ExpanderEngine/AI/AITextTransformer.swift")
        XCTAssertTrue(transformer.contains("warmSession = nil"), "A spent warm session must not be retained")
        XCTAssertTrue(transformer.contains("staticTokenCache = AIBoundedCache"))
        XCTAssertFalse(transformer.contains("func budgetedChunks"), "Chunk budgets come from AIChunkPlanner")
    }
}
