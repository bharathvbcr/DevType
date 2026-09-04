import Foundation

/// Unified snippet import: one entry point that auto-detects the source format
/// (TextExpander settings bundle vs Espanso YAML/config) and delegates to the
/// matching engine importer. The UI offers a single "Import Snippets…" action
/// backed by this type.
public enum SnippetImporter {

    /// Whole-operation limits. Per-file/per-field limits below can skip one bad
    /// item and continue; exceeding one of these budgets refuses the entire
    /// import so a capped prefix is never presented as complete coverage.
    public struct ResourceLimits: Equatable, Sendable {
        public let maxFileCount: Int
        public let maxAggregateBytes: Int
        public let maxSnippetCount: Int

        public init(maxFileCount: Int, maxAggregateBytes: Int, maxSnippetCount: Int) {
            self.maxFileCount = max(0, maxFileCount)
            self.maxAggregateBytes = max(0, maxAggregateBytes)
            self.maxSnippetCount = max(0, maxSnippetCount)
        }

        public static let production = ResourceLimits(
            maxFileCount: 4_096,
            maxAggregateBytes: 256 * 1024 * 1024,
            maxSnippetCount: 50_000
        )
    }

    public enum ResourceLimit: Equatable, Sendable {
        case fileCount
        case aggregateBytes
        case snippetCount
    }

    /// Hard size bounds at the import boundary. Imported libraries are untrusted
    /// input (shared team exports, downloaded packs); without these a multi-GB
    /// match file or a half-gigabyte snippet body balloons the parser and then
    /// lives in the library store forever. Limits are generous far beyond any
    /// real-world library — they only reject pathological content.
    public enum SnippetImportLimits {
        /// Per-source-file read cap before any parsing happens.
        public static let maxSourceFileBytes = 64 * 1024 * 1024
        /// Longest accepted trigger abbreviation.
        public static let maxTriggerCharacters = 512
        /// Longest accepted replacement body.
        public static let maxReplacementCharacters = 100_000

        public static func isOversized(trigger: String, replacement: String) -> Bool {
            trigger.count > maxTriggerCharacters || replacement.count > maxReplacementCharacters
        }
    }

    public enum SourceKind: String, Equatable {
        case textExpander = "TextExpander"
        case espanso = "Espanso"
    }

    /// Structured, content-free import detail. Formatting belongs to the UI so
    /// a Korean or Japanese app never appends hard-coded English engine prose.
    public enum ImportNote: Equatable, Sendable {
        case richTextDowngraded(Int)
        case scriptImportedLiterally(Int)
        case missingAbbreviationSkipped(Int)
        case disabledGroupPreserved(Int)
        case wordBoundaryPreserved(Int)
        case oversizedItemSkipped(Int)
        case imageMatchImported(Int)
        case imageMatchSkipped(Int)
        case markdownImportedLiterally(Int)
        case appScopePreserved(Int)
        case propagateCaseNotAdapted(Int)
        case unsupportedMatchSkipped(Int)
    }

    /// A detected on-disk location the user can import from.
    public struct DetectedSource: Equatable {
        public let kind: SourceKind
        public let url: URL
    }

    public struct ImportResult: Equatable {
        public let kind: SourceKind
        public let groups: [SnippetGroup]
        public let snippetCount: Int
        /// Espanso `image_path` matches imported as image snippets.
        public let imageCount: Int
        public let sourcePath: String
        /// Structured import details (rich-text downgrade, skipped matches, …).
        public let notes: [ImportNote]
        /// Items refused at the size boundary (`SnippetImportLimits`).
        public let skippedOversized: Int

        public var groupCount: Int { groups.count }
    }

    /// Immutable, value-semantic result of reading and parsing one import source.
    ///
    /// The UI keeps this exact value from preview through confirmation. Committing
    /// a plan therefore cannot observe a changed, moved, or deleted source file.
    public struct ImportPlan: Equatable {
        public let result: ImportResult
        private let stagedAttachments: [StagedAttachment]
        private let imageStore: ImageAttachmentStore

        public var kind: SourceKind { result.kind }
        public var groups: [SnippetGroup] { result.groups }
        public var snippetCount: Int { result.snippetCount }
        public var imageCount: Int { result.imageCount }
        public var groupCount: Int { result.groupCount }
        public var sourcePath: String { result.sourcePath }
        public var notes: [ImportNote] { result.notes }
        public var skippedOversized: Int { result.skippedOversized }

        fileprivate init(
            result: ImportResult,
            stagedAttachments: [StagedAttachment] = [],
            imageStore: ImageAttachmentStore = .shared
        ) {
            // Groups are the payload commit actually consumes, so their count is
            // authoritative even if a future format adapter miscounts while
            // accumulating diagnostics.
            self.result = ImportResult(
                kind: result.kind,
                groups: result.groups,
                snippetCount: result.groups.reduce(0) { $0 + $1.snippets.count },
                imageCount: result.imageCount,
                sourcePath: result.sourcePath,
                notes: result.notes,
                skippedOversized: result.skippedOversized
            )
            self.stagedAttachments = stagedAttachments
            self.imageStore = imageStore
        }

