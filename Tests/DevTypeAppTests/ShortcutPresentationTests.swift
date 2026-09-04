import AppKit
import Carbon
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

@MainActor
final class ShortcutPresentationTests: XCTestCase {
    private var savedDefaults: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in [HotkeyPreferences.inlineSearchKey, HotkeyPreferences.aiPaletteKey, HotkeyPreferences.voiceKey] {
            savedDefaults[key] = defaults.object(forKey: key)
        }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for (key, value) in savedDefaults {
            if let value { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testShortcutKeyCapsFollowCanonicalModifierOrder() {
        let shortcut = DevTypeShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)
        )

        XCTAssertEqual(shortcut.keyCaps, ["⌃", "⌥", "⇧", "⌘", "K"])
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘K")
    }

    func testHomeShowsConfiguredShortcutsAndRefreshesAfterPreferenceChange() {
        _ = NSApplication.shared
        HotkeyPreferences.inlineSearchShortcut = DevTypeShortcut(
            keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(controlKey | optionKey)
        )
        HotkeyPreferences.aiPaletteShortcut = DevTypeShortcut(
            keyCode: UInt32(kVK_ANSI_K), carbonModifiers: UInt32(cmdKey | shiftKey)
        )
        HotkeyPreferences.voiceShortcut = DevTypeShortcut(
            keyCode: UInt32(kVK_F8), carbonModifiers: UInt32(controlKey)
        )
        let controller = HomeViewController(engine: EventTapEngine())
        let labels = descendants(of: controller.view).compactMap { $0 as? NSTextField }

        XCTAssertTrue(labels.contains { $0.stringValue == "⌃ ⌥ J" })
        XCTAssertTrue(labels.contains { $0.stringValue == "⇧ ⌘ K" })
        XCTAssertTrue(labels.contains { $0.stringValue == "⌃ F8" })

        HotkeyPreferences.voiceShortcut = DevTypeShortcut(
            keyCode: UInt32(kVK_ANSI_B), carbonModifiers: UInt32(optionKey | cmdKey)
        )
        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)

        XCTAssertTrue(labels.contains { $0.stringValue == "⌥ ⌘ B" })
        XCTAssertFalse(labels.contains { $0.stringValue == "⌃ F8" })
    }

    func testReferenceCatalogUsesConfiguredGlobalShortcuts() {
        let search = DevTypeShortcut(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(controlKey))
        let ai = DevTypeShortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey))
        let voice = DevTypeShortcut(keyCode: UInt32(kVK_F9), carbonModifiers: UInt32(cmdKey))

        let entries = ShortcutReferenceCatalog.make(
            loc: .shared,
            inlineSearch: search,
            aiPalette: ai,
            voice: voice
        )

        XCTAssertEqual(Array(entries.prefix(3).map(\.keyCaps)), [search.keyCaps, ai.keyCaps, voice.keyCaps])
        XCTAssertFalse(entries.contains { $0.note == "Prefix query with >" })
        XCTAssertFalse(entries.contains { $0.note == "Click HUD" })
        XCTAssertFalse(entries.contains { $0.note == "Insert dynamic macro" })
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
