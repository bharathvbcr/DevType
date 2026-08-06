import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Menu-bar / status-item display state derived from Listen + AX + tap + pause + Secure Input.
/// A swallowing `defaultTap` needs Listen **and** Accessibility. Post-only missing degrades
/// inject and does **not** force Needs Permissions while the tap is running.
public enum EngineDisplayStatus: Equatable {
    case needsPermissions
    case tapFailed
    case paused
    case secure
    case active

    /// True when the user should open Permission Recovery or fix TCC / tap.
    public var requiresAction: Bool {
        switch self {
        case .needsPermissions, .tapFailed:
            return true
        case .paused, .secure, .active:
            return false
        }
    }

    public var menuTitle: String {
        switch self {
        case .needsPermissions: return "Status: Needs Permissions"
        case .tapFailed: return "Status: Tap Failed"
        case .paused: return "Status: Paused"
        case .secure: return "Status: Secure"
        case .active: return "Status: Active"
        }
    }

    /// Menu title with a lightweight action badge when permissions or tap need attention.
    public var menuTitleWithActionHint: String {
        requiresAction ? "\(menuTitle) ⚠" : menuTitle
    }

    public var buttonTitle: String {
        switch self {
        case .needsPermissions: return "DevType (Needs Permissions)"
        case .tapFailed: return "DevType (Tap Failed)"
        case .paused: return "DevType (Paused)"
        case .secure: return "DevType (Secure)"
        case .active: return "DevType"
        }
    }

    public var toolTip: String {
        toolTip(snapshot: nil)
    }

    /// Tooltip listing missing capabilities (Listen / AX / Post).
    public func toolTip(snapshot: PermissionSnapshot?) -> String {
        toolTip(
            missingCapabilityNames: snapshot?.missingCapabilityNames ?? [],
            canListenTap: snapshot?.canListenTap ?? true,
            canUseAX: snapshot?.canUseAX ?? true,
            degradedInject: snapshot?.isDegradedInject ?? false
        )
    }

    public func toolTip(
        missingCapabilityNames: [String],
        canListenTap: Bool = true,
        canUseAX: Bool = true,
        degradedInject: Bool = false
    ) -> String {
        switch self {
        case .needsPermissions:
            if missingCapabilityNames.isEmpty {
                return "Grant Input Monitoring and Accessibility in Permission Recovery (⌘⇧P) so the event tap can start"
            }
            var tip = "\(PermissionSnapshot.missingSummary(from: missingCapabilityNames)). Open Permission Recovery (⌘⇧P)."
            if !canListenTap || !canUseAX {
                tip += " Input Monitoring and Accessibility are both required for the event tap."
            }
            return tip
        case .tapFailed:
            return "Event tap failed to start despite Listen + Accessibility — quit other DevType copies, re-open the packaged app, then use Permission Recovery (⌘⇧P)"
        case .paused:
            return "DevType is paused"
        case .secure:
            return "Secure Input active — typed abbreviations muted. Use ⌘/ to paste into password fields (typing cannot work)."
        case .active:
            if degradedInject {
                let names = missingCapabilityNames.filter { $0 != "Input Monitoring" && $0 != "Accessibility" }
                if !names.isEmpty {
                    return "\(PermissionSnapshot.missingSummary(from: names)). Tap active — inject degraded. Permission Recovery (⌘⇧P)."
                }
            }
            return "DevType Native macOS Text Expander"
        }
    }

    /// Guidance when Listen + AX are granted but the tap still will not start.
    public static let tapFailedRecoveryGuidance = """
    Tap Failed: Input Monitoring and Accessibility look granted but the event tap did not start. Quit any other DevType copies, then re-open \(ProcessIdentity.preferredInstalledAppPath) (or \(ProcessIdentity.developmentAppPathHint) while developing) so TCC matches this identity. If Settings toggles look ON for an older binary, run Scripts/reset-tcc.sh and Request again.
    """

    /// Active when Listen + AX allow a running tap, user has not paused, and Secure Input is off.
    /// Missing Post alone does not demote to Needs Permissions.
    public static func resolve(
        canListenTap: Bool,
        canUseAX: Bool = true,
        isTapRunning: Bool,
        isEnabled: Bool,
        isSecureInputActive: Bool
    ) -> EngineDisplayStatus {
        // `.defaultTap` needs both capabilities; missing either is Needs Permissions, not Tap Failed.
        if !canListenTap || !canUseAX {
            return .needsPermissions
        }
        if !isTapRunning {
            return .tapFailed
        }
        if isSecureInputActive {
            return .secure
        }
        if !isEnabled {
            return .paused
        }
        return .active
    }

