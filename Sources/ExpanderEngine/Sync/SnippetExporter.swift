import Foundation
import Yams

/// §0.4: The other half of `SnippetImporter`.
///
/// Import was fully built (TextExpander + Espanso auto-detect) while the only way out was an
/// internal backup file — the opposite of the lock-in story the importers sell against. JSON
/// export of DevType's own library format lives on the store (`SnippetStore.exportLibraryData()`);
/// this type covers the *interchange* formats, so a user can leave for Espanso or take their
/// snippets into a spreadsheet.
public enum SnippetExporter {

    public enum Format: String, Equatable, CaseIterable {
        /// Espanso match file (`matches:` list). Round-trips through `EspansoImporter`.
        case espansoYAML
        /// RFC 4180 CSV, one row per snippet.
        case csv

        public var fileExtension: String {
            switch self {
            case .espansoYAML: return "yml"
            case .csv: return "csv"
            }
        }

        public var displayName: String {
            switch self {
            case .espansoYAML: return "Espanso YAML"
            case .csv: return "CSV"
            }
        }

        /// Suggested `NSSavePanel` file name.
        public var suggestedFileName: String {
            switch self {
            case .espansoYAML: return "devtype-espanso.\(fileExtension)"
            case .csv: return "devtype-snippets.\(fileExtension)"
            }
        }
    }

