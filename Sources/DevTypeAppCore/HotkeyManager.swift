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

/// Registers global Carbon hotkeys for inline search (⌘/), AI palette, and optional text/URL macros.
final class HotkeyManager {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private var inlineSearchHotkeyID: UInt32?
    private var aiPaletteHotkeyID: UInt32?
    private var voiceDictationHotkeyID: UInt32?
    private var macroByID: [UInt32: HotkeyMacroAction] = [:]

    var onInlineSearch: (() -> Void)?
    var onAIPalette: (() -> Void)?
    var onVoiceDictation: (() -> Void)?
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

    /// Persisted in `devtype.hotkey.aiPalette`. Defaults to ⌘⌥A.
    var aiPaletteShortcut: DevTypeShortcut = HotkeyPreferences.aiPaletteShortcut

    /// Persisted in `devtype.voice.hotkey`. Defaults to ⌘⌥V.
    var voiceShortcut: DevTypeShortcut = HotkeyPreferences.voiceShortcut

    func registerAll() {
        installHandlerIfNeeded()
        unregisterAll()
        lastMacroRegistrationFailures.removeAll()
        // The kill switch unregisters everything and registers nothing — checked here, at the
        // single choke point, so a toggle mid-session takes effect on the next registerAll()
        // and a rebind while disabled still persists without silently re-enabling.
        guard !HotkeyPreferences.shortcutsDisabled else {
            DevTypeLog.app.info("[App] hotkeys disabled by preference — nothing registered")
            return
        }
        registerInlineSearch()
        registerAIPalette()
        registerVoiceDictation()
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
        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        return lastRegistrationStatus
    }

    /// Rebinds the AI action-palette shortcut, persists it, and re-registers.
    @discardableResult
    func applyAIPaletteShortcut(_ shortcut: DevTypeShortcut) -> OSStatus {
        HotkeyPreferences.aiPaletteShortcut = shortcut
        aiPaletteShortcut = shortcut
        lastAIPaletteRegistrationStatus = noErr
        registerAll()
        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        return lastAIPaletteRegistrationStatus
    }

    /// Rebinds the Voice Dictation shortcut, persists it, and re-registers.
    @discardableResult
    func applyVoiceShortcut(_ shortcut: DevTypeShortcut) -> OSStatus {
        HotkeyPreferences.voiceShortcut = shortcut
        voiceShortcut = shortcut
        lastVoiceRegistrationStatus = noErr
        registerAll()
        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        return lastVoiceRegistrationStatus
    }

    /// §4.3: replaces the macro list, persists it, and re-registers.
    ///
    /// Returns one entry per macro whose registration failed (human-readable
    /// shortcut + status). `onRegistrationFailed` alone was not enough: the app
    /// delegate suppresses it while Preferences is visible on the assumption that
    /// Preferences reports inline — but nothing checked macros there, so a chord
    /// owned by another app produced a table row that silently did nothing forever.
    @discardableResult
    func applyMacros(_ updated: [HotkeyMacroAction]) -> [(label: String, status: OSStatus)] {
        HotkeyPreferences.saveMacros(updated)
        macros = updated
        registerAll()
        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        return lastMacroRegistrationFailures
    }

    /// Status from the most recent inline-search registration attempt.
    private(set) var lastRegistrationStatus: OSStatus = noErr

    /// Status from the most recent AI-palette registration attempt.
    private(set) var lastAIPaletteRegistrationStatus: OSStatus = noErr

    /// Status from the most recent Voice Dictation registration attempt.
    private(set) var lastVoiceRegistrationStatus: OSStatus = noErr

    /// Failures from the most recent macro re-registration, surfaced by
    /// Preferences after `applyMacros(_:)`.
    private(set) var lastMacroRegistrationFailures: [(label: String, status: OSStatus)] = []

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

    /// The four-char signature every DevType hot key is registered under.
    private static let hotkeySignature = OSType(0x4454_5059) // DTYP

