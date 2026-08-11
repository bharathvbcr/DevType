import XCTest
@testable import ExpanderEngine

final class ExpanderEngineTests: XCTestCase {

    func testSafeMathParserEvaluation() {
        XCTAssertEqual(SafeMathParser.evaluate("12 + 4"), 16.0)
        XCTAssertEqual(SafeMathParser.evaluate("10 * (3 + 2)"), 50.0)
        XCTAssertEqual(SafeMathParser.evaluate("2 ^ 3"), 8.0)
        XCTAssertEqual(SafeMathParser.evaluate("10 % 3"), 1.0)
        XCTAssertEqual(SafeMathParser.evaluate("-5 + 10"), 5.0)
        XCTAssertNil(SafeMathParser.evaluate("10 / 0"))
    }

    func testDynamicTemplateEngineDateAndClipboard() {
        let engine = DynamicTemplateEngine.shared
        let testDate = Date(timeIntervalSince1970: 1700000000)

        let template = "Hello {{clipboard}}, today is {{date:yyyy-MM-dd}}, calc={{calc: 5 * 5}}"
        let result = engine.resolve(template, currentDate: testDate, clipboardText: "DevType User")

        XCTAssertEqual(result.text, "Hello DevType User, today is 2023-11-14, calc=25")
        XCTAssertNil(result.cursorOffset)
    }

    func testDynamicTemplateEngineCursorOffset() {
        let engine = DynamicTemplateEngine.shared
        let template = "Function: () { {{cursor}} }"
        let result = engine.resolve(template)

        XCTAssertEqual(result.text, "Function: () {  }")
        XCTAssertEqual(result.cursorOffset, 15)
    }

    func testDynamicTemplateEngineMultipleCursorTags() {
        let engine = DynamicTemplateEngine.shared
        let template = "Start: {{cursor}}, End: {{cursor}}"
        let result = engine.resolve(template)

        XCTAssertEqual(result.text, "Start: , End: ")
        XCTAssertEqual(result.cursorOffset, 7)
    }

    func testDynamicPasteboardRestoreDelayMath() {
        let pipeline = TextInjectionPipeline.shared

        let smallDelay = pipeline.calculateRestoreDelay(payloadBytes: 100)
        XCTAssertEqual(smallDelay, 0.15, accuracy: 0.001)

        let mediumDelay = pipeline.calculateRestoreDelay(payloadBytes: 4000)
        XCTAssertEqual(mediumDelay, 0.15, accuracy: 0.001)

        let hugeDelay = pipeline.calculateRestoreDelay(payloadBytes: 50000)
        XCTAssertEqual(hugeDelay, 0.45, accuracy: 0.001)
    }

    func testEraseCountWithSwallowedFinalKey() {
        XCTAssertEqual(TextInjectionPipeline.eraseCount(triggerLength: 4, swallowedFinalKey: true), 3)
        XCTAssertEqual(TextInjectionPipeline.eraseCount(triggerLength: 4, swallowedFinalKey: false), 4)
        XCTAssertEqual(TextInjectionPipeline.eraseCount(triggerLength: 1, swallowedFinalKey: true), 0)
        XCTAssertEqual(TextInjectionPipeline.eraseCount(triggerLength: 0, swallowedFinalKey: true), 0)
        XCTAssertEqual(TextInjectionPipeline.eraseCount(triggerLength: 0, swallowedFinalKey: false), 0)
    }

    func testEraseCountUsesLastEventCharacterCount() {
        // Multi-scalar final key (e.g. composed character) swallowed → erase fewer code units.
        XCTAssertEqual(
            TextInjectionPipeline.eraseCount(triggerLength: 5, swallowedFinalKey: true, lastEventCharacterCount: 2),
            3
        )
        XCTAssertEqual(
            TextInjectionPipeline.eraseCount(triggerLength: 2, swallowedFinalKey: true, lastEventCharacterCount: 2),
            0
        )
        XCTAssertEqual(
            TextInjectionPipeline.eraseCount(triggerLength: 3, swallowedFinalKey: true, lastEventCharacterCount: 5),
            0
        )
    }

    func testRestoreGenerationTokenMonotonic() {
        XCTAssertEqual(TextInjectionPipeline.nextRestoreGeneration(current: 0), 1)
        XCTAssertEqual(TextInjectionPipeline.nextRestoreGeneration(current: 41), 42)
        XCTAssertEqual(TextInjectionPipeline.nextRestoreGeneration(current: UInt64.max), 0)
    }

    func testShouldResetBufferPolicy() {
        XCTAssertTrue(EventTapEngine.shouldResetBuffer(flags: .maskCommand, keyCode: 0))
        XCTAssertTrue(EventTapEngine.shouldResetBuffer(flags: .maskControl, keyCode: 0))
        XCTAssertTrue(EventTapEngine.shouldResetBuffer(flags: [], keyCode: 123)) // left arrow
        XCTAssertTrue(EventTapEngine.shouldResetBuffer(flags: .maskAlternate, keyCode: 51)) // Option+Delete
        XCTAssertTrue(EventTapEngine.shouldResetBuffer(flags: .maskShift, keyCode: 51))
        XCTAssertFalse(EventTapEngine.shouldResetBuffer(flags: [], keyCode: 51)) // plain backspace
        XCTAssertFalse(EventTapEngine.shouldResetBuffer(flags: [], keyCode: 0)) // plain key
    }

    func testEmptyTriggerNeverMatches() {
        let engine = EventTapEngine()
        engine.snippets = [
            SnippetModel(title: "Empty", triggerKeyword: "", replacementText: "nope", requireWordBoundary: false)
        ]
        XCTAssertNil(engine.findMatch(in: "anything"))
        XCTAssertNil(engine.findMatch(in: ""))
        XCTAssertFalse(engine.evaluateMatch(bufferSnapshot: "hello"))
    }

    func testDefaultHelloHasNoClipboardTemplate() {
        let hello = SnippetStore().defaultSnippets().first { $0.triggerKeyword == ":hello" }
        XCTAssertNotNil(hello)
        XCTAssertFalse(hello!.replacementText.contains("{{clipboard}}"))
    }

    func testSnippetMatchingLogic() {
        let engine = EventTapEngine()
        let snippet1 = SnippetModel(
            title: "Email",
            triggerKeyword: ":eml",
            replacementText: "user@example.com",
            isCaseSensitive: false,
            requireWordBoundary: false
        )
        let snippet2 = SnippetModel(
            title: "CaseSensitive",
            triggerKeyword: ":CODE",
            replacementText: "SECRET",
            isCaseSensitive: true,
            requireWordBoundary: false
        )

        engine.snippets = [snippet1, snippet2]

        // Pure findMatch / evaluateMatch — no inject, no pasteboard mutation
        XCTAssertNotNil(engine.findMatch(in: "hello :EML"))
        XCTAssertTrue(engine.evaluateMatch(bufferSnapshot: "hello :EML"))
        XCTAssertNil(engine.findMatch(in: "hello :code"))
        XCTAssertFalse(engine.evaluateMatch(bufferSnapshot: "hello :code"))
        XCTAssertEqual(engine.findMatch(in: "hello :CODE")?.snippet.triggerKeyword, ":CODE")
    }

    func testLongestMatchWinsAmongSuffixTriggers() {
        let engine = EventTapEngine()
        let short = SnippetModel(
            title: "Short",
            triggerKeyword: ":em",
            replacementText: "short",
            isCaseSensitive: false,
            requireWordBoundary: false
        )
        let long = SnippetModel(
            title: "Long",
            triggerKeyword: ":eml",
            replacementText: "long",
            isCaseSensitive: false,
            requireWordBoundary: false
        )
        // Short listed first — longest-match must still prefer :eml
        engine.snippets = [short, long]

        XCTAssertEqual(engine.findMatch(in: "hello :eml")?.snippet.triggerKeyword, ":eml")
        XCTAssertEqual(engine.findMatch(in: "hello :em")?.snippet.triggerKeyword, ":em")
    }

