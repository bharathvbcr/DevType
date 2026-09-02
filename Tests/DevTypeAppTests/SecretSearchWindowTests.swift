import AppKit
import Carbon.HIToolbox
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// Opt in on a Mac with a WindowServer: these checks briefly show synthetic UI.
final class SecretSearchWindowTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEVTYPE_RUN_APPKIT_SMOKE"] == "1",
                          "Set DEVTYPE_RUN_APPKIT_SMOKE=1 for native window interaction")
        _ = NSApplication.shared
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func searchPanel(placeholder: String) throws -> NSPanel {
        // Let AppKit finish the 160 ms opening animation and activate the window
        // before converting row coordinates into native mouse events.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }.first { panel in
            guard panel.isVisible, let content = panel.contentView else { return false }
            return descendants(of: content).compactMap { $0 as? NSTextField }
                .contains { ($0.placeholderString ?? $0.placeholderAttributedString?.string) == placeholder }
        })
    }

    private final class PendingAuthenticator: BiometricAuthenticating {
        private(set) var evaluations = 0
        var completion: ((BiometricGate.Outcome) -> Void)?
        func availability() -> BiometricGate.Availability { .biometry("Touch ID") }
        func evaluate(reason: String, completion: @escaping (BiometricGate.Outcome) -> Void) {
            evaluations += 1
            self.completion = completion
        }
        func invalidate() { completion = nil }
        func finish(_ outcome: BiometricGate.Outcome) {
            let reply = completion
            completion = nil
            reply?(outcome)
        }
    }

    private func secretFixture() throws -> (store: SnippetStore, secrets: [SnippetModel], values: SecretStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "DevType.SecretSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            InlineSearchPanel.close()
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        let secrets = (0..<2).map { index in
            SnippetModel(title: "Synthetic secret \(index)", triggerKeyword: ";secret\(index)",
                         replacementText: "", updatedAt: Date(timeIntervalSince1970: Double(2 - index)), isSecret: true)
        }
        let values = SecretStore(backing: InMemorySecretBackingStore())
        for (index, secret) in secrets.enumerated() {
            try values.store("synthetic-password-\(index)", for: secret.id).get()
        }
        let file = directory.appendingPathComponent("snippets.json")
        try JSONEncoder().encode(SnippetDocument(snippets: secrets)).write(to: file)
        let store = SnippetStore(location: .init(fileURL: file, expectsExistingLibrary: true),
                                 deviceDefaults: defaults, localSupportDirectory: directory, secretStore: values)
        return (store, secrets, values)
    }

    private func click(_ table: NSTableView, row: Int, count: Int = 1) throws {
        table.scrollRowToVisible(row)
        table.layoutSubtreeIfNeeded()
        let rect = table.rect(ofRow: row)
        try click(table, at: NSPoint(x: rect.midX, y: rect.midY), count: count)
    }

    private func click(_ table: NSTableView, at point: NSPoint, count: Int = 1) throws {
        let window = try XCTUnwrap(table.window)
        let location = table.convert(point, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: count, pressure: 0
        ))
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(release)
        }
    }

    func testSingleClickReachesAuthenticationBeforeCopyingChosenSecret() throws {
        let fixture = try secretFixture()
        let auth = PendingAuthenticator()
        let gate = BiometricGate(authenticator: auth)
        let clipboard = SecretClipboard()
        let board = NSPasteboard(name: .init("DevType.SecretSelectionTests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setString("previous clipboard", forType: .string)
        var picked: UUID?
        var copied = false
        InlineSearchPanel.open(store: fixture.store, mode: .copySecrets) { pick, _, _ in
            guard case .snippet(let snippet) = pick else { return XCTFail("Unexpected command") }
            picked = snippet.id
            SecretMenuFlow.resolve(snippet, secretStore: fixture.values, gate: gate, preferenceEnabled: true) { result in
                guard case .success(let value) = result else { return XCTFail("Expected authorized copy") }
                copied = clipboard.copy(value, pasteboard: board, broker: nil, schedule: { _, _ in }) != nil
            }
        }
        let panel = try searchPanel(placeholder: LocalizationManager.shared.s("menu.searchSecrets.placeholder"))
        let table = try XCTUnwrap(descendants(of: try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(auth.evaluations, 0)
        let target = try XCTUnwrap(table.target)
        try click(table, row: 2)
        XCTAssertEqual(table.selectedRow, 2, "The real mouse event must reach the intended row")
        XCTAssertEqual(auth.evaluations, 1, "A single click must request authentication")
        XCTAssertEqual(picked, fixture.secrets[1].id)
        // Native double-click and delayed action delivery must not start a second read.
        XCTAssertTrue(table.sendAction(table.action, to: target))
        XCTAssertTrue(table.sendAction(table.doubleAction, to: target))
        XCTAssertEqual(auth.evaluations, 1)
        XCTAssertFalse(copied)
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
        auth.finish(.authorized)
        XCTAssertTrue(copied)
        XCTAssertEqual(board.string(forType: .string), "synthetic-password-1")
        XCTAssertNotNil(board.data(forType: PasteboardBroker.concealedType))
        XCTAssertFalse(InlineSearchPanel.isOpen)
    }

    func testCancelledOrFailedAuthenticationPreservesClipboard() throws {
        let fixture = try secretFixture()
        for outcome in [BiometricGate.Outcome.cancelled, .failed("Synthetic authentication failure")] {
            let auth = PendingAuthenticator()
            let gate = BiometricGate(authenticator: auth)
            let board = NSPasteboard(name: .init("DevType.SecretSelectionTests.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.setString("untouched clipboard", forType: .string)
            let originalChangeCount = board.changeCount
            let clipboard = SecretClipboard()
            var failure: SecretMenuFlow.ResolveFailure?
            InlineSearchPanel.open(store: fixture.store, mode: .copySecrets) { pick, _, _ in
                guard case .snippet(let snippet) = pick else { return XCTFail("Unexpected command") }
                SecretMenuFlow.resolve(snippet, secretStore: fixture.values, gate: gate, preferenceEnabled: true) { result in
                    switch result {
                    case .success(let text):
                        clipboard.copy(text, pasteboard: board, broker: nil, schedule: { _, _ in })
                    case .failure(let error): failure = error
                    }
                }
            }
            let panel = try searchPanel(placeholder: LocalizationManager.shared.s("menu.searchSecrets.placeholder"))
            let table = try XCTUnwrap(descendants(of: try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTableView }.first)
            try click(table, row: 1)
            XCTAssertEqual(auth.evaluations, 1)
            auth.finish(outcome)
            XCTAssertNotNil(failure)
            XCTAssertEqual(failure?.isSilent, outcome == .cancelled)
            XCTAssertEqual(board.changeCount, originalChangeCount)
            XCTAssertEqual(board.string(forType: .string), "untouched clipboard")
            XCTAssertFalse(clipboard.hasOutstandingSecret)
        }
    }

    func testCopyModesIgnoreNavigationHeadersBlankSpaceAndFilteringUntilExplicitCommit() throws {
        let fixture = try secretFixture()
        for mode in [InlineSearchPanel.Mode.copySecrets, .copy] {
            var selections = 0
            InlineSearchPanel.open(store: fixture.store, mode: mode) { _, _, _ in selections += 1 }
            let panel = try searchPanel(placeholder: LocalizationManager.shared.s(mode.placeholderKey))
            let views = descendants(of: try XCTUnwrap(panel.contentView))
            let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
            let search = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.isEditable })
            let selectable = (0..<table.numberOfRows).filter { table.delegate?.tableView?(table, shouldSelectRow: $0) == true }
            let firstRow = try XCTUnwrap(selectable.first)
            table.selectRowIndexes(IndexSet(integer: firstRow), byExtendingSelection: false)
            XCTAssertEqual(selections, 0, "Selection changes must not copy")
            try click(table, row: 0)
            XCTAssertEqual(selections, 0, "Headers must not commit the previous selection")
            search.stringValue = "no-matching-synthetic-secret-7c30"
            search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
            XCTAssertEqual(selections, 0, "Filtering must not commit")
            XCTAssertEqual(table.numberOfRows, 0)
            try click(table, at: NSPoint(x: table.bounds.midX, y: table.bounds.midY))
            XCTAssertEqual(selections, 0, "An empty result area must not copy the stale selection")
            XCTAssertTrue(InlineSearchPanel.isOpen)
            InlineSearchPanel.close()
        }
    }

    func testInsertModeSingleClickOnlySelectsAndDoubleClickCommitsClickedRow() throws {
        let fixture = try secretFixture()
        var selections = 0
        InlineSearchPanel.open(store: fixture.store, mode: .insert) { _, _, _ in selections += 1 }
        let panel = try searchPanel(placeholder: LocalizationManager.shared.s("search.placeholder"))
        let table = try XCTUnwrap(descendants(of: try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTableView }.first)
        let row = try XCTUnwrap((0..<table.numberOfRows).first { table.delegate?.tableView?(table, shouldSelectRow: $0) == true })
        try click(table, row: row)
        XCTAssertEqual(selections, 0)
        XCTAssertTrue(InlineSearchPanel.isOpen)
        try click(table, row: row, count: 2)
        XCTAssertEqual(selections, 1)
        XCTAssertFalse(InlineSearchPanel.isOpen)
    }

    func testKeyboardNavigationWaitsForReturnOrExplicitJumpShortcut() throws {
        let fixture = try secretFixture()
        for jump in [false, true] {
            var picked: UUID?
            InlineSearchPanel.open(store: fixture.store, mode: .copySecrets) { pick, _, _ in
                guard case .snippet(let snippet) = pick else { return XCTFail("Unexpected command") }
                picked = snippet.id
            }
            let panel = try searchPanel(placeholder: LocalizationManager.shared.s("menu.searchSecrets.placeholder"))
            let table = try XCTUnwrap(descendants(of: try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSTableView }.first)
            func key(_ code: Int, characters: String, flags: NSEvent.ModifierFlags = []) throws {
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
                ))
                NSApp.sendEvent(event)
            }
            try key(kVK_DownArrow, characters: "\u{F701}")
            XCTAssertNil(picked, "Arrow navigation must not copy")
            XCTAssertEqual(table.selectedRow, 2)
            if jump {
                try key(kVK_ANSI_1, characters: "1", flags: .command)
            } else {
                try key(kVK_Return, characters: "\r")
            }
            XCTAssertEqual(picked, fixture.secrets[jump ? 0 : 1].id)
            XCTAssertFalse(InlineSearchPanel.isOpen)
        }
    }

    func testExplicitSecretSearchReplacesPaletteAndReleasesSuspension() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "DevType.SecretSearchWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            InlineSearchPanel.close()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let secret = SnippetModel(title: "Synthetic secret", triggerKeyword: ";synthetic",
                                  replacementText: "", isSecret: true)
        let ordinary = SnippetModel(title: "Ordinary snippet", triggerKeyword: ";ordinary", replacementText: "Example")
        let file = directory.appendingPathComponent("snippets.json")
        try JSONEncoder().encode(SnippetDocument(snippets: [ordinary, secret])).write(to: file)
        let store = SnippetStore(location: .init(fileURL: file, expectsExistingLibrary: true),
                                 deviceDefaults: defaults, localSupportDirectory: directory)
        let baselineOwners = EventTapEngine.shared.matchingSuspensionOwners().count
        let loc = LocalizationManager.shared

        InlineSearchPanel.open(store: store, mode: .copy) { _, _, _ in XCTFail("Old callback fired") }
        let oldPanel = try searchPanel(placeholder: loc.s("menu.copySnippet"))
        var selected: UUID?
        for _ in 0..<5 {
            InlineSearchPanel.open(store: store, mode: .copySecrets) { pick, _, _ in
                guard case .snippet(let snippet) = pick else { return XCTFail("Secret search returned a command") }
                selected = snippet.id
            }
            XCTAssertTrue(InlineSearchPanel.isOpen)
            XCTAssertFalse(oldPanel.isVisible)
            XCTAssertEqual(EventTapEngine.shared.matchingSuspensionOwners().count, baselineOwners + 1)
        }
        let panel = try searchPanel(placeholder: loc.s("menu.searchSecrets.placeholder"))
        let content = try XCTUnwrap(panel.contentView)
        let table = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSTableView }.first)
        XCTAssertTrue(panel.firstResponder is NSTextView, "Typing must go directly to search")
        XCTAssertEqual(table.numberOfRows, 2, "One section header and only the synthetic secret")
        try click(table, row: 1)
        XCTAssertEqual(selected, secret.id)
        XCTAssertFalse(InlineSearchPanel.isOpen)
        XCTAssertEqual(EventTapEngine.shared.matchingSuspensionOwners().count, baselineOwners)

        try JSONEncoder().encode(SnippetDocument(snippets: [])).write(to: file)
        let emptyStore = SnippetStore(location: .init(fileURL: file, expectsExistingLibrary: true),
                                      deviceDefaults: defaults, localSupportDirectory: directory)
        InlineSearchPanel.open(store: emptyStore, mode: .copySecrets) { _, _, _ in XCTFail("Empty search selected a result") }
        let emptyPanel = try searchPanel(placeholder: loc.s("menu.searchSecrets.placeholder"))
        let emptyContent = try XCTUnwrap(emptyPanel.contentView)
        let emptyTable = try XCTUnwrap(descendants(of: emptyContent).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(emptyTable.numberOfRows, 0)
        InlineSearchPanel.close()
        XCTAssertEqual(EventTapEngine.shared.matchingSuspensionOwners().count, baselineOwners)
    }

    func testNativeStatusButtonDeliversSecondaryClick() throws {
        let item = NSStatusBar.system.statusItem(withLength: 30)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        button.title = "T"
        let window = try XCTUnwrap(button.window)
        let layoutDeadline = Date().addingTimeInterval(2)
        while window.frame.height < 1 && Date() < layoutDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertGreaterThan(window.frame.height, 0, "WindowServer must lay out the status item before event delivery")
        var searches = 0
        var menus = 0
        let interaction = StatusItemInteraction(
            button: button, offersCopySecret: { true },
            openSearchSecrets: { searches += 1 }, openMenu: { _ in menus += 1 }
        )
        let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func click(downType: NSEvent.EventType, upType: NSEvent.EventType, flags: NSEvent.ModifierFlags) throws {
            let down = try XCTUnwrap(NSEvent.mouseEvent(
                with: downType, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            let up = try XCTUnwrap(NSEvent.mouseEvent(
                with: upType, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
            ))
            NSApp.postEvent(up, atStart: true)
            NSApp.sendEvent(down)
            let releaseMask: NSEvent.EventTypeMask = upType == .rightMouseUp ? .rightMouseUp : .leftMouseUp
            if let release = NSApp.nextEvent(matching: releaseMask, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(release)
            }
        }
        try click(downType: .leftMouseDown, upType: .leftMouseUp, flags: [])
        XCTAssertEqual(searches, 1)
        XCTAssertEqual(menus, 0)
        try click(downType: .leftMouseDown, upType: .leftMouseUp, flags: .control)
        XCTAssertEqual(searches, 1)
        XCTAssertEqual(menus, 1)
        try click(downType: .rightMouseDown, upType: .rightMouseUp, flags: [])
        XCTAssertEqual(searches, 1)
        XCTAssertEqual(menus, 2)
        button.performClick(nil)
        withExtendedLifetime(interaction) {
            XCTAssertEqual(searches, 2, "A programmatic press must not replay the last secondary mouse event")
            XCTAssertEqual(menus, 2)
        }
    }
}
