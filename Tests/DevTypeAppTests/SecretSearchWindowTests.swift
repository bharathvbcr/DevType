import AppKit
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
        try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }.first { panel in
            guard panel.isVisible, let content = panel.contentView else { return false }
            return descendants(of: content).compactMap { $0 as? NSTextField }
                .contains { ($0.placeholderString ?? $0.placeholderAttributedString?.string) == placeholder }
        })
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
        XCTAssertTrue(table.sendAction(table.doubleAction, to: table.target))
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
