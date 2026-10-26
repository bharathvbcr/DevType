import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension TextInjectionPipeline {
    /// Every question the pipeline asks the machine it runs on: whether this process is trusted for
    /// Accessibility and may post events, whether Secure Input is on, what is frontmost, and what
    /// AX says is focused. The same shape as `PasteboardBroker.Environment`.
    ///
    /// Production uses `.live`, which answers exactly what the inline calls it replaced did. A test
    /// scripts the answers, so the verdict of a gate is the test's own and never whatever this Mac
    /// grants the test host, which application the developer has in front, or whether a password
    /// field somewhere has Secure Input on.
    struct Environment {
        /// The frontmost application as the pipeline reads it: its process and its bundle.
        struct FrontmostApp: Equatable {
            var processIdentifier: pid_t?
            var bundleIdentifier: String?
        }

        var isProcessTrusted: () -> Bool = { AXContextChecker.shared.isProcessTrusted() }
        var secureInputActive: () -> Bool = { AXContextChecker.isSecureEventInputEnabledLive() }
        var canPostEvents: () -> Bool = { CGPreflightPostEventAccess() }
        var permissionSnapshot: () -> PermissionSnapshot = { PermissionCoordinator.shared.cachedSnapshot }
        var frontmostApp: () -> FrontmostApp = {
            let app = NSWorkspace.shared.frontmostApplication
            return FrontmostApp(processIdentifier: app?.processIdentifier, bundleIdentifier: app?.bundleIdentifier)
        }
        /// A live read of the focused element — the one the re-checks that exist to catch the user
        /// moving compare against. Never the inject's own threaded element.
        var focusedElement: () -> AXUIElement? = { AXContextChecker.shared.focusedElement() }
        var focusedRole: (AXUIElement) -> String? = { AXContextChecker.shared.focusedElementRole(element: $0) }
        var imeMarkedText: (AXUIElement) -> Bool = {
            AXContextChecker.shared.hasActiveIMEMarkedText(element: $0)
        }
        var expandGate: (
            _ canUseAX: Bool, _ canPostEvents: Bool, _ focus: AXContextChecker.FocusQueryResult
        ) -> AXContextChecker.ExpandGateDecision = { canUseAX, canPostEvents, focus in
            AXContextChecker.shared.evaluateExpandGate(
                canUseAX: canUseAX, canPostEvents: canPostEvents, focus: focus
            )
        }
        var shellLikeContext: (FocusedElementSource) -> Bool = {
            AXContextChecker.shared.isFrontmostShellLikeContext(focus: $0)
        }

        func evaluateExpandGate(
            canUseAX: Bool, canPostEvents: Bool, focus: AXContextChecker.FocusQueryResult
        ) -> AXContextChecker.ExpandGateDecision {
            expandGate(canUseAX, canPostEvents, focus)
        }

        func isFrontmostShellLikeContext(focus: FocusedElementSource) -> Bool {
            shellLikeContext(focus)
        }

        func hasActiveIMEMarkedText(_ element: AXUIElement) -> Bool {
            imeMarkedText(element)
        }

        static let live = Environment()
    }
}
