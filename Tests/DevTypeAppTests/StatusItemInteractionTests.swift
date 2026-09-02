import AppKit
import XCTest
@testable import DevTypeAppCore

final class StatusItemInteractionTests: XCTestCase {
    func testNativeButtonActionOpensSearchExactlyOnceAndNormalClickOpensMenu() {
        _ = NSApplication.shared
        let button = NSButton()
        var secure = true
        var searches = 0
        var menus = 0
        let interaction = StatusItemInteraction(
            button: button, offersCopySecret: { secure },
            openSearchSecrets: { searches += 1 },
            openMenu: { sender in
                XCTAssertTrue(sender === button)
                menus += 1
            }
        )
        XCTAssertTrue(button.target === interaction)
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseUp]
        // NSButton's cell reports its primary-button mask; secondary dispatch belongs
        // to NSStatusBarButton and is checked separately with native mouse events.
        let primaryEvents = button.sendAction(on: events)
        XCTAssertNotEqual(primaryEvents & Int(NSEvent.EventTypeMask.leftMouseDown.rawValue), 0)
        XCTAssertEqual(primaryEvents & Int(NSEvent.EventTypeMask.leftMouseUp.rawValue), 0)
        button.performClick(nil)
        XCTAssertEqual(searches, 1)
        XCTAssertEqual(menus, 0)
        secure = false
        button.performClick(nil)
        XCTAssertEqual(searches, 1)
        XCTAssertEqual(menus, 1)
    }

    func testSecondaryAndControlClickAlwaysOpenFullMenu() throws {
        _ = NSApplication.shared
        let button = NSButton()
        var secure = false
        var searches = 0
        var menus = 0
        let interaction = StatusItemInteraction(
            button: button, offersCopySecret: { secure },
            openSearchSecrets: { searches += 1 }, openMenu: { _ in menus += 1 }
        )
        for secureState in [true, false] {
            secure = secureState
            for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .rightMouseUp] {
                for flags in [NSEvent.ModifierFlags(), .control, [.control, .shift], .shift, .option, .command] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(
                        with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                    ))
                    let before = (searches, menus)
                    interaction.activate(button, event: event)
                    let expectsSearch = secureState && type == .leftMouseDown && !flags.contains(.control)
                    XCTAssertEqual(searches - before.0, expectsSearch ? 1 : 0)
                    XCTAssertEqual(menus - before.1, expectsSearch ? 0 : 1)
                }
            }
        }
        XCTAssertEqual(searches + menus, 36)
    }

    func testAccessibilityActivationAndRapidFocusChangesUseCurrentVisibleAction() {
        _ = NSApplication.shared
        let button = NSButton()
        var context = StatusItemContext()
        var searches = 0
        var menus = 0
        let interaction = StatusItemInteraction(
            button: button, offersCopySecret: { context.offersCopySecret },
            openSearchSecrets: { searches += 1 }, openMenu: { _ in menus += 1 }
        )
        for _ in 0..<1_000 {
            context.refresh(secureInputActive: true)
            interaction.activate(button, event: nil)
            context.refresh(secureInputActive: false)
            interaction.activate(button, event: nil)
        }
        XCTAssertEqual(searches, 1_000)
        XCTAssertEqual(menus, 1_000)
    }
}
