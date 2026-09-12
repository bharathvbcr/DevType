import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

@MainActor
final class ExpansionUndoPreferencesTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testSwitchIsAccessiblePersistsAndReloadsItsActualValue() throws {
        _ = NSApplication.shared
        let previousLanguage = LocalizationManager.shared.language
        LocalizationManager.shared.language = .en
        defer { LocalizationManager.shared.language = previousLanguage }
        let pipeline = TextInjectionPipeline.shared
        let key = TextInjectionPipeline.expansionUndoEnabledDefaultsKey
        let original = UserDefaults.standard.object(forKey: key)
        let wasEnabled = pipeline.expansionUndoEnabled
        defer {
            pipeline.expansionUndoEnabled = wasEnabled
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        pipeline.expansionUndoEnabled = true
        let controller = PreferencesViewController(hotkeyManager: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 980, height: 760))
        defer { controller.viewWillDisappear(); window.close() }
        controller.select(.general)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(controller.view.bounds.height, 700)
        let title = LocalizationManager.shared.s("prefs.general.undo")
        let toggle = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSSwitch }
            .first { $0.accessibilityLabel() == title })
        XCTAssertEqual(toggle.state, .on)
        let action = try XCTUnwrap(toggle.action)
        toggle.state = .off
        XCTAssertTrue(NSApp.sendAction(action, to: toggle.target, from: toggle))
        XCTAssertFalse(pipeline.expansionUndoEnabled)
        controller.select(.home)
        controller.select(.general)
        XCTAssertEqual(toggle.state, .off)
        toggle.state = .on
        XCTAssertTrue(NSApp.sendAction(action, to: toggle.target, from: toggle))
        XCTAssertTrue(pipeline.expansionUndoEnabled)

        if let output = ProcessInfo.processInfo.environment["DEVTYPE_UNDO_QA_OUTPUT"] {
            controller.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output))
        }
    }

    func testEverySupportedLanguageExplainsTheSwitchAndItsScope() {
        for language in AppLanguage.concreteCases {
            let strings = LocalizationManager.stringTable(for: language)
            for key in ["prefs.general.typing", "prefs.general.undo", "prefs.general.undo.hint"] {
                XCTAssertFalse(strings[key]?.isEmpty ?? true, "Missing \(key) in \(language)")
            }
        }
    }
}
