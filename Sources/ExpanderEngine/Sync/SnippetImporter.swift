import Foundation

/// Unified snippet import: one entry point that auto-detects the source format
/// (TextExpander settings bundle vs Espanso YAML/config) and delegates to the
/// matching engine importer. The UI offers a single "Import Snippets…" action
/// backed by this type.
public enum SnippetImporter {

    public enum SourceKind: String, Equatable {
        case textExpander = "TextExpander"
        case espanso = "Espanso"
    }

    /// A detected on-disk location the user can import from.
    public struct DetectedSource: Equatable {
        public let kind: SourceKind
        public let url: URL
    }

    public struct ImportResult {
        public let kind: SourceKind
        public let groups: [SnippetGroup]
        public let snippetCount: Int
        /// Espanso `image_path` matches imported as image snippets.
        public let imageCount: Int
        public let sourcePath: String
        /// Human-readable import notes (rich-text downgrade, skipped matches, …).
        public let notes: [String]

        public var groupCount: Int { groups.count }
    }

    public enum ImportError: LocalizedError {
        case pathNotFound(String)
        case unrecognizedSource(String)

        public var errorDescription: String? {
            switch self {
            case .pathNotFound(let p): return "Path not found: \(p)"
            case .unrecognizedSource(let p):
                return "Could not detect a snippet library at: \(p)\n\nChoose a TextExpander settings folder (.textexpandersettings) or an Espanso config folder, match directory, package, or .yml file."
            }
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
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        if !isDir.boolValue {
            let ext = url.pathExtension.lowercased()
            return (ext == "yml" || ext == "yaml") ? .espanso : nil
        }

        let ext = url.pathExtension.lowercased()
        if ext == "textexpandersettings" || ext == "textexpanderbackup" {
            return .textExpander
        }

        let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        if children.contains(where: {
            $0.lastPathComponent.contains("group_") && $0.pathExtension.lowercased() == "xml"
        }) {
            return .textExpander
        }

        // Espanso root (match/), package dir, or any folder containing YAML files.
        let hasMatchDir = children.contains {
            $0.lastPathComponent == "match" && $0.hasDirectoryPath
        } || fm.fileExists(atPath: url.appendingPathComponent("match").path)
        if hasMatchDir { return .espanso }
        if children.contains(where: {
            let ext = $0.pathExtension.lowercased()
            return ext == "yml" || ext == "yaml"
        }) {
            return .espanso
        }

        return nil
    }

    // MARK: - Import

    /// Imports snippets from `url`, auto-detecting TextExpander vs Espanso.
    public static func importFrom(
        _ url: URL,
        imageStore: ImageAttachmentStore = .shared
    ) throws -> ImportResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw ImportError.pathNotFound(url.path)
        }
        guard let kind = detectKind(at: url) else {
            throw ImportError.unrecognizedSource(url.path)
        }

        switch kind {
        case .textExpander:
            let result = try TEImporter.importFolder(url)
            var notes: [String] = []
            if result.richTextCount > 0 {
                notes.append("\(result.richTextCount) rich-text snippet(s) were imported as plain text.")
            }
            // §3.8
            if result.scriptCount > 0 {
                notes.append("\(result.scriptCount) script snippet(s) were imported as literal text — DevType does not run scripts.")
            }
            if result.skippedEmptyAbbrev > 0 {
                notes.append("\(result.skippedEmptyAbbrev) snippet(s) without an abbreviation were skipped.")
            }
            if result.disabledGroupCount > 0 {
                notes.append("\(result.disabledGroupCount) group(s) were disabled in TextExpander and were imported disabled.")
            }
            if result.wordBoundaryCount > 0 {
                notes.append("\(result.wordBoundaryCount) snippet(s) expand only at a word boundary (TextExpander \"expand at delimiter\").")
            }
            return ImportResult(
                kind: .textExpander,
                groups: result.groups,
                snippetCount: result.snippetCount,
                imageCount: 0,
                sourcePath: result.sourcePath,
                notes: notes
            )

        case .espanso:
            let result = try EspansoImporter.importFrom(url, imageStore: imageStore)
            var notes: [String] = []
            if result.imageCount > 0 {
                notes.append("\(result.imageCount) image match(es) imported as image snippets.")
            }
            if result.skippedImage > 0 {
                notes.append("\(result.skippedImage) image match(es) skipped (image file missing or unreadable).")
            }
            // §3.8
            if result.markdownAsPlainCount > 0 {
                notes.append("\(result.markdownAsPlainCount) Markdown match(es) were imported as their literal Markdown text.")
            }
            if result.appScopedCount > 0 {
                notes.append("\(result.appScopedCount) match(es) kept their app scoping (apps / exclude_apps).")
            }
            if result.propagateCaseCount > 0 {
                notes.append("\(result.propagateCaseCount) match(es) used propagate_case — matching stays case-insensitive, but the expansion's case is not adapted.")
            }
            let nonImageSkipped = result.skippedVars + result.skippedForm + result.skippedHtml
                + result.skippedMarkdown + result.skippedRegex + result.skippedEmptyTrigger
            if nonImageSkipped > 0 {
                notes.append("\(nonImageSkipped) match(es) skipped (variables/forms/html/regex/empty trigger).")
            }
            return ImportResult(
                kind: .espanso,
                groups: result.groups,
                snippetCount: result.snippetCount,
                imageCount: result.imageCount,
                sourcePath: result.sourcePath,
                notes: notes
            )
        }
    }
}
