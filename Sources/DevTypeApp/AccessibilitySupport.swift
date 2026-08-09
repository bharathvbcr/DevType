import AppKit
import ExpanderEngine

// MARK: - §5.1 / §5.2 — DevType's own accessibility surface
//
// DevType requires the Accessibility permission and reads other apps' AX trees,
// yet before this file the app exposed *nothing* over AX itself: bare
// `NSTextField`s in plain `NSView` rows, an unlabeled `NSStatusItem`, and status
// conveyed only by the colour of an 8×8 dot.
//
// This file is the shared vocabulary the rest of the UI uses:
//   • `DevTypeAccessibility` — the four `NSWorkspace` display flags nothing in
//     `Sources/` previously consulted (differentiate-without-colour, reduce
//     motion, reduce transparency, increase contrast) plus a change observer.
//   • `NSView.dtApplyAccessibility(...)` — one call to label a custom view.
//   • `DevTypeAccessibility.symbolDescription(_:)` — a real
//     `accessibilityDescription` for every SF Symbol the app renders, replacing
//     the blanket `accessibilityDescription: nil` at DevTypeTheme.swift:111,117.

enum DevTypeAccessibility {

    // MARK: System display preferences (§5.2)

    /// User asked for status to be legible without relying on hue.
    /// Every colour-coded affordance in DevType pairs with a glyph or text when true.
    static var differentiateWithoutColor: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }

    /// User asked for reduced motion — the palette fade/scale is skipped when true.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// User asked for reduced transparency — glass surfaces fall back to solid fills.
    static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// User asked for increased contrast — hairlines and text are strengthened.
    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Observes `accessibilityDisplayOptionsDidChangeNotification` on the main queue.
    /// Callers keep the returned token alive for as long as they want updates.
    @discardableResult
    static func observeDisplayOptions(_ handler: @escaping () -> Void) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in handler() }
    }

    // MARK: Symbol descriptions (§5.1)

    /// Human-readable description for an SF Symbol name.
    ///
    /// Known symbols get a curated, localized label; anything else is humanized
    /// from the symbol name (`"square.and.arrow.down"` → `"square and arrow down"`)
    /// so no image in the app is ever announced as an unlabeled element.
    static func symbolDescription(_ name: String) -> String {
        if let key = Self.symbolLocalizationKeys[name] {
            return LocalizationManager.shared.s(key)
        }
        return humanize(name)
    }

    /// `"chevron.down.circle.fill"` → `"chevron down circle"`.
    static func humanize(_ symbolName: String) -> String {
        let cosmetic: Set<String> = ["fill", "circle", "square", "badge"]
        let parts = symbolName
            .split(separator: ".")
            .map(String.init)
        let meaningful = parts.filter { !cosmetic.contains($0) }
        let words = meaningful.isEmpty ? parts : meaningful
        return words.joined(separator: " ")
    }

    /// Curated labels for the symbols that carry meaning in DevType's chrome.
    /// Everything else falls through to `humanize(_:)`.
    private static let symbolLocalizationKeys: [String: String] = [
        "square.stack.3d.up": "ax.symbol.manage",
        "square.stack.3d.up.fill": "ax.symbol.allSnippets",
        "magnifyingglass": "ax.symbol.search",
        "text.magnifyingglass": "ax.symbol.search",
        "square.and.arrow.down": "ax.symbol.import",
        "square.and.arrow.up": "ax.symbol.export",
        "clock.arrow.circlepath": "ax.symbol.recent",
        "pause.circle": "ax.symbol.pause",
        "play.circle": "ax.symbol.resume",
        "sunrise": "ax.symbol.openAtLogin",
        "globe": "ax.symbol.language",
        "checkmark.shield": "ax.symbol.permissionRecovery",
        "lock.shield": "ax.symbol.secureInput",
        "speaker.slash": "ax.symbol.mute",
        "speaker.slash.fill": "ax.symbol.mutedApps",
        "power": "ax.symbol.quit",
        "gearshape": "ax.symbol.settings",
        "sparkles": "ax.symbol.ai",
        "slider.horizontal.3": "ax.symbol.preferences",
        "plus": "ax.symbol.add",
        "pencil": "ax.symbol.edit",
        "trash": "ax.symbol.delete",
        "folder": "ax.symbol.group",
        "folder.badge.plus": "ax.symbol.newGroup",
        "plus.square.on.square": "ax.symbol.duplicate",
        "arrow.counterclockwise": "ax.symbol.reset",
        "arrow.clockwise": "ax.symbol.relaunch",
        "arrow.triangle.2.circlepath": "ax.symbol.refresh",
        "bolt.fill": "ax.symbol.testExpansion",
        "hand.raised": "ax.symbol.request",
        "checkmark": "ax.symbol.granted",
        "doc.on.doc": "ax.symbol.copy",
        "doc.text.magnifyingglass": "ax.symbol.diagnostics",
        "number.square": "ax.symbol.binaryIdentity",
        "accessibility": "ax.symbol.accessibility",
        "keyboard": "ax.symbol.inputMonitoring",
        "cursorarrow.rays": "ax.symbol.postEvents",
        "text.insert": "ax.symbol.expand",
        "text.badge.plus": "ax.symbol.newSnippet",
        "chart.bar": "ax.symbol.statistics",
        "chevron.down": "ax.symbol.disclosureClosed",
        "chevron.up": "ax.symbol.disclosureOpen",
        "exclamationmark.triangle.fill": "ax.symbol.warning",
        "xmark": "ax.symbol.close"
    ]

}

/// Local mirror of `EngineDisplayStatus` so this file does not need to import
/// `ExpanderEngine` just to switch on five cases. `AppDelegate` maps across.
enum EngineDisplayStatusKind {
    case needsPermissions
    case tapFailed
    case paused
    case secure
    case active
}

// MARK: - View labelling helper

extension NSView {
    /// §5.1: labels a custom composite view for VoiceOver in one call.
    ///
    /// Custom row views (`SearchHitCellView`, `SnippetRowView`, `GroupRowView`) are
    /// plain `NSView`s holding bare `NSTextField`s. Without an explicit role +
    /// label VoiceOver announces "row 1" and nothing else. Marking the container
    /// as *the* accessibility element and hiding the children collapses the row
    /// into one meaningful utterance.
    func dtApplyAccessibility(
        role: NSAccessibility.Role? = nil,
        label: String? = nil,
        value: String? = nil,
        help: String? = nil,
        isElement: Bool = true
    ) {
        setAccessibilityElement(isElement)
        if let role { setAccessibilityRole(role) }
        if let label { setAccessibilityLabel(label) }
        if let value { setAccessibilityValue(value) }
        if let help { setAccessibilityHelp(help) }
    }

    /// Hides every descendant from AX so the container speaks as a single unit.
    func dtHideSubviewsFromAccessibility() {
        for subview in subviews {
            subview.setAccessibilityElement(false)
            subview.dtHideSubviewsFromAccessibility()
        }
    }
}
