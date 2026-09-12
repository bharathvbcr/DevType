import Foundation
import ExpanderEngine

/// Value-free failures for editor resource operations. The editor may explain the failed class
/// of operation, but must never carry an attachment path or secret value into UI or logs.
enum SnippetEditResourceError: Error, Equatable {
    case unavailable
}

enum SnippetEditSecretSnapshot: Equatable {
    case missing
    case value(String)
    /// Metadata says an item exists, but its value could not be read (for example, a locked
    /// keychain). Overwriting without a rollback value would make an atomic edit impossible.
    case unavailable
}

enum SnippetEditSecretIntent: Equatable {
    /// Keep and verify the already-stored value.
    case unchanged
    /// Create or replace the stored value.
    case set(String)
    /// The candidate is no longer a secret. Deletion is commit cleanup, after library save.
    case remove
}

/// Injectable resource boundary for the editor transaction. Production uses the same attachment
/// directory and SecretStore as before; tests inject deterministic failures without touching the
/// developer's files or keychain.
struct SnippetEditResourceAccess {
    var importImage: (URL) -> Result<String, SnippetEditResourceError>
    var deleteImage: (String) -> Result<Void, SnippetEditResourceError>
    var readSecret: (UUID) -> SnippetEditSecretSnapshot
    var storeSecret: (String, UUID) -> Result<Void, SnippetEditResourceError>
    var removeSecret: (UUID) -> Result<Void, SnippetEditResourceError>
    var protectSecretFromOrphanPurge: (UUID) -> SecretStore.OrphanPurgeLease?
    var performSecretTransaction: (_ body: () -> Void) -> Bool = { body in body(); return true }

    static let live = using(secretStore: .shared)

    static func using(secretStore: SecretStore) -> Self {
        SnippetEditResourceAccess(
            importImage: { source in
                do {
                    return .success(try ImageAttachmentStore.shared.importImage(from: source))
                } catch {
                    return .failure(.unavailable)
                }
            },
            deleteImage: { path in
                guard !path.isEmpty, !path.hasPrefix("/") else { return .success(()) }
                guard let url = ImageAttachmentStore.shared.resolvedURL(forImagePath: path) else {
                    return .failure(.unavailable)
                }
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    return .success(())
                } catch {
                    return .failure(.unavailable)
                }
            },
            readSecret: { id in
                if let value = secretStore.secret(for: id) { return .value(value) }
                return secretStore.hasSecret(for: id) ? .unavailable : .missing
            },
            storeSecret: { value, id in
                secretStore.store(value, for: id).mapError { _ in .unavailable }
            },
            removeSecret: { id in
                secretStore.remove(for: id).mapError { _ in .unavailable }
            },
            protectSecretFromOrphanPurge: { id in
                secretStore.protectFromOrphanPurge(id)
            },
            performSecretTransaction: secretStore.performExclusiveTransaction
        )
    }
}

/// A host save is not complete until resource cleanup succeeds. Hosts therefore return a receipt:
/// `rollback` restores their exact pre-edit group snapshot, while `finalize` updates host-only UI
/// and undo state once the entire transaction commits.
struct SnippetEditorPersistenceReceipt {
    let outcome: SnippetStore.SaveOutcome
    let rollback: () -> SnippetStore.SaveOutcome
    let finalize: () -> Void
    let cleanupImage: (_ path: String, _ deleteImage: (String) -> Bool) -> SnippetStore.ImageCleanupResult

    init(
        outcome: SnippetStore.SaveOutcome,
        rollback: @escaping () -> SnippetStore.SaveOutcome,
        finalize: @escaping () -> Void,
        cleanupImage: @escaping (
            _ path: String,
            _ deleteImage: (String) -> Bool
        ) -> SnippetStore.ImageCleanupResult = { path, deleteImage in
            deleteImage(path) ? .removed : .failed
        }
    ) {
        self.outcome = outcome
        self.rollback = rollback
        self.finalize = finalize
        self.cleanupImage = cleanupImage
    }

    static func refused(_ outcome: SnippetStore.SaveOutcome) -> Self {
        Self(outcome: outcome, rollback: { .saved }, finalize: {})
    }

