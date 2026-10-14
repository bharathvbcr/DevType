import XCTest
@testable import ExpanderEngine

/// Hostile interleavings around the post-miss publication check.
/// A candidate may be stored only when the cache is still empty and both the
/// language and the resolution epoch captured at the miss are unchanged.
final class LocalizationResolutionAttackTests: XCTestCase {

    private let key = "common.cancel"
    private let appleLanguagesKey = "AppleLanguages"
    private var savedLanguage: String?
    private var savedAppleLanguages: Any?

    override func setUp() {
        super.setUp()
        savedLanguage = UserDefaults.standard.string(forKey: LocalizationManager.deviceKey)
        savedAppleLanguages = UserDefaults.standard.object(forKey: appleLanguagesKey)
    }

    override func tearDown() {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: LocalizationManager.deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
        }
        if let savedAppleLanguages {
            UserDefaults.standard.set(savedAppleLanguages, forKey: appleLanguagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
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

    /// `s` on a background queue so a lock taken from the miss hook fails the
    /// test at 5s instead of hanging the runner.
    private func lookup(
        _ manager: LocalizationManager,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let done = expectation(description: "localized lookup")
        var value: String?
        DispatchQueue.global().async {
            value = manager.s(self.key)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(value, "lookup did not finish within 5s", file: file, line: line)
    }

    func testHookFlipThroughKoreanDoesNotCacheEnglish() throws {
        let english = try tableValue(.en)
        let korean = try tableValue(.ko)
        let japanese = try tableValue(.ja)
        XCTAssertNotEqual(english, korean)
        XCTAssertNotEqual(korean, japanese)

        let manager = makeManager(.en)
        manager.resolutionMissHookForTesting = {
            manager.language = .ko
            manager.language = .ja
        }
        let raced = try lookup(manager)
        manager.resolutionMissHookForTesting = nil

        XCTAssertEqual(raced, japanese)
        XCTAssertNotEqual(manager.cachedResolvedLanguageForTesting, .en)
        XCTAssertNotEqual(
            manager.cachedResolvedLanguageForTesting,
            .ko,
            "the in-flight resolver published an intermediate language"
        )

        XCTAssertEqual(manager.s(key), japanese)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .ja)
    }

    func testSameValueAssignmentInHookDoesNotPublishTheStaleCandidate() throws {
        let english = try tableValue(.en)
        let manager = makeManager(.en)
        let didSetLock = NSLock()
        var didSetRan = false
        let observer = NotificationCenter.default.addObserver(
            forName: .devTypeLanguageChanged,
            object: nil,
            queue: nil
        ) { _ in
            didSetLock.lock()
            didSetRan = true
            didSetLock.unlock()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.resolutionMissHookForTesting = {
            // Same value. `didSet` still invalidates and bumps the epoch.
            manager.language = .en
        }
        let raced = try lookup(manager)
        manager.resolutionMissHookForTesting = nil

        didSetLock.lock()
        let observedDidSet = didSetRan
        didSetLock.unlock()
        XCTAssertTrue(observedDidSet, "same-value assignment did not run language didSet")
        XCTAssertEqual(raced, english)
        XCTAssertNil(
            manager.cachedResolvedLanguageForTesting,
            "invalidation during the miss still published the in-flight English candidate"
        )

        XCTAssertEqual(manager.s(key), english)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .en)
    }

    func testSystemCandidateIsNotStoredWhenHookSelectsAnotherLanguage() throws {
        let manager = makeManager(.system)
        let systemCode = manager.effectiveLanguageCode()
        let systemLanguage = try XCTUnwrap(
            AppLanguage(rawValue: systemCode),
            "system mode resolved to \(systemCode), which is not a concrete language"
        )
        XCTAssertNotEqual(systemLanguage, .system)
        let hookLanguage: AppLanguage = systemLanguage == .ja ? .en : .ja
        XCTAssertNotEqual(hookLanguage, systemLanguage)
        let hookString = try tableValue(hookLanguage)

        manager.resolutionMissHookForTesting = {
            manager.language = hookLanguage
        }
        let raced = try lookup(manager)
        manager.resolutionMissHookForTesting = nil

        XCTAssertEqual(raced, hookString)
        let cached = manager.cachedResolvedLanguageForTesting
        XCTAssertNotEqual(
            cached,
            systemLanguage,
            "stored the concrete code Locale.preferredLanguages produced for .system"
        )
        XCTAssertTrue(
            cached == nil || cached == hookLanguage,
            "cache was \(String(describing: cached)) after the hook selected \(hookLanguage)"
        )

        XCTAssertEqual(manager.s(key), hookString)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, hookLanguage)
    }

    func testInFlightResolverDoesNotOverwriteAConcurrentPublication() throws {
        let english = try tableValue(.en)
        let japanese = try tableValue(.ja)
        XCTAssertNotEqual(english, japanese)

        let manager = makeManager(.en)
        let entered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let state = NSLock()
        var firstHook = true

        manager.resolutionMissHookForTesting = {
            state.lock()
            let isFirst = firstHook
            if isFirst { firstHook = false }
            state.unlock()
            guard isFirst else { return }
            manager.language = .ja
            manager.invalidateResolvedLanguage()
            entered.signal()
            releaseFirst.wait()
        }

        let firstDone = expectation(description: "first resolver finished")
        var firstResult: String?
        DispatchQueue.global().async {
            firstResult = manager.s(self.key)
            firstDone.fulfill()
        }

        let enteredInTime = entered.wait(timeout: .now() + 5) == .success
        if !enteredInTime {
            releaseFirst.signal()
        }
        XCTAssertTrue(enteredInTime, "first resolver did not reach the miss hook")

        var secondResult: String?
        if enteredInTime {
            let secondDone = expectation(description: "second resolver published")
            DispatchQueue.global().async {
                secondResult = manager.s(self.key)
                secondDone.fulfill()
            }
            wait(for: [secondDone], timeout: 5)
            XCTAssertEqual(secondResult, japanese)
            XCTAssertEqual(
                manager.cachedResolvedLanguageForTesting,
                .ja,
                "the second resolver did not publish Japanese before the first relocked"
            )
        }

        releaseFirst.signal()
        wait(for: [firstDone], timeout: 5)
        manager.resolutionMissHookForTesting = nil

        XCTAssertEqual(firstResult, japanese, "the first resolver returned the stale English string")
        XCTAssertEqual(
            manager.cachedResolvedLanguageForTesting,
            .ja,
            "the first resolver overwrote the language the second thread published"
        )
        XCTAssertEqual(manager.language, .ja)
    }

    func testConcurrentLookupsWhileLanguageTogglesStayInsideTheTables() throws {
        let english = try tableValue(.en)
        let korean = try tableValue(.ko)
        let japanese = try tableValue(.ja)
        XCTAssertNotEqual(english, korean)
        XCTAssertNotEqual(korean, japanese)
        XCTAssertNotEqual(japanese, english)
        let allowed: Set<String> = [english, korean, japanese]
        let cycle: [AppLanguage] = [.en, .ko, .ja]

        let manager = makeManager(.en)
        let resultsLock = NSLock()
        var results: [String] = []
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let lookupsPerThread = 40
        let toggles = 120

        for _ in 0..<20 {
            group.enter()
            queue.async {
                defer { group.leave() }
                var local: [String] = []
                local.reserveCapacity(lookupsPerThread)
                for _ in 0..<lookupsPerThread {
                    local.append(manager.s(self.key))
                }
                resultsLock.lock()
                results.append(contentsOf: local)
                resultsLock.unlock()
            }
        }
        group.enter()
        queue.async {
            defer { group.leave() }
            for index in 0..<toggles {
                manager.language = cycle[index % cycle.count]
            }
        }

        let outcome = group.wait(timeout: .now() + 5)
        XCTAssertEqual(outcome, .success, "resolvers or the language toggler did not finish within 5s")
        guard outcome == .success else { return }

        XCTAssertEqual(results.count, 20 * lookupsPerThread)
        let offenders = results.filter { !allowed.contains($0) }
        XCTAssertTrue(
            offenders.isEmpty,
            "lookup returned \(offenders.prefix(5)) outside the en/ko/ja tables"
        )

        let last = manager.language
        XCTAssertEqual(manager.s(key), try tableValue(last))
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, last)
    }

