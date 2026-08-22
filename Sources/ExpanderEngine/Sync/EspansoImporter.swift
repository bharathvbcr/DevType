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
        /// §3.8: `markdown:` matches imported as their literal Markdown source.
        public var markdownAsPlainCount: Int = 0
        /// §3.8: matches carrying `propagate_case` (case-insensitive matching preserved; the
        /// output-case adaptation itself has no DevType equivalent).
        public var propagateCaseCount: Int = 0
        /// §3.8: matches scoped with `apps:` / `exclude_apps:` mapped onto
        /// `SnippetModel.includeApps` / `excludeApps`.
        public var appScopedCount: Int = 0
        /// Items refused at the size boundary (`SnippetImporter.SnippetImportLimits`).
        public var skippedOversized: Int = 0
        /// §hardening: `imports:` entries refused because they pointed outside the
        /// importing file's directory (absolute paths, `..` escapes) or lacked a
        /// `.yml`/`.yaml` extension. Untrusted configs must not read arbitrary files.
        public var skippedUnsafeImports: Int = 0
        /// §robustness: files reached via `imports:` whose YAML failed to parse. The
        /// batch continues with the remaining imports; a broken top-level entry file
        /// still fails the import outright.
        public var skippedParseFailed: Int = 0

        public var totalSkipped: Int {
            skippedVars + skippedForm + skippedHtml + skippedMarkdown
                + skippedImage + skippedRegex + skippedEmptyTrigger
                + skippedOversized
                + skippedUnsafeImports + skippedParseFailed
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

        // Import files are untrusted input: skip absurdly large sources instead of
        // ballooning memory in the YAML parser. Counted so the user is told.
        if fileSize(at: standardized) > SnippetImporter.SnippetImportLimits.maxSourceFileBytes {
            accumulator.skippedOversized += 1
            return
        }

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
                // §hardening: import files are untrusted input. An `imports:` entry may
                // only name a YAML file inside this file's directory — absolute targets
                // and `..` escapes would let an untrusted package read any user-readable
                // file, so they are refused and counted instead of followed.
                guard isImportableYAMLName(raw),
                      let importedURL = containedURL(raw, relativeTo: baseDir) else {
                    accumulator.skippedUnsafeImports += 1
                    continue
                }
                // Imports may target underscore-prefixed private match sets.
                guard FileManager.default.fileExists(atPath: importedURL.path) else { continue }
                let importedGroup = makeGroupName(for: importedURL, packageRoot: nil)
                do {
                    try processFile(importedURL, groupName: importedGroup, forceInclude: true, imageStore: imageStore, into: &accumulator)
                } catch {
                    // §robustness: one malformed imported file must not abort the whole
                    // batch — skip it, count it, keep processing siblings. The top-level
                    // entry file keeps its throwing contract (see `importFrom`).
                    accumulator.skippedParseFailed += 1
                }
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
            // HTML is a rendered payload, not source text the user typed — importing the raw
            // markup would inject angle brackets into plain-text fields.
            counters.skippedHtml += 1
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

        // §3.8: `markdown:` is source text the user typed, so import it verbatim as plain text
        // (the same downgrade the TextExpander importer applies to rich text) instead of
        // dropping the match entirely.
        var importedMarkdown = false
        let payload: String
        if let replace = match["replace"] as? String {
            payload = replace
        } else if let markdown = match["markdown"] as? String {
            payload = markdown
            importedMarkdown = true
        } else {
            // No static payload (and not already counted above).
            if match["form"] == nil && match["html"] == nil
                && match["markdown"] == nil && match["image_path"] == nil {
                counters.skippedVars += 1
            }
            return
        }

        // §3.8: the old rule rejected the match on **any** `{{`, including literal braces the
        // user wanted. Only an actual Espanso variable reference — `{{identifier}}` naming
        // something DevType cannot resolve — is a reason to skip.
        if containsUnresolvableEspansoVariable(payload) {
            counters.skippedVars += 1
            return
        }

        let triggers = collectTriggers(from: match)
        if triggers.isEmpty {
            counters.skippedEmptyTrigger += 1
            return
        }

        let label = (match["label"] as? String) ?? ""
        // §3.8: `word` / `left_word` / `right_word` → requireWordBoundary.
        let word = boolValue(match["word"])
        let leftWord = boolValue(match["left_word"])
        let rightWord = boolValue(match["right_word"])
        let requireWordBoundary = word || leftWord || rightWord
        // §3.8: `propagate_case` implies case-insensitive matching. DevType has no equivalent for
        // the output-case adaptation itself, so it is counted and reported rather than dropped
        // silently.
        let propagateCase = boolValue(match["propagate_case"])
        if propagateCase { counters.propagateCaseCount += 1 }
        // §3.8: `apps:` / `exclude_apps:` → SnippetModel.includeApps / excludeApps (§4.4).
        let includeApps = stringList(match["apps"])
        let excludeApps = stringList(match["exclude_apps"])
        if !includeApps.isEmpty || !excludeApps.isEmpty { counters.appScopedCount += 1 }
        // §3.8: `search_terms:` are exactly DevType tags.
        let tags = stringList(match["search_terms"])
        let replacement = payload.replacingOccurrences(of: "$|$", with: "{{cursor}}")

        var addedAny = false
        for trigger in triggers {
            let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                counters.skippedEmptyTrigger += 1
                continue
            }
            if SnippetImporter.SnippetImportLimits.isOversized(
                trigger: trimmed, replacement: replacement
            ) {
                counters.skippedOversized += 1
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
                enabled: true,
                tags: tags,
                includeApps: includeApps,
                excludeApps: excludeApps
            ))
            counters.snippetCount += 1
            addedAny = true
        }
        if addedAny && importedMarkdown {
            counters.markdownAsPlainCount += 1
        }
    }

    /// §3.8: Espanso variable syntax is `{{name}}` / `{{name.field}}` / `{{form.field}}`.
    ///
    /// Literal text such as `{{ hello }}`, `{{1}}`, or a Handlebars snippet the user is
    /// deliberately expanding is **not** variable syntax and must survive the import. DevType's
    /// own mustache tags are also fine — they resolve at expansion time.
    static func containsUnresolvableEspansoVariable(_ text: String) -> Bool {
        guard text.contains("{{"), let regex = espansoVariableRegex else { return false }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches where match.numberOfRanges >= 2 {
            let identifier = ns.substring(with: match.range(at: 1)).lowercased()
            let root = identifier.components(separatedBy: ".").first ?? identifier
            if !devTypeResolvableTags.contains(root) { return true }
        }
        return false
    }

    /// Tags DevType's own template engine resolves (`DynamicTemplateEngine` / `MacroRenderer`).
    private static let devTypeResolvableTags: Set<String> = [
        "cursor", "clipboard", "date", "time", "calc", "snippet",
        "uuid", "random", "counter", "upper", "lower", "title", "sentence",
    ]

    /// `{{ident}}` / `{{ident.field}}` / `{{ident:arg}}` — no spaces, identifier-shaped.
    private static let espansoVariableRegex = try? NSRegularExpression(
        pattern: "\\{\\{([A-Za-z_][A-Za-z0-9_]*(?:\\.[A-Za-z0-9_]+)*)(?::[^{}]*)?\\}\\}",
        options: []
    )

    /// Accepts a YAML scalar or sequence and normalizes to a trimmed, non-empty string list.
    private static func stringList(_ value: Any?) -> [String] {
        if let single = value as? String {
            let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let list = value as? [Any] {
            return list.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
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
        // §hardening: same confinement as `imports:` — an untrusted config may only
        // pull images from inside its own tree. Absolute paths and `..` escapes used
        // to copy arbitrary user-readable files into the store (an exfiltration
        // primitive); they now count as skipped images like any other failure.
        guard let imageURL = containedURL(rawImagePath, relativeTo: baseDir) else {
            counters.skippedImage += 1
            return
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
        // §3.8: same metadata translation as the text path.
        let includeApps = stringList(match["apps"])
        let excludeApps = stringList(match["exclude_apps"])
        if !includeApps.isEmpty || !excludeApps.isEmpty { counters.appScopedCount += 1 }
        let tags = stringList(match["search_terms"])

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
                imagePath: storedName,
                tags: tags,
                includeApps: includeApps,
                excludeApps: excludeApps
            ))
            counters.snippetCount += 1
        }
        counters.imageCount += 1
    }

    // MARK: - Helpers

    /// `imports:` targets must be YAML match files — anything else is refused
    /// outright rather than parsed opportunistically.
    private static func isImportableYAMLName(_ raw: String) -> Bool {
        let ext = (raw as NSString).pathExtension.lowercased()
        return ext == "yml" || ext == "yaml"
    }

    /// §hardening: resolves an untrusted relative reference (an `imports:` entry or
    /// an Espanso `image_path`) against `root` — the importing file's directory —
    /// and returns `nil` for anything that would read outside it.
    ///
    /// Refused: absolute targets (a leading `/`), and any target whose resolved
    /// standardized location does not sit strictly below `root` (which covers every
    /// surviving `..` after standardization). Symlinks are resolved on both sides
    /// first so a symlinked directory inside the config cannot smuggle a path out.
    /// Plain relative references — including subdirectories — resolve exactly as
    /// they always did.
    private static func containedURL(_ raw: String, relativeTo root: URL) -> URL? {
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.hasPrefix("\\") else { return nil }

        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = root.appendingPathComponent(raw).standardizedFileURL
        let candidatePath = candidate.resolvingSymlinksInPath().path

        // Component-wise prefix compare so `/root-evil` can never pass a `/root`
        // check, and the target must be *inside* the root, not the root itself.
        let rootParts = (rootPath as NSString).pathComponents
        let candidateParts = (candidatePath as NSString).pathComponents
        guard candidateParts.count > rootParts.count,
              Array(candidateParts.prefix(rootParts.count)) == rootParts else {
            return nil
        }
        return URL(fileURLWithPath: candidatePath)
    }

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

    /// File size in bytes; 0 when the file cannot be stat'ed (the read itself will fail).
    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int64) ?? 0
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

    /// Directory names that carry no meaning for a user-facing group label.
    private static let genericContainerDirectories: Set<String> = [
        "match", "matches", "espanso", "config", "packages", ".config", "yml", "yaml",
    ]

    /// §3.8: the fallback used to be the bare file basename, so `match/work/base.yml` and
    /// `match/home/base.yml` produced the same group name and merged — destructively, once
    /// `SnippetStore.importGroups` replaced the same-named group wholesale (§1.10). Qualify the
    /// name with the parent directory unless that directory is a generic container.
    private static func makeGroupName(for file: URL, packageRoot: URL?) -> String {
        if let packageRoot, let title = packageTitle(from: packageRoot) {
            return title
        }
        if let packageRoot {
            return packageRoot.lastPathComponent
        }
        let base = file.deletingPathExtension().lastPathComponent
        let parent = file.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty,
              parent != "/",
              parent != base,
              !genericContainerDirectories.contains(parent.lowercased())
        else {
            return base
        }
        return "\(parent)/\(base)"
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
        // §3.8
        var markdownAsPlainCount = 0
        var propagateCaseCount = 0
        var appScopedCount = 0
        var skippedOversized = 0
        // §hardening
        var skippedUnsafeImports = 0
        var skippedParseFailed = 0

        var totalSkipped: Int {
            skippedVars + skippedForm + skippedHtml + skippedMarkdown
                + skippedImage + skippedRegex + skippedEmptyTrigger
                + skippedOversized
                + skippedUnsafeImports + skippedParseFailed
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
                sourcePath: sourcePath,
                markdownAsPlainCount: markdownAsPlainCount,
                propagateCaseCount: propagateCaseCount,
                appScopedCount: appScopedCount,
                skippedOversized: skippedOversized,
                skippedUnsafeImports: skippedUnsafeImports,
                skippedParseFailed: skippedParseFailed
            )
        }
    }
}