    /// Canonical host adapter: derive the candidate from the store's latest snapshot under its
    /// read-modify-write lock, retain the exact committed pair for a conditional compensating
    /// write, and defer UI/undo mutation until resource cleanup has committed.
    static func mutating(
        store: SnippetStore,
        mutation: (inout [SnippetGroup]) -> Bool,
        finalize: @escaping (_ before: [SnippetGroup], _ after: [SnippetGroup]) -> Void
    ) -> Self {
        let result = store.mutateGroups(mutation)
        switch result {
        case .saved(let before, let after):
            return Self(
                outcome: .saved,
                rollback: {
                    let rollbackResult = store.replaceGroups(ifCurrent: after, with: before)
                    switch rollbackResult {
                    case .saved, .unchanged:
                        return .saved
                    case .rejected:
                        return .blockedByRemoteChange
                    case .refused(let outcome):
                        LibraryHealthMonitor.shared.refresh()
                        return outcome
                    }
                },
                finalize: { finalize(before, after) },
                cleanupImage: { path, deleteImage in
                    store.deleteImageIfUnreferenced(path, deleteImage: deleteImage)
                }
            )

        case .unchanged(let current):
            return Self(
                outcome: .saved,
                rollback: { .saved },
                finalize: { finalize(current, current) }
            )

        case .rejected:
            return .refused(.blockedByRemoteChange)

        case .refused(let outcome):
            LibraryHealthMonitor.shared.refresh()
            return .refused(outcome)
        }
    }
}

enum SnippetEditTransactionFailure: Equatable {
    case imageStaging
    case secretRead
    case secretWrite
    case persistence(SnippetStore.SaveOutcome)
    /// The candidate save landed, but deleting the superseded resource failed. The library and
    /// newly staged resources were restored to their pre-edit state.
    case commitCleanup
    /// A staged resource could not be restored yet. The transaction retains the compensation so
    /// Save or Cancel can retry; the sheet must stay open.
    case rollback
}

enum SnippetEditTransactionWarning: Equatable {
    /// Commit cleanup failed and the host also refused restoration. The candidate is therefore
    /// the actual on-disk state; its new resources must be retained and host UI finalized.
    case libraryRollback
}

enum SnippetEditTransactionOutcome: Equatable {
    case committed
    case committedWithWarning(SnippetEditTransactionWarning)
    case failed(SnippetEditTransactionFailure)

    var didCommit: Bool {
        switch self {
        case .committed, .committedWithWarning: return true
        case .failed: return false
        }
    }
}

enum SnippetEditCancellationOutcome: Equatable {
    case clean
    case rollbackFailed
}

/// One editor session's explicit transaction owner.
///
/// Staging is compensatable (new attachment / new secret), persistence is host-owned, and only a
/// landed library is followed by destructive cleanup of the old resource. Failed compensation is
/// retained rather than forgotten, so a later Save or Cancel retries it before doing anything new.
final class SnippetEditTransaction {
    private struct Compensation {
        let run: () -> Result<Void, SnippetEditResourceError>
    }

    private let resources: SnippetEditResourceAccess
    private let executionLock = NSLock()
    private var pendingCompensations: [Compensation] = []
    private var pendingSecretID: UUID?
    private var secretProtection: SecretStore.OrphanPurgeLease?

    init(resources: SnippetEditResourceAccess = .live) {
        self.resources = resources
    }

