import AppKit
import Carbon.HIToolbox
import XCTest
@testable import DevTypeAppCore

/// Keyboard Shortcuts opens Preferences with a nil manager. That argument must not
/// drop a manager already installed, and a later non-nil manager must still replace it.
/// Rebind counts the `apply` / `registerAll` branch without calling Carbon.
@MainActor
final class HotkeyNilShowRetainTests: XCTestCase {
    private var controller: PreferencesWindowController?
    private var savedShortcut: Data?
    private var savedKind: BuiltInHotkey?

    override func tearDown() {
        HotkeyBindingApply.commitApplyHook = nil
        if let savedKind {
            if let savedShortcut {
                UserDefaults.standard.set(savedShortcut, forKey: savedKind.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: savedKind.defaultsKey)
            }
        }
        savedShortcut = nil
        savedKind = nil
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

    private func hotkeysPane(
        of controller: PreferencesWindowController
    ) throws -> HotkeysPreferencesViewController {
        let prefs = try XCTUnwrap(controller.window?.contentViewController as? PreferencesViewController)
        return try XCTUnwrap(
            prefs.children.compactMap { $0 as? HotkeysPreferencesViewController }.first
        )
    }

    /// Removes the stored shortcut so a defaults-only write is visible, and puts the original back.
    private func isolate(_ kind: BuiltInHotkey) {
        savedKind = kind
        savedShortcut = UserDefaults.standard.data(forKey: kind.defaultsKey)
        UserDefaults.standard.removeObject(forKey: kind.defaultsKey)
    }

    private func recordedShortcut() -> DevTypeShortcut {
        DevTypeShortcut(keyCode: UInt32(kVK_ANSI_J), carbonModifiers: UInt32(cmdKey | controlKey))
    }

    func testNilShowKeepsInstalledManagerAndRebindUsesApplyBranch() throws {
        let installed = HotkeyManager()
        let controller = openPreferences()
        controller.show(tab: .hotkeys, hotkeyManager: installed)
        controller.show(tab: .hotkeys, hotkeyManager: nil)

        XCTAssertTrue(controller.hotkeyManager === installed)
        let pane = try hotkeysPane(of: controller)
        XCTAssertTrue(pane.hotkeyManager === installed)

        isolate(.inlineSearch)
        var applyBranch = 0
        var defaultsBranchNotices = 0
        let token = NotificationCenter.default.addObserver(
            forName: .devTypePreferencesChanged,
            object: nil,
            queue: nil
        ) { _ in
            defaultsBranchNotices += 1
        }
        defer {
            NotificationCenter.default.removeObserver(token)
            HotkeyBindingApply.commitApplyHook = nil
        }
        HotkeyBindingApply.commitApplyHook = { _, _ in
            applyBranch += 1
            return noErr
        }

        HotkeyBindingApply.commit(
            recordedShortcut(),
            kind: .inlineSearch,
            manager: pane.hotkeyManager,
            reload: {}
        )

        XCTAssertEqual(applyBranch, 1, "rebind must take the branch that calls apply/registerAll")
        XCTAssertEqual(defaultsBranchNotices, 0, "defaults-only branch must not run")
        XCTAssertNil(
            UserDefaults.standard.data(forKey: BuiltInHotkey.inlineSearch.defaultsKey),
            "defaults-only branch writes the shortcut; the hooked apply branch does not"
        )
    }

    func testNonNilShowReplacesManagerInstalledAfterNil() throws {
        let first = HotkeyManager()
        let second = HotkeyManager()
        let controller = openPreferences()

        controller.show(tab: .hotkeys, hotkeyManager: nil)
        XCTAssertNil(controller.hotkeyManager)

        controller.show(tab: .hotkeys, hotkeyManager: first)
        XCTAssertTrue(controller.hotkeyManager === first)
        XCTAssertTrue(try hotkeysPane(of: controller).hotkeyManager === first)

        controller.show(tab: .hotkeys, hotkeyManager: nil)
        XCTAssertTrue(controller.hotkeyManager === first)

        controller.show(tab: .general, hotkeyManager: second)
        XCTAssertTrue(controller.hotkeyManager === second)
        XCTAssertTrue(try hotkeysPane(of: controller).hotkeyManager === second)
    }

    func testFirstNilShowStaysNilAndCommitWritesDefaults() throws {
        let controller = openPreferences()
        controller.show(tab: .hotkeys, hotkeyManager: nil)
        XCTAssertNil(controller.hotkeyManager)
        XCTAssertNil(try hotkeysPane(of: controller).hotkeyManager)

        isolate(.aiPalette)
        var applyBranch = 0
        defer { HotkeyBindingApply.commitApplyHook = nil }
        HotkeyBindingApply.commitApplyHook = { _, _ in
            applyBranch += 1
            return noErr
        }

        HotkeyBindingApply.commit(
            recordedShortcut(),
            kind: .aiPalette,
            manager: controller.hotkeyManager,
            reload: {}
        )

        XCTAssertEqual(applyBranch, 0, "a truly nil manager stays on the defaults-only branch")
        let stored = try XCTUnwrap(UserDefaults.standard.data(forKey: BuiltInHotkey.aiPalette.defaultsKey))
        let decoded = try JSONDecoder().decode(DevTypeShortcut.self, from: stored)
        XCTAssertEqual(decoded, recordedShortcut())
    }
}
