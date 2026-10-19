import AppKit
import Carbon.HIToolbox
import ExpanderEngine

/// Commits one manager mutation without letting an optimistic UI state outrun durable storage.
///
/// The manager owns whole-library model changes, while the snippet editor owns staged Keychain
/// and attachment edits. Duplication is the one manager action that stages a new attachment before
/// persistence, so refused or no-op writes must compensate it. Conversely, attachments removed by
/// a successful delete are cleaned only after the new library is durable. A model-only undo is
/// offered only when the UUID-to-resource mapping is identical before and after; otherwise undo
/// could recreate a secret without its Keychain value, or redo an image snippet after its file was
/// deleted.
enum SnippetManagerMutationCommitter {
    enum Outcome: Equatable {
        case unchanged(cleanupFailures: Int)
        case committed(allowsModelOnlyUndo: Bool, cleanupFailures: Int)
        case stale(cleanupFailures: Int)
        case refused(SnippetStore.SaveOutcome, cleanupFailures: Int)
    }

    private struct ResourceIdentity: Equatable {
        let id: UUID
        let isSecret: Bool
        let imagePath: String
    }

    static func finish(
        _ result: SnippetStore.GroupMutationResult,
        stagedImagePaths: [String] = [],
        deleteImage: (String) -> Bool
    ) -> Outcome {
        switch result {
        case .unchanged:
            return .unchanged(cleanupFailures: cleanup(stagedImagePaths, using: deleteImage))
        case .rejected:
            return .stale(cleanupFailures: cleanup(stagedImagePaths, using: deleteImage))
        case .refused(let outcome):
            return .refused(
                outcome,
                cleanupFailures: cleanup(stagedImagePaths, using: deleteImage)
            )
        case .saved(let before, let after):
            let beforeImages = imagePaths(in: before)
            let afterImages = imagePaths(in: after)
            let removedImages = beforeImages.subtracting(afterImages).sorted()
            let cleanupFailures = cleanup(removedImages, using: deleteImage)
            return .committed(
                allowsModelOnlyUndo: resourceProjection(in: before) == resourceProjection(in: after),
                cleanupFailures: cleanupFailures
            )
        }
    }

    private static func resourceProjection(in groups: [SnippetGroup]) -> [ResourceIdentity] {
        groups.flatMap(\.snippets).compactMap { snippet in
            guard snippet.isSecret || !snippet.imagePath.isEmpty else { return nil }
            return ResourceIdentity(
                id: snippet.id,
                isSecret: snippet.isSecret,
                imagePath: snippet.imagePath
            )
        }.sorted { left, right in
            if left.id != right.id { return left.id.uuidString < right.id.uuidString }
            if left.isSecret != right.isSecret { return !left.isSecret && right.isSecret }
            return left.imagePath < right.imagePath
        }
    }

    private static func imagePaths(in groups: [SnippetGroup]) -> Set<String> {
        Set(groups.flatMap(\.snippets).map(\.imagePath).filter { !$0.isEmpty })
    }

    private static func cleanup(_ paths: [String], using deleteImage: (String) -> Bool) -> Int {
        paths.reduce(into: 0) { failures, path in
            if !deleteImage(path) { failures += 1 }
        }
    }
}