    func testEmptyPreferredLanguagesResolveToEnglish() throws {
        let english = try tableValue(.en)
        UserDefaults.standard.set([String](), forKey: appleLanguagesKey)
        guard Locale.preferredLanguages.isEmpty else {
            XCTFail("could not force an empty Locale.preferredLanguages list")
            return
        }

        let manager = makeManager(.system)
        XCTAssertEqual(manager.effectiveLanguageCode(), AppLanguage.en.rawValue)
        XCTAssertEqual(manager.s(key), english)
        XCTAssertEqual(manager.language, .system)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .en)

        XCTAssertEqual(manager.s(key), english)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .en)
    }

    func testClearingPreferredLanguagesDuringMissDoesNotPublishTheOldCode() throws {
        let english = try tableValue(.en)
        let korean = try tableValue(.ko)
        XCTAssertNotEqual(english, korean)

        UserDefaults.standard.set(["ko-KR"], forKey: appleLanguagesKey)
        XCTAssertEqual(Locale.preferredLanguages.first?.lowercased().hasPrefix("ko"), true)

        let manager = makeManager(.system)
        XCTAssertEqual(manager.effectiveLanguageCode(), AppLanguage.ko.rawValue)

        manager.resolutionMissHookForTesting = {
            // Writing AppleLanguages does not post the locale notification, so
            // do what that observer does: retire the in-flight candidate.
            UserDefaults.standard.set([String](), forKey: self.appleLanguagesKey)
            NotificationCenter.default.post(
                name: NSLocale.currentLocaleDidChangeNotification,
                object: nil
            )
        }
        let raced = try lookup(manager)
        manager.resolutionMissHookForTesting = nil

        XCTAssertEqual(raced, english, "answered with the Korean code captured before the list was cleared")
        XCTAssertNotEqual(manager.cachedResolvedLanguageForTesting, .ko)
        XCTAssertNil(
            manager.cachedResolvedLanguageForTesting,
            "published a candidate after the locale observer invalidated it"
        )

        XCTAssertEqual(manager.s(key), english)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .en)
    }

    /// A hit's effect is observable. `Locale.preferredLanguages` itself is not:
    /// it does not go through `NSLocale.preferredLanguages`, so a swizzle cannot
    /// count calls. This checks that a hit does not follow a new list.
    func testCacheHitDoesNotFollowALaterPreferredLanguageChange() throws {
        let korean = try tableValue(.ko)
        let japanese = try tableValue(.ja)
        XCTAssertNotEqual(korean, japanese)

        UserDefaults.standard.set(["ko-KR"], forKey: appleLanguagesKey)
        let manager = makeManager(.system)
        XCTAssertEqual(manager.s(key), korean)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .ko)

        UserDefaults.standard.set(["ja-JP"], forKey: appleLanguagesKey)
        XCTAssertEqual(Locale.preferredLanguages.first?.lowercased().hasPrefix("ja"), true)
        XCTAssertEqual(
            manager.s(key),
            korean,
            "a cache hit followed a preferred-language change that did not invalidate"
        )
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .ko)

        manager.invalidateResolvedLanguage()
        XCTAssertEqual(manager.s(key), japanese)
        XCTAssertEqual(manager.cachedResolvedLanguageForTesting, .ja)
    }
}
