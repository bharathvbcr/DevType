import CryptoKit
import Foundation

extension SnippetStore {
    public func defaultSnippets() -> [SnippetModel] {
        return [
            SnippetModel(title: "Email Address", triggerKeyword: ":eml", replacementText: "user@devtype.app", isCaseSensitive: false, requireWordBoundary: true),
            SnippetModel(title: "Current Date", triggerKeyword: ":tdate", replacementText: "Today is {{date:yyyy-MM-dd}}", isCaseSensitive: false, requireWordBoundary: false),
            SnippetModel(title: "Greeting Template", triggerKeyword: ":hello", replacementText: "Hello, thanks for reaching out!\n\nBest regards,\nDevType Team", isCaseSensitive: false, requireWordBoundary: true),
            SnippetModel(title: "Function Signature", triggerKeyword: ":func", replacementText: "func {{cursor}}() {\n    // Implementation\n}", isCaseSensitive: false, requireWordBoundary: true)
        ]
    }

    /// Replaces snippet groups with the defaults while retaining the independent secrets under the same
    /// read-modify-write boundary as every other logical mutation. Callers receive the exact
    /// before/after pair and must not present success unless this result is `.saved`.
    @discardableResult
    public func resetToDefaults() -> GroupMutationResult {
        mutateGroups { groups in
            let secrets = SnippetDocument(groups: groups).secrets
            groups = SnippetDocument(groups: [SnippetGroup(
                name: SnippetDocument.defaultGroupName,
                snippets: defaultSnippets()
            )], secrets: secrets).transactionGroups
            return true
        }
    }

    public func search(_ query: String, limit: Int? = nil) -> [SearchHit] {
        let snapshot = loadGroupsWithRevision()
        return SnippetSearch.run(
            query: query,
            in: snapshot.groups,
            includeDisabled: false,
            limit: limit,
            revision: snapshot.revision,
            libraryID: searchCacheIdentity
        )
    }

    // MARK: - Image housekeeping (§3.7)

    /// Deletes one attachment only if the latest committed library still leaves it unreferenced.
    ///
    /// Post-save cleanup cannot safely act on the editor/manager's old snapshot: another mutation
    /// may have re-used the path after that save returned. The reference check and physical
    /// deletion therefore share the store's whole-library RMW lock. A changed disk digest is
    /// deferred until external state is adopted rather than treating a stale cache as authority.
    @discardableResult
    public func deleteImageIfUnreferenced(
        _ path: String,
        deleteImage: (String) -> Bool
    ) -> ImageCleanupResult {
        guard !path.isEmpty else { return .failed }

        invokeConcurrencyProbe(\.attachmentCleanupWillAcquireMutationLock)
        rmwLock.lock()

        lock.lock()
        let current = _cachedGroups ?? loadGroupsUnlocked()
        lock.unlock()

        let isReferenced = current.lazy
            .flatMap(\.snippets)
            .contains(where: { $0.imagePath == path })
        let result: ImageCleanupResult
        if isReferenced {
            result = .retainedReferenced
        } else if Self.currentDigest(at: fileURL) != lastKnownDigest() {
            result = .deferredRemoteChange
        } else if let blocked = blockedReason() {
            result = blocked == .blockedByRemoteChange ? .deferredRemoteChange : .failed
        } else {
            result = deleteImage(path) ? .removed : .failed
        }
        rmwLock.unlock()

        if result == .deferredRemoteChange {
            externalChangeDetected()
        }
        return result
    }

    /// §3.7: deletes stored images no live snippet references. Returns the file
    /// names removed (or that would be removed when `dryRun` is true).
    @discardableResult
    public func collectOrphanedImages(dryRun: Bool = false) -> [String] {
        rmwLock.lock()
        defer { rmwLock.unlock() }
        return ImageAttachmentStore.shared.collectOrphans(for: loadGroups(), dryRun: dryRun)
    }
}
