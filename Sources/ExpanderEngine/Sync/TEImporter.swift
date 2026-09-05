// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// Imports snippets from TextExpander 4/5 data folders
/// (.textexpandersettings and .textexpanderbackup bundles).
public enum TEImporter {

    // MARK: - TextExpander plist constants (§3.8)

    /// `snippetPlists[].snippetType`.
    ///
    /// TextExpander stores the payload kind alongside the snippet. Only `.plainText` round-trips
    /// losslessly into DevType; everything else is flattened to `plainText` and counted so the
    /// importer can tell the user what was downgraded.
    public enum TESnippetType: Int, Equatable {
        case plainText = 0
        case richText = 1
        case script = 2
        case appleScript = 3
        case picture = 4

        public init(rawPlistValue: Int) {
            self = TESnippetType(rawValue: rawPlistValue) ?? .richText
        }

        public var isPlainText: Bool { self == .plainText }
    }

    /// `snippetPlists[].abbreviationMode`.
    ///
    /// Replaces the bare `mode == 0` magic number that used to sit in this file with no comment.
    /// Mode 0 is TextExpander's "case sensitive" abbreviation matching; the other modes both
    /// match case-insensitively (they differ only in how the *output* case is adapted, which
    /// DevType has no equivalent for).
    public enum TEAbbreviationMode: Int, Equatable {
        case caseSensitive = 0
        case adaptToCase = 1
        case ignoreCase = 2

        public init(rawPlistValue: Int) {
            self = TEAbbreviationMode(rawValue: rawPlistValue) ?? .caseSensitive
        }

        public var isCaseSensitive: Bool { self == .caseSensitive }
    }

    /// Group-level "Expand Abbreviations" setting.
    ///
    /// §3.8: `requireWordBoundary` was never derived from TextExpander data, so every imported
    /// snippet silently took `SnippetModel`'s default of `true` — which changes the behavior of
    /// TextExpander's expand-immediately snippets, the common case. TextExpander's default is to
    /// expand as soon as the abbreviation is typed, so that is the default here too.
    public enum TEExpandAfterMode: Int, Equatable {
        /// Fire as soon as the abbreviation is complete (TextExpander default).
        case anyCharacter = 0
        /// Require a delimiter after the abbreviation.
        case delimiter = 1

        public init(rawPlistValue: Int) {
            self = TEExpandAfterMode(rawValue: rawPlistValue) ?? .anyCharacter
        }

        public var requiresWordBoundary: Bool { self == .delimiter }
    }

    /// Keys TextExpander has used across versions for the group-level delimiter setting.
    private static let expandAfterKeys = ["expandAfterMode", "expansionMode", "delimiterMode"]
    /// Keys TextExpander has used for group enablement. Absent ⇒ enabled.
    private static let groupEnabledKeys = ["enabled", "groupEnabled", "isEnabled"]
    private static let groupDisabledKeys = ["disabled", "groupDisabled", "isDisabled"]

    // MARK: - Result

    public struct ImportResult {
        public var groups: [SnippetGroup]
        public var snippetCount: Int
        public var richTextCount: Int
        public var skippedEmptyAbbrev: Int
        public var sourcePath: String
        /// §3.8: groups that arrived disabled and were imported disabled rather than silently on.
        public var disabledGroupCount: Int = 0
        /// §3.8: snippets whose group asked for delimiter expansion (`requireWordBoundary`).
        public var wordBoundaryCount: Int = 0
        /// §3.8: script / AppleScript snippets — imported as their literal source text.
        public var scriptCount: Int = 0
        /// Items refused at the size boundary (`SnippetImportLimits`): whole group
        /// files over the byte cap and individual snippets with oversized bodies.
        public var skippedOversized: Int = 0
    }

    public enum ImportError: LocalizedError {
        case folderNotFound(String)
        case noGroupFiles(String)

        public var errorDescription: String? {
            switch self {
            case .folderNotFound(let p): return "Folder not found: \(p)"
            case .noGroupFiles(let p): return "No TextExpander group files found in: \(p)"
            }
        }
    }

