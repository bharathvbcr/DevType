import XCTest
@testable import ExpanderEngine

/// The deferred-expand quiescence guard compares tap marks (`CGEvent.timestamp`) with `arm()`
/// (`DispatchTime` uptime). Whether those share a unit on a real tap cannot be observed headlessly
/// — a constructed event's timestamp is 0 — so the clock reports the ratio once per process.
final class InputClockTimestampUnitsTests: XCTestCase {

    func testTheRatioIsReportedOnceAndOnlyOnce() throws {
        let clock = InputClock(now: { 0 })
        let ratio = try XCTUnwrap(clock.noteTimestampUnitsOnce(eventNanos: 1_000, uptimeNanos: 1_000))
        XCTAssertEqual(ratio, 1, accuracy: 1e-9)
        XCTAssertNil(clock.noteTimestampUnitsOnce(eventNanos: 2_000, uptimeNanos: 2_000))
    }

    func testMachTicksReadAsAFractionNotAsNanoseconds() throws {
        // Apple silicon: 125/3 ns per tick, so a tick count is 3/125 of the nanosecond count.
        let uptime: UInt64 = 409_117_982_442_375
        let ticks = uptime * 3 / 125
        let ratio = try XCTUnwrap(InputClock(now: { 0 }).noteTimestampUnitsOnce(eventNanos: ticks, uptimeNanos: uptime))
        XCTAssertEqual(ratio, 0.024, accuracy: 0.0001)
    }

    func testAConstructedEventsZeroTimestampDoesNotSpendTheOnce() {
        let clock = InputClock(now: { 0 })
        XCTAssertNil(clock.noteTimestampUnitsOnce(eventNanos: 0, uptimeNanos: 1_000))
        XCTAssertNotNil(clock.noteTimestampUnitsOnce(eventNanos: 1_000, uptimeNanos: 1_000))
    }
}
