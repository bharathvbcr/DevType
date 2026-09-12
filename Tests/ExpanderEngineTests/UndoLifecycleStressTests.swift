import ApplicationServices
import Foundation
import XCTest
@testable import ExpanderEngine

final class UndoLifecycleStressTests: XCTestCase {
    private func pipeline() throws -> TextInjectionPipeline {
        let suite = "DevType.UndoAudit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return TextInjectionPipeline(defaults: defaults)
    }

    private func record(_ pipeline: TextInjectionPipeline, pid: pid_t? = 1234) {
        pipeline.recordUndoExpansion(.init(
            erasePlan: ErasePlan(text: "ab"), injectedText: "expanded", triggerText: "abc",
            bundleID: "test.editor"
        ), target: .init(pid: pid, element: nil, range: nil))
    }

    func testSettingDefaultsOnPersistsOffAndPreventsRecordingOrSwallowing() throws {
        let pipeline = try pipeline()
        XCTAssertTrue(pipeline.expansionUndoEnabled)
        record(pipeline)
        XCTAssertNotNil(pipeline.lastExpansion)
        pipeline.expansionUndoEnabled = false
        XCTAssertFalse(pipeline.expansionUndoEnabled)
        XCTAssertNil(pipeline.lastExpansion)
        record(pipeline)
        XCTAssertNil(pipeline.lastExpansion)
        XCTAssertNil(pipeline.takeUndoAttempt(now: Date(), frontmostPID: 1234))
        XCTAssertFalse(pipeline.undoLastExpansion(heldBackspace: .init(didSwallow: true)))
    }

    func testSettingSurvivesNewPipelineAndReenablingCannotResurrectARecord() throws {
        let suite = "DevType.UndoPersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pipeline = TextInjectionPipeline(defaults: defaults)
        record(pipeline)
        pipeline.expansionUndoEnabled = false
        XCTAssertFalse(TextInjectionPipeline(defaults: defaults).expansionUndoEnabled)
        pipeline.expansionUndoEnabled = true
        XCTAssertNil(pipeline.takeUndoAttempt(now: Date(), frontmostPID: 1234))
        record(pipeline)
        XCTAssertNotNil(pipeline.takeUndoAttempt(now: Date(), frontmostPID: 1234))
    }

    func testUnknownOrDifferentProcessNeverClaimsUndoEvenForSameBundle() throws {
        let pipeline = try pipeline()
        for pid: pid_t? in [nil, 0, -1, 9999] {
            record(pipeline)
            XCTAssertNil(pipeline.takeUndoAttempt(now: Date(), frontmostPID: pid))
            XCTAssertNil(pipeline.takeUndoAttempt(now: Date(), frontmostPID: 1234))
        }
        for pid: pid_t? in [nil, 0, -1] {
            record(pipeline, pid: pid)
            XCTAssertNil(pipeline.lastExpansion)
        }
    }

    func testEveryInvalidationPermanentlyRevokesQueuedUndo() throws {
        let pipeline = try pipeline()
        let invalidations: [(TextInjectionPipeline) -> Void] = [
            { $0.clearLastExpansion() },
            { $0.noteInputAfterExpansion() },
            { $0.noteDeliveryInput() },
            { $0.cancelCurrentInjection() },
            { $0.expansionUndoEnabled = false; $0.expansionUndoEnabled = true },
            { self.record($0) }
        ]
        for invalidate in invalidations {
            record(pipeline)
            let attempt = try XCTUnwrap(pipeline.takeUndoAttempt(now: Date(), frontmostPID: 1234))
            XCTAssertTrue(pipeline.undoAttemptIsCurrent(attempt))
            invalidate(pipeline)
            XCTAssertFalse(pipeline.undoAttemptIsCurrent(attempt))
            record(pipeline)
            XCTAssertFalse(pipeline.undoAttemptIsCurrent(attempt))
        }
    }

