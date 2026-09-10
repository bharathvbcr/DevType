import XCTest
@testable import ExpanderEngine

private final class StoreWatchSpy: StoreWatching {
    var onChange: (() -> Void)?
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func start() {
        startCallCount += 1
    }

    func stop() {
        stopCallCount += 1
    }
}

final class CompositeWatcherTests: XCTestCase {
    func testCompositeStartAndStopOnNoChildrenAreSafe() {
        let composite = CompositeWatcher([])
        var onChangeCalled = false
        composite.onChange = { onChangeCalled = true }

        composite.start()
        composite.stop()
        XCTAssertFalse(onChangeCalled)
    }

    func testCompositeStartStopsPropagateToAllChildren() {
        let first = StoreWatchSpy()
        let second = StoreWatchSpy()
        let composite = CompositeWatcher([first, second])

        composite.start()
        XCTAssertEqual(first.startCallCount, 1)
        XCTAssertEqual(second.startCallCount, 1)

        composite.stop()
        XCTAssertEqual(first.stopCallCount, 1)
        XCTAssertEqual(second.stopCallCount, 1)
    }

    func testCompositeForwardsChildChangeNotifications() {
        let first = StoreWatchSpy()
        let second = StoreWatchSpy()
        let composite = CompositeWatcher([first, second])
        var totalCalls = 0

        composite.onChange = {
            totalCalls += 1
        }

        first.onChange?()
        second.onChange?()

        XCTAssertEqual(totalCalls, 2)
    }

    func testCompositeStopsObservingWhenCallbackCleared() {
        let first = StoreWatchSpy()
        let composite = CompositeWatcher([first])
        var totalCalls = 0

        composite.onChange = { totalCalls += 1 }
        composite.onChange = nil
        first.onChange?()

        XCTAssertEqual(totalCalls, 0)
    }
}
