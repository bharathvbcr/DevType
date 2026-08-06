import Foundation

/// Capability-split TCC snapshot.
///
/// A swallowing `defaultTap` needs **Input Monitoring and Accessibility**. Missing either
/// blocks tap install. Post Events is inject-only (HID paste / cursor); dropping it degrades
/// inject and must not tear down a running tap.
public struct PermissionSnapshot: Equatable {
    public let canListenTap: Bool
    public let canUseAX: Bool
    public let canPostEvents: Bool

    public init(canListenTap: Bool, canUseAX: Bool, canPostEvents: Bool) {
        self.canListenTap = canListenTap
        self.canUseAX = canUseAX
        self.canPostEvents = canPostEvents
    }

    /// All three capabilities granted (UI / verify only — never a tap kill-switch by itself).
    public var isFullyCapable: Bool {
        canListenTap && canUseAX && canPostEvents
    }

    /// Human-readable names of missing capabilities, in display order.
    public var missingCapabilityNames: [String] {
        var missing: [String] = []
        if !canUseAX { missing.append("Accessibility") }
        if !canListenTap { missing.append("Input Monitoring") }
        if !canPostEvents { missing.append("Post Events") }
        return missing
    }

    public var missingCapabilitiesSummary: String {
        Self.missingSummary(from: missingCapabilityNames)
    }

    /// True when Input Monitoring alone is absent.
    public var inputMonitoringBlocksEventTap: Bool {
        !canListenTap
    }

    /// True when Accessibility alone is absent — `.defaultTap` cannot be created.
    public var accessibilityBlocksEventTap: Bool {
        !canUseAX
    }

    /// True when Listen or AX is missing — either blocks a swallowing event tap.
    public var blocksDefaultEventTap: Bool {
        !canListenTap || !canUseAX
    }

    /// Listen + AX OK but inject degraded (missing Post only).
    /// AX missing is not "degraded inject" — inject refuses and the tap cannot start.
    public var isDegradedInject: Bool {
        canListenTap && canUseAX && !canPostEvents
    }

    public static func missingSummary(from names: [String]) -> String {
        switch names.count {
        case 0:
            return "All capabilities granted"
        case 1:
            return "Missing: \(names[0])"
        case 2:
            return "Missing: \(names[0]) and \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "Missing: \(head), and \(names.last!)"
        }
    }
}

/// TCC permission kinds DevType requests via CG / AX APIs.
public enum PermissionKind: Equatable, CaseIterable {
    case accessibility
    case inputMonitoring
    case postEvent
}
