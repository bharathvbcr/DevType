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

    private func sourceFilesContaining(_ token: String) throws -> Set<String> {
        let sourcesRoot = Self.repoRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate source files at \(sourcesRoot.path)")
            return []
        }

        var matches: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  Self.strippingComments(text).contains(token) else { continue }
            matches.insert(String(url.path.dropFirst(Self.repoRoot.path.count + 1)))
        }
        return matches
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

    /// The initial palette dispatcher must consume the captured selection, never re-read while
    /// DevType's panel is still key. Selection-dependent AI recovery lives in `runPaletteAI`,
    /// after the panel closes and the source app has explicitly been reactivated.
    func testPaletteCommandHandlersDoNotReReadSelectionLive() throws {
        let text = try source("Sources/DevTypeApp/AppDelegate.swift")

        guard let start = offset(of: "private func handlePaletteCommand", in: text),
              let end = offset(of: "private func runPaletteAI", in: text)
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
            "The palette dispatcher must use the selection captured by InlineSearchPanel at "
                + "panel-open time. A live read while our own panel is key always resolves the "
                + "wrong app; only runPaletteAI may retry after restoring source focus."
        )
    }

    /// Codex currently exposes no focused AX candidate for its composer. The selection captured
    /// while opening the command palette therefore arrives here as `noFocusedElement`. Once the
    /// user explicitly chooses an AI action, DevType must return focus to the source app and retry
    /// through the same brokered-copy fallback used by the dedicated AI hotkey.
    func testPaletteAIRecoversNoFocusAfterReactivatingTheSourceApp() throws {
        let text = try source("Sources/DevTypeApp/AppDelegate.swift")

        guard let start = offset(of: "private func runPaletteAI", in: text),
              let end = offset(of: "private func injectPaletteText", in: text),
              start < end else {
            return XCTFail("Could not locate the palette AI handling region in AppDelegate.")
        }
        let region = String(
            text[text.index(text.startIndex, offsetBy: start)..<text.index(text.startIndex, offsetBy: end)]
        )

        XCTAssertTrue(
            region.contains("case .failure(.noFocusedElement)"),
            "Palette AI must distinguish a missing AX tree from real empty selection."
        )
        guard let activateOffset = offset(of: "sourceApp.activate()", in: region),
              let fallbackOffset = offset(
                  of: "SelectionReader.readSelectionForExplicitAIAction()",
                  in: region
              ) else {
            return XCTFail(
                "Palette AI must reactivate the source app, then retry with the brokered "
                    + "clipboard fallback after a no-focus capture."
            )
        }
        XCTAssertLessThan(
            activateOffset,
            fallbackOffset,
            "The selection retry must run only after focus has returned to the source app."
        )
    }

    /// The first recovery fix checked focus in AppDelegate and then entered a selection read
    /// that can spend 1.5 seconds probing AX before it posts its fallback copy. Focus can change
    /// inside that window. The original source pid must therefore be carried through the reader
    /// and revalidated by the clipboard broker immediately before it posts ⌘C.
    func testClipboardFallbackPinsTheOriginalSourceThroughTheCopyPost() throws {
        let reader = try source("Sources/ExpanderEngine/AI/SelectionReader.swift")
        let broker = try source("Sources/ExpanderEngine/Engine/PasteboardBroker.swift")

        XCTAssertTrue(
            reader.contains("expectedFrontmostPID: frontmostPID"),
            "SelectionReader must pass the source pid captured before AX probing to the copy broker."
        )
        XCTAssertTrue(
            broker.contains("expectedFrontmostPID"),
            "PasteboardBroker must accept a pinned source pid for immediate pre-post validation."
        )
        XCTAssertTrue(
            broker.contains("sourceAppChanged"),
            "A focus change must be diagnosable, not collapsed into a generic post failure."
        )
    }

    /// Focus polling is policy, not AppDelegate UI glue. Keeping the transition table in the
    /// engine makes termination, exhausted budgets, nil frontmost state, and matching pids
    /// directly unit-testable instead of relying on source-shape assertions alone.
    func testPaletteFocusRecoveryUsesTheCanonicalSelectionPolicy() throws {
        let text = try source("Sources/DevTypeApp/AppDelegate.swift")
        XCTAssertTrue(
            text.contains("SelectionReader.sourceFocusRetryDecision("),
            "AppDelegate must delegate focus recovery decisions to the tested engine policy."
        )
    }

    /// Synthetic copy is not a general selection-reader option. A Boolean at the public boundary
    /// lets any future caller turn it on without naming the user gesture that authorizes it. Keep
    /// the ordinary reader AX-only and expose one deliberately named AI-only entry point.
    func testClipboardFallbackRequiresTheExplicitAIEntryPoint() throws {
        let reader = try source("Sources/ExpanderEngine/AI/SelectionReader.swift")
        XCTAssertFalse(
            reader.contains("allowClipboardFallback: Bool"),
            "A public Boolean makes synthetic copy an ambient option instead of an explicit-AI capability."
        )
        XCTAssertTrue(
            reader.contains("readSelectionForExplicitAIAction("),
            "The fallback must be reachable only through a deliberately named explicit-AI entry point."
        )

        for path in [
            "Sources/DevTypeApp/AITransformFlow.swift",
            "Sources/DevTypeApp/AppDelegate.swift",
            "Sources/DevTypeApp/VoiceDictationController.swift",
        ] {
            let text = try source(path)
            XCTAssertTrue(
                text.contains("SelectionReader.readSelectionForExplicitAIAction("),
                "\(path) is an authorized explicit-AI path and must use the named entry point."
            )
            XCTAssertFalse(
                text.contains("allowClipboardFallback"),
                "\(path) must not retain the old ambient Boolean escape hatch."
            )
        }

        // The invariant is the exact *set* of authorized files; file-enumeration order
        // is incidental, so compare as sets and report the difference either way.
        let authorized: Set<String> = [
            "Sources/ExpanderEngine/AI/SelectionReader.swift",
            "Sources/DevTypeApp/AITransformFlow.swift",
            "Sources/DevTypeApp/VoiceDictationController.swift",
            "Sources/DevTypeApp/AppDelegate.swift",
        ]
        let actual = Set(try sourceFilesContaining("readSelectionForExplicitAIAction("))
        XCTAssertEqual(
            actual,
            authorized,
            """
            No non-AI source path may acquire the synthetic-copy capability.
            unexpected: \(actual.subtracting(authorized).sorted())
            missing:    \(authorized.subtracting(actual).sorted())
            """
        )
    }

    /// A fallback capture can be a real selection or an editor's copy-current-line behavior.
    /// The action picker must not represent that ambiguous provenance as AX-verified selection.
    func testClipboardFallbackPreviewNamesItsAmbiguousProvenance() throws {
        let flow = try source("Sources/DevTypeApp/AITransformFlow.swift")
        let panel = try source("Sources/DevTypeApp/AIActionPanel.swift")
        XCTAssertTrue(
            flow.contains("source: selection.source"),
            "The hotkey flow must carry selection provenance into the pre-action preview."
        )
        XCTAssertTrue(
            panel.contains("source: SelectionReader.Source"),
            "AIActionPanel must accept the provenance needed to label a copy fallback honestly."
        )
        XCTAssertTrue(
            panel.contains("ai.palette.clipboardPreview"),
            "Clipboard fallback text must be labeled as copied/ambiguous, not as verified selected text."
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
            region.contains("SelectionReader.readSelectionForExplicitAIAction()"),
            "presentFromHotkey must use the explicit-AI reader so the alert can name the real cause, "
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

    /// §8.11: a keychain copy may be dropped only after the sealed copy is saved and verified —
    /// in both consolidation and the ordinary save. Reordering either is how secrets get lost.
    func testTierCopyIsDroppedOnlyAfterTheArchiveIsVerified() throws {
        let store = try source("Sources/ExpanderEngine/Models/SecretStore.swift")
        // Anchor inside ConsolidatedSecretBackingStore: the keychain tier has a `set` of its
        // own, earlier in the file, with none of this machinery.
        guard let classStart = store.range(of: "final class ConsolidatedSecretBackingStore") else {
            return XCTFail("ConsolidatedSecretBackingStore is gone; rewrite this contract.")
        }
        let consolidated = store[classStart.upperBound...]
        for function in ["public func set(_ value: String, account:", "private func consolidateLocked("] {
            guard let start = consolidated.range(of: function) else {
                return XCTFail("SecretStore no longer has the shape this contract describes.")
            }
            let body = consolidated[start.upperBound...]
            guard let save = body.range(of: "saveArchive(entries)"),
                  let verify = body.range(of: "verifiedOnDisk(account:"),
                  let drop = body.range(of: "tier.delete(account:") else {
                return XCTFail("\(function) no longer has the shape this contract describes.")
            }
            XCTAssertTrue(
                save.lowerBound < verify.lowerBound && verify.lowerBound < drop.lowerBound,
                "\(function): save, then prove the entry decrypts from the bytes on disk, and "
                + "only then drop the keychain copy. Reordering this is how §8.11 lost a secret."
            )
        }

        // And the master key is never trusted without the read-back that proves this identity
        // can decrypt with it tomorrow.
        guard let create = store.range(of: "diagnostics.note(\"master key created\""),
              let readBack = store.range(of: "master key read-back failed") else {
            return XCTFail("masterKey(createIfNeeded:) no longer has the shape this contract describes.")
        }
        XCTAssertTrue(create.lowerBound < readBack.lowerBound)
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

    // MARK: - Preferences must behave like one coherent surface

    /// Hidden scroll views can acquire a non-zero clip origin while Auto Layout sizes their
    /// documents. Without a first-presentation reset, long panes (notably Voice and AI) open in
    /// the middle and hide their primary enablement/status controls above the viewport.
    func testPreferencesTabsStartAtTheTopOnFirstPresentation() throws {
        let preferences = try source("Sources/DevTypeApp/PreferencesWindowController.swift")

        XCTAssertTrue(
            preferences.contains("tabsShownAtLeastOnce.insert(tab).inserted"),
            "Each Preferences tab must distinguish its first presentation from later returns."
        )
        XCTAssertTrue(
            preferences.contains("scroll.contentView.scroll(to: .zero)"),
            "A newly revealed Preferences pane must explicitly reset its flipped document to y=0."
        )
        XCTAssertTrue(
            preferences.contains("scroll.reflectScrolledClipView(scroll.contentView)"),
            "The scroller must be synchronized after resetting the clip view."
        )
    }

    /// The Home dashboard is itself an `NSScrollView`, but Preferences embeds its view in a
    /// constraint-managed pane host. Leaving the outer scroll view's autoresizing mask enabled
    /// adds a second set of constraints at that seam and can collapse every preferences pane.
    func testEmbeddedHomePreferencesPaneDisablesAutoresizingMaskConstraints() throws {
        let home = try source("Sources/DevTypeApp/HomeViewController.swift")
        let preferences = try source("Sources/DevTypeApp/PreferencesWindowController.swift")

        XCTAssertTrue(
            home.contains("scroll.translatesAutoresizingMaskIntoConstraints = false"),
            "The Home scroll view must be constraint-managed before Preferences embeds it."
        )
        XCTAssertTrue(
            preferences.contains("homeView.translatesAutoresizingMaskIntoConstraints = false"),
            "The Preferences pane host must explicitly own the embedded Home view's constraints."
        )
    }

    /// Every list-shaped preference needs the same in-context empty state. A label below a fixed
    /// 110-point table leaves a large blank box that looks broken, and the macro table previously
    /// had no empty message at all.
    func testPreferencesListsUseTheSharedEmptyStateContainer() throws {
        let preferences = try source("Sources/DevTypeApp/PreferencesWindowController.swift")
        let uses = preferences.components(separatedBy: "makeTableArea(").count - 1

        XCTAssertEqual(
            uses,
            6,
            "Five list/table cards plus the helper declaration must flow through makeTableArea."
        )
        XCTAssertTrue(
            preferences.contains("macroEmptyLabel"),
            "Hotkey Macros must explain its empty state just like the other preference lists."
        )
    }

    /// macOS settings rows read left-to-right as label then control. Keeping the switch on the
    /// leading edge while popups sit on the trailing edge made adjacent cards feel unrelated and
    /// made long Voice labels harder to scan.
    func testPreferencesToggleRowsAlignLabelsLeadingAndSwitchesTrailing() throws {
        let preferences = try source("Sources/DevTypeApp/PreferencesWindowController.swift")
        guard let start = preferences.range(of: "private func makeToggleRow("),
              let end = preferences.range(of: "\n    private func", range: start.upperBound..<preferences.endIndex)
        else {
            return XCTFail("makeToggleRow no longer has the shape this contract describes.")
        }
        let body = String(preferences[start.upperBound..<end.lowerBound])

        XCTAssertTrue(body.contains("label.leadingAnchor.constraint(equalTo: row.leadingAnchor)"))
        XCTAssertTrue(body.contains("toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor)"))
        XCTAssertFalse(
            body.contains("toggle.leadingAnchor.constraint(equalTo: row.leadingAnchor)"),
            "Switches belong at the trailing edge of a full-width settings row."
        )
    }

    /// Speech recognizers and transcript-cleanup LLMs answer different questions, but their
    /// inventory does not need the data-table treatment intended for user-authored mappings.
    func testVoicePreferencesSeparatesSpeechModelsFromCleanupModels() throws {
        let preferences = try source("Sources/DevTypeApp/PreferencesWindowController.swift")

        XCTAssertTrue(
            preferences.contains("makeVoiceRecognitionModelInventory"),
            "Voice Preferences must keep speech models visible in a compact inventory."
        )
        XCTAssertFalse(
            preferences.contains("voiceRecognitionModelsTable"),
            "The table treatment belongs to vocabulary and trigger mappings, not model inventory."
        )
        XCTAssertTrue(
            preferences.contains("prefs.voice.cleanupModels"),
            "Local chat models must be labeled as transcript-cleanup models, not speech models."
        )
        XCTAssertFalse(
            preferences.contains("Available Speech / Cleanup Models"),
            "A combined label falsely presents chat-only models as speech recognizers."
        )
    }

    func testVoiceVocabularyAndTriggersUseNamedTableColumns() throws {
        let preferences = try source("Sources/DevTypeApp/PreferencesWindowController.swift")

        XCTAssertTrue(preferences.contains("configureVoiceDictionaryTable"))
        XCTAssertTrue(preferences.contains("voiceDictSpoken"))
        XCTAssertTrue(preferences.contains("voiceDictReplacement"))
        XCTAssertTrue(preferences.contains("configureVoiceTriggersTable"))
        XCTAssertTrue(preferences.contains("voiceTriggerPhrase"))
        XCTAssertTrue(preferences.contains("voiceTriggerAction"))
    }

    func testImportPreviewCancellationReleasesTheInProgressGuard() throws {
        let preview = try source("Sources/DevTypeApp/SnippetImportPreviewSheet.swift")

        XCTAssertTrue(
            preview.contains("onCancel: (() -> Void)? = nil"),
            "The preview must expose a cancellation callback so the flow can release its guard."
        )
        XCTAssertTrue(
            preview.contains("override func viewWillDisappear()")
                && preview.contains("finishCancelledIfNeeded()"),
            "Closing the title-bar window must release the import guard just like Cancel."
        )
        XCTAssertTrue(
            preview.contains("case 1: mode = .skipConflicts"),
            "Skip Conflicting must use the non-destructive store mode."
        )
    }

}
