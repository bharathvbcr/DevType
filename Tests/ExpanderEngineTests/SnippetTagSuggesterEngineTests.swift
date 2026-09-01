import XCTest
@testable import ExpanderEngine

/// `SnippetTagSuggester.suggest` — the composition around the model call.
///
/// The model itself needs macOS 26 and on-device assets, so it stays out of reach. Everything
/// else did too, purely because it lived in the same function: the two preference gates, the
/// secret refusal, the eligibility floor, the single-flight latch, and the rule that every
/// failure degrades to "no suggestion" rather than an error. A `TaggingEngine` seam at the one
/// step that genuinely needs hardware makes the rest ordinary code under test.
final class SnippetTagSuggesterEngineTests: XCTestCase {

    // MARK: - Preferences

    private var savedMaster: Any?
    private var savedOwn: Any?

    override func setUp() {
        super.setUp()
        savedMaster = UserDefaults.standard.object(forKey: AIPreferences.enabledKey)
        savedOwn = UserDefaults.standard.object(forKey: SnippetTagSuggester.enabledKey)
        UserDefaults.standard.set(true, forKey: AIPreferences.enabledKey)
        UserDefaults.standard.set(true, forKey: SnippetTagSuggester.enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedMaster, forKey: AIPreferences.enabledKey)
        UserDefaults.standard.set(savedOwn, forKey: SnippetTagSuggester.enabledKey)
        super.tearDown()
    }

    // MARK: - Helpers

    private let body = "Thanks for the invoice — it is approved and scheduled for payment."

