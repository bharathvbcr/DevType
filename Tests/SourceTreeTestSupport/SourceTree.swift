import Foundation

/// The one reader every source-contract test uses to look at `Sources/`.
///
/// A source contract is a statement about a *type*, not about the file that happens to hold it, so
/// `Dir/Type.swift` is read together with every `Dir/Type+*.swift` in the same directory. That way a
/// pure-move split of a large type into `Type+Role.swift` extensions neither breaks a "must contain"
/// check nor, worse, silently satisfies a "must not contain" check by hiding code from it. `Type.swift`
/// comes first, its siblings follow in name order, and `TypeOther.swift` (no `+`) is a different type
/// and is never included.
///
/// A missing primary file throws; the reader never returns an empty result. Test targets cannot share
/// a source file, so this lives in its own library target that both source-reading test bundles import.
public enum SourceTree {
    /// A source file the contract names could not be found.
    public struct MissingSourceError: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "source contract file not found: \(path)" }
    }

    /// The repository root, derived from this file's location (`Tests/SourceTreeTestSupport/`).
    public static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The primary file at `relativePath` followed by its `Type+*.swift` siblings, sorted by name.
    /// `base` exists so the reader itself can be tested against a temporary tree.
    public static func files(_ relativePath: String, in base: URL = SourceTree.root) throws -> [URL] {
        let primary = base.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: primary.path) else {
            throw MissingSourceError(path: primary.path)
        }
        let directory = primary.deletingLastPathComponent()
        let stem = primary.deletingPathExtension().lastPathComponent
        let siblings = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(stem + "+") && $0.pathExtension == primary.pathExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return [primary] + siblings
    }

    /// The path a `Type+Role.swift` file reports as: `Type.swift` in the same directory when that
    /// primary exists, otherwise `relativePath` unchanged (an extension of a type declared elsewhere,
    /// such as `NSView+Foo.swift`, is its own owner). Tests that assert a token lives "only in file X"
    /// attribute each hit through this, so X's whole family counts as X.
    public static func familyPrimary(of relativePath: String, in base: URL = SourceTree.root) -> String {
        let name = (relativePath as NSString).lastPathComponent
        guard name.hasSuffix(".swift"), let plus = name.firstIndex(of: "+"), plus != name.startIndex else {
            return relativePath
        }
        let directory = (relativePath as NSString).deletingLastPathComponent
        let primaryName = String(name[..<plus]) + ".swift"
        let primary = directory.isEmpty ? primaryName : directory + "/" + primaryName
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(primary).path) ? primary : relativePath
    }

    /// The contents of `files(relativePath)` joined with a newline.
    public static func text(_ relativePath: String, in base: URL = SourceTree.root) throws -> String {
        try files(relativePath, in: base)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// `relativePath`'s family followed by the family of each file in `movedTypes` (paths relative to
    /// the repository root, or to `base`).
    ///
    /// A split can move a top-level type out of the primary file into a file of its own
    /// (`SnippetSortMode.swift`, not `SnippetManagerViewController+SortMode.swift`), which
    /// `text(_:)` rightly does not read: it is a different type. A contract that was about the
    /// whole pre-split file, above all a "must not contain" check, names those files here so it
    /// keeps covering the code it covered before. A missing file throws.
    public static func text(
        _ relativePath: String, including movedTypes: [String], in base: URL = SourceTree.root
    ) throws -> String {
        try ([relativePath] + movedTypes)
            .map { try text($0, in: base) }
            .joined(separator: "\n")
    }

    // MARK: - Function bodies

    /// Why `functionBody` could not hand back a body. Every case is loud: a locator that cannot
    /// find exactly one balanced body must fail the test, never return a guess.
    public enum FunctionBodyError: Error, CustomStringConvertible {
        case missing(signature: String)
        case ambiguous(signature: String, count: Int)
        case noBody(signature: String)
        case unbalanced(signature: String)

        public var description: String {
            switch self {
            case .missing(let signature): return "no declaration contains `\(signature)`"
            case .ambiguous(let signature, let count):
                return "`\(signature)` occurs \(count) times; anchor on a longer signature fragment"
            case .noBody(let signature): return "`\(signature)` is declared without a `{ ... }` body"
            case .unbalanced(let signature): return "the body that follows `\(signature)` never closes"
            }
        }
    }

    /// The declaration that starts at `signature`, from the first character of the match through
    /// the `}` that closes its body, found by brace matching.
    ///
    /// This is how a contract names "this function's body". It replaces two-marker slices
    /// (`range(of: "func A(")` to `range(of: "func B(")`), which only mean "A's body" while B is the
    /// next declaration in the same file: once A and B live in different `Type+Role.swift` files the
    /// slice is empty or inverted. Anchor on `func name(` without an access modifier so a member
    /// widened from `private` to internal by a split still matches.
    ///
    /// `signature` must occur exactly once in `text`, so a shorter anchor can never silently bind to a
    /// namesake. Braces inside string literals (including interpolations, raw and multi-line strings)
    /// and inside comments do not count. A parenthesised default argument may contain braces.
    public static func functionBody(_ signature: String, in text: String) throws -> String {
        var matches: [Range<String.Index>] = []
        var from = text.startIndex
        while let found = text.range(of: signature, range: from..<text.endIndex) {
            matches.append(found)
            from = found.upperBound
        }
        guard let first = matches.first else { throw FunctionBodyError.missing(signature: signature) }
        guard matches.count == 1 else {
            throw FunctionBodyError.ambiguous(signature: signature, count: matches.count)
        }

        let scalars = Array(text.unicodeScalars)
        let start = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: first.lowerBound)
        var i = start
        var parens = 0
        var open: Int?
        while i < scalars.count {
            if skipTrivia(scalars, &i) { continue }
            switch scalars[i] {
            case "(": parens += 1
            case ")": parens -= 1
            case "{" where parens <= 0: open = i
            case "}" where parens <= 0: throw FunctionBodyError.noBody(signature: signature)
            default: break
            }
            if open != nil { break }
            i += 1
        }
        guard var cursor = open else { throw FunctionBodyError.noBody(signature: signature) }

        var depth = 0
        while cursor < scalars.count {
            if skipTrivia(scalars, &cursor) { continue }
            if scalars[cursor] == "{" { depth += 1 }
            if scalars[cursor] == "}" {
                depth -= 1
                if depth == 0 {
                    var view = String.UnicodeScalarView()
                    view.append(contentsOf: scalars[start...cursor])
                    return String(view)
                }
            }
            cursor += 1
        }
        throw FunctionBodyError.unbalanced(signature: signature)
    }

    /// Advances `i` past a comment or string literal that starts there, and reports whether it did.
    /// Anything else leaves `i` alone.
    private static func skipTrivia(_ s: [Unicode.Scalar], _ i: inout Int) -> Bool {
        guard i < s.count else { return false }
        if s[i] == "/", i + 1 < s.count {
            if s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
                return true
            }
            if s[i + 1] == "*" {
                var nesting = 0
                while i < s.count {
                    if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" {
                        nesting += 1
                        i += 2
                    } else if s[i] == "*", i + 1 < s.count, s[i + 1] == "/" {
                        nesting -= 1
                        i += 2
                        if nesting == 0 { break }
                    } else {
                        i += 1
                    }
                }
                return true
            }
        }
        var hashes = 0
        var quote = i
        while quote < s.count, s[quote] == "#" { hashes += 1; quote += 1 }
        guard quote < s.count, s[quote] == "\"" else { return false }
        let multiline = quote + 2 < s.count && s[quote + 1] == "\"" && s[quote + 2] == "\""
        let quotes = multiline ? 3 : 1
        var k = quote + quotes
        while k < s.count {
            if s[k] == "\\", hasHashes(s, k + 1, hashes) {
                let escaped = k + 1 + hashes
                if escaped < s.count, s[escaped] == "(" {
                    k = escaped + 1
                    var parens = 1
                    while k < s.count, parens > 0 {
                        if skipTrivia(s, &k) { continue }
                        if s[k] == "(" { parens += 1 }
                        if s[k] == ")" { parens -= 1 }
                        k += 1
                    }
                } else {
                    k = escaped + 1
                }
                continue
            }
            if s[k] == "\"", (1..<quotes).allSatisfy({ k + $0 < s.count && s[k + $0] == "\"" }),
               hasHashes(s, k + quotes, hashes) {
                i = k + quotes + hashes
                return true
            }
            k += 1
        }
        i = s.count
        return true
    }

    private static func hasHashes(_ s: [Unicode.Scalar], _ at: Int, _ count: Int) -> Bool {
        count == 0 || (at + count <= s.count && (0..<count).allSatisfy { s[at + $0] == "#" })
    }
}
