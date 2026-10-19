import Foundation
import XCTest
import SourceTreeTestSupport
@testable import ExpanderEngine

/// §2.4 + §3.1: one owner, one lock. The undo record, the counters that keep a blind undo
/// honest, the input revision and the current operation live in `ExpansionLedger`, and every
/// pair that must change together is one ledger method — so these tests drive the ledger
/// directly, with no window server, focused field or event tap.
final class ExpansionLedgerTests: XCTestCase {

    private typealias Ledger = TextInjectionPipeline.ExpansionLedger

    private func ledger() throws -> Ledger {
        let suite = "DevType.ExpansionLedger.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return Ledger(defaults: defaults)
    }

    private func record(_ ledger: Ledger, pid: pid_t? = 1234, injected: String = "expanded") {
        ledger.record(.init(
            erasePlan: ErasePlan(text: "ab"), injectedText: injected, triggerText: "abc",
            bundleID: "test.editor"
        ), target: .init(pid: pid, element: nil, range: nil))
    }

    // MARK: - The pipeline owns no lock

    func testThePipelineHoldsNoLockOfItsOwn() throws {
        let source = SourceContractTests.strippingComments(try SourceTree.text("Sources/ExpanderEngine/Engine/TextInjectionPipeline.swift"))
        for lockUse in ["UnfairLock", ".withLock", ".lock()", ".unlock()"] {
            XCTAssertFalse(source.contains(lockUse),
                           "\(lockUse) in the pipeline: shared inject/undo state has one owner, ExpansionLedger")
        }
    }

    // MARK: - Operations

    func testClaimingCancelsThePreviousOperationAndReturnsTheRevision() throws {
        let ledger = try ledger()
        let first = InjectCompletionGuard()
        let revision = ledger.claim(first, consumingUndo: true)
        XCTAssertTrue(ledger.isCurrent(first, revision: revision))

        let second = InjectCompletionGuard()
        let next = ledger.claim(second, consumingUndo: true)
        XCTAssertEqual(first.continuationBlock(), .cancelled)
        XCTAssertFalse(ledger.isCurrent(first, revision: revision))
        XCTAssertTrue(ledger.isCurrent(second, revision: next))
    }

    func testAnExpansionClaimConsumesTheRecordAndAnUndoClaimDoesNot() throws {
        let ledger = try ledger()
        record(ledger)
        _ = ledger.claim(InjectCompletionGuard(), consumingUndo: false)
        XCTAssertNotNil(ledger.record, "An undo's own inject must not consume the record it is undoing")
        _ = ledger.claim(InjectCompletionGuard(), consumingUndo: true)
        XCTAssertNil(ledger.record)
    }

    func testInputAdvancesTheRevision() throws {
        let ledger = try ledger()
        let operation = InjectCompletionGuard()
        let revision = ledger.claim(operation, consumingUndo: true)
        ledger.noteInputAfterExpansion(units: 1)
        XCTAssertFalse(ledger.isCurrent(operation, revision: revision))

        let again = ledger.claim(operation, consumingUndo: true)
        ledger.noteDeliveryInput(units: 1)
        XCTAssertFalse(ledger.isCurrent(operation, revision: again))
        ledger.noteInputAfterExpansion(units: 0)
        ledger.noteDeliveryInput(units: 0)
        XCTAssertEqual(ledger.currentDeliveryInputUnits, 1, "Zero units are a no-op")
    }

    func testCancellingInvalidatesTheRecordAndTheOperation() throws {
        let ledger = try ledger()
        record(ledger)
        let operation = InjectCompletionGuard()
        let revision = ledger.claim(operation, consumingUndo: false)
        ledger.cancelCurrent()
        XCTAssertNil(ledger.record)
        XCTAssertEqual(operation.continuationBlock(), .cancelled)
        XCTAssertFalse(ledger.isCurrent(operation, revision: revision))
    }

    // MARK: - Undo record