    /// Convenience from a full snapshot.
    public static func resolve(
        snapshot: PermissionSnapshot,
        isTapRunning: Bool,
        isEnabled: Bool,
        isSecureInputActive: Bool
    ) -> EngineDisplayStatus {
        resolve(
            canListenTap: snapshot.canListenTap,
            canUseAX: snapshot.canUseAX,
            isTapRunning: isTapRunning,
            isEnabled: isEnabled,
            isSecureInputActive: isSecureInputActive
        )
    }
}

public final class EventTapEngine {
    public static let shared = EventTapEngine()

    private var eventTapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let processingQueue = DispatchQueue(label: "com.devtype.eventprocessing", qos: .userInteractive)

    private let lock = NSLock()
    private var ringBuffer: [Character] = []
    private var layoutBuffer = LayoutBuffer()
    private let maxBufferCapacity = 64
    /// UTF-16 length of the most recent keyDown that appended to the buffer (for AX erase math).
    private var lastEventUTF16Count: Int = 1

    private var _snippets: [SnippetModel] = []
    private var _isEnabled: Bool = true
    private var _isTapRunning: Bool = false
    private var _isExpanding: Bool = false
    private var _matchingSuspended: Bool = false
    private var _isSecureInputActive: Bool = false

    /// Event-time quiescence clock (boot nanos via CGEvent.timestamp).
    public let inputClock = InputClock()

    private var appSwitchObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var healthTimer: DispatchSourceTimer?
    /// How often to probe `CGEvent.tapIsEnabled` for silent inert taps (macOS TCC/re-sign class).
    private let healthCheckInterval: TimeInterval = 2.0

    /// Invoked on the main queue when health monitor clears / reinstalls a dead tap.
    public var onTapHealthChanged: (() -> Void)?

    /// Called on the main queue after a snippet expansion inject completes successfully.
    public var onExpansionSucceeded: ((SnippetModel) -> Void)?

    /// Present fill-in UI from the app target. `(title, fields, completion)` — completion nil = cancel.
    public var presentFillIn: ((String, [FillField], @escaping ([Int: String]?) -> Void) -> Void)?

    /// Keycodes that desync the ring buffer. Return/Tab intentionally omitted — DevType may
    /// treat them as terminators and swallow (unlike SnipKey listenOnly clearBuffer).
    public static let bufferResetKeyCodes: Set<Int64> = [
        53, 115, 116, 117, 119, 121, 123, 124, 125, 126
    ]

