import AppKit
import ExpanderEngine

/// The menu's copy affordance is independent of engine permission/pause diagnostics:
/// choosing a secret uses the existing authenticated clipboard path, not the event tap.
struct StatusItemPresentation {
    let statusName: String
    let statusColor: NSColor
    let needsAttention: Bool
    let offersCopySecret: Bool
    let title: String
    let image: NSImage
    let toolTip: String
    let accessibilityValue: String
    let accessibilityHelp: String
    private let accessibilityLabel: String

    init(
        display: EngineDisplayStatus,
        snapshot: PermissionSnapshot,
        isSecureInputActive: Bool,
        urgentInject: Bool,
        libraryUnhealthy: Bool,
        differentiateWithoutColor: Bool,
        highlighted: Bool,
        loc: LocalizationManager = .shared
    ) {
        let urgent = urgentInject || snapshot.isDegradedInject
        statusName = Self.statusName(for: display, urgent: urgentInject, loc: loc)
        statusColor = Self.statusColor(for: display, urgent: urgent)
        needsAttention = display.requiresAction || urgent
        offersCopySecret = isSecureInputActive
        accessibilityLabel = loc.s("ax.status.item")

        if offersCopySecret {
            let action = loc.s("menu.copySecret")
            title = " \(action)"
            // A template follows light/dark and selected menu appearances automatically.
            // The text remains usable even if the system cannot provide the key symbol.
            image = DevTypeTheme.menuIcon("key.fill", description: action)
                ?? DevTypeTheme.statusItemImage(badge: nil, highlighted: highlighted, accessibilityLabel: action)
            let help = loc.s("status.secure.copyHelp", action)
            toolTip = needsAttention ? "\(help)\n\(display.toolTip(snapshot: snapshot))" : help
            accessibilityValue = action
            accessibilityHelp = needsAttention ? "\(help) \(statusName)" : help
        } else {
            let kind = Self.statusKind(for: display)
            let quiet = display == .active && !urgent
            image = DevTypeTheme.statusItemImage(
                badge: quiet ? nil : (kind, statusColor),
                highlighted: highlighted,
                accessibilityLabel: statusName
            )
            let showsText = differentiateWithoutColor || needsAttention || libraryUnhealthy
            title = showsText ? " \(statusName)" : ""
            toolTip = display.toolTip(snapshot: snapshot)
            accessibilityValue = statusName
            accessibilityHelp = loc.s("ax.status.item.help", statusName)
        }
    }

    func apply(to button: NSButton) {
        assertMainThread()
        button.image = image
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = toolTip
        button.setAccessibilityRole(offersCopySecret ? .button : .menuButton)
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityValue(accessibilityValue)
        button.setAccessibilityHelp(accessibilityHelp)
    }

    private static func statusColor(for display: EngineDisplayStatus, urgent: Bool) -> NSColor {
        switch display {
        case .active:
            return urgent ? DevTypeTheme.statusOrange : DevTypeTheme.statusGreen
        case .secure:
            return DevTypeTheme.statusBlue
        case .paused:
            return DevTypeTheme.statusGray
        case .needsPermissions, .tapFailed:
            return DevTypeTheme.accent
        }
    }

    /// §5.2: five engine states used to map onto dot colours only.
    /// These three helpers add the non-colour channels: a glyph stamped into the
    /// badge, a localized name spoken by VoiceOver, and an optional text title
    /// beside the icon.
    private static func statusKind(for display: EngineDisplayStatus) -> EngineDisplayStatusKind {
        switch display {
        case .active: return .active
        case .secure: return .secure
        case .paused: return .paused
        case .needsPermissions: return .needsPermissions
        case .tapFailed: return .tapFailed
        }
    }

    private static func statusName(for display: EngineDisplayStatus, urgent: Bool, loc: LocalizationManager) -> String {
        if urgent, display == .active { return loc.s("status.injectIssue") }
        switch display {
        case .active: return loc.s("status.active")
        case .secure: return loc.s("status.secure")
        case .paused: return loc.s("status.paused")
        case .needsPermissions: return loc.s("status.needsPermissions")
        case .tapFailed: return loc.s("status.tapFailed")
        }
    }

}

/// Preserve the action the user clicked until menu tracking ends. Opening a menu
/// can itself make a password field resign focus and release Secure Input.
struct StatusItemContext {
    private(set) var menuIsOpen = false
    private(set) var offersCopySecret = false

    mutating func refresh(secureInputActive: Bool) {
        offersCopySecret = secureInputActive || (menuIsOpen && offersCopySecret)
    }

    mutating func openMenu(secureInputActive: Bool) {
        menuIsOpen = true
        refresh(secureInputActive: secureInputActive)
    }

    mutating func closeMenu(secureInputActive: Bool) {
        menuIsOpen = false
        refresh(secureInputActive: secureInputActive)
    }
}

/// Dispatch the status button's native action before mouse-up can change field focus.
/// A secondary click always preserves access to settings, diagnostics, and the full menu.
final class StatusItemInteraction: NSObject {
    private let offersCopySecret: () -> Bool
    private let openSearchSecrets: () -> Void
    private let openMenu: (NSButton) -> Void
    private var lastClickEvent: NSEvent?

    init(
        button: NSButton,
        offersCopySecret: @escaping () -> Bool,
        openSearchSecrets: @escaping () -> Void,
        openMenu: @escaping (NSButton) -> Void
    ) {
        self.offersCopySecret = offersCopySecret
        self.openSearchSecrets = openSearchSecrets
        self.openMenu = openMenu
        super.init()
        button.target = self
        button.action = #selector(activate(_:))
        button.sendAction(on: [.leftMouseDown, .rightMouseUp])
    }

    @objc private func activate(_ sender: NSButton) {
        // Programmatic/AX presses can leave the previous mouse event in currentEvent.
        // Only consume a fresh event of a type this button actually dispatches.
        let event = NSApp.currentEvent.flatMap { event in
            guard sender.window != nil, event.window === sender.window,
                  event !== lastClickEvent,
                  event.type == .leftMouseDown || event.type == .rightMouseUp else { return nil as NSEvent? }
            lastClickEvent = event
            return event
        }
        activate(sender, event: event)
    }

    func activate(_ sender: NSButton, event: NSEvent?) {
        assertMainThread()
        let secondaryClick = event?.type == .rightMouseDown || event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if !secondaryClick && offersCopySecret() {
            openSearchSecrets()
        } else {
            openMenu(sender)
        }
    }
}
