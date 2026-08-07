import ApplicationServices
import Foundation

/// Synchronous AX read of the current selection for the AI hotkey path.
///
/// Phase 1 reads `kAXSelectedTextAttribute` only — no synthetic ⌘C. Clipboard
/// ownership is owned by `PasteboardBroker`; an unmanaged copy would corrupt
/// `changeCount` and abandon restore.
public enum SelectionReader {
    public struct Result: Equatable {
        public let text: String
        public let bundleID: String?
        /// True when `AXWriteCapabilityStore.seedVerdict` marks this app as unreliable AX.
        public let isWeakAX: Bool

        public init(text: String, bundleID: String?, isWeakAX: Bool) {
            self.text = text
            self.bundleID = bundleID
            self.isWeakAX = isWeakAX
        }
    }

    /// Read selected text from the focused AX element.
    ///
    /// Returns `nil` when Accessibility is untrusted, Secure Input is active, the
    /// frontmost app is muted, focus is missing, or the selection is empty / unreadable.
    public static func readSelectedText(
        checker: AXContextChecker = .shared,
        muteStore: AppMuteStore = .shared
    ) -> Result? {
        guard checker.isProcessTrusted() else { return nil }
        guard !AXContextChecker.isSecureEventInputEnabledLive() else { return nil }

        let bundleID = checker.frontmostApplicationBundleIdentifier()
        if let bundleID, muteStore.isMuted(bundleID) { return nil }

        guard let element = checker.focusedElement() else { return nil }
        AXContextChecker.applyMessagingTimeout(to: element)

        guard let text = copySelectedText(from: element), !text.isEmpty else {
            return nil
        }

        let weakAX = bundleID.map { Self.isWeakAXApp(bundleID: $0) } ?? false
        return Result(text: text, bundleID: bundleID, isWeakAX: weakAX)
    }

    /// Apps seeded as AX false-success (Chrome, Slack, Electron, …) — treat selection
    /// as untrustworthy for the typed-path staleness gate.
    public static func isWeakAXApp(bundleID: String) -> Bool {
        AXWriteCapabilityStore.seedVerdict(bundleID: bundleID) == .falseSuccess
    }

    /// Shared AX attribute read used by `SelectionMonitor` and the hotkey path.
    public static func copySelectedText(from element: AXUIElement) -> String? {
        AXContextChecker.applyMessagingTimeout(to: element)
        var selectedTextRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextRef
        ) == .success else {
            return nil
        }
        return selectedTextRef as? String
    }
}
