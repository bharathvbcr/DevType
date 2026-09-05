import XCTest
@testable import ExpanderEngine

final class MacroCounterPersistenceTests: XCTestCase {
    private final class ObservedDefaults: UserDefaults {
        var beforeCounterSet: (([String: Int]) -> Void)?

        override func set(_ value: Any?, forKey defaultName: String) {
            if defaultName == "testCounters", let counters = value as? [String: Int] {
                beforeCounterSet?(counters)
            }
            super.set(value, forKey: defaultName)
        }
    }

    func testPersistentSnapshotsCannotCommitOutOfOrder() throws {
        let suite = "devtype.counter.order.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(ObservedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacroCounterStore(defaults: defaults, defaultsKey: "testCounters")
        let firstWrite = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondDone = DispatchSemaphore(value: 0)
        let done = expectation(description: "both counter mutations")
        done.expectedFulfillmentCount = 2
        defaults.beforeCounterSet = { values in
            if values["x"] == 1 {
                firstWrite.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
            }
        }
        DispatchQueue.global().async { store.advance("x"); done.fulfill() }
        XCTAssertEqual(firstWrite.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async { store.advance("x"); secondDone.signal(); done.fulfill() }
        _ = secondDone.wait(timeout: .now() + 0.1)
        releaseFirst.signal()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(store.value(for: "x"), 2)
        XCTAssertEqual(defaults.dictionary(forKey: "testCounters")?["x"] as? Int, 2)
        XCTAssertEqual(MacroCounterStore(defaults: defaults, defaultsKey: "testCounters").value(for: "x"), 2)
    }

    func testPersistenceDoesNotHoldTheValueReadLockAcrossDefaultsCallbacks() throws {
        let suite = "devtype.counter.callback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(ObservedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacroCounterStore(defaults: defaults, defaultsKey: "testCounters")
        defaults.beforeCounterSet = { _ in
            let readDone = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = store.value(for: "x"); readDone.signal() }
            XCTAssertEqual(readDone.wait(timeout: .now() + 0.2), .success,
                           "Preference observers must be able to read counters during persistence")
        }
        XCTAssertEqual(store.advance("x"), 1)
    }

    func testSetResetAndAdvancePersistOneCoherentSnapshot() throws {
        let suite = "devtype.counter.all.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MacroCounterStore(defaults: defaults, defaultsKey: "testCounters")
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index.isMultiple(of: 3) { store.set("x", to: index) }
            else if index.isMultiple(of: 5) { store.resetAll() }
            else { store.advance("x") }
        }
        let reopened = MacroCounterStore(defaults: defaults, defaultsKey: "testCounters")
        XCTAssertEqual(reopened.value(for: "x"), store.value(for: "x"))
        store.reset("x")
        XCTAssertEqual(MacroCounterStore(defaults: defaults, defaultsKey: "testCounters").value(for: "x"), 0)
    }

}