    public static func detectDataFolders() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [URL] = [
            home.appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/TextExpander/Settings.textexpandersettings"),
            home.appendingPathComponent(
                "Library/Application Support/TextExpander/Settings.textexpandersettings"),
            home.appendingPathComponent("Dropbox/TextExpander/Settings.textexpandersettings"),
        ]
        let backupsDir = home.appendingPathComponent("Library/Application Support/TextExpander/Backups")
        if let enumerator = FileManager.default.enumerator(
            at: backupsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) {
            var inspected = 0
            var newest: (url: URL, date: Date)?
            var overflowed = false
            for case let backup as URL in enumerator {
                inspected += 1
                guard inspected <= SnippetImporter.ResourceLimits.production.maxFileCount else {
                    overflowed = true
                    break
                }
                guard backup.lastPathComponent.hasSuffix(".textexpanderbackup") else { continue }
                let date = (try? backup.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                if newest == nil || date > newest!.date {
                    newest = (backup, date)
                }
            }
            // A truncated discovery scan cannot truthfully claim which backup is
            // newest. Keep the fixed locations but omit the ambiguous candidate.
            if !overflowed, let newest { candidates.append(newest.url) }
        }
        return candidates.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    public static func importFolder(
        _ folder: URL,
        limits: SnippetImporter.ResourceLimits = .production
    ) throws -> ImportResult {
        try importFolder(folder, budget: SnippetImporter.ResourceBudget(limits: limits))
    }

    internal static func importFolder(
        _ folder: URL,
        budget: SnippetImporter.ResourceBudget
    ) throws -> ImportResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.folderNotFound(folder.path)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            throw ImportError.noGroupFiles(folder.path)
        }
        var groupFiles: [URL] = []
        for case let url as URL in enumerator {
            try budget.registerFile(url)
            if url.lastPathComponent.contains("group_") && url.pathExtension.lowercased() == "xml" {
                groupFiles.append(url)
            }
        }
        guard !groupFiles.isEmpty else {
            throw ImportError.noGroupFiles(folder.path)
        }

        struct Candidate {
            let url: URL
            let isConflictCopy: Bool
            let sequence: Int
            let plist: [String: Any]
            let uuid: String
        }

        var bestByUUID: [String: Candidate] = [:]
        var skippedOversized = 0
        for url in groupFiles.sorted(by: { $0.path < $1.path }) {
            // Import files are untrusted input: refuse to read absurdly large
            // sources rather than ballooning memory in the plist parser.
            guard let data = try SnippetImporter.SnippetImportLimits.boundedSourceData(at: url) else {
                skippedOversized += 1
                continue
            }
            try budget.consumeBytes(data.count, from: url)
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let uuid = plist["uuidString"] as? String
            else { continue }
            let name = url.lastPathComponent
            let isConflict = !name.hasPrefix("group_")
            let sequence = Int(name.split(separator: "_").last?.split(separator: ".").first ?? "0") ?? 0
            let candidate = Candidate(url: url, isConflictCopy: isConflict, sequence: sequence, plist: plist, uuid: uuid)
            if let existing = bestByUUID[uuid] {
                let existingScore = (existing.isConflictCopy ? 0 : 1, existing.sequence)
                let newScore = (isConflict ? 0 : 1, sequence)
                if newScore > existingScore { bestByUUID[uuid] = candidate }
            } else {
                bestByUUID[uuid] = candidate
            }
        }

        var groups: [SnippetGroup] = []
        var snippetCount = 0
        var richTextCount = 0
        var scriptCount = 0
        var skippedEmpty = 0
        var disabledGroupCount = 0
        var wordBoundaryCount = 0

