import Foundation
import XCTest
@testable import ExpanderEngine

/// `AssetInventory.status` is a per-app reservation fact: an asset already on disk reads
/// `.supported` until the app reserves its locale (verified on macOS 27 with the `swift`
/// interpreter). These tests pin the reservation policy without a Speech runtime.
final class AppleSpeechAssetReservationTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func testAnAlreadyReservedLocaleIsNotReservedAgain() async {
        let store = ReservationStore(reserved: [english], maximum: 5)

        let outcome = await AppleSpeechAssetReservation.reserve(english, using: store.operations)

        XCTAssertEqual(outcome, .alreadyReserved)
        XCTAssertEqual(store.reserveCalls, 0, "re-reserving a held locale returns false on macOS 27")
    }

    func testAnAlreadyReservedLocaleIsRecognisedAcrossIdentifierSpellings() async {
        let store = ReservationStore(reserved: [Locale(identifier: "en_US")], maximum: 5)

        let outcome = await AppleSpeechAssetReservation.reserve(
            Locale(identifier: "en-US"), using: store.operations
        )

        XCTAssertEqual(outcome, .alreadyReserved)
        XCTAssertEqual(store.reserveCalls, 0)
    }

    func testAFreeSlotIsReservedWithoutReleasingAnything() async {
        let store = ReservationStore(reserved: [Locale(identifier: "de_DE")], maximum: 5)

        let outcome = await AppleSpeechAssetReservation.reserve(english, using: store.operations)

        XCTAssertEqual(outcome, .reserved)
        XCTAssertEqual(store.releaseCalls, [])
        XCTAssertEqual(store.reserveCalls, 1)
    }

    /// Verified on macOS 27: at the limit `reserve(locale:)` returns false, it does not throw.
    func testLimitReportedAsFalseReleasesOneOtherLocaleAndRetriesOnce() async {
        let existing = ["de_DE", "fr_FR", "it_IT", "es_ES", "ja_JP"].map(Locale.init(identifier:))
        let store = ReservationStore(reserved: existing, maximum: 5, limitBehavior: .returnFalse)

        let outcome = await AppleSpeechAssetReservation.reserve(english, using: store.operations)

        XCTAssertEqual(outcome, .reservedAfterEviction(evicted: existing[0]))
        XCTAssertEqual(store.releaseCalls, [existing[0]])
        XCTAssertEqual(store.reserveCalls, 2, "one attempt, one eviction, exactly one retry")
        XCTAssertTrue(store.reservedLocalesNow.contains(english))
        XCTAssertEqual(store.reservedLocalesNow.count, 5)
    }

    /// Apple documents a throw when the limit is exceeded; it takes the same path.
    func testLimitReportedAsAThrowReleasesOneOtherLocaleAndRetriesOnce() async {
        let existing = ["de_DE", "fr_FR", "it_IT", "es_ES", "ja_JP"].map(Locale.init(identifier:))
        let store = ReservationStore(reserved: existing, maximum: 5, limitBehavior: .throwError)

        let outcome = await AppleSpeechAssetReservation.reserve(english, using: store.operations)

        XCTAssertEqual(outcome, .reservedAfterEviction(evicted: existing[0]))
        XCTAssertEqual(store.releaseCalls, [existing[0]])
        XCTAssertEqual(store.reserveCalls, 2)
    }

    func testARefusalBelowTheLimitNeverReleasesAnotherLocale() async {
        let store = ReservationStore(
            reserved: [Locale(identifier: "de_DE")], maximum: 5, alwaysRefuse: .throwError
        )

        let outcome = await AppleSpeechAssetReservation.reserve(english, using: store.operations)

        XCTAssertEqual(outcome, .notReserved, "an unrelated throw must fall through to the status read")
        XCTAssertEqual(store.releaseCalls, [], "evicting a locale cannot help when the limit is not the cause")
        XCTAssertEqual(store.reserveCalls, 1)
    }

    func testAFalseRefusalBelowTheLimitNeverReleasesAnotherLocale() async {
        let store = ReservationStore(
            reserved: [Locale(identifier: "de_DE")], maximum: 5, alwaysRefuse: .returnFalse
        )

        let outcome = await AppleSpeechAssetReservation.reserve(english, using: store.operations)

        XCTAssertEqual(outcome, .notReserved)
        XCTAssertEqual(store.releaseCalls, [])
    }

    func testARetryThatStillFailsIsNotRepeated() async {
        let existing = ["de_DE", "fr_FR", "it_IT", "es_ES", "ja_JP"].map(Locale.init(identifier:))
        let store = ReservationStore(
            reserved: existing, maximum: 5, limitBehavior: .returnFalse, alwaysRefuse: .returnFalse
        )

        let outcome = await AppleSpeechAssetReservation.reserve(english, using: store.operations)

        XCTAssertEqual(outcome, .notReserved)
        XCTAssertEqual(store.releaseCalls.count, 1, "at most one eviction")
        XCTAssertEqual(store.reserveCalls, 2, "at most one retry")
    }

    func testAnEvictionThatCannotBeReleasedDoesNotRetry() async {
        let existing = ["de_DE", "fr_FR", "it_IT", "es_ES", "ja_JP"].map(Locale.init(identifier:))
        let store = ReservationStore(
            reserved: existing, maximum: 5, limitBehavior: .returnFalse, releaseSucceeds: false
        )

        let outcome = await AppleSpeechAssetReservation.reserve(english, using: store.operations)

        XCTAssertEqual(outcome, .notReserved)
        XCTAssertEqual(store.reserveCalls, 1)
    }

    func testTheRequestedLocaleIsNeverTheOneEvicted() async {
        // The held list contains only the requested locale's namesake spelled differently from
        // the request, so it is `alreadyReserved`; with a full list that lacks it, the victim is
        // always another locale.
        let existing = ["de_DE", "fr_FR", "it_IT", "es_ES", "ja_JP"].map(Locale.init(identifier:))
        for requested in ["en_US", "pt_BR", "ko_KR"].map(Locale.init(identifier:)) {
            let store = ReservationStore(reserved: existing, maximum: 5, limitBehavior: .returnFalse)
            _ = await AppleSpeechAssetReservation.reserve(requested, using: store.operations)
            XCTAssertFalse(store.releaseCalls.contains(requested))
        }
    }

    // MARK: Adapter ordering

    /// The adapter must reserve before it reads. This is the regression: a runtime whose status
    /// is `.supported` until reserved made `probe()` ask the user to download an asset that was
    /// already on disk.
    func testCurrentAssetStateReservesBeforeReadingStatus() async {
        let events = EventLog()
        let reserved = LockBox(false)
        let runtime = AppleSpeechAnalyzerRuntime(
            isPlatformSupported: { true },
            reserveAssets: { _ in events.append("reserve"); reserved.value = true },
            assetState: { _ in
                events.append("status")
                return reserved.value ? .installed : .downloadable
            },
            transcribe: { _, _ in },
            installAssets: { _ in events.append("install") }
        )

        let state = await runtime.currentAssetState(Locale(identifier: "en-US"))

        XCTAssertEqual(state, .installed)
        XCTAssertEqual(events.values, ["reserve", "status"])
    }
}

