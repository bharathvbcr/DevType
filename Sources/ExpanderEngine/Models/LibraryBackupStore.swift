import CryptoKit
import Foundation

/// The one owner of snippet-library backups.
///
/// Two private helpers on `SnippetStore` used to write backups in two shapes and two places:
/// `makeTimestampedBackup` dropped `snippets.json.bak.<epoch>` beside the library (inside an
/// iCloud folder, when the library lived there), and `writeBackup` dropped
/// `devtype-backup-<tag>-<stamp>.json` in Application Support and returned `nil` on failure
/// without logging anything. Nothing else ever made a copy, so a bad bulk edit or a sync client
/// rewriting the file left nothing to go back to.
///
/// Every backup now lands in one device-local directory (`<support>/Backups`, never synced) under
/// one name scheme, `library-<kind>-<UTC yyyyMMdd'T'HHmmss.SSS'Z'>[-n].bak.json`. The timestamp
/// in the name — not the file's modification date, which a copy or move carries over from the
/// original — is the backup's age. Files that do not match the scheme are never read or removed.
///
/// Backups are raw library bytes, so they hold exactly what the library file held: secret
/// metadata, never secret values (those live only in `SecretStore`).
public final class LibraryBackupStore {
    public enum Kind: String, CaseIterable, Equatable {
        /// The bytes a save replaced. Rolling: subject to `retainedRollingBackups`.
        case save
        /// The file a user-confirmed "Replace with Defaults" replaced.
        case preOverwrite = "pre-overwrite"
        /// The library a "Restore from Backup…" replaced.
        case preRestore = "pre-restore"
        /// A library already at a Save As destination.
        case preSaveAs = "pre-save-as"
        /// The local library Stop Syncing replaced.
        case preStopSync = "pre-stop-sync"
        /// The library shown before Link to Existing switched away from it.
        case localBeforeLink = "local-before-link"
        /// A library file that could not be decoded at load.
        case corrupted

        /// Per-save copies roll under `retainedRollingBackups`.
        public var isRolling: Bool { self == .save }

        /// Safety copies are taken once, right before a destructive step. Each kind is capped by
        /// `retainedSafetyBackups` so repeated restores or Save As cannot grow the directory
        /// without bound. `corrupted` quarantines are the one kind never pruned: they hold the
        /// only copy of a file this build could not read.
        public var isCappedSafety: Bool { !isRolling && self != .corrupted }
    }

    public struct Entry: Equatable {
        public let url: URL
        public let createdAt: Date
        public let kind: Kind
        /// The `-n` collision suffix: orders backups taken within the same millisecond.
        let sequence: Int

        init(url: URL, createdAt: Date, kind: Kind, sequence: Int = 0) {
            self.url = url
            self.createdAt = createdAt
            self.kind = kind
            self.sequence = sequence
        }
    }

    /// What `preserve(fileAt:bytes:kind:)` did with a file that is about to be replaced.
    struct Preserved: Equatable {
        let url: URL
        /// The original was renamed into the backup directory rather than copied, because its
        /// bytes could not be read. The caller must put it back if the replacement fails.
        let moved: Bool
        /// This call wrote the backup. `false` when an identical backup already existed and was
        /// reused, which a caller undoing its own backup must never remove.
        var created = false
    }

    /// A rolling copy that `maximumBackupBytes` would make unlistable and unrestorable is not
    /// written; the save it belongs to still lands.
    struct OversizedBackup: LocalizedError {
        let byteCount: Int
        var errorDescription: String? {
            "The previous library is \(byteCount) bytes, over the \(LibraryBackupStore.maximumBackupBytes)-byte backup limit, so no rolling backup was kept."
        }
    }

    struct PruneReport: Equatable {
        var removed = 0
        var retained = 0
        var failed = 0
    }

    /// Retention promise for rolling (`.save`) backups: the newest `rollingCount`, plus the newest
    /// of each calendar day for the last `dailyWindowDays` days.
    static let rollingCount = 20
    static let dailyWindowDays = 30
    /// Retention promise for each capped safety kind: its newest `safetyCountPerKind` copies, plus
    /// every copy younger than `safetyWindowDays`. The newest of a kind is always kept.
    static let safetyCountPerKind = 10
    static let safetyWindowDays = 30
    /// Bounds a restore or listing read, matching the conflict resolver's candidate ceiling.
    static let maximumBackupBytes = LibraryConflictRecovery.maximumCandidateBytes