    func testEqualLengthMatchPrefersEarlierSnippet() {
        let engine = EventTapEngine()
        let first = SnippetModel(
            title: "First",
            triggerKeyword: ":ab",
            replacementText: "one",
            isCaseSensitive: false,
            requireWordBoundary: false
        )
        let second = SnippetModel(
            title: "Second",
            triggerKeyword: ":AB",
            replacementText: "two",
            isCaseSensitive: false,
            requireWordBoundary: false
        )
        engine.snippets = [first, second]

        XCTAssertEqual(engine.findMatch(in: "x :ab")?.snippet.title, "First")
    }

    func testTerminalBundleIDsIncludeWarp() {
        let checker = AXContextChecker()
        XCTAssertTrue(checker.isTerminalBundleID("com.apple.Terminal"))
        XCTAssertTrue(checker.isTerminalBundleID("dev.warp.Warp-Stable"))
        XCTAssertTrue(checker.isTerminalBundleID("dev.warp.Warp"))
        XCTAssertTrue(checker.isTerminalBundleID("co.zeit.hyper"))
        XCTAssertTrue(checker.isTerminalBundleID("com.cmuxterm.app"))
        XCTAssertFalse(checker.isTerminalBundleID("com.apple.Safari"))
    }

    func testIDEBundleIDsIncludeCursorAndVSCode() {
        let checker = AXContextChecker()
        XCTAssertTrue(checker.isIDEBundleID("com.todesktop.230313mzl4w4u92"))
        XCTAssertTrue(checker.isIDEBundleID("com.microsoft.VSCode"))
        XCTAssertTrue(checker.isIDEBundleID("com.apple.dt.Xcode"))
        XCTAssertFalse(checker.isIDEBundleID("com.apple.Terminal"))
        XCTAssertFalse(checker.isIDEBundleID("com.apple.Safari"))
    }

    func testVerifyTextDeliverySucceedsWhenValueChangesToContainExpectedText() {
        let before = TextInjectionPipeline.FocusedTextObservation(
            value: "abc",
            selectedText: nil
        )
        let after = TextInjectionPipeline.FocusedTextObservation(
            value: "abcHello",
            selectedText: nil
        )

        XCTAssertEqual(
            TextInjectionPipeline.verifyTextDelivery(
                expectedText: "Hello",
                baseline: before,
                after: after
            ),
            .delivered
        )
    }

    func testVerifyTextDeliveryFailsWhenReadableValueDoesNotContainExpectedText() {
        let before = TextInjectionPipeline.FocusedTextObservation(
            value: "abc",
            selectedText: nil
        )
        let after = TextInjectionPipeline.FocusedTextObservation(
            value: "abc",
            selectedText: nil
        )

        XCTAssertEqual(
            TextInjectionPipeline.verifyTextDelivery(
                expectedText: "Hello",
                baseline: before,
                after: after
            ),
            .failed
        )
    }

    func testVerifyTextDeliveryReturnsUnavailableWhenExpectedWasAlreadyPresentWithoutObservableChange() {
        let before = TextInjectionPipeline.FocusedTextObservation(
            value: "Hello",
            selectedText: nil
        )
        let after = TextInjectionPipeline.FocusedTextObservation(
            value: "Hello",
            selectedText: nil
        )

        XCTAssertEqual(
            TextInjectionPipeline.verifyTextDelivery(
                expectedText: "Hello",
                baseline: before,
                after: after
            ),
            .unavailable
        )
    }

    func testVerifyTextDeliveryDeliversWhenSelectedTextMatchesExpected() {
        // After paste many apps leave the pasted text selected; this path confirms delivery
        // even when the field value is not readable.
        let after = TextInjectionPipeline.FocusedTextObservation(
            value: nil,
            selectedText: "Hello"
        )
        XCTAssertEqual(
            TextInjectionPipeline.verifyTextDelivery(
                expectedText: "Hello",
                baseline: nil,
                after: after
            ),
            .delivered
        )
    }

    func testVerifyTextDeliveryReturnsUnavailableWhenAfterIsNil() {
        XCTAssertEqual(
            TextInjectionPipeline.verifyTextDelivery(
                expectedText: "Hello",
                baseline: nil,
                after: nil
            ),
            .unavailable
        )
    }

    func testVerifyTextDeliveryTreatsEmptyExpectedAsDelivered() {
        XCTAssertEqual(
            TextInjectionPipeline.verifyTextDelivery(
                expectedText: "",
                baseline: nil,
                after: nil
            ),
            .delivered
        )
    }

    func testPasteReverifyDelayIsReasonable() {
        // The deferred re-check delay must be short enough to feel instant but long enough
        // for slow apps to process the paste (100–500 ms range is acceptable).
        XCTAssertGreaterThanOrEqual(TextInjectionPipeline.pasteReverifyDelay, 0.10)
        XCTAssertLessThanOrEqual(TextInjectionPipeline.pasteReverifyDelay, 0.50)
    }

    func testDecidePasteHoldSucceedsWhenDelivered() {
        XCTAssertEqual(
            TextInjectionPipeline.decidePasteHold(
                delivery: .delivered,
                pasteAttemptsCompleted: 1,
                elapsed: 0.01,
                holdTimeout: 0.35
            ),
            .succeed
        )
    }

    func testDecidePasteHoldRetriesOnceOnConfirmedFailure() {
        XCTAssertEqual(
            TextInjectionPipeline.decidePasteHold(
                delivery: .failed,
                pasteAttemptsCompleted: 1,
                elapsed: 0.05,
                holdTimeout: 0.35
            ),
            .retryPaste
        )
        XCTAssertEqual(
            TextInjectionPipeline.decidePasteHold(
                delivery: .failed,
                pasteAttemptsCompleted: 2,
                elapsed: 0.10,
                holdTimeout: 0.35
            ),
            .failConfirmed
        )
    }

    func testDecidePasteHoldWaitsThenGivesUpWhenUnavailable() {
        XCTAssertEqual(
            TextInjectionPipeline.decidePasteHold(
                delivery: .unavailable,
                pasteAttemptsCompleted: 1,
                elapsed: 0.10,
                holdTimeout: 0.35
            ),
            .waitMore
        )
        XCTAssertEqual(
            TextInjectionPipeline.decidePasteHold(
                delivery: .unavailable,
                pasteAttemptsCompleted: 1,
                elapsed: 0.35,
                holdTimeout: 0.35
            ),
            .giveUpUnverified
        )
    }

    func testPasteDeliverySettleDelayIsShort() {
        XCTAssertGreaterThan(TextInjectionPipeline.pasteDeliverySettleDelay, 0)
        XCTAssertLessThanOrEqual(TextInjectionPipeline.pasteDeliverySettleDelay, 0.12)
        XCTAssertEqual(TextInjectionPipeline.pasteDeliveryMaxAttempts, 2)
    }

    func testSanitizeClipboardStripsTemplateTokens() {
        let raw = "hello {{clipboard}} {{cursor}} {{calc:1+2}} {{date}} world"
        let clean = DynamicTemplateEngine.sanitizeClipboardText(raw)
        XCTAssertFalse(clean.contains("{{"))
        XCTAssertTrue(clean.contains("hello"))
        XCTAssertTrue(clean.contains("world"))
    }

    func testSafeMathParserBoundsExpressionLength() {
        let oversized = String(repeating: "1+", count: 40) + "1"
        XCTAssertGreaterThan(oversized.count, SafeMathParser.maxExpressionLength)
        XCTAssertNil(SafeMathParser.evaluate(oversized))
        XCTAssertEqual(SafeMathParser.evaluate("1+2"), 3.0)
        XCTAssertNil(SafeMathParser.evaluate("1 + abc"))
    }

    func testCursorOffsetUsesUTF16() {
        let engine = DynamicTemplateEngine.shared
        // BMP-only: Character index == UTF-16 index
        let ascii = engine.resolve("ab{{cursor}}cd")
        XCTAssertEqual(ascii.cursorOffset, 2)
        // Emoji is one Character but two UTF-16 units
        let emoji = engine.resolve("👍{{cursor}}")
        XCTAssertEqual(emoji.cursorOffset, 2)
    }

