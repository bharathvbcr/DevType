import XCTest
@testable import ExpanderEngine

// MARK: - §8.12: the payload must outlive the host's read
//
// Reported symptom: expanding a snippet into Claude Desktop pasted the *previous clipboard
// contents* instead of the snippet. Nothing in the AI / ⌘C selection path was involved
// (`Selection reads: (none this session)` in the diagnostic report), so the substitution
// happened inside the ordinary clipboard paste.
//
// Mechanism: `pasteViaClipboard` writes the payload, posts ⌘V, polls AX for delivery, and then
// puts the user's clipboard back. The put-back is scheduled on a *timer*, and the timer is not
// evidence that the target app ever read the pasteboard. Worse, the two inputs to that timer are
// inverted with respect to risk:
//
//   1. Apps whose AX cannot confirm delivery (Electron / Chromium — Claude Desktop, Codex) end the
//      hold at `.giveUpUnverified`, which restores the clipboard *immediately*. The hosts we have
//      the least evidence about are the ones we release soonest.
//   2. `InjectTimingStore` may *shrink* the hold from learned samples. A p90 measured back when AX
//      could confirm shortens the hold for a host that today confirms nothing.
//
// Together those put the user's old clipboard back ~0.15 s after ⌘V. A busy Electron main thread
// has not processed the keystroke by then, so ⌘V lands on the restored clipboard.
//
// The tests below are split into what they prove:
//   - `characterization` tests pin the arithmetic that produced the reported 0.15 s hold.
//   - `contract` tests state the invariant the fix must establish; they fail against the pre-fix
//     source. `PasteboardBroker`'s release policy is inline control flow, not a callable seam,
//     so the pre-fix defect can only be pinned at the source level — the behavioural tests for
//     the extracted policy live in `ClipboardResidencyPolicyTests`.
final class ClipboardResidencyTests: XCTestCase {

    private static let brokerPath = "Sources/ExpanderEngine/Engine/PasteboardBroker.swift"

