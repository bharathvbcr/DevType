import AppKit
import XCTest
@testable import ExpanderEngine

final class UserClipboardWriteTests: XCTestCase {
    private func snapshot(_ string: String) -> PasteboardBroker.PasteboardSnapshot {
        [[.string: Data(string.utf8)]]
    }

    func testFailedUserWriteRestoresTheBoundedPriorSnapshot() {
        let broker = PasteboardBroker()
        let prior: PasteboardBroker.PasteboardSnapshot = [[
            .string: Data("precious clipboard".utf8),
            .rtf: Data([0x7B, 0x5C, 0x72, 0x74, 0x66, 0x31, 0x7D]),
        ]]
        var changeCount = 40
        var restored: PasteboardBroker.PasteboardSnapshot?
        let generationBefore = broker.currentRestoreGeneration()

        let outcome = broker.performUserClipboardWrite(
            "new value",
            priorSnapshot: prior,
            operations: .init(
                clearContents: {
                    changeCount += 1
                    return changeCount
                },
                currentChangeCount: { changeCount },
                setString: { _ in false },
                restoreSnapshot: { candidate, ownedChangeCount in
                    guard changeCount == ownedChangeCount else { return .ownershipLost }
                    restored = candidate
                    return .restored
                }
            )
        )

        XCTAssertEqual(outcome, .writeFailedPriorRestored)
        XCTAssertEqual(restored, prior)
        XCTAssertGreaterThan(
            broker.currentRestoreGeneration(), generationBefore,
            "A deliberate copy attempt must invalidate any deferred expansion restore even when the write fails."
        )
    }

    func testFailedUserWriteNeverRestoresOverAConcurrentOwner() {
        let broker = PasteboardBroker()
        var changeCount = 70
        var restoreRan = false

        let outcome = broker.performUserClipboardWrite(
            "new value",
            priorSnapshot: snapshot("old value"),
            operations: .init(
                clearContents: {
                    changeCount += 1
                    return changeCount
                },
                currentChangeCount: { changeCount },
                setString: { _ in
                    // Another process takes the board before AppKit reports our failure.
                    changeCount += 1
                    return false
                },
                restoreSnapshot: { _, _ in
                    restoreRan = true
                    return .restored
                }
            )
        )

        XCTAssertEqual(outcome, .ownershipLost)
        XCTAssertFalse(
            restoreRan,
            "Recovery must leave a newer pasteboard owner strictly alone."
        )
    }

    func testRecoveryRechecksOwnershipAtTheRestoreBoundary() {
        let broker = PasteboardBroker()
        var changeCount = 10

        let outcome = broker.performUserClipboardWrite(
            "new value",
            priorSnapshot: snapshot("old value"),
            operations: .init(
                clearContents: {
                    changeCount += 1
                    return changeCount
                },
                currentChangeCount: { changeCount },
                setString: { _ in false },
                restoreSnapshot: { _, ownedChangeCount in
                    changeCount += 1 // owner changes after the first failure check
                    return changeCount == ownedChangeCount ? .restored : .ownershipLost
                }
            )
        )

        XCTAssertEqual(outcome, .ownershipLost)
    }

    func testSuccessfulWriteReturnsTruthfulSuccessWithoutRecovery() {
        let broker = PasteboardBroker()
        var changeCount = 5
        var restored = false

        let outcome = broker.performUserClipboardWrite(
            "new value",
            priorSnapshot: snapshot("old value"),
            operations: .init(
                clearContents: {
                    changeCount += 1
                    return changeCount
                },
                currentChangeCount: { changeCount },
                setString: { _ in true },
                restoreSnapshot: { _, _ in
                    restored = true
                    return .restored
                }
            )
        )

        XCTAssertEqual(outcome, .written)
        XCTAssertTrue(outcome.didWrite)
        XCTAssertFalse(restored)
    }

    func testFailedWriteWithNoRestorableSnapshotIsNotSuccess() {
        let broker = PasteboardBroker()
        var changeCount = 1

        let outcome = broker.performUserClipboardWrite(
            "new value",
            priorSnapshot: nil,
            operations: .init(
                clearContents: {
                    changeCount += 1
                    return changeCount
                },
                currentChangeCount: { changeCount },
                setString: { _ in false },
                restoreSnapshot: { _, _ in
                    XCTFail("There is no snapshot to restore")
                    return .restored
                }
            )
        )

        XCTAssertEqual(outcome, .writeFailedNoPriorSnapshot)
        XCTAssertFalse(outcome.didWrite)
    }

