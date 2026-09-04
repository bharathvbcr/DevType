import AppKit
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

final class StatusItemPresentationTests: XCTestCase {
    private let snapshot = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true)

    private func presentation(
        display: EngineDisplayStatus = .secure,
        secure: Bool = true,
        highlighted: Bool = false
    ) -> StatusItemPresentation {
        StatusItemPresentation(
            display: display, snapshot: snapshot, isSecureInputActive: secure,
            urgentInject: false, libraryUnhealthy: false,
            differentiateWithoutColor: false, highlighted: highlighted
        )
    }

    func testAll1024CombinationsKeepCopyAvailableWithoutChangingEngineDiagnosis() {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        let copy = LocalizationManager.shared.s("menu.copySecret")
        var checked = 0
        for input in 0..<64 {
            let snapshot = PermissionSnapshot(
                canListenTap: input & 1 != 0, canUseAX: input & 2 != 0,
                canPostEvents: input & 4 != 0
            )
            let secure = input & 8 != 0
            let display = EngineDisplayStatus.resolve(
                snapshot: snapshot, isTapRunning: input & 16 != 0,
                isEnabled: input & 32 != 0, isSecureInputActive: secure
            )
            for options in 0..<16 {
                let urgent = options & 1 != 0
                let unhealthy = options & 2 != 0
                let differentiate = options & 4 != 0
                let subject = StatusItemPresentation(
                    display: display, snapshot: snapshot, isSecureInputActive: secure,
                    urgentInject: urgent, libraryUnhealthy: unhealthy,
                    differentiateWithoutColor: differentiate, highlighted: options & 8 != 0
                )
                let enginePresentation = EngineDisplayPresentation(
                    display: display,
                    snapshot: snapshot,
                    urgentInject: urgent
                )
                subject.apply(to: button)
                XCTAssertEqual(subject.offersCopySecret, secure)
                XCTAssertEqual(button.accessibilityRole(), secure ? .button : .menuButton)
                XCTAssertEqual(subject.needsAttention, display.requiresAction || urgent || snapshot.isDegradedInject)
                if secure {
                    XCTAssertEqual(button.title, " \(copy)")
                    XCTAssertEqual(button.imagePosition, .imageLeading)
                    XCTAssertEqual(button.accessibilityValue() as? String, copy)
                    XCTAssertTrue(button.image?.isTemplate == true)
                    XCTAssertTrue(button.toolTip?.contains("⌘V") == true)
                    XCTAssertFalse(button.toolTip?.contains("⌘/") == true)
                    XCTAssertTrue(button.accessibilityHelp()?.contains(copy) == true)
                    if display.requiresAction {
                        XCTAssertTrue(button.accessibilityHelp()?.contains(subject.statusName) == true)
                        XCTAssertTrue(button.toolTip?.contains(enginePresentation.toolTip) == true)
                    }
                } else {
                    XCTAssertNotEqual(button.accessibilityValue() as? String, copy)
                    let textRequired = differentiate || unhealthy || subject.needsAttention
                    XCTAssertEqual(button.title.isEmpty, !textRequired)
                    XCTAssertEqual(button.imagePosition, textRequired ? .imageLeading : .imageOnly)
                    XCTAssertEqual(button.toolTip, enginePresentation.toolTip)
                }
                checked += 1
            }
        }
        XCTAssertEqual(checked, 1024)
    }

    func testReusingButtonClearsSecretTitleAndHelpWhenFocusLeaves() {
        let button = NSButton()
        for _ in 0..<100 {
            presentation().apply(to: button)
            XCTAssertFalse(button.title.isEmpty)
            presentation(display: .active, secure: false).apply(to: button)
            XCTAssertEqual(button.title, "")
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertEqual(button.accessibilityValue() as? String, LocalizationManager.shared.s("status.active"))
            XCTAssertFalse(button.accessibilityHelp()?.contains("⌘V") == true)
            presentation(display: .paused, secure: false).apply(to: button)
            XCTAssertEqual(button.accessibilityValue() as? String, LocalizationManager.shared.s("status.paused"))
        }
    }

    func testMenuFocusChangesKeepTheClickedActionUntilClose() {
        var context = StatusItemContext()
        context.refresh(secureInputActive: true)
        context.openMenu(secureInputActive: false)
        for _ in 0..<10_000 {
            context.refresh(secureInputActive: false)
            XCTAssertTrue(context.offersCopySecret)
        }
        context.closeMenu(secureInputActive: false)
        XCTAssertFalse(context.offersCopySecret)
        XCTAssertFalse(context.menuIsOpen)
        context.openMenu(secureInputActive: false)
        XCTAssertFalse(context.offersCopySecret)
        context.refresh(secureInputActive: true)
        context.refresh(secureInputActive: false)
        XCTAssertTrue(context.offersCopySecret)
        context.closeMenu(secureInputActive: true)
        XCTAssertTrue(context.offersCopySecret)
        context.refresh(secureInputActive: false)
        XCTAssertFalse(context.offersCopySecret)
    }

    func testRapidClosedMenuTransitionsNeverKeepAStaleCopyPrompt() {
        var context = StatusItemContext()
        for _ in 0..<10_000 {
            context.refresh(secureInputActive: true)
            XCTAssertTrue(context.offersCopySecret)
            context.refresh(secureInputActive: false)
            XCTAssertFalse(context.offersCopySecret)
        }
    }

    func testIconsRenderInLightDarkAndHighlightedAppearances() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for highlighted in [false, true] {
                for secure in [false, true] {
                    let subject = presentation(display: secure ? .secure : .paused, secure: secure, highlighted: highlighted)
                    appearance.performAsCurrentDrawingAppearance {
                        XCTAssertNotNil(subject.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                    }
                }
            }
        }
    }
}
