import AppKit
import CoreGraphics
import Foundation
import SafariHarnessCore

enum HIDError: Error, CustomStringConvertible {
    case eventCreationFailed(UInt16)
    case postAccessLost

    var description: String {
        switch self {
        case .eventCreationFailed(let code): return "CGEvent could not be created for key code \(code)"
        case .postAccessLost: return "posting events is no longer allowed for this process"
        }
    }
}

/// Posts real keyboard events at the HID tap, the way a keyboard driver would.
///
/// The source is `.hidSystemState` and its `userData` is left at 0: these events are untagged, so
/// DevType's tap treats them as the user's. DevType's own injections use a `.privateState` source
/// stamped with `SyntheticEventMarker.magicUserData` (`HIDKeyPoster.makeTaggedEventSource`) so its
/// tap ignores them; this harness must never carry that stamp or DevType would skip every key.
final class HIDKeyboard: KeyboardPort {
    private let source: CGEventSource?
    private var heldModifierKeys: Set<UInt16> = []

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        source?.userData = 0
    }

    func post(_ event: KeyEvent) throws {
        guard CGPreflightPostEventAccess() else { throw HIDError.postAccessLost }
        guard let cg = CGEvent(keyboardEventSource: source, virtualKey: event.keyCode, keyDown: event.down) else {
            throw HIDError.eventCreationFailed(event.keyCode)
        }
        let modifier = Modifier.allCases.first(where: { $0.keyCode == event.keyCode })
        // CGEvent already builds a modifier keycode as a `.flagsChanged` event whose flags carry the
        // device-dependent left/right bits (checked offline: key code 56 gives type 12, not keyDown).
        // Overwriting those flags would drop the bits some apps use to tell the sides apart, so only
        // ordinary keys get explicit flags.
        if modifier == nil { cg.flags = CGEventFlags(rawValue: event.flags.rawValue) }
        cg.post(tap: .cghidEventTap)
        if let modifier {
            if event.down { heldModifierKeys.insert(modifier.keyCode) } else { heldModifierKeys.remove(modifier.keyCode) }
        }
    }

    func releaseHeldModifiers() {
        for code in heldModifierKeys {
            if let cg = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
                cg.flags = []
                cg.post(tap: .cghidEventTap)
            }
        }
        heldModifierKeys.removeAll()
    }
}

/// The real general pasteboard. Constructed only for a live run.
final class SystemClipboard: ClipboardPort {
    /// A pasteboard bigger than this is not copied byte for byte; the run refuses rather than
    /// pretending it can restore it.
    static let maxBytes = 32 * 1024 * 1024

    func snapshot() throws -> ClipboardSnapshot {
        var total = 0
        var items: [[String: Data]] = []
        for item in NSPasteboard.general.pasteboardItems ?? [] {
            var entry: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > Self.maxBytes {
                    throw NSError(domain: "SafariHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "clipboard holds more than \(Self.maxBytes / 1_048_576) MB; not copying it"])
                }
                entry[type.rawValue] = data
            }
            items.append(entry)
        }
        return ClipboardSnapshot(items: items)
    }

    func restore(_ snapshot: ClipboardSnapshot) throws {
        let board = NSPasteboard.general
        // Built before the board is cleared, so nothing that can fail sits between clearing the
        // user's clipboard and writing it back; a refused write is retried once before giving up.
        let items = snapshot.items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        board.clearContents()
        guard !items.isEmpty else { return }
        if board.writeObjects(items) { return }
        board.clearContents()
        guard board.writeObjects(items) else {
            throw NSError(domain: "SafariHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: "pasteboard refused the restored items twice"])
        }
    }
}

/// Reads the page through Safari's "Allow JavaScript from Apple Events". Read-only except for the
/// page's own reset function. Every script is guarded so it only answers on the harness page.
final class JSBridge {
    private(set) var available = false
    private(set) var reason: String?

    private static let guardExpr = "(document.title===\"\(HarnessConstants.pageTitle)\"&&window.__dth)"

    func probe() {
        guard let out = run("\(Self.guardExpr)?\"ok\":\"NOT-HARNESS\"") else { return }
        if out == "ok" { available = true; reason = nil } else { reason = "the front Safari tab is not the harness page" }
    }

    /// Runs `expression` in the front tab and returns its string result, or nil (recording why).
    private func run(_ expression: String) -> String? {
        let escaped = expression.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Safari\" to do JavaScript \"\(escaped)\" in current tab of front window"
        let result = SystemFacts.run("/usr/bin/osascript", ["-e", script], timeout: 8)
        if result.timedOut { reason = "osascript timed out"; return nil }
        guard result.status == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            reason = message.contains("Apple Events") || message.contains("1743") || message.contains("not allowed")
                ? "Safari refused: enable Develop > Developer Settings > Allow JavaScript from Apple Events, and allow the Automation prompt (\(String(message.prefix(120))))"
                : String(message.prefix(200))
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func values() -> [String: String]? {
        guard available,
              let raw = run("\(Self.guardExpr)?JSON.stringify(window.__dth.snapshot()):\"NOT-HARNESS\""),
              let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let fields = root["fields"] as? [String: [String: Any]] else { return nil }
        return fields.compactMapValues { $0["value"] as? String }
    }

    func drain() -> [String] {
        guard available,
              let raw = run("\(Self.guardExpr)?JSON.stringify(window.__dth.drain()):\"[]\""),
              let data = raw.data(using: .utf8),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return entries.map { entry in
            let t = entry["t"] as? Int ?? 0
            let kind = entry["kind"] as? String ?? "?"
            let id = entry["id"] as? String ?? "?"
            let value = (entry["value"] as? String).map { " = " + String(reflecting: $0) } ?? ""
            return "+\(t)ms \(kind) \(id)\(value)"
        }
    }

    @discardableResult
    func reset() -> Bool {
        guard available else { return false }
        return run("\(Self.guardExpr)?(window.__dth.reset(),\"ok\"):\"NOT-HARNESS\"") == "ok"
    }
}
