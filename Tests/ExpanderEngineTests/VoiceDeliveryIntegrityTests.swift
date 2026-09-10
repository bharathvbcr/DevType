import XCTest
@testable import ExpanderEngine

final class VoiceDeliveryIntegrityTests: XCTestCase {
    @MainActor
    func testFinalReceiptReflectsRealInjectionOutcome() async {
        for (outcome, quality): (PermissionCoordinator.InjectOutcome, DeliveryEvidenceQuality) in [
            (.refused("moved caret"), .failed), (.failedSilent, .failed),
            (.succeeded, .verifiedDirectAX), (.degradedAXOnly, .verifiedDirectAX),
            (.postedUnverified, .settledUnverifiedPaste)
        ] {
            var edits: [VoiceReconciledEdit] = []
            let service = VoiceInsertionService(submit: { edit, completion in
                edits.append(edit)
                completion(outcome)
            })
            service.beginSession()
            let receipt = await service.deliver(text: "hello", targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0),
                                                sessionID: VoiceSessionID(), generation: SessionGeneration(rawValue: 1))
            XCTAssertEqual(edits.count, 1)
            XCTAssertEqual(receipt.evidenceQuality, quality)
            XCTAssertEqual(receipt.deliveredTextLength, quality == .failed ? 0 : 5)
            if quality == .failed { XCTAssertEqual(service.ownedText, "") }
        }
    }

    @MainActor
    func testLiveRevisionsWaitForPriorEditInsteadOfSupersedingIt() async {
        var edits: [VoiceReconciledEdit] = []
        var completions: [TextInjectionPipeline.InjectionCompletion] = []
        let service = VoiceInsertionService(submit: { edit, completion in
            edits.append(edit)
            completions.append(completion)
        }, liveMode: .typeAsYouSpeak)
        service.beginSession()
        service.applyLiveSegment(SpeechSegment(segmentID: "phrase", revision: 1, text: "hello"))
        service.applyLiveSegment(SpeechSegment(segmentID: "phrase", revision: 2, text: "hello world"))
        service.applyLiveSegment(SpeechSegment(segmentID: "phrase", revision: 3, text: "hello world again", finality: .final))
        XCTAssertEqual(edits.count, 1, "Overlapping injections cancel the earlier operation in the real pipeline")
        let pending = completions
        for completion in pending { completion(.succeeded) }
        await Task.yield()
        let remaining = Array(completions.dropFirst(pending.count))
        for completion in remaining { completion(.succeeded) }
        await Task.yield()
        XCTAssertEqual(edits.last?.resultingText, "hello world again")
    }

    @MainActor
    func testTenThousandPendingRevisionsCoalesceAndFinalDeliveryWaits() async {
        var edits: [VoiceReconciledEdit] = []
        var callbacks: [TextInjectionPipeline.InjectionCompletion] = []
        let secondPosted = expectation(description: "latest pending transcript posted")
        let service = VoiceInsertionService(submit: { edit, completion in
            edits.append(edit)
            callbacks.append(completion)
            if edits.count == 2 { secondPosted.fulfill() }
        }, liveMode: .typeAsYouSpeak)
        service.beginSession()
        for revision in 1...10_000 {
            service.applyLiveSegment(SpeechSegment(segmentID: "phrase", revision: UInt64(revision),
                                                   text: "spoken words \(revision)"))
        }
        XCTAssertEqual(edits.count, 1)
        callbacks[0](.succeeded)
        await fulfillment(of: [secondPosted], timeout: 2)
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits[1].resultingText, "spoken words 10000")
        let delivery = Task {
            await service.deliver(text: "spoken words 10000", targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0),
                                  sessionID: VoiceSessionID(), generation: SessionGeneration(rawValue: 1))
        }
        callbacks[1](.postedUnverified)
        callbacks[1](.refused("duplicate completion must be ignored"))
        let receipt = await delivery.value
        XCTAssertEqual(receipt.evidenceQuality, .settledUnverifiedPaste)
        XCTAssertEqual(service.ownedText, "spoken words 10000")
        XCTAssertEqual(edits.count, 2)
    }

    @MainActor
    func testLateFinalCompletionCannotMutateReplacementSession() async {
        var finish: TextInjectionPipeline.InjectionCompletion?
        let posted = expectation(description: "old final edit started")
        let service = VoiceInsertionService(submit: { _, completion in
            finish = completion
            posted.fulfill()
        })
        service.beginSession()
        let delivery = Task {
            await service.deliver(text: "old transcript", targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0),
                                  sessionID: VoiceSessionID(), generation: SessionGeneration(rawValue: 1))
        }
        await fulfillment(of: [posted], timeout: 2)
        service.beginSession()
        service.applyLiveSegment(SpeechSegment(segmentID: "new", text: "new transcript"))
        finish?(.refused("old request"))
        let receipt = await delivery.value
        XCTAssertEqual(receipt.evidenceQuality, .cancelled)
        XCTAssertEqual(service.recognizedText, "new transcript")
        XCTAssertEqual(service.ownedText, "")
    }

    @MainActor
    func testUncertainLiveFailureStopsFurtherErasesAndFinalDelivery() async {
        var count = 0
        let service = VoiceInsertionService(submit: { _, completion in
            count += 1
            completion(.failedSilent)
        }, liveMode: .typeAsYouSpeak)
        service.beginSession()
        service.applyLiveSegment(SpeechSegment(segmentID: "phrase", text: "hello"))
        let receipt = await service.deliver(text: "hello world", targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0),
                                            sessionID: VoiceSessionID(), generation: SessionGeneration(rawValue: 1))
        XCTAssertEqual(receipt.evidenceQuality, .failed)
        XCTAssertEqual(receipt.deliveredTextLength, 0)
        XCTAssertEqual(service.ownedText, "")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(service.rollback(), 0)
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testCancellationWithPendingLiveWriteDoesNotSpeculativelyErase() async {
        var edits: [VoiceReconciledEdit] = []
        var finish: TextInjectionPipeline.InjectionCompletion?
        let service = VoiceInsertionService(submit: { edit, completion in
            edits.append(edit)
            finish = completion
        }, liveMode: .typeAsYouSpeak)
        service.beginSession()
        service.applyLiveSegment(SpeechSegment(segmentID: "phrase", text: "not yet confirmed"))
        XCTAssertEqual(service.rollback(), 0)
        finish?(.succeeded)
        await Task.yield()
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(service.ownedText, "")
        XCTAssertEqual(service.recognizedText, "")
    }

    @MainActor
    func testSuppressedFinalEditDoesNotClaimTheNewTranscriptWasInserted() async {
        var count = 0
        let service = VoiceInsertionService(submit: { _, completion in
            count += 1
            completion(.succeeded)
        }, liveMode: .typeAsYouSpeak)
        service.beginSession()
        let text = String(repeating: "spoken ", count: 3_000).trimmingCharacters(in: .whitespaces)
        service.applyLiveSegment(SpeechSegment(segmentID: "phrase", text: text))
        let receipt = await service.deliver(text: text + " new ending", targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0),
                                            sessionID: VoiceSessionID(), generation: SessionGeneration(rawValue: 1))
        XCTAssertEqual(count, 1, "The reconciler correctly suppressed the oversized follow-up edit")
        XCTAssertEqual(receipt.evidenceQuality, .failed, "A suppressed proposal is not an inserted final transcript")
        XCTAssertEqual(receipt.deliveredTextLength, 0)
        XCTAssertEqual(service.ownedText, text)
    }

    @MainActor
    func testOldFinalCallCannotEnterANewerBoundSessionEvenWithTheSameGeneration() async {
        var count = 0
        let service = VoiceInsertionService(submit: { _, completion in
            count += 1
            completion(.succeeded)
        })
        let lease = TargetLease(bundleIdentifier: nil, processIdentifier: 0)
        let oldID = VoiceSessionID()
        let replacement = SessionTaskBag(sessionID: VoiceSessionID())
        service.beginSession(targetLease: lease, bag: replacement, generation: replacement.generation)
        let receipt = await service.deliver(text: "old session transcript", targetLease: lease,
                                            sessionID: oldID, generation: replacement.generation)
        XCTAssertEqual(receipt.evidenceQuality, .cancelled)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(service.ownedText, "")
    }

    @MainActor
    func testFinalDeliveryClosesLiveAdmissionUntilAnotherSessionBegins() async {
        var count = 0
        let service = VoiceInsertionService(submit: { _, completion in
            count += 1
            completion(.succeeded)
        }, liveMode: .typeAsYouSpeak)
        service.beginSession()
        let receipt = await service.deliver(text: "finished words", targetLease: TargetLease(bundleIdentifier: nil, processIdentifier: 0),
                                            sessionID: VoiceSessionID(), generation: SessionGeneration(rawValue: 1))
        XCTAssertEqual(receipt.evidenceQuality, .verifiedDirectAX)
        // A segment already queued on main can run before the coordinator receives the
        // final receipt and retires its bag. It must not reopen live typing in that gap.
        service.applyLiveSegment(SpeechSegment(segmentID: "late", text: "finished words extra"))
        XCTAssertEqual(count, 1)
        XCTAssertEqual(service.ownedText, "finished words")
        XCTAssertEqual(service.recognizedText, "", "Closed live admission also protects recognized state")
        service.beginSession()
        service.applyLiveSegment(SpeechSegment(segmentID: "new", text: "new session"))
        XCTAssertEqual(count, 2)
    }
}
