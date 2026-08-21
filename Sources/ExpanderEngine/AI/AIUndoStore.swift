import Foundation

/// Stashes the pre-transform selection for `.direct` AI replaces so the palette
/// can offer "Undo last AI". Single-slot, process-local (not persisted).
public enum AIUndoStore {
    private static let lock = NSLock()
    private static var originalText: String?

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

    /// Test / reset hook.
    public static func clear() {
        lock.lock()
        originalText = nil
        lock.unlock()
    }
}
