import XCTest
@testable import DevTypeAppCore

final class ActivityDiagnosticCopyGateTests: XCTestCase {
    func testOnlyOneDiagnosticCopyCanRunUntilTheActiveBuildFinishes() {
        var gate = ActivityDiagnosticCopyGate()

        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.isInFlight)

        gate.finish()

        XCTAssertFalse(gate.isInFlight)
        XCTAssertTrue(gate.begin())
    }
}
