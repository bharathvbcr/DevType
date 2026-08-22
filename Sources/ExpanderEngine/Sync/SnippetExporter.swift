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

        public var errorDescription: String? {
            switch self {
            case .yamlSerializationFailed(let detail): return "Could not write Espanso YAML: \(detail)"
            case .encodingFailed: return "Could not encode the exported snippets as UTF-8."
            }
        }
    }

    /// Options shared by every format.
    public struct Options {
        /// Skip snippets (and groups) that are disabled.
        public var includeDisabled: Bool
        /// Resolve `imagePath` to an absolute file path in the exported document.
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
    public static func espansoYAML(
        from groups: [SnippetGroup],
        options: Options = .default
    ) throws -> String {
        var matches: [Node] = []
        for group in groups {
            if !options.includeDisabled && !group.enabled { continue }
            for snippet in group.snippets {
                if !options.includeDisabled && !snippet.enabled { continue }
                guard !snippet.triggerKeyword.isEmpty else { continue }
                matches.append(matchNode(for: snippet, groupName: group.name, options: options))
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

    /// One Espanso match file per group, keyed by a safe file name. Useful for writing a whole
    /// `match/` directory instead of a single document.
    public static func espansoYAMLFiles(
        from groups: [SnippetGroup],
        options: Options = .default
    ) throws -> [(fileName: String, contents: String)] {
        var files: [(fileName: String, contents: String)] = []
        var usedNames: Set<String> = []
        for group in groups {
            if !options.includeDisabled && !group.enabled { continue }
            let contents = try espansoYAML(from: [group], options: options)
            var name = safeFileName(group.name)
            var suffix = 2
            while usedNames.contains(name) {
                name = "\(safeFileName(group.name))-\(suffix)"
                suffix += 1
            }
            usedNames.insert(name)
            files.append((fileName: "\(name).yml", contents: contents))
        }
        return files
    }

    private static let header = """
    # Exported by DevType. Drop this into your Espanso `match/` directory.
    # DevType macros that Espanso cannot evaluate are left as literal text.

    """

    private static func matchNode(
        for snippet: SnippetModel,
        groupName: String,
        options: Options
    ) -> Node {
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
            let path = options.imageStore?.resolvedURL(forImagePath: snippet.imagePath)?.path
                ?? snippet.imagePath
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
