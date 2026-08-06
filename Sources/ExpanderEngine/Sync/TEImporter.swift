// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

/// Imports snippets from TextExpander 4/5 data folders
/// (.textexpandersettings and .textexpanderbackup bundles).
public enum TEImporter {

    public struct ImportResult {
        public var groups: [SnippetGroup]
        public var snippetCount: Int
        public var richTextCount: Int
        public var skippedEmptyAbbrev: Int
        public var sourcePath: String
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
        if let backups = try? FileManager.default.contentsOfDirectory(
            at: backupsDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) {
            let sorted = backups
                .filter { $0.lastPathComponent.hasSuffix(".textexpanderbackup") }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da > db
                }
            if let newest = sorted.first { candidates.append(newest) }
        }
        return candidates.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    public static func importFolder(_ folder: URL) throws -> ImportResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.folderNotFound(folder.path)
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)
        let groupFiles = files.filter {
            $0.lastPathComponent.contains("group_") && $0.pathExtension == "xml"
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
        for url in groupFiles {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
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
        var skippedEmpty = 0

        for candidate in bestByUUID.values {
            let plist = candidate.plist
            let name = plist["name"] as? String ?? "Imported"
            let groupID = UUID(uuidString: candidate.uuid) ?? UUID()
            var snippets: [SnippetModel] = []

            for raw in plist["snippetPlists"] as? [[String: Any]] ?? [] {
                let abbreviation = raw["abbreviation"] as? String ?? ""
                guard !abbreviation.isEmpty else {
                    skippedEmpty += 1
                    continue
                }
                let plainText = raw["plainText"] as? String ?? ""
                let label = raw["label"] as? String ?? ""
                let snippetType = raw["snippetType"] as? Int ?? 0
                let mode = raw["abbreviationMode"] as? Int ?? 0
                let created = raw["creationDate"] as? Date ?? Date()
                let modified = raw["modificationDate"] as? Date ?? created
                let id = (raw["uuidString"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()

                if snippetType != 0 { richTextCount += 1 }
                let title = label.isEmpty ? abbreviation : label
                snippets.append(SnippetModel(
                    id: id,
                    title: title,
                    label: label,
                    triggerKeyword: abbreviation,
                    replacementText: plainText,
                    isCaseSensitive: mode == 0,
                    isPlainText: snippetType == 0,
                    enabled: true,
                    createdAt: created,
                    updatedAt: modified
                ))
                snippetCount += 1
            }
            groups.append(SnippetGroup(id: groupID, name: name, snippets: snippets))
        }

        groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ImportResult(
            groups: groups,
            snippetCount: snippetCount,
            richTextCount: richTextCount,
            skippedEmptyAbbrev: skippedEmpty,
            sourcePath: folder.path
        )
    }
}
