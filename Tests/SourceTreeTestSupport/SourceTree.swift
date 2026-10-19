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
}