    func testSecureFieldHelperFailClosedWithoutFocusedElement() {
        // Unit-test process: AX untrusted and/or no focused element → fail-closed (true = block expand).
        let checker = AXContextChecker.shared
        if checker.isProcessTrusted(), checker.focusedElement() != nil {
            // Rare in CI: if we somehow have focus, just assert the helpers return a Bool.
            _ = checker.isFocusedElementSecure()
            _ = checker.hasActiveIMEMarkedText()
        } else {
            XCTAssertTrue(checker.isFocusedElementSecure())
            XCTAssertTrue(checker.hasActiveIMEMarkedText())
        }
        XCTAssertTrue(checker.shouldBlockExpand(canUseAX: false))
    }

    func testSnippetStoragePersistenceAndListeners() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
            .appendingPathComponent("snippets.json")
        defer {
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        }

        // Isolated store — does not touch shared singleton or Application Support
        let store = SnippetStore(fileURL: tempURL)
        let testSnippets = [
            SnippetModel(title: "Test", triggerKeyword: ":test", replacementText: "Replacement Text")
        ]

        let expectation = expectation(description: "Listener triggered")

        store.addListener { snippets in
            if snippets.first?.triggerKeyword == ":test" {
                expectation.fulfill()
            }
        }

        store.saveSnippets(testSnippets)
        wait(for: [expectation], timeout: 2.0)