        public static func == (lhs: ImportPlan, rhs: ImportPlan) -> Bool {
            lhs.result == rhs.result && lhs.stagedAttachments == rhs.stagedAttachments
        }

        /// Promotes only after the user confirms. Every file written by this
        /// attempt is returned to the caller so a refused library save can undo
        /// the promotion without touching pre-existing attachments.
        internal func materializeAttachments() throws -> MaterializedImport {
            guard !stagedAttachments.isEmpty else {
                return MaterializedImport(result: result, writtenPaths: [], imageStore: imageStore)
            }
            let promoted = try SnippetImporter.materializeAttachments(
                in: result.groups,
                attachments: stagedAttachments,
                imageStore: imageStore
            )
            let materializedResult = ImportResult(
                kind: result.kind,
                groups: promoted.groups,
                snippetCount: promoted.groups.reduce(0) { $0 + $1.snippets.count },
                imageCount: result.imageCount,
                sourcePath: result.sourcePath,
                notes: result.notes,
                skippedOversized: result.skippedOversized
            )
            return MaterializedImport(
                result: materializedResult,
                writtenPaths: promoted.writtenPaths,
                imageStore: imageStore
            )
        }
    }

    public enum ImportError: LocalizedError, Equatable {
        case pathNotFound(String)
        case unrecognizedSource(String)
        case noImportableSnippets(String)
        case resourceLimitExceeded(ResourceLimit)
        case attachmentCommitFailed
        case libraryCommitFailed

        public var errorDescription: String? {
            switch self {
            case .pathNotFound(let p): return "Path not found: \(p)"
            case .unrecognizedSource(let p):
                return "Could not detect a snippet library at: \(p)\n\nChoose a TextExpander settings folder (.textexpandersettings) or an Espanso config folder, match directory, package, or .yml file."
            case .noImportableSnippets(let p):
                return "No importable snippets were found at: \(p)"
            case .resourceLimitExceeded(.fileCount):
                return "Import stopped because the selected library contains too many files."
            case .resourceLimitExceeded(.aggregateBytes):
                return "Import stopped because the selected library exceeds the total data limit."
            case .resourceLimitExceeded(.snippetCount):
                return "Import stopped because the selected library contains too many snippets."
            case .attachmentCommitFailed:
                return "The imported image attachments could not be saved."
            case .libraryCommitFailed:
                return "The imported library could not be committed."
            }
        }
    }

    internal struct StagedAttachment: Equatable {
        let token: String
        let image: ImageAttachmentStore.PreparedImage
    }

    internal struct MaterializedImport {
        let result: ImportResult
        let writtenPaths: [String]
        let imageStore: ImageAttachmentStore

        @discardableResult
        func rollbackAll() -> AttachmentCleanupSummary {
            let summary = SnippetImporter.cleanupAttachments(writtenPaths, imageStore: imageStore)
            SnippetImporter.logIncompleteAttachmentCleanup(summary)
            return summary
        }

        @discardableResult
        func removeUnreferenced(from groups: [SnippetGroup]) -> AttachmentCleanupSummary {
            let referenced = Set(groups.flatMap(\.snippets).map(\.imagePath))
            let unreferenced = writtenPaths.filter { !referenced.contains($0) }
            let summary = SnippetImporter.cleanupAttachments(unreferenced, imageStore: imageStore)
            SnippetImporter.logIncompleteAttachmentCleanup(summary)
            return summary
        }
    }

    internal struct AttachmentCleanupSummary: Equatable {
        let attempted: Int
        let removed: Int
        let failed: Int

        var diagnosticLabel: String {
            "attempted=\(attempted) removed=\(removed) failed=\(failed)"
        }
    }

    private static func cleanupAttachments(
        _ paths: [String],
        imageStore: ImageAttachmentStore
    ) -> AttachmentCleanupSummary {
        var removed = 0
        var failed = 0
        for path in paths {
            switch imageStore.deleteImageReportingResult(path: path) {
            case .removed: removed += 1
            case .failed: failed += 1
            }
        }
        return AttachmentCleanupSummary(
            attempted: paths.count,
            removed: removed,
            failed: failed
        )
    }

    private static func logIncompleteAttachmentCleanup(_ summary: AttachmentCleanupSummary) {
        guard summary.failed > 0 else { return }
        // Aggregate counts only: attachment names, source paths, and raw
        // filesystem failure prose never enter diagnostics.
        DevTypeLog.store.error(
            "[Store] Import attachment cleanup incomplete attempted=\(summary.attempted, privacy: .public) removed=\(summary.removed, privacy: .public) failed=\(summary.failed, privacy: .public)"
        )
    }