    func save(
        snippet originalCandidate: SnippetModel,
        existing: SnippetModel?,
        pickedImageURL: URL?,
        secretIntent: SnippetEditSecretIntent,
        groupID: UUID?,
        persist: (SnippetModel, UUID?) -> SnippetEditorPersistenceReceipt
    ) -> SnippetEditTransactionOutcome {
        guard executionLock.try() else { return .failed(.secretWrite) }
        defer { executionLock.unlock() }
        guard pendingSecretID == nil || pendingSecretID == originalCandidate.id else { return .failed(.rollback) }
        let needsSecretTransaction = originalCandidate.isSecret || existing?.isSecret == true || {
            if case .set = secretIntent { return true }
            return false
        }()
        if needsSecretTransaction {
            // Acquire before the backing transaction: a same-ID orphan delete may already be
            // waiting on the backing lock. Failed compensation keeps this lease until retry.
            if secretProtection == nil { secretProtection = resources.protectSecretFromOrphanPurge(originalCandidate.id) }
            pendingSecretID = originalCandidate.id
        }
        defer {
            if pendingCompensations.isEmpty {
                secretProtection = nil
                pendingSecretID = nil
            }
        }
        if needsSecretTransaction {
            var outcome = SnippetEditTransactionOutcome.failed(.secretWrite)
            guard resources.performSecretTransaction({
                outcome = saveExclusively(snippet: originalCandidate, existing: existing,
                    pickedImageURL: pickedImageURL, secretIntent: secretIntent, groupID: groupID, persist: persist)
            }) else { return .failed(.secretWrite) }
            return outcome
        }
        return saveExclusively(snippet: originalCandidate, existing: existing,
            pickedImageURL: pickedImageURL, secretIntent: secretIntent, groupID: groupID, persist: persist)
    }

    private func saveExclusively(
        snippet originalCandidate: SnippetModel,
        existing: SnippetModel?,
        pickedImageURL: URL?,
        secretIntent: SnippetEditSecretIntent,
        groupID: UUID?,
        persist: (SnippetModel, UUID?) -> SnippetEditorPersistenceReceipt
    ) -> SnippetEditTransactionOutcome {
        guard retryPendingCompensations() else { return .failed(.rollback) }

        var candidate = originalCandidate
        var staged: [Compensation] = []

        let willBeSecret: Bool
        switch secretIntent {
        case .set: willBeSecret = true
        case .unchanged: willBeSecret = candidate.isSecret
        case .remove: willBeSecret = false
        }
        // The model makes image+secret unrepresentable on disk. Refuse the inconsistent request
        // before copying anything, so a future caller cannot turn that invariant into an orphan.
        if willBeSecret, pickedImageURL != nil { return .failed(.imageStaging) }

        // A newly selected attachment is the only image mutation that must precede persistence:
        // the candidate needs its stable stored name. The old attachment remains untouched.
        if let pickedImageURL {
            switch resources.importImage(pickedImageURL) {
            case .failure:
                return .failed(.imageStaging)
            case .success(let storedPath):
                candidate.imagePath = storedPath
                candidate.replacementText = ""
                staged.append(Compensation { [resources] in
                    resources.deleteImage(storedPath)
                })
            }
        }

        switch secretIntent {
        case .unchanged:
            // A secret model without a readable backing value must not be re-saved as healthy.
            guard candidate.isSecret, existing?.isSecret == true,
                  case .value = resources.readSecret(candidate.id) else {
                return failAfterStaging(.secretRead, staged: staged)
            }

        case .set(let value):
            let prior = resources.readSecret(candidate.id)
            guard prior != .unavailable else {
                return failAfterStaging(.secretRead, staged: staged)
            }
            // Backings can make a durable partial write and still report failure. Stage the
            // compensation before attempting the write, then inspect what actually survived.
            staged.append(Compensation { [resources] in
                switch resources.readSecret(candidate.id) {
                case .unavailable: return .failure(.unavailable)
                case .missing: return .success(())
                case .value(let current) where current != value || prior == .value(current): return .success(())
                case .value: break
                }
                switch prior {
                case .value(let oldValue): return resources.storeSecret(oldValue, candidate.id)
                case .missing: return resources.removeSecret(candidate.id)
                case .unavailable: return .failure(.unavailable)
                }
            })
            switch resources.storeSecret(value, candidate.id) {
            case .failure:
                return failAfterStaging(.secretWrite, staged: staged)
            case .success:
                candidate.isSecret = true
                candidate.replacementText = ""
                candidate.imagePath = ""
            }

        case .remove:
            candidate.isSecret = false
        }

        let receipt = persist(candidate, groupID)
        guard receipt.outcome.didSave else {
            if !rollBack(staged) { return .failed(.rollback) }
            return .failed(.persistence(receipt.outcome))
        }

        var cleanupFailed = false
        if let oldPath = existing?.imagePath,
           !oldPath.isEmpty,
           oldPath != candidate.imagePath {
            let cleanup = receipt.cleanupImage(oldPath) { [resources] path in
                if case .success = resources.deleteImage(path) { return true }
                return false
            }
            if cleanup == .failed || cleanup == .deferredRemoteChange {
                cleanupFailed = true
            }
        }
        if existing?.isSecret == true,
           !candidate.isSecret,
           case .failure = resources.removeSecret(candidate.id) {
            cleanupFailed = true
        }

        guard cleanupFailed else {
            receipt.finalize()
            return .committed
        }

        // Destructive cleanup did not complete. Restore the previous library first; only then is
        // it safe to remove/restore the staged resources that the candidate referenced.
        guard receipt.rollback().didSave else {
            receipt.finalize()
            return .committedWithWarning(.libraryRollback)
        }
        if !rollBack(staged) { return .failed(.rollback) }
        return .failed(.commitCleanup)
    }

