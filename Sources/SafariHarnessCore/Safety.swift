import Foundation

public enum AbortReason: Equatable, Sendable, CustomStringConvertible {
    case escapePressed
    case interrupted
    case timeout(seconds: Double)
    case unsafeFocus(String)

    public var description: String {
        switch self {
        case .escapePressed: return "Escape pressed"
        case .interrupted: return "interrupted (SIGINT)"
        case .timeout(let s): return "run deadline of \(Int(s)) s reached"
        case .unsafeFocus(let why): return "refused to post a key: \(why)"
        }
    }
}

public struct HarnessAbort: Error, Equatable, CustomStringConvertible {
    public let reason: AbortReason
    public var description: String { "aborted: \(reason)" }
}

/// The one place that decides whether posting may continue. It latches: once tripped it stays
/// tripped, so a key released a millisecond later cannot "un-abort" the run.
///
/// Escape is polled (`CGEventSource.keyState`), which needs no Input Monitoring. The harness never
/// posts Escape to Safari; the one time it posts Escape to DevType's own palette it first calls
/// `suppressEscape`, so its own synthetic key is not read as the user's.
public final class AbortController: @unchecked Sendable {
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let escapeDown: () -> Bool
    private let signalled: () -> Bool
    private let started: TimeInterval
    private let timeoutSeconds: Double
    private var latched: AbortReason?
    private var escapeIgnoredUntil: TimeInterval = 0

    public init(
        timeoutSeconds: Double,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        escapeDown: @escaping () -> Bool,
        signalled: @escaping () -> Bool
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.now = now
        self.escapeDown = escapeDown
        self.signalled = signalled
        self.started = now()
    }

    public func suppressEscape(forSeconds seconds: Double) {
        lock.lock()
        escapeIgnoredUntil = max(escapeIgnoredUntil, now() + seconds)
        lock.unlock()
    }

    /// Trips for an externally decided reason, such as the focus guard refusing a key.
    public func trip(_ reason: AbortReason) {
        lock.lock()
        if latched == nil { latched = reason }
        lock.unlock()
    }

    public var tripped: AbortReason? {
        lock.lock()
        defer { lock.unlock() }
        return latched
    }

    /// Polls every source. Cheap enough to call before each key and between sleep slices.
    @discardableResult
    public func poll() -> AbortReason? {
        lock.lock()
        defer { lock.unlock() }
        if latched != nil { return latched }
        let t = now()
        if signalled() {
            latched = .interrupted
        } else if t - started >= timeoutSeconds {
            latched = .timeout(seconds: timeoutSeconds)
        } else if t >= escapeIgnoredUntil, escapeDown() {
            latched = .escapePressed
        }
        return latched
    }

    public func check() throws {
        if let reason = poll() { throw HarnessAbort(reason: reason) }
    }
}

/// What the harness could read about the focused element at the moment of a keystroke.
public struct FocusSnapshot: Equatable, Sendable {
    public var frontBundleID: String?
    public var frontPID: Int32?
    public var focusedPID: Int32?
    public var focusedDOMID: String?
    public var focusedRole: String?
    /// Path of the AXWebArea's URL that contains the focused element, symlinks resolved.
    public var webAreaPath: String?

    public init(
        frontBundleID: String? = nil, frontPID: Int32? = nil, focusedPID: Int32? = nil,
        focusedDOMID: String? = nil, focusedRole: String? = nil, webAreaPath: String? = nil
    ) {
        self.frontBundleID = frontBundleID
        self.frontPID = frontPID
        self.focusedPID = focusedPID
        self.focusedDOMID = focusedDOMID
        self.focusedRole = focusedRole
        self.webAreaPath = webAreaPath
    }
}

/// Where a keystroke is allowed to go.
public enum FocusPolicy: Equatable, Sendable {
    /// The fixture page in Safari.
    case harnessPage(fixturePath: String)
    /// DevType's own AI palette, after the harness opened it with DevType's hotkey. Only the
    /// letters of "proofread" and Return are ever posted under this policy.
    case devTypePalette(devTypePID: Int32)
}

public enum FocusDecision: Equatable, Sendable {
    case allow
    case deny(String)

    public var isAllowed: Bool { self == .allow }
}

public enum FocusSafety {
    static let paletteRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    public static func decide(_ snapshot: FocusSnapshot, policy: FocusPolicy) -> FocusDecision {
        switch policy {
        case .harnessPage(let fixturePath):
            guard snapshot.frontBundleID == HarnessConstants.safariBundleID else {
                return .deny("frontmost app is \(snapshot.frontBundleID ?? "unknown"), not Safari")
            }
            guard let id = snapshot.focusedDOMID, id.hasPrefix(HarnessConstants.domPrefix) else {
                return .deny("focused element is not a harness control (id \(snapshot.focusedDOMID ?? "none"))")
            }
            guard let pid = snapshot.focusedPID, pid == snapshot.frontPID else {
                return .deny("focused element belongs to a different process than the frontmost app")
            }
            guard snapshot.webAreaPath == fixturePath else {
                return .deny("focused element is in \(snapshot.webAreaPath ?? "an unreadable document"), not the harness page")
            }
            if id == PageField.reset.domID {
                return .deny("focus is on the reset button, which never receives typing")
            }
            return .allow
        case .devTypePalette(let devTypePID):
            guard snapshot.frontBundleID == HarnessConstants.devTypeBundleID, snapshot.frontPID == devTypePID else {
                return .deny("frontmost app is \(snapshot.frontBundleID ?? "unknown"), not the DevType process the harness checked")
            }
            guard snapshot.focusedPID == devTypePID else {
                return .deny("focused element is not in DevType")
            }
            guard let role = snapshot.focusedRole, paletteRoles.contains(role) else {
                return .deny("focused element in DevType is \(snapshot.focusedRole ?? "unreadable"), not a text field")
            }
            return .allow
        }
    }
}
