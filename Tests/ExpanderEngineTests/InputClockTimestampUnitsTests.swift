import XCTest
@testable import ExpanderEngine

/// The deferred-expand quiescence guard compares tap marks (`CGEvent.timestamp`) with `arm()`
/// (`DispatchTime` uptime). A real tap on Apple silicon delivers mach ticks — the field log of
/// DevType 1.3.0 build 438 read `ratio=0.0240` (3/125) — and the tap read them as nanoseconds,
/// so every mark sat ~41× earlier than any arm and the guard never aborted.
final class InputClockTimestampUnitsTests: XCTestCase {

    /// Apple silicon's timebase: 125 ns per tick.
    private let appleSilicon: (numer: UInt64, denom: UInt64) = (125, 3)
    private let uptimeNanos: UInt64 = 419_117_982_442_375
    private var ticks: UInt64 { uptimeNanos * appleSilicon.denom / appleSilicon.numer }

    func testTicksAreRecognisedAndConvertedToTheArmClock() {
        XCTAssertEqual(
            InputClock.decideEventTimestampUnit(raw: ticks, machNow: ticks + 3_000, uptimeNanosNow: uptimeNanos),
            .machTicks
        )
        let converted = InputClock.nanoseconds(fromEventTimestamp: ticks, unit: .machTicks, timebase: appleSilicon)
        XCTAssertEqual(Double(converted), Double(uptimeNanos), accuracy: 1_000)
    }

    func testNanosecondsAreLeftAlone() {
        XCTAssertEqual(
            InputClock.decideEventTimestampUnit(raw: uptimeNanos - 5_000_000, machNow: ticks, uptimeNanosNow: uptimeNanos),
            .uptimeNanoseconds
        )
        XCTAssertEqual(
            InputClock.nanoseconds(fromEventTimestamp: 1_234, unit: .uptimeNanoseconds, timebase: appleSilicon),
            1_234
        )
    }

    /// The defect itself: a key typed after the expansion armed must abort it. Read as nanoseconds,
    /// the key's tick timestamp lands ~41× before `armedAt` and the guard proceeds.
    func testAKeyAfterArmingAbortsTheExpansionWhenTheEventCarriesTicks() {
        let armedAt = InputClock.seconds(sinceBootNanos: uptimeNanos - 10_000_000)
        let keyTicks = ticks
        let clock = InputClock(now: { armedAt })

        let asNanoseconds = InputClock.seconds(sinceBootNanos: keyTicks)
        XCTAssertEqual(
            InputQuiescenceGuard(armedAt: armedAt).decide(lastInputAt: asNanoseconds), .proceed,
            "characterises the bug: ticks read as nanoseconds can never be after the arm"
        )

        let keyTime = clock.seconds(
            fromEventTimestamp: keyTicks,
            machNow: { keyTicks + 100 },
            uptimeNanosNow: { self.uptimeNanos }
        )
        XCTAssertEqual(clock.eventTimestampUnit, .machTicks)
        guard case .abort = InputQuiescenceGuard(armedAt: armedAt).decide(lastInputAt: keyTime) else {
            return XCTFail("a key 10 ms after the arm must abort the deferred expansion")
        }
    }

    func testTheUnitIsDecidedOnceAndKeptForLaterEvents() {
        let clock = InputClock(now: { 0 })
        _ = clock.seconds(fromEventTimestamp: ticks, machNow: { self.ticks }, uptimeNanosNow: { self.uptimeNanos })
        XCTAssertEqual(clock.eventTimestampUnit, .machTicks)
        // A later reading that would look like nanoseconds does not flip the decision mid-session.
        _ = clock.seconds(fromEventTimestamp: uptimeNanos, machNow: { self.ticks }, uptimeNanosNow: { self.uptimeNanos })
        XCTAssertEqual(clock.eventTimestampUnit, .machTicks)
    }

    func testAConstructedEventsZeroTimestampDecidesNothing() {
        let clock = InputClock(now: { 0 })
        XCTAssertEqual(clock.seconds(fromEventTimestamp: 0), 0)
        XCTAssertNil(clock.eventTimestampUnit)
    }
}