    func testFailedRecoveryRemainsAFailureAndIsAttemptedOnlyOnce() {
        let broker = PasteboardBroker()
        var changeCount = 20
        var restoreAttempts = 0

        let outcome = broker.performUserClipboardWrite(
            "new value",
            priorSnapshot: snapshot("old value"),
            operations: .init(
                clearContents: {
                    changeCount += 1
                    return changeCount
                },
                currentChangeCount: { changeCount },
                setString: { _ in false },
                restoreSnapshot: { _, ownedChangeCount in
                    XCTAssertEqual(changeCount, ownedChangeCount)
                    restoreAttempts += 1
                    return .failed
                }
            )
        )

        XCTAssertEqual(outcome, .writeFailedRestoreFailed)
        XCTAssertFalse(outcome.didWrite)
        XCTAssertEqual(restoreAttempts, 1, "Recovery is synchronous and bounded to one attempt.")
    }

    func testRefusedFlavorRejectsTheWholeRecoveryBeforePasteboardWrite() {
        let prior: PasteboardBroker.PasteboardSnapshot = [[
            .string: Data("plain".utf8),
            .rtf: Data([0x7B, 0x5C, 0x72, 0x74, 0x66, 0x31, 0x7D]),
        ]]
        var attemptedTypes = Set<NSPasteboard.PasteboardType>()
        var representationAttempts = 0
        var writeObjectsRan = false

        let outcome = PasteboardBroker.restoreUserClipboardSnapshot(
            prior,
            ownedChangeCount: 42,
            clearContents: { XCTFail("Invalid reconstruction must not clear"); return 43 },
            currentChangeCount: { 42 },
            setData: { item, data, type in
                attemptedTypes.insert(type)
                representationAttempts += 1
                guard representationAttempts < 2 else { return false }
                return item.setData(data, forType: type)
            },
            writeObjects: { _ in
                writeObjectsRan = true
                return true
            }
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(attemptedTypes, Set([.string, .rtf]))
        XCTAssertEqual(representationAttempts, 2, "One accepted flavor followed by one refusal exercises partial reconstruction.")
        XCTAssertFalse(
            writeObjectsRan,
            "A reduced-flavor item must never reach writeObjects and masquerade as a complete restore."
        )
    }

    func testSnapshotRecoveryLeavesAnOwnerWhoArrivesDuringReconstructionAlone() {
        var changeCount = 42
        var writeObjectsRan = false

        let outcome = PasteboardBroker.restoreUserClipboardSnapshot(
            snapshot("old value"),
            ownedChangeCount: 42,
            clearContents: { XCTFail("External ownership must not clear"); return 43 },
            currentChangeCount: { changeCount },
            setData: { item, data, type in
                let accepted = item.setData(data, forType: type)
                changeCount += 1 // an external owner arrives while local items are rebuilt
                return accepted
            },
            writeObjects: { _ in
                writeObjectsRan = true
                return true
            }
        )

        XCTAssertEqual(outcome, .ownershipLost)
        XCTAssertFalse(writeObjectsRan)
    }

    func testDiagnosticAndRecoveryCopiesUseTheCanonicalBroker() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let diagnostics = try String(
            contentsOf: root.appendingPathComponent("Sources/ExpanderEngine/Logging/DiagnosticReport.swift"),
            encoding: .utf8
        )
        let recovery = try String(
            contentsOf: root.appendingPathComponent("Sources/DevTypeAppCore/RecoveredDictationWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(diagnostics.contains("PasteboardBroker.shared.writeUserClipboardString(text)"))
        XCTAssertFalse(diagnostics.contains("pasteboard.clearContents()"))
        XCTAssertTrue(recovery.contains("PasteboardBroker.shared.writeUserClipboardString(text)"))
        XCTAssertFalse(
            recovery.contains("board.clearContents()"),
            "Recovered dictation must not maintain a second clear-then-write implementation."
        )
    }
}
