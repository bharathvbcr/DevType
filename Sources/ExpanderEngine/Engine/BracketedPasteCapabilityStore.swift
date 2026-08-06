import Foundation

/// §3.10: per-app learning for bracketed paste, instead of wrapping unconditionally.
///
/// `TextInjectionPipeline.bracketPastePayload` wraps every shell-like paste in `ESC[200~` /
/// `ESC[201~`. Modern shells (readline ≥ 7, zsh, fish, iTerm2, Terminal.app) consume those markers
/// and treat the payload as literal text, which is exactly what we want — it stops a pasted
/// newline from executing. But a plain `cat`, a `read -p`, several REPLs, and SSH sessions to an
/// older system do **not** implement bracketed paste, and they receive the escape sequences as
/// visible garbage around the user's snippet.
///
/// There is no capability probe for this, so learn from evidence instead: after a bracketed paste,
/// if AX can read the focused field and the literal `ESC[200~` is sitting in it, this host does not
/// support bracketed paste and never gets it again.
///
/// Defaults stay fail-safe: an unknown shell-like host is still bracketed, because the failure mode
/// of *not* bracketing (a pasted newline runs a command) is far worse than a visible escape code.
public final class BracketedPasteCapabilityStore {
    public static let shared = BracketedPasteCapabilityStore(
        fileURL: BracketedPasteCapabilityStore.defaultFileURL()
    )

    public enum Verdict: Equatable {
        /// Never observed — bracket (the safe default) and watch the result.
        case unknown
        /// Markers were consumed by the host.
        case supported
        /// Markers were observed as literal text in the field — never bracket this app again.
        case unsupported
    }

    public static let bracketStart = "\u{1B}[200~"
    public static let bracketEnd = "\u{1B}[201~"

    /// Escape hatch, matching `ErasePreconditionChecker.disableDefaultsKey`'s style:
    /// `defaults write com.devtype.app DevTypeDisableBracketedPaste -bool YES`
    public static let disableDefaultsKey = "DevTypeDisableBracketedPaste"

    public static let persistenceFileName = "bracketed-paste-capability.json"
    public static let persistenceSchemaVersion = 1

    private let lock = UnfairLock()
    private var learned: [String: Verdict] = [:]

    /// `nil` disables persistence (tests, and the plain `init()`).
    private let fileURL: URL?
    private let ioQueue = DispatchQueue(label: "com.devtype.bracketedpaste.io", qos: .utility)
    private var savePending = false

    public convenience init() {
        self.init(fileURL: nil)
    }

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL {
            let parent = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            learned = Self.loadFromDisk(fileURL: fileURL)
        }
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("DevType", isDirectory: true)
        return dir.appendingPathComponent(persistenceFileName)
    }

    /// True when `text` carries a literal bracketed-paste marker — i.e. the host echoed it back
    /// instead of consuming it.
    public static func containsLiteralBracketMarkers(_ text: String) -> Bool {
        text.contains(bracketStart) || text.contains(bracketEnd)
    }

    // MARK: - Queries

    public func verdict(for bundleID: String?) -> Verdict {
        guard let bundleID, !bundleID.isEmpty, bundleID != "nil" else { return .unknown }
        lock.lock()
        let value = learned[bundleID]
        lock.unlock()
        return value ?? .unknown
    }

    /// The live decision used by the inject path. Only called for shell-like contexts.
    public func shouldBracketPaste(bundleID: String?) -> Bool {
        if UserDefaults.standard.bool(forKey: Self.disableDefaultsKey) { return false }
        return verdict(for: bundleID) != .unsupported
    }

    // MARK: - Learning

    public func recordSupported(bundleID: String?) {
        record(.supported, bundleID: bundleID)
    }

    public func recordUnsupported(bundleID: String?) {
        record(.unsupported, bundleID: bundleID)
    }

    /// Learns from the focused field's value after a bracketed paste. `nil` / unreadable values
    /// teach nothing — AX-opaque terminals simply stay on the safe default.
    public func learn(fromObservedValue value: String?, bundleID: String?) {
        guard let value, !value.isEmpty else { return }
        if Self.containsLiteralBracketMarkers(value) {
            recordUnsupported(bundleID: bundleID)
        } else {
            // The markers are gone from a field we *can* read: the host consumed them.
            recordSupported(bundleID: bundleID)
        }
    }

    private func record(_ verdict: Verdict, bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty, bundleID != "nil" else { return }
        lock.lock()
        let previous = learned[bundleID]
        learned[bundleID] = verdict
        let changed = previous != verdict
        lock.unlock()
        guard changed else { return }
        switch verdict {
        case .unsupported:
            DevTypeLog.inject.notice(
                "[Inject] §3.10 bracketed paste condemned for \(bundleID, privacy: .public) — literal ESC[200~ observed in the field; plain paste from now on"
            )
        case .supported:
            DevTypeLog.inject.info(
                "[Inject] §3.10 bracketed paste confirmed for \(bundleID, privacy: .public)"
            )
        case .unknown:
            break
        }
        scheduleSave()
    }

    /// Test / recovery hook.
    public func reset() {
        lock.lock()
        learned.removeAll()
        lock.unlock()
        scheduleSave()
    }

    /// Diagnostic dump: `bundleID -> verdict`, sorted.
    public func learnedVerdicts() -> [(key: String, verdict: Verdict)] {
        lock.lock()
        let snapshot = learned
        lock.unlock()
        return snapshot
            .map { (key: $0.key, verdict: $0.value) }
            .sorted { $0.key < $1.key }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard let fileURL else { return }
        lock.lock()
        if savePending {
            lock.unlock()
            return
        }
        savePending = true
        lock.unlock()

        ioQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.savePending = false
            let snapshot = self.learned
            self.lock.unlock()
            Self.saveToDisk(snapshot, fileURL: fileURL)
        }
    }

    private struct PersistedFile: Codable {
        var version: Int
        /// bundle ID -> "supported" / "unsupported".
        var entries: [String: String]
    }

    private static func rawValue(for verdict: Verdict) -> String? {
        switch verdict {
        case .unknown: return nil
        case .supported: return "supported"
        case .unsupported: return "unsupported"
        }
    }

    private static func verdict(fromRaw raw: String) -> Verdict? {
        switch raw {
        case "supported": return .supported
        case "unsupported": return .unsupported
        default: return nil
        }
    }

    private static func loadFromDisk(fileURL: URL) -> [String: Verdict] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(PersistedFile.self, from: data) else {
            return [:]
        }
        guard file.version <= persistenceSchemaVersion else {
            DevTypeLog.inject.notice(
                "[Inject] bracketed-paste file schema \(file.version, privacy: .public) is newer than \(persistenceSchemaVersion, privacy: .public) — ignoring"
            )
            return [:]
        }
        var result: [String: Verdict] = [:]
        for (key, raw) in file.entries {
            guard !key.isEmpty, let verdict = verdict(fromRaw: raw) else { continue }
            result[key] = verdict
        }
        return result
    }

    private static func saveToDisk(_ verdicts: [String: Verdict], fileURL: URL) {
        var entries: [String: String] = [:]
        for (key, verdict) in verdicts {
            guard let raw = rawValue(for: verdict) else { continue }
            entries[key] = raw
        }
        let file = PersistedFile(version: persistenceSchemaVersion, entries: entries)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DevTypeLog.inject.error(
                "[Inject] Failed to persist bracketed-paste verdicts: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
