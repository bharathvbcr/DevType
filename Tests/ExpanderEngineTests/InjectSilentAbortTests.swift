import XCTest
@testable import ExpanderEngine

/// The aborts that used to drop an already-generated payload without recording anything.
///
/// The bug these cover is not "an inject was refused" — refusing is often right. It is that four
/// abort points ended in a bare `return` or a completion handed straight back to the caller, so a
/// diagnostic report showed an AI transform that *succeeded* with no inject attempt anywhere
/// beside it, and no way to tell which condition had fired. A check that could not run must never
/// leave the same trace as a check that ran and passed.
final class InjectSilentAbortTests: XCTestCase {

    // MARK: - Entry gate: every refusal is named, and named distinctly

    func testEntryGateNamesTheFirstFailingConditionInGateOrder() {
        // Superseded wins over everything else it is tested before.
        XCTAssertEqual(
            TextInjectionPipeline.entryGateRefusal(
                revisionCurrent: false,
                continuationBlock: .callerStopped,
                secureInputBlocked: true,
                axUntrusted: true,
                targetCurrent: false
            ),
            .superseded
        )
        XCTAssertEqual(
            TextInjectionPipeline.entryGateRefusal(
                revisionCurrent: true,
                continuationBlock: .callerStopped,
                secureInputBlocked: true,
                axUntrusted: true,
                targetCurrent: false
            ),
            .continuation
        )
        XCTAssertEqual(
            TextInjectionPipeline.entryGateRefusal(
                revisionCurrent: true,
                continuationBlock: nil,
                secureInputBlocked: true,
                axUntrusted: true,
                targetCurrent: false
            ),
            .secureInput
        )
        XCTAssertEqual(
            TextInjectionPipeline.entryGateRefusal(
                revisionCurrent: true,
                continuationBlock: nil,
                secureInputBlocked: false,
                axUntrusted: true,
                targetCurrent: false
            ),
            .accessibility
        )
        XCTAssertEqual(
            TextInjectionPipeline.entryGateRefusal(
                revisionCurrent: true,
                continuationBlock: nil,
                secureInputBlocked: false,
                axUntrusted: false,
                targetCurrent: false
            ),
            .targetChanged
        )
    }

    /// A caller that stopped us is a different bug report from being superseded: for the AI and
    /// palette paths it means the source app never came back to the front, which no other case
    /// implies. Every other block reason is the operation being replaced or already finished.
    func testCallerStoppedIsDistinguishedFromEveryOtherContinuationBlock() {
        XCTAssertEqual(
            TextInjectionPipeline.entryGateRefusal(
                revisionCurrent: true,
                continuationBlock: .callerStopped,
                secureInputBlocked: false,
                axUntrusted: false,
                targetCurrent: true
            ),
            .continuation
        )
        for block: InjectCompletionGuard.ContinuationBlock in [.cancelled, .timedOut, .alreadyCompleted] {
            XCTAssertEqual(
                TextInjectionPipeline.entryGateRefusal(
                    revisionCurrent: true,
                    continuationBlock: block,
                    secureInputBlocked: false,
                    axUntrusted: false,
                    targetCurrent: true
                ),
                .superseded,
                "\(block)"
            )
        }
    }

    /// The gate refused, but nothing still reports false by the time the reason is classified.
    /// That is a real race, and it is labelled rather than guessed — inventing `.targetChanged`
    /// here would send whoever reads the report after the wrong condition.
    func testUnreproducedIsNamedRatherThanGuessed() {
        XCTAssertEqual(
            TextInjectionPipeline.entryGateRefusal(
                revisionCurrent: true,
                continuationBlock: nil,
                secureInputBlocked: false,
                axUntrusted: false,
                targetCurrent: true
            ),
            .unreproduced
        )
    }

    /// Every entry-gate case must survive sanitization as its own string. Before the fix these
    /// paths did not exist, so they all fell through to the generic "Injection refused" and the
    /// report was no more useful than the silent `return` it replaced.
    func testEveryEntryGateRefusalSurvivesSanitizationDistinctly() {
        let cases: [TextInjectionPipeline.EntryGateRefusal] = [
            .superseded, .continuation, .secureInput, .accessibility, .targetChanged, .unreproduced
        ]
        var seen: [String: String] = [:]
        for refusal in cases {
            let sanitized = PermissionCoordinator.sanitizedRefusalReason(
                refusal.reason,
                path: refusal.path
            )
            XCTAssertNotEqual(sanitized, "Injection refused", "\(refusal) fell through to the generic reason")
            if let other = seen[sanitized] {
                XCTFail("\(refusal) and \(other) collapse to the same reason: \(sanitized)")
            }
            seen[sanitized] = refusal.rawValue
        }
    }

