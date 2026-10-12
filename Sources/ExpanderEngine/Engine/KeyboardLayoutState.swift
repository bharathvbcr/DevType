import Carbon
import CoreGraphics
import Foundation

/// Reads the keyboard layout from HIToolbox. Every member is main-queue only: on macOS 27 the
/// Text Input Source APIs `dispatch_assert_queue` the main queue and trap anywhere else.
protocol KeyboardLayoutProviding {
    /// Current input source ID, or nil when the system cannot report one.
    func currentSourceID() -> String?
    /// The virtual key code producing `character` on the current layout, or nil.
    func keyCode(for character: Character) -> CGKeyCode?
}

/// The only code in the app that calls `TIS*` / `UCKeyTranslate` (pinned by `SourceContractTests`).
struct LiveKeyboardLayoutProvider: KeyboardLayoutProviding {
    static let changeNotification = NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
    }

    /// The brute-force scan: up to 128 `UCKeyTranslate` calls.
    func keyCode(for targetChar: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = unsafeBitCast(layoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let wanted = String(targetChar).lowercased()

        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { keyboardLayout -> CGKeyCode? in
            var chars = [UniChar](repeating: 0, count: 4)
            var realLength = 0
            for code: CGKeyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(
                    keyboardLayout, code, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(KBGetLayoutType(0)), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, 4, &realLength, &chars
                )
                if status == noErr && realLength > 0,
                   String(utf16CodeUnits: chars, count: realLength).lowercased() == wanted {
                    return code
                }
            }
            return nil
        }
    }
}

/// The single owner of keyboard-layout state, shared by `HIDKeyPoster` and `EventTapEngine`.
///
/// TIS is touched only by `refresh()`, which asserts the main queue. Everything else reads a
/// lock-guarded `Snapshot`, so the brokered-copy tier on `SelectionReader.readQueue`, the event
/// tap thread and main can all ask for the layout without ever calling HIToolbox. Until the first
/// refresh lands, the snapshot is empty and callers use their `kVK_ANSI_*` fallbacks.
final class KeyboardLayoutState {
    struct Snapshot: Equatable {
        var sourceID: String = ""
        var keyCodes: [Character: CGKeyCode] = [:]

        /// Physical-Hangul fallback is armed only on the 2-Set Korean source.
        var isTwoSetKorean: Bool { isTwoSetKoreanSourceID(sourceID) }
    }

    /// Characters whose key codes are resolved at refresh: the Cmd-C / Cmd-V chords.
    static let primedCharacters: [Character] = ["c", "v"]

    static let shared = KeyboardLayoutState(
        provider: LiveKeyboardLayoutProvider(),
        center: DistributedNotificationCenter.default(),
        changeName: LiveKeyboardLayoutProvider.changeNotification
    )

    private let provider: KeyboardLayoutProviding
    private let lock = UnfairLock()
    private var current = Snapshot()
    private var primeRequested = false
    private var listeners: [UUID: () -> Void] = [:]
    private var observer: NSObjectProtocol?
    private let observedCenter: NotificationCenter?

    /// - Parameters:
    ///   - center/changeName: where the system announces a layout change. The center may deliver
    ///     on any thread (the live one is a `DistributedNotificationCenter` with `queue: nil`),
    ///     so the handler hops to main before it refreshes.
    init(provider: KeyboardLayoutProviding, center: NotificationCenter? = nil, changeName: NSNotification.Name? = nil) {
        self.provider = provider
        observedCenter = center
        if let center, let changeName {
            observer = center.addObserver(forName: changeName, object: nil, queue: nil) { [weak self] _ in
                self?.refreshOnMain()
            }
        }
    }

    deinit {
        if let observer { observedCenter?.removeObserver(observer) }
    }

    /// Latest snapshot; any thread, never calls TIS. The first read before any refresh schedules
    /// one on main (asynchronously — never `main.sync`, which could deadlock a read main awaits).
    func snapshot() -> Snapshot {
        lock.lock()
        let value = current
        let needsPrime = !primeRequested
        primeRequested = true
        lock.unlock()
        if needsPrime { DispatchQueue.main.async { [self] in refresh() } }
        return value
    }

    /// The key code for `character` on the last-refreshed layout; nil until refreshed or when
    /// the layout has no such character. The caller owns its fallback.
    func keyCode(for character: Character) -> CGKeyCode? {
        snapshot().keyCodes[character]
    }

    /// Re-read the layout from HIToolbox and notify listeners. Main queue only.
    func refresh() {
        dispatchPrecondition(condition: .onQueue(.main))
        let sourceID = provider.currentSourceID() ?? ""
        var codes: [Character: CGKeyCode] = [:]
        if !sourceID.isEmpty {
            for character in Self.primedCharacters {
                if let code = provider.keyCode(for: character) { codes[character] = code }
            }
        }
        lock.lock()
        current = Snapshot(sourceID: sourceID, keyCodes: codes)
        primeRequested = true
        let callbacks = Array(listeners.values)
        lock.unlock()
        for callback in callbacks { callback() }
    }

    /// `refresh()` from any queue: inline on main, otherwise hopped to main asynchronously.
    func refreshOnMain() {
        if Thread.isMainThread { refresh() } else { DispatchQueue.main.async { [self] in refresh() } }
    }

    /// Uncached lookup on the current layout. Main queue only.
    func resolveKeyCodeNow(for character: Character) -> CGKeyCode? {
        dispatchPrecondition(condition: .onQueue(.main))
        return provider.keyCode(for: character)
    }

    /// `callback` runs on main after every refresh (layout switch or initial prime).
    @discardableResult
    func addChangeListener(_ callback: @escaping () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        listeners[token] = callback
        lock.unlock()
        return token
    }

    func removeChangeListener(_ token: UUID) {
        lock.lock()
        listeners[token] = nil
        lock.unlock()
    }
}
