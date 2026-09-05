import XCTest
@testable import ExpanderEngine

final class MacroOperationRegressionTests: XCTestCase {
    func testTwoImmediateExpansionsOfSameContentReserveDifferentCounterValues() throws {
        let suite = "devtype.macro.operations.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let environment = MacroEnvironment(counters: MacroCounterStore(defaults: defaults))
        let first = MacroRenderer.expand(content: "{{counter:invoice}}", clipboardText: "", environment: environment)
        let second = MacroRenderer.expand(content: "{{counter:invoice}}", clipboardText: "", environment: environment)
        XCTAssertEqual(first.text, "1")
        XCTAssertEqual(second.text, "2")
    }

    func testOperationMemoDoesNotExpireWhileItsOwnerIsAlive() {
        let values = MacroVolatileStore()
        var produced = 0
        let first = values.value(forKey: "one-operation") { produced += 1; return "\(produced)" }
        Thread.sleep(forTimeInterval: 0.6)
        let second = values.value(forKey: "one-operation") { produced += 1; return "\(produced)" }
        XCTAssertEqual(first, second)
        XCTAssertEqual(produced, 1)
    }

    func testConcurrentMissesEvaluateOneProducer() {
        let values = MacroVolatileStore()
        let lock = NSLock()
        var produced = 0
        var results: [String] = []
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let done = expectation(description: "both readers")
        done.expectedFulfillmentCount = 2
        let read = {
            let result = values.value(forKey: "one-operation") {
                let number = lock.withLock { produced += 1; return produced }
                entered.signal()
                _ = release.wait(timeout: .now() + 1)
                return "\(number)"
            }
            lock.withLock { results.append(result) }
            done.fulfill()
        }
        DispatchQueue.global().async(execute: read)
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async(execute: read)
        // Old implementation starts the second producer before publication; the fixed one waits.
        _ = entered.wait(timeout: .now() + 0.1)
        release.signal()
        release.signal()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(produced, 1)
        XCTAssertEqual(results, ["1", "1"])
    }
}
