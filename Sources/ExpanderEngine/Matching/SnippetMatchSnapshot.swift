import Foundation

/// §2.1 / §2.4: Immutable `(snippets, matcher)` pair published as a single reference.
///
/// The event-tap callback used to build a fresh `AbbreviationMatcher` on **every keystroke**
/// (~2000 dictionary inserts + ~1000 string allocations per typed character at 1000 snippets,
/// inside a CGEventTap callback that macOS disables when it runs long).
///
/// The matcher is already an immutable value type, so the whole thing is built once in the
/// `snippets` setter and swapped in as a single class reference. The callback then only has to
/// copy one pointer out from under a tiny `os_unfair_lock` instead of holding a lock across a
/// full rebuild.
public final class SnippetMatchSnapshot {
    public let snippets: [SnippetModel]
    public let matcher: AbbreviationMatcher
    /// Monotonic revision so observers can detect a swap without comparing arrays.
    public let revision: UInt64

    public init(snippets: [SnippetModel], revision: UInt64 = 0) {
        self.snippets = snippets
        self.matcher = AbbreviationMatcher(snippets: snippets)
        self.revision = revision
    }

    public static let empty = SnippetMatchSnapshot(snippets: [])
}
