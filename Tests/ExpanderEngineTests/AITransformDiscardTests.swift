import XCTest
@testable import ExpanderEngine

#if canImport(FoundationModels)
import FoundationModels
#endif

/// What "discard this request" has to mean.
///
/// `AITransformDiscardHandle.discard()` used to drop the *result* and leave the *work*
/// running. The generation kept `AITextTransformer`'s single-flight latch, so the request
/// that replaced it was refused `.busy` by the request it had just replaced — and the
/// caller had no way to tell the difference between "the model is busy with someone else's
/// work" and "the model is busy with my own abandoned work". Abandoning has to stop the
/// work, and a caller replacing its own request has to be able to wait for that to happen.
///
/// `AITextTransformer` needs macOS 26, so these skip with the reason rather than reporting
/// a pass they never ran — but the first three need no model, only the OS.
final class AITransformDiscardTests: XCTestCase {

    private func requireTransformer() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw XCTSkip("needs macOS 26+") }
        #else
        throw XCTSkip("FoundationModels unavailable at compile time")
        #endif
    }

    private func requireLiveModel() throws {
        try requireTransformer()
        if ProcessInfo.processInfo.environment["DEVTYPE_SKIP_LIVE_AI"] == "1" {
            throw XCTSkip("live model tests disabled by DEVTYPE_SKIP_LIVE_AI=1")
        }
        guard case .available = AITextTransformSupport.availability else {
            throw XCTSkip("model unavailable: \(AITextTransformSupport.availability)")
        }
    }

    private static let longSelection = """
        we was discussing the api desing yesterday and it dont work as expcted, please take \
        a look at the retry logic and the timeout handling when you get a chance. also the \
        docs for the endpoint are out of date and the examples dont compile anymore.
        """

    #if canImport(FoundationModels)

    /// Spins until `ready`, or gives up — the completions land on a background queue.
    private func waitUntil(_ ready: () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !ready() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - No model required

    /// The local transforms answer without a model, so the handle's plumbing — attach,
    /// settle, complete exactly once — is checkable wherever the OS supports the type.
    func testSettledResolvesOnceALocalRequestHasFinished() async throws {
        try requireTransformer()
        guard #available(macOS 26.0, *) else { return }
        let collected = ResultBox()

        let handle = AITextTransformer().transformStreaming(
            kind: .removeMarkdown,
            input: "# Heading\n\n**bold**",
            onPartial: nil,
            completionQueue: .global(qos: .userInitiated)
        ) { collected.append($0) }

        await handle.settled()
        await waitUntil { collected.count == 1 }

        XCTAssertEqual(collected.count, 1)
        guard case .success(let text) = try XCTUnwrap(collected.first) else {
            return XCTFail("local transform should succeed: \(String(describing: collected.first))")
        }
        XCTAssertEqual(text, "Heading\n\nbold")
    }

    /// A handle is handed back from the same statement that creates its task, so `discard()`
    /// can arrive before the task exists. The request must still be cancelled, not lost.
    func testDiscardBeforeTheTaskIsObservedStillEndsTheRequest() async throws {
        try requireTransformer()
        guard #available(macOS 26.0, *) else { return }
        let collected = ResultBox()

        let handle = AITextTransformer().transformStreaming(
            kind: .removeMarkdown,
            input: "# Heading\n\n**bold**",
            onPartial: nil,
            completionQueue: .global(qos: .userInitiated)
        ) { collected.append($0) }
        handle.discard()
        await handle.settled()
        await waitUntil { collected.count == 1 }

        XCTAssertEqual(collected.count, 1, "The completion must still run exactly once")
        guard case .failure(.discarded) = try XCTUnwrap(collected.first) else {
            return XCTFail("a discarded request reports `.discarded`: \(String(describing: collected.first))")
        }
    }

    /// `after:` sequences the replacement behind the request it replaces.
    func testRequestsChainedWithAfterRunInOrder() async throws {
        try requireTransformer()
        guard #available(macOS 26.0, *) else { return }
        let transformer = AITextTransformer()
        let order = OrderBox()

        let first = transformer.transformStreaming(
            kind: .removeMarkdown,
            input: "**one**",
            onPartial: nil,
            completionQueue: .global(qos: .userInitiated)
        ) { _ in order.append("first") }

        let second = transformer.transformStreaming(
            kind: .removeMarkdown,
            input: "**two**",
            after: first,
            onPartial: nil,
            completionQueue: .global(qos: .userInitiated)
        ) { _ in order.append("second") }

        await second.settled()
        await waitUntil { order.values.count == 2 }
        XCTAssertEqual(order.values, ["first", "second"])
    }

    // MARK: - Live model

    /// Starts a long rewrite and returns once it is provably streaming, so that discarding
    /// it tests cancelling live work rather than racing a generation that already finished.
    @available(macOS 26.0, *)
    private func liveGeneration(
        after previous: AITransformDiscardHandle? = nil
    ) async throws -> (handle: AITransformDiscardHandle, result: ResultBox) {
        let partials = OrderBox()
        let result = ResultBox()
        let handle = AITextTransformer.shared.transformStreaming(
            kind: .rewrite,
            input: Self.longSelection,
            after: previous,
            onPartial: { _ in partials.append("partial") },
            completionQueue: .global(qos: .userInitiated)
        ) { result.append($0) }

        await waitUntil({ !partials.values.isEmpty || result.count == 1 }, timeout: 90)
        if case .failure(.deferredBySystem) = result.first {
            throw XCTSkip("macOS deferred the model request for system state (e.g. memory pressure)")
        }
        try XCTSkipIf(result.count == 1, "generation finished before it could be interrupted")
        return (handle, result)
    }

    /// The fix, at the layer that owns the latch: a discarded generation must hand the
    /// model back, so its replacement runs instead of being refused `.busy`.
    func testDiscardedGenerationReleasesTheLatchForItsReplacement() async throws {
        try requireLiveModel()
        guard #available(macOS 26.0, *) else { return }

        let abandoned = try await liveGeneration()
        abandoned.handle.discard()

        let replacement = ResultBox()
        let replacementHandle = AITextTransformer.shared.transformStreaming(
            kind: .rewrite,
            input: Self.longSelection,
            after: abandoned.handle,
            onPartial: { _ in },
            completionQueue: .global(qos: .userInitiated)
        ) { replacement.append($0) }
        defer { replacementHandle.discard() }

        await waitUntil({ replacement.count == 1 }, timeout: 90)
        let result = try XCTUnwrap(replacement.first, "the replacement never completed")
        if case .failure(.busy) = result {
            XCTFail("A replacement must not be refused by the request it replaced")
        }
        if case .failure(.discarded) = result {
            XCTFail("The replacement must run, not inherit the discard")
        }

        // The predecessor really was interrupted — otherwise the latch was never contested.
        guard case .failure(.discarded) = try XCTUnwrap(abandoned.result.first) else {
            return XCTFail("the abandoned request should report `.discarded`")
        }
    }

    /// Taking a request back is the user changing their mind, not the model failing. It
    /// used to be classified as `.unknown`, logged, and recorded in the diagnostics store —
    /// so every tone change a user made counted against the model's reliability.
    func testDiscardingAGenerationDoesNotRecordADiagnosticFailure() async throws {
        try requireLiveModel()
        guard #available(macOS 26.0, *) else { return }
        let store = AIDiagnosticsStore.shared
        let before = store.recentFailures().count

        let live = try await liveGeneration()
        live.handle.discard()
        await live.handle.settled()
        try await Task.sleep(nanoseconds: 200_000_000)

        guard case .failure(.discarded) = try XCTUnwrap(live.result.first) else {
            return XCTFail("the request should report `.discarded`")
        }
        XCTAssertEqual(
            store.recentFailures().count,
            before,
            "Cancelling is not a failure: \(store.recentFailures().map(\.error))"
        )
    }

    /// Cancellation is cooperative, so the promise is that `settled()` resolves — not that
    /// it resolves instantly. It must still resolve well inside a generation's own length.
    func testSettledResolvesPromptlyAfterDiscardingALiveGeneration() async throws {
        try requireLiveModel()
        guard #available(macOS 26.0, *) else { return }

        let live = try await liveGeneration()
        let start = Date()
        live.handle.discard()
        await live.handle.settled()
        let elapsed = Date().timeIntervalSince(start)

        guard case .failure(.discarded) = try XCTUnwrap(live.result.first) else {
            return XCTFail("the request should report `.discarded`")
        }
        XCTAssertLessThan(elapsed, 20, "A discarded generation must unwind, not run to term")
    }

    #endif
}

/// Collects completions delivered on a background queue.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<String, AITransformError>] = []

    func append(_ result: Result<String, AITransformError>) {
        lock.lock(); results.append(result); lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return results.count }
    var first: Result<String, AITransformError>? {
        lock.lock(); defer { lock.unlock() }; return results.first
    }
}

private final class OrderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []

    func append(_ value: String) { lock.lock(); order.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return order }
}
