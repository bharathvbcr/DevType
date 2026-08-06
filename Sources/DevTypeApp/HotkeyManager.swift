import AppKit
import Carbon
import Carbon.HIToolbox
import ExpanderEngine

/// Optional hotkey macro (insertText / openURL only — no shell/AppleScript).
struct HotkeyMacroAction: Equatable {
    enum Kind: String { case insertText, openURL }
    var id: UInt32
    var keyCode: UInt32
    var modifiers: UInt32
    var kind: Kind
    var argument: String
}

/// Registers global Carbon hotkeys for inline search (⌘/) and optional text/URL macros.
final class HotkeyManager {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private var inlineSearchHotkeyID: UInt32?
    private var macroByID: [UInt32: HotkeyMacroAction] = [:]

    var onInlineSearch: (() -> Void)?
    var onInsertText: ((String) -> Void)?
    var onOpenURL: ((String) -> Void)?
    /// §4.2: `RegisterEventHotKey` failure used to be logged and dropped, so a
    /// shortcut claimed by another app silently did nothing forever. Preferences
    /// (and the app delegate) hook this to tell the user.
    /// Parameters: human-readable shortcut, OSStatus.
    var onRegistrationFailed: ((String, OSStatus) -> Void)?
    /// Device-local macros loaded from UserDefaults (`devtype.hotkeyMacros`).
    var macros: [HotkeyMacroAction] = HotkeyManager.loadMacros()

    /// §4.2: user-configurable, persisted in `devtype.hotkey.inlineSearch`.
    /// Defaults to ⌘/ for compatibility with the old hardcoded binding.
    var inlineSearchShortcut: DevTypeShortcut = HotkeyPreferences.inlineSearchShortcut

    func registerAll() {
        installHandlerIfNeeded()
        unregisterAll()
        registerInlineSearch()
        for macro in macros where macro.keyCode != 0 {
            registerMacro(macro)
        }
    }

    /// §4.2: rebinds the palette shortcut, persists it, and re-registers.
    /// Returns `noErr` on success so Preferences can surface the failure inline
    /// as well as through `onRegistrationFailed`.
    @discardableResult
    func applyInlineSearchShortcut(_ shortcut: DevTypeShortcut) -> OSStatus {
        HotkeyPreferences.inlineSearchShortcut = shortcut
        inlineSearchShortcut = shortcut
        lastRegistrationStatus = noErr
        registerAll()
        return lastRegistrationStatus
    }

    /// §4.3: replaces the macro list, persists it, and re-registers.
    func applyMacros(_ updated: [HotkeyMacroAction]) {
        HotkeyPreferences.saveMacros(updated)
        macros = updated
        registerAll()
    }

    /// Status from the most recent inline-search registration attempt.
    private(set) var lastRegistrationStatus: OSStatus = noErr

    static func loadMacros() -> [HotkeyMacroAction] {
        guard let data = UserDefaults.standard.data(forKey: "devtype.hotkeyMacros"),
              let decoded = try? JSONDecoder().decode([CodableMacro].self, from: data) else {
            return []
        }
        return decoded.map {
            HotkeyMacroAction(
                id: 0,
                keyCode: $0.keyCode,
                modifiers: $0.modifiers,
                kind: HotkeyMacroAction.Kind(rawValue: $0.kind) ?? .insertText,
                argument: $0.argument
            )
        }
    }

    private struct CodableMacro: Codable {
        var keyCode: UInt32
        var modifiers: UInt32
        var kind: String
        var argument: String
    }

    private func registerInlineSearch() {
        // §4.2: was `kVK_ANSI_Slash` + `cmdKey`, hardcoded. Now read from
        // `HotkeyPreferences` so the Preferences recorder can rebind it.
        let shortcut = inlineSearchShortcut
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4454_5059), id: id) // DTYP
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        lastRegistrationStatus = status
        let label = shortcut.displayString
        if status == noErr, let ref {
            refs[id] = ref
            inlineSearchHotkeyID = id
            DevTypeLog.app.info("[Hotkey] inline search registered (\(label, privacy: .public))")
        } else {
            // §4.2: no longer a silent log-and-forget — the user is told.
            DevTypeLog.app.error(
                "[Hotkey] inline search registration failed shortcut=\(label, privacy: .public) status=\(status, privacy: .public)"
            )
            onRegistrationFailed?(label, status)
        }
    }

    private func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        inlineSearchHotkeyID = nil
        // §4.3: re-registering after an edit reuses fresh IDs; stale entries here
        // would keep firing removed macros.
        macroByID.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, refcon -> OSStatus in
                guard let event, let refcon else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.fire(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            refcon,
            nil
        )
        handlerInstalled = true
    }

    private func registerMacro(_ macro: HotkeyMacroAction) {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4454_5059), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            macro.keyCode,
            macro.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            refs[id] = ref
            var stored = macro
            stored.id = id
            macroByID[id] = stored
        } else {
            // §4.2/§4.3: macro registration failures were not even logged.
            let label = DevTypeShortcut(
                keyCode: macro.keyCode,
                carbonModifiers: macro.modifiers
            ).displayString
            DevTypeLog.app.error(
                "[Hotkey] macro registration failed shortcut=\(label, privacy: .public) status=\(status, privacy: .public)"
            )
            onRegistrationFailed?(label, status)
        }
    }

    private func fire(id: UInt32) {
        if id == inlineSearchHotkeyID {
            DispatchQueue.main.async { [weak self] in
                self?.onInlineSearch?()
            }
            return
        }
        if let macro = macroByID[id] {
            DispatchQueue.main.async { [weak self] in
                switch macro.kind {
                case .insertText: self?.onInsertText?(macro.argument)
                case .openURL: self?.onOpenURL?(macro.argument)
                }
            }
        }
    }
}
