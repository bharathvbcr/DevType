import Foundation
import Yams

/// Imports static Espanso matches (Tier A) into DevType snippet groups.
/// `image_path` matches import as image snippets; dynamic vars, forms,
/// HTML/markdown, and regex triggers are skipped.
public enum EspansoImporter {

    public struct ImportResult {
        public var groups: [SnippetGroup]
        public var snippetCount: Int
        /// Matches imported as image snippets (`image_path`).
        public var imageCount: Int
        public var skippedVars: Int
        public var skippedForm: Int
        public var skippedHtml: Int
        public var skippedMarkdown: Int
        public var skippedImage: Int
        public var skippedRegex: Int
        public var skippedEmptyTrigger: Int
        public var sourcePath: String

        public var totalSkipped: Int {
            skippedVars + skippedForm + skippedHtml + skippedMarkdown
                + skippedImage + skippedRegex + skippedEmptyTrigger
        }
    }

    public enum ImportError: LocalizedError {
        case pathNotFound(String)
        case noMatchFiles(String)
        case parseFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case .pathNotFound(let p): return "Path not found: \(p)"
            case .noMatchFiles(let p): return "No Espanso match files found in: \(p)"
            case .parseFailed(let p, let detail): return "Failed to parse \(p): \(detail)"
            }
        }
    }

    // MARK: - Detection

    public static func detectConfigRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent("Library/Application Support/espanso"),
            home.appendingPathComponent(".config/espanso"),
        ]
        return candidates.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    // MARK: - Import entry

    /// Import from an espanso root, `match/` folder, package directory, or single `.yml`/`.yaml`.
    /// `imageStore` receives copied `image_path` payloads (injectable for tests).
    public static func importFrom(_ url: URL, imageStore: ImageAttachmentStore = .shared) throws -> ImportResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ImportError.pathNotFound(url.path)
        }

        var accumulator = Accumulator(sourcePath: url.path)

        if !isDir.boolValue {
            guard isYAMLFile(url) else {
                throw ImportError.noMatchFiles(url.path)
            }
            try processFile(url, groupName: makeGroupName(for: url, packageRoot: nil), forceInclude: true, imageStore: imageStore, into: &accumulator)
            return accumulator.makeResult()
        }

        // Package directory (has package.yml / _manifest.yml, or looks like a package tree).
        if looksLikePackageDirectory(url) {
            try importPackageDirectory(url, imageStore: imageStore, into: &accumulator)
            return accumulator.makeResult()
        }

        // Espanso root → import match/
        let matchDir = url.appendingPathComponent("match", isDirectory: true)
        if fm.fileExists(atPath: matchDir.path) {
            try importMatchDirectory(matchDir, imageStore: imageStore, into: &accumulator)
            return accumulator.makeResult()
        }

        // Already a match/ folder (or any folder of YAML match sets).
        try importMatchDirectory(url, imageStore: imageStore, into: &accumulator)
        return accumulator.makeResult()
    }

    // MARK: - Directory walks

    private static func importMatchDirectory(_ matchDir: URL, imageStore: ImageAttachmentStore, into accumulator: inout Accumulator) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: matchDir,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.noMatchFiles(matchDir.path)
        }

        var seedFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            guard isYAMLFile(fileURL) else { continue }
            let name = fileURL.lastPathComponent
            // Underscore-prefixed files are not auto-loaded (reached only via imports:).
            if name.hasPrefix("_") { continue }
            // package.yml / _manifest.yml are metadata, not match sets.
            if name == "package.yml" || name == "package.yaml" { continue }
            seedFiles.append(fileURL.standardizedFileURL)
        }

        guard !seedFiles.isEmpty else {
            throw ImportError.noMatchFiles(matchDir.path)
        }

        for file in seedFiles.sorted(by: { $0.path < $1.path }) {
            let packageRoot = enclosingPackageRoot(of: file, under: matchDir)
            let name = makeGroupName(for: file, packageRoot: packageRoot)
            try processFile(file, groupName: name, forceInclude: false, imageStore: imageStore, into: &accumulator)
        }

        if accumulator.groups.isEmpty && accumulator.snippetCount == 0 && accumulator.totalSkipped == 0 {
            throw ImportError.noMatchFiles(matchDir.path)
        }
    }

    private static func importPackageDirectory(_ packageDir: URL, imageStore: ImageAttachmentStore, into accumulator: inout Accumulator) throws {
        let title = packageTitle(from: packageDir) ?? packageDir.lastPathComponent
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: packageDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ImportError.noMatchFiles(packageDir.path)
        }

        var seedFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            guard isYAMLFile(fileURL) else { continue }
            let name = fileURL.lastPathComponent
            if name.hasPrefix("_") { continue }
            if name == "package.yml" || name == "package.yaml" { continue }
            seedFiles.append(fileURL.standardizedFileURL)
        }

        // package.yml itself may contain matches.
        for candidate in ["package.yml", "package.yaml"] {
            let pkg = packageDir.appendingPathComponent(candidate)
            if fm.fileExists(atPath: pkg.path) {
                seedFiles.append(pkg.standardizedFileURL)
            }
        }

        seedFiles = Array(Set(seedFiles.map(\.path))).map { URL(fileURLWithPath: $0) }.sorted { $0.path < $1.path }
        guard !seedFiles.isEmpty else {
            throw ImportError.noMatchFiles(packageDir.path)
        }

        for file in seedFiles {
            try processFile(file, groupName: title, forceInclude: true, imageStore: imageStore, into: &accumulator)
        }
    }

    // MARK: - File processing

    private static func processFile(
        _ fileURL: URL,
        groupName: String,
        forceInclude: Bool,
        imageStore: ImageAttachmentStore,
        into accumulator: inout Accumulator
    ) throws {
        let standardized = fileURL.standardizedFileURL
        if accumulator.visited.contains(standardized.path) { return }
        accumulator.visited.insert(standardized.path)

        let name = standardized.lastPathComponent
        if !forceInclude, name.hasPrefix("_") { return }

        let root: [String: Any]
        do {
            root = try loadYAMLDictionary(at: standardized)
        } catch {
            throw ImportError.parseFailed(standardized.path, error.localizedDescription)
        }

        // Resolve imports first (relative to this file's directory).
        if let imports = root["imports"] as? [Any] {
            let baseDir = standardized.deletingLastPathComponent()
            for entry in imports {
                guard let raw = entry as? String, !raw.isEmpty else { continue }
                let importedURL: URL
                if raw.hasPrefix("/") {
                    importedURL = URL(fileURLWithPath: raw).standardizedFileURL
                } else {
                    importedURL = baseDir.appendingPathComponent(raw).standardizedFileURL
                }
                // Imports may target underscore-prefixed private match sets.
                guard FileManager.default.fileExists(atPath: importedURL.path) else { continue }
                let importedGroup = makeGroupName(for: importedURL, packageRoot: nil)
                try processFile(importedURL, groupName: importedGroup, forceInclude: true, imageStore: imageStore, into: &accumulator)
            }
        }

        let matches = root["matches"] as? [[String: Any]] ?? []
        guard !matches.isEmpty else { return }

        let baseDir = standardized.deletingLastPathComponent()
        var snippets: [SnippetModel] = accumulator.pendingSnippets[groupName] ?? []
        for match in matches {
            appendSnippets(from: match, baseDir: baseDir, imageStore: imageStore, into: &snippets, counters: &accumulator)
        }
        accumulator.pendingSnippets[groupName] = snippets
    }

    private static func appendSnippets(
        from match: [String: Any],
        baseDir: URL,
        imageStore: ImageAttachmentStore,
        into snippets: inout [SnippetModel],
        counters: inout Accumulator
    ) {
        if match["regex"] != nil {
            counters.skippedRegex += 1
            return
        }
        if match["form"] != nil {
            counters.skippedForm += 1
            return
        }
        if match["html"] != nil {
            counters.skippedHtml += 1
            return
        }
        if match["markdown"] != nil {
            counters.skippedMarkdown += 1
            return
        }
        if let rawImagePath = match["image_path"] as? String, !rawImagePath.isEmpty {
            appendImageSnippets(
                from: match,
                rawImagePath: rawImagePath,
                baseDir: baseDir,
                imageStore: imageStore,
                into: &snippets,
                counters: &counters
            )
            return
        }
        if let vars = match["vars"] as? [Any], !vars.isEmpty {
            counters.skippedVars += 1
            return
        }

        guard let replace = match["replace"] as? String else {
            // No static replace payload (and not already counted above).
            if match["form"] == nil && match["html"] == nil
                && match["markdown"] == nil && match["image_path"] == nil {
                counters.skippedVars += 1
            }
            return
        }

        // Never import untranslated Espanso {{var}} mustache (collides with DevType macros).
        if replace.contains("{{") {
            counters.skippedVars += 1
            return
        }

        let triggers = collectTriggers(from: match)
        if triggers.isEmpty {
            counters.skippedEmptyTrigger += 1
            return
        }

        let label = (match["label"] as? String) ?? ""
        let word = boolValue(match["word"])
        let leftWord = boolValue(match["left_word"])
        let rightWord = boolValue(match["right_word"])
        let requireWordBoundary = word || leftWord || rightWord
        let replacement = replace.replacingOccurrences(of: "$|$", with: "{{cursor}}")

        var addedAny = false
        for trigger in triggers {
            let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                counters.skippedEmptyTrigger += 1
                continue
            }
            let title = label.isEmpty ? trimmed : label
            snippets.append(SnippetModel(
                title: title,
                label: label,
                triggerKeyword: trimmed,
                replacementText: replacement,
                isCaseSensitive: false,
                requireWordBoundary: requireWordBoundary,
                isPlainText: true,
                enabled: true
            ))
            counters.snippetCount += 1
            addedAny = true
        }
        if !addedAny {
            // All triggers were empty.
        }
    }

    /// Imports an `image_path` match as an image snippet: the image file is copied
    /// into the attachment store so the snippet survives the original config.
    private static func appendImageSnippets(
        from match: [String: Any],
        rawImagePath: String,
        baseDir: URL,
        imageStore: ImageAttachmentStore,
        into snippets: inout [SnippetModel],
        counters: inout Accumulator
    ) {
        let imageURL: URL
        if rawImagePath.hasPrefix("/") {
            imageURL = URL(fileURLWithPath: rawImagePath).standardizedFileURL
        } else {
            imageURL = baseDir.appendingPathComponent(rawImagePath).standardizedFileURL
        }

        let storedName: String
        do {
            storedName = try imageStore.importImage(from: imageURL)
        } catch {
            counters.skippedImage += 1
            return
        }

        let triggers = collectTriggers(from: match)
        if triggers.isEmpty {
            counters.skippedEmptyTrigger += 1
            return
        }

        let label = (match["label"] as? String) ?? ""
        let word = boolValue(match["word"])
        let leftWord = boolValue(match["left_word"])
        let rightWord = boolValue(match["right_word"])
        let requireWordBoundary = word || leftWord || rightWord

        for trigger in triggers {
            let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                counters.skippedEmptyTrigger += 1
                continue
            }
            let title = label.isEmpty ? trimmed : label
            snippets.append(SnippetModel(
                title: title,
                label: label,
                triggerKeyword: trimmed,
                replacementText: "",
                isCaseSensitive: false,
                requireWordBoundary: requireWordBoundary,
                isPlainText: true,
                enabled: true,
                imagePath: storedName
            ))
            counters.snippetCount += 1
        }
        counters.imageCount += 1
    }

    // MARK: - Helpers

    private static func collectTriggers(from match: [String: Any]) -> [String] {
        if let triggers = match["triggers"] as? [Any] {
            return triggers.compactMap { $0 as? String }
        }
        if let trigger = match["trigger"] as? String {
            return [trigger]
        }
        return []
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            return ["true", "yes", "1"].contains(s.lowercased())
        }
        return false
    }

    private static func isYAMLFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "yml" || ext == "yaml"
    }

    private static func looksLikePackageDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        let manifest = url.appendingPathComponent("_manifest.yml")
        let packageYml = url.appendingPathComponent("package.yml")
        let packageYaml = url.appendingPathComponent("package.yaml")
        return fm.fileExists(atPath: manifest.path)
            || fm.fileExists(atPath: packageYml.path)
            || fm.fileExists(atPath: packageYaml.path)
    }

    private static func enclosingPackageRoot(of file: URL, under matchDir: URL) -> URL? {
        // match/packages/<name>/<ver>/...
        let packages = matchDir.appendingPathComponent("packages", isDirectory: true).standardizedFileURL
        let path = file.standardizedFileURL.path
        let packagesPath = packages.path
        guard path.hasPrefix(packagesPath + "/") else { return nil }

        var current = file.deletingLastPathComponent()
        while current.path.hasPrefix(packagesPath) && current.path != packagesPath {
            if looksLikePackageDirectory(current) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private static func makeGroupName(for file: URL, packageRoot: URL?) -> String {
        if let packageRoot, let title = packageTitle(from: packageRoot) {
            return title
        }
        if let packageRoot {
            return packageRoot.lastPathComponent
        }
        return file.deletingPathExtension().lastPathComponent
    }

    private static func packageTitle(from packageRoot: URL) -> String? {
        let manifest = packageRoot.appendingPathComponent("_manifest.yml")
        guard FileManager.default.fileExists(atPath: manifest.path),
              let dict = try? loadYAMLDictionary(at: manifest) else {
            return nil
        }
        if let title = dict["title"] as? String, !title.isEmpty { return title }
        if let name = dict["name"] as? String, !name.isEmpty { return name }
        return nil
    }

    private static func loadYAMLDictionary(at url: URL) throws -> [String: Any] {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let loaded = try Yams.load(yaml: text) else {
            return [:]
        }
        if let dict = loaded as? [String: Any] {
            return dict
        }
        // Yams may return NSDictionary bridging.
        if let dict = loaded as? NSDictionary {
            return dict as? [String: Any] ?? [:]
        }
        return [:]
    }

    // MARK: - Accumulator

    private struct Accumulator {
        var sourcePath: String
        var visited: Set<String> = []
        var pendingSnippets: [String: [SnippetModel]] = [:]
        var snippetCount = 0
        var imageCount = 0
        var skippedVars = 0
        var skippedForm = 0
        var skippedHtml = 0
        var skippedMarkdown = 0
        var skippedImage = 0
        var skippedRegex = 0
        var skippedEmptyTrigger = 0

        var totalSkipped: Int {
            skippedVars + skippedForm + skippedHtml + skippedMarkdown
                + skippedImage + skippedRegex + skippedEmptyTrigger
        }

        var groups: [SnippetGroup] {
            pendingSnippets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .compactMap { name -> SnippetGroup? in
                    guard let snippets = pendingSnippets[name], !snippets.isEmpty else { return nil }
                    return SnippetGroup(name: name, snippets: snippets)
                }
        }

        func makeResult() -> ImportResult {
            ImportResult(
                groups: groups,
                snippetCount: snippetCount,
                imageCount: imageCount,
                skippedVars: skippedVars,
                skippedForm: skippedForm,
                skippedHtml: skippedHtml,
                skippedMarkdown: skippedMarkdown,
                skippedImage: skippedImage,
                skippedRegex: skippedRegex,
                skippedEmptyTrigger: skippedEmptyTrigger,
                sourcePath: sourcePath
            )
        }
    }
}
