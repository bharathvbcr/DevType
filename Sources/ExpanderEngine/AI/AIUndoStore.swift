import AppKit
import Foundation

/// Stashes the pre-transform selection for `.direct` AI replaces so the palette
/// can offer "Undo last AI". Single-slot, process-local (not persisted).
///
/// The stash holds a copy of the user's selection text, so it does not outlive the
/// session it belongs to: DevType resigning active clears it, exactly like
/// `BiometricGate.invalidate()` on resign. Walking away from the Mac and coming
/// back should not leave the previous selection pinned in memory indefinitely —
/// and "Undo last AI" offering text from before you switched apps is stale anyway.
public enum AIUndoStore {
    private static let lock = NSLock()
    private static var originalText: String?

    /// Installed once, on first use (`stash` is the only writer, so it forces
    /// installation). Block-based observer retained forever by the static — the
    /// store lives for the process, mirroring the AppDelegate's resign-active hook
    /// for `BiometricGate`. Main queue: `clear()` touches UI-adjacent state and
    /// callers already assume main-thread semantics.
    private static let resignActiveToken: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: .main
    ) { _ in clear() }

    public static var hasUndo: Bool {
        lock.lock()
        defer { lock.unlock() }
        return originalText != nil
    }

    /// Preview of the stashed original (truncated), for palette rows.
    public static var preview: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let text = originalText, !text.isEmpty else { return nil }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 80 ? String(flat.prefix(77)) + "…" : flat
    }

    public static func stash(_ text: String) {
        // Force the resign-active observer to exist before the first value lands,
        // so there is no window where a stash can outlive its clear hook.
        _ = resignActiveToken
        let trimmed = text
        guard !trimmed.isEmpty else { return }
        lock.lock()
        originalText = trimmed
        lock.unlock()
    }

    /// Returns and clears the stashed original, or `nil` when empty.
    public static func consume() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let value = originalText
        originalText = nil
        return value
    }

    /// Non-consuming read of the stashed original, or `nil` when empty.
    ///
    /// Exists for `AIPromptLeakGuard.injectionVerdict` at the injection seam: both AI
    /// flows stash the source selection immediately before handing off the result, so
    /// the guard can exempt prompt clauses the author's own text contains without
    /// racing the later Undo flow (`consume()` stays exclusive to it).
    public static func stashedOriginal() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return originalText
    }

    /// Drops the stashed original. Reached from the resign-active observer above;
    /// also the test / reset hook.
    public static func clear() {
        lock.lock()
        originalText = nil
        lock.unlock()
    }
}
