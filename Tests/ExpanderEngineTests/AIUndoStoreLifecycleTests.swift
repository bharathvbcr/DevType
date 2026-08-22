import XCTest
import AppKit
@testable import ExpanderEngine

/// The undo stash holds a copy of the user's selection text, so it must not
/// outlive the active session: DevType resigning active clears it (mirroring
/// `BiometricGate.invalidate()` on resign). These tests pin that contract and
/// confirm `stash`/`consume` semantics are unchanged by the lifecycle hook.
///
/// The store installs its observer lazily on first `stash`, so every test drives
/// the real public API — no notification-centre surgery.
final class AIUndoStoreLifecycleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AIUndoStore.clear()
    }

    override func tearDown() {
        AIUndoStore.clear()
        super.tearDown()
    }

    /// Posting the resign-active notification clears the stash. The clear runs on
    /// the main queue, so the trailing async hop both waits for it and proves the
    /// queue drained (main queue is FIFO).
    func testResignActiveClearsStash() {
        AIUndoStore.stash("selected text")

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)

        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        XCTAssertFalse(AIUndoStore.hasUndo, "stashed selection survived resign-active")
        XCTAssertNil(AIUndoStore.preview)
        XCTAssertNil(AIUndoStore.stashedOriginal())
    }

    /// Without an intervening resign, the stash behaves exactly as before the
    /// lifecycle hook was added.
    func testStashSemanticsUnchangedWithoutResign() {
        XCTAssertFalse(AIUndoStore.hasUndo)
        AIUndoStore.stash("keep me")
        XCTAssertTrue(AIUndoStore.hasUndo)
        XCTAssertEqual(AIUndoStore.stashedOriginal(), "keep me")
        XCTAssertEqual(AIUndoStore.consume(), "keep me")
        XCTAssertFalse(AIUndoStore.hasUndo)
    }

    /// Empty stashes never install state (and the observer forced-install in
    /// `stash` must not change that).
    func testEmptyStashIsIgnored() {
        AIUndoStore.stash("")
        XCTAssertFalse(AIUndoStore.hasUndo)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        XCTAssertFalse(AIUndoStore.hasUndo)
    }
}
