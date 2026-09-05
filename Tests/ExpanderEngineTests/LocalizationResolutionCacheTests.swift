import XCTest
@testable import ExpanderEngine

/// `LocalizationManager.lookup` resolved the UI language on every call, and in the default
/// `.system` mode that walks `Locale.preferredLanguages` — a CFPreferences read returning fresh
/// strings, measured at 783 ns, guarding a 16 ns dictionary lookup. With 1,518 `s(…)` call sites
/// the resolution dominated every bulk fetch.
///
/// The resolution is now cached. These tests pin what the cache must not break: switching
/// language still switches strings, plural selection still follows the resolved language, and
/// the cache is safe to read from the threads that actually read it.
final class LocalizationResolutionCacheTests: XCTestCase {

    private func makeManager() -> LocalizationManager {
        let manager = LocalizationManager()
        manager.language = .en
        return manager
    }

    // MARK: - The cache still tracks the language

    func testSwitchingLanguageChangesStringsImmediately() {
        let manager = makeManager()
        let english = manager.s("common.cancel")

        manager.language = .ko
        let korean = manager.s("common.cancel")
        XCTAssertNotEqual(korean, english, "the cached resolution outlived the language change")

        manager.language = .ja
        XCTAssertNotEqual(manager.s("common.cancel"), korean)

        manager.language = .en
        XCTAssertEqual(manager.s("common.cancel"), english, "switching back must restore English")
    }

    /// Repeated lookups have to keep answering, not just the first one after a switch.
    func testRepeatedLookupsAreStable() {
        let manager = makeManager()
        let first = manager.s("common.cancel")
        for _ in 0..<50 {
            XCTAssertEqual(manager.s("common.cancel"), first)
        }
        manager.language = .ja
        let japanese = manager.s("common.cancel")
        for _ in 0..<50 {
            XCTAssertEqual(manager.s("common.cancel"), japanese)
        }
    }

    /// Plural category is chosen from the *resolved* language, so a stale cache would give
    /// English plural rules to a Korean UI.
    func testPluralCategoryFollowsTheResolvedLanguage() {
        let manager = makeManager()
        let englishOne = manager.p("alert.import.note.oversized", count: 1, 1)
        let englishMany = manager.p("alert.import.note.oversized", count: 5, 5)

        manager.language = .ko
        let koreanOne = manager.p("alert.import.note.oversized", count: 1, 1)
        let koreanMany = manager.p("alert.import.note.oversized", count: 5, 5)

        XCTAssertNotEqual(koreanOne, englishOne, "Korean must not keep serving English forms")
        // Korean has no grammatical plural: one form covers every count.
        XCTAssertEqual(
            koreanOne.replacingOccurrences(of: "1", with: "#"),
            koreanMany.replacingOccurrences(of: "5", with: "#")
        )
        XCTAssertNotEqual(
            englishOne.replacingOccurrences(of: "1", with: "#"),
            englishMany.replacingOccurrences(of: "5", with: "#"),
            "English still needs distinct singular and plural forms for this key"
        )
    }

    /// Explicit invalidation forces the next lookup to re-resolve, which is what the
    /// system-locale-changed observer relies on.
    func testInvalidationForcesReresolution() {
        let manager = makeManager()
        let before = manager.s("common.cancel")
        manager.invalidateResolvedLanguage()
        XCTAssertEqual(manager.s("common.cancel"), before)

        manager.language = .ja
        manager.invalidateResolvedLanguage()
        XCTAssertNotEqual(manager.s("common.cancel"), before)
    }

    // MARK: - Threading

    /// Strings are fetched from the inject queue and the tap thread as well as from AppKit, so
    /// the cache is lock-guarded rather than main-confined. This would trip the thread sanitiser
    /// or produce torn reads if it were not.
    func testConcurrentLookupsAgree() {
        let manager = makeManager()
        let expected = manager.s("common.cancel")
        let done = expectation(description: "concurrent lookups")
        done.expectedFulfillmentCount = 8

        for _ in 0..<8 {
            DispatchQueue.global().async {
                for _ in 0..<500 {
                    XCTAssertEqual(manager.s("common.cancel"), expected)
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 20)
    }

    /// Interleaving invalidation with lookups must never produce a wrong string or a crash.
    func testConcurrentInvalidationIsSafe() {
        let manager = makeManager()
        let expected = manager.s("common.cancel")
        let done = expectation(description: "invalidate while reading")
        done.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for _ in 0..<2_000 { manager.invalidateResolvedLanguage() }
            done.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<2_000 { XCTAssertEqual(manager.s("common.cancel"), expected) }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }

    // MARK: - The cost that motivated the cache

    /// Loose bound: it catches a return to per-lookup locale resolution, not a particular speed.
    func testBulkLookupsDoNotReresolvePerCall() {
        let manager = makeManager()
        let started = Date()
        for _ in 0..<200_000 { _ = manager.s("common.cancel") }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 1.0,
            "200k lookups took \(elapsed)s — the locale list is being walked per call again"
        )
    }
}
