import Foundation
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

final class SnippetEditTransactionTests: XCTestCase {
    private final class Resources {
        var events: [String] = []
        var images: Set<String> = []
        var secrets: [UUID: String] = [:]
        var importedPath = "staged.png"
        var failImageImport = false
        var failSecretStore = false
        var failSecretRemove = false
        var imageDeleteFailuresRemaining = 0
        var protectedSecretIDs: [UUID] = []

        func access() -> SnippetEditResourceAccess {
            SnippetEditResourceAccess(
                importImage: { [self] _ in
                    events.append("image.import")
                    guard !failImageImport else { return .failure(.unavailable) }
                    images.insert(importedPath)
                    return .success(importedPath)
                },
                deleteImage: { [self] path in
                    events.append("image.delete:\(path)")
                    if imageDeleteFailuresRemaining > 0 {
                        imageDeleteFailuresRemaining -= 1
                        return .failure(.unavailable)
                    }
                    images.remove(path)
                    return .success(())
                },
                readSecret: { [self] id in
                    events.append("secret.read")
                    if let value = secrets[id] { return .value(value) }
                    return .missing
                },
                storeSecret: { [self] value, id in
                    events.append("secret.store:\(value)")
                    guard !failSecretStore else { return .failure(.unavailable) }
                    secrets[id] = value
                    return .success(())
                },
                removeSecret: { [self] id in
                    events.append("secret.remove")
                    guard !failSecretRemove else { return .failure(.unavailable) }
                    secrets.removeValue(forKey: id)
                    return .success(())
                },
                protectSecretFromOrphanPurge: { [self] id in
                    events.append("secret.protect")
                    protectedSecretIDs.append(id)
                    return nil
                }
            )
        }
    }

    private func snippet(
        id: UUID = UUID(),
        imagePath: String = "",
        isSecret: Bool = false,
        replacement: String = "body"
    ) -> SnippetModel {
        SnippetModel(
            id: id,
            title: "Example",
            triggerKeyword: ":example",
            replacementText: replacement,
            imagePath: imagePath,
            isSecret: isSecret
        )
    }

    private func receipt(
        _ resources: Resources,
        outcome: SnippetStore.SaveOutcome = .saved,
        rollbackOutcome: SnippetStore.SaveOutcome = .saved,
        captured: ((SnippetModel) -> Void)? = nil
    ) -> (SnippetModel, UUID?) -> SnippetEditorPersistenceReceipt {
        { candidate, _ in
            resources.events.append("library.persist")
            captured?(candidate)
            return SnippetEditorPersistenceReceipt(
                outcome: outcome,
                rollback: {
                    resources.events.append("library.rollback")
                    return rollbackOutcome
                },
                finalize: { resources.events.append("library.finalize") }
            )
        }
    }

    func testNewImageStagesBeforePersistenceAndFinalizesWithoutCleanup() {
        let resources = Resources()
        let transaction = SnippetEditTransaction(resources: resources.access())
        var persisted: SnippetModel?

        let outcome = transaction.save(
            snippet: snippet(replacement: ""),
            existing: nil,
            pickedImageURL: URL(fileURLWithPath: "/tmp/source.png"),
            secretIntent: .remove,
            groupID: nil,
            persist: receipt(resources, captured: { persisted = $0 })
        )

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(persisted?.imagePath, "staged.png")
        XCTAssertEqual(resources.images, ["staged.png"])
        XCTAssertEqual(resources.events, ["image.import", "library.persist", "library.finalize"])
    }