    /// Allocates an id and asks Carbon for the shortcut, retaining the returned ref on
    /// success. All four registration paths — the three built-ins and each macro —
    /// shared this verbatim and differ only in what they do with the outcome.
    private func claimHotkey(keyCode: UInt32, modifiers: UInt32) -> (id: UInt32, status: OSStatus) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.hotkeySignature, id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref { refs[id] = ref }
        return (id, status)
    }

    /// Registers one of the three built-in shortcuts. Returns the claimed id, or `nil`
    /// when Carbon refused — §4.2: a refusal is no longer a silent log-and-forget, so
    /// every one of these tells the user through `onRegistrationFailed`.
    private func registerBuiltIn(
        _ shortcut: DevTypeShortcut,
        named name: String
    ) -> (id: UInt32?, status: OSStatus) {
        let claim = claimHotkey(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers)
        let label = shortcut.displayString
        guard claim.status == noErr, refs[claim.id] != nil else {
            DevTypeLog.app.error(
                "[Hotkey] \(name, privacy: .public) registration failed shortcut=\(label, privacy: .public) status=\(claim.status, privacy: .public)"
            )
            onRegistrationFailed?(label, claim.status)
            return (nil, claim.status)
        }
        DevTypeLog.app.info("[Hotkey] \(name, privacy: .public) registered (\(label, privacy: .public))")
        return (claim.id, claim.status)
    }

    private func registerInlineSearch() {
        // §4.2: was `kVK_ANSI_Slash` + `cmdKey`, hardcoded. Now read from
        // `HotkeyPreferences` so the Preferences recorder can rebind it.
        let result = registerBuiltIn(inlineSearchShortcut, named: "inline search")
        lastRegistrationStatus = result.status
        if let id = result.id { inlineSearchHotkeyID = id }
    }

    private func registerAIPalette() {
        let result = registerBuiltIn(aiPaletteShortcut, named: "AI palette")
        lastAIPaletteRegistrationStatus = result.status
        if let id = result.id { aiPaletteHotkeyID = id }
    }

    private func registerVoiceDictation() {
        let result = registerBuiltIn(voiceShortcut, named: "Voice dictation")
        lastVoiceRegistrationStatus = result.status
        if let id = result.id { voiceDictationHotkeyID = id }
    }

    private func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        inlineSearchHotkeyID = nil
        aiPaletteHotkeyID = nil
        voiceDictationHotkeyID = nil
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
        // Ownership invariant: the refcon is `passUnretained`, which is safe ONLY because
        // AppDelegate owns this manager for the process lifetime (see AppDelegate) — Carbon
        // dispatch never retains it. If ownership ever moves, switch to `passRetained` plus a
        // release in `deinit` or every hotkey press becomes a use-after-free.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // A failed handler installation means every registration "succeeds" while
        // nothing ever fires — the total-death shape §4.2 fixed for registration,
        // still open for dispatch. Fail loudly at both channels.
        let installStatus = InstallEventHandler(
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
        handlerInstalled = installStatus == noErr
        if installStatus != noErr {
            DevTypeLog.app.fault(
                "[Hotkey] handler installation failed status=\(installStatus, privacy: .public) — hotkeys will not fire"
            )
            onRegistrationFailed?("(all shortcuts)", installStatus)
        }
    }

    private func registerMacro(_ macro: HotkeyMacroAction) {
        let (id, status) = claimHotkey(keyCode: macro.keyCode, modifiers: macro.modifiers)
        if status == noErr, refs[id] != nil {
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
            lastMacroRegistrationFailures.append((label, status))
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
        if id == aiPaletteHotkeyID {
            DispatchQueue.main.async { [weak self] in
                self?.onAIPalette?()
            }
            return
        }
        if id == voiceDictationHotkeyID {
            DispatchQueue.main.async { [weak self] in
                self?.onVoiceDictation?()
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
