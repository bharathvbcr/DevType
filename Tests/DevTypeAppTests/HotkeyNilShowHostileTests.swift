import AppKit
import Carbon.HIToolbox
import XCTest
@testable import DevTypeAppCore

/// Attacks the nil-manager retain fix: repeated nil shows, a later replacement,
/// a truly nil first open, and a commit hook that must stand in for `apply`
/// without reaching Carbon.
@MainActor
final class HotkeyNilShowHostileTests: XCTestCase {
    private var controller: PreferencesWindowController?
    private var defaultsGuards: [DefaultsGuard] = []

    override func setUp() {
        super.setUp()
        XCTAssertNil(
            HotkeyBindingApply.commitApplyHook,
            "commitApplyHook must be nil at the start; a sloppy test left it set"
        )
    }

    override func tearDown() {
        HotkeyBindingApply.commitApplyHook = nil
        for guard_ in defaultsGuards { guard_.restore() }
        defaultsGuards.removeAll()
        controller?.window?.close()
        controller = nil
        super.tearDown()
    }

    private func openPreferences() -> PreferencesWindowController {
        _ = NSApplication.shared
        let controller = PreferencesWindowController()
        self.controller = controller
        return controller
    }

    private func preferences(
        of controller: PreferencesWindowController
    ) throws -> PreferencesViewController {
        try XCTUnwrap(controller.window?.contentViewController as? PreferencesViewController)
    }

    private func child<T: NSViewController>(
        _ type: T.Type,
        of controller: PreferencesWindowController
    ) throws -> T {
        try XCTUnwrap(preferences(of: controller).children.compactMap { $0 as? T }.first)
    }

    /// Drops the manager the panes are showing so the next `show` must write it back.
    /// A skipped refresh, or a refresh with nil, leaves the nil in place.
    private func poisonPanes(
        hotkeys: HotkeysPreferencesViewController,
        voice: VoicePreferencesViewController,
        ai: AIPreferencesViewController?
    ) {
        hotkeys.hotkeyManager = nil
        voice.hotkeyManager = nil
        ai?.hotkeyManager = nil
    }

    private func isolate(_ kind: BuiltInHotkey) -> DefaultsGuard {
        let guard_ = DefaultsGuard(kind)
        defaultsGuards.append(guard_)
        UserDefaults.standard.removeObject(forKey: kind.defaultsKey)
        return guard_
    }

    private func chord(_ keyCode: Int, _ modifiers: UInt32) -> DevTypeShortcut {
        DevTypeShortcut(keyCode: UInt32(keyCode), carbonModifiers: modifiers)
    }

    func testRepeatedNilShowKeepsIdentityAndRefreshesPreferencesWithThatManager() throws {
        let installed = HotkeyManager()
        let controller = openPreferences()
        controller.show(tab: .hotkeys, hotkeyManager: installed)
        let prefs = try preferences(of: controller)
        controller.show(tab: .voice, hotkeyManager: installed)
        let ai: AIPreferencesViewController?
        if PreferencesTab.visibleCases.contains(.ai) {
            controller.show(tab: .ai, hotkeyManager: installed)
            ai = try child(AIPreferencesViewController.self, of: controller)
        } else {
            ai = nil
        }
        let hotkeys = try child(HotkeysPreferencesViewController.self, of: controller)
        let voice = try child(VoicePreferencesViewController.self, of: controller)

        poisonPanes(hotkeys: hotkeys, voice: voice, ai: ai)
        controller.window?.close()
        controller.show(tab: .hotkeys, hotkeyManager: nil)
        XCTAssertTrue(controller.hotkeyManager === installed)
        XCTAssertTrue(controller.window?.contentViewController === prefs)
        XCTAssertTrue(hotkeys.hotkeyManager === installed, "first nil show refreshed the hotkeys pane with nil")
        XCTAssertTrue(voice.hotkeyManager === installed, "first nil show refreshed voice with nil")
        XCTAssertTrue(ai.map { $0.hotkeyManager === installed } ?? true, "first nil show refreshed AI with nil")

        poisonPanes(hotkeys: hotkeys, voice: voice, ai: ai)
        controller.show(tab: .voice, hotkeyManager: nil)
        XCTAssertTrue(controller.hotkeyManager === installed)
        XCTAssertTrue(controller.window?.contentViewController === prefs)
        XCTAssertTrue(hotkeys.hotkeyManager === installed, "second nil show refreshed the hotkeys pane with nil")
        XCTAssertTrue(voice.hotkeyManager === installed, "second nil show refreshed voice with nil")
        XCTAssertTrue(ai.map { $0.hotkeyManager === installed } ?? true, "second nil show refreshed AI with nil")
    }

