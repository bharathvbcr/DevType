import XCTest
@testable import ExpanderEngine

/// On-device palette routing.
///
/// The tool definitions existed but nothing ever called them: only the debounce *constant*
/// was referenced anywhere in the app, so `shouldAttemptRouting`, `makeTools` and the three
/// tools were dead, and `AIPreferences.isSemanticRoutingEnabled` was a preference that could
/// not change any behaviour. These tests cover everything except the model call itself, which
/// is injected — the same split `SnippetTagSuggester` uses.
final class PaletteToolRoutingTests: XCTestCase {

    private var savedAI = false
    private var savedRouting = false

    override func setUp() {
        super.setUp()
        savedAI = AIPreferences.isEnabled
        savedRouting = AIPreferences.isSemanticRoutingEnabled
        AIPreferences.isEnabled = true
        AIPreferences.isSemanticRoutingEnabled = true
    }

    override func tearDown() {
        AIPreferences.isEnabled = savedAI
        AIPreferences.isSemanticRoutingEnabled = savedRouting
        super.tearDown()
    }

    // MARK: - Gates

    func testRoutingIsOffUnlessBothSwitchesAreOn() {
        AIPreferences.isSemanticRoutingEnabled = false
        XCTAssertFalse(PaletteToolRouter.shouldAttemptRouting(query: "date three weeks out"))

        AIPreferences.isSemanticRoutingEnabled = true
        AIPreferences.isEnabled = false
        XCTAssertFalse(
            PaletteToolRouter.shouldAttemptRouting(query: "date three weeks out"),
            "The master AI switch must still gate routing."
        )
    }

    func testDeterministicPrefixesAndShortQueriesAreNotRouted() {
        XCTAssertFalse(PaletteToolRouter.shouldAttemptRouting(query: "=2+2"))
        XCTAssertFalse(PaletteToolRouter.shouldAttemptRouting(query: "> upper"))
        XCTAssertFalse(PaletteToolRouter.shouldAttemptRouting(query: "abc"))
        XCTAssertTrue(PaletteToolRouter.shouldAttemptRouting(query: "uppercase what I copied"))
    }

    func testNilEngineRoutesToNothing() async {
        let routed = await PaletteToolRouter.route(query: "uppercase what I copied", engine: nil)
        XCTAssertNil(routed, "No model available must be a quiet no-op, not an error row.")
    }

    func testAGatedQueryNeverReachesTheEngine() async {
        AIPreferences.isSemanticRoutingEnabled = false
        let called = Sendable_Box()
        let routed = await PaletteToolRouter.route(query: "uppercase what I copied") { _ in
            called.set()
            return "NOPE"
        }
        XCTAssertNil(routed)
        XCTAssertFalse(called.value, "A gated query must not spend a model round trip.")
    }

    // MARK: - Trust boundary

    /// The tools resolve through real code, so a tool *result* is always real. This guards the
    /// other path: a model that wrote prose instead of calling a tool.
    func testProseAndOverlongOutputAreRefused() {
        XCTAssertNil(PaletteToolRouter.sanitize("  "))
        XCTAssertNil(PaletteToolRouter.sanitize("line one\nline two"))
        XCTAssertNil(PaletteToolRouter.sanitize(
            String(repeating: "x", count: PaletteToolRouter.maximumResultCharacters + 1)
        ))
        XCTAssertEqual(PaletteToolRouter.sanitize("  2026-09-22  "), "2026-09-22")
    }

    func testRefusedOutputProducesNoRow() async {
        let routed = await PaletteToolRouter.route(query: "what is the date") { _ in
            "Sure! Here is what I found:\nThe date is..."
        }
        XCTAssertNil(routed, "Multi-line prose is the model ignoring the tools, not an answer.")
    }

    func testEngineFailureIsSwallowed() async {
        struct Boom: Error {}
        let routed = await PaletteToolRouter.route(query: "what is the date") { _ in throw Boom() }
        XCTAssertNil(routed)
    }

    // MARK: - Staleness

    /// Routing is debounced and asynchronous, so an answer usually lands after the user has
    /// typed more. The result carries the query it answered so a stale row can be dropped.
    func testResultCarriesTheQueryItAnswered() async {
        let routed = await PaletteToolRouter.route(query: "  the date next friday  ") { _ in
            "2026-09-04"
        }
        XCTAssertEqual(routed?.query, "the date next friday", "Query is carried, trimmed.")
        XCTAssertEqual(routed?.text, "2026-09-04")
    }

