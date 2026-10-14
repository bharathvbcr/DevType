import XCTest
@testable import ExpanderEngine

/// The resolution cache used to publish whatever it had computed after dropping
/// `resolutionLock`. A language change in that gap — `didSet` clears the cache —
/// was then overwritten by the stale code. These tests block inside that gap.
final class LocalizationResolutionRaceTests: XCTestCase {

    private let key = "common.cancel"
    private var savedLanguage: String?

    override func setUp() {
        super.setUp()
        savedLanguage = UserDefaults.standard.string(forKey: LocalizationManager.deviceKey)
    }

    override func tearDown() {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: LocalizationManager.deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
        }
        super.tearDown()
    }

    private func makeManager(_ language: AppLanguage) -> LocalizationManager {
        let manager = LocalizationManager(pseudolocalize: false)
        manager.language = language
        manager.invalidateResolvedLanguage()
        return manager
    }

    private func tableValue(_ language: AppLanguage) throws -> String {
        try XCTUnwrap(
            LocalizationManager.stringTable(for: language)[key],
            "\(language.rawValue) has no \(key) in the resource table"
        )
    }

    /// Runs `body` on a background queue while the miss hook is blocked.
    /// `duringGap` runs on the test thread only after the hook has entered,
    /// and therefore while `resolutionLock` is not held by the resolver.
    private func resolveDuringGap(
        _ manager: LocalizationManager,
        duringGap: () -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var hookCalls = 0
        let callsLock = NSLock()
        manager.resolutionMissHookForTesting = {
            callsLock.lock()
            hookCalls += 1
            callsLock.unlock()
            entered.signal()
            release.wait()
        }

        let done = expectation(description: "racing resolution")
        var raced: String?
        DispatchQueue.global().async {
            raced = manager.s(self.key)
            done.fulfill()
        }

        let enteredInTime = entered.wait(timeout: .now() + 5) == .success
        if !enteredInTime {
            release.signal()
        }
        XCTAssertTrue(enteredInTime, "resolver did not reach the miss hook", file: file, line: line)
        if enteredInTime {
            duringGap()
        }
        release.signal()
        wait(for: [done], timeout: 5)

        callsLock.lock()
        let calls = hookCalls
        callsLock.unlock()
        XCTAssertEqual(calls, 1, "the miss hook ran \(calls) times", file: file, line: line)
        manager.resolutionMissHookForTesting = nil
        return try XCTUnwrap(raced, file: file, line: line)
    }

    func testLanguageChangeDuringMissDoesNotPublishTheStaleLanguage() throws {
        let english = try tableValue(.en)
        let korean = try tableValue(.ko)
        XCTAssertNotEqual(english, korean)

        let manager = makeManager(.en)
        XCTAssertNil(manager.cachedResolvedLanguageForTesting)

        let raced = try resolveDuringGap(manager) {
            manager.language = .ko
        }

        XCTAssertNotEqual(manager.cachedResolvedLanguageForTesting, .en)
        XCTAssertNil(
            manager.cachedResolvedLanguageForTesting,
            "the in-flight English resolution was published after the switch to Korean"
        )
        XCTAssertEqual(raced, korean, "the racer returned the stale English string")

        XCTAssertEqual(manager.s(key), korean)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .ko)
    }

    func testHookCanChangeLanguageWithoutDeadlocking() throws {
        let japanese = try tableValue(.ja)
        let english = try tableValue(.en)
        XCTAssertNotEqual(japanese, english)

        let manager = makeManager(.en)
        let done = expectation(description: "hook returned and resolution finished")
        var raced: String?
        manager.resolutionMissHookForTesting = {
            // `didSet` takes `resolutionLock`. Deadlocks if the miss still holds it.
            manager.language = .ja
        }
        DispatchQueue.global().async {
            raced = manager.s(self.key)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        manager.resolutionMissHookForTesting = nil

        XCTAssertEqual(raced, japanese)
        XCTAssertNotEqual(manager.cachedResolvedLanguageForTesting, .en)
        XCTAssertEqual(manager.s(key), japanese)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .ja)
    }

    func testConcurrentResolversOfTheSameLanguageFillTheCache() throws {
        let korean = try tableValue(.ko)
        let manager = makeManager(.ko)
        let done = expectation(description: "two resolvers")
        done.expectedFulfillmentCount = 2

        for _ in 0..<2 {
            DispatchQueue.global().async {
                XCTAssertEqual(manager.s(self.key), korean)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .ko)
    }

    func testSwitchingToSystemDuringGapDoesNotStoreThePreviousConcreteLanguage() throws {
        let korean = try tableValue(.ko)
        let manager = makeManager(.ko)

        let raced = try resolveDuringGap(manager) {
            manager.language = .system
        }

        XCTAssertNil(
            manager.cachedResolvedLanguageForTesting,
            "stored a concrete code computed from the previous explicit language"
        )
        XCTAssertNotEqual(manager.cachedResolvedLanguageForTesting, .ko)

        let systemCode = manager.effectiveLanguageCode()
        let systemLanguage = try XCTUnwrap(AppLanguage(rawValue: systemCode))
        XCTAssertNotEqual(systemLanguage, .system)
        let systemString = try XCTUnwrap(LocalizationManager.stringTable(for: systemLanguage)[key])
        XCTAssertEqual(raced, systemString)
        // The stale candidate was Korean. It must not have been what we returned
        // unless the live system resolution is also Korean.
        if systemLanguage != .ko {
            XCTAssertNotEqual(raced, korean)
        }

        XCTAssertNil(manager.cachedResolvedLanguageForTesting)
        _ = manager.s(key)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, systemLanguage)
    }

    func testSecondInvalidateInsideHookLeavesTheCacheEmpty() throws {
        let english = try tableValue(.en)
        let manager = makeManager(.en)

        let raced = try resolveDuringGap(manager) {
            manager.invalidateResolvedLanguage()
            manager.invalidateResolvedLanguage()
        }

        XCTAssertNil(
            manager.cachedResolvedLanguageForTesting,
            "invalidation during the gap republished the stale resolution"
        )
        XCTAssertEqual(raced, english, "explicit English is still the language to answer with")

        XCTAssertEqual(manager.s(key), english)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .en)
    }

    func testHookRunsOncePerMissAndNotOnACacheHit() throws {
        let english = try tableValue(.en)
        let manager = makeManager(.en)
        var calls = 0
        manager.resolutionMissHookForTesting = { calls += 1 }

        XCTAssertEqual(manager.s(key), english)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .en)

        XCTAssertEqual(manager.s(key), english)
        XCTAssertEqual(manager.p("stats.uses", count: 3, 3), manager.p("stats.uses", count: 3, 3))
        XCTAssertEqual(calls, 1, "a cache hit must not run the miss hook")

        manager.invalidateResolvedLanguage()
        XCTAssertEqual(manager.s(key), english)
        XCTAssertEqual(calls, 2, "a later miss must run the hook again")
    }
}
