import XCTest

@testable import ExpanderEngine

/// The macro reference is a declaration layer, and nothing was checking it.
///
/// `docs/MACRO_REFERENCE.md` is the page a reader consults before typing a
/// macro into a snippet. Every token in its tables is a promise that the
/// engine understands that token — and a promise nothing tested. A macro the
/// engine does not know is not an error: `MacroParser` leaves it alone, so the
/// snippet expands to the macro's own source, verbatim, in whatever the reader
/// was typing into. Documented-but-unimplemented therefore fails silently, at
/// the keyboard, in someone else's app.
///
/// This file is the fix, and it is deliberately behavioural rather than
/// textual. It does not grep the sources for a keyword — it runs every token
/// the document tabulates through `MacroRenderer.expand` and asserts the engine
/// did *something* with it. A grep would pass on a token that appears in a
/// comment; only expansion answers the question a reader actually has.
///
/// `MacroCatalog.swift` already documents the same failure one layer over:
/// "Every macro the engine gained after that menu was written … was invisible
/// in the UI and therefore a dead feature. Nothing tied the menu to the parser,
/// so the two drifted silently." The menu is tied to the parser now. The
/// reference was the third copy of that list, and it was still loose.
final class MacroReferenceContractTests: XCTestCase {

    /// The repository root, from this file's location.
    ///
    /// Deliberately derived from `#filePath` rather than from the working
    /// directory: `swift test` and Xcode disagree about the latter, and a guard
    /// that silently reads nothing is the failure this file exists to prevent.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ExpanderEngineTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private func read(_ relative: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Tokens tabulated in the reference, taken from the first column of every
    /// table row that begins with a backticked value.
    ///
    /// Reading the tables rather than the prose is load-bearing. A first pass
    /// scanned the whole document for `%…%` and `{{…}}` runs and immediately
    /// produced a false finding: the escaping section contains the example
    /// output `50%off`, whose `%off` is not a macro at all but the literal a
    /// reader sees after `%%` collapses. Prose about macros is not a list of
    /// them.
    private func documentedTokens() throws -> [String] {
        let body = try read("docs/MACRO_REFERENCE.md")
        var tokens: [String] = []

        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("| `") else { continue }
            // First cell: | `token` | … |
            let cells = trimmed.split(separator: "|", omittingEmptySubsequences: false)
            guard cells.count > 1 else { continue }
            let cell = cells[1].trimmingCharacters(in: .whitespaces)
            guard cell.hasPrefix("`"), cell.hasSuffix("`"), cell.count > 2 else { continue }
            let token = String(cell.dropFirst().dropLast())
            guard token.hasPrefix("{{") || token.hasPrefix("%") else { continue }
            tokens.append(token)
        }
        return tokens
    }

    /// Every token the reference tabulates must be one the engine acts on.
    func testEveryDocumentedMacroExpands() throws {
        let tokens = try documentedTokens()
        XCTAssertGreaterThanOrEqual(
            tokens.count, 30,
            "only \(tokens.count) tokens read out of docs/MACRO_REFERENCE.md; "
                + "the tables were restructured and this guard is no longer reading them")

        // A fixed instant, so a date macro's output is deterministic and a
        // failure here is never a clock.
        let now = Date(timeIntervalSince1970: 1_755_300_000)
        var inert: [String] = []

        for token in tokens {
            let result = MacroRenderer.expand(
                content: token,
                lookup: { _ in "nested" },
                clipboardText: "CLIPBOARD",
                now: now)

            // Four ways the engine can demonstrate it understood the token.
            let rewritten = result.text != token
            let asksTheUser = !result.fillFields.isEmpty || result.needsFillIn
            let placesTheCaret = result.cursorOffset != nil
            let sendsAKey = !result.trailingKeys.isEmpty

            if !(rewritten || asksTheUser || placesTheCaret || sendsAKey) {
                inert.append(token)
            }
        }

        XCTAssertTrue(
            inert.isEmpty,
            "docs/MACRO_REFERENCE.md documents \(inert.count) macro(s) the engine "
                + "does nothing with — a snippet using one expands to its own source, "
                + "in the reader's app: \(inert.joined(separator: ", "))")
    }

    /// The date presets the reference names must be presets the library has.
    ///
    /// `{{date:iso}}` and `%date:us%` name entries in `DateFormatLibrary.presets`
    /// by id. A preset renamed there leaves the documented spelling parsing as
    /// a *format pattern* instead — which does not fail, it silently produces
    /// gibberish built from the letters of the name.
    func testEveryDocumentedDatePresetExists() throws {
        let known = Set(DateFormatLibrary.presets.map(\.id))
        XCTAssertFalse(known.isEmpty, "the preset table is empty; this check examined nothing")

        let tokens = try documentedTokens()
        var missing: [String] = []
        var checked = 0

        for token in tokens {
            // `{{date:iso}}`, `{{date:iso:+1d}}`, `%date:us%`
            guard let spec = datePresetSpec(in: token) else { continue }
            // A spec is either a preset id or a raw format pattern; only an
            // all-lowercase-letters spec can be a preset name, and a pattern
            // like `yyyy-MM-dd` carries separators or capitals.
            guard spec.allSatisfy({ $0.isLowercase && $0.isLetter }) else { continue }
            checked += 1
            if !known.contains(spec) { missing.append(token) }
        }

        XCTAssertGreaterThan(
            checked, 0,
            "no date presets found in the reference; this check examined nothing")
        XCTAssertTrue(
            missing.isEmpty,
            "documented date presets that DateFormatLibrary does not define — these "
                + "silently render as format patterns rather than failing: "
                + missing.joined(separator: ", "))
    }

    /// Pull the preset portion out of a documented date token, or nil.
    private func datePresetSpec(in token: String) -> String? {
        var body: String
        if token.hasPrefix("{{date:"), token.hasSuffix("}}") {
            body = String(token.dropFirst("{{date:".count).dropLast(2))
        } else if token.hasPrefix("%date:"), token.hasSuffix("%") {
            body = String(token.dropFirst("%date:".count).dropLast())
        } else {
            return nil
        }
        // `iso:+1d` is preset + offset; the offset is not a preset name.
        if let colon = body.firstIndex(of: ":") {
            body = String(body[body.startIndex..<colon])
        }
        return body.isEmpty ? nil : body
    }

    /// The reference's table of contents must point at headings that exist.
    ///
    /// Its entries are anchor links, and an anchor that no longer matches lands
    /// the reader at the top of a long document with no indication anything
    /// went wrong.
    func testTableOfContentsAnchorsResolve() throws {
        let body = try read("docs/MACRO_REFERENCE.md")

        // GitHub's slug rule, for the headings this document actually uses.
        var anchors = Set<String>()
        for line in body.split(separator: "\n") {
            guard line.hasPrefix("#") else { continue }
            let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            anchors.insert(slug(text))
        }
        XCTAssertFalse(anchors.isEmpty, "no headings found; this check examined nothing")

        var broken: [String] = []
        var checked = 0
        for match in body.ranges(ofPattern: "](#") {
            let after = body[match.upperBound...]
            guard let close = after.firstIndex(of: ")") else { continue }
            let anchor = String(after[after.startIndex..<close])
            guard !anchor.isEmpty else { continue }
            checked += 1
            if !anchors.contains(anchor) { broken.append("#\(anchor)") }
        }

        XCTAssertGreaterThan(checked, 0, "no anchor links found; this check examined nothing")
        XCTAssertTrue(
            broken.isEmpty,
            "table-of-contents links that match no heading: \(broken.joined(separator: ", "))")
    }

    /// GitHub's heading-slug rule: lowercase, spaces to hyphens, drop anything
    /// that is not a letter, number, hyphen or underscore.
    private func slug(_ heading: String) -> String {
        var out = ""
        for ch in heading.lowercased() {
            if ch == " " {
                out.append("-")
            } else if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                out.append(ch)
            }
        }
        return out
    }

    /// Relative links across the documentation must resolve.
    func testEveryRelativeDocLinkResolves() throws {
        let fm = FileManager.default
        var docs = ["README.md"]
        let docsDir = repoRoot.appendingPathComponent("docs")
        for name in (try? fm.contentsOfDirectory(atPath: docsDir.path)) ?? [] where name.hasSuffix(".md") {
            docs.append("docs/\(name)")
        }
        XCTAssertGreaterThanOrEqual(docs.count, 4, "only \(docs.count) documents found")

        var broken: [String] = []
        var checked = 0

        for doc in docs {
            let body = try read(doc)
            let base = repoRoot.appendingPathComponent(doc).deletingLastPathComponent()
            for range in body.ranges(ofPattern: "](") {
                let after = body[range.upperBound...]
                guard let close = after.firstIndex(of: ")") else { continue }
                let raw = String(after[after.startIndex..<close])
                let target = raw.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
                // Compare the scalar, not the Character. A heading written with
                // a keycap emoji slugs to an anchor whose first grapheme cluster
                // is `#` joined to U+FE0F, so `hasPrefix("#")` is *false* for it
                // and the anchor gets treated as a relative path that of course
                // does not exist. This check reported exactly that as a broken
                // link on its first run: the link was fine and the guard was not.
                if raw.unicodeScalars.first == "#" { continue }
                if target.isEmpty || target.hasPrefix("http://") || target.hasPrefix("https://")
                    || target.hasPrefix("mailto:")
                {
                    continue
                }
                checked += 1
                if !fm.fileExists(atPath: base.appendingPathComponent(target).path) {
                    broken.append("\(doc): \(raw)")
                }
            }
        }

        XCTAssertGreaterThan(checked, 0, "no relative links checked; this guard is not reading the docs")
        XCTAssertTrue(broken.isEmpty, "links that point at nothing: \(broken.joined(separator: ", "))")
    }
}

extension String {
    /// Every range at which `pattern` occurs. Small helper so these checks add
    /// no dependency and no regex.
    fileprivate func ranges(ofPattern pattern: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var search = startIndex..<endIndex
        while let found = range(of: pattern, range: search) {
            out.append(found)
            search = found.upperBound..<endIndex
        }
        return out
    }
}
