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

    // MARK: - Hold surrender vs. the first write

    private let terminator = SwallowedKey(didSwallow: true, unicode: " ", keyCode: 49, flags: [])

    func testSurrenderBeforeTheFirstWriteAbandonsAndHandsBackTheTerminatorOnce() throws {
        let ledger = try ledger()
        ledger.beginDeliveryWindow()
        ledger.oweTerminator(terminator)
        let operation = InjectCompletionGuard()
        let revision = ledger.claim(operation, consumingUndo: false)

        XCTAssertEqual(ledger.surrenderHold(), .abandoned(replay: terminator))
        XCTAssertFalse(ledger.isCurrent(operation, revision: revision))
        XCTAssertFalse(ledger.beginMutation(operation, revision: revision), "an abandoned inject cannot write")
        XCTAssertEqual(ledger.surrenderHold(), .abandoned(replay: nil), "the debt is paid once")
        XCTAssertFalse(ledger.consumeTerminator(matching: terminator), "no refusal may post it again")
    }

    func testSurrenderAfterTheFirstWriteBeganChangesNothing() throws {
        let ledger = try ledger()
        ledger.beginDeliveryWindow()
        ledger.oweTerminator(terminator)
        let operation = InjectCompletionGuard()
        let revision = ledger.claim(operation, consumingUndo: false)

        XCTAssertTrue(ledger.beginMutation(operation, revision: revision))
        XCTAssertEqual(ledger.surrenderHold(), .mutationBegun)
        XCTAssertTrue(ledger.isCurrent(operation, revision: revision), "the surrender itself moves nothing")
        XCTAssertTrue(ledger.consumeTerminator(matching: terminator), "the refusal path still owns the key")
    }

    /// A hold that surrenders in the gap between the tap's claim and the pipeline's (a focus
    /// query and a render) must still abandon the inject that claims afterwards.
    func testASurrenderBeforeTheClaimCancelsTheLateOperation() throws {
        let ledger = try ledger()
        ledger.beginDeliveryWindow()
        ledger.oweTerminator(terminator)
        XCTAssertEqual(ledger.surrenderHold(), .abandoned(replay: terminator))

        let late = InjectCompletionGuard()
        let revision = ledger.claim(late, consumingUndo: false)
        XCTAssertFalse(late.allowsContinuation(), "the late operation is cancelled at birth")
        XCTAssertFalse(ledger.beginMutation(late, revision: revision))
    }

    func testBeginMutationRefusesAStaleRevisionAndASupersededOperation() throws {
        let ledger = try ledger()
        ledger.beginDeliveryWindow()
        let first = InjectCompletionGuard()
        let revision = ledger.claim(first, consumingUndo: false)
        ledger.noteDeliveryInput(units: 1)
        XCTAssertFalse(ledger.beginMutation(first, revision: revision), "input landed since the claim")

        let second = InjectCompletionGuard()
        let secondRevision = ledger.claim(second, consumingUndo: false)
        XCTAssertFalse(ledger.beginMutation(first, revision: secondRevision), "superseded")
        XCTAssertTrue(ledger.beginMutation(second, revision: secondRevision))
    }

    func testClosingTheWindowReleasesTheSurrenderAndTheDebt() throws {
        let ledger = try ledger()
        ledger.beginDeliveryWindow()
        ledger.oweTerminator(terminator)
        _ = ledger.surrenderHold()
        ledger.endDeliveryWindow()

        XCTAssertTrue(ledger.consumeTerminator(matching: terminator),
                      "a later replay of an equal key (an undo's held backspace) is not withheld")
        let next = InjectCompletionGuard()
        _ = ledger.claim(next, consumingUndo: false)
        XCTAssertTrue(next.allowsContinuation(), "and a later inject is not born cancelled")
    }

    func testOnlyTheOwedKeyIsWithheld() throws {
        let ledger = try ledger()
        ledger.beginDeliveryWindow()
        ledger.oweTerminator(terminator)
        _ = ledger.surrenderHold()
        let backspace = SwallowedKey(didSwallow: true, unicode: "\u{7F}", keyCode: 51, flags: [])
        XCTAssertTrue(ledger.consumeTerminator(matching: backspace))
    }

    func testAKeyThatNeverReachedTheFieldOwesNothing() throws {
        let ledger = try ledger()
        ledger.beginDeliveryWindow()
        ledger.oweTerminator(SwallowedKey(didSwallow: false))
        XCTAssertEqual(ledger.surrenderHold(), .abandoned(replay: nil))
    }

    func testAnUncountedKeyMovesTheRevisionButNotTheCounters() throws {
        let ledger = try ledger()
        ledger.beginDeliveryWindow()
        let operation = InjectCompletionGuard()
        let revision = ledger.claim(operation, consumingUndo: false)
        ledger.noteUncountedDeliveryKey()
        XCTAssertFalse(ledger.isCurrent(operation, revision: revision))
        XCTAssertEqual(ledger.currentDeliveryInputUnits, 0)
    }

    /// The pipeline (main) and the tap thread race for the same fact. Exactly one may win, every
    /// time: a write that began is never abandoned, and an abandoned inject never writes.
    func testBeginMutationAndSurrenderNeverBothWin() throws {
        for round in 0..<400 {
            let ledger = try ledger()
            ledger.beginDeliveryWindow()
            ledger.oweTerminator(terminator)
            let operation = InjectCompletionGuard()
            let revision = ledger.claim(operation, consumingUndo: false)
            let results = NSLock()
            var wrote = false
            var surrendered: TextInjectionPipeline.ExpansionLedger.HoldSurrender?
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    let won = ledger.beginMutation(operation, revision: revision)
                    results.lock(); wrote = won; results.unlock()
                } else {
                    let outcome = ledger.surrenderHold()
                    results.lock(); surrendered = outcome; results.unlock()
                }
            }
            if wrote {
                XCTAssertEqual(surrendered, .mutationBegun, "round \(round): wrote and was abandoned")
            } else {
                XCTAssertEqual(surrendered, .abandoned(replay: terminator), "round \(round): neither won")
            }
        }
    }
}