    internal static func materializeAttachments(
        in sourceGroups: [SnippetGroup],
        attachments: [StagedAttachment],
        imageStore: ImageAttachmentStore
    ) throws -> (groups: [SnippetGroup], writtenPaths: [String]) {
        var namesByToken: [String: String] = [:]
        var writtenPaths: [String] = []
        do {
            for attachment in attachments {
                let storedName = try imageStore.save(prepared: attachment.image)
                namesByToken[attachment.token] = storedName
                writtenPaths.append(storedName)
            }
        } catch {
            let cleanup = cleanupAttachments(writtenPaths, imageStore: imageStore)
            logIncompleteAttachmentCleanup(cleanup)
            throw ImportError.attachmentCommitFailed
        }

        var groups = sourceGroups
        for groupIndex in groups.indices {
            for snippetIndex in groups[groupIndex].snippets.indices {
                let token = groups[groupIndex].snippets[snippetIndex].imagePath
                if let storedName = namesByToken[token] {
                    groups[groupIndex].snippets[snippetIndex].imagePath = storedName
                }
            }
        }
        return (groups, writtenPaths)
    }

    /// Shared, path-deduplicating budget for detection plus the selected format
    /// adapter. It is synchronous and owned by exactly one import operation.
    internal final class ResourceBudget {
        let limits: ResourceLimits
        private var discoveredPaths: Set<String> = []
        private var materializedPaths: Set<String> = []
        private(set) var aggregateBytes = 0
        private(set) var snippetCount = 0

        init(limits: ResourceLimits) {
            self.limits = limits
        }

        func registerFile(_ url: URL) throws {
            // Count directory entries, not resolved targets. Otherwise an
            // attacker can create an unbounded number of symlink aliases to one
            // file and make the directory walker visit all of them for one unit
            // of budget. The standardized spelling still deduplicates the same
            // entry observed once during detection and again during parsing.
            let path = url.standardizedFileURL.path
            guard discoveredPaths.insert(path).inserted else { return }
            guard discoveredPaths.count <= limits.maxFileCount else {
                throw ImportError.resourceLimitExceeded(.fileCount)
            }
        }

        func consumeBytes(_ count: Int, from url: URL) throws {
            // Charge every distinct path that was actually read. Resolving
            // symlinks here would let many alias reads consume one byte-budget
            // entry even though each read and parse repeats the work.
            let path = url.standardizedFileURL.path
            guard materializedPaths.insert(path).inserted else { return }
            guard count >= 0,
                  aggregateBytes <= limits.maxAggregateBytes,
                  count <= limits.maxAggregateBytes - aggregateBytes else {
                throw ImportError.resourceLimitExceeded(.aggregateBytes)
            }
            aggregateBytes += count
        }

        func consumeSnippets(_ count: Int = 1) throws {
            guard count >= 0,
                  snippetCount <= limits.maxSnippetCount,
                  count <= limits.maxSnippetCount - snippetCount else {
                throw ImportError.resourceLimitExceeded(.snippetCount)
            }
            snippetCount += count
        }
    }

    // MARK: - Detection

    /// Candidate library locations from all supported sources, TextExpander first.
    public static func detectedSources() -> [DetectedSource] {
        var sources: [DetectedSource] = TEImporter.detectDataFolders()
            .map { DetectedSource(kind: .textExpander, url: $0) }
        sources.append(contentsOf: EspansoImporter.detectConfigRoots()
            .map { DetectedSource(kind: .espanso, url: $0) })
        return sources
    }

    /// Sniffs the format of a user-chosen file/folder.
    public static func detectKind(at url: URL) -> SourceKind? {
        let budget = ResourceBudget(limits: .production)
        return try? detectKind(at: url, budget: budget)
    }

    private static func detectKind(at url: URL, budget: ResourceBudget) throws -> SourceKind? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        if !isDir.boolValue {
            try budget.registerFile(url)
            let ext = url.pathExtension.lowercased()
            return (ext == "yml" || ext == "yaml") ? .espanso : nil
        }

        let ext = url.pathExtension.lowercased()
        if ext == "textexpandersettings" || ext == "textexpanderbackup" {
            return .textExpander
        }

        // Espanso root (match/), package dir, or any folder containing YAML files.
        let hasMatchDir = fm.fileExists(atPath: url.appendingPathComponent("match").path)
        if hasMatchDir { return .espanso }

