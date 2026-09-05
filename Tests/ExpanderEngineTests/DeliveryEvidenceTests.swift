import XCTest
@testable import ExpanderEngine

/// §8.4 — the delivery-evidence protocol, born from the antigravity double-input incident
/// (2026-08-07, `com.google.antigravity`).
///
/// One expansion produced three writes: HID paste #1 landed, the app's stale AX mirror kept
/// answering "expected text missing", the hold loop believed it and posted paste #2, and the
/// failure handler then *restored the trigger* on top. Two design flaws compounded:
///
///  1. The false-success condemnation was recorded role-scoped (`bundle|AXTextArea`) but the
///     delivery-trust query asked with the bundle alone — and missed it.
///  2. `unknown` apps were treated as trustworthy witnesses, so even without (1) the first
///     contact with any readable-but-lying mirror would re-paste.
///
/// The protocol these tests pin down: **corrective writes (re-paste, trigger restore) require a
/// proven truthful witness** — a `(bundle, role)` that is not condemned AND has at least one
/// earlier in-window AX-confirmed delivery. Everything else pastes once and reports unverified.
final class DeliveryEvidenceTests: XCTestCase {

    private let antigravity = "com.google.antigravity"

    // MARK: - The incident, layer by layer

    /// Flaw 1: a role-scoped condemnation must be visible to a role-aware delivery-trust query.
    func testRoleScopedCondemnationSuppressesDeliveryTrust() {
        let store = AXWriteCapabilityStore()
        let shell = "org.example.ElectronShell"
        store.recordFalseSuccess(bundleID: shell, role: "AXTextArea")

        XCTAssertFalse(
            store.canConfirmDelivery(bundleID: shell, role: "AXTextArea"),
            "The condemnation was recorded under (bundle, AXTextArea) — the role-aware query"
                + " must see it. Missing it is how the incident re-pasted."
        )
        XCTAssertFalse(store.mayActOnDeliveryFailure(bundleID: shell, role: "AXTextArea"))
        // The legacy bundle-only shim keeps its historical semantics (role isolation intact):
        // the bundle-level verdict is untouched, so bundle-only callers see no condemnation.
        XCTAssertTrue(store.canConfirmDelivery(bundleID: shell))
    }

    /// Flaw 2: `unknown` is not `proven`. A fresh app — no verdict, no history — must never have
    /// its "text missing" answer acted on. One paste, unverified outcome, field left alone.
    func testUnknownAppsAreNotTrustedWitnesses() {
        let store = AXWriteCapabilityStore()
        XCTAssertFalse(
            store.mayActOnDeliveryFailure(bundleID: "org.fresh.NeverSeen", role: "AXTextArea"),
            "Trust-until-condemned is the first-contact double-paste. Trust must be earned."
        )
        XCTAssertFalse(
            store.mayActOnDeliveryFailure(bundleID: nil, role: nil),
            "A nil bundle can never have earned proof."
        )
    }

