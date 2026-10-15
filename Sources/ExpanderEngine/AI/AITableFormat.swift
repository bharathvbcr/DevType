import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Turns a column-and-row table into the Markdown the preview inserts.
///
/// The model is asked for this shape through `DynamicGenerationSchema` on macOS 26
/// and later. Rendering lives here, outside that call, so a cell can never carry a
/// broken fence or a raw JSON object into the focused field — and so the Markdown
/// rules are testable on the macOS 14–25 toolchain, where the schema type does not
/// exist. The schema builder itself is compiled only where Foundation Models is.
public enum AITableFormat {
    /// Wide enough for the records people paste into a palette, narrow enough that a
    /// model cannot emit a spreadsheet. The schema states the same caps.
    public static let maximumColumns = 8
    public static let maximumRows = 40
    /// A cell is one fact, not the selection copied back. Longer text is cut.
    public static let maximumCellCharacters = 500

    /// A GitHub-flavored Markdown table, or `nil` when there is nothing to show.
    ///
    /// `nil` is a failed format, not an empty table: the caller refuses to replace
    /// the selection with a header and no rows. Short rows are padded, long rows
    /// are cut to the header width, and `|` or a line break inside a cell is made
    /// safe so it cannot open a new column or a new row.
    public static func markdown(columns: [String], rows: [[String]]) -> String? {
        let headers = Array(columns.prefix(maximumColumns)).map(cell)
        guard !headers.isEmpty, headers.contains(where: { !$0.isEmpty }) else { return nil }
        let width = headers.count
        let body = rows.prefix(maximumRows).map { row -> [String] in
            var cells = row.prefix(width).map(cell)
            if cells.count < width {
                cells.append(contentsOf: repeatElement("", count: width - cells.count))
            }
            return cells
        }
        guard !body.isEmpty else { return nil }

        func line(_ cells: [String]) -> String {
            "| " + cells.joined(separator: " | ") + " |"
        }
        let rule = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"
        return ([line(headers), rule] + body.map(line)).joined(separator: "\n")
    }

    /// One cell, safe to sit between pipes.
    static func cell(_ raw: String) -> String {
        var text = ""
        text.reserveCapacity(min(raw.count, maximumCellCharacters))
        for character in raw {
            if text.count >= maximumCellCharacters {
                text.append("\u{2026}")
                break
            }
            if character.isNewline || character == "\r" {
                text.append(" ")
            } else if character == "|" {
                text.append("\\|")
            } else {
                text.append(character)
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    #if canImport(FoundationModels)
    /// The guided-generation schema for `AITransformKind.toTable`.
    ///
    /// Confirmed against the macOS SDK's `FoundationModels.swiftinterface`:
    /// `DynamicGenerationSchema.init(name:description:properties:)`,
    /// `DynamicGenerationSchema.init(arrayOf:minimumElements:maximumElements:)`,
    /// `DynamicGenerationSchema.init(type:guides:)`,
    /// `DynamicGenerationSchema.Property.init(name:description:schema:isOptional:)`,
    /// and `GenerationSchema.init(root:dependencies:)`.
    ///
    /// This function is the whole use of that API. It is not compiled into a
    /// toolchain that cannot import Foundation Models — the macOS 14 CI job —
    /// and `markdown(columns:rows:)` above is what that job still builds and tests.
    @available(macOS 26.0, *)
    public static func generationSchema() throws -> GenerationSchema {
        let cellSchema = DynamicGenerationSchema(type: String.self)
        let columns = DynamicGenerationSchema(
            arrayOf: cellSchema,
            minimumElements: 1,
            maximumElements: maximumColumns
        )
        let row = DynamicGenerationSchema(
            arrayOf: cellSchema,
            minimumElements: 1,
            maximumElements: maximumColumns
        )
        let rows = DynamicGenerationSchema(
            arrayOf: row,
            minimumElements: 1,
            maximumElements: maximumRows
        )
        let root = DynamicGenerationSchema(
            name: "FormattedTable",
            description: "A table whose cells are taken from the user's text.",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "columns",
                    description: "Header labels, left to right. One short name per column.",
                    schema: columns
                ),
                DynamicGenerationSchema.Property(
                    name: "rows",
                    description: "One row per record. Each row is one string per column, in the same order. Use an empty string for a missing cell.",
                    schema: rows
                ),
            ]
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// Markdown for a guided-generation result, or `nil` when the content is not
    /// the table schema yet. Partials fail this until both properties decode.
    @available(macOS 26.0, *)
    public static func markdown(from content: GeneratedContent) -> String? {
        guard let columns = try? content.value([String].self, forProperty: "columns"),
              let rows = try? content.value([[String]].self, forProperty: "rows") else {
            return nil
        }
        return markdown(columns: columns, rows: rows)
    }
    #endif
}
