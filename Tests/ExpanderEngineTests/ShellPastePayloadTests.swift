import XCTest
@testable import ExpanderEngine

/// The payload contract: **DevType delivers the snippet text and nothing else.**
///
/// The bug this pins down: bracketed-paste markers were baked into the pasteboard payload for any
/// shell-like host. Bracketed paste is a terminal→pty protocol, not clipboard content — when the
/// shell enables mode 2004 the *terminal emulator* wraps whatever is pasted, at paste time. Every
/// DevType expansion is delivered with a synthetic ⌘V, so those markers landed **inside** the
/// terminal's own wrapper and zsh inserted them as literal text: the reported
/// `[200~/Users/bharath/Code [201~` on a cmux command line. Verified against the shipping
/// binaries — both `cmux` and `Terminal.app` emit the wrapper themselves. A host that does *not*
/// implement bracketed paste receives the same visible garbage, and the pasted newline the markers
/// were meant to neutralise executes either way. There was no receiver for which wrapping was
/// correct.
///
/// Three fences here, because the defect could return in three different shapes:
///  1. `testShippedSourcesNeverSynthesiseBracketedPasteMarkers` — nobody re-adds the wrap.
///  2. `testTerminalsNeverTakeAnAXWritePath` — terminals keep reaching the clipboard path at all.
///  3. `testExpansionNeverIntroducesControlCharacters` — no *other* control sequence sneaks into a
///     payload by a different route.
final class ShellPastePayloadTests: XCTestCase {

    // MARK: - 1. No marker may be synthesised in shipped code

    /// Marker bodies as they are *spelled in Swift source*. `\u{1B}[200~`, `\033[200~`, `\e[200~`
    /// and a raw ESC byte all share these tails, so matching the tail alone catches every spelling
    /// without enumerating escapes.
    static let markerBodies = ["200~", "201~"]