    func testLaterNonNilManagerReplacesTheFirstOnEveryRefreshedPane() throws {
        let first = HotkeyManager()
        let second = HotkeyManager()
        let controller = openPreferences()
        controller.show(tab: .hotkeys, hotkeyManager: first)
        controller.show(tab: .voice, hotkeyManager: nil)
        controller.show(tab: .hotkeys, hotkeyManager: nil)
        let hotkeys = try child(HotkeysPreferencesViewController.self, of: controller)
        let voice = try child(VoicePreferencesViewController.self, of: controller)
        XCTAssertTrue(controller.hotkeyManager === first)
        XCTAssertTrue(hotkeys.hotkeyManager === first)

        poisonPanes(hotkeys: hotkeys, voice: voice, ai: nil)
        controller.show(tab: nil, hotkeyManager: second)
        XCTAssertTrue(controller.hotkeyManager === second)
        XCTAssertFalse(controller.hotkeyManager === first)
        XCTAssertTrue(hotkeys.hotkeyManager === second, "replacement did not refresh the hotkeys pane")
        XCTAssertTrue(voice.hotkeyManager === second, "replacement did not refresh voice")
        XCTAssertFalse(hotkeys.hotkeyManager === first)
    }

    func testFirstNilOpenStoresNilAndCommitWritesDefaultsWithoutHook() throws {
        XCTAssertNil(HotkeyBindingApply.commitApplyHook)
        let controller = openPreferences()
        controller.show(tab: .hotkeys, hotkeyManager: nil)
        controller.show(tab: .hotkeys, hotkeyManager: nil)
        XCTAssertNil(controller.hotkeyManager)
        XCTAssertNil(try child(HotkeysPreferencesViewController.self, of: controller).hotkeyManager)

        let kind = BuiltInHotkey.voiceDictation
        let stored = isolate(kind)
        let shortcut = chord(kVK_F5, UInt32(cmdKey | shiftKey))
        var hooks = 0
        var reloads = 0
        defer { HotkeyBindingApply.commitApplyHook = nil }
        HotkeyBindingApply.commitApplyHook = { _, _ in
            hooks += 1
            return noErr
        }

        HotkeyBindingApply.commit(shortcut, kind: kind, manager: nil, reload: { reloads += 1 })

        XCTAssertEqual(hooks, 0, "nil manager must not take the apply hook")
        XCTAssertEqual(reloads, 1)
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: kind.defaultsKey))
        XCTAssertEqual(try JSONDecoder().decode(DevTypeShortcut.self, from: data), shortcut)
        stored.restore()
        XCTAssertEqual(UserDefaults.standard.data(forKey: kind.defaultsKey), stored.original)
    }

    func testCommitWithManagerCallsHookOnceAndDoesNotApply() throws {
        XCTAssertNil(HotkeyBindingApply.commitApplyHook)
        let installed = HotkeyManager()
        let untouched = chord(kVK_ANSI_Z, UInt32(optionKey))
        let committed = chord(kVK_F5, UInt32(cmdKey | controlKey))
        XCTAssertNotEqual(untouched, committed)
        installed.inlineSearchShortcut = untouched
        installed.aiPaletteShortcut = untouched
        installed.voiceShortcut = untouched

        let kind = BuiltInHotkey.inlineSearch
        let stored = isolate(kind)
        var hooks = 0
        var reloads = 0
        defer { HotkeyBindingApply.commitApplyHook = nil }
        HotkeyBindingApply.commitApplyHook = { received, receivedKind in
            hooks += 1
            XCTAssertEqual(received, committed)
            XCTAssertEqual(receivedKind, kind)
            return noErr
        }

        HotkeyBindingApply.commit(committed, kind: kind, manager: installed, reload: { reloads += 1 })

        XCTAssertEqual(hooks, 1, "non-nil commit must take the apply/registerAll branch once")
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(installed.inlineSearchShortcut, untouched, "manager.apply ran and would have reached registerAll")
        XCTAssertEqual(installed.aiPaletteShortcut, untouched)
        XCTAssertEqual(installed.voiceShortcut, untouched)
        XCTAssertEqual(UserDefaults.standard.data(forKey: kind.defaultsKey), stored.original)
    }

    func testNilShortcutDoesNotCallHookOrWriteDefaults() throws {
        XCTAssertNil(HotkeyBindingApply.commitApplyHook)
        let installed = HotkeyManager()
        let before = installed.inlineSearchShortcut
        let kind = BuiltInHotkey.inlineSearch
        let stored = isolate(kind)
        var hooks = 0
        var reloads = 0
        defer { HotkeyBindingApply.commitApplyHook = nil }
        HotkeyBindingApply.commitApplyHook = { _, _ in
            hooks += 1
            return noErr
        }

        HotkeyBindingApply.commit(nil, kind: kind, manager: installed, reload: { reloads += 1 })

        XCTAssertEqual(hooks, 0)
        XCTAssertEqual(reloads, 0)
        XCTAssertEqual(installed.inlineSearchShortcut, before)
        XCTAssertEqual(UserDefaults.standard.data(forKey: kind.defaultsKey), stored.original)
    }
}

private final class DefaultsGuard {
    let key: String
    let original: Data?

    init(_ kind: BuiltInHotkey) {
        key = kind.defaultsKey
        original = UserDefaults.standard.data(forKey: key)
    }

    func restore() {
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