    func testAStaleRoutedAnswerIsNotShown() {
        let stale = PaletteToolRouter.Routed(query: "the date next friday", text: "2026-09-04")
        let rows = CommandPaletteCatalog.buildRows(
            query: "something else entirely",
            groups: [],
            loc: .shared,
            routedResult: stale
        )
        XCTAssertFalse(
            rows.contains { row in
                if case .command(let hit) = row { return hit.command.id.hasPrefix("routed.") }
                return false
            },
            "A row answering an older query must not be shown against current text."
        )
    }

    func testAFreshRoutedAnswerLeadsTheCommandSection() {
        CommandPaletteCatalog.invalidateCache()
        let fresh = PaletteToolRouter.Routed(query: "the date next friday", text: "2026-09-04")
        let rows = CommandPaletteCatalog.buildRows(
            query: "the date next friday",
            groups: [],
            loc: .shared,
            routedResult: fresh
        )
        let firstCommand = rows.compactMap { row -> PaletteCommandHit? in
            if case .command(let hit) = row { return hit }
            return nil
        }.first
        XCTAssertEqual(firstCommand?.command.id, "routed.the date next friday")
        XCTAssertEqual(firstCommand?.insertText, "2026-09-04", "The row must insert the resolved text.")
        CommandPaletteCatalog.invalidateCache()
    }

    /// A routed row commits through the existing `.insert` action, so it cannot reach anything
    /// a `=` math result could not.
    func testRoutedRowUsesTheInsertAction() {
        let hit = CommandPaletteCatalog.routedHit(
            PaletteToolRouter.Routed(query: "q", text: "value"), loc: .shared
        )
        XCTAssertEqual(hit.command.action, .insert)
        XCTAssertEqual(hit.insertText, "value")
        XCTAssertTrue(hit.command.isEphemeral)
    }

    /// Rows built from the query text carry an id that is unique per keystroke and resolves to
    /// nothing in the catalogue. Recording usage against them wrote an entry per distinct
    /// expression typed — a stats file growing without bound, full of rows nothing can rank.
    func testQueryBuiltRowsAreMarkedEphemeral() {
        for query in ["=2+2", "+3w", "date+1"] {
            let hits = CommandPaletteCatalog.matchCommands(query: query, loc: .shared)
            guard let hit = hits.first else {
                XCTFail("no hits for \(query)")
                continue
            }
            XCTAssertTrue(
                hit.command.isEphemeral,
                "\(query) → \(hit.command.id) is built from the query and must be ephemeral."
            )
        }
        let catalogue = CommandPaletteCatalog.matchCommands(query: "upper", loc: .shared)
        XCTAssertEqual(catalogue.first?.command.isEphemeral, false, "Catalogue rows must still be counted.")
    }

    // MARK: - Single flight

    /// Routing must never stack model calls behind a fast typist, nor compete with a transform
    /// the user explicitly asked for.
    func testConcurrentRoutingIsSerialized() async {
        let counter = Sendable_Counter()
        let firstEntered = Sendable_AsyncGate()
        let releaseFirst = Sendable_AsyncGate()
        async let a = PaletteToolRouter.route(query: "the date next friday") { _ in
            counter.increment()
            firstEntered.signal()
            await releaseFirst.wait()
            try? await Task.sleep(nanoseconds: 40_000_000)
            return "2026-09-04"
        }

        await firstEntered.wait()

        async let b = PaletteToolRouter.route(query: "the date next monday") { _ in
            counter.increment()
            return "2026-09-07"
        }

        let secondResult = await b
        XCTAssertNil(secondResult, "The latch must drop the overlapping call.")
        XCTAssertEqual(counter.value, 1, "Only one call may reach the model.")

        releaseFirst.signal()
        let firstResult = await a
        XCTAssertNotNil(firstResult, "The in-flight call still completes normally.")
    }

    /// The latch must be released on both paths, or the first failure wedges routing for the
    /// rest of the session.
    func testLatchIsReleasedAfterAFailure() async {
        struct Boom: Error {}
        _ = await PaletteToolRouter.route(query: "the date next friday") { _ in throw Boom() }
        let after = await PaletteToolRouter.route(query: "the date next friday") { _ in "2026-09-04" }
        XCTAssertNotNil(after, "A failed route must not hold the latch.")
    }
}

/// Minimal thread-safe boxes so the async tests above can observe engine calls.
final class Sendable_Box: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

final class Sendable_Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class Sendable_AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if signaled {
                signaled = false
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        let continuation = waiter
        waiter = nil
        if continuation == nil {
            signaled = true
        }
        lock.unlock()
        continuation?.resume()
    }
}