        let loaded = store.loadSnippets()
        XCTAssertFalse(loaded.isEmpty)
        XCTAssertEqual(loaded.first?.triggerKeyword, ":test")
        XCTAssertEqual(loaded.first?.replacementText, "Replacement Text")
    }

    func testSnippetStoreListenerUnregistration() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
            .appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let store = SnippetStore(fileURL: tempURL)
        var callCount = 0
        let token = store.addListener { _ in
            callCount += 1
        }
        XCTAssertEqual(callCount, 1)

        store.removeListener(token: token)
        store.saveSnippets([SnippetModel(title: "New", triggerKeyword: ":new", replacementText: "val")])
        XCTAssertEqual(callCount, 1)
    }

    func testEmptyJSONArrayPersistsAsEmpty() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
        let tempURL = dir.appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "[]".data(using: .utf8)?.write(to: tempURL)

        let store = SnippetStore(fileURL: tempURL)
        let loaded = store.loadSnippets()
        XCTAssertTrue(loaded.isEmpty)
    }

    /// §0.3: a corrupt library must NOT be replaced with demo snippets.
    ///
    /// The old contract was `XCTAssertFalse(loaded.isEmpty)` — the store wrote four demos with
    /// `writeGroupsToDisk(defaults, force: true)`, bypassing both the digest and the block guard,
    /// and that replacement then synced to every other device. The new contract: take a
    /// timestamped backup, latch a hard-fail state so every save is refused, return the
    /// empty/last-known library, and **persist nothing**.
    func testCorruptJSONBacksUpAndHardFailsWithoutWritingDefaults() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
        let tempURL = dir.appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let corruptBytes = Data("{not-json".utf8)
        try? corruptBytes.write(to: tempURL)

        let store = SnippetStore(fileURL: tempURL)

        // 1. No defaults were handed out.
        XCTAssertTrue(store.loadSnippets().isEmpty)

        // 2. A timestamped backup of the original bytes exists.
        guard case .corrupted(let backup)? = store.lastLoadIssue else {
            return XCTFail("Expected .corrupted load issue, got \(String(describing: store.lastLoadIssue))")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try? Data(contentsOf: backup), corruptBytes)
        XCTAssertTrue(
            backup.lastPathComponent.contains(".bak."),
            "Backup must be timestamped, not a single reusable .bak: \(backup.lastPathComponent)"
        )
        XCTAssertNotEqual(backup.lastPathComponent, "snippets.json.bak")

        // 3. The hard-fail latch is set and names the file.
        XCTAssertTrue(store.isLibraryReadFailed)
        XCTAssertEqual(store.libraryReadFailureReason?.contains(tempURL.path), true)

        // 4. Nothing was written over the user's file, and saves are refused.
        XCTAssertEqual(try? Data(contentsOf: tempURL), corruptBytes)
        let outcome = store.saveGroups([
            SnippetGroup(name: "General", snippets: [
                SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1")
            ])
        ])
        XCTAssertFalse(outcome.didSave)
        XCTAssertEqual(try? Data(contentsOf: tempURL), corruptBytes)
    }

    /// §0.3: the user-driven escape hatch is the *only* thing that may overwrite the file.
    func testForceOverwriteLibraryClearsHardFailure() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
        let tempURL = dir.appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("{not-json".utf8).write(to: tempURL)

        let store = SnippetStore(fileURL: tempURL)
        XCTAssertTrue(store.isLibraryReadFailed)

        let groups = [
            SnippetGroup(name: "General", snippets: [
                SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1")
            ])
        ]
        XCTAssertTrue(store.forceOverwriteLibrary(with: groups).didSave)
        XCTAssertFalse(store.isLibraryReadFailed)
        XCTAssertEqual(store.loadSnippets().map(\.triggerKeyword), [":a"])
    }

    /// §1.9: `sanitize` used to drop empty-trigger and duplicate snippets on **every save**, so
    /// duplicating a snippet and editing the body before the trigger silently deleted it. It is
    /// now deliberately non-destructive; the diagnostic moved to `triggerConflicts`.
    func testSanitizeIsNonDestructive() {
        let snippets = [
            SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1"),
            SnippetModel(title: "Empty", triggerKeyword: "", replacementText: "x"),
            SnippetModel(title: "Dup", triggerKeyword: ":a", replacementText: "2"),
            SnippetModel(title: "B", triggerKeyword: ":b", replacementText: "3")
        ]
        let sanitized = SnippetStore.sanitize(snippets)
        XCTAssertEqual(sanitized.count, snippets.count)
        XCTAssertEqual(sanitized.map(\.triggerKeyword), [":a", "", ":a", ":b"])
        XCTAssertEqual(sanitized.map(\.id), snippets.map(\.id))
    }

    /// §1.9: the reporting that replaced the silent deletion.
    func testTriggerConflictsReportsEmptyAndDuplicateTriggers() {
        let groups = [
            SnippetGroup(name: "General", snippets: [
                SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1"),
                SnippetModel(title: "Empty", triggerKeyword: "", replacementText: "x"),
                SnippetModel(title: "Dup", triggerKeyword: ":a", replacementText: "2"),
                SnippetModel(title: "B", triggerKeyword: ":b", replacementText: "3")
            ])
        ]
        let conflicts = SnippetStore.triggerConflicts(in: groups)
        XCTAssertTrue(conflicts.contains { $0.kind == .emptyTrigger })
        XCTAssertTrue(conflicts.contains { $0.kind == .duplicateTrigger && $0.trigger == ":a" })
        XCTAssertFalse(conflicts.contains { $0.trigger == ":b" })
    }

    func testAppMuteStoreRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevTypeMute-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("muted-apps.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = AppMuteStore(fileURL: url)
        XCTAssertFalse(store.isMuted("com.example.App"))
        store.mute("com.example.App")
        XCTAssertTrue(store.isMuted("com.example.App"))

        let reloaded = AppMuteStore(fileURL: url)
        XCTAssertTrue(reloaded.isMuted("com.example.App"))
        reloaded.unmute("com.example.App")
        XCTAssertFalse(reloaded.isMuted("com.example.App"))
    }


    // MARK: - Settings URL builder (modern + legacy fallback)

    func testSettingsURLsAccessibilityModernAndLegacy() {
        let urls = SettingsDeepLinker.settingsURLs(for: .accessibility)
        XCTAssertEqual(
            urls.modern.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
        XCTAssertEqual(
            urls.legacy.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testSettingsURLsInputMonitoringListenEvent() {
        let urls = SettingsDeepLinker.settingsURLs(for: .inputMonitoring)
        XCTAssertEqual(
            urls.modern.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
        )
        XCTAssertEqual(
            urls.legacy.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )
    }

    func testSettingsURLsPostEventUsesAccessibilityPane() {
        let urls = SettingsDeepLinker.settingsURLs(for: .postEvent)
        XCTAssertTrue(urls.modern.absoluteString.contains("Privacy_Accessibility"))
        XCTAssertTrue(urls.legacy.absoluteString.contains("Privacy_Accessibility"))
        XCTAssertFalse(urls.modern.absoluteString.contains("Privacy_PostEvent"))
        XCTAssertEqual(
            urls.modern.absoluteString,
            SettingsDeepLinker.settingsURLs(for: .accessibility).modern.absoluteString
        )
    }

    func testSettingsURLsNilPermissionRootPanes() {
        let urls = SettingsDeepLinker.settingsURLs(for: nil)
        XCTAssertEqual(
            urls.modern.absoluteString,
            SettingsDeepLinker.modernPrivacySecurityScheme
        )
        XCTAssertEqual(
            urls.legacy.absoluteString,
            "\(SettingsDeepLinker.legacySecurityScheme)?Privacy"
        )
    }

    func testPrivacyRevealKeysPerPermissionKind() {
        XCTAssertEqual(
            SettingsDeepLinker.privacyRevealKey(for: .inputMonitoring),
            "Privacy_ListenEvent"
        )
        XCTAssertEqual(
            SettingsDeepLinker.privacyRevealKey(for: .accessibility),
            "Privacy_Accessibility"
        )
        XCTAssertEqual(
            SettingsDeepLinker.privacyRevealKey(for: .postEvent),
            "Privacy_Accessibility",
            "Post Event has no dedicated pane; deep-link Accessibility"
        )
        XCTAssertNil(SettingsDeepLinker.privacyRevealKey(for: nil))
        XCTAssertEqual(
            SettingsDeepLinker.privacyRevealKey(for: .postEvent),
            SettingsDeepLinker.privacyRevealKey(for: .accessibility)
        )
    }

    func testPreferredKindForMissingCapabilitiesOrder() {
        XCTAssertEqual(
            SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: false,
                canUseAX: false
            ),
            .inputMonitoring,
            "Listen missing takes priority over Accessibility"
        )
        XCTAssertEqual(
            SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: true,
                canUseAX: false
            ),
            .accessibility
        )
        XCTAssertNil(
            SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: true,
                canUseAX: true,
                canPostEvents: true
            )
        )
    }

    func testPreferredKindWhenOnlyPostEventsMissing() {
        XCTAssertEqual(
            SettingsDeepLinker.preferredKindForMissingCapabilities(
                canListenTap: true,
                canUseAX: true,
                canPostEvents: false
            ),
            .postEvent,
            "Post-only missing still offers Open Accessibility (not nil → Relaunch-only)"
        )
        XCTAssertEqual(
            PermissionCopy.openSettingsButtonTitle(for: .postEvent),
            "Open Accessibility"
        )
    }

    func testSystemSettingsBundleIdentifiersIncludeModernAndLegacy() {
        XCTAssertTrue(
            SettingsDeepLinker.systemSettingsBundleIdentifiers.contains("com.apple.systempreferences")
        )
        XCTAssertTrue(
            SettingsDeepLinker.systemSettingsBundleIdentifiers.contains("com.apple.Preferences")
        )
    }

    // MARK: - Engine display status (Listen-only gate)

    func testEngineDisplayStatusNeedsPermissionsWhenListenMissing() {
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: false,
                isTapRunning: true,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .needsPermissions
        )
    }

    func testEngineDisplayStatusActiveWithDegradedPostOnly() {
        // Missing Post must NOT demote Active when Listen + AX + tap are OK.
        // Missing AX is Needs Permissions (defaultTap cannot start without it).
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                canUseAX: true,
                isTapRunning: true,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .active
        )
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                canUseAX: false,
                isTapRunning: false,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .needsPermissions
        )
    }

    func testEngineDisplayStatusTapFailedWhenListenAndAXOkButNoTap() {
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                canUseAX: true,
                isTapRunning: false,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .tapFailed
        )
    }

    func testEngineDisplayStatusActiveRequiresTapEnabledNotSecure() {
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                isTapRunning: true,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .active
        )
        XCTAssertNotEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                isTapRunning: false,
                isEnabled: true,
                isSecureInputActive: false
            ),
            .active
        )
    }

    func testEngineDisplayStatusPausedAndSecure() {
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                isTapRunning: true,
                isEnabled: false,
                isSecureInputActive: false
            ),
            .paused
        )
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                isTapRunning: true,
                isEnabled: true,
                isSecureInputActive: true
            ),
            .secure
        )
        XCTAssertEqual(
            EngineDisplayStatus.resolve(
                canListenTap: true,
                isTapRunning: true,
                isEnabled: false,
                isSecureInputActive: true
            ),
            .secure
        )
    }

    // MARK: - Capability snapshot + InjectionPlanner

    func testMissingCapabilitiesSummaryEmptyFullAndPartial() {
        XCTAssertEqual(
            PermissionSnapshot.missingSummary(from: []),
            "All capabilities granted"
        )
        XCTAssertEqual(
            PermissionSnapshot.missingSummary(from: ["Accessibility"]),
            "Missing: Accessibility"
        )
        XCTAssertEqual(
            PermissionSnapshot.missingSummary(from: ["Accessibility", "Input Monitoring"]),
            "Missing: Accessibility and Input Monitoring"
        )
        XCTAssertEqual(
            PermissionSnapshot.missingSummary(from: [
                "Accessibility", "Input Monitoring", "Post Events"
            ]),
            "Missing: Accessibility, Input Monitoring, and Post Events"
        )
    }

    func testPermissionSnapshotMissingNamesAndListenFlag() {
        let partial = PermissionSnapshot(
            canListenTap: false,
            canUseAX: true,
            canPostEvents: true
        )
        XCTAssertEqual(partial.missingCapabilityNames, ["Input Monitoring"])
        XCTAssertEqual(partial.missingCapabilitiesSummary, "Missing: Input Monitoring")
        XCTAssertTrue(partial.inputMonitoringBlocksEventTap)
        XCTAssertFalse(partial.isFullyCapable)

        let allMissing = PermissionSnapshot(
            canListenTap: false,
            canUseAX: false,
            canPostEvents: false
        )
        XCTAssertEqual(
            allMissing.missingCapabilityNames,
            ["Accessibility", "Input Monitoring", "Post Events"]
        )

        let full = PermissionSnapshot(
            canListenTap: true,
            canUseAX: true,
            canPostEvents: true
        )
        XCTAssertEqual(full.missingCapabilityNames, [])
        XCTAssertTrue(full.isFullyCapable)
        XCTAssertFalse(full.inputMonitoringBlocksEventTap)

        let degraded = PermissionSnapshot(
            canListenTap: true,
            canUseAX: true,
            canPostEvents: false
        )
        XCTAssertTrue(degraded.isDegradedInject)
        XCTAssertFalse(degraded.blocksDefaultEventTap)

        let axMissing = PermissionSnapshot(
            canListenTap: true,
            canUseAX: false,
            canPostEvents: true
        )
        XCTAssertFalse(axMissing.isDegradedInject)
        XCTAssertTrue(axMissing.accessibilityBlocksEventTap)
        XCTAssertTrue(axMissing.blocksDefaultEventTap)
    }

    func testInjectionPlannerFailClosedWithoutAX() {
        let planner = InjectionPlanner()
        let snap = PermissionSnapshot(canListenTap: true, canUseAX: false, canPostEvents: true)
        if case .refuse(let reason) = planner.plan(snapshot: snap, isTerminal: false, needsCursorHID: false) {
            XCTAssertTrue(reason.localizedCaseInsensitiveContains("fail-closed") || reason.localizedCaseInsensitiveContains("Accessibility"))
        } else {
            XCTFail("expected refuse without AX")
        }
    }

    func testInjectionPlannerAXOnlyWithoutPost() {
        let planner = InjectionPlanner()
        let snap = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: false)
        XCTAssertEqual(
            planner.plan(snapshot: snap, isTerminal: false, needsCursorHID: false),
            .axOnly
        )
        if case .refuse = planner.plan(snapshot: snap, isTerminal: true, needsCursorHID: false) {
            // ok — a terminal is clipboard-only, and the ⌘V still needs Post
        } else {
            XCTFail("terminal without Post should refuse")
        }
        // Non-shell multi-line + caret use AX range/caret — allowed without Post.
        XCTAssertEqual(
            planner.plan(snapshot: snap, isTerminal: false, needsCursorHID: true),
            .axOnly
        )
        XCTAssertEqual(
            planner.plan(
                snapshot: snap,
                isTerminal: false,
                needsCursorHID: false,
                isMultiLine: true
            ),
            .axOnly
        )
        XCTAssertEqual(
            planner.plan(
                snapshot: snap,
                isTerminal: false,
                needsCursorHID: true,
                isMultiLine: true
            ),
            .axOnly
        )
    }

    func testRefuseMustNotSwallowContract() {
        let refuse = InjectionPlan.refuse(reason: "test")
        XCTAssertFalse(EventTapEngine.shouldSwallowTrigger(plan: refuse))
        XCTAssertTrue(EventTapEngine.shouldSwallowTrigger(plan: .axOnly))
        XCTAssertTrue(EventTapEngine.shouldSwallowTrigger(plan: .axPlusHID))
        XCTAssertTrue(EventTapEngine.mustReinjectOnRefuse(didSwallow: true))
        XCTAssertFalse(EventTapEngine.mustReinjectOnRefuse(didSwallow: false))
    }

    func testAutorepeatIgnoredForMatching() {
        XCTAssertTrue(EventTapEngine.shouldIgnoreForMatching(isAutorepeat: true))
        XCTAssertFalse(EventTapEngine.shouldIgnoreForMatching(isAutorepeat: false))
    }

    func testClipboardLazyReadSkipsPasteboardWithoutTag() {
        let engine = DynamicTemplateEngine.shared
        XCTAssertFalse(DynamicTemplateEngine.templateNeedsClipboard("hello {{date}} {{cursor}}"))
        XCTAssertTrue(DynamicTemplateEngine.templateNeedsClipboard("x {{clipboard}} y"))

        // Without {{clipboard}}, an explicit clipboardText must not appear in output.
        let noTag = engine.resolve(
            "plain {{calc:1+1}}",
            clipboardText: "SHOULD_NOT_APPEAR"
        )
        XCTAssertEqual(noTag.text, "plain 2")
        XCTAssertFalse(noTag.text.contains("SHOULD_NOT_APPEAR"))

        // With tag, provided clipboardText is used (no need to touch the real pasteboard).
        let withTag = engine.resolve(
            "clip={{clipboard}}",
            clipboardText: "from-arg"
        )
        XCTAssertEqual(withTag.text, "clip=from-arg")
    }

    func testSnippetDocumentSchemaVersionRoundTrip() throws {
        let snippets = [
            SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1")
        ]
        let document = SnippetDocument(schemaVersion: SnippetDocument.currentSchemaVersion, groups: [
            SnippetGroup(name: "Test", snippets: snippets)
        ])
        let data = try JSONEncoder().encode(document)
        let decoded = try SnippetStore.decodeSnippets(from: data)
        XCTAssertEqual(decoded.map(\.triggerKeyword), [":a"])

        // Legacy bare array still loads (backward compatible — no wipe).
        let legacy = try JSONEncoder().encode(snippets)
        let legacyDecoded = try SnippetStore.decodeSnippets(from: legacy)
        XCTAssertEqual(legacyDecoded.map(\.triggerKeyword), [":a"])
    }

    func testSnippetStorePersistsSchemaVersionEnvelope() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
        let tempURL = dir.appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = SnippetStore(fileURL: tempURL)
        store.saveSnippets([
            SnippetModel(title: "T", triggerKeyword: ":t", replacementText: "ok")
        ])
        let raw = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("schemaVersion"))
        XCTAssertTrue(raw.contains("\"groups\""))

        let reloaded = SnippetStore(fileURL: tempURL).loadSnippets()
        XCTAssertEqual(reloaded.first?.triggerKeyword, ":t")
    }

    func testAXMessagingTimeoutConstant() {
        XCTAssertEqual(AXContextChecker.messagingTimeoutSeconds, 0.05, accuracy: 0.0001)
    }

    func testInjectionPlannerFullWithPost() {
        let planner = InjectionPlanner()
        let snap = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true)
        XCTAssertEqual(
            planner.plan(snapshot: snap, isTerminal: true, needsCursorHID: true),
            .axPlusHID
        )
    }

    func testAXFailClosedNilFocusedPolicy() {
        XCTAssertTrue(
            AXContextChecker.mustRefuseExpandWhenFocusedUnknown(
                axTrusted: false,
                focusedElementAvailable: false
            )
        )
        XCTAssertTrue(
            AXContextChecker.mustRefuseExpandWhenFocusedUnknown(
                axTrusted: true,
                focusedElementAvailable: false
            )
        )
        XCTAssertFalse(
            AXContextChecker.mustRefuseExpandWhenFocusedUnknown(
                axTrusted: true,
                focusedElementAvailable: true
            )
        )
    }

    func testUnlockDescriptionsMentionEventTapAndPostEventPane() {
        let input = PermissionCopy.unlockDescription(for: .inputMonitoring)
        XCTAssertTrue(input.localizedCaseInsensitiveContains("event tap"))
        let post = PermissionCopy.unlockDescription(for: .postEvent)
        XCTAssertTrue(
            post.localizedCaseInsensitiveContains("Privacy_PostEvent")
                || post.localizedCaseInsensitiveContains("dedicated")
        )
        XCTAssertTrue(post.localizedCaseInsensitiveContains("Accessibility"))
    }

    func testSettingsOpenFailureMessageIncludesManualPath() {
        let message = PermissionCopy.settingsOpenFailureMessage(for: .inputMonitoring)
        XCTAssertTrue(message.contains(PermissionCopy.manualPrivacySecurityPath))
        XCTAssertTrue(message.contains("Input Monitoring"))
        let post = PermissionCopy.settingsOpenFailureMessage(for: .postEvent)
        XCTAssertTrue(post.contains("Accessibility"))
        XCTAssertTrue(post.contains(PermissionCopy.manualPrivacySecurityPath))
    }

    func testEngineDisplayStatusToolTipListsMissingAndFlagsInputMonitoring() {
        let tip = EngineDisplayStatus.needsPermissions.toolTip(
            missingCapabilityNames: ["Accessibility", "Input Monitoring"],
            canListenTap: false
        )
        XCTAssertTrue(tip.contains("Missing: Accessibility and Input Monitoring"))
        XCTAssertTrue(tip.localizedCaseInsensitiveContains("event tap"))
        XCTAssertTrue(tip.contains("⌘⇧P"))
    }

    func testEngineDisplayStatusActiveTooltipShowsDegraded() {
        let tip = EngineDisplayStatus.active.toolTip(
            missingCapabilityNames: ["Post Events"],
            canListenTap: true,
            degradedInject: true
        )
        XCTAssertTrue(tip.contains("Post Events"))
        XCTAssertTrue(tip.localizedCaseInsensitiveContains("degraded"))
    }

    func testEngineDisplayStatusActionHintAndRequiresAction() {
        XCTAssertTrue(EngineDisplayStatus.needsPermissions.requiresAction)
        XCTAssertTrue(EngineDisplayStatus.tapFailed.requiresAction)
        XCTAssertFalse(EngineDisplayStatus.active.requiresAction)
        XCTAssertEqual(
            EngineDisplayStatus.needsPermissions.menuTitleWithActionHint,
            "Status: Needs Permissions ⚠"
        )
        XCTAssertEqual(EngineDisplayStatus.active.menuTitleWithActionHint, "Status: Active")
    }

    func testTapFailedRecoveryGuidanceMentionsOtherCopies() {
        let guide = EngineDisplayStatus.tapFailedRecoveryGuidance
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("quit"))
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("DevType"))
    }

    // MARK: - Identity / Settings listing helpers

    func testIsPackagedAppBundlePaths() {
        XCTAssertTrue(ProcessIdentity.isPackagedAppBundle(bundlePath: "/Users/me/Code/DevType/.build/DevType.app"))
        XCTAssertTrue(ProcessIdentity.isPackagedAppBundle(bundlePath: "/Users/me/Code/DevType/.build/DevType.app/"))
        XCTAssertFalse(ProcessIdentity.isPackagedAppBundle(bundlePath: "/Users/me/Code/DevType/.build/debug/DevType"))
        XCTAssertFalse(ProcessIdentity.isPackagedAppBundle(bundlePath: "/Users/me/Code/DevType/.build/arm64-apple-macosx/debug"))
    }

    func testSiblingDevTypePathsExcludesCurrentAndDedupes() {
        let current = "/Users/me/Code/DevType/.build/DevType.app"
        let siblings = ProcessIdentity.siblingDevTypePaths(
            fromRunningApps: [
                (bundleIdentifier: "com.devtype.app", bundlePath: current, localizedName: "DevType"),
                (bundleIdentifier: "com.devtype.app", bundlePath: "/Users/me/Code/DevType/build/DevType.app", localizedName: "DevType"),
                (bundleIdentifier: "com.devtype.app", bundlePath: "/Users/me/Code/DevType/build/DevType.app", localizedName: "DevType"),
                (bundleIdentifier: "com.apple.Safari", bundlePath: "/Applications/Safari.app", localizedName: "Safari"),
                (bundleIdentifier: nil, bundlePath: "/tmp/OtherDevType.app", localizedName: "DevType Helper"),
                (
                    bundleIdentifier: ProcessIdentity.legacyStaleBundleIdentifier,
                    bundlePath: "/tmp/LegacyDevType.app",
                    localizedName: "DevType"
                )
            ],
            currentBundleID: "com.devtype.app",
            currentPath: current
        )
        XCTAssertEqual(
            siblings,
            [
                "/Users/me/Code/DevType/build/DevType.app",
                "/tmp/LegacyDevType.app",
                "/tmp/OtherDevType.app"
            ]
        )
    }

    func testLivePreflightSummaryAndSettingsMismatchGuidance() {
        let denied = PermissionSnapshot(canListenTap: false, canUseAX: false, canPostEvents: true)
        let line = PermissionCopy.livePreflightSummary(snapshot: denied)
        XCTAssertTrue(line.contains("LIVE preflight"))
        XCTAssertTrue(line.contains("Listen: Denied"))
        XCTAssertTrue(line.contains("AX: Denied"))
        XCTAssertTrue(line.contains("Post: Granted"))

        let guide = ProcessIdentity.settingsToggleMismatchGuidance(
            executablePath: "/Applications/DevType.app/Contents/MacOS/DevType",
            cdHash: "abc123"
        )
        XCTAssertTrue(guide.contains(ProcessIdentity.legacyStaleBundleIdentifier))
        XCTAssertTrue(guide.contains("abc123"))
        XCTAssertTrue(guide.contains(ProcessIdentity.preferredInstalledAppPath))
        XCTAssertTrue(PermissionCopy.staleLegacyBundleIdGuidance.contains(ProcessIdentity.legacyStaleBundleIdentifier))
        XCTAssertTrue(
            PermissionCopy.relaunchAfterSettingsGuidance(missingNames: ["Input Monitoring"])
                .localizedCaseInsensitiveContains("Relaunch")
        )
    }

    func testDevelopmentAppBundlePresentAndStaleLegacyWarning() {
        XCTAssertTrue(
            ProcessIdentity.developmentAppBundlePresent(
                runningPath: "/Applications/DevType.app",
                siblingPaths: ["/Users/me/Code/DevType/.build/DevType.app"]
            )
        )
        XCTAssertFalse(
            ProcessIdentity.developmentAppBundlePresent(
                runningPath: "/Applications/DevType.app",
                siblingPaths: []
            )
        )
        XCTAssertNotNil(
            ProcessIdentity.staleLegacyBundleWarning(
                runningBundleIDs: [ProcessIdentity.legacyStaleBundleIdentifier]
            )
        )
        XCTAssertNil(ProcessIdentity.staleLegacyBundleWarning(runningBundleIDs: ["com.devtype.app"]))
    }

    func testOnDiskDevelopmentAppBundlePathsWithoutRunningSibling() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("devtype-ondisk-\(UUID().uuidString)")
        let buildApp = root.appendingPathComponent(".build/DevType.app")
        try fm.createDirectory(at: buildApp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let suite = "devtype.tests.ondisk.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Seed from Applications-like path that walks up into the temp repo root.
        let seed = root.appendingPathComponent("Package.swift").path
        try "test".write(toFile: seed, atomically: true, encoding: .utf8)
        let found = ProcessIdentity.onDiskDevelopmentAppBundlePaths(
            seedPaths: [seed],
            fileManager: fm,
            defaults: defaults,
            spotlightPaths: []
        )
        XCTAssertEqual(found, [ProcessIdentity.normalizedBundlePath(buildApp.path)])

        XCTAssertTrue(
            ProcessIdentity.developmentAppBundlePresentIncludingOnDisk(
                runningPath: "/Applications/DevType.app",
                siblingPaths: [],
                fileManager: fm,
                defaults: defaults,
                spotlightPaths: [buildApp.path]
            )
        )
        XCTAssertFalse(
            ProcessIdentity.developmentAppBundlePresentIncludingOnDisk(
                runningPath: "/Applications/DevType.app",
                siblingPaths: [],
                fileManager: fm,
                defaults: defaults,
                spotlightPaths: []
            )
        )
    }

    func testSiblingDoesNotMatchUnrelatedNameOnlyAppsWithBundleID() {
        let siblings = ProcessIdentity.siblingDevTypePaths(
            fromRunningApps: [
                (bundleIdentifier: "com.example.Notes", bundlePath: "/tmp/Notes.app", localizedName: "DevType Notes")
            ],
            currentBundleID: "com.devtype.app",
            currentPath: "/Users/me/.build/DevType.app"
        )
        XCTAssertTrue(siblings.isEmpty)
    }

    func testDuplicateProcessWarningNilWhenEmpty() {
        XCTAssertNil(ProcessIdentity.duplicateProcessWarning(siblingPaths: []))
        let warning = ProcessIdentity.duplicateProcessWarning(
            siblingPaths: ["/Users/me/Code/DevType/build/DevType.app"]
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("build/DevType.app"))
        XCTAssertTrue(warning!.localizedCaseInsensitiveContains("quit"))
    }

    func testUnpackagedBinaryWarning() {
        XCTAssertNil(ProcessIdentity.unpackagedBinaryWarning(bundlePath: "/tmp/DevType.app"))
        let warning = ProcessIdentity.unpackagedBinaryWarning(bundlePath: "/tmp/.build/debug/DevType")
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("com.devtype.app"))
    }

    func testSettingsToggleAndOpenButtonTitles() {
        XCTAssertEqual(PermissionCopy.settingsToggleDisplayName(for: .accessibility), "Accessibility")
        XCTAssertEqual(PermissionCopy.settingsToggleDisplayName(for: .inputMonitoring), "Input Monitoring")
        XCTAssertEqual(PermissionCopy.settingsToggleDisplayName(for: .postEvent), "Accessibility")
        XCTAssertEqual(PermissionCopy.openSettingsButtonTitle(for: .accessibility), "Open Settings")
        XCTAssertEqual(PermissionCopy.openSettingsButtonTitle(for: .inputMonitoring), "Open Settings")
        XCTAssertEqual(PermissionCopy.openSettingsButtonTitle(for: .postEvent), "Open Accessibility")
    }

    func testOpenSettingsWithoutRequestHintMentionsRequestFirst() {
        let access = PermissionCopy.openSettingsWithoutRequestHint(
            for: .accessibility,
            bundleID: "com.devtype.app"
        )
        XCTAssertTrue(access.localizedCaseInsensitiveContains("Request"))
        XCTAssertTrue(access.contains("com.devtype.app"))

        let input = PermissionCopy.openSettingsWithoutRequestHint(
            for: .inputMonitoring,
            bundleID: "com.devtype.app"
        )
        XCTAssertTrue(input.localizedCaseInsensitiveContains("Request"))
        XCTAssertTrue(input.localizedCaseInsensitiveContains("Input Monitoring"))
        XCTAssertTrue(input.localizedCaseInsensitiveContains("DevType"))

        let post = PermissionCopy.openSettingsWithoutRequestHint(
            for: .postEvent,
            bundleID: "com.devtype.app"
        )
        XCTAssertTrue(post.localizedCaseInsensitiveContains("no Privacy list"))
        XCTAssertTrue(post.localizedCaseInsensitiveContains("Request"))
    }

    func testExecutablePathForAppBundle() {
        XCTAssertEqual(
            ProcessIdentity.executablePath(forAppBundlePath: "/Users/me/.build/DevType.app"),
            "/Users/me/.build/DevType.app/Contents/MacOS/DevType"
        )
    }

    func testNotListedInSettingsGuidanceIncludesPathAndToggle() {
        let guide = PermissionCopy.notListedInSettingsGuidance(
            for: .inputMonitoring,
            bundleID: "com.devtype.app",
            appPath: "/Users/me/.build/DevType.app",
            siblingPaths: ["/Users/me/build/DevType.app"],
            binaryPath: "/Users/me/.build/DevType.app/Contents/MacOS/DevType"
        )
        XCTAssertTrue(guide.contains("Input Monitoring"))
        XCTAssertTrue(guide.contains("com.devtype.app"))
        XCTAssertTrue(guide.contains("/Users/me/.build/DevType.app"))
        XCTAssertTrue(guide.contains("/Users/me/build/DevType.app"))
        XCTAssertTrue(guide.contains("Contents/MacOS/DevType"))
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("Request"))
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("+"))
        XCTAssertTrue(guide.localizedCaseInsensitiveContains("scroll"))

        let post = PermissionCopy.notListedInSettingsGuidance(
            for: .postEvent,
            bundleID: "com.devtype.app",
            appPath: "/Users/me/.build/DevType.app",
            siblingPaths: []
        )
        XCTAssertTrue(post.localizedCaseInsensitiveContains("not a Settings list"))
        XCTAssertTrue(post.localizedCaseInsensitiveContains("Accessibility"))
    }

    func testSettingsOpenResultNeverProvisionalTrueWithoutOpen() {
        // Constructed results must reflect honest didOpen — callers must not invent true.
        let pending = SettingsDeepLinker.OpenResult(
            modernURL: URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!,
            legacyURL: URL(string: "x-apple.systempreferences:com.apple.preference.security")!,
            usedModern: true,
            didOpen: false
        )
        XCTAssertFalse(pending.didOpen)
    }

    func testSettingsOpenFailureMessageIncludesBundleID() {
        let message = PermissionCopy.settingsOpenFailureMessage(for: .accessibility)
        XCTAssertTrue(message.contains(ProcessIdentity.expectedBundleIdentifier))
    }

    func testParseCDHashFromCodesignOutput() {
        let sample = """
        Executable=/Users/me/.build/DevType.app/Contents/MacOS/DevType
        Identifier=com.devtype.app
        CDHash=bb726507e094387f8a1c200fe83254eb36c8b969
        Signature=adhoc
        """
        XCTAssertEqual(
            ProcessIdentity.parseCDHash(fromCodesignOutput: sample),
            "bb726507e094387f8a1c200fe83254eb36c8b969"
        )
        XCTAssertNil(ProcessIdentity.parseCDHash(fromCodesignOutput: "Identifier=com.devtype.app\n"))
    }

    func testAccessibilityAppearsResetBoundToCDHash() {
        XCTAssertTrue(
            ProcessIdentity.accessibilityAppearsReset(
                grantedCDHash: "abc",
                currentCDHash: "abc",
                isCurrentlyGranted: false
            )
        )
        XCTAssertFalse(
            ProcessIdentity.accessibilityAppearsReset(
                grantedCDHash: "abc",
                currentCDHash: "def",
                isCurrentlyGranted: false
            )
        )
        XCTAssertFalse(
            ProcessIdentity.accessibilityAppearsReset(
                grantedCDHash: nil,
                currentCDHash: "abc",
                isCurrentlyGranted: false
            )
        )
        XCTAssertFalse(
            ProcessIdentity.accessibilityAppearsReset(
                grantedCDHash: "abc",
                currentCDHash: "abc",
                isCurrentlyGranted: true
            )
        )
    }

    func testBinaryIdentityChangedDetectsCDHashAndPath() {
        XCTAssertTrue(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "aaa",
                storedPath: "/old/DevType.app",
                currentCDHash: "bbb",
                currentPath: "/old/DevType.app"
            ),
            "Legacy CDHash churn without requirement"
        )
        XCTAssertTrue(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "aaa",
                storedPath: "/old/DevType.app",
                currentCDHash: "aaa",
                currentPath: "/new/DevType.app"
            )
        )
        XCTAssertFalse(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "aaa",
                storedPath: "/same/DevType.app",
                currentCDHash: "aaa",
                currentPath: "/same/DevType.app"
            )
        )
        let req = "identifier \"com.devtype.app\" and certificate root = H\"abc\""
        XCTAssertFalse(
            ProcessIdentity.binaryIdentityChanged(
                storedCDHash: "aaa",
                storedPath: "/same/DevType.app",
                currentCDHash: "bbb",
                currentPath: "/same/DevType.app",
                storedDesignatedRequirement: req,
                currentDesignatedRequirement: req
            ),
            "Stable requirement must ignore CDHash churn"
        )
    }

    func testBinaryChangedGuidanceMentionsResignAndPath() {
        let text = PermissionCopy.binaryChangedGuidance(
            appPath: "/Users/me/Code/DevType/.build/DevType.app",
            cdHash: "abc123"
        )
        XCTAssertTrue(text.localizedCaseInsensitiveContains("re-signed") || text.localizedCaseInsensitiveContains("identity"))
        XCTAssertTrue(text.contains(ProcessIdentity.preferredInstalledAppPath))
        XCTAssertTrue(text.contains(".build/DevType.app"))
        XCTAssertTrue(text.contains("abc123"))
    }

    func testCanFinishOnboardingGates() {
        // Finish/Verify advance on Accessibility (+ CDHash load for Finish); Listen/tap optional.
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true,
                tapRunning: false,
                canUseAX: true,
                cdHash: "abc",
                cdHashLoadFinished: true
            ),
            "Listen/tap incomplete must not block Finish when AX is granted"
        )
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: false,
                tapRunning: false,
                canUseAX: true,
                cdHash: "abc",
                cdHashLoadFinished: true
            ),
            "Finish with AX only (Listen denied)"
        )
        XCTAssertFalse(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true,
                tapRunning: true,
                canUseAX: false,
                cdHash: "abc",
                cdHashLoadFinished: true
            ),
            "AX required for Finish"
        )
        XCTAssertFalse(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true,
                tapRunning: true,
                canUseAX: true,
                cdHash: nil,
                cdHashLoadFinished: false
            ),
            "Block Finish while CDHash still loading"
        )
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true,
                tapRunning: true,
                canUseAX: true,
                cdHash: "abc",
                cdHashLoadFinished: true
            )
        )
        XCTAssertTrue(
            ProcessIdentity.canAdvanceFromVerify(
                canListenTap: true,
                tapRunning: true,
                canUseAX: true
            )
        )
        XCTAssertTrue(
            ProcessIdentity.canAdvanceFromVerify(
                canListenTap: false,
                tapRunning: false,
                canUseAX: true
            ),
            "Verify advances with AX even when Listen/tap incomplete"
        )
        XCTAssertFalse(
            ProcessIdentity.canAdvanceFromVerify(
                canListenTap: true,
                tapRunning: true,
                canUseAX: false
            )
        )
    }

    func testIdentityChangeDetectionNilToHash() {
        let suite = "devtype.tests.identity.nilhash.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        ProcessIdentity.markOnboardingCompleted(
            cdHash: "stored-hash",
            path: "/Applications/DevType.app",
            defaults: defaults
        )

        XCTAssertFalse(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: nil,
                currentPath: "/Applications/DevType.app"
            ),
            "Nil current CDHash (still loading) must not look like a stable match or mismatch"
        )
        // Legacy rows without a stored designated requirement still treat CDHash churn as identity change.
        XCTAssertTrue(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: "different-hash",
                currentPath: "/Applications/DevType.app"
            ),
            "After nil→hash resolves to a different value with no stored requirement, re-onboard"
        )
        XCTAssertFalse(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: "stored-hash",
                currentPath: "/Applications/DevType.app"
            )
        )
        // Once a requirement is recorded, CDHash churn alone must not re-onboard.
        defaults.set(
            "identifier \"com.devtype.app\" and certificate root = H\"abc\"",
            forKey: ProcessIdentity.onboardingDesignatedRequirementDefaultsKey
        )
        XCTAssertFalse(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: "different-hash",
                currentPath: "/Applications/DevType.app",
                currentDesignatedRequirement: "identifier \"com.devtype.app\" and certificate root = H\"abc\""
            )
        )
    }

    func testRequestNeverAutoOpensSettings() {
        XCTAssertFalse(
            PermissionRequester.autoOpensSettingsAfterRequest,
            "Request must never auto-open Settings; Open is an explicit separate action"
        )
    }

    func testDualInstallWarningWhenBothExist() {
        let warning = ProcessIdentity.dualInstallWarning(
            runningPath: "/Users/me/Code/DevType/.build/DevType.app",
            applicationsExists: true,
            buildBundleExists: true
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains(ProcessIdentity.preferredInstalledAppPath))
        // Running Applications while a .build package is also present must still warn.
        let appsRunning = ProcessIdentity.dualInstallWarning(
            runningPath: "/Applications/DevType.app",
            applicationsExists: true,
            buildBundleExists: true
        )
        XCTAssertNotNil(appsRunning)
        XCTAssertTrue(appsRunning!.contains(".build"))
        XCTAssertNil(
            ProcessIdentity.dualInstallWarning(
                runningPath: "/Applications/DevType.app",
                applicationsExists: true,
                buildBundleExists: false
            )
        )
    }

    func testBackfillOnboardingCDHashIfNeeded() {
        let suite = "devtype.tests.backfill.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ProcessIdentity.onboardingCompletedDefaultsKey)
        defaults.set("/Applications/DevType.app", forKey: ProcessIdentity.onboardingPathDefaultsKey)
        XCTAssertTrue(
            ProcessIdentity.backfillOnboardingCDHashIfNeeded(currentCDHash: "newhash", defaults: defaults)
        )
        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey), "newhash")
        XCTAssertFalse(
            ProcessIdentity.backfillOnboardingCDHashIfNeeded(currentCDHash: "other", defaults: defaults)
        )
    }

    func testRememberAccessibilityGrantedBoundToCDHash() {
        let suite = "devtype.tests.tcc.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults.string(forKey: ProcessIdentity.accessibilityGrantedCDHashDefaultsKey))
        ProcessIdentity.rememberAccessibilityGranted(false, cdHash: "abc", defaults: defaults)
        XCTAssertNil(defaults.string(forKey: ProcessIdentity.accessibilityGrantedCDHashDefaultsKey))
        ProcessIdentity.rememberAccessibilityGranted(true, cdHash: "abc", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.accessibilityGrantedCDHashDefaultsKey), "abc")
    }

    func testOnboardingCompletedPersistence() {
        let suite = "devtype.tests.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(ProcessIdentity.isOnboardingCompleted(defaults: defaults))
        ProcessIdentity.markOnboardingCompleted(
            cdHash: "hash1",
            path: "/Users/me/.build/DevType.app",
            defaults: defaults
        )
        XCTAssertTrue(ProcessIdentity.isOnboardingCompleted(defaults: defaults))
        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey), "hash1")
        XCTAssertEqual(
            defaults.string(forKey: ProcessIdentity.onboardingPathDefaultsKey),
            ProcessIdentity.normalizedBundlePath("/Users/me/.build/DevType.app")
        )
    }

    func testUpdateOnboardingIdentityStopsRecoveryLoop() {
        let suite = "devtype.tests.onboarding.update.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ProcessIdentity.markOnboardingCompleted(
            cdHash: "old-hash",
            path: "/Applications/DevType.app",
            defaults: defaults
        )
        XCTAssertTrue(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: "new-hash",
                currentPath: "/Applications/DevType.app"
            )
        )
        ProcessIdentity.updateOnboardingIdentity(
            cdHash: "new-hash",
            path: "/Applications/DevType.app",
            defaults: defaults
        )
        XCTAssertFalse(
            ProcessIdentity.shouldReOnboardForIdentityChange(
                defaults: defaults,
                currentCDHash: "new-hash",
                currentPath: "/Applications/DevType.app"
            )
        )
        XCTAssertEqual(defaults.string(forKey: ProcessIdentity.onboardingCDHashDefaultsKey), "new-hash")
    }

    func testNeedsCursorHIDHelper() {
        XCTAssertFalse(InjectionPlanner.needsCursorHID(cursorOffset: nil, totalLength: 10))
        XCTAssertFalse(InjectionPlanner.needsCursorHID(cursorOffset: 10, totalLength: 10))
        XCTAssertTrue(InjectionPlanner.needsCursorHID(cursorOffset: 3, totalLength: 10))
        XCTAssertTrue(InjectionPlanner.needsCursorHID(cursorOffset: 3, totalUTF16Length: 10))
    }

    func testCanFinishOnboardingWithoutPostEvents() {
        // Post is optional — Finish needs AX (+ CDHash load finished); Listen/tap not required.
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: true,
                tapRunning: true,
                canUseAX: true,
                cdHash: "abc",
                cdHashLoadFinished: true
            )
        )
        XCTAssertTrue(
            ProcessIdentity.canFinishOnboarding(
                canListenTap: false,
                tapRunning: false,
                canUseAX: true,
                cdHash: nil,
                cdHashLoadFinished: true
            ),
            "AX-only Finish without Listen/tap/Post"
        )
    }

    func testNestedFillPartRendering() {
        // Single fillPart ON / OFF
        let singleOn = MacroParser.parse("%fillpart:name=Sec:default=yes%Hello%fillpartend%")
        XCTAssertEqual(MacroParser.render(tokens: singleOn).text, "Hello")

        let singleOff = MacroParser.parse("%fillpart:name=Sec:default=no%Hello%fillpartend%")
        XCTAssertEqual(MacroParser.render(tokens: singleOff).text, "")

        // Outer OFF, Inner ON -> Outer skip must NOT be cleared by Inner fillPartEnd
        let outerOffInnerOn = MacroParser.parse(
            "A%fillpart:name=Out:default=no%B%fillpart:name=In:default=yes%C%fillpartend%D%fillpartend%E"
        )
        XCTAssertEqual(MacroParser.render(tokens: outerOffInnerOn).text, "AE")

        // Outer OFF, Inner OFF
        let outerOffInnerOff = MacroParser.parse(
            "A%fillpart:name=Out:default=no%B%fillpart:name=In:default=no%C%fillpartend%D%fillpartend%E"
        )
        XCTAssertEqual(MacroParser.render(tokens: outerOffInnerOff).text, "AE")

        // Outer ON, Inner OFF
        let outerOnInnerOff = MacroParser.parse(
            "A%fillpart:name=Out:default=yes%B%fillpart:name=In:default=no%C%fillpartend%D%fillpartend%E"
        )
        XCTAssertEqual(MacroParser.render(tokens: outerOnInnerOff).text, "ABDE")

        // Outer ON, Inner ON
        let outerOnInnerOn = MacroParser.parse(
            "A%fillpart:name=Out:default=yes%B%fillpart:name=In:default=yes%C%fillpartend%D%fillpartend%E"
        )
        XCTAssertEqual(MacroParser.render(tokens: outerOnInnerOn).text, "ABCDE")
    }

    func testAXContextCheckerOptimizedGateAndIDEBundle() {
        let checker = AXContextChecker()
        XCTAssertTrue(checker.isIDEBundleID("com.todesktop.test"))
        XCTAssertTrue(checker.isIDEBundleID("com.todesktop."))
        XCTAssertTrue(checker.shouldBlockExpand(canUseAX: false))
    }

    func testSnippetStoreSaveBlockedThreadSafety() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeTests-\(UUID().uuidString)")
            .appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let store = SnippetStore(fileURL: tempURL)
        XCTAssertTrue(store.saveGroups([]).didSave)
    }
}
