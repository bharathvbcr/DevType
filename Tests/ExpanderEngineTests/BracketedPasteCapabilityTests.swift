import XCTest
@testable import ExpanderEngine

/// §3.10 — bracketed paste used to be unconditional for anything "shell-like", so a plain `cat`,
/// a `read -p`, an old SSH host, or a REPL without bracketed-paste support received `ESC[200~`
/// as visible garbage. The store learns from evidence; the marker detector is what produces it.
final class BracketedPasteCapabilityTests: XCTestCase {

    private let start = BracketedPasteCapabilityStore.bracketStart
    private let end = BracketedPasteCapabilityStore.bracketEnd

    // MARK: - containsLiteralBracketMarkers

    func testCleanTextHasNoMarkers() {
        XCTAssertFalse(BracketedPasteCapabilityStore.containsLiteralBracketMarkers(""))
        XCTAssertFalse(BracketedPasteCapabilityStore.containsLiteralBracketMarkers("git status"))
        XCTAssertFalse(BracketedPasteCapabilityStore.containsLiteralBracketMarkers("echo 'hello'\n"))
    }

    func testDetectsStartMarker() {
        XCTAssertTrue(BracketedPasteCapabilityStore.containsLiteralBracketMarkers(start))
        XCTAssertTrue(BracketedPasteCapabilityStore.containsLiteralBracketMarkers("\(start)git status"))
    }

    func testDetectsEndMarker() {
        XCTAssertTrue(BracketedPasteCapabilityStore.containsLiteralBracketMarkers(end))
        XCTAssertTrue(BracketedPasteCapabilityStore.containsLiteralBracketMarkers("git status\(end)"))
    }

    func testDetectsAFullyEchoedWrappedPayload() {
        XCTAssertTrue(
            BracketedPasteCapabilityStore.containsLiteralBracketMarkers("\(start)git status\(end)")
        )
    }

    /// The markers are `ESC [ 2 0 0 ~`. The bare digits, or the bracket without the escape, are
    /// ordinary text a user may legitimately paste.
    func testDoesNotFireOnLookalikeTextWithoutTheEscape() {
        XCTAssertFalse(BracketedPasteCapabilityStore.containsLiteralBracketMarkers("[200~"))
        XCTAssertFalse(BracketedPasteCapabilityStore.containsLiteralBracketMarkers("[201~"))
        XCTAssertFalse(BracketedPasteCapabilityStore.containsLiteralBracketMarkers("200~ items"))
        XCTAssertFalse(BracketedPasteCapabilityStore.containsLiteralBracketMarkers("\u{1B}[2J"))
    }

    // MARK: - Learning

    func testUnknownHostStillGetsBracketedPaste() {
        let store = BracketedPasteCapabilityStore()
        XCTAssertEqual(store.verdict(for: "com.example.newterm"), .unknown)
        // Fail-safe default: a pasted newline running a command is far worse than a visible
        // escape sequence, so an unknown shell-like host is still bracketed.
        XCTAssertTrue(store.shouldBracketPaste(bundleID: "com.example.newterm"))
    }

    func testLiteralMarkersInTheFieldCondemnTheHost() {
        let store = BracketedPasteCapabilityStore()
        store.learn(fromObservedValue: "\(start)git status\(end)", bundleID: "com.example.oldshell")
        XCTAssertEqual(store.verdict(for: "com.example.oldshell"), .unsupported)
        XCTAssertFalse(store.shouldBracketPaste(bundleID: "com.example.oldshell"))
    }

    func testConsumedMarkersConfirmSupport() {
        let store = BracketedPasteCapabilityStore()
        store.learn(fromObservedValue: "git status", bundleID: "com.example.zsh")
        XCTAssertEqual(store.verdict(for: "com.example.zsh"), .supported)
        XCTAssertTrue(store.shouldBracketPaste(bundleID: "com.example.zsh"))
    }

    func testUnreadableFieldTeachesNothing() {
        let store = BracketedPasteCapabilityStore()
        store.learn(fromObservedValue: nil, bundleID: "com.example.opaque")
        store.learn(fromObservedValue: "", bundleID: "com.example.opaque")
        XCTAssertEqual(store.verdict(for: "com.example.opaque"), .unknown)
    }

    func testMissingBundleIDIsNeverLearned() {
        let store = BracketedPasteCapabilityStore()
        store.learn(fromObservedValue: "\(start)x", bundleID: nil)
        store.learn(fromObservedValue: "\(start)x", bundleID: "")
        store.learn(fromObservedValue: "\(start)x", bundleID: "nil")
        XCTAssertEqual(store.verdict(for: nil), .unknown)
        XCTAssertEqual(store.verdict(for: "nil"), .unknown)
    }
}

/// §3.10 (second half) — the AX heuristic that decides *whether* a focused element is a terminal.
///
/// It used to be a substring match for `terminal` / `console` / `shell` / `term` / `pty` over the
/// joined title + description + identifier, so a VS Code tab named `terminal.ts` or an Xcode file
/// named `Console.swift` routed a normal edit through bracketed paste. A false negative here is
/// safe (a plain paste into a terminal); a false positive injects visible escape sequences.
final class TerminalTitleHeuristicTests: XCTestCase {

    func testRealTerminalTitlesMatch() {
        for title in ["Terminal", "terminal", "Terminal 1", "bash", "zsh — 80×24", "Console",
                      "xterm", "PowerShell", "pty", "Node REPL", "Terminals",
                      "Terminal — -zsh — 120×30"] {
            XCTAssertTrue(
                AXContextChecker.axTitleLooksLikeTerminal(title),
                "Expected \(title) to read as a terminal"
            )
        }
    }

    func testSourceFileNamesDoNotMatch() {
        for title in ["terminal.ts", "Console.swift", "shell.py", "Terminal.tsx", "pty.go",
                      "console.log.txt", "bash.md", "TerminalView.swift"] {
            XCTAssertFalse(
                AXContextChecker.axTitleLooksLikeTerminal(title),
                "\(title) is a document title, not a terminal"
            )
        }
    }

    func testUnrelatedTitlesDoNotMatch() {
        for title in ["", "Untitled", "Message to Alice", "Search", "Determinant", "Terminator",
                      "Preferences"] {
            XCTAssertFalse(
                AXContextChecker.axTitleLooksLikeTerminal(title),
                "\(title) must not read as a terminal"
            )
        }
    }

    func testWholeTokenMatchingIsRequired() {
        // `Determinant` and `Terminator` both *contain* "termina", which the old substring
        // heuristic accepted.
        XCTAssertFalse(AXContextChecker.axTitleLooksLikeTerminal("Determinant matrix"))
        XCTAssertFalse(AXContextChecker.axTitleLooksLikeTerminal("Terminator"))
        XCTAssertTrue(AXContextChecker.axTitleLooksLikeTerminal("Integrated Terminal"))
    }

    func testTerminalRoleSetExcludesPlainTextFields() {
        // An `AXTextField` (a search box, a URL bar) is never an integrated terminal.
        XCTAssertFalse(AXContextChecker.terminalLikeAXRoles.contains("AXTextField"))
        XCTAssertFalse(AXContextChecker.terminalLikeAXRoles.contains(""))
        XCTAssertTrue(AXContextChecker.terminalLikeAXRoles.contains("AXTextArea"))
    }
}
