import XCTest

// MARK: - Source-level contract audits for the DevTypeApp executable target
//
// `DevTypeApp` is an `executableTarget`, so the test target cannot import it — the usual
// unit-test route is closed. Both bugs guarded here were AppKit threading / focus-ordering
// defects that a green suite could not see: they compile, they type-check, and they only
// misbehave at runtime against live AppKit state.
//
// These tests read the source and assert the invariants that were violated. That is a
// coarse instrument, so each assertion is anchored to a distinctive token rather than to
// formatting, and every failure message states the invariant instead of just the diff.

final class SourceContractTests: XCTestCase {

    // MARK: - Source access

    /// Repo root derived from this file's location (`Tests/ExpanderEngineTests/…`).
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ExpanderEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// Source with comments removed.
    ///
    /// These tests search for the same tokens the surrounding comments *explain* (the fix for
    /// the focus bug is documented right next to the call it guards), so scanning raw text
    /// matches the documentation and not the code. Stripping comments first is what makes the
    /// assertions mean what they say.
    private func source(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("Could not read \(relativePath) at \(url.path)")
            return ""
        }
        return Self.strippingComments(text)
    }

    /// Removes `//` line comments and `/* */` blocks. Deliberately simple: it does not parse
    /// string literals, which is safe here because every token these tests search for is code.
    static func strippingComments(_ text: String) -> String {
        var out = ""
        var inBlock = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var kept = ""
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                if inBlock {
                    if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "/" {
                        inBlock = false
                        i += 2
                        continue
                    }
                    i += 1
                    continue
                }
                if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "/" {
                    break   // line comment: drop the remainder
                }
                if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "*" {
                    inBlock = true
                    i += 2
                    continue
                }
                kept.append(chars[i])
                i += 1
            }
            out += kept + "\n"
        }
        return out
    }

    /// Byte offset of `needle`, or `nil`. Used for ordering assertions.
    private func offset(of needle: String, in text: String) -> Int? {
        text.range(of: needle).map { text.distance(from: text.startIndex, to: $0.lowerBound) }
    }

    // MARK: - Selection must be captured before DevType steals focus

    /// `SelectionReader` resolves the *system-wide* focused element. Once
    /// `NSApp.activate(ignoringOtherApps:)` makes DevType frontmost, that element is our own
    /// search field, so any later read returns nil and every palette AI command reports
    /// "no text selected".
    ///
    /// Regression for: ⌘/ palette AI commands always failing with "no text selected" while
    /// ⌘⌥A worked, because `runPaletteAI` read the selection after the panel was already key.
    func testInlineSearchPanelReadsSelectionBeforeActivatingDevType() throws {
        let text = try source("Sources/DevTypeApp/InlineSearchPanel.swift")

        guard let readOffset = offset(of: "SelectionReader.readSelectedText()", in: text) else {
            return XCTFail(
                "InlineSearchPanel must capture the selection at panel-open time. "
                    + "Without it, palette commands have no selection to act on."
            )
        }
        guard let activateOffset = offset(of: "NSApp.activate(", in: text) else {
            return XCTFail("Expected InlineSearchPanel to activate the app when opening.")
        }

        XCTAssertLessThan(
            readOffset,
            activateOffset,
            "InlineSearchPanel must read the selection BEFORE NSApp.activate(...). "
                + "After activation the system-wide focused element is DevType's own search "
                + "field, so the read returns nil and every palette AI/text command fails."
        )
    }

    /// The palette command handlers must consume the captured selection, never re-read it.
    /// A live read here is always nil, and for `.textOp` it silently fell through to the
    /// clipboard — transforming the wrong text with no error shown.
    func testPaletteCommandHandlersDoNotReReadSelectionLive() throws {
        let text = try source("Sources/DevTypeApp/AppDelegate.swift")

        guard let start = offset(of: "private func handlePaletteCommand", in: text),
              let end = offset(of: "private func injectPaletteText", in: text) ?? offset(of: "private func presentAIPalette", in: text)
        else {
            return XCTFail("Could not locate the palette command handling region in AppDelegate.")
        }
        guard start < end else {
            return XCTFail("Unexpected ordering of palette handlers in AppDelegate.")
        }

        let startIndex = text.index(text.startIndex, offsetBy: start)
        let endIndex = text.index(text.startIndex, offsetBy: end)
        let region = String(text[startIndex..<endIndex])

        // Guard against a vacuous pass: if the region extraction ever silently yields an empty
        // or wrong slice, the absence assertion below would succeed while checking nothing.
        XCTAssertGreaterThan(
            region.count, 200,
            "Extracted palette-handler region looks too small (\(region.count) chars) — "
                + "the anchors have probably moved and this test is no longer checking anything."
        )
        XCTAssertTrue(
            region.contains("runPaletteAI("),
            "Extracted region must contain the AI palette dispatch; anchors have drifted."
        )
        XCTAssertTrue(
            region.contains("case .textOp"),
            "Extracted region must contain the text-op branch, which is the case that silently "
                + "fell back to the clipboard when the live selection read returned nil."
        )

        XCTAssertFalse(
            region.contains("SelectionReader.readSelectedText()"),
            "Palette command handlers must use the selection captured by InlineSearchPanel at "
                + "panel-open time. A live SelectionReader read runs while our own panel is key "
                + "and always returns nil (and for .textOp silently falls back to the clipboard)."
        )
    }

    // MARK: - AppKit helpers must not run on the inject queue

    /// `TextInjectionPipeline` fires its completion on `com.devtype.inject`, and three inject
    /// completions call `refreshStatusItemUI()`. Updating the status badge runs AutoLayout,
    /// and AutoLayout off-main aborts the process rather than degrading.
    ///
    /// Regression for: SIGABRT in `_AssertAutoLayoutOnAllowedThreadsOnly` via
    /// `PillBadgeView.updateCornerRadius()` ← `refreshStatusItemUI()` ←
    /// `injectAIReplacement`'s completion, on queue `com.devtype.inject`.
    func testRefreshStatusItemUIHopsToMainThread() throws {
        let text = try source("Sources/DevTypeApp/AppDelegate.swift")

        guard let start = offset(of: "private func refreshStatusItemUI()", in: text) else {
            return XCTFail("Could not locate refreshStatusItemUI() in AppDelegate.")
        }
        let startIndex = text.index(text.startIndex, offsetBy: start)
        // The guard must be the first thing in the body — inspect a small prefix only.
        let prefix = String(text[startIndex...].prefix(400))

        XCTAssertTrue(
            prefix.contains("Thread.isMainThread"),
            "refreshStatusItemUI() must funnel to the main thread before touching AppKit. "
                + "It is called from TextInjectionPipeline completions, which run on the serial "
                + "com.devtype.inject queue; AutoLayout off-main aborts the process."
        )
        XCTAssertTrue(
            prefix.contains("DispatchQueue.main.async"),
            "refreshStatusItemUI() must re-dispatch to main when called off-main, not return early."
        )
    }

    /// The debug-only contract helper must stay debug-only. Making it unconditional would
    /// convert latent off-main calls into new production crashes.
    func testMainThreadContractHelperIsDebugOnly() throws {
        let text = try source("Sources/DevTypeApp/MainThreadContract.swift")

        XCTAssertTrue(
            text.contains("dispatchPrecondition(condition: .onQueue(.main))"),
            "assertMainThread() must assert main-queue execution."
        )
        XCTAssertTrue(
            text.contains("#if DEBUG"),
            "assertMainThread() must be debug-only so release behaviour is unchanged."
        )
    }

    /// AppKit helpers that mutate the status item / menus carry the contract, so a future
    /// off-main caller fails at the real call site instead of deep inside CoreAutoLayout.
    func testAppKitHelpersDeclareMainThreadContract() throws {
        let appDelegate = try source("Sources/DevTypeApp/AppDelegate.swift")
        let theme = try source("Sources/DevTypeApp/DevTypeTheme.swift")

        for (name, marker, text) in [
            ("rebuildRecentMenu()", "private func rebuildRecentMenu()", appDelegate),
            ("PillBadgeView.update(text:tint:)", "func update(text: String, tint newTint: NSColor)", theme)
        ] {
            guard let start = offset(of: marker, in: text) else {
                XCTFail("Could not locate \(name).")
                continue
            }
            let startIndex = text.index(text.startIndex, offsetBy: start)
            let prefix = String(text[startIndex...].prefix(400))
            XCTAssertTrue(
                prefix.contains("assertMainThread()"),
                "\(name) mutates AppKit state and must call assertMainThread() so an off-main "
                    + "caller fails at this call site in debug rather than aborting inside AppKit."
            )
        }
    }
}