    /// The decision walk of the incident under the new gate: a stale mirror keeps answering
    /// `.failed`, and across the entire hold window the loop must never choose a corrective
    /// action — no `.retryPaste`, no `.failConfirmed`.
    func testStaleFailedReadsNeverDriveCorrectiveActionsWithoutProof() {
        let store = AXWriteCapabilityStore()
        // As in the field: the AX write just false-succeeded and condemned (bundle, AXTextArea).
        store.recordFalseSuccess(bundleID: antigravity, role: "AXTextArea")
        let trusted = store.mayActOnDeliveryFailure(bundleID: antigravity, role: "AXTextArea")
        XCTAssertFalse(trusted)

        var consecutive = 0
        for tick in 0..<10 {
            consecutive += 1
            let elapsed = Double(tick) * 0.05
            let decision = PasteboardBroker.decidePasteHold(
                delivery: .failed,
                pasteAttemptsCompleted: 1,
                elapsed: elapsed,
                holdTimeout: 0.25,
                consecutiveFailures: consecutive,
                trustFailureVerdict: trusted
            )
            XCTAssertNotEqual(decision, .retryPaste, "tick \(tick): re-paste would duplicate")
            XCTAssertNotEqual(decision, .failConfirmed, "tick \(tick): restore would duplicate")
            XCTAssertTrue(
                decision == .waitMore || decision == .giveUpUnverified,
                "tick \(tick): only waiting or giving up unverified is safe"
            )
        }
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .failed,
                pasteAttemptsCompleted: 1,
                elapsed: 1.0,
                holdTimeout: 0.25,
                consecutiveFailures: consecutive,
                trustFailureVerdict: trusted
            ),
            .giveUpUnverified,
            "Past the hold window the outcome is unverified — never failConfirmed."
        )
    }

    /// The universality guarantee, stated as a test: the seed list is an *optimization* (it skips
    /// one doomed AX write probe on first contact), never the safety mechanism. A lying shell
    /// that no seed, no learned verdict, and no persisted file has ever heard of must already be
    /// unable to reproduce the incident — because safety comes from "unknown = unproven witness",
    /// not from enumerating broken apps. If someone ever "fixes" a new shell by adding a seed
    /// while this test fails, the fix is wrong.
    func testUnseededLyingShellIsSafeOnFirstContactWithoutAnySeed() {
        let store = AXWriteCapabilityStore()
        // A shell invented for this test — assert it is genuinely outside every seed rule, so
        // this test cannot silently start leaning on the list it exists to distrust.
        let shell = "org.devtype.tests.FutureLyingShell"
        XCTAssertEqual(AXWriteCapabilityStore.seedVerdict(bundleID: shell), .unknown)
        XCTAssertEqual(store.verdict(for: shell, role: "AXTextArea"), .unknown)

        // Corrective writes are locked before the app has ever been observed at all.
        XCTAssertFalse(store.mayActOnDeliveryFailure(bundleID: shell, role: "AXTextArea"))

        // The incident's read pattern — a readable, stale, never-changing mirror — walked across
        // the entire hold window: never a re-paste, never a confirmed failure to restore from.
        let trusted = store.mayActOnDeliveryFailure(bundleID: shell, role: "AXTextArea")
        for tick in 1...12 {
            let decision = PasteboardBroker.decidePasteHold(
                delivery: .failed,
                pasteAttemptsCompleted: 1,
                elapsed: Double(tick) * 0.05,
                holdTimeout: 0.25,
                consecutiveFailures: tick,
                trustFailureVerdict: trusted
            )
            XCTAssertNotEqual(decision, .retryPaste, "tick \(tick)")
            XCTAssertNotEqual(decision, .failConfirmed, "tick \(tick)")
        }

        // And the staleness oracle catches the same mirror one layer earlier: a read that still
        // shows the just-erased trigger is discarded before trust is even consulted.
        let stale = DeliveryVerifier.FocusedTextObservation(value: "notes slml", selectedText: nil)
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "expansion body",
                baseline: stale,
                after: stale,
                staleProbe: "slml"
            ),
            .unavailable
        )
    }

    /// Antigravity itself is now seeded, so no fresh install ever pays the first AX write.
    func testAntigravityIsSeededAsFalseSuccess() {
        XCTAssertEqual(AXWriteCapabilityStore.seedVerdict(bundleID: antigravity), .falseSuccess)
        let store = AXWriteCapabilityStore()
        XCTAssertTrue(store.shouldSkipAXSelectedText(bundleID: antigravity))
        XCTAssertFalse(store.canConfirmDelivery(bundleID: antigravity))
        // Even a (spurious) recorded confirmation cannot re-arm corrections for a condemned app.
        store.recordDeliveryConfirmed(bundleID: antigravity, role: "AXTextArea")
        XCTAssertFalse(store.mayActOnDeliveryFailure(bundleID: antigravity, role: "AXTextArea"))
    }

    // MARK: - Earning, scoping, and losing proof

    func testHistoricalDeliveryProofCannotUnlockReplay() {
        let store = AXWriteCapabilityStore()
        let app = "com.example.NativeApp"
        XCTAssertFalse(store.mayActOnDeliveryFailure(bundleID: app, role: "AXTextField"))

        store.recordDeliveryConfirmed(bundleID: app, role: "AXTextField")

        XCTAssertTrue(store.hasProvenDeliveryReads(bundleID: app, role: "AXTextField"))
        XCTAssertTrue(store.mayActOnDeliveryFailure(bundleID: app, role: "AXTextField"))
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .failed,
                pasteAttemptsCompleted: 1,
                elapsed: 0.15,
                holdTimeout: 0.25,
                consecutiveFailures: PasteboardBroker.requiredFailureConfirmations,
                trustFailureVerdict: true
            ),
            .waitMore,
            "A truthful historical observation cannot prove non-application of this paste."
        )
    }

    /// §3.3 discipline carries over: proof earned in one role must not vouch for another —
    /// a native field's truthful AX cannot re-arm corrections inside the same app's web view.
    func testProofIsRoleScopedWithBundleLevelFallback() {
        let store = AXWriteCapabilityStore()
        let app = "com.example.HybridApp"
        store.recordDeliveryConfirmed(bundleID: app, role: "AXTextField")
        XCTAssertTrue(store.mayActOnDeliveryFailure(bundleID: app, role: "AXTextField"))
        XCTAssertFalse(
            store.mayActOnDeliveryFailure(bundleID: app, role: "AXTextArea"),
            "Proof for the native field must not vouch for the web view."
        )

        // A role-less confirmation lands at bundle level and covers all roles (legacy parity
        // with `verdict(for:role:)` lookup order).
        store.recordDeliveryConfirmed(bundleID: app, role: nil)
        XCTAssertTrue(store.mayActOnDeliveryFailure(bundleID: app, role: "AXTextArea"))
    }

    /// Proof follows canonical identity: confirmed in one Chromium web app, valid for the host
    /// browser and every sibling shell.
    func testProofCanonicalizesAcrossWebAppShells() {
        let store = AXWriteCapabilityStore()
        let pwaA = "org.niche.Browser.app.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let pwaB = "org.niche.Browser.app.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        store.recordDeliveryConfirmed(bundleID: pwaA, role: "AXTextArea")
        XCTAssertTrue(store.hasProvenDeliveryReads(bundleID: pwaB, role: "AXTextArea"))
        XCTAssertTrue(store.hasProvenDeliveryReads(bundleID: "org.niche.Browser", role: "AXTextArea"))
    }

    /// Negative evidence revokes proof — an app update can regress a once-truthful mirror, and
    /// stale proof must not re-arm corrections its reads can no longer justify.
    func testNegativeEvidenceRevokesProof() {
        let store = AXWriteCapabilityStore()
        let app = "com.example.Regressed"

        store.recordDeliveryConfirmed(bundleID: app, role: "AXTextArea")
        XCTAssertTrue(store.mayActOnDeliveryFailure(bundleID: app, role: "AXTextArea"))
        _ = store.recordUnverifiableAfterWrite(bundleID: app, role: "AXTextArea")
        XCTAssertFalse(
            store.mayActOnDeliveryFailure(bundleID: app, role: "AXTextArea"),
            "One unverifiable-after-write strike suspends the corrective ladder immediately."
        )

        let other = "com.example.Regressed2"
        store.recordDeliveryConfirmed(bundleID: other, role: "AXTextArea")
        store.recordFalseSuccess(bundleID: other, role: "AXTextArea")
        XCTAssertFalse(store.mayActOnDeliveryFailure(bundleID: other, role: "AXTextArea"))
        XCTAssertFalse(
            store.hasProvenDeliveryReads(bundleID: other, role: "AXTextArea"),
            "Condemnation deletes the proof outright — it must be re-earned after rehabilitation."
        )
    }

    /// Proof survives relaunch in the same file as verdicts, without corrupting either.
    func testProofPersistsAlongsideVerdicts() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent(AXWriteCapabilityStore.persistenceFileName)

        let first = AXWriteCapabilityStore(fileURL: fileURL)
        first.recordDeliveryConfirmed(bundleID: "com.example.NativeApp", role: "AXTextField")
        first.recordFalseSuccess(bundleID: "org.example.Shell", role: "AXTextArea")
        // The save is coalesced onto a utility queue with a 0.5 s delay — wait it out.
        let deadline = Date().addingTimeInterval(3.0)
        while !FileManager.default.fileExists(atPath: fileURL.path), Date() < deadline {
            usleep(50_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let reloaded = AXWriteCapabilityStore(fileURL: fileURL)
        XCTAssertTrue(
            reloaded.hasProvenDeliveryReads(bundleID: "com.example.NativeApp", role: "AXTextField")
        )
        XCTAssertTrue(reloaded.mayActOnDeliveryFailure(bundleID: "com.example.NativeApp", role: "AXTextField"))
        XCTAssertEqual(
            reloaded.verdict(for: "org.example.Shell", role: "AXTextArea"),
            .falseSuccess,
            "Verdicts and proof share the file; neither may clobber the other."
        )
        XCTAssertFalse(
            reloaded.hasProvenDeliveryReads(bundleID: "org.example.Shell", role: "AXTextArea")
        )
    }

    // MARK: - The staleness oracle

    /// The erase removed the trigger with counted backspaces immediately before the paste. Any
    /// read still showing the trigger therefore describes a field state that no longer exists —
    /// it must be discarded as `.unavailable`, never believed as a miss.
    func testReadStillShowingTheErasedTriggerIsStaleByConstruction() {
        let stale = DeliveryVerifier.FocusedTextObservation(
            value: "some earlier prose slml",
            selectedText: nil
        )
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "the full expansion text",
                baseline: stale,
                after: stale,
                staleProbe: "slml"
            ),
            .unavailable,
            "The mirror still shows the erased trigger — its 'missing' answer is testimony"
                + " about the past."
        )
        // Absence is inconclusive even when a stale-text probe was not supplied.
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "the full expansion text",
                baseline: stale,
                after: stale,
                staleProbe: nil
            ),
            .unavailable
        )
    }

    /// Case-insensitive snippets store the snippet's casing in the plan while the field held the
    /// user's casing. The probe must fold case exactly like the erase precondition does, or a
    /// user who typed "SLML" gets no staleness protection for trigger "slml".
    func testStaleProbeFoldsCaseForCaseInsensitiveTriggers() {
        let stale = DeliveryVerifier.FocusedTextObservation(value: "notes SLML", selectedText: nil)
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "expansion body",
                baseline: stale,
                after: stale,
                staleProbe: "slml",
                staleProbeCaseInsensitive: true
            ),
            .unavailable
        )
        // Case-sensitive absence likewise cannot prove non-application.
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "expansion body",
                baseline: stale,
                after: stale,
                staleProbe: "slml",
                staleProbeCaseInsensitive: false
            ),
            .unavailable
        )
    }

    /// Adversarial timing: the user retypes the trigger *during* the hold window. The read now
    /// honestly shows the trigger — and the probe deliberately treats that the same as a stale
    /// mirror: no re-paste, no restore. Any correction here would clobber or duplicate text the
    /// user just typed; suppressing is the safe resolution both times the ambiguity can arise.
    func testUserRetypingTheTriggerDuringTheHoldSuppressesCorrections() {
        let afterRetype = DeliveryVerifier.FocusedTextObservation(
            value: "prose slml",
            selectedText: nil
        )
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "expansion body",
                baseline: DeliveryVerifier.FocusedTextObservation(value: "prose ", selectedText: nil),
                after: afterRetype,
                staleProbe: "slml"
            ),
            .unavailable,
            "Whether this read is stale or freshly shows a retyped trigger, corrective writes"
                + " must stand down."
        )
    }

    func testFreshReadsStillProduceHonestVerdictsWithProbePresent() {
        let baseline = DeliveryObservationFixture.at("prose ", 6)
        // Erased trigger and absent payload still cannot exclude pending delivery.
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "expansion",
                baseline: baseline,
                after: baseline,
                staleProbe: "slml"
            ),
            .unavailable
        )
        // Delivered text wins regardless of the probe.
        XCTAssertEqual(
            DeliveryVerifier.verifyTextDelivery(
                expectedText: "expansion",
                baseline: baseline,
                after: DeliveryObservationFixture.at("prose expansion", 15),
                staleProbe: "slml"
            ),
            .delivered
        )
    }

    // MARK: - Host trust cannot establish current-operation non-application

    /// All historical count states remain unverified until this operation has delivery evidence.
    func testProvenAppStillRequiresOperationSpecificEvidence() {
        let store = AXWriteCapabilityStore()
        let app = "com.example.Truthful"
        store.recordDeliveryConfirmed(bundleID: app, role: "AXTextArea")
        let trusted = store.mayActOnDeliveryFailure(bundleID: app, role: "AXTextArea")
        XCTAssertTrue(trusted)

        // One miss: re-read, don't act.
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .failed, pasteAttemptsCompleted: 1, maxAttempts: 2,
                elapsed: 0.05, holdTimeout: 0.25,
                consecutiveFailures: 1, trustFailureVerdict: trusted
            ),
            .waitMore
        )
        // Repeated misses with a legacy attempt budget still wait.
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .failed, pasteAttemptsCompleted: 1, maxAttempts: 2,
                elapsed: 0.10, holdTimeout: 0.25,
                consecutiveFailures: PasteboardBroker.requiredFailureConfirmations,
                trustFailureVerdict: trusted
            ),
            .waitMore
        )
        // Exhausting the legacy attempt budget cannot authorize a trigger restore.
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .failed, pasteAttemptsCompleted: 2, maxAttempts: 2,
                elapsed: 0.20, holdTimeout: 0.25,
                consecutiveFailures: PasteboardBroker.requiredFailureConfirmations,
                trustFailureVerdict: trusted
            ),
            .waitMore
        )
        // And a delivered read short-circuits to success at any point.
        XCTAssertEqual(
            PasteboardBroker.decidePasteHold(
                delivery: .delivered, pasteAttemptsCompleted: 2, maxAttempts: 2,
                elapsed: 0.20, holdTimeout: 0.25,
                consecutiveFailures: 0, trustFailureVerdict: trusted
            ),
            .succeed
        )
    }

    // MARK: - Hostile persistence

    /// A crafted (or corrupted) persistence file must not be able to mint read proof: proof
    /// requires the exact prefix AND the exact marker value together. Wrong-valued prefix keys
    /// stay ordinary entries; the empty bare key is discarded; garbage is dropped.
    func testHostilePersistenceFileCannotMintProof() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent(AXWriteCapabilityStore.persistenceFileName)

        let hostile = """
        {"version":1,"entries":{
          "deliveryRead|com.victim":"falseSuccess",
          "deliveryRead|":"confirmed",
          "deliveryRead|com.legit|AXTextArea":"confirmed",
          "com.ok":"trusted",
          "com.junk":"definitelyNotAVerdict"
        }}
        """
        try hostile.data(using: .utf8)!.write(to: fileURL)

        let store = AXWriteCapabilityStore(fileURL: fileURL)
        XCTAssertFalse(
            store.hasProvenDeliveryReads(bundleID: "com.victim", role: nil),
            "A prefix key with a non-marker value must never become proof."
        )
        XCTAssertTrue(store.hasProvenDeliveryReads(bundleID: "com.legit", role: "AXTextArea"))
        XCTAssertEqual(store.verdict(for: "com.ok"), .trusted)
        XCTAssertEqual(store.verdict(for: "com.junk"), .unknown, "Garbage raw values are dropped.")
    }

    /// Unreadable bytes and newer schema versions degrade to an empty, functioning store.
    func testCorruptAndFutureSchemaFilesDegradeGracefully() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent(AXWriteCapabilityStore.persistenceFileName)

        try Data([0xFF, 0x00, 0x42, 0x13, 0x37]).write(to: fileURL)
        let corrupt = AXWriteCapabilityStore(fileURL: fileURL)
        XCTAssertFalse(corrupt.hasProvenDeliveryReads(bundleID: "com.any", role: nil))
        corrupt.recordDeliveryConfirmed(bundleID: "com.any", role: nil)
        XCTAssertTrue(corrupt.hasProvenDeliveryReads(bundleID: "com.any", role: nil))

        try """
        {"version":\(AXWriteCapabilityStore.persistenceSchemaVersion + 1),"entries":{"deliveryRead|com.future":"confirmed"}}
        """.data(using: .utf8)!.write(to: fileURL)
        let future = AXWriteCapabilityStore(fileURL: fileURL)
        XCTAssertFalse(
            future.hasProvenDeliveryReads(bundleID: "com.future", role: nil),
            "A newer schema's semantics are unknown — relearn rather than guess."
        )
    }

    // MARK: - Concurrency

    /// Storm the store from four threads — queries, proofs, condemnations, strikes, and resets
    /// interleaving on a small key space. Two things are under test: TSAN cleanliness of the new
    /// `deliveryReadProven` state, and the safety direction of the `mayActOnDeliveryFailure`
    /// check pair (condemnation check, then proof check): because negative evidence revokes
    /// proof *inside the same critical section that condemns*, a racing caller can only ever be
    /// flipped toward `false`. At quiescence, every condemned key must answer false.
    func testConcurrentEvidenceStormKeepsTheSafetyInvariant() {
        let store = AXWriteCapabilityStore()
        let bundles = ["com.storm.a", "com.storm.b", "com.storm.c"]
        let roles: [String?] = [nil, "AXTextArea", "AXTextField"]
        let iterations = 2_500

        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            var seed = UInt64(worker) &* 0x9E3779B97F4A7C15 &+ 1
            func next() -> UInt64 {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                return seed
            }
            for _ in 0..<iterations {
                let bundle = bundles[Int(next() % UInt64(bundles.count))]
                let role = roles[Int(next() % UInt64(roles.count))]
                switch next() % 10 {
                case 0, 1, 2:
                    _ = store.mayActOnDeliveryFailure(bundleID: bundle, role: role)
                case 3, 4:
                    store.recordDeliveryConfirmed(bundleID: bundle, role: role)
                case 5:
                    store.recordFalseSuccess(bundleID: bundle, role: role)
                case 6:
                    _ = store.recordUnverifiableAfterWrite(bundleID: bundle, role: role)
                case 7:
                    _ = store.verdict(for: bundle, role: role)
                case 8:
                    _ = store.hasProvenDeliveryReads(bundleID: bundle, role: role)
                default:
                    if next() % 50 == 0 { store.reset() }
                }
            }
        }

        // Quiescent invariant: wherever the write verdict says "liar", the corrective ladder is
        // locked — regardless of how proofs and condemnations interleaved.
        for bundle in bundles {
            for role in roles where store.verdict(for: bundle, role: role) == .falseSuccess {
                XCTAssertFalse(
                    store.mayActOnDeliveryFailure(bundleID: bundle, role: role),
                    "\(bundle)|\(role ?? "-"): condemned keys must never re-arm corrections."
                )
            }
        }
    }
}
