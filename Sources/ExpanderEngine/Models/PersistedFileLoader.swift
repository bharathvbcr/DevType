import Foundation

/// The one load-or-quarantine path for small persisted settings files and UserDefaults blobs.
///
/// A store that loads with `try?` turns a corrupt or unreadable file into "empty", and its next
/// save then overwrites the only copy of the user's data with no record of why. This helper
/// separates the three cases every such store has:
///
/// - **absent** (no file, or a zero-byte file that holds nothing to lose): the normal first-run
///   state, no log, the caller uses its empty default.
/// - **loaded**: the bytes decoded.
/// - **unreadable**: the bytes could not be read or decoded. The file is moved aside (never
///   deleted, never overwritten) and one public-safe diagnostic line names the store and the
///   error. The caller uses its empty default and may save freely, because the original bytes
///   now live at `preservedAt`.
///
/// Generic over the decoded value so a merged usage-stats store can call it directly.
public enum PersistedFileLoader {
    public enum Outcome<Value> {
        case absent
        case loaded(Value)
        /// `preservedAt` is nil only when the quarantine itself failed; that failure is logged.
        case unreadable(preservedAt: URL?)

        /// The decoded value, or nil for both `absent` and `unreadable`.
        public var value: Value? {
            if case .loaded(let value) = self { return value }
            return nil
        }
    }

    /// Bound on side-by-side quarantined copies of one defaults key.
    public static let maximumQuarantinedCopies = 8

    private static let observerLock = NSLock()
    private static var observerStorage: ((String) -> Void)?

    /// Test seam: receives every diagnostic line this helper emits, in addition to OSLog.
    public static var observer: ((String) -> Void)? {
        get { observerLock.lock(); defer { observerLock.unlock() }; return observerStorage }
        set { observerLock.lock(); observerStorage = newValue; observerLock.unlock() }
    }

    public static func load<Value>(
        store: String,
        fileURL: URL,
        decode: (Data) throws -> Value
    ) -> Outcome<Value> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return quarantine(store: store, fileURL: fileURL, error: error)
        }
        if data.isEmpty { return .absent }
        do {
            return .loaded(try decode(data))
        } catch {
            return quarantine(store: store, fileURL: fileURL, error: error)
        }
    }

    /// Moves `fileURL` aside as `<name>.unreadable`, or `<name>.unreadable.<uuid>` when that
    /// name is taken, so an earlier quarantined copy is never replaced.
    private static func quarantine<Value>(
        store: String,
        fileURL: URL,
        error: Error
    ) -> Outcome<Value> {
        let fm = FileManager.default
        var aside = fileURL.appendingPathExtension("unreadable")
        if fm.fileExists(atPath: aside.path) {
            aside = fileURL.appendingPathExtension("unreadable.\(UUID().uuidString)")
        }
        do {
            try fm.moveItem(at: fileURL, to: aside)
            report(
                "[Store] \(store) unreadable (\(DevTypeLog.errorMetadata(error))); "
                    + "preserved original \(DevTypeLog.publicPathMetadata(aside.path)); starting empty"
            )
            return .unreadable(preservedAt: aside)
        } catch let moveError {
            report(
                "[Store] \(store) unreadable (\(DevTypeLog.errorMetadata(error))) and quarantine failed "
                    + "(\(DevTypeLog.errorMetadata(moveError))) \(DevTypeLog.publicPathMetadata(fileURL.path)); "
                    + "starting empty"
            )
            return .unreadable(preservedAt: nil)
        }
    }

    /// UserDefaults flavour: when `key` holds a value that `validate` rejects, copies the raw
    /// value to `<key>.unreadable.<unix-seconds>` (reusing a copy that already holds the same bytes) and
    /// logs. The original key is left for the caller's next save to replace; the bytes survive
    /// in the copy. Returns the quarantine key, or nil when there was nothing to preserve or
    /// the copy could not be made.
    @discardableResult
    public static func preserveUndecodableDefaultsValue(
        store: String,
        key: String,
        defaults: UserDefaults = .standard,
        validate: (Data) throws -> Void
    ) -> String? {
        guard let object = defaults.object(forKey: key) else { return nil }
        let failure: Error
        if let data = object as? Data {
            if data.isEmpty { return nil }
            do { try validate(data); return nil } catch { failure = error }
        } else {
            // A non-Data value under a Data key is itself the corruption.
            failure = CocoaError(.coderReadCorrupt)
        }
        let prefix = "\(key).unreadable."
        let existingKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        if let current = object as? Data {
            for existingKey in existingKeys where (defaults.object(forKey: existingKey) as? Data) == current {
                return existingKey
            }
        }
        guard existingKeys.count < maximumQuarantinedCopies else {
            report(
                "[Store] \(store) unreadable (\(DevTypeLog.errorMetadata(failure))); "
                    + "quarantine capacity reached, raw value not preserved"
            )
            return nil
        }
        let stamp = Int(Date().timeIntervalSince1970)
        var target = "\(prefix)\(stamp)"
        if defaults.object(forKey: target) != nil { target += ".\(UUID().uuidString.prefix(8))" }
        defaults.set(object, forKey: target)
        report(
            "[Store] \(store) unreadable (\(DevTypeLog.errorMetadata(failure))); "
                + "preserved raw value under \(target)"
        )
        return target
    }

    /// Single sink for store-failure diagnostics: OSLog (public-safe text only) plus the test observer.
    public static func report(_ line: String) {
        DevTypeLog.store.error("\(line, privacy: .public)")
        observer?(line)
    }
}