    /// Cancel has no work before the first save attempt. After a failed rollback it is a cleanup
    /// retry, and callers must keep the editor open if that retry still fails.
    func cancel() -> SnippetEditCancellationOutcome {
        guard executionLock.try() else { return .rollbackFailed }
        defer { executionLock.unlock() }
        var clean = false
        let retry = { clean = self.retryPendingCompensations() }
        if pendingSecretID != nil {
            guard resources.performSecretTransaction(retry) else { return .rollbackFailed }
        } else { retry() }
        if clean {
            secretProtection = nil
            pendingSecretID = nil
        }
        return clean ? .clean : .rollbackFailed
    }

    private func failAfterStaging(
        _ failure: SnippetEditTransactionFailure,
        staged: [Compensation]
    ) -> SnippetEditTransactionOutcome {
        rollBack(staged) ? .failed(failure) : .failed(.rollback)
    }

    private func rollBack(_ compensations: [Compensation]) -> Bool {
        var failed: [Compensation] = []
        for compensation in compensations.reversed() {
            if case .failure = compensation.run() {
                failed.append(compensation)
            }
        }
        // Preserve retry order: failed compensations are already in reverse execution order.
        pendingCompensations.append(contentsOf: failed)
        return failed.isEmpty
    }

    private func retryPendingCompensations() -> Bool {
        guard !pendingCompensations.isEmpty else { return true }
        let pending = pendingCompensations
        pendingCompensations = []
        var failed: [Compensation] = []
        for compensation in pending {
            if case .failure = compensation.run() { failed.append(compensation) }
        }
        pendingCompensations = failed
        return failed.isEmpty
    }
}

/// The editor delegates collision semantics to the matcher's canonical detector. All entry points
/// call this owner; `detectionEnabled` represents the one intentional global "warnings off"
/// preference and is injectable so tests never mutate process-wide defaults.
enum SnippetTriggerAuthoringValidator {
    static func conflict(
        trigger: String,
        caseSensitive: Bool,
        requireWordBoundary: Bool,
        enabled: Bool = true,
        excludingID: UUID?,
        groups: [SnippetGroup],
        detectionEnabled: Bool = SnippetStore.isConflictDetectionEnabled
    ) -> SnippetStore.TriggerConflict? {
        let candidate = SnippetModel(
            id: excludingID ?? UUID(),
            title: "Editor draft",
            triggerKeyword: trigger,
            replacementText: "Editor draft",
            isCaseSensitive: caseSensitive,
            requireWordBoundary: requireWordBoundary,
            enabled: enabled
        )
        return conflict(
            for: candidate,
            excludingID: excludingID,
            groups: groups,
            detectionEnabled: detectionEnabled
        )
    }