    /// 1-indexed line numbers in `source` where a marker appears in **code** (comments excluded).
    ///
    /// Comment stripping can only ever *shorten* the text being searched, so it cannot invent an
    /// offender — the failure mode it risks is the opposite one, a fence that silently searches
    /// nothing. `testScannerFlagsRealCode` and the corpus-size assertions below are what keep this
    /// honest. Known blind spot: a marker sitting after a `//` inside a string literal, which no
    /// payload construction looks like.
    static func markerLines(in source: String) -> [Int] {
        let withoutBlockComments = strippingBlockComments(source)
        var hits: [Int] = []
        for (index, line) in withoutBlockComments
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            let code = strippingLineComment(String(line))
            if markerBodies.contains(where: code.contains) {
                hits.append(index + 1)
            }
        }
        return hits
    }

    static func strippingLineComment(_ line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<range.lowerBound])
    }

    /// Replaces `/* … */` spans with newlines so line numbers survive the strip.
    static func strippingBlockComments(_ source: String) -> String {
        guard source.contains("/*") else { return source }
        var output = ""
        var remainder = Substring(source)
        while let open = remainder.range(of: "/*") {
            output += remainder[remainder.startIndex..<open.lowerBound]
            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.range(of: "*/") else {
                // Unterminated: drop the rest, preserving its line count.
                output += String(repeating: "\n", count: afterOpen.filter { $0 == "\n" }.count)
                return output
            }
            let comment = afterOpen[afterOpen.startIndex..<close.lowerBound]
            output += String(repeating: "\n", count: comment.filter { $0 == "\n" }.count)
            remainder = afterOpen[close.upperBound...]
        }
        return output + remainder
    }

    func testShippedSourcesNeverSynthesiseBracketedPasteMarkers() throws {
        var offenders: [String] = []
        var filesScanned = 0
        var codeLinesScanned = 0

        for file in try shippedSourceFiles() {
            filesScanned += 1
            let contents = try String(contentsOf: file, encoding: .utf8)
            codeLinesScanned += contents.split(separator: "\n", omittingEmptySubsequences: false).count
            for line in Self.markerLines(in: contents) {
                offenders.append("\(file.lastPathComponent):\(line)")
            }
        }

        // Vacuity guards: a stripping or enumeration bug must fail loudly, not pass by scanning
        // an empty corpus. Floors are set well under the real counts so ordinary churn never
        // trips them.
        XCTAssertGreaterThan(filesScanned, 40, "Scanned too few files — the fence went vacuous")
        XCTAssertGreaterThan(codeLinesScanned, 5_000, "Scanned too few lines — the fence went vacuous")

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Bracketed-paste markers are being synthesised again. The terminal emits these itself \
            when the shell enables mode 2004; ours land inside its wrapper and reach the command \
            line as literal text. Offending lines: \(offenders.joined(separator: ", "))
            """
        )
    }

    /// Positive control: proves the scanner can still fail. Without this, a stripping bug would
    /// turn the fence above into a test that passes no matter what ships.
    func testScannerFlagsRealCode() {
        let marker = "\u{1B}[" + "200~"
        XCTAssertEqual(Self.markerLines(in: "let payload = \"\(marker)\" + text"), [1])
        XCTAssertEqual(Self.markerLines(in: "let a = 1\nlet b = \"\(marker)\"\nlet c = 3"), [2])
        XCTAssertEqual(Self.markerLines(in: "let end = \"\u{1B}[" + "201~\""), [1])
    }

    func testScannerIgnoresProseAboutTheBug() {
        let marker = "\u{1B}[" + "200~"
        XCTAssertEqual(Self.markerLines(in: "// the host echoed \(marker) back"), [])
        XCTAssertEqual(Self.markerLines(in: "/// doc: never emit \(marker)"), [])
        XCTAssertEqual(Self.markerLines(in: "/* block\n   about \(marker)\n */"), [])
        XCTAssertEqual(Self.markerLines(in: "let x = 1 // trailing \(marker)"), [])
    }

    func testBlockCommentStrippingPreservesLineNumbers() {
        let marker = "\u{1B}[" + "200~"
        // Marker on line 4, block comment spanning lines 1-3.
        XCTAssertEqual(Self.markerLines(in: "/* a\n b\n */\nlet x = \"\(marker)\""), [4])
        // Unterminated block comment must not swallow a later line into a false negative *and*
        // must not crash.
        XCTAssertEqual(Self.markerLines(in: "/* unterminated\nlet x = \"\(marker)\""), [])
    }

    // MARK: - 2. Terminals are clipboard-only

    /// The payload is only safe because terminals reach the clipboard path. Both AX write sites
    /// share this predicate; before, the rule lived twice as a bare `!a && !b` in control flow
    /// where it could drift.
    func testTerminalsNeverTakeAnAXWritePath() {
        XCTAssertFalse(TextInjectionPipeline.mayWriteViaAX(shellLike: true, preferHID: false))
        XCTAssertFalse(TextInjectionPipeline.mayWriteViaAX(shellLike: true, preferHID: true))
    }

    func testCondemnedHostsNeverTakeAnAXWritePath() {
        XCTAssertFalse(TextInjectionPipeline.mayWriteViaAX(shellLike: false, preferHID: true))
    }

    func testHealthyNonShellHostKeepsTheAXWritePath() {
        XCTAssertTrue(TextInjectionPipeline.mayWriteViaAX(shellLike: false, preferHID: false))
    }

    /// Every terminal DevType knows about must resolve as shell-like, or it silently regains the
    /// AX write path. cmux is the host that reported the bug.
    func testKnownTerminalsAreRecognised() {
        let checker = AXContextChecker()
        for bundleID in [
            "com.cmuxterm.app",
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty",
            "io.alacritty",
            "com.github.wez.wezterm",
            "dev.warp.Warp-Stable",
            "co.zeit.hyper",
        ] {
            XCTAssertTrue(checker.isTerminalBundleID(bundleID), "\(bundleID) lost terminal status")
            XCTAssertFalse(checker.isIDEBundleID(bundleID), "\(bundleID) misclassified as an IDE")
        }
    }

    // MARK: - 3. Expansion introduces no control characters of its own

    private static func controlScalars(_ text: String) -> Set<Unicode.Scalar> {
        Set(text.unicodeScalars.filter { $0.value < 0x20 || $0.value == 0x7F })
    }

    /// The general form of the defect: a payload carrying a control character the user never
    /// authored. Fuzzes the macro renderer and asserts the control characters in the expansion are
    /// a subset of those in its inputs.
    func testExpansionNeverIntroducesControlCharacters() {
        // Several fixed seeds rather than one: a single stream can miss a fragment ordering, and
        // fixed constants keep every failure reproducible from the seed printed below.
        for seed in [0xD3F7_1E55_0BAD_C0DE, 0x0000_0000_0000_0001, 0xFFFF_FFFF_FFFF_FFFF,
                     0x5DEE_CE66_D3F1_A2B4, 0xA5A5_A5A5_A5A5_A5A5] as [UInt64] {
            fuzzExpansionForControlCharacters(seed: seed)
        }
    }

    private func fuzzExpansionForControlCharacters(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let fragments = [
            "hello", "cd ", "/Users/bharath/Code", "héllo", "日本語", "🎉", "a b\tc",
            "line1\nline2", "\r\n", "{{date}}", "{{time}}", "{{uuid}}", "{{clipboard}}",
            "{{cursor}}", "{{calc:1+1}}", "{{random}}", "{{counter}}", "echo 'hi'", "%|",
            "{{date:yyyy-MM-dd}}", "", "  ", "$(whoami)", "`id`", "&& rm -rf /tmp/x",
        ]
        let clipboards = ["plain", "with\nnewline", "with\ttab", "", "🎉 emoji", "a\u{7F}b"]
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

        for iteration in 0..<3_000 {
            let count = Int.random(in: 0...6, using: &rng)
            let content = (0..<count)
                .map { _ in fragments.randomElement(using: &rng)! }
                .joined()
            let clipboard = clipboards.randomElement(using: &rng)!

            let result = MacroRenderer.expand(
                content: content,
                fillValues: [:],
                lookup: { _ in nil },
                clipboardText: clipboard,
                now: fixedNow
            )

            let introduced = Self.controlScalars(result.text)
                .subtracting(Self.controlScalars(content))
                .subtracting(Self.controlScalars(clipboard))
            XCTAssertTrue(
                introduced.isEmpty,
                """
                seed \(String(format: "0x%016llX", seed)) iteration \(iteration): \
                expansion introduced control scalars \
                \(introduced.map { String(format: "U+%04X", $0.value) }.sorted()) \
                that neither the snippet nor the clipboard contained. \
                content=\(content.debugDescription) clipboard=\(clipboard.debugDescription)
                """
            )
        }
    }

    /// Long payloads take different paths through the renderer and the pasteboard timing formulas
    /// (`restoreDelay` scales with byte count) — an escape injected only on the large-payload path
    /// would be invisible to the corpus above.
    func testLargeAndPathologicalPayloadsStayClean() {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let cases = [
            String(repeating: "a", count: 100_000),
            String(repeating: "{{date}} ", count: 2_000),
            String(repeating: "🎉", count: 20_000),
            String(repeating: "line\n", count: 10_000),
            String(repeating: "{{clipboard}}", count: 500),
        ]
        for content in cases {
            let result = MacroRenderer.expand(
                content: content,
                fillValues: [:],
                lookup: { _ in nil },
                clipboardText: "clip",
                now: fixedNow
            )
            let introduced = Self.controlScalars(result.text)
                .subtracting(Self.controlScalars(content))
            XCTAssertTrue(
                introduced.isEmpty,
                "large payload introduced \(introduced) (content prefix: \(content.prefix(24)))"
            )
        }
    }

    // MARK: - Helpers

    private func shippedSourceFiles() throws -> [URL] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ExpanderEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            XCTFail("Cannot enumerate \(sources.path)")
            return []
        }
        // Every language that ships in the app bundle, not just Swift — DevTypeSafety is ObjC.
        let extensions: Set<String> = ["swift", "m", "h"]
        return walker
            .compactMap { $0 as? URL }
            .filter { extensions.contains($0.pathExtension) }
    }
}
