import ApplicationServices
import Carbon.HIToolbox
import XCTest
@testable import ExpanderEngine

/// The `abctrigx` question: with text typed after the trigger up to the caret (value `abctrigx`,
/// caret at the end, plan `trig`), `ErasePreconditionChecker` downgrades the mismatch to
/// `.unavailable` — pinned by `EraseSafetyTests` for a Claude Desktop incident where the caret is
/// reported at the end of the value — and the HID backspaces that follow would delete `rigx`.
///
/// What stands between that field and those backspaces is not the checker. It is the guarantee
/// that no key can reach the field between the trigger and the erase without moving the input
/// revision the erase's continue-check reads. These tests drive that guarantee through the real
/// `handleTapEvent`, the shared ledger, and the real `EraseExecutor`:
///
///   * the control: with nothing moving the revision, the checker's `.unavailable` really does
///     let the backspaces go (the incident's shape is pinned, so this is the one protection);
///   * every route a typed key can take to the field before the erase moves the revision first,
///     including one that arrives while the executor is reading the field.
final class TapEraseGuardTests: TapEventTestCase {

    private final class RecordingBackspaces: BackspacePosting {
        var requested: [Int] = []
        func sendBackspaces(count: Int) -> Int { requested.append(count); return count }
        func sendBackspacesAsync(count: Int, completion: @escaping (Bool) -> Void) {
            requested.append(count)
            DispatchQueue.main.async { completion(true) }
        }
    }

    private let element = AXUIElementCreateApplication(getpid())
    private let terminator = SwallowedKey(didSwallow: true, unicode: " ", keyCode: Int64(kVK_Space), flags: [])
    private var claimed: (operation: InjectCompletionGuard, revision: UInt64)!

    override func setUp() {
        super.setUp()
        engine.swallowedKeyPoster = { _ in }
        XCTAssertTrue(engine.tryBeginExpansion())
        pipeline.oweSwallowedKey(terminator)
        claimed = pipeline.claimOperationForTesting()
    }

    override func tearDown() {
        abandonExpansion()
        pipeline.cancelCurrentInjection()
        claimed = nil
        super.tearDown()
    }

    private var injectIsCurrent: Bool {
        pipeline.operationIsCurrentForTesting(claimed.operation, revision: claimed.revision)
    }

    /// An executor whose field reads say `abctrigx`, caret at the end; `onFirstRead` runs inside
    /// the first read, where a key typed during the AX round trip would land.
    private func executor(
        poster: RecordingBackspaces, onFirstRead: @escaping () -> Void = {}
    ) -> EraseExecutor {
        var reads = 0
        return EraseExecutor(
            hid: poster,
            textAccess: .init(
                value: { _ in
                    reads += 1
                    if reads == 1 { onFirstRead() }
                    return "abctrigx"
                },
                selectedRange: { _ in NSRange(location: 8, length: 0) },
                stringForRange: { _, range in ("abctrigx" as NSString).substring(with: range) }
            ),
            settle: AXSettleRetry(isMainThread: { true }, sleep: { _ in }, scheduleOnMain: { _, work in work() })
        )
    }