    /// `.superseded` and `.unreproduced` are allowed to differ from the erase-path wording, but
    /// the entry-gate paths must never collide with the pre-existing vocabulary by accident.
    func testEntryGatePathsAreNamespaced() {
        for refusal in [TextInjectionPipeline.EntryGateRefusal.superseded, .targetChanged] {
            XCTAssertTrue(refusal.path.hasPrefix("entryGate_"), refusal.path)
        }
    }

    // MARK: - Panel-driven delivery paths

    /// The three panel-driven deliveries each lose an already-resolved payload when the source
    /// app does not come back to the front. They are recorded under their own paths so the
    /// report says *which* panel lost it.
    func testPanelDeliveryRefusalsAreRecordedUnderDistinctPaths() {
        let paths = ["aiResultDelivery", "paletteTextDelivery", "searchExpansionDelivery"]
        for path in paths {
            let sanitized = PermissionCoordinator.sanitizedRefusalReason(
                "Source application did not return to the front",
                path: path
            )
            XCTAssertEqual(sanitized, "Source application did not return to the front", path)
        }
    }

    /// `InjectionPlanner` only refuses on a missing capability, so the reason is actionable and
    /// must reach the report intact instead of being dropped with a bare `return`.
    func testPlanRefusalKeepsTheActionableCapability() {
        XCTAssertEqual(
            PermissionCoordinator.sanitizedRefusalReason(
                "Post Events missing — terminal / shell-like paste unsupported",
                path: "aiResultPlanRefused"
            ),
            "Post Events permission is required for insertion"
        )
        XCTAssertEqual(
            PermissionCoordinator.sanitizedRefusalReason(
                "Accessibility unavailable — refusing expand (fail-closed)",
                path: "searchExpansionPlanRefused"
            ),
            "Accessibility unavailable — expansion blocked"
        )
    }

    // MARK: - Continuation guard

    /// `allowsContinuation` is the same answer as `continuationBlock`, collapsed. One owner for
    /// the rule, so the gate can never permit what the reason says it refused, or vice versa.
    func testAllowsContinuationAgreesWithTheReasonItReports() {
        let open = InjectCompletionGuard()
        XCTAssertNil(open.continuationBlock())
        XCTAssertTrue(open.allowsContinuation())

        let cancelled = InjectCompletionGuard()
        cancelled.cancel()
        XCTAssertEqual(cancelled.continuationBlock(), .cancelled)
        XCTAssertFalse(cancelled.allowsContinuation())

        let timedOut = InjectCompletionGuard()
        timedOut.markTimedOut()
        XCTAssertEqual(timedOut.continuationBlock(), .timedOut)
        XCTAssertFalse(timedOut.allowsContinuation())

        let completed = InjectCompletionGuard()
        XCTAssertEqual(completed.markCompleted(.succeeded), 1)
        XCTAssertEqual(completed.continuationBlock(), .alreadyCompleted)
        XCTAssertFalse(completed.allowsContinuation())
        // Observation-only reads tolerate a finished inject; they must not be relabelled.
        XCTAssertNil(completed.continuationBlock(observationOnly: true))
        XCTAssertTrue(completed.allowsContinuation(observationOnly: true))

        let stopped = InjectCompletionGuard(shouldContinue: { false })
        XCTAssertEqual(stopped.continuationBlock(), .callerStopped)
        XCTAssertFalse(stopped.allowsContinuation())
        XCTAssertEqual(stopped.continuationBlock(observationOnly: true), .callerStopped)
    }

    /// The caller's closure is only consulted once local state says yes — a cancelled operation
    /// must not keep calling back into AppKit-touching predicates.
    func testCallerClosureIsNotConsultedOnceLocalStateRefuses() {
        final class Counter: @unchecked Sendable {
            var calls = 0
        }
        let counter = Counter()
        let guardUnderTest = InjectCompletionGuard(shouldContinue: {
            counter.calls += 1
            return true
        })
        _ = guardUnderTest.continuationBlock()
        XCTAssertEqual(counter.calls, 1)
        guardUnderTest.cancel()
        _ = guardUnderTest.continuationBlock()
        _ = guardUnderTest.allowsContinuation()
        XCTAssertEqual(counter.calls, 1, "cancelled guard must short-circuit before the caller's closure")
    }
}