    func testRecordingDrainsTheDeliveryWindowIntoTheRecord() throws {
        let ledger = try ledger()
        ledger.beginDeliveryWindow()
        ledger.noteDeliveryInput(units: 2)
        record(ledger)
        XCTAssertEqual(ledger.currentDeliveryInputUnits, 0)
        let attempt = try XCTUnwrap(ledger.takeUndoAttempt(now: Date(), frontmostPID: 1234))
        XCTAssertEqual(attempt.inputEvents, 2, "Input during delivery poisons the blind-undo premise")
    }

    func testTakingAnAttemptConsumesTheRecord() throws {
        let ledger = try ledger()
        record(ledger)
        ledger.noteInputAfterExpansion(units: 3)
        let attempt = try XCTUnwrap(ledger.takeUndoAttempt(now: Date(), frontmostPID: 1234))
        XCTAssertEqual(attempt.inputEvents, 3)
        XCTAssertTrue(ledger.undoAttemptIsCurrent(attempt))
        XCTAssertNil(ledger.record)
        XCTAssertNil(ledger.takeUndoAttempt(now: Date(), frontmostPID: 1234))
    }

    func testAForeignOrStaleRecordIsInvalidatedNotReturned() throws {
        let ledger = try ledger()
        record(ledger)
        XCTAssertFalse(ledger.canUndo(now: Date(), frontmostPID: 99))
        XCTAssertNil(ledger.takeUndoAttempt(now: Date(), frontmostPID: 99))
        XCTAssertNil(ledger.record, "A refused claim must not leave the record for a later app")

        record(ledger)
        XCTAssertNil(ledger.takeUndoAttempt(now: Date().addingTimeInterval(3_600), frontmostPID: 1234))
        XCTAssertNil(ledger.record)
    }

    func testARecordWithoutATargetProcessIsNotKept() throws {
        let ledger = try ledger()
        record(ledger, pid: nil)
        XCTAssertNil(ledger.record)
        record(ledger, pid: 1234, injected: "")
        XCTAssertNil(ledger.record)
    }

    func testDisablingUndoInvalidatesAnAttemptAlreadyTaken() throws {
        let ledger = try ledger()
        record(ledger)
        XCTAssertTrue(ledger.canUndo(now: Date(), frontmostPID: 1234))
        let attempt = try XCTUnwrap(ledger.takeUndoAttempt(now: Date(), frontmostPID: 1234))
        ledger.undoEnabled = false
        XCTAssertFalse(ledger.undoAttemptIsCurrent(attempt))
        ledger.undoEnabled = true
        XCTAssertFalse(ledger.undoAttemptIsCurrent(attempt), "Re-enabling does not revive a revoked attempt")
        record(ledger)
        XCTAssertNotNil(ledger.record)
    }

    func testInvalidatingByTextOnlyMatchesThatRecord() throws {
        let ledger = try ledger()
        record(ledger, injected: "expanded")
        ledger.invalidateUndo(ifInjectedTextIs: "other")
        XCTAssertNotNil(ledger.record)
        ledger.invalidateUndo(ifInjectedTextIs: "expanded")
        XCTAssertNil(ledger.record)
    }

    /// Check-and-consume is one critical section: hammered from many threads, no record is ever
    /// handed to two undo attempts.
    func testConcurrentClaimsNeverHandOutOneRecordTwice() throws {
        let ledger = try ledger()
        let collected = UnfairLock()
        var taken: [String] = []
        DispatchQueue.concurrentPerform(iterations: 4_000) { i in
            switch i % 3 {
            case 0:
                record(ledger, injected: "expanded-\(i)")
            case 1:
                if let attempt = ledger.takeUndoAttempt(now: Date(), frontmostPID: 1234) {
                    collected.withLock { taken.append(attempt.record.injectedText) }
                }
            default:
                ledger.noteDeliveryInput(units: 1)
            }
        }
        XCTAssertEqual(Set(taken).count, taken.count, "A record was claimed by two undo attempts")
    }
}