    public enum ExportError: LocalizedError {
        case yamlSerializationFailed(String)
        case encodingFailed
        /// The attachment could not be read from inside the image store. The associated
        /// value is the snippet trigger, never a filesystem path.
        case imageUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .yamlSerializationFailed(let detail): return "Could not write Espanso YAML: \(detail)"
            case .encodingFailed: return "Could not encode the exported snippets as UTF-8."
            case .imageUnavailable(let trigger):
                let name = trigger.isEmpty ? "snippet" : trigger
                return "Could not export the image for \"\(name)\" because the attachment is missing or is not inside the image store."
            }
        }
    }

    /// Directory name, relative to the match file, that holds exported images.
    public static let espansoImageDirectoryName = "images"

    /// Options shared by every format.
    public struct Options {
        /// Skip snippets (and groups) that are disabled.
        public var includeDisabled: Bool
        /// Reads image snippets so Espanso `image_path` can be a relative `images/<safe name>`.
        /// Directory export writes those files beside the match YAML. A nil store, a missing
        /// file, or a path outside the store fails the export — `snippet.imagePath` is not
        /// written into the YAML.
        public var imageStore: ImageAttachmentStore?

        public init(includeDisabled: Bool = true, imageStore: ImageAttachmentStore? = ImageAttachmentStore.shared) {
            self.includeDisabled = includeDisabled
            self.imageStore = imageStore
        }

        public static var `default`: Options { Options() }
    }

    // MARK: - Entry points

    public static func data(
        from groups: [SnippetGroup],
        format: Format,
        options: Options = .default
    ) throws -> Data {
        let text: String
        switch format {
        case .espansoYAML: text = try espansoYAML(from: groups, options: options)
        case .csv: text = csv(from: groups, options: options)
        }
        guard let data = text.data(using: .utf8) else { throw ExportError.encodingFailed }
        return data
    }

    // MARK: - Espanso YAML

    /// One Espanso match file containing every exported snippet.
    ///
    /// Image matches use a relative `image_path`. This string cannot carry the image bytes;
    /// `espansoDirectoryDocument` is the round trip.
    public static func espansoYAML(
        from groups: [SnippetGroup],
        options: Options = .default
    ) throws -> String {
        var images = ImageExportPlan()
        return try renderEspansoYAML(from: groups, options: options, images: &images)
    }

    /// Match files plus the image bytes those files reference. Paths are relative to the
    /// directory the match files are written into.
    public struct EspansoDirectoryDocument: Equatable {
        public struct MatchFile: Equatable {
            public let fileName: String
            public let contents: String
        }

        public struct ImageFile: Equatable {
            public let relativePath: String
            public let data: Data
        }

        public let files: [MatchFile]
        public let images: [ImageFile]
    }

    public static func espansoDirectoryDocument(
        from groups: [SnippetGroup],
        options: Options = .default
    ) throws -> EspansoDirectoryDocument {
        var images = ImageExportPlan()
        var files: [EspansoDirectoryDocument.MatchFile] = []
        var usedNames: Set<String> = []
        for group in groups {
            if !options.includeDisabled && !group.enabled { continue }
            let contents = try renderEspansoYAML(from: [group], options: options, images: &images)
            var name = safeFileName(group.name)
            var suffix = 2
            while usedNames.contains(name) {
                name = "\(safeFileName(group.name))-\(suffix)"
                suffix += 1
            }
            usedNames.insert(name)
            files.append(EspansoDirectoryDocument.MatchFile(fileName: "\(name).yml", contents: contents))
        }
        return EspansoDirectoryDocument(files: files, images: images.files)
    }

    /// One Espanso match file per group, keyed by a safe file name. Useful for writing a whole
    /// `match/` directory instead of a single document. Image bytes are not included; use
    /// `espansoDirectoryDocument` when the export must round-trip images.
    public static func espansoYAMLFiles(
        from groups: [SnippetGroup],
        options: Options = .default
    ) throws -> [(fileName: String, contents: String)] {
        let document = try espansoDirectoryDocument(from: groups, options: options)
        return document.files.map { ($0.fileName, $0.contents) }
    }

    /// True when `path` is a relative `images/<safe file name>` Espanso will accept:
    /// no absolute prefix, no `..`, no backslash, and nothing outside that directory.
    public static func isSafeImageRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.contains(".."),
              !path.contains("\\"),
              !path.contains("\0") else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0] == espansoImageDirectoryName else { return false }
        let name = parts[1]
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix(".") else { return false }
        guard !(name as NSString).pathExtension.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy(isSafeImageFileScalar)
    }

    private static let header = """
    # Exported by DevType. Drop this into your Espanso `match/` directory.
    # DevType macros that Espanso cannot evaluate are left as literal text.

    """

    private static func renderEspansoYAML(
        from groups: [SnippetGroup],
        options: Options,
        images: inout ImageExportPlan
    ) throws -> String {
        var matches: [Node] = []
        for group in groups {
            if !options.includeDisabled && !group.enabled { continue }
            for snippet in group.snippets {
                if !options.includeDisabled && !snippet.enabled { continue }
                guard !snippet.triggerKeyword.isEmpty else { continue }
                matches.append(try matchNode(for: snippet, groupName: group.name, options: options, images: &images))
            }
        }

        let root = Node([(Node("matches"), Node(matches, Tag(.seq)))], Tag(.map))
        do {
            let body = try Yams.serialize(node: root, allowUnicode: true)
            return Self.header + body
        } catch {
            throw ExportError.yamlSerializationFailed(error.localizedDescription)
        }
    }

    private static func matchNode(
        for snippet: SnippetModel,
        groupName: String,
        options: Options,
        images: inout ImageExportPlan
    ) throws -> Node {
        var pairs: [(Node, Node)] = [
            (Node("trigger"), Node(snippet.triggerKeyword)),
        ]

        // `{{cursor}}` is DevType's marker; Espanso spells it `$|$`.
        let replacement = snippet.replacementText.replacingOccurrences(of: "{{cursor}}", with: "$|$")
        pairs.append((Node("replace"), Node(replacement)))

        let label = snippet.label.isEmpty ? snippet.title : snippet.label
        if !label.isEmpty, label != snippet.triggerKeyword {
            pairs.append((Node("label"), Node(label)))
        }
        if snippet.requireWordBoundary {
            pairs.append((Node("word"), Node("true", Tag(.bool))))
        }
        if !snippet.tags.isEmpty {
            pairs.append((Node("search_terms"), Node(snippet.tags.map { Node($0) }, Tag(.seq))))
        }
        if !snippet.includeApps.isEmpty {
            pairs.append((Node("apps"), Node(snippet.includeApps.map { Node($0) }, Tag(.seq))))
        }
        if !snippet.excludeApps.isEmpty {
            pairs.append((Node("exclude_apps"), Node(snippet.excludeApps.map { Node($0) }, Tag(.seq))))
        }
        if snippet.isImageSnippet {
            let path = try images.relativePath(for: snippet, store: options.imageStore)
            guard isSafeImageRelativePath(path) else {
                throw ExportError.imageUnavailable(snippet.triggerKeyword)
            }
            pairs.append((Node("image_path"), Node(path)))
        }
        if !groupName.isEmpty {
            // Espanso ignores unknown keys; keeping the origin group makes a round trip readable.
            pairs.append((Node("devtype_group"), Node(groupName)))
        }
        return Node(pairs, Tag(.map))
    }

    private static func safeFileName(_ name: String) -> String {
        let allowed = name.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let collapsed = String(allowed)
            .components(separatedBy: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return collapsed.isEmpty ? "snippets" : collapsed.lowercased()
    }

    /// Bytes for one exported image, keyed so two snippets that sanitize to the same
    /// name cannot overwrite each other when their bytes differ.
    private struct ImageExportPlan {
        private(set) var files: [EspansoDirectoryDocument.ImageFile] = []
        private var claimed: [String: (relativePath: String, data: Data)] = [:]

        mutating func relativePath(for snippet: SnippetModel, store: ImageAttachmentStore?) throws -> String {
            let trigger = snippet.triggerKeyword
            guard let store,
                  let source = SnippetExporter.containedStoreImageURL(store: store, imagePath: snippet.imagePath) else {
                throw ExportError.imageUnavailable(trigger)
            }
            let prepared: ImageAttachmentStore.PreparedImage
            do {
                prepared = try store.prepareImage(from: source)
            } catch {
                throw ExportError.imageUnavailable(trigger)
            }
            let fileName = SnippetExporter.safeImageFileName(
                storedPath: snippet.imagePath,
                preferredExtension: prepared.preferredExtension
            )
            return try claim(fileName: fileName, data: prepared.data, trigger: trigger)
        }

        mutating func claim(fileName: String, data: Data, trigger: String) throws -> String {
            let stem = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            var name = fileName
            var suffix = 2
            while true {
                if let existing = claimed[name.lowercased()] {
                    if existing.data == data { return existing.relativePath }
                    guard suffix <= 10_000 else { throw ExportError.imageUnavailable(trigger) }
                    name = "\(stem)-\(suffix).\(ext)"
                    suffix += 1
                    continue
                }
                let relative = "\(SnippetExporter.espansoImageDirectoryName)/\(name)"
                guard SnippetExporter.isSafeImageRelativePath(relative) else {
                    throw ExportError.imageUnavailable(trigger)
                }
                claimed[name.lowercased()] = (relative, data)
                files.append(EspansoDirectoryDocument.ImageFile(relativePath: relative, data: data))
                return relative
            }
        }
    }

    /// Last path piece of an attachment name, splitting on both separators so a stored
    /// name cannot carry a directory into the export.
    private static func attachmentLeaf(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
    }

    /// ASCII letters, digits, `.`, `-`, and `_` only. Dots are removed from the stem so
    /// sanitizing cannot produce a `..` component.
    private static func safeImageFileName(storedPath: String, preferredExtension: String) -> String {
        let leaf = attachmentLeaf(storedPath)
        let rawExtension = (leaf as NSString).pathExtension.lowercased()
        let preferred = preferredExtension.lowercased()
        let ext: String
        if ImageAttachmentStore.supportedExtensions.contains(rawExtension) {
            ext = rawExtension
        } else if ImageAttachmentStore.supportedExtensions.contains(preferred) {
            ext = preferred
        } else {
            ext = "png"
        }
        var stem = ""
        for scalar in ((leaf as NSString).deletingPathExtension).unicodeScalars where isSafeImageStemScalar(scalar) {
            stem.unicodeScalars.append(scalar)
        }
        if stem.isEmpty { stem = "image" }
        if stem.count > 80 { stem = String(stem.prefix(80)) }
        return "\(stem).\(ext)"
    }

    private static func isSafeImageStemScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else { return false }
        let value = scalar.value
        let digit = value >= 48 && value <= 57
        let upper = value >= 65 && value <= 90
        let lower = value >= 97 && value <= 122
        return digit || upper || lower || scalar == "-" || scalar == "_"
    }

    private static func isSafeImageFileScalar(_ scalar: Unicode.Scalar) -> Bool {
        isSafeImageStemScalar(scalar) || scalar == "."
    }

    /// File URL strictly inside the image store after symlink resolution.
    /// Absolute paths, `..`, and links that resolve outside the store are `nil`.
    private static func containedStoreImageURL(store: ImageAttachmentStore, imagePath: String) -> URL? {
        guard !imagePath.isEmpty,
              !imagePath.hasPrefix("/"),
              !imagePath.hasPrefix("\\"),
              !imagePath.contains("..") else {
            return nil
        }
        guard let unresolved = store.resolvedURL(forImagePath: imagePath) else { return nil }

        let storeRoot = store.imagesDirectory.standardizedFileURL
        let unresolvedParts = (unresolved.standardizedFileURL.path as NSString).pathComponents
        let storeParts = (storeRoot.path as NSString).pathComponents
        guard unresolvedParts.count > storeParts.count,
              Array(unresolvedParts.prefix(storeParts.count)) == storeParts else {
            return nil
        }

        let root = storeRoot.resolvingSymlinksInPath()
        let resolved = unresolved.resolvingSymlinksInPath()
        let rootParts = (root.path as NSString).pathComponents
        let resolvedParts = (resolved.path as NSString).pathComponents
        guard resolvedParts.count > rootParts.count,
              Array(resolvedParts.prefix(rootParts.count)) == rootParts else {
            return nil
        }

        let values = try? resolved.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values?.isSymbolicLink != true, values?.isRegularFile == true else { return nil }
        return resolved
    }

    // MARK: - CSV

    public static let csvColumns = [
        "group", "trigger", "title", "label", "replacement",
        "caseSensitive", "wordBoundary", "plainText", "enabled",
        "imagePath", "tags", "includeApps", "excludeApps",
        "createdAt", "updatedAt",
    ]

    /// RFC 4180 CSV: CRLF line endings, `"` doubled inside quoted fields.
    public static func csv(from groups: [SnippetGroup], options: Options = .default) -> String {
        let formatter = ISO8601DateFormatter()
        var rows: [String] = [csvRow(csvColumns)]
        for group in groups {
            if !options.includeDisabled && !group.enabled { continue }
            for snippet in group.snippets {
                if !options.includeDisabled && !snippet.enabled { continue }
                rows.append(csvRow([
                    group.name,
                    snippet.triggerKeyword,
                    snippet.title,
                    snippet.label,
                    snippet.replacementText,
                    snippet.isCaseSensitive ? "true" : "false",
                    snippet.requireWordBoundary ? "true" : "false",
                    snippet.isPlainText ? "true" : "false",
                    snippet.enabled ? "true" : "false",
                    snippet.imagePath,
                    snippet.tags.joined(separator: ";"),
                    snippet.includeApps.joined(separator: ";"),
                    snippet.excludeApps.joined(separator: ";"),
                    formatter.string(from: snippet.createdAt),
                    formatter.string(from: snippet.updatedAt),
                ]))
            }
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    private static func csvRow(_ fields: [String]) -> String {
        fields.map(csvField).joined(separator: ",")
    }

    /// Leading characters that spreadsheet applications interpret as the start of
    /// a formula. A CSV field beginning with any of these executes as a formula
    /// when the export is opened in Excel / Numbers / Sheets — classic CSV
    /// injection, turning an innocent data export into code execution on the
    /// reader's machine (e.g. a snippet titled `=cmd|' /C calc'!A0`).
    ///
    /// The standard mitigation is applied: such fields are prefixed with a single
    /// apostrophe, which spreadsheets treat as a "literal text" marker and strip
    /// on display. This happens *before* RFC 4180 quoting so the apostrophe ends
    /// up inside the quoted field. A leading `-` does occur in ordinary prose;
    /// that over-triggering is an accepted tradeoff — safety beats cosmetic
    /// fidelity for an interchange export.
    private static let csvFormulaLeadingCharacters: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    private static func csvField(_ raw: String) -> String {
        var field = raw
        if let first = field.first, csvFormulaLeadingCharacters.contains(first) {
            field = "'" + field
        }
        let needsQuoting = field.contains(",") || field.contains("\"")
            || field.contains("\n") || field.contains("\r")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
