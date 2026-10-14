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


    // MARK: - Bounds

    func testTimeoutReturnsWhileCancellationIgnoringEngineKeepsAdmission() async {
        let entered = expectation(description: "engine entered")
        let returned = expectation(description: "caller returned by deadline")
        let release = Sendable_AsyncGate()
        let operation = Task {
            let result = await PaletteToolRouter.route(
                query: "the date next friday",
                engine: { _ in
                    entered.fulfill()
                    await release.wait()
                    return "late answer"
                }, timeout: 0.02
            )
            XCTAssertNil(result)
            returned.fulfill()
        }
        await fulfillment(of: [entered], timeout: 1)
        await fulfillment(of: [returned], timeout: 0.5)
        let extraCalls = Sendable_Counter()
        for _ in 0..<100 {
            let result = await PaletteToolRouter.route(query: "the date next monday") { _ in
                extraCalls.increment()
                return "overlap"
            }
            XCTAssertNil(result)
        }
        XCTAssertEqual(extraCalls.value, 0, "Abandoned work must still occupy admission")
        release.signal()
        await operation.value
        // The uncooperative operation now finishes; give its actor cleanup a bounded turn.
        try? await Task.sleep(nanoseconds: 20_000_000)
        let recovered = await PaletteToolRouter.route(query: "the date next monday") { _ in "recovered" }
        XCTAssertEqual(recovered?.text, "recovered")
    }

    /// A model that never answers used to hold the single-flight latch for the rest of the
    /// session: every later keystroke found it busy and routing was dead, with no error
    /// surfaced anywhere. The timeout is what makes that recoverable.
    func testATimedOutCallReleasesTheLatch() async {
        let hung = await PaletteToolRouter.route(
            query: "the date next friday",
            engine: { _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return "never"
            },
            timeout: 0.3
        )
        XCTAssertNil(hung, "A call past the deadline must be abandoned, not awaited.")

        let after = await PaletteToolRouter.route(
            query: "the date next monday", engine: { _ in "2026-09-07" }
        )
        XCTAssertNotNil(after, "Routing must still work after a hung call.")
    }

    /// The deadline must not truncate a normal answer.
    func testAPromptAnswerIsNotAffectedByTheDeadline() async {
        let routed = await PaletteToolRouter.route(
            query: "the date next friday", engine: { _ in "2026-09-04" }, timeout: 5
        )
        XCTAssertEqual(routed?.text, "2026-09-04")
    }

    /// The panel cancels its routing task when it closes. That must not strand the latch.
    func testACancelledRouteDoesNotStrandTheLatch() async {
        let task = Task {
            await PaletteToolRouter.route(
                query: "the date next friday",
                engine: { _ in
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    return "never"
                },
                timeout: 9
            )
        }
        task.cancel()
        _ = await task.value

        let after = await PaletteToolRouter.route(
            query: "the date next monday", engine: { _ in "2026-09-07" }
        )
        XCTAssertNotNil(after, "A cancelled route must leave routing usable.")
    }

    /// Past the ranking cap a query is a paste, not a question — and a routed answer to an
    /// unclamped query could never match the clamped one `buildRows` compares against.
    func testAnOverlongQueryIsNotRouted() async {
        let huge = String(repeating: "a", count: CommandPaletteCatalog.maximumQueryCharacters + 1)
        XCTAssertFalse(PaletteToolRouter.shouldAttemptRouting(query: huge))

        let called = Sendable_Box()
        let routed = await PaletteToolRouter.route(query: huge) { _ in
            called.set()
            return "x"
        }
        XCTAssertNil(routed)
        XCTAssertFalse(called.value, "An overlong query must not reach the model.")
    }

    /// The latch must be released on both paths, or the first failure wedges routing for the
    /// rest of the session.
    func testLatchIsReleasedAfterAFailure() async {
        struct Boom: Error {}
        _ = await PaletteToolRouter.route(query: "the date next friday") { _ in throw Boom() }
        let after = await PaletteToolRouter.route(query: "the date next friday") { _ in "2026-09-04" }
        XCTAssertNotNil(after, "A failed route must not hold the latch.")
    }

    // MARK: - False success

    /// `bool(forKey:)` is false when the key was never written. Routing must stay off
    /// in that state even if the master AI switch is on. The production default is unchanged.
    func testSemanticRoutingIsOffWhenTheDefaultsKeyIsAbsent() {
        let key = AIPreferences.semanticRoutingEnabledKey
        let suiteName = "devtype.tests.palette-routing-absent-key"
        let suite = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(suite)
        suite?.removePersistentDomain(forName: suiteName)
        XCTAssertNil(suite?.object(forKey: key))
        XCTAssertFalse(suite?.bool(forKey: key) ?? true)

        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
        XCTAssertFalse(AIPreferences.isSemanticRoutingEnabled)
        AIPreferences.isEnabled = true
        XCTAssertFalse(
            PaletteToolRouter.shouldAttemptRouting(query: "date three weeks out"),
            "Absent semantic-routing key must not route, even when AI is enabled."
        )
    }

    func testExtractedDateAndMacroDecisionsFailClosed() {
        let phrases = [
            "",
            "   \n\t",
            "today",
            "..",
            "🎉",
            "not-a-date",
            "日期",
            String(repeating: "日", count: 80),
        ]
        for format in ["medium", "iso"] {
            let today = CommandPaletteCatalog.resolveDate(.offsetDays(0, format: format))
            for phrase in phrases {
                XCTAssertNil(CommandPaletteCatalog.parseTypedQuery(phrase), "parser fixture \(phrase.count)")
                XCTAssertNil(CommandPaletteCatalog.parseRelativeDayQuery(phrase), "parser fixture \(phrase.count)")
                let resolved = PaletteToolRouter.resolveDatePhrase(phrase: phrase, format: format)
                XCTAssertNotEqual(resolved, today, "miss must not be today (\(phrase.count) chars, \(format))")
                XCTAssertNil(resolved, "miss must not be a row (\(phrase.count) chars, \(format))")
            }
        }
        for phrase in ["+1d", "  +3w  ", "next friday"] {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = CommandPaletteCatalog.parseRelativeDayQuery(trimmed)
            XCTAssertNotNil(parsed, phrase)
            guard let parsed else { continue }
            let expected = CommandPaletteCatalog.resolveDate(
                .offsetDays(parsed.days, format: parsed.format)
            )
            XCTAssertEqual(
                PaletteToolRouter.resolveDatePhrase(phrase: phrase, format: "iso"),
                expected,
                phrase
            )
        }

        XCTAssertEqual(
            PaletteToolRouter.runMacro(operation: "uppercase", text: "ab"),
            PaletteTextOps.apply(.upper, to: "ab")
        )
        XCTAssertEqual(PaletteToolRouter.runMacro(operation: "  UpperCase  ", text: "ab"), "AB")
        XCTAssertEqual(
            PaletteToolRouter.runMacro(operation: "lowercase", text: "AB"),
            PaletteTextOps.apply(.lower, to: "AB")
        )
        XCTAssertEqual(PaletteToolRouter.runMacro(operation: "upper", text: "ab"), "AB")
        for op in PaletteTextOp.allCases {
            XCTAssertEqual(PaletteTextOp.resolved(from: op.rawValue), op)
            XCTAssertEqual(PaletteTextOp.resolved(from: " \(op.rawValue.uppercased()) "), op)
        }
        let hostile = ["", "   ", "..", "no-such-op", "lorem", "uuid", "password", "🎉"]
        for operation in hostile {
            XCTAssertNil(PaletteTextOp.resolved(from: operation), operation)
            XCTAssertNil(PaletteToolRouter.runMacro(operation: operation, text: "ab"), operation)
            XCTAssertNotEqual(
                PaletteToolRouter.runMacro(operation: operation, text: "ab"),
                "ab",
                operation
            )
        }
        let longID = String(repeating: "op", count: 4_000)
        XCTAssertNil(PaletteToolRouter.runMacro(operation: longID, text: "ab"))
        XCTAssertNotEqual(PaletteToolRouter.runMacro(operation: longID, text: "ab"), "ab")
    }

    func testAPhraseNeitherParserAcceptsIsNotToday() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models tool API requires macOS 26")
        }
        let tool = PaletteToolRouter.ResolveDateTool()
        let phrases = [
            "",
            "   \n\t",
            "today",
            "..",
            "🎉",
            "not-a-date",
            "日期",
            String(repeating: "日", count: 80),
        ]
        for format in ["medium", "iso"] {
            let today = CommandPaletteCatalog.resolveDate(.offsetDays(0, format: format))
            for phrase in phrases {
                XCTAssertNil(CommandPaletteCatalog.parseTypedQuery(phrase))
                XCTAssertNil(CommandPaletteCatalog.parseRelativeDayQuery(phrase))
                let result = try? await tool.call(arguments: .init(phrase: phrase, format: format))
                XCTAssertEqual(result, PaletteToolRouter.resolveDatePhrase(phrase: phrase, format: format))
                XCTAssertNotEqual(result, today, "miss must not be today (\(phrase.count) chars, \(format))")
                XCTAssertNil(result, "A parser miss must not become a row (\(phrase.count) chars, \(format))")
            }
        }
        #else
        throw XCTSkip("Foundation Models SDK unavailable")
        #endif
    }

    func testAPhraseTheParsersAcceptMatchesTheCatalogDate() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models tool API requires macOS 26")
        }
        let tool = PaletteToolRouter.ResolveDateTool()
        for phrase in ["+1d", "  +3w  ", "next friday"] {
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = try XCTUnwrap(
                CommandPaletteCatalog.parseRelativeDayQuery(trimmed),
                "fixture must be a phrase the parser accepts: \(phrase)"
            )
            let expected = CommandPaletteCatalog.resolveDate(
                .offsetDays(parsed.days, format: parsed.format)
            )
            let result = try await tool.call(arguments: .init(phrase: phrase, format: "iso"))
            XCTAssertEqual(result, PaletteToolRouter.resolveDatePhrase(phrase: phrase, format: "iso"))
            XCTAssertEqual(result, expected, phrase)
            XCTAssertNotEqual(
                result,
                CommandPaletteCatalog.resolveDate(.offsetDays(0, format: "iso")),
                "A hit must not be rewritten as today in the tool's format."
            )
        }
        #else
        throw XCTSkip("Foundation Models SDK unavailable")
        #endif
    }

    func testUppercaseMatchesUpperAndUnknownIdsDoNotEcho() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models tool API requires macOS 26")
        }
        let tool = PaletteToolRouter.RunMacroTool()
        let upper = try await tool.call(arguments: .init(operation: "uppercase", text: "ab"))
        XCTAssertEqual(upper, PaletteToolRouter.runMacro(operation: "uppercase", text: "ab"))
        XCTAssertEqual(upper, PaletteTextOps.apply(.upper, to: "ab"))
        XCTAssertEqual(upper, "AB")
        XCTAssertNotEqual(upper, "ab")

        let mixed = try await tool.call(arguments: .init(operation: "  UpperCase  ", text: "ab"))
        XCTAssertEqual(mixed, "AB")
        let raw = try await tool.call(arguments: .init(operation: "upper", text: "ab"))
        XCTAssertEqual(raw, PaletteTextOps.apply(.upper, to: "ab"))
        let lower = try await tool.call(arguments: .init(operation: "lowercase", text: "AB"))
        XCTAssertEqual(lower, PaletteTextOps.apply(.lower, to: "AB"))
        XCTAssertEqual(lower, "ab")

        let hostile = [
            "",
            "   ",
            "..",
            "no-such-op",
            "lorem",
            "🎉",
            String(repeating: "op", count: 4_000),
        ]
        for operation in hostile {
            let result = try? await tool.call(arguments: .init(operation: operation, text: "ab"))
            XCTAssertEqual(result, PaletteToolRouter.runMacro(operation: operation, text: "ab"))
            XCTAssertNotEqual(result, "ab", "unknown id must not echo input (\(operation.count) chars)")
            XCTAssertNil(result, "unknown id \(operation.count) chars")
        }
        #else
        throw XCTSkip("Foundation Models SDK unavailable")
        #endif
    }

    func testEachToolReportsItsOwnNameBeforeReturning() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models tool API requires macOS 26")
        }
        let names = Sendable_List()
        let date = PaletteToolRouter.ResolveDateTool(onCall: { names.append($0) })
        _ = try? await date.call(arguments: .init(phrase: "today", format: "medium"))
        XCTAssertEqual(names.values, ["resolveDate"])

        let macro = PaletteToolRouter.RunMacroTool(onCall: { names.append($0) })
        _ = try? await macro.call(arguments: .init(operation: "no-such-op", text: "ab"))
        XCTAssertEqual(names.values, ["resolveDate", "runMacro"])

        let snippets = PaletteToolRouter.FindSnippetTool(
            groupsProvider: { [] },
            onCall: { names.append($0) }
        )
        let found = try await snippets.call(arguments: .init(query: "anything"))
        XCTAssertEqual(found, "")
        XCTAssertEqual(names.values, ["resolveDate", "runMacro", "findSnippet"])
        #else
        throw XCTSkip("Foundation Models SDK unavailable")
        #endif
    }
}

/// Minimal thread-safe boxes so the async tests above can observe engine calls.
final class Sendable_Box: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

final class Sendable_List: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return items }
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