    func testInputDuringDeliveryAndAfterRecordingCannotWrapToBlindUndoPermission() throws {
        let pipeline = try pipeline()
        pipeline.beginDeliveryWindow()
        pipeline.noteDeliveryInput(units: Int.max)
        pipeline.noteDeliveryInput()
        record(pipeline)
        pipeline.noteInputAfterExpansion(units: Int.max)
        let attempt = try XCTUnwrap(pipeline.takeUndoAttempt(now: Date(), frontmostPID: 1234))
        XCTAssertEqual(attempt.inputEvents, Int.max)
        XCTAssertNotNil(TextInjectionPipeline.undoEraseRefusalReason(
            result: .unavailable("opaque"), inputEventsSinceExpansion: attempt.inputEvents
        ))
    }

    private final class DeferredPoster: BackspacePosting {
        var pending: (() -> Void)?
        var posted = 0
        func sendBackspaces(count: Int) -> Int { XCTFail("Unexpected synchronous post"); return 0 }
        func sendBackspacesAsync(count: Int, completion: @escaping (Bool) -> Void) {
            XCTFail("Missing continuation guard")
            completion(false)
        }
        func sendBackspacesAsync(count: Int, shouldContinue: @escaping () -> Bool,
                                 completion: @escaping (Bool) -> Void) {
            pending = {
                let permitted = shouldContinue()
                if permitted { self.posted += count }
                completion(permitted)
            }
        }
    }

    func testDelayedEraseAndCommandChordRecheckTheRealUndoToken() throws {
        let pipeline = try pipeline()
        for revoke in [false, true] {
            record(pipeline)
            let attempt = try XCTUnwrap(pipeline.takeUndoAttempt(now: Date(), frontmostPID: 1234))
            let poster = DeferredPoster()
            let executor = EraseExecutor(hid: poster)
            var outcomes: [Bool] = []
            executor.finishGuardedErase(
                plan: ErasePlan(text: "expanded"), afterPossibleWrite: false, result: .ok,
                intent: .undo(inputEventsSinceExpansion: 0),
                canProceed: { pipeline.undoAttemptIsCurrent(attempt) }, onUnverifiableAfterWrite: nil
            ) { outcomes.append($0) }
            XCTAssertNotNil(poster.pending)
            if revoke { pipeline.clearLastExpansion() }
            poster.pending?()
            XCTAssertEqual(outcomes, [!revoke])
            XCTAssertEqual(poster.posted, revoke ? 0 : 8)

            record(pipeline)
            let paste = try XCTUnwrap(pipeline.takeUndoAttempt(now: Date(), frontmostPID: 1234))
            var callbacks: [() -> Void] = []
            var events: [String] = []
            HIDKeyPoster.performCommandChord(
                shouldContinue: { pipeline.undoAttemptIsCurrent(paste) }, canPost: { true },
                postCommandDown: { events.append("down"); return true },
                postLetter: { events.append("v"); return true },
                releaseCommand: { events.append("up") }, schedule: { callbacks.append($0) },
                completion: { events.append("completed-\($0)") }
            )
            if revoke { pipeline.expansionUndoEnabled = false; pipeline.expansionUndoEnabled = true }
            while !callbacks.isEmpty { callbacks.removeFirst()() }
            XCTAssertEqual(events, revoke ? ["down", "up", "completed-false"]
                                         : ["down", "v", "up", "completed-true"])
        }
    }

    func testFinalEraseCannotForgetTheOpacityPolicyAfterPreflightPassed() {
        for inputs in [0, 1, Int.max] {
            for result: ErasePreconditionResult in [.ok, .unavailable("disappeared"), .mismatch("changed")] {
                let poster = DeferredPoster()
                var outcomes: [Bool] = []
                EraseExecutor(hid: poster).finishGuardedErase(
                    plan: ErasePlan(text: "expanded"), afterPossibleWrite: false, result: result,
                    intent: .undo(inputEventsSinceExpansion: inputs), onUnverifiableAfterWrite: nil
                ) { outcomes.append($0) }
                poster.pending?()
                let allowed = result == .ok || (inputs == 0 && result == .unavailable("disappeared"))
                XCTAssertEqual(outcomes, [allowed])
                XCTAssertEqual(poster.posted, allowed ? 8 : 0)
            }
        }
    }

