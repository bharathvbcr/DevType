import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// §8.1: every CGEvent this app posts, and nothing else. Zero AX, zero pasteboard.
///
/// Two rules hold for everything in here:
///
/// 1. **Every** event we post must carry `SyntheticEventMarker.magicUserData` in its source's
///    `userData`, because `EventTapEngine`'s callback uses exactly that to tell our own events
///    apart from the user's. An untagged event we post is indistinguishable from typing (§1.2).
/// 2. A posted arrow / backspace moves or deletes one **grapheme cluster**, never one UTF-16 code
///    unit. Anything converting an AX range into a key-press count has to convert units (§1.6).
public final class HIDKeyPoster {
    public static let shared = HIDKeyPoster()

    /// §2.7: `resolveVirtualKeyCodeForChar` brute-forces up to 128 `UCKeyTranslate` calls. It used
    /// to run on main for every ⌘V *and* every paste retry, to look up the same constant. The
    /// answer only changes when the keyboard input source changes, so cache it per source ID.
    private let lock = UnfairLock()
    private var cachedSourceID: String?
    private var cachedKeyCodes: [Character: CGKeyCode] = [:]

    public init() {}

    // MARK: - Event source

    /// §1.2: the only sanctioned way to build a source. Tagging is not optional — an untagged
    /// reinjected key lands in the tap's ring buffer and can re-fire the snippet that produced it
    /// (`restoreTriggerAfterFailedPaste` runs from a deferred re-verify, long after `isExpanding`
    /// has already been cleared, so `isExpanding` is *not* a backstop).
    public func makeTaggedEventSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .privateState) ?? CGEventSource(stateID: .hidSystemState)
        source?.userData = SyntheticEventMarker.magicUserData
        return source
    }

    // MARK: - Unicode key events

    /// Posts a keyDown/keyUp carrying `unicode` (best-effort delivery; post ≠ guaranteed delivery).
    @discardableResult
    public func postUnicodeKeyEvent(unicode: String, keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard CGPreflightPostEventAccess() else { return false }
        // §1.2: was a bare `CGEventSource(stateID:)` — the reinjected trigger key was therefore
        // seen by our own tap as user input and could re-trigger the same expansion.
        let source = makeTaggedEventSource()
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = flags
        up.flags = flags
        if !unicode.isEmpty {
            let utf16 = Array(unicode.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                }
            }
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Trailing keys

    /// Posts `%key:` trailing keys after successful inject (enter/tab/…).
    public func postTrailingKeys(_ names: [String]) {
        guard !names.isEmpty, CGPreflightPostEventAccess() else { return }
        let source = makeTaggedEventSource()
        for name in names {
            guard let keyCode = Self.keyCode(forTrailingKeyName: name) else { continue }
            if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    public static func keyCode(forTrailingKeyName name: String) -> CGKeyCode? {
        switch name.lowercased() {
        case "enter", "return": return CGKeyCode(kVK_Return)
        case "tab": return CGKeyCode(kVK_Tab)
        case "escape", "esc": return CGKeyCode(kVK_Escape)
        case "space": return CGKeyCode(kVK_Space)
        default: return nil
        }
    }

    // MARK: - Cmd+V

    /// Physical ⌘V: Command down → V → Command up. Flag-only ⌘V fails under many IMEs.
    /// Used only on the HID clipboard paste path — never on AX range replace.
    ///
    /// Synchronous form: kept for callers that need a `Bool` right now, but it blocks the calling
    /// thread for `2 × cmdVModifierGap`. Prefer `postCmdVKeyEventsAsync` on the main thread.
    @discardableResult
    public func postCmdVKeyEvents() -> Bool {
        // Re-check at post time — CGEvent create-success is not delivery proof if Post was revoked.
        guard CGPreflightPostEventAccess() else {
            DevTypeLog.inject.error(
                "[Inject] Cmd+V refused — CGPreflightPostEventAccess false at post time"
            )
            return false
        }

        let source = makeTaggedEventSource()
        let command = CGKeyCode(kVK_Command)
        let vKeyCode = virtualKeyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)

        var commandIsDown = false
        if let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true) {
            cmdDown.flags = .maskCommand
            cmdDown.post(tap: .cghidEventTap)
            commandIsDown = true
        }
        usleep(useconds_t(InjectTiming.cmdVModifierGap * 1_000_000))

        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            DevTypeLog.inject.error(
                "[Inject] Cmd+V CGEvent create failed — Post Events may be revoked or CG HID unavailable"
            )
            // Command was already pressed; bailing without releasing it leaves the modifier stuck
            // down system-wide.
            if commandIsDown {
                releaseCommand(source: source, command: command)
            }
            return false
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        usleep(useconds_t(InjectTiming.cmdVModifierGap * 1_000_000))

        releaseCommand(source: source, command: command)
        return true
    }

    /// §2.7: same key sequence, scheduled instead of slept. Removes 30 ms of hard main-thread
    /// block per paste (60 ms with the hold-loop retry). `completion` runs on main.
    public func postCmdVKeyEventsAsync(completion: @escaping (Bool) -> Void) {
        guard CGPreflightPostEventAccess() else {
            DevTypeLog.inject.error(
                "[Inject] Cmd+V refused — CGPreflightPostEventAccess false at post time"
            )
            completion(false)
            return
        }

        let source = makeTaggedEventSource()
        let command = CGKeyCode(kVK_Command)
        let vKeyCode = virtualKeyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)

        var commandIsDown = false
        if let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true) {
            cmdDown.flags = .maskCommand
            cmdDown.post(tap: .cghidEventTap)
            commandIsDown = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.cmdVModifierGap) {
            guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
                  let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
                DevTypeLog.inject.error(
                    "[Inject] Cmd+V CGEvent create failed — Post Events may be revoked or CG HID unavailable"
                )
                if commandIsDown {
                    self.releaseCommand(source: source, command: command)
                }
                completion(false)
                return
            }
            vDown.flags = .maskCommand
            vUp.flags = .maskCommand
            vDown.post(tap: .cghidEventTap)
            vUp.post(tap: .cghidEventTap)

            DispatchQueue.main.asyncAfter(deadline: .now() + InjectTiming.cmdVModifierGap) {
                self.releaseCommand(source: source, command: command)
                completion(true)
            }
        }
    }

    private func releaseCommand(source: CGEventSource?, command: CGKeyCode) {
        if let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false) {
            cmdUp.flags = []
            cmdUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Virtual key lookup

    /// Virtual key code producing `targetChar` on the current layout, cached per input source.
    /// Falls back to `9` (ANSI "v") exactly as the pre-cache implementation did.
    public func virtualKeyCode(for targetChar: Character) -> CGKeyCode? {
        let sourceID = Self.currentInputSourceID()

        lock.lock()
        if cachedSourceID != sourceID {
            cachedSourceID = sourceID
            cachedKeyCodes.removeAll(keepingCapacity: true)
        }
        let cached = cachedKeyCodes[targetChar]
        lock.unlock()
        if let cached { return cached }

        let resolved = Self.resolveVirtualKeyCodeForChar(targetChar)

        lock.lock()
        // Only keep the entry if the source has not changed underneath the (unlocked) resolve.
        if cachedSourceID == sourceID {
            cachedKeyCodes[targetChar] = resolved
        }
        lock.unlock()
        return resolved
    }

    private static func currentInputSourceID() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPointer = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) else {
            return nil
        }
        return unsafeBitCast(idPointer, to: CFString.self) as String
    }

    /// The uncached brute-force scan. 128 `UCKeyTranslate` calls — never call this per paste.
    public static func resolveVirtualKeyCodeForChar(_ targetChar: Character) -> CGKeyCode {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return 9
        }

        let data = unsafeBitCast(layoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return 9 }

        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { keyboardLayout -> CGKeyCode in
            var chars = [UniChar](repeating: 0, count: 4)
            var realLength = 0

            for code: CGKeyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                let status = UCKeyTranslate(
                    keyboardLayout,
                    code,
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(KBGetLayoutType(0)),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    4,
                    &realLength,
                    &chars
                )
                if status == noErr && realLength > 0 {
                    let str = String(utf16CodeUnits: chars, count: realLength)
                    if str.lowercased() == String(targetChar).lowercased() {
                        return code
                    }
                }
            }
            return 9
        }
    }

    // MARK: - Backspaces

    public func sendBackspaces(count: Int) {
        guard count > 0 else { return }
        guard CGPreflightPostEventAccess() else {
            DevTypeLog.inject.error(
                "[Inject] backspace refused — CGPreflightPostEventAccess false at post time count=\(count, privacy: .public)"
            )
            return
        }
        let source = makeTaggedEventSource()
        var posted = 0
        for _ in 0..<count {
            if let bDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
               let bUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false) {
                bDown.post(tap: .cghidEventTap)
                bUp.post(tap: .cghidEventTap)
                posted += 1
            }
        }
        if posted == 0 {
            DevTypeLog.inject.error(
                "[Inject] backspace CGEvent create failed count=\(count, privacy: .public) — Post Events may be revoked"
            )
        } else if posted < count {
            DevTypeLog.inject.notice(
                "[Inject] backspace CGEvent partial posted=\(posted, privacy: .public)/\(count, privacy: .public)"
            )
        }
    }

    public func sendBackspacesAsync(count: Int, completion: @escaping () -> Void) {
        guard count > 0 else {
            completion()
            return
        }
        sendBackspaces(count: count)
        let settle = Double(count) * InjectTiming.backspacePerKeyDelay + InjectTiming.backspaceTrailingDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: completion)
    }

    // MARK: - Left arrows

    public func sendLeftArrows(count: Int) {
        guard count > 0 else { return }
        guard CGPreflightPostEventAccess() else {
            DevTypeLog.inject.error(
                "[Inject] left-arrow refused — CGPreflightPostEventAccess false at post time count=\(count, privacy: .public)"
            )
            return
        }
        // §1.2: was a bare `CGEventSource(stateID:)`. Untagged arrows are visible to our own tap.
        let source = makeTaggedEventSource()
        var posted = 0
        for _ in 0..<count {
            if let aDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: true),
               let aUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_LeftArrow), keyDown: false) {
                aDown.post(tap: .cghidEventTap)
                aUp.post(tap: .cghidEventTap)
                posted += 1
            }
        }
        if posted == 0 {
            DevTypeLog.inject.error(
                "[Inject] left-arrow CGEvent create failed count=\(count, privacy: .public) — Post Events may be revoked"
            )
        } else if posted < count {
            DevTypeLog.inject.notice(
                "[Inject] left-arrow CGEvent partial posted=\(posted, privacy: .public)/\(count, privacy: .public)"
            )
        }
    }

    public func sendLeftArrowsAsync(count: Int, completion: @escaping () -> Void) {
        guard count > 0 else {
            completion()
            return
        }
        sendLeftArrows(count: count)
        let settle = Double(count) * InjectTiming.arrowPerKeyDelay + InjectTiming.arrowTrailingDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: completion)
    }

    // MARK: - Unit conversion

    /// §1.6: how many `kVK_LeftArrow` presses move the caret back over the last
    /// `utf16OffsetFromEnd` **UTF-16 code units** of `text`.
    ///
    /// This is the same class of bug `ErasePlan` was written to eliminate: AX selected-text ranges
    /// are UTF-16 code units, a posted arrow moves one grapheme cluster. `positionCursorIfNeeded`
    /// used the UTF-16 count directly, so `{{cursor}}` placed before an emoji, an astral CJK
    /// character or any combining sequence overshot — and because the AX caret path is correct,
    /// this only ever bit the HID fallback, i.e. Chrome/Electron, the majority path.
    ///
    /// If the offset lands inside a grapheme cluster (only reachable from a hand-built offset),
    /// the index rounds down to the cluster start, so we move over the whole cluster rather than
    /// splitting it.
    public static func leftArrowCount(text: String, utf16OffsetFromEnd: Int) -> Int {
        guard utf16OffsetFromEnd > 0 else { return 0 }
        let total = text.utf16.count
        guard utf16OffsetFromEnd < total else { return text.count }
        let rawIndex = String.Index(utf16Offset: total - utf16OffsetFromEnd, in: text)
        // Mid-cluster UTF-16 offsets (ZWJ emoji, flags) must round down to the
        // grapheme start; otherwise the suffix Character view can invent extra
        // clusters from a torn sequence and overshoot `text.count`.
        let splitIndex = text.rangeOfComposedCharacterSequence(at: rawIndex).lowerBound
        return text[splitIndex...].count
    }
}