    static func conflict(
        for candidate: SnippetModel,
        excludingID: UUID?,
        groups: [SnippetGroup],
        detectionEnabled: Bool = SnippetStore.isConflictDetectionEnabled
    ) -> SnippetStore.TriggerConflict? {
        guard detectionEnabled, candidate.isTypedTriggerExpandable else { return nil }

        var probe = groups.map { group -> SnippetGroup in
            var copy = group
            if let excludingID {
                copy.snippets.removeAll { $0.id == excludingID }
            }
            return copy
        }
        if probe.isEmpty { probe = [SnippetGroup(name: SnippetDocument.defaultGroupName)] }
        probe[0].snippets.append(candidate)

        func priority(_ kind: SnippetStore.TriggerConflict.Kind) -> Int {
            switch kind {
            case .emptyTrigger: return 0
            case .duplicateTrigger: return 1
            case .caseShadow: return 2
            case .prefixShadow: return 3
            }
        }
        return SnippetStore.triggerConflicts(in: probe)
            .filter { $0.snippetIDs.contains(candidate.id) }
            .sorted {
                let left = priority($0.kind)
                let right = priority($1.kind)
                if left != right { return left < right }
                return $0.trigger < $1.trigger
            }
            .first
    }
}

/// Pure group mutation shared by every editor host. Returning `nil` refuses a stale edit instead
/// of silently adding a duplicate when its snippet or explicitly selected group disappeared, and
/// repeats canonical trigger validation at the persistence seam so a host cannot bypass it.
enum SnippetLibraryEdit {
    /// The manager's existing undo stores only the group models. It is valid only when undo does
    /// not also need to recreate a deleted attachment or a prior Keychain value. Resource edits
    /// are already atomic, but cannot be represented honestly by that model-only undo stack.
    static func supportsModelOnlyUndo(existing: SnippetModel?, candidate: SnippetModel) -> Bool {
        guard let existing else { return !candidate.isSecret && candidate.imagePath.isEmpty }
        guard !existing.isSecret, !candidate.isSecret else { return false }
        return existing.imagePath == candidate.imagePath
    }

    static func applying(
        snippet: SnippetModel,
        existingID: UUID?,
        chosenGroupID: UUID?,
        fallbackGroupID: UUID?,
        to original: [SnippetGroup],
        conflictDetectionEnabled: Bool = SnippetStore.isConflictDetectionEnabled
    ) -> [SnippetGroup]? {
        guard !snippet.isSecret else { return nil }
        let document = SnippetDocument(groups: original)
        var groups = document.groups

        if let existingID {
            let locations = groups.indices.flatMap { groupIndex in
                groups[groupIndex].snippets.indices.compactMap { snippetIndex in
                    groups[groupIndex].snippets[snippetIndex].id == existingID
                        ? (groupIndex, snippetIndex)
                        : nil
                }
            }
            guard locations.count == 1, let source = locations.first else { return nil }
            guard SnippetTriggerAuthoringValidator.conflict(
                for: snippet,
                excludingID: existingID,
                groups: original,
                detectionEnabled: conflictDetectionEnabled
            ) == nil else { return nil }

            let destinationIndex: Int
            if let chosenGroupID {
                guard let index = groups.firstIndex(where: { $0.id == chosenGroupID }) else { return nil }
                destinationIndex = index
            } else {
                destinationIndex = source.0
            }

            if destinationIndex == source.0 {
                groups[source.0].snippets[source.1] = snippet
            } else {
                groups[source.0].snippets.remove(at: source.1)
                groups[destinationIndex].snippets.append(snippet)
            }
            return SnippetDocument(groups: groups, secrets: document.secrets).transactionGroups
        }

        guard !document.snippets.contains(where: { $0.id == snippet.id }) else { return nil }
        guard SnippetTriggerAuthoringValidator.conflict(
            for: snippet,
            excludingID: nil,
            groups: original,
            detectionEnabled: conflictDetectionEnabled
        ) == nil else { return nil }

        let destinationIndex: Int
        if let chosenGroupID {
            guard let index = groups.firstIndex(where: { $0.id == chosenGroupID }) else { return nil }
            destinationIndex = index
        } else if let fallbackGroupID,
                  let index = groups.firstIndex(where: { $0.id == fallbackGroupID }) {
            destinationIndex = index
        } else if let index = groups.firstIndex(where: { $0.name == SnippetDocument.defaultGroupName }) {
            destinationIndex = index
        } else if groups.isEmpty {
            groups = [SnippetGroup(name: SnippetDocument.defaultGroupName)]
            destinationIndex = 0
        } else {
            destinationIndex = 0
        }
        groups[destinationIndex].snippets.append(snippet)
        return SnippetDocument(groups: groups, secrets: document.secrets).transactionGroups
    }
}