    private func erase(_ executor: EraseExecutor) -> Bool {
        let done = expectation(description: "guarded erase")
        var result = false
        executor.performGuardedErase(
            plan: ErasePlan(text: "trig"), focus: .resolved(element),
            canProceed: { self.injectIsCurrent && self.pipeline.beginMutationForTesting(
                self.claimed.operation, revision: self.claimed.revision
            ) }
        ) { erased in
            result = erased
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        return result
    }

    /// The checker alone does not protect this field: the incident's downgrade lets it through.
    func testControlTheCheckerAloneLetsAnUnverifiableFieldBeErased() {
        let result = ErasePreconditionChecker.evaluate(
            plan: ErasePlan(text: "trig"), value: "abctrigx", caretLocation: 8, selectionLength: 0
        )
        guard case .unavailable = result else { return XCTFail("the pinned incident shape: \(result)") }

        let poster = RecordingBackspaces()
        XCTAssertTrue(erase(executor(poster: poster)), "with no key having reached the field, the erase goes")
        XCTAssertEqual(poster.requested, [4], "…and would delete the last four units, `rigx`")
    }

    /// A key that reaches the field before the erase begins refuses it, whichever way it got there.
    func testAKeyThatReachedTheFieldBeforeTheEraseRefusesIt() {
        let routes: [(String, () -> Void)] = [
            ("return", { self.key("\r", keyCode: Int64(kVK_Return)) }),
            ("backspace", { self.key("\u{7F}", keyCode: Int64(kVK_Delete)) }),
            ("chord", { self.key("v", keyCode: Int64(kVK_ANSI_V), flags: .maskCommand) }),
            ("arrow", { self.key("", keyCode: Int64(kVK_LeftArrow)) }),
            ("characterless", { self.key("", keyCode: Int64(kVK_Function)) }),
            ("click", { self.click() })
        ]
        for (name, route) in routes {
            abandonExpansion()
            XCTAssertTrue(engine.tryBeginExpansion(), name)
            pipeline.oweSwallowedKey(terminator)
            claimed = pipeline.claimOperationForTesting()

            route()

            let poster = RecordingBackspaces()
            XCTAssertFalse(erase(executor(poster: poster)), name)
            XCTAssertEqual(poster.requested, [], "\(name): the erase must not run over a key the tap saw")
        }
    }

    /// The tightest window: the key arrives while the executor is reading the field, after its
    /// first continue-check and before its last. The check that guards the backspaces runs after
    /// the read, so it sees the revision the key moved.
    func testAKeyArrivingWhileTheExecutorReadsTheFieldRefusesTheErase() {
        let poster = RecordingBackspaces()
        let executor = executor(poster: poster, onFirstRead: { self.key("", keyCode: Int64(kVK_RightArrow)) })
        let done = expectation(description: "guarded erase")
        var result = true
        executor.performGuardedErase(
            plan: ErasePlan(text: "trig"), focus: .resolved(element),
            // Current before the read; not after the key moved the revision during it.
            canProceed: { self.injectIsCurrent }
        ) { erased in
            result = erased
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(result)
        XCTAssertEqual(poster.requested, [])
    }

    /// The window between the pipeline's last gate and its first backspace — the precondition's
    /// reads (and, on a mismatch, a settle) — touches nothing. A hold that surrenders inside it
    /// must still cancel the erase AND put the terminator back; the write is claimed at the first
    /// backspace pair, not at the gate before the reads. The gates here have the shape
    /// `performInject` gives the executor: `canProceed` is a pure read, `postingContinue` claims.
    func testASurrenderDuringThePreconditionReadStillReplaysTheTerminator() {
        var terminators: [String] = []
        engine.swallowedKeyPoster = { terminators.append($0.unicode) }
        let poster = RecordingBackspaces()
        let executor = executor(poster: poster, onFirstRead: { self.key("\r", keyCode: Int64(kVK_Return)) })
        let done = expectation(description: "guarded erase")
        var result = true
        executor.performGuardedErase(
            plan: ErasePlan(text: "trig"), focus: .resolved(element),
            canProceed: { self.injectIsCurrent },
            postingContinue: {
                self.pipeline.beginMutationForTesting(self.claimed.operation, revision: self.claimed.revision)
            }
        ) { erased in
            result = erased
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertFalse(result)
        XCTAssertEqual(poster.requested, [], "nothing was erased")
        XCTAssertEqual(terminators, [" "], "and the swallowed terminator went back, once")
    }

    /// Keys the hold swallows never reach the field, so they must not refuse an erase that is
    /// otherwise safe — and our own synthetic keys must not abort the erase they belong to.
    func testHeldAndSyntheticKeysDoNotRefuseTheErase() {
        XCTAssertNil(key("x"), "held for replay after delivery")
        key("\u{8}", keyCode: Int64(kVK_Delete), synthetic: true)
        XCTAssertTrue(injectIsCurrent)

        let poster = RecordingBackspaces()
        XCTAssertTrue(erase(executor(poster: poster)))
        XCTAssertEqual(poster.requested, [4])
    }
}