    private static let mouseDownTypes: Set<CGEventType> = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown
    ]

    public var snippets: [SnippetModel] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _snippets
        }
        set {
            lock.lock()
            _snippets = newValue
            lock.unlock()
        }
    }

    /// User pause flag. When false, matching is skipped but the tap may still be installed.
    /// Persisted across launches so a deliberate pause survives relaunch / rebuild.
    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isEnabled
        }
        set {
            lock.lock()
            _isEnabled = newValue
            lock.unlock()
            UserDefaults.standard.set(!newValue, forKey: ProcessIdentity.userPausedDefaultsKey)
        }
    }

    /// Whether a CGEvent tap is currently installed (independent of user pause).
    public var isTapRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isTapRunning
    }

    /// True while an expansion inject + clipboard restore is in flight; matching is suppressed.
    public var isExpanding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isExpanding
    }

    /// When true, the tap still runs but abbreviation matching is skipped (fill-in panels, inline search).
    public var matchingSuspended: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _matchingSuspended
        }
        set {
            lock.lock()
            _matchingSuspended = newValue
            lock.unlock()
        }
    }

    public func suspendMatching() {
        matchingSuspended = true
    }

    public func resumeMatching() {
        matchingSuspended = false
    }

    /// Set when macOS Secure Event Input is active; matching is suppressed independently of user pause.
    public var isSecureInputActive: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSecureInputActive
        }
        set {
            lock.lock()
            let changed = _isSecureInputActive != newValue
            _isSecureInputActive = newValue
            if newValue && changed {
                ringBuffer.removeAll(keepingCapacity: true)
                layoutBuffer.clear()
                lastEventUTF16Count = 1
            }
            lock.unlock()
        }
    }

    /// Testable policy: whether this key should clear the ring buffer (no append / no match).
    public static func shouldResetBuffer(flags: CGEventFlags, keyCode: Int64) -> Bool {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return true
        }
        if KeyClassifier.action(forKeyCode: Int(keyCode)) == .clearBuffer {
            return true
        }
        if bufferResetKeyCodes.contains(keyCode) {
            return true
        }
        // Option / modified Backspace deletes a word or otherwise desyncs single-char removeLast.
        if keyCode == 51 {
            let modifiers: CGEventFlags = [.maskAlternate, .maskShift, .maskCommand, .maskControl]
            if !flags.intersection(modifiers).isEmpty {
                return true
            }
        }
        return false
    }

    /// Current TIS input source ID (empty on failure → physical Hangul fallback stays off).
    public static func currentInputSourceID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let cfID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return ""
        }
        return Unmanaged<CFString>.fromOpaque(cfID).takeUnretainedValue() as String
    }

    /// Autorepeat must not append or match — holding a key floods the ring buffer.
    public static func shouldIgnoreForMatching(isAutorepeat: Bool) -> Bool {
        isAutorepeat
    }

    /// InjectionPlanner contract: never keep a swallow if expand is refused.
    /// Sync-safe refuse (cached snapshot + planner) must pass the key through; async refuse must reinject.
    public static func shouldSwallowTrigger(plan: InjectionPlan) -> Bool {
        if case .refuse = plan { return false }
        return true
    }

    /// True when a deferred refuse must restore the swallowed final key to the target field.
    public static func mustReinjectOnRefuse(didSwallow: Bool) -> Bool {
        didSwallow
    }

    private let tapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let engine = Unmanaged<EventTapEngine>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            engine.reEnableTap()
            return Unmanaged.passUnretained(event)
        }

        let isSynthetic = event.getIntegerValueField(.eventSourceUserData) == SyntheticEventMarker.magicUserData
        if !isSynthetic {
            let eventTime = InputClock.seconds(sinceBootNanos: event.timestamp)
            if EventTapEngine.mouseDownTypes.contains(type) || type == .keyDown {
                engine.inputClock.mark(at: eventTime)
            }
        }

        // Mouse clicks move the caret — buffer is no longer valid.
        if EventTapEngine.mouseDownTypes.contains(type) {
            engine.resetBuffer()
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            engine.handleFlagsChanged(event)
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Pass through while inject+restore owns the critical section.
        // Must NOT swallow synthetic HID (backspace / ⌘V / arrows) we post ourselves.
        if engine.isExpanding || isSynthetic {
            return Unmanaged.passUnretained(event)
        }

        guard engine.isEnabled && !engine.isSecureInputActive && !engine.matchingSuspended else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if EventTapEngine.shouldIgnoreForMatching(isAutorepeat: isAutorepeat) {
            return Unmanaged.passUnretained(event)
        }

        if EventTapEngine.shouldResetBuffer(flags: flags, keyCode: keyCode) {
            engine.resetBuffer()
            return Unmanaged.passUnretained(event)
        }

        var length = 0
        var chars = [UniChar](repeating: 0, count: 128)
        event.keyboardGetUnicodeString(maxStringLength: 128, actualStringLength: &length, unicodeString: &chars)

        let unicodeStr = String(utf16CodeUnits: chars, count: length)
        let shift = flags.contains(.maskShift)
        let physicalChar = USKeyboardLayout.character(forKeyCode: Int(keyCode), shift: shift)
            ?? unicodeStr.first
        let keyAction = KeyClassifier.action(forKeyCode: Int(keyCode))

        engine.lock.lock()
        if keyAction == .deleteLast {
            if !engine.ringBuffer.isEmpty {
                engine.ringBuffer.removeLast()
            }
            engine.layoutBuffer.deleteLast()
            engine.lastEventUTF16Count = 1
        } else if length > 0 {
            for char in unicodeStr {
                engine.ringBuffer.append(char)
            }
            if let physicalChar {
                engine.layoutBuffer.appendLiteral(composed: unicodeStr, physical: physicalChar)
            }
            // AX ranges are UTF-16; keep erase math in the same units.
            engine.lastEventUTF16Count = max(1, unicodeStr.utf16.count)
            if engine.ringBuffer.count > engine.maxBufferCapacity {
                engine.ringBuffer.removeFirst(engine.ringBuffer.count - engine.maxBufferCapacity)
            }
        }
        let currentSnapshot = String(engine.ringBuffer)
        let layoutSnapshot = engine.layoutBuffer
        let activeSnippets = engine._snippets
        let lastUTF16Count = engine.lastEventUTF16Count
        engine.lock.unlock()

        // Hot path: muted check + matcher + sync-safe planner gate only.
        // Heavy AX (secure/IME/focus) stays off-callback; refuse there reinjects the swallow.
        if AppMuteStore.shared.isFrontmostMuted() {
            return Unmanaged.passUnretained(event)
        }

        let allowPhysical = isTwoSetKoreanSourceID(EventTapEngine.currentInputSourceID())
        if let match = engine.findMatch(
            in: currentSnapshot,
            layout: layoutSnapshot,
            allowPhysicalFallback: allowPhysical,
            snippets: activeSnippets
        ) {
            let snapshot = PermissionCoordinator.shared.cachedSnapshot
            let lookup: (String) -> String? = { trigger in
                activeSnippets.first { $0.triggerKeyword == trigger || (!$0.isCaseSensitive && $0.triggerKeyword.lowercased() == trigger.lowercased()) }?.replacementText
            }
            // Sync-safe shape for planner (no pasteboard; empty clipboard for refuse shape).
            let preview = MacroRenderer.expand(
                content: match.snippet.replacementText,
                fillValues: [:],
                lookup: lookup,
                clipboardText: ""
            )
            let previewText = preview.needsFillIn ? match.snippet.replacementText : preview.text
            let previewCursor = preview.needsFillIn ? nil : preview.cursorOffset
            let needsCursor = InjectionPlanner.needsCursorHID(
                cursorOffset: previewCursor,
                totalUTF16Length: previewText.utf16.count
            )
            // Dedicated terminals only on hot path (NSWorkspace); IDE shell needs AX → deferred.
            let isTerminal = AXContextChecker.shared.isFrontmostAppTerminal()
            let plan = InjectionPlanner().plan(
                snapshot: snapshot,
                isTerminal: isTerminal,
                needsCursorHID: needsCursor,
                isMultiLine: previewText.contains(where: \.isNewline) || preview.needsFillIn
            )
            guard EventTapEngine.shouldSwallowTrigger(plan: plan) else {
                // InjectionPlanner refuse — must not swallow (pass key through).
                return Unmanaged.passUnretained(event)
            }

            let focusPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            engine.beginExpansion()
            engine.resetBuffer()
            let utf16Trigger = match.eraseCount
            let charCount = lastUTF16Count
            let swallowedUnicode = unicodeStr
            let swallowedKeyCode = keyCode
            let swallowedFlags = flags
            let terminator = match.terminator
            let eraseOverride = match.source == .physical ? match.eraseCount : nil
            // Exact text expected left of the caret. Carries both unit systems (UTF-16 for AX
            // ranges, graphemes for backspaces) so neither path has to re-derive them.
            let erasePlan: ErasePlan
            if let fieldText = match.fieldText {
                erasePlan = ErasePlan.forMatch(
                    matchedTrigger: fieldText,
                    terminator: terminator,
                    swallowedFinalKey: true,
                    swallowedUnicode: swallowedUnicode,
                    caseInsensitive: !match.snippet.isCaseSensitive
                )
            } else {
                erasePlan = .counted(match.eraseCount)
            }
            engine.processingQueue.async {
                engine.performDeferredExpand(
                    snippet: match.snippet,
                    triggerUTF16Length: utf16Trigger,
                    lastEventUTF16Count: charCount,
                    swallowedUnicode: swallowedUnicode,
                    swallowedKeyCode: swallowedKeyCode,
                    swallowedFlags: swallowedFlags,
                    terminator: terminator,
                    eraseCountOverride: eraseOverride,
                    erasePlan: erasePlan,
                    armedFocusPID: focusPID
                )
            }
            return nil // Swallow only after sync-safe planner allow
        }

        return Unmanaged.passUnretained(event)
    }

    public init() {
        let paused = UserDefaults.standard.bool(forKey: ProcessIdentity.userPausedDefaultsKey)
        _isEnabled = !paused
        installAppSwitchObserver()
        installInputSourceObserver()
    }

    deinit {
        removeAppSwitchObserver()
        removeInputSourceObserver()
    }

    public func start() -> Bool {
        let listenGranted = CGPreflightListenEventAccess()
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let axGranted = AXIsProcessTrustedWithOptions(axOptions)
        DevTypeLog.eventTap.info(
            "[EventTap] start begin listenPreflight=\(DevTypeLog.grantLabel(listenGranted), privacy: .public) ax=\(DevTypeLog.grantLabel(axGranted), privacy: .public)"
        )
        // `.defaultTap` (swallowing) needs Listen + Accessibility. Attempting create without AX
        // returns nil and used to be misreported as Tap Failed / identity mismatch.
        if !listenGranted || !axGranted {
            lock.lock()
            _isTapRunning = false
            lock.unlock()
            DevTypeLog.eventTap.error(
                "[EventTap] start refused — defaultTap requires Listen+Accessibility (listen=\(DevTypeLog.grantLabel(listenGranted), privacy: .public) ax=\(DevTypeLog.grantLabel(axGranted), privacy: .public))"
            )
            return false
        }
        if eventTapPort != nil {
            stop()
        }

        var mask: CGEventMask = 0
        mask |= 1 << CGEventType.keyDown.rawValue
        mask |= 1 << CGEventType.flagsChanged.rawValue
        mask |= 1 << CGEventType.leftMouseDown.rawValue
        mask |= 1 << CGEventType.rightMouseDown.rawValue
        mask |= 1 << CGEventType.otherMouseDown.rawValue

        eventTapPort = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let port = eventTapPort else {
            lock.lock()
            _isTapRunning = false
            lock.unlock()
            DevTypeLog.eventTap.error(
                "[EventTap] start failed — CGEvent.tapCreate returned nil despite Listen+AX granted (check duplicate DevType processes / TCC identity)"
            )
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        lock.lock()
        _isTapRunning = true
        lock.unlock()
        startHealthMonitor()
        DevTypeLog.eventTap.info("[EventTap] start success — defaultTap installed + health monitor")
        return true
    }

    public func stop() {
        let wasRunning = isTapRunning
        stopHealthMonitor()
        if let port = eventTapPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTapPort = nil
        runLoopSource = nil
        lock.lock()
        _isTapRunning = false
        lock.unlock()
        if wasRunning {
            DevTypeLog.eventTap.info("[EventTap] stop — tap removed")
        }
    }

    public func reEnableTap() {
        guard let port = eventTapPort else { return }
        DevTypeLog.eventTap.notice(
            "[EventTap] re-enable after tapDisabledByTimeout/UserInput"
        )
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Starts a main-queue timer that re-enables or reinstalls an inert CGEvent tap.
    /// Called automatically from `start()`; safe to call again (resets the timer).
    public func startHealthMonitor() {
        stopHealthMonitor()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + healthCheckInterval, repeating: healthCheckInterval)
        timer.setEventHandler { [weak self] in
            self?.checkTapHealth()
        }
        healthTimer = timer
        timer.resume()
    }

    private func stopHealthMonitor() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    /// If the tap is expected to be live but `tapIsEnabled` is false (or the port is gone),
    /// try `tapEnable` then a full reinstall. Addresses silent disable after timeout/re-sign.
    private func checkTapHealth() {
        lock.lock()
        let expectRunning = _isTapRunning
        let userEnabled = _isEnabled
        lock.unlock()
        guard expectRunning, userEnabled else { return }

        guard let port = eventTapPort else {
            DevTypeLog.eventTap.notice(
                "[EventTap] health: port missing while expected running — reinstalling"
            )
            reinstallFromHealthMonitor(reason: "nil port")
            return
        }

        if CGEvent.tapIsEnabled(tap: port) {
            return
        }

        DevTypeLog.eventTap.notice(
            "[EventTap] health: tapIsEnabled=false — attempting tapEnable then reinstall"
        )
        CGEvent.tapEnable(tap: port, enable: true)
        if !CGEvent.tapIsEnabled(tap: port) {
            reinstallFromHealthMonitor(reason: "inert tap")
        } else {
            DevTypeLog.eventTap.info("[EventTap] health: tap re-enabled without reinstall")
        }
    }

    private func reinstallFromHealthMonitor(reason: String) {
        let snapshot = PermissionCoordinator.shared.cachedSnapshot
        if snapshot.blocksDefaultEventTap {
            DevTypeLog.eventTap.error(
                "[EventTap] health: reinstall skipped — Listen/AX missing (\(reason)); clearing running flag"
            )
            lock.lock()
            _isTapRunning = false
            lock.unlock()
            notifyTapHealthChanged()
            return
        }

        let ok = start()
        if !ok {
            DevTypeLog.eventTap.error(
                "[EventTap] health: reinstall failed after \(reason) (possible TCC revoke / identity)"
            )
            notifyTapHealthChanged()
        } else {
            DevTypeLog.eventTap.info("[EventTap] health: reinstall succeeded after \(reason)")
            notifyTapHealthChanged()
        }
    }

    private func notifyTapHealthChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onTapHealthChanged?()
        }
    }

    public func resetBuffer() {
        lock.lock()
        ringBuffer.removeAll(keepingCapacity: true)
        layoutBuffer.clear()
        lastEventUTF16Count = 1
        lock.unlock()
    }

    /// Off-callback expand: AX gates, macro resolve / fill-in, inject plan, then inject-owned lifetime.
    /// On refuse after swallow, reinjects the trigger key (InjectionPlanner contract).
    private func performDeferredExpand(
        snippet: SnippetModel,
        triggerUTF16Length: Int,
        lastEventUTF16Count: Int,
        swallowedUnicode: String,
        swallowedKeyCode: Int64,
        swallowedFlags: CGEventFlags,
        terminator: String,
        eraseCountOverride: Int?,
        erasePlan: ErasePlan,
        armedFocusPID: pid_t?
    ) {
        let quiescence = inputClock.arm()

        // AX / AppKit / Secure Input must run on main (avoid off-main IPC flake + nested main.sync).
        let mainProbe = Self.runOnMainSync { () -> (
            decision: AXContextChecker.ExpandGateDecision,
            secureInput: Bool,
            clipboard: String?,
            currentPID: pid_t?,
            refuseContext: PermissionCoordinator.InjectRefuseProvenance?
        ) in
            let snapshot = PermissionCoordinator.shared.cachedSnapshot
            let decision = AXContextChecker.shared.evaluateExpandGate(
                canUseAX: snapshot.canUseAX,
                canPostEvents: snapshot.canPostEvents
            )
            let secureInput = AXContextChecker.isSecureEventInputEnabledLive()
            let clipboard = NSPasteboard.general.string(forType: .string)
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let refuseContext: PermissionCoordinator.InjectRefuseProvenance?
            if secureInput {
                refuseContext = .capture(
                    reason: AXContextChecker.secureInputActiveReason,
                    decision: decision
                )
            } else if decision.shouldBlock {
                refuseContext = .capture(reason: decision.reason, decision: decision)
            } else {
                refuseContext = nil
            }
            return (decision, secureInput, clipboard, currentPID, refuseContext)
        }

        if mainProbe.secureInput {
            refuseAfterSwallow(
                reason: AXContextChecker.secureInputActiveReason,
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags,
                refuseContext: mainProbe.refuseContext
            )
            return
        }

        if mainProbe.decision.shouldBlock {
            refuseAfterSwallow(
                reason: mainProbe.decision.reason,
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags,
                refuseContext: mainProbe.refuseContext
            )
            return
        }

        if let armedFocusPID, mainProbe.currentPID != armedFocusPID {
            refuseAfterSwallow(
                reason: "Focus moved — expand aborted",
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags
            )
            return
        }

        if case .abort = inputClock.decide(quiescence) {
            refuseAfterSwallow(
                reason: "User input after arm — expand aborted",
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags
            )
            return
        }

        let clipboardSnapshot = mainProbe.clipboard
        let lookup: (String) -> String? = { [weak self] trigger in
            guard let self else { return nil }
            return self.snippets.first {
                $0.triggerKeyword == trigger
                    || (!$0.isCaseSensitive && $0.triggerKeyword.lowercased() == trigger.lowercased())
            }?.replacementText
        }

        let firstPass = MacroRenderer.expand(
            content: snippet.replacementText,
            fillValues: [:],
            lookup: lookup,
            clipboardText: clipboardSnapshot
        )

        if firstPass.needsFillIn {
            let fields = firstPass.fillFields
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let presenter = self.presentFillIn
                guard let presenter else {
                    self.refuseAfterSwallow(
                        reason: "Fill-in required but no presenter wired",
                        swallowedUnicode: swallowedUnicode,
                        swallowedKeyCode: swallowedKeyCode,
                        swallowedFlags: swallowedFlags
                    )
                    return
                }
                presenter(snippet.displayTitle, fields) { values in
                    self.processingQueue.async {
                        guard let values else {
                            self.refuseAfterSwallow(
                                reason: "Fill-in cancelled",
                                swallowedUnicode: swallowedUnicode,
                                swallowedKeyCode: swallowedKeyCode,
                                swallowedFlags: swallowedFlags
                            )
                            return
                        }
                        // Double-arm quiescence on panel close (panel Return must not abort).
                        let postPanel = self.inputClock.arm()
                        let resolved = MacroRenderer.expand(
                            content: snippet.replacementText,
                            fillValues: values,
                            lookup: lookup,
                            clipboardText: clipboardSnapshot
                        )
                        self.finishDeferredInject(
                            snippet: snippet,
                            triggerUTF16Length: triggerUTF16Length,
                            lastEventUTF16Count: lastEventUTF16Count,
                            swallowedUnicode: swallowedUnicode,
                            swallowedKeyCode: swallowedKeyCode,
                            swallowedFlags: swallowedFlags,
                            terminator: terminator,
                            eraseCountOverride: eraseCountOverride,
                            erasePlan: erasePlan,
                            resolved: resolved,
                            clipboardSnapshot: clipboardSnapshot,
                            quiescence: postPanel,
                            armedFocusPID: armedFocusPID
                        )
                    }
                }
            }
            return
        }

        finishDeferredInject(
            snippet: snippet,
            triggerUTF16Length: triggerUTF16Length,
            lastEventUTF16Count: lastEventUTF16Count,
            swallowedUnicode: swallowedUnicode,
            swallowedKeyCode: swallowedKeyCode,
            swallowedFlags: swallowedFlags,
            terminator: terminator,
            eraseCountOverride: eraseCountOverride,
            erasePlan: erasePlan,
            resolved: firstPass,
            clipboardSnapshot: clipboardSnapshot,
            quiescence: quiescence,
            armedFocusPID: armedFocusPID
        )
    }

    private func finishDeferredInject(
        snippet: SnippetModel,
        triggerUTF16Length: Int,
        lastEventUTF16Count: Int,
        swallowedUnicode: String,
        swallowedKeyCode: Int64,
        swallowedFlags: CGEventFlags,
        terminator: String,
        eraseCountOverride: Int?,
        erasePlan: ErasePlan,
        resolved: MacroExpansionResult,
        clipboardSnapshot: String?,
        quiescence: InputQuiescenceGuard,
        armedFocusPID: pid_t?
    ) {
        if case .abort = inputClock.decide(quiescence) {
            refuseAfterSwallow(
                reason: "User input after arm — expand aborted",
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags
            )
            return
        }

        let mainProbe = Self.runOnMainSync { () -> (currentPID: pid_t?, shellLike: Bool) in
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let shellLike = AXContextChecker.shared.isFrontmostShellLikeContext()
            return (currentPID, shellLike)
        }

        if let armedFocusPID, mainProbe.currentPID != armedFocusPID {
            refuseAfterSwallow(
                reason: "Focus moved — expand aborted",
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags
            )
            return
        }

        let snapshot = PermissionCoordinator.shared.cachedSnapshot
        let shellLike = mainProbe.shellLike
        let needsCursor = InjectionPlanner.needsCursorHID(
            cursorOffset: resolved.cursorOffset,
            totalUTF16Length: resolved.text.utf16.count
        )
        let plan = InjectionPlanner().plan(
            snapshot: snapshot,
            isTerminal: shellLike,
            needsCursorHID: needsCursor,
            isMultiLine: resolved.text.contains(where: \.isNewline)
        )
        if case .refuse(let reason) = plan {
            refuseAfterSwallow(
                reason: reason,
                swallowedUnicode: swallowedUnicode,
                swallowedKeyCode: swallowedKeyCode,
                swallowedFlags: swallowedFlags
            )
            return
        }

        let lookup: (String) -> String? = { [weak self] trigger in
            guard let self else { return nil }
            return self.snippets.first {
                $0.triggerKeyword == trigger
                    || (!$0.isCaseSensitive && $0.triggerKeyword.lowercased() == trigger.lowercased())
            }?.replacementText
        }

        TextInjectionPipeline.shared.inject(
            snippet: snippet,
            triggerLength: triggerUTF16Length,
            clipboardOverride: clipboardSnapshot,
            swallowedFinalKey: true,
            lastEventCharacterCount: lastEventUTF16Count,
            plan: plan,
            swallowedUnicode: swallowedUnicode,
            swallowedKeyCode: swallowedKeyCode,
            swallowedFlags: swallowedFlags,
            terminator: terminator,
            eraseCountOverride: eraseCountOverride,
            erasePlan: erasePlan,
            preResolvedText: resolved.text,
            preResolvedCursorOffset: resolved.cursorOffset,
            trailingKeys: resolved.trailingKeys,
            snippetLookup: lookup
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.onExpansionSucceeded?(snippet)
            }
            self?.endExpansion()
        }
    }

    /// Records refuse and reinjects the swallowed key while `isExpanding` still suppresses rematch.
    private func refuseAfterSwallow(
        reason: String,
        swallowedUnicode: String,
        swallowedKeyCode: Int64,
        swallowedFlags: CGEventFlags,
        refuseContext: PermissionCoordinator.InjectRefuseProvenance? = nil
    ) {
        if Self.mustReinjectOnRefuse(didSwallow: true) {
            _ = TextInjectionPipeline.shared.reinjectSwallowedKey(
                unicode: swallowedUnicode,
                keyCode: swallowedKeyCode,
                flags: swallowedFlags
            )
        }
        DispatchQueue.main.async {
            PermissionCoordinator.shared.recordInjectOutcome(
                .refused(reason),
                refuseContext: refuseContext
            )
        }
        endExpansion()
    }

    /// Hop to main for AppKit/AX without nested `main.sync` when already on main.
    private static func runOnMainSync<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    /// Pure match via AbbreviationMatcher (+ optional physical Hangul fallback).
    public func findMatch(
        in bufferSnapshot: String,
        layout: LayoutBuffer = LayoutBuffer(),
        allowPhysicalFallback: Bool = false,
        snippets: [SnippetModel]? = nil
    ) -> SnippetMatch? {
        let activeSnippets = snippets ?? self.snippets
        let matcher = AbbreviationMatcher(snippets: activeSnippets)
        guard let decision = LayoutAwareMatcher.decide(
            composedBuffer: bufferSnapshot,
            layout: layout,
            matcher: matcher,
            allowPhysicalFallback: allowPhysicalFallback
        ) else {
            return nil
        }
        let source: SnippetMatch.Source = decision.source == .physical ? .physical : .composed
        let erase: Int
        if decision.source == .physical {
            // Grapheme count from LayoutAwareMatcher — no text to verify against.
            erase = decision.backspaces
        } else {
            // Terminator (when present) is swallowed separately — erase the trigger only.
            // Measure the text the user actually typed, not the stored keyword: they can differ in
            // casing, and for astral characters they can differ in UTF-16 length too.
            erase = (decision.fieldText ?? decision.match.snippet.triggerKeyword).utf16.count
        }
        return SnippetMatch(
            snippet: decision.match.snippet,
            triggerLength: decision.match.triggerLength,
            terminator: decision.terminator,
            source: source,
            eraseCount: erase,
            fieldText: decision.fieldText
        )
    }

    /// Pure match check for tests and callers that only need a Bool. Does not inject.
    public func evaluateMatch(bufferSnapshot: String) -> Bool {
        findMatch(in: bufferSnapshot) != nil
    }

    /// Marks inject+restore critical section. Cleared only by `endExpansion` after inject completes.
    private func beginExpansion() {
        lock.lock()
        _isExpanding = true
        lock.unlock()
    }

    private func endExpansion() {
        lock.lock()
        _isExpanding = false
        ringBuffer.removeAll(keepingCapacity: true)
        layoutBuffer.clear()
        lastEventUTF16Count = 1
        lock.unlock()
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Caps Lock (keycode 57) toggles often imply caret/context change — reset.
        if keyCode == 57 {
            resetBuffer()
        }
    }

    private func installAppSwitchObserver() {
        guard appSwitchObserver == nil else { return }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.resetBuffer()
        }
    }

    private func removeAppSwitchObserver() {
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    private func installInputSourceObserver() {
        guard inputSourceObserver == nil else { return }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.resetBuffer()
        }
    }

    private func removeInputSourceObserver() {
        if let observer = inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            inputSourceObserver = nil
        }
    }

}
