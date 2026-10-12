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
///   now live at `preservedAt`. When the quarantine itself fails (`preservedAt` is nil) the
///   original is still the only copy, so the path is remembered as write-blocked: stores gate
///   every save through `permitWrite`, which refuses until the file is quarantined or gone.
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

    /// Test seam for the quarantine rename, so a failed move is reachable without a read-only volume.
    public static var moveItem: (URL, URL) throws -> Void {
        get { stateLock.lock(); defer { stateLock.unlock() }; return moveStorage }
        set { stateLock.lock(); moveStorage = newValue; stateLock.unlock() }
    }

    private static let stateLock = NSLock()
    private static var moveStorage: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    /// Files that were unreadable and could not be moved aside: saving over one destroys the only copy.
    private static var writeBlocked: Set<String> = []

    private static func key(_ fileURL: URL) -> String { fileURL.standardizedFileURL.path }

    /// Whether a store may write `fileURL`. False while an unreadable original could not be
    /// preserved: each call retries the quarantine, and a file that has since vanished or been
    /// moved aside unblocks the path. A refusal is logged through `report` and must be treated by
    /// the caller as a failed save (kept dirty, retried), never as success.
    public static func permitWrite(store: String, fileURL: URL) -> Bool {
        let path = key(fileURL)
        stateLock.lock()
        let blocked = writeBlocked.contains(path)
        stateLock.unlock()
        guard blocked else { return true }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            setBlocked(path, false)
            return true
        }
        // The bytes were undecodable when the path was blocked; moving them aside now keeps them
        // (never deleted) and is what lets the store write again. `quarantine` clears the block
        // only when the move lands.
        _ = quarantine(store: store, fileURL: fileURL, error: CocoaError(.fileReadCorruptFile)) as Outcome<Void>
        stateLock.lock()
        let stillBlocked = writeBlocked.contains(path)
        stateLock.unlock()
        if !stillBlocked { return true }
        report("[Store] \(store) save refused: the unreadable original could not be preserved \(DevTypeLog.publicPathMetadata(fileURL.path))")
        return false
    }

    private static func setBlocked(_ path: String, _ blocked: Bool) {
        stateLock.lock()
        if blocked { writeBlocked.insert(path) } else { writeBlocked.remove(path) }
        stateLock.unlock()
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            setBlocked(key(fileURL), false)
            return .absent
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return quarantine(store: store, fileURL: fileURL, error: error)
        }
        if data.isEmpty { setBlocked(key(fileURL), false); return .absent }
        do {
            let value = try decode(data)
            setBlocked(key(fileURL), false)
            return .loaded(value)
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
            try moveItem(fileURL, aside)
            setBlocked(key(fileURL), false)
            report(
                "[Store] \(store) unreadable (\(DevTypeLog.errorMetadata(error))); "
                    + "preserved original \(DevTypeLog.publicPathMetadata(aside.path)); starting empty"
            )
            return .unreadable(preservedAt: aside)
        } catch let moveError {
            report(
                "[Store] \(store) unreadable (\(DevTypeLog.errorMetadata(error))) and quarantine failed "
                    + "(\(DevTypeLog.errorMetadata(moveError))) \(DevTypeLog.publicPathMetadata(fileURL.path)); "
                    + "starting empty; saves are refused until it can be preserved"
            )
            setBlocked(key(fileURL), true)
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

    /// Result of reading a Codable value out of UserDefaults.
    public enum DefaultsRead<Value> {
        /// The key was never written (or holds an empty blob): the normal first-run state.
        case unset
        case value(Value)
        /// The key holds something that is not a `Value`. The raw value was copied aside
        /// (see `preserveUndecodableDefaultsValue`) and the key is left for the next save.
        case undecodable
    }

    /// Reads and decodes `key`, preserving the raw value when it cannot be decoded. This is the
    /// one defaults read for user data that must not silently decode to "empty" and then be
    /// overwritten by the next save.
    public static func readDefaultsValue<Value: Decodable>(
        _ type: Value.Type,
        store: String,
        key: String,
        defaults: UserDefaults = .standard
    ) -> DefaultsRead<Value> {
        guard let object = defaults.object(forKey: key) else { return .unset }
        if let data = object as? Data {
            if data.isEmpty { return .unset }
            if let value = try? JSONDecoder().decode(Value.self, from: data) { return .value(value) }
        }
        preserveUndecodableDefaultsValue(store: store, key: key, defaults: defaults) { data in
            _ = try JSONDecoder().decode(Value.self, from: data)
        }
        return .undecodable
    }

    /// Single sink for store-failure diagnostics: OSLog (public-safe text only) plus the test observer.
    public static func report(_ line: String) {
        DevTypeLog.store.error("\(line, privacy: .public)")
        observer?(line)
    }
}