    private func brokerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ExpanderEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = root.appendingPathComponent(Self.brokerPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Could not read \(Self.brokerPath) at \(url.path)")
            return ""
        }
        return SourceContractTests.strippingComments(text)
    }

    /// Body of a `switch` branch, as a bounded window after its label.
    ///
    /// Deliberately crude — it exists so the assertion names the *branch* that regressed rather
    /// than searching the whole file, and a window is enough for branches this short.
    private func branchWindow(after label: String, in source: String, characters: Int = 500) -> String {
        guard let range = source.range(of: label) else {
            XCTFail("Branch `\(label)` no longer exists in \(Self.brokerPath) — the release policy moved; re-point this test at it")
            return ""
        }
        return String(source[range.upperBound...].prefix(characters))
    }

    // MARK: - Characterization: how the reported 0.15 s hold arises

    /// Learned samples shrink the hold below the blind default. This is the arithmetic behind the
    /// reported failure: Claude Desktop's hold was ~0.15 s, not the 0.35 s an unknown app gets.
    func testLearnedFastSamplesShrinkTheHoldBelowTheBlindDefault() {
        let store = InjectTimingStore()
        let bundle = "com.anthropic.claudefordesktop"
        for _ in 0..<InjectTimingStore.minSamplesForConfidence + 4 {
            store.recordDeliveryLatency(0.02, bundleID: bundle)
        }

        let learned = store.holdTimeout(bundleID: bundle)
        XCTAssertEqual(learned, InjectTiming.pasteDeliveryHoldTimeoutFloor, accuracy: 0.0001)
        XCTAssertLessThan(
            learned,
            InjectTiming.pasteDeliveryHoldTimeout,
            "characterization: a host with fast historical samples polls AX for less than half the blind window"
        )
    }

    /// The same store also shrinks the *restore* delay below the blind floor, which is what the
    /// no-`expectedText` paste path uses directly as its payload residency.
    func testLearnedFastSamplesShrinkTheRestoreDelayBelowTheBlindFloor() {
        let store = InjectTimingStore()
        let bundle = "com.anthropic.claudefordesktop"
        for _ in 0..<InjectTimingStore.minSamplesForConfidence + 4 {
            store.recordDeliveryLatency(0.02, bundleID: bundle)
        }

        XCTAssertLessThan(
            store.restoreDelay(bundleID: bundle, payloadBytes: 200),
            InjectTiming.restoreDelayFloor,
            "characterization: learned samples drop the payload residency below the unknown-app floor"
        )
    }

    // MARK: - Contract: an unverified paste may not release the payload on the spot

    /// The core inversion. `.giveUpUnverified` means "⌘V was posted and nothing ever proved the
    /// host consumed the board" — the one outcome with *no* evidence — and it restored the user's
    /// clipboard synchronously, before returning to the run loop.
    func testUnverifiedHoldMustNotRestoreTheClipboardImmediately() throws {
        let source = try brokerSource()
        let window = branchWindow(after: "case .giveUpUnverified:", in: source)

        XCTAssertFalse(
            window.contains("deferBy: nil"),
            """
            §8.12: `.giveUpUnverified` is the outcome with no delivery evidence at all — the host \
            may not have processed ⌘V yet. Restoring the user's clipboard here lets the paste land \
            on the restored contents. The payload must stay on the board for the full unverified \
            residency, measured from the ⌘V post.
            """
        )
        XCTAssertTrue(
            window.contains("releaseOwnership"),
            "§8.12: every pasteboard release must go through the single residency-aware releaser"
        )
    }

    /// A confirmed miss is also not evidence of a *read*: the field can be readable and unchanged
    /// because the host has not got to the keystroke yet.
    func testConfirmedFailureMustNotRestoreTheClipboardImmediately() throws {
        let source = try brokerSource()
        let window = branchWindow(after: "case .failConfirmed:", in: source, characters: 900)

        XCTAssertFalse(
            window.contains("deferBy: nil"),
            "§8.12: a confirmed miss releases the payload only after the unverified residency"
        )
        XCTAssertTrue(
            window.contains("releaseOwnership"),
            "§8.12: every pasteboard release must go through the single residency-aware releaser"
        )
    }

    /// The image path has the identical shape (hold, then release on a timer with no read proof)
    /// and must not be left behind — an image snippet pasting the user's old clipboard is the same
    /// bug wearing a different payload type.
    func testImageHoldMustUseTheSameResidencyReleaser() throws {
        let source = try brokerSource()
        guard let loop = source.range(of: "private func runImageHoldLoop") else {
            XCTFail("runImageHoldLoop no longer exists — re-point this test")
            return
        }
        let body = String(source[loop.upperBound...].prefix(1_400))

        XCTAssertFalse(
            body.contains("deferBy: nil"),
            "§8.12: the image hold loop released the payload with no proof the host read the board"
        )
        XCTAssertTrue(
            body.contains("releaseOwnership"),
            "§8.12: image paste and text paste must share one release policy, not two"
        )
    }

    /// The residency invariant only holds if a ⌘V cannot be posted by anyone who has not taken
    /// ownership of the board. `TextInjectionPipeline` re-exported a bare `postCmdVKeyEvents()`
    /// (no callers) that did exactly that: post a paste against whatever happened to be on the
    /// clipboard, with no ticket, no snapshot and no restore.
    func testOnlyTheBrokerMayPostAPaste() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)

        guard let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate Sources")
            return
        }

        var posters: Set<String> = []
        for case let url as URL in files where url.pathExtension == "swift" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard SourceContractTests.strippingComments(raw).contains("postCmdVKeyEvents") else { continue }
            posters.insert(url.lastPathComponent)
        }

        XCTAssertEqual(
            posters,
            ["PasteboardBroker.swift", "HIDKeyPoster.swift"],
            """
            §8.12: ⌘V may only be posted by `PasteboardBroker`, which owns the snapshot, the \
            ticket and the residency. A paste posted from anywhere else lands on whatever is on \
            the board — which is the bug this section exists to prevent. Found: \
            \(posters.sorted().joined(separator: ", "))
            """
        )
    }

    /// Structural: `deferBy` was an ad-hoc delay applied from wherever the caller happened to be.
    /// Residency is a property of the ⌘V, so the deadline must be absolute and computed once.
    func testReleaseDelayIsNotAnAdHocPerCallSiteDelay() throws {
        let source = try brokerSource()
        XCTAssertFalse(
            source.contains("deferBy:"),
            """
            §8.12: `deferBy:` measured the wait from whenever the caller finished, so an outcome \
            that took 0.3 s to reach held the payload 0.3 s longer than one that took 0 s. \
            Residency belongs to the ⌘V post, so the releaser takes an absolute deadline.
            """
        )
    }
}