    /// Records the prompt it was handed and returns a canned answer.
    private final class EngineSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _prompts: [String] = []
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }
        var callCount: Int { prompts.count }

        var result: Result<SnippetTagSuggester.RawTagging, any Error>
        /// Runs while the engine is "in flight", for the latch test.
        var duringCall: (@Sendable () async -> Void)?

        init(tags: [String] = ["invoice"], group: String? = nil) {
            result = .success(SnippetTagSuggester.RawTagging(tags: tags, group: group))
        }

        func engine() -> SnippetTagSuggester.TaggingEngine {
            { [self] prompt in
                lock.lock(); _prompts.append(prompt); lock.unlock()
                await duringCall?()
                return try result.get()
            }
        }
    }

    private func suggest(
        engine: SnippetTagSuggester.TaggingEngine?,
        title: String = "Invoice reply",
        body: String? = nil,
        isSecret: Bool = false,
        existingTags: [String] = [],
        groupNames: [String] = []
    ) async -> SnippetTagSuggester.Suggestion {
        await SnippetTagSuggester.suggest(
            title: title,
            body: body ?? self.body,
            isSecret: isSecret,
            existingTags: existingTags,
            groupNames: groupNames,
            engine: engine
        )
    }

    // MARK: - Nothing reaches the model unless it should

    func testNoEngineMeansNoSuggestion() async {
        let result = await suggest(engine: nil)
        XCTAssertEqual(result, .none)
    }

    func testTheMasterAISwitchVetoesBeforeTheModelIsCalled() async {
        UserDefaults.standard.set(false, forKey: AIPreferences.enabledKey)
        let spy = EngineSpy()
        let result = await suggest(engine: spy.engine())
        XCTAssertEqual(result, .none)
        XCTAssertEqual(spy.callCount, 0, "a disabled feature must not spend model time")
    }

    func testTheFeatureSwitchVetoesBeforeTheModelIsCalled() async {
        UserDefaults.standard.set(false, forKey: SnippetTagSuggester.enabledKey)
        let spy = EngineSpy()
        _ = await suggest(engine: spy.engine())
        XCTAssertEqual(spy.callCount, 0)
    }

    /// The one that matters most: a secret's body is the secret, and it must never be sent.
    func testASecretBodyNeverReachesTheModel() async {
        let spy = EngineSpy()
        let result = await suggest(engine: spy.engine(), body: "hunter2-hunter2-hunter2-hunter2", isSecret: true)
        XCTAssertEqual(result, .none)
        XCTAssertEqual(spy.callCount, 0)
        XCTAssertTrue(spy.prompts.isEmpty, "no prompt should have been built at all")
    }

    func testABodyBelowTheEligibilityFloorNeverReachesTheModel() async {
        let spy = EngineSpy()
        _ = await suggest(engine: spy.engine(), body: "too short")
        XCTAssertEqual(spy.callCount, 0)
    }

    // MARK: - What the model is told

    func testThePromptCarriesTheGroupsAndTheBody() async {
        let spy = EngineSpy()
        _ = await suggest(engine: spy.engine(), groupNames: ["Work", "Personal"])
        let prompt = try? XCTUnwrap(spy.prompts.first)
        XCTAssertTrue(prompt?.contains("Work") == true)
        XCTAssertTrue(prompt?.contains("Personal") == true)
        XCTAssertTrue(prompt?.contains("invoice") == true)
    }

    // MARK: - Nothing the model returns is trusted

    func testModelOutputIsNormalizedBeforeItIsReturned() async {
        let spy = EngineSpy(tags: ["Invoice", "billing;urgent", "  Payment  Terms ", "invoice"])
        let result = await suggest(engine: spy.engine())
        XCTAssertEqual(
            result.tags,
            ["invoice", "payment terms"],
            "case-folded, delimiter-bearing dropped, duplicate removed"
        )
    }

    func testExistingTagsAreExcludedFromTheSuggestion() async {
        let spy = EngineSpy(tags: ["invoice", "billing"])
        let result = await suggest(engine: spy.engine(), existingTags: ["invoice"])
        XCTAssertEqual(result.tags, ["billing"])
    }

    func testAnInventedGroupIsRefused() async {
        let spy = EngineSpy(tags: ["invoice"], group: "Invoices")
        let result = await suggest(engine: spy.engine(), groupNames: ["Work", "Personal"])
        XCTAssertNil(result.groupName, "the model cannot create a group by naming one")
    }

    func testAKnownGroupComesBackInTheLibrarySpelling() async {
        let spy = EngineSpy(tags: ["invoice"], group: "work")
        let result = await suggest(engine: spy.engine(), groupNames: ["Work", "Personal"])
        XCTAssertEqual(result.groupName, "Work")
    }

    // MARK: - Every failure is just "no suggestion"

    func testAThrowingEngineDegradesToNoSuggestion() async {
        struct Refused: Error {}
        let spy = EngineSpy()
        spy.result = .failure(Refused())
        let result = await suggest(engine: spy.engine())
        XCTAssertEqual(result, .none, "a refusal is not an error worth showing anyone")
    }

    func testACancelledEngineDegradesToNoSuggestion() async {
        let spy = EngineSpy()
        spy.result = .failure(CancellationError())
        let result = await suggest(engine: spy.engine())
        XCTAssertEqual(result, .none)
    }

    func testAnEmptyModelAnswerIsAnEmptySuggestion() async {
        let spy = EngineSpy(tags: [], group: nil)
        let result = await suggest(engine: spy.engine())
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Single flight

    /// Two editors open at once must not both drive the model. The second call is dropped rather
    /// than queued: its answer would arrive against a body the user has since rewritten.
    func testASecondSuggestionIsDroppedWhileOneIsInFlight() async {
        let firstEntered = expectation(description: "first call entered the engine")
        let releaseFirst = expectation(description: "first call may finish")

        let slow = EngineSpy(tags: ["first"])
        slow.duringCall = { @Sendable in
            firstEntered.fulfill()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { continuation.resume() }
            }
        }
        let fast = EngineSpy(tags: ["second"])

        async let firstResult = suggest(engine: slow.engine())
        await fulfillment(of: [firstEntered], timeout: 5)

        let secondResult = await suggest(engine: fast.engine())
        XCTAssertEqual(secondResult, .none, "the latch must drop the overlapping request")
        XCTAssertEqual(fast.callCount, 0, "and must drop it before spending model time")

        releaseFirst.fulfill()
        await fulfillment(of: [releaseFirst], timeout: 1)
        let first = await firstResult
        XCTAssertEqual(first.tags, ["first"], "the in-flight request still completes normally")
    }

    /// And the latch must be released afterwards, or one suggestion would poison the session.
    func testTheLatchIsReleasedAfterACall() async {
        let spy = EngineSpy(tags: ["invoice"])
        _ = await suggest(engine: spy.engine())
        // Give the deferred release a turn.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let second = await suggest(engine: spy.engine())
        XCTAssertEqual(second.tags, ["invoice"], "a later suggestion must still be able to run")
    }

    /// Including after a failure — the release is in a `defer`, and losing it there would be
    /// silent and permanent.
    func testTheLatchIsReleasedAfterAThrow() async {
        struct Refused: Error {}
        let failing = EngineSpy()
        failing.result = .failure(Refused())
        _ = await suggest(engine: failing.engine())
        try? await Task.sleep(nanoseconds: 50_000_000)

        let ok = EngineSpy(tags: ["invoice"])
        let result = await suggest(engine: ok.engine())
        XCTAssertEqual(result.tags, ["invoice"], "a thrown call must not strand the latch")
    }
}