        // Stream the directory rather than materializing an unbounded array.
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return nil }
        var foundTextExpander = false
        var foundEspanso = false
        for case let child as URL in enumerator {
            try budget.registerFile(child)
            if child.lastPathComponent.contains("group_")
                && child.pathExtension.lowercased() == "xml" {
                foundTextExpander = true
            }
            let childExtension = child.pathExtension.lowercased()
            if childExtension == "yml" || childExtension == "yaml" {
                foundEspanso = true
            }
        }
        if foundTextExpander { return .textExpander }
        return foundEspanso ? .espanso : nil
    }

    // MARK: - Import

    /// Parses the source exactly once and freezes the result that preview and
    /// commit must share. Empty sources are refused before presenting a success-
    /// looking confirmation sheet or replacing a same-named group with emptiness.
    public static func prepareImport(
        from url: URL,
        imageStore: ImageAttachmentStore = .shared,
        limits: ResourceLimits = .production
    ) throws -> ImportPlan {
        let budget = ResourceBudget(limits: limits)
        let parsed = try parseImport(
            from: url,
            imageStore: imageStore,
            budget: budget,
            stageAttachments: true
        )
        let plan = ImportPlan(
            result: parsed.result,
            stagedAttachments: parsed.stagedAttachments,
            imageStore: imageStore
        )
        guard plan.snippetCount > 0 else {
            throw ImportError.noImportableSnippets(parsed.result.sourcePath)
        }
        return plan
    }

    /// Imports snippets from `url`, auto-detecting TextExpander vs Espanso.
    public static func importFrom(
        _ url: URL,
        imageStore: ImageAttachmentStore = .shared,
        limits: ResourceLimits = .production
    ) throws -> ImportResult {
        let budget = ResourceBudget(limits: limits)
        return try parseImport(
            from: url,
            imageStore: imageStore,
            budget: budget,
            stageAttachments: false
        ).result
    }

    private static func parseImport(
        from url: URL,
        imageStore: ImageAttachmentStore,
        budget: ResourceBudget,
        stageAttachments: Bool
    ) throws -> (result: ImportResult, stagedAttachments: [StagedAttachment]) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ImportError.pathNotFound(url.path)
        }
        guard let kind = try detectKind(at: url, budget: budget) else {
            throw ImportError.unrecognizedSource(url.path)
        }

        switch kind {
        case .textExpander:
            let result = try TEImporter.importFolder(url, budget: budget)
            var notes: [ImportNote] = []
            if result.richTextCount > 0 {
                notes.append(.richTextDowngraded(result.richTextCount))
            }
            // §3.8
            if result.scriptCount > 0 {
                notes.append(.scriptImportedLiterally(result.scriptCount))
            }
            if result.skippedEmptyAbbrev > 0 {
                notes.append(.missingAbbreviationSkipped(result.skippedEmptyAbbrev))
            }
            if result.disabledGroupCount > 0 {
                notes.append(.disabledGroupPreserved(result.disabledGroupCount))
            }
            if result.wordBoundaryCount > 0 {
                notes.append(.wordBoundaryPreserved(result.wordBoundaryCount))
            }
            if result.skippedOversized > 0 {
                notes.append(.oversizedItemSkipped(result.skippedOversized))
            }
            return (ImportResult(
                kind: .textExpander,
                groups: result.groups,
                snippetCount: result.snippetCount,
                imageCount: 0,
                sourcePath: result.sourcePath,
                notes: notes,
                skippedOversized: result.skippedOversized
            ), [])

        case .espanso:
            let result = try EspansoImporter.importFrom(
                url,
                imageStore: imageStore,
                budget: budget,
                stageAttachments: stageAttachments
            )
            var notes: [ImportNote] = []
            if result.imageCount > 0 {
                notes.append(.imageMatchImported(result.imageCount))
            }
            if result.skippedImage > 0 {
                notes.append(.imageMatchSkipped(result.skippedImage))
            }
            // §3.8
            if result.markdownAsPlainCount > 0 {
                notes.append(.markdownImportedLiterally(result.markdownAsPlainCount))
            }
            if result.appScopedCount > 0 {
                notes.append(.appScopePreserved(result.appScopedCount))
            }
            if result.propagateCaseCount > 0 {
                notes.append(.propagateCaseNotAdapted(result.propagateCaseCount))
            }
            let nonImageSkipped = result.skippedVars + result.skippedForm + result.skippedHtml
                + result.skippedMarkdown + result.skippedRegex + result.skippedEmptyTrigger
                + result.skippedUnsafeImports + result.skippedParseFailed
            if nonImageSkipped > 0 {
                notes.append(.unsupportedMatchSkipped(nonImageSkipped))
            }
            if result.skippedOversized > 0 {
                notes.append(.oversizedItemSkipped(result.skippedOversized))
            }
            return (ImportResult(
                kind: .espanso,
                groups: result.groups,
                snippetCount: result.snippetCount,
                imageCount: result.imageCount,
                sourcePath: result.sourcePath,
                notes: notes,
                skippedOversized: result.skippedOversized
            ), result.stagedAttachments)
        }
    }
}