    func testImageReplacementDeletesOldAttachmentOnlyAfterPersistenceLands() {
        let resources = Resources()
        resources.images = ["old.png"]
        let old = snippet(imagePath: "old.png", replacement: "")
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: old,
            existing: old,
            pickedImageURL: URL(fileURLWithPath: "/tmp/source.png"),
            secretIntent: .remove,
            groupID: nil,
            persist: receipt(resources)
        )

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(resources.images, ["staged.png"])
        XCTAssertEqual(
            resources.events,
            ["image.import", "library.persist", "image.delete:old.png", "library.finalize"]
        )
    }

    func testImageRemovalDeletesOldAttachmentOnlyAfterPersistenceLands() {
        let resources = Resources()
        resources.images = ["old.png"]
        let old = snippet(imagePath: "old.png", replacement: "")
        var candidate = old
        candidate.imagePath = ""
        candidate.replacementText = "now text"
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: candidate,
            existing: old,
            pickedImageURL: nil,
            secretIntent: .remove,
            groupID: nil,
            persist: receipt(resources)
        )

        XCTAssertEqual(outcome, .committed)
        XCTAssertTrue(resources.images.isEmpty)
        XCTAssertEqual(
            resources.events,
            ["library.persist", "image.delete:old.png", "library.finalize"]
        )
    }

    func testSecretCreateStagesValueBeforePersistence() {
        let resources = Resources()
        let id = UUID()
        var candidate = snippet(id: id, replacement: "")
        candidate.isSecret = true
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: candidate,
            existing: nil,
            pickedImageURL: nil,
            secretIntent: .set("new value"),
            groupID: nil,
            persist: receipt(resources)
        )

        XCTAssertEqual(outcome, .committed)
        XCTAssertEqual(resources.secrets[id], "new value")
        XCTAssertEqual(resources.protectedSecretIDs, [id])
        XCTAssertEqual(
            resources.events,
            ["secret.protect", "secret.read", "secret.store:new value", "library.persist", "library.finalize"]
        )
    }

    func testUnchangedSecretProtectsBeforeReadAndRefusesAnAbsentValue() {
        let resources = Resources()
        let id = UUID()
        let old = snippet(id: id, isSecret: true, replacement: "")
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: old,
            existing: old,
            pickedImageURL: nil,
            secretIntent: .unchanged,
            groupID: nil,
            persist: { _, _ in
                XCTFail("An absent unchanged secret must not be published.")
                return .refused(.failed("unexpected"))
            }
        )

        XCTAssertEqual(outcome, .failed(.secretRead))
        XCTAssertEqual(resources.protectedSecretIDs, [id])
        XCTAssertEqual(resources.events, ["secret.protect", "secret.read"])
    }

    func testSecretUpdateRestoresPriorValueWhenSaveIsRefused() {
        let resources = Resources()
        let id = UUID()
        resources.secrets[id] = "prior value"
        let old = snippet(id: id, isSecret: true, replacement: "")
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: old,
            existing: old,
            pickedImageURL: nil,
            secretIntent: .set("replacement value"),
            groupID: nil,
            persist: receipt(resources, outcome: .blockedByRemoteChange)
        )

        XCTAssertEqual(outcome, .failed(.persistence(.blockedByRemoteChange)))
        XCTAssertEqual(resources.secrets[id], "prior value")
        XCTAssertEqual(
            resources.events,
            [
                "secret.protect", "secret.read", "secret.store:replacement value", "library.persist",
                "secret.store:prior value"
            ]
        )
    }

    func testSecretRemovalWaitsUntilPersistenceLands() {
        let resources = Resources()
        let id = UUID()
        resources.secrets[id] = "prior value"
        let old = snippet(id: id, isSecret: true, replacement: "")
        var candidate = old
        candidate.isSecret = false
        candidate.replacementText = "ordinary"
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: candidate,
            existing: old,
            pickedImageURL: nil,
            secretIntent: .remove,
            groupID: nil,
            persist: receipt(resources)
        )

        XCTAssertEqual(outcome, .committed)
        XCTAssertNil(resources.secrets[id])
        XCTAssertEqual(
            resources.events,
            ["library.persist", "secret.remove", "library.finalize"]
        )
    }

    func testSaveRefusalRollsBackNewImageAndDoesNotFinalizeHost() {
        let resources = Resources()
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: snippet(replacement: ""),
            existing: nil,
            pickedImageURL: URL(fileURLWithPath: "/tmp/source.png"),
            secretIntent: .remove,
            groupID: nil,
            persist: receipt(resources, outcome: .blockedByNewerSchema)
        )

        XCTAssertEqual(outcome, .failed(.persistence(.blockedByNewerSchema)))
        XCTAssertTrue(resources.images.isEmpty)
        XCTAssertEqual(
            resources.events,
            ["image.import", "library.persist", "image.delete:staged.png"]
        )
    }

    func testKeychainWriteFailureStopsBeforeLibraryPersistence() {
        let resources = Resources()
        resources.failSecretStore = true
        var candidate = snippet(replacement: "")
        candidate.isSecret = true
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: candidate,
            existing: nil,
            pickedImageURL: nil,
            secretIntent: .set("new value"),
            groupID: nil,
            persist: { _, _ in
                XCTFail("Persistence must not run after a Keychain failure")
                return .refused(.failed("unexpected"))
            }
        )

        XCTAssertEqual(outcome, .failed(.secretWrite))
        XCTAssertTrue(resources.images.isEmpty)
        XCTAssertEqual(resources.events, ["secret.protect", "secret.read", "secret.store:new value"])
    }

    func testImageImportFailureStopsBeforePersistenceWithoutCreatingAnAsset() {
        let resources = Resources()
        resources.failImageImport = true
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: snippet(replacement: ""),
            existing: nil,
            pickedImageURL: URL(fileURLWithPath: "/tmp/source.png"),
            secretIntent: .remove,
            groupID: nil,
            persist: { _, _ in
                XCTFail("Persistence must not run after an image staging failure")
                return .refused(.failed("unexpected"))
            }
        )

        XCTAssertEqual(outcome, .failed(.imageStaging))
        XCTAssertTrue(resources.images.isEmpty)
        XCTAssertEqual(resources.events, ["image.import"])
    }

    func testKeychainRemovalFailureRestoresPreviousLibraryAndKeepsSecret() {
        let resources = Resources()
        resources.failSecretRemove = true
        let id = UUID()
        resources.secrets[id] = "prior value"
        let old = snippet(id: id, isSecret: true, replacement: "")
        var candidate = old
        candidate.isSecret = false
        candidate.replacementText = "ordinary"
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: candidate,
            existing: old,
            pickedImageURL: nil,
            secretIntent: .remove,
            groupID: nil,
            persist: receipt(resources)
        )

        XCTAssertEqual(outcome, .failed(.commitCleanup))
        XCTAssertEqual(resources.secrets[id], "prior value")
        XCTAssertEqual(
            resources.events,
            ["library.persist", "secret.remove", "library.rollback"]
        )
    }

    func testRollbackFailureIsRetainedAndCancelRetriesCleanupInsteadOfLeakingStage() {
        let resources = Resources()
        resources.imageDeleteFailuresRemaining = 1
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: snippet(replacement: ""),
            existing: nil,
            pickedImageURL: URL(fileURLWithPath: "/tmp/source.png"),
            secretIntent: .remove,
            groupID: nil,
            persist: receipt(resources, outcome: .failed("disk refused"))
        )

        XCTAssertEqual(outcome, .failed(.rollback))
        XCTAssertEqual(resources.images, ["staged.png"])
        XCTAssertEqual(transaction.cancel(), .clean)
        XCTAssertTrue(resources.images.isEmpty)
        XCTAssertEqual(
            resources.events,
            [
                "image.import", "library.persist", "image.delete:staged.png",
                "image.delete:staged.png"
            ]
        )
    }

    func testCommitCleanupFailureRestoresLibraryThenRollsBackNewResources() {
        let resources = Resources()
        resources.images = ["old.png"]
        // First delete (old attachment) fails; deleting the new stage succeeds.
        resources.imageDeleteFailuresRemaining = 1
        let old = snippet(imagePath: "old.png", replacement: "")
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: old,
            existing: old,
            pickedImageURL: URL(fileURLWithPath: "/tmp/source.png"),
            secretIntent: .remove,
            groupID: nil,
            persist: receipt(resources)
        )

        XCTAssertEqual(outcome, .failed(.commitCleanup))
        XCTAssertEqual(resources.images, ["old.png"])
        XCTAssertEqual(
            resources.events,
            [
                "image.import", "library.persist", "image.delete:old.png",
                "library.rollback", "image.delete:staged.png"
            ]
        )
    }

    func testLibraryRollbackFailureKeepsCommittedResourcesAndFinalizesActualLibraryState() {
        let resources = Resources()
        resources.images = ["old.png"]
        resources.imageDeleteFailuresRemaining = 1
        let old = snippet(imagePath: "old.png", replacement: "")
        let transaction = SnippetEditTransaction(resources: resources.access())

        let outcome = transaction.save(
            snippet: old,
            existing: old,
            pickedImageURL: URL(fileURLWithPath: "/tmp/source.png"),
            secretIntent: .remove,
            groupID: nil,
            persist: receipt(resources, rollbackOutcome: .failed("rollback refused"))
        )

        XCTAssertEqual(outcome, .committedWithWarning(.libraryRollback))
        XCTAssertEqual(resources.images, ["old.png", "staged.png"])
        XCTAssertEqual(
            resources.events,
            [
                "image.import", "library.persist", "image.delete:old.png",
                "library.rollback", "library.finalize"
            ]
        )
    }

    func testCancelBeforeSaveTouchesNoResourcesOrPersistence() {
        let resources = Resources()
        let transaction = SnippetEditTransaction(resources: resources.access())

        XCTAssertEqual(transaction.cancel(), .clean)
        XCTAssertTrue(resources.events.isEmpty)
        XCTAssertTrue(resources.images.isEmpty)
        XCTAssertTrue(resources.secrets.isEmpty)
    }

    func testLibraryEditMovesAnExistingSnippetWithoutMutatingInput() throws {
        let firstID = UUID()
        let secondID = UUID()
        let original = snippet()
        let groups = [
            SnippetGroup(id: firstID, name: "First", snippets: [original]),
            SnippetGroup(id: secondID, name: "Second")
        ]
        var edited = original
        edited.title = "Edited"

        let result = try XCTUnwrap(
            SnippetLibraryEdit.applying(
                snippet: edited,
                existingID: original.id,
                chosenGroupID: secondID,
                fallbackGroupID: firstID,
                to: groups
            )
        )

        XCTAssertEqual(groups[0].snippets, [original])
        XCTAssertTrue(result[0].snippets.isEmpty)
        XCTAssertEqual(result[1].snippets, [edited])
        XCTAssertNil(
            SnippetLibraryEdit.applying(
                snippet: edited,
                existingID: UUID(),
                chosenGroupID: secondID,
                fallbackGroupID: firstID,
                to: groups
            )
        )
    }

    func testModelOnlyUndoIsRefusedWhenItCouldNotRestoreAResource() {
        let text = snippet()
        let image = snippet(imagePath: "image.png", replacement: "")
        let secret = snippet(isSecret: true, replacement: "")

        XCTAssertTrue(SnippetLibraryEdit.supportsModelOnlyUndo(existing: nil, candidate: text))
        XCTAssertFalse(SnippetLibraryEdit.supportsModelOnlyUndo(existing: nil, candidate: image))
        XCTAssertFalse(SnippetLibraryEdit.supportsModelOnlyUndo(existing: nil, candidate: secret))
        XCTAssertTrue(SnippetLibraryEdit.supportsModelOnlyUndo(existing: image, candidate: image))

        var removedImage = image
        removedImage.imagePath = ""
        removedImage.replacementText = "text"
        XCTAssertFalse(SnippetLibraryEdit.supportsModelOnlyUndo(existing: image, candidate: removedImage))

        var changedSecret = secret
        changedSecret.title = "Renamed"
        XCTAssertFalse(SnippetLibraryEdit.supportsModelOnlyUndo(existing: secret, candidate: changedSecret))
    }

    func testSecretModeDraftRestoresTypedReplacementAfterRoundTrip() {
        var draft = SnippetSecretModeDraft(isSecret: false)

        XCTAssertEqual(
            draft.transition(toSecret: true, currentReplacement: "typed before toggle"),
            ""
        )
        XCTAssertTrue(draft.isSecret)
        XCTAssertEqual(
            draft.transition(toSecret: false, currentReplacement: ""),
            "typed before toggle"
        )
        XCTAssertFalse(draft.isSecret)
    }

    func testSecretModeDraftRecapturesEditsAcrossRepeatedToggleCycles() {
        var draft = SnippetSecretModeDraft(isSecret: false)

        _ = draft.transition(toSecret: true, currentReplacement: "first draft")
        XCTAssertEqual(draft.transition(toSecret: false, currentReplacement: ""), "first draft")
        _ = draft.transition(toSecret: true, currentReplacement: "edited draft")
        XCTAssertEqual(draft.transition(toSecret: false, currentReplacement: ""), "edited draft")
    }

    func testSecretModeTransitionRequiresConfirmationBeforeRemovingImage() {
        XCTAssertEqual(
            SnippetSecretModeTransition.resolve(isSecret: false, hasImage: true),
            .confirmImageRemoval
        )
        XCTAssertEqual(
            SnippetSecretModeTransition.resolve(isSecret: false, hasImage: false),
            .enable
        )
        XCTAssertEqual(
            SnippetSecretModeTransition.resolve(isSecret: true, hasImage: true),
            .disable
        )
    }

    func testCanonicalTriggerValidationFindsExactCaseAndPrefixConflicts() throws {
        let exact = snippet()
        var caseSensitive = snippet()
        caseSensitive.triggerKeyword = ":Mixed"
        caseSensitive.isCaseSensitive = true
        var prefix = snippet()
        prefix.triggerKeyword = "`short"
        prefix.requireWordBoundary = true
        let groups = [SnippetGroup(name: "Existing", snippets: [exact, caseSensitive, prefix])]

        XCTAssertEqual(
            SnippetTriggerAuthoringValidator.conflict(
                trigger: exact.triggerKeyword,
                caseSensitive: exact.isCaseSensitive,
                requireWordBoundary: exact.requireWordBoundary,
                excludingID: nil,
                groups: groups,
                detectionEnabled: true
            )?.kind,
            .duplicateTrigger
        )
        XCTAssertEqual(
            SnippetTriggerAuthoringValidator.conflict(
                trigger: ":mixed",
                caseSensitive: false,
                requireWordBoundary: true,
                excludingID: nil,
                groups: groups,
                detectionEnabled: true
            )?.kind,
            .caseShadow
        )
        let prefixConflict = try XCTUnwrap(
            SnippetTriggerAuthoringValidator.conflict(
                trigger: "`shorter",
                caseSensitive: false,
                requireWordBoundary: true,
                excludingID: nil,
                groups: groups,
                detectionEnabled: true
            )
        )
        XCTAssertEqual(prefixConflict.kind, .prefixShadow)
        XCTAssertEqual(prefixConflict.trigger, "`short")
        XCTAssertEqual(prefixConflict.blockedTriggers, ["`shorter"])
    }

    func testCanonicalTriggerValidationExcludesTheSnippetBeingEdited() {
        let existing = snippet()
        let groups = [SnippetGroup(name: "Existing", snippets: [existing])]

        XCTAssertNil(
            SnippetTriggerAuthoringValidator.conflict(
                trigger: existing.triggerKeyword,
                caseSensitive: existing.isCaseSensitive,
                requireWordBoundary: existing.requireWordBoundary,
                excludingID: existing.id,
                groups: groups,
                detectionEnabled: true
            )
        )
    }

    func testCanonicalTriggerValidationHasOneExplicitGlobalOptOut() {
        let existing = snippet()
        let groups = [SnippetGroup(name: "Existing", snippets: [existing])]

        XCTAssertNil(
            SnippetTriggerAuthoringValidator.conflict(
                trigger: existing.triggerKeyword,
                caseSensitive: existing.isCaseSensitive,
                requireWordBoundary: existing.requireWordBoundary,
                excludingID: nil,
                groups: groups,
                detectionEnabled: false
            )
        )
    }

    func testLibraryMutationRefusesTriggerConflictEvenWithoutHostPrevalidation() {
        let existing = snippet()
        var colliding = snippet()
        colliding.triggerKeyword = existing.triggerKeyword.uppercased()
        colliding.isCaseSensitive = false
        let groups = [SnippetGroup(name: "Existing", snippets: [existing])]

        XCTAssertNil(
            SnippetLibraryEdit.applying(
                snippet: colliding,
                existingID: nil,
                chosenGroupID: groups[0].id,
                fallbackGroupID: groups[0].id,
                to: groups,
                conflictDetectionEnabled: true
            )
        )
    }

    func testNewEditorSafetyCopyExistsInEveryLanguage() {
        let keys = [
            "editor.image.removeConfirm.title",
            "editor.image.removeConfirm.message",
            "editor.image.removeConfirm.confirm",
            "editor.secret.removeImage.title",
            "editor.secret.removeImage.message",
            "editor.secret.removeImage.confirm",
            "editor.error.conflict.duplicate",
            "editor.error.conflict.caseShadow",
            "editor.error.conflict.prefixShadow",
        ]
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for key in keys {
                XCTAssertNotNil(table[key], "\(language.rawValue) is missing \(key)")
            }
        }
    }

    func testEditorPersistenceRebasesOntoLatestLibraryAndConditionalRollbackPreservesNewerWork() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeEditorAtomic-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnippetStore(
            location: .init(
                fileURL: directory.appendingPathComponent("snippets.json"),
                expectsExistingLibrary: false
            ),
            watcherFactory: { _ in nil },
            secretPurgeEnabled: false
        )

        let original = snippet()
        let group = SnippetGroup(name: "General", snippets: [original])
        XCTAssertEqual(store.saveGroups([group]), .saved)

        // The sheet rendered this model before another surface added a snippet.
        let renderedExisting = original
        var concurrent = store.loadGroups()
        concurrent[0].snippets.append(SnippetModel(
            title: "Concurrent",
            triggerKeyword: ":concurrent",
            replacementText: "keep"
        ))
        XCTAssertEqual(store.saveGroups(concurrent), .saved)

        var edited = original
        edited.title = "Edited"
        var finalizedBefore: [SnippetGroup]?
        var finalizedAfter: [SnippetGroup]?
        let receipt = SnippetEditorPersistenceReceipt.mutating(
            store: store,
            mutation: { latest in
                guard latest.flatMap(\.snippets).first(where: { $0.id == original.id }) == renderedExisting,
                      let after = SnippetLibraryEdit.applying(
                        snippet: edited,
                        existingID: original.id,
                        chosenGroupID: group.id,
                        fallbackGroupID: group.id,
                        to: latest
                      ) else { return false }
                latest = after
                return true
            },
            finalize: { before, after in
                finalizedBefore = before
                finalizedAfter = after
            }
        )

        XCTAssertEqual(receipt.outcome, .saved)
        receipt.finalize()
        XCTAssertEqual(finalizedBefore, concurrent)
        XCTAssertEqual(finalizedAfter, store.loadGroups())
        XCTAssertEqual(
            store.loadGroups().flatMap(\.snippets).first(where: { $0.id == original.id })?.title,
            "Edited"
        )
        XCTAssertNotNil(
            store.loadGroups().flatMap(\.snippets).first(where: {
                $0.triggerKeyword == ":concurrent"
            })
        )

        var newer = store.loadGroups()
        newer[0].snippets.append(SnippetModel(
            title: "Newer",
            triggerKeyword: ":newer",
            replacementText: "preserve"
        ))
        XCTAssertEqual(store.saveGroups(newer), .saved)
        XCTAssertEqual(receipt.rollback(), .blockedByRemoteChange)
        XCTAssertEqual(store.loadGroups(), newer)
    }
}