    func testUndoRejectsSelectionAndCannotBorrowLenientCaretRecovery() {
        for (value, range) in [("expanded", NSRange(location: 8, length: 1)),
                               ("expandedx", NSRange(location: 9, length: 0))] {
            let executor = EraseExecutor(textAccess: .init(
                value: { _ in value }, selectedRange: { _ in range }, stringForRange: { _, _ in "expanded" }
            ))
            XCTAssertTrue(executor.evaluateErasePrecondition(
                plan: ErasePlan(text: "expanded"), element: AXUIElementCreateApplication(1234),
                retryOnMismatch: false, insertionPointFollowsExpectedText: true,
                intent: .undo(inputEventsSinceExpansion: 0)
            ).blocksErase)
        }
    }

    func testDeveloperEraseBypassDoesNotDisableUndoVerification() {
        let key = ErasePreconditionChecker.disableDefaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: key)
        let executor = EraseExecutor(textAccess: .init(
            value: { _ in "changed!" }, selectedRange: { _ in NSRange(location: 8, length: 0) },
            stringForRange: { _, _ in nil }
        ))
        XCTAssertTrue(executor.evaluateErasePrecondition(
            plan: ErasePlan(text: "expanded"), element: AXUIElementCreateApplication(1234),
            retryOnMismatch: false, intent: .undo(inputEventsSinceExpansion: 0)
        ).blocksErase)
    }

    func testConcurrentClaimsHaveExactlyOneWinnerAndDisableRevokesIt() throws {
        let pipeline = try pipeline()
        let lock = NSLock()
        for _ in 0..<100 {
            record(pipeline)
            var winners = 0
            DispatchQueue.concurrentPerform(iterations: 32) { _ in
                if pipeline.takeUndoAttempt(now: Date(), frontmostPID: 1234) != nil {
                    lock.lock(); winners += 1; lock.unlock()
                }
            }
            XCTAssertEqual(winners, 1)
            pipeline.expansionUndoEnabled = false
            XCTAssertNil(pipeline.lastExpansion)
            pipeline.expansionUndoEnabled = true
        }
    }

    func testLongFieldWideningUsesOnlyTheCaretWindow() throws {
        let value = String(repeating: "z", count: 1_000_000) + "expanded🎓"
        let result = try XCTUnwrap(TextInjectionPipeline.widenedUndo(
            injectedText: "expanded", triggerText: "abc", value: value,
            caretLocation: value.utf16.count
        ))
        XCTAssertEqual(result.plan.expectedText, "expanded🎓")
        XCTAssertEqual(result.restore, "abc🎓")
    }

    func testPreparationUsesTheRecordedPositionWhenNewTextRepeatsTheExpansion() {
        for injected in ["a", "aa", "aba", "🎓", "e\u{0301}"] {
            for copies in 1...4 {
                let tail = String(repeating: injected, count: copies)
                guard tail.utf16.count <= TextInjectionPipeline.undoMaxTypedAfter else { continue }
                let record = TextInjectionPipeline.LastExpansion(
                    erasePlan: ErasePlan(text: "x"), injectedText: injected,
                    triggerText: "xy", bundleID: "test.editor"
                )
                let field = "prefix " + injected + tail
                XCTAssertEqual(TextInjectionPipeline.prepareUndo(
                    record: record,
                    originalRange: NSRange(location: 7 + injected.utf16.count, length: 0),
                    inputEvents: copies, field: (field, field.utf16.count, 0)
                ), .replacement(ErasePlan(text: injected + tail), "xy" + tail))
            }
        }
    }

    func testPreparationRefusesToGuessWhenOriginalPositionIsUnavailable() {
        let record = TextInjectionPipeline.LastExpansion(
            erasePlan: ErasePlan(text: "x"), injectedText: "aa", triggerText: "xy", bundleID: nil
        )
        XCTAssertEqual(TextInjectionPipeline.prepareUndo(
            record: record, originalRange: nil, inputEvents: 2, field: ("aaaa", 4, 0)
        ), .refused(.originalPosition))
        XCTAssertEqual(TextInjectionPipeline.prepareUndo(
            record: record, originalRange: NSRange(location: 2, length: 0),
            inputEvents: 0, field: ("aa!", 3, 0)
        ), .refused(.verification), "Unobserved edits cannot authorize widening.")
    }
}