    let directory: URL
    private let now: () -> Date
    private let calendar: Calendar
    private let fileManager = FileManager.default

    private let lock = NSLock()
    /// Newest backup this process knows of, any kind. `nil` until seeded from disk once.
    private var newest: (entry: Entry, digest: String)?
    private var newestSeeded = false

    private let pruneQueue = DispatchQueue(label: "devtype.store.backup-prune", qos: .utility)
    private let pruneStateLock = NSLock()
    private var pruneQueued = false
    private var pruneCompletions: [(PruneReport) -> Void] = []

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter
    }()
    private static let stampLength = 20
    private static let prefix = "library-"
    private static let suffix = ".bak.json"

    init(directory: URL, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.directory = directory
        self.now = now
        self.calendar = calendar
    }

    // MARK: Writing

    /// Records `data` as a `kind` backup and returns its URL.
    ///
    /// When the newest backup already holds these exact bytes no second copy is written: a
    /// rolling save request is satisfied by any identical backup, and a safety request by an
    /// identical safety backup of the same kind. A rolling copy is never reused as a safety copy,
    /// because rolling copies age out and safety copies must not.
    ///
    /// - Returns: the backup holding `data`, and whether this call created it.
    @discardableResult
    func backUp(_ data: Data, kind: Kind) throws -> (url: URL, created: Bool) {
        // Listing and restore read at most `maximumBackupBytes`, so a larger rolling copy would be
        // written but never offered. Safety copies are exempt: keeping the bytes outranks listing.
        if kind.isRolling, data.count > Self.maximumBackupBytes {
            throw OversizedBackup(byteCount: data.count)
        }
        let digest = Self.sha256(of: data)
        lock.lock()
        defer { lock.unlock() }
        seedNewestLocked()
        if let newest, newest.digest == digest, kind.isRolling || newest.entry.kind == kind,
           fileManager.fileExists(atPath: newest.entry.url.path) {
            return (newest.entry.url, false)
        }
        let url = try writeLocked(data, kind: kind, digest: digest)
        return (url, true)
    }

    /// Takes a safety copy of the file at `url`, which the caller is about to replace and holds
    /// under file coordination.
    ///
    /// `bytes` are the file's contents when the caller could read them. When it could not, the
    /// file itself is renamed into the backup directory: a rename needs permission on the
    /// directories only, so an unreadable library is preserved byte for byte instead of being
    /// overwritten. A rename that crosses volumes degrades to a copy and fails the same way the
    /// read did — that failure is thrown, and the caller must not replace the file.
    ///
    /// - Returns: `nil` when there is nothing to preserve (no file, or a zero-byte one).
    func preserve(fileAt url: URL, bytes: Data?, kind: Kind) throws -> Preserved? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if let bytes {
            guard !bytes.isEmpty else { return nil }
            let copy = try backUp(bytes, kind: kind)
            return Preserved(url: copy.url, moved: false, created: copy.created)
        }
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
           size.intValue == 0 {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }
        do {
            try createDirectoryLocked()
            let destination = try uniqueURLLocked(kind: kind, at: now())
            try fileManager.moveItem(at: url, to: destination)
            do {
                // A directory sitting at the library path is preserved whole; 0o600 would strip its
                // search bit and leave the contents it was kept for unreachable.
                var isDirectory: ObjCBool = false
                _ = fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory)
                try FilePermissions.setPOSIX(destination, isDirectory.boolValue ? 0o700 : 0o600)
            } catch {
                // The bytes are preserved either way; an owner-unreadable backup is still a backup.
                DevTypeLog.store.error(
                    "[Backup] Moved an unreadable library aside but could not make it readable \(DevTypeLog.errorMetadata(error), privacy: .public)"
                )
            }
            DevTypeLog.store.notice(
                "[Backup] Moved unreadable library aside as \(destination.lastPathComponent, privacy: .public)"
            )
            // Its digest is unknown, so it can never satisfy a later dedupe; forget the cache
            // entry rather than let an older one claim to be newest.
            newest = nil
            return Preserved(url: destination, moved: true, created: true)
        } catch {
            DevTypeLog.store.error(
                "[Backup] Could not preserve the library before replacing it kind=\(kind.rawValue, privacy: .public) \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            throw error
        }
    }

    /// Removes a backup this process just wrote because the replacement it guarded never landed.
    func discard(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            DevTypeLog.store.error(
                "[Backup] Could not remove an orphaned backup \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            return
        }
        if newest?.entry.url == url { newest = nil; newestSeeded = false }
    }

    private func writeLocked(_ data: Data, kind: Kind, digest: String) throws -> URL {
        let stamp = now()
        do {
            try createDirectoryLocked()
            let url = try uniqueURLLocked(kind: kind, at: stamp)
            try FilePermissions.atomicWrite(data, to: url)
            let parsed = Self.parse(url.lastPathComponent)
            let entry = Entry(url: url, createdAt: parsed?.date ?? stamp, kind: kind, sequence: parsed?.sequence ?? 0)
            newest = (entry, digest)
            DevTypeLog.store.notice(
                "[Backup] Wrote library backup \(url.lastPathComponent, privacy: .public)"
            )
            return url
        } catch {
            DevTypeLog.store.error(
                "[Backup] Could not write library backup kind=\(kind.rawValue, privacy: .public) \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            throw error
        }
    }

    private func createDirectoryLocked() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func uniqueURLLocked(kind: Kind, at date: Date) throws -> URL {
        let base = Self.prefix + kind.rawValue + "-" + Self.stampFormatter.string(from: date)
        var candidate = directory.appendingPathComponent(base + Self.suffix)
        var counter = 1
        while fileManager.fileExists(atPath: candidate.path) {
            guard counter <= 1_000 else { throw CocoaError(.fileWriteFileExists) }
            candidate = directory.appendingPathComponent("\(base)-\(counter)\(Self.suffix)")
            counter += 1
        }
        return candidate
    }

    /// The newest backup's digest is read once per process, so the first save after launch does
    /// not copy bytes that an earlier run already backed up.
    private func seedNewestLocked() {
        guard !newestSeeded else { return }
        newestSeeded = true
        guard let entry = entries().first,
              let data = try? LibraryConflictRecovery.boundedRead(entry.url) else { return }
        newest = (entry, Self.sha256(of: data))
    }

    // MARK: Reading

    /// Every backup that matches the name scheme, newest first. Unreadable directories yield `[]`.
    public func entries() -> [Entry] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .compactMap { name -> Entry? in
                guard let parsed = Self.parse(name) else { return nil }
                return Entry(
                    url: directory.appendingPathComponent(name),
                    createdAt: parsed.date,
                    kind: parsed.kind,
                    sequence: parsed.sequence
                )
            }
            .sorted(by: Self.newerFirst)
    }

    /// The entry for `url` when it names a backup in this store's directory, else `nil`. A file
    /// chosen from anywhere else is not a DevType backup, whatever its name.
    func entry(for url: URL) -> Entry? {
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard parent == directory.standardizedFileURL.resolvingSymlinksInPath(),
              let parsed = Self.parse(url.lastPathComponent) else { return nil }
        return Entry(url: url, createdAt: parsed.date, kind: parsed.kind, sequence: parsed.sequence)
    }

    static func parse(_ name: String) -> (kind: Kind, date: Date, sequence: Int)? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let body = name.dropFirst(prefix.count).dropLast(suffix.count)
        // Longest raw value first, so `pre-save-as` is never read as a `save` prefix.
        for kind in Kind.allCases.sorted(by: { $0.rawValue.count > $1.rawValue.count }) {
            let lead = kind.rawValue + "-"
            guard body.hasPrefix(lead) else { continue }
            let rest = body.dropFirst(lead.count)
            guard rest.count >= stampLength,
                  let date = stampFormatter.date(from: String(rest.prefix(stampLength))) else { return nil }
            let tail = rest.dropFirst(stampLength)
            if tail.isEmpty { return (kind, date, 0) }
            guard tail.first == "-", let sequence = Int(tail.dropFirst()), sequence > 0,
                  tail.dropFirst().allSatisfy(\.isASCII) else { return nil }
            return (kind, date, sequence)
        }
        return nil
    }

    private static func newerFirst(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        if lhs.sequence != rhs.sequence { return lhs.sequence > rhs.sequence }
        return lhs.url.lastPathComponent > rhs.url.lastPathComponent
    }

    // MARK: Retention

    /// Exactly the rolling backups the retention promise keeps: the `rollingCount` newest, plus
    /// the newest of every calendar day (in `calendar`) within `dailyWindowDays` of `now`.
    /// Safety copies are outside this rule; see `retainedSafetyBackups`.
    static func retainedRollingBackups(
        _ entries: [Entry],
        now: Date,
        calendar: Calendar,
        rollingCount: Int = rollingCount,
        dailyWindowDays: Int = dailyWindowDays
    ) -> Set<URL> {
        let rolling = entries.filter(\.kind.isRolling).sorted(by: newerFirst)
        var kept = Set(rolling.prefix(max(0, rollingCount)).map(\.url))
        let windowStart = calendar.date(
            byAdding: .day,
            value: -max(0, dailyWindowDays),
            to: now
        ) ?? now
        var daysSeen = Set<Date>()
        for entry in rolling where entry.createdAt > windowStart {
            // `rolling` is newest first, so the first entry seen for a day is that day's newest.
            if daysSeen.insert(calendar.startOfDay(for: entry.createdAt)).inserted {
                kept.insert(entry.url)
            }
        }
        return kept
    }

    /// The safety copies the retention promise keeps: per capped kind, the `countPerKind` newest
    /// plus anything younger than `windowDays`. Other kinds are not this rule's concern.
    static func retainedSafetyBackups(
        _ entries: [Entry],
        now: Date,
        calendar: Calendar,
        countPerKind: Int = safetyCountPerKind,
        windowDays: Int = safetyWindowDays
    ) -> Set<URL> {
        let windowStart = calendar.date(byAdding: .day, value: -max(0, windowDays), to: now) ?? now
        var kept = Set<URL>()
        for kind in Kind.allCases where kind.isCappedSafety {
            let ofKind = entries.filter { $0.kind == kind }.sorted(by: newerFirst)
            // At least one, so a zero count can never delete the newest copy of a kind.
            kept.formUnion(ofKind.prefix(max(1, countPerKind)).map(\.url))
            kept.formUnion(ofKind.filter { $0.createdAt > windowStart }.map(\.url))
        }
        return kept
    }

    /// Removes the rolling and capped-safety backups outside the retention promise. A removal failure is logged
    /// and counted; the next pass retries it.
    @discardableResult
    func prune() -> PruneReport {
        lock.lock()
        let all = entries()
        let keep = Self.retainedRollingBackups(all, now: now(), calendar: calendar)
            .union(Self.retainedSafetyBackups(all, now: now(), calendar: calendar))
        var report = PruneReport()
        for entry in all {
            guard entry.kind.isRolling || entry.kind.isCappedSafety, !keep.contains(entry.url) else {
                report.retained += 1
                continue
            }
            do {
                try fileManager.removeItem(at: entry.url)
                report.removed += 1
                if newest?.entry.url == entry.url { newest = nil; newestSeeded = false }
            } catch {
                report.failed += 1
                report.retained += 1
                DevTypeLog.store.error(
                    "[Backup] Could not prune \(entry.url.lastPathComponent, privacy: .public) \(DevTypeLog.errorMetadata(error), privacy: .public)"
                )
            }
        }
        lock.unlock()
        if report.removed > 0 || report.failed > 0 {
            DevTypeLog.store.info(
                "[Backup] prune removed=\(report.removed, privacy: .public) retained=\(report.retained, privacy: .public) failed=\(report.failed, privacy: .public)"
            )
        }
        return report
    }

    /// Runs `prune()` on a utility queue. Requests that arrive before a queued pass starts join
    /// it, so a burst of saves costs one directory scan; a request that arrives once a pass has
    /// started queues one more, which sees the newer files.
    func schedulePrune(completion: ((PruneReport) -> Void)? = nil) {
        pruneStateLock.lock()
        let alreadyQueued = pruneQueued
        pruneQueued = true
        if let completion { pruneCompletions.append(completion) }
        pruneStateLock.unlock()
        guard !alreadyQueued else { return }

        pruneQueue.async { [weak self] in
            guard let self else { return }
            self.pruneStateLock.lock()
            self.pruneQueued = false
            let completions = self.pruneCompletions
            self.pruneCompletions.removeAll()
            self.pruneStateLock.unlock()
            let report = self.prune()
            for completion in completions { completion(report) }
        }
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
