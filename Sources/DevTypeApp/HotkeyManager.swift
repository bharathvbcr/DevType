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
    /// Device-local macros loaded from UserDefaults (`devtype.hotkeyMacros`).
    var macros: [HotkeyMacroAction] = HotkeyManager.loadMacros()

    func registerAll() {
        installHandlerIfNeeded()
        unregisterAll()
        registerInlineSearch()
        for macro in macros where macro.keyCode != 0 {
            registerMacro(macro)
        }
    }

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
        let keyCode = UInt32(kVK_ANSI_Slash)
        let modifiers = UInt32(cmdKey)
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4454_5059), id: id) // DTYP
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            refs[id] = ref
            inlineSearchHotkeyID = id
            DevTypeLog.app.info("[Hotkey] inline search registered (⌘/)")
        } else {
            DevTypeLog.app.error("[Hotkey] inline search registration failed status=\(status)")
        }
    }

    private func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        inlineSearchHotkeyID = nil
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
