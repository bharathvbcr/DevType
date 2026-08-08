import XCTest
@testable import ExpanderEngine

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

        guard let readOffset = offset(of: "SelectionReader.readSelection()", in: text) else {
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
            region.contains("SelectionReader.read"),
            "Palette command handlers must use the selection captured by InlineSearchPanel at "
                + "panel-open time. A live SelectionReader read runs while our own panel is key "
                + "and always returns nil (and for .textOp silently falls back to the clipboard)."
        )
    }

    // MARK: - Failed selection reads must explain themselves

    /// Every path that tells the user there is no selection must render the *typed* failure.
    /// Hard-coding `ai.alert.noSelection.message` there is how a revoked Accessibility grant,
    /// an active Secure Input session, and a muted app all came to say "Select text first" —
    /// advice the user has already followed, pointing at none of the three real causes.
    func testSelectionFailuresAreReportedWithTheirOwnReason() throws {
        for path in ["Sources/DevTypeApp/AITransformFlow.swift", "Sources/DevTypeApp/AppDelegate.swift"] {
            let text = try source(path)
            guard text.contains("SelectionReader.read") || text.contains("selection.failure")
                    || text.contains("case .selection(") else {
                continue
            }
            XCTAssertTrue(
                text.contains("failure.message(loc:") || text.contains("failure?.message(loc:"),
                "\(path) resolves a selection but never renders the typed failure message."
            )
        }
    }

    /// The AI hotkey path must ask for the reason, not just the text. `readSelectedText()`
    /// discards it, and this entry point is the one that pops the alert.
    func testAIHotkeyPathUsesTheTypedOutcome() throws {
        let text = try source("Sources/DevTypeApp/AITransformFlow.swift")
        guard let start = offset(of: "static func presentFromHotkey", in: text),
              let end = offset(of: "static func presentFromEngine", in: text),
              start < end else {
            return XCTFail("Could not locate presentFromHotkey in AITransformFlow.")
        }
        let region = String(
            text[text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)]
        )
        XCTAssertTrue(
            region.contains("SelectionReader.readSelection(allowClipboardFallback: true)"),
            "presentFromHotkey must use readSelection so the alert can name the real cause, "
                + "and it is the one path that opts into the brokered ⌘C fallback — the captured "
                + "text is shown in the action panel before anything is written back."
        )
        XCTAssertFalse(
            region.contains("readSelectedText()"),
            "readSelectedText() throws the failure reason away."
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
    // MARK: - Secrets

    /// A password is not a template. Every route that resolves a secret must use the stored value
    /// verbatim — running one through `MacroRenderer` would corrupt any value containing `{{`, and
    /// could resolve a nested `{{snippet:…}}` inside it.
    func testSecretResolutionNeverGoesThroughTheMacroRenderer() throws {
        let flow = try source("Sources/DevTypeApp/SecretMenuFlow.swift")
        guard let secretBranch = flow.range(of: "if snippet.isSecret {"),
              let renderCall = flow.range(of: "MacroRenderer.expand") else {
            return XCTFail("SecretMenuFlow no longer has the shape this contract describes.")
        }
        XCTAssertTrue(
            secretBranch.upperBound < renderCall.lowerBound,
            "The secret branch must return before the renderer is reached."
        )

        // Every secret read funnels through `SecretMenuFlow.resolve`, which is where the
        // Touch ID gate lives. A surface that reached into `SecretStore` directly would be a
        // path around the gate — and the next one to be added would copy whichever example it
        // found first.
        let appDelegate = try source("Sources/DevTypeApp/AppDelegate.swift")
        XCTAssertFalse(
            appDelegate.contains("SecretStore.shared.secret("),
            "Read secrets through `SecretMenuFlow.resolve`, never straight from the store."
        )
        XCTAssertTrue(appDelegate.contains("SecretMenuFlow.resolve("))
    }

    /// The library file is the thing this feature exists to keep a password out of. The redaction
    /// lives in `encode(to:)` precisely so no writer has to remember it — assert it is still there
    /// rather than trusting that every future exporter looks it up.
    func testSecretRedactionStaysInTheEncoder() throws {
        let model = try source("Sources/ExpanderEngine/Models/SnippetModel.swift")
        XCTAssertTrue(
            model.contains("try c.encode(isSecret ? \"\" : replacementText, forKey: .replacementText)"),
            "Move this out of `encode(to:)` and every exporter becomes a place a password can leak."
        )
        // The decoder's half is asserted by behaviour rather than by shape: it has already grown
        // a second field (`imagePath`, once secret-and-image became unrepresentable), and a
        // contract that pins formatting breaks on every such extension while proving less.
        let smuggled = """
        {"id":"6C4A2B1E-0000-4000-8000-000000000001","title":"t","triggerKeyword":";t",
         "replacementText":"leaked","imagePath":"leaked.png","isSecret":true}
        """
        let decoded = try JSONDecoder().decode(SnippetModel.self, from: Data(smuggled.utf8))
        XCTAssertEqual(decoded.replacementText, "", "A hand-edited library must not reintroduce it.")
        XCTAssertEqual(decoded.imagePath, "", "Secret and image is an ambiguous state on purpose.")
        XCTAssertFalse(decoded.isImageSnippet)
    }

    /// §8.10: an ordinary secret read must be structurally incapable of showing the login
    /// keychain dialog. Every `SecItemCopyMatching` in the store runs inside the UI-suppressed
    /// wrapper except exactly one — the interactive fetch inside `migrateLegacy`, which the UI
    /// reaches only through an alert that announces the dialogs first.
    func testKeychainDialogIsReachableOnlyThroughMigration() throws {
        let store = try source("Sources/ExpanderEngine/Models/SecretStore.swift")

        // The one interactive fetch lives in migrateLegacy, after the allowInteraction guard.
        guard let migrate = store.range(of: "public func migrateLegacy(allowInteraction:"),
              let interactive = store.range(of: "legacy fetch with dialog") else {
            return XCTFail("SecretStore no longer has the shape this contract describes.")
        }
        XCTAssertTrue(
            migrate.upperBound < interactive.lowerBound,
            "The dialog-capable fetch must live inside migrateLegacy."
        )
        XCTAssertEqual(
            store.components(separatedBy: "legacy fetch with dialog").count - 1, 1,
            "Exactly one dialog-capable fetch, so 'never surprise-prompts' stays checkable."
        )

        // value() reports needsUser instead of ever falling through to a prompt.
        guard let valueFn = store.range(of: "public func value(account:"),
              let needsUser = store.range(of: "case .needsUser:") else {
            return XCTFail("value() no longer has the shape this contract describes.")
        }
        XCTAssertTrue(valueFn.upperBound < needsUser.lowerBound)

        // And the UI reaches migrateLegacy(allowInteraction: true) only inside the flow that
        // has just told the user how many dialogs to expect.
        let appDelegate = try source("Sources/DevTypeApp/AppDelegate.swift")
        XCTAssertEqual(
            appDelegate.components(separatedBy: "migrateLegacy(allowInteraction: true)").count - 1, 1,
            "One doorway: offerSecretMigration. A second caller is a second surprise prompt."
        )
        guard let offer = appDelegate.range(of: "private func offerSecretMigration("),
              let migrateCall = appDelegate.range(of: "migrateLegacy(allowInteraction: true)") else {
            return XCTFail("AppDelegate no longer has the shape this contract describes.")
        }
        XCTAssertTrue(offer.upperBound < migrateCall.lowerBound)
    }

    /// §8.10: a locked login keychain must be diagnosed as locked, never reported as "no secret
    /// stored" — and the unlock dialog has exactly one explained doorway, like migration.
    func testLockedKeychainIsDiagnosedNotDeniedAndUnlockHasOneDoorway() throws {
        let flow = try source("Sources/DevTypeApp/SecretMenuFlow.swift")
        guard let lockCheck = flow.range(of: "isKeychainLocked()"),
              let missing = flow.range(of: ".failure(.secretUnavailable)") else {
            return XCTFail("SecretMenuFlow no longer has the shape this contract describes.")
        }
        XCTAssertTrue(
            lockCheck.lowerBound < missing.lowerBound,
            "Check the lock before declaring the secret missing — the fix is 'unlock', not 're-enter'."
        )

        let appDelegate = try source("Sources/DevTypeApp/AppDelegate.swift")
        XCTAssertEqual(
            appDelegate.components(separatedBy: "requestKeychainUnlock()").count - 1, 1,
            "One doorway: offerKeychainUnlock. A second caller is a second surprise dialog."
        )
        guard let offer = appDelegate.range(of: "private func offerKeychainUnlock("),
              let unlockCall = appDelegate.range(of: "requestKeychainUnlock()") else {
            return XCTFail("AppDelegate no longer has the shape this contract describes.")
        }
        XCTAssertTrue(offer.upperBound < unlockCall.lowerBound)
    }

    /// Secrets are filtered at the engine's own setter, not at its callers, so no future caller
    /// can put one back on the typed path.
    func testTypedPathFilterLivesInTheEngineSetter() throws {
        let engine = try source("Sources/ExpanderEngine/Engine/EventTapEngine.swift")
        XCTAssertTrue(engine.contains("newValue.filter(\\.isTypedTriggerExpandable)"))
    }

    // MARK: - Editor panel must not resize itself

    /// The editor is a fixed-size borderless panel, and AppKit sizes such a window from its
    /// content view's *fitting* size — which counts every label's intrinsic width. The live
    /// preview strip is fed by the replacement text, so without these guards the panel grew wider
    /// with every character typed.
    func testEditorCannotBeGrownByItsOwnContent() throws {
        let editor = try source("Sources/DevTypeApp/SnippetEditorSheet.swift")

        XCTAssertTrue(
            editor.contains("previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)"),
            "Restore this and the preview label's intrinsic width widens the window again."
        )
        XCTAssertTrue(
            editor.contains("MacroPreview.clampedForStage(rendered)"),
            "The stage must be handed a bounded string, not the whole replacement."
        )
        XCTAssertTrue(
            editor.contains("panel.contentMaxSize = fixedSize"),
            "The backstop that makes the next such bug impossible rather than merely fixed."
        )
    }

    /// The behaviour chips outgrew the panel the moment a fifth was added, and the row had no
    /// trailing constraint, so the overflow ran off the edge unreachable. It scrolls now — the
    /// trailing edge is the part that makes that true.
    func testBehaviourChipsAreBoundedByThePanelWidth() throws {
        let editor = try source("Sources/DevTypeApp/SnippetEditorSheet.swift")
        XCTAssertTrue(editor.contains("chipsScroll.documentView = chipsRow"))
        XCTAssertTrue(
            editor.contains("chipsScroll.trailingAnchor.constraint(equalTo: titleField.trailingAnchor)"),
            "Without a trailing edge the row overflows instead of scrolling."
        )
        XCTAssertFalse(
            editor.contains("root.addSubview(chipsRow)"),
            "The row belongs to the scroller now; adding it to the root again reintroduces the "
                + "unbounded version."
        )

        // An overlay scroller floats over its content, so without a reserved band it is drawn
        // across the bottom of the pills for as long as the user is scrolling them.
        XCTAssertTrue(editor.contains("chipsScroll.automaticallyAdjustsContentInsets = false"))
        XCTAssertTrue(editor.contains("bottom: SnippetEditorSheet.chipScrollerBand"))
        XCTAssertFalse(
            editor.contains("chipsRow.bottomAnchor.constraint(equalTo: chipsScroll.contentView.bottomAnchor)"),
            "Pinned to the bottom the stack stretches across the band and the pills end up under "
                + "the scroller again."
        )
    }

    /// Copying must never put a modal in the way.
    ///
    /// The first version showed `DevTypeAlert.info` after every copy. Two problems, and the
    /// second is the serious one: the user had to dismiss a dialog to get on with a two-second
    /// task, and an alert *activates DevType*, taking focus off the password field they were
    /// about to paste into. The confirmation is a non-activating toast that any next action
    /// dismisses.
    func testCopyConfirmationIsNeverAModal() throws {
        let appDelegate = try source("Sources/DevTypeApp/AppDelegate.swift")
        // The switch moved out of `copyToClipboard` when the resolve step became asynchronous
        // for the Touch ID gate; the contract is about wherever the *result* is applied.
        guard let start = appDelegate.range(of: "private func applyCopyResult("),
              let end = appDelegate.range(
                  of: "\n    private func",
                  range: start.upperBound..<appDelegate.endIndex
              )
        else {
            return XCTFail("applyCopyResult no longer has the shape this contract describes.")
        }
        let body = String(appDelegate[start.upperBound..<end.lowerBound])

        XCTAssertTrue(body.contains("ToastPanel.show"), "The success path must use the toast.")
        // `DevTypeAlert.present` survives for the *failure* path, where the user has to go and fix
        // something and a dismissible banner would be the wrong shape. Only the modal that blocks
        // a successful copy is forbidden.
        XCTAssertFalse(
            body.contains("DevTypeAlert.info"),
            "A modal on the success path both interrupts the task and steals focus from the "
                + "field the user is about to paste into."
        )
    }

    /// The toast must never become key or activate the app — that is the whole reason it exists.
    func testToastNeverTakesFocus() throws {
        let toast = try source("Sources/DevTypeApp/ToastPanel.swift")
        XCTAssertTrue(toast.contains("override var canBecomeKey: Bool { false }"))
        XCTAssertTrue(toast.contains("override var canBecomeMain: Bool { false }"))
        XCTAssertTrue(
            toast.contains("orderFrontRegardless()"),
            "Shown without activating; `makeKeyAndOrderFront` would pull focus."
        )
        XCTAssertFalse(
            toast.contains("NSApp.activate"),
            "Activating for a confirmation is exactly the bug the toast replaces."
        )
    }

}
