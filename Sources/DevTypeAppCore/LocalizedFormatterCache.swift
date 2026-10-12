import Foundation

/// One formatter per (kind, language code), built on first use and reused afterwards.
///
/// `DateFormatter`, `NumberFormatter` and friends are expensive to create (ICU data load), and the
/// Activity Center and Statistics screens used to build a fresh one per row or per value. The
/// language code is part of the key, so an in-app language switch simply resolves a different
/// entry and the previous language's formatters can never be served. System locale, time-zone and
/// calendar changes invalidate everything, because those alter output without changing the key.
///
/// Formatters are configured once inside `make` and never mutated afterwards by callers.
final class LocalizedFormatterCache: @unchecked Sendable {
    static let shared = LocalizedFormatterCache()

    private struct Key: Hashable {
        let kind: String
        let languageCode: String
    }

    private let lock = NSLock()
    private var entries: [Key: AnyObject] = [:]
    private var observers: [NSObjectProtocol] = []
    private var _buildCount = 0

    /// How many formatters have been constructed. A seam for tests that assert reuse.
    var buildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _buildCount
    }

    init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSLocale.currentLocaleDidChangeNotification,
            .NSSystemTimeZoneDidChange,
            .NSCalendarDayChanged
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.removeAll()
            }
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func removeAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func formatter<F: Formatter>(
        kind: String,
        languageCode: String,
        make: () -> F
    ) -> F {
        let key = Key(kind: kind, languageCode: languageCode)
        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[key] as? F { return cached }
        let created = make()
        entries[key] = created
        _buildCount += 1
        return created
    }
}