        for candidate in bestByUUID.values {
            let plist = candidate.plist
            let name = plist["name"] as? String ?? "Imported"
            let groupID = UUID(uuidString: candidate.uuid) ?? UUID()

            // §3.8: group enablement is real user intent — importing a disabled TextExpander
            // group as enabled turns snippets back on behind the user's back.
            let isGroupEnabled = groupEnabled(in: plist)
            if !isGroupEnabled { disabledGroupCount += 1 }

            // §3.8: group-level "Expand Abbreviations" drives DevType's word-boundary flag.
            let expandAfter = TEExpandAfterMode(
                rawPlistValue: intValue(in: plist, keys: expandAfterKeys) ?? TEExpandAfterMode.anyCharacter.rawValue
            )
            let requireWordBoundary = expandAfter.requiresWordBoundary

            var snippets: [SnippetModel] = []
            let rawSnippetEntries = plist["snippetPlists"] as? [Any] ?? []
            try budget.consumeSnippets(rawSnippetEntries.count)

            for case let raw as [String: Any] in rawSnippetEntries {
                let abbreviation = raw["abbreviation"] as? String ?? ""
                guard !abbreviation.isEmpty else {
                    skippedEmpty += 1
                    continue
                }
                // Rich text and scripts have no DevType equivalent; TextExpander keeps a plain
                // rendering alongside, so fall back through the alternatives it writes.
                let plainText = (raw["plainText"] as? String)
                    ?? (raw["stringValue"] as? String)
                    ?? ""
                let label = raw["label"] as? String ?? ""
                let snippetType = TESnippetType(rawPlistValue: raw["snippetType"] as? Int ?? 0)
                let mode = TEAbbreviationMode(rawPlistValue: raw["abbreviationMode"] as? Int ?? 0)
                let created = raw["creationDate"] as? Date ?? Date()
                let modified = raw["modificationDate"] as? Date ?? created
                _ = (raw["uuidString"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()

                switch snippetType {
                case .plainText: break
                case .script, .appleScript: scriptCount += 1
                case .richText, .picture: richTextCount += 1
                }

                // Per-snippet override, when TextExpander wrote one; otherwise the group setting.
                let snippetExpandAfter = intValue(in: raw, keys: expandAfterKeys)
                    .map { TEExpandAfterMode(rawPlistValue: $0).requiresWordBoundary }
                    ?? requireWordBoundary
                if snippetExpandAfter { wordBoundaryCount += 1 }

                if SnippetImporter.SnippetImportLimits.isOversized(
                    trigger: abbreviation, replacement: plainText
                ) {
                    skippedOversized += 1
                    continue
                }

                let title = label.isEmpty ? abbreviation : label
                snippets.append(SnippetModel(
                    title: title,
                    label: label,
                    triggerKeyword: abbreviation,
                    replacementText: plainText,
                    // §3.8: was `mode == 0` with no explanation — see `TEAbbreviationMode`.
                    isCaseSensitive: mode.isCaseSensitive,
                    requireWordBoundary: snippetExpandAfter,
                    isPlainText: snippetType.isPlainText,
                    enabled: true,
                    createdAt: created,
                    updatedAt: modified
                ))
                snippetCount += 1
            }
            groups.append(SnippetGroup(id: groupID, name: name, enabled: isGroupEnabled, snippets: snippets))
        }

        groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ImportResult(
            groups: groups,
            snippetCount: snippetCount,
            richTextCount: richTextCount,
            skippedEmptyAbbrev: skippedEmpty,
            sourcePath: folder.path,
            disabledGroupCount: disabledGroupCount,
            wordBoundaryCount: wordBoundaryCount,
            scriptCount: scriptCount,
            skippedOversized: skippedOversized
        )
    }

    /// Reads at most one byte beyond the per-file ceiling. A stat check alone is
    /// insufficient because an untrusted source can grow between stat and read.

    // MARK: - Plist helpers

    /// First integer found under any of `keys` (TextExpander renamed several across versions).
    private static func intValue(in plist: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = plist[key] as? Int { return value }
            if let number = plist[key] as? NSNumber { return number.intValue }
        }
        return nil
    }

    private static func boolValue(in plist: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = plist[key] as? Bool { return value }
            if let number = plist[key] as? NSNumber { return number.boolValue }
        }
        return nil
    }

    /// §3.8: enabled unless TextExpander explicitly said otherwise, under either polarity of key.
    private static func groupEnabled(in plist: [String: Any]) -> Bool {
        if let enabled = boolValue(in: plist, keys: groupEnabledKeys) { return enabled }
        if let disabled = boolValue(in: plist, keys: groupDisabledKeys) { return !disabled }
        return true
    }
}