// MARK: - Doubles

private final class LockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ event: String) { lock.withLock { storage.append(event) } }
    var values: [String] { lock.withLock { storage } }
}

/// A fake `AssetInventory`: a bounded set of reserved locales with a configurable way of saying no.
private final class ReservationStore: @unchecked Sendable {
    enum Refusal { case returnFalse, throwError }
    struct Refused: Error {}

    private let lock = NSLock()
    private var reserved: [Locale]
    private let maximum: Int
    private let limitBehavior: Refusal
    private let alwaysRefuse: Refusal?
    private let releaseSucceeds: Bool
    private var reserveCount = 0
    private var released: [Locale] = []

    init(
        reserved: [Locale],
        maximum: Int,
        limitBehavior: Refusal = .returnFalse,
        alwaysRefuse: Refusal? = nil,
        releaseSucceeds: Bool = true
    ) {
        self.reserved = reserved
        self.maximum = maximum
        self.limitBehavior = limitBehavior
        self.alwaysRefuse = alwaysRefuse
        self.releaseSucceeds = releaseSucceeds
    }

    var reserveCalls: Int { lock.withLock { reserveCount } }
    var releaseCalls: [Locale] { lock.withLock { released } }
    var reservedLocalesNow: [Locale] { lock.withLock { reserved } }

    var operations: AppleSpeechAssetReservation.Operations {
        AppleSpeechAssetReservation.Operations(
            reservedLocales: { [self] in lock.withLock { reserved } },
            maximumReservedLocales: { [maximum] in maximum },
            reserve: { [self] locale in try reserve(locale) },
            release: { [self] locale in release(locale) }
        )
    }

    private func reserve(_ locale: Locale) throws -> Bool {
        try lock.withLock {
            reserveCount += 1
            if let alwaysRefuse {
                if alwaysRefuse == .throwError { throw Refused() }
                return false
            }
            if reserved.count >= maximum {
                if limitBehavior == .throwError { throw Refused() }
                return false
            }
            reserved.append(locale)
            return true
        }
    }

    private func release(_ locale: Locale) -> Bool {
        lock.withLock {
            released.append(locale)
            guard releaseSucceeds, let index = reserved.firstIndex(of: locale) else { return false }
            reserved.remove(at: index)
            return true
        }
    }
}
