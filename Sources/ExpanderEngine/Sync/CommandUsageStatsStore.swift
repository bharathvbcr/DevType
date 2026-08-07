import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// String-keyed usage sidecar for palette commands (`"ai.proofread"`, …).
///
/// Parallel to `UsageStatsStore` (UUID-keyed snippets). Same debounce / terminate
/// flush pattern; separate on-disk file so command IDs never collide with UUIDs.
public final class CommandUsageStatsStore {
    public static let shared = CommandUsageStatsStore()

    public struct Stat: Codable, Equatable {
        public var usageCount: Int
        public var lastUsedAt: Date?

        public init(usageCount: Int = 0, lastUsedAt: Date? = nil) {
            self.usageCount = usageCount
            self.lastUsedAt = lastUsedAt
        }
    }

    private struct Document: Codable {
        static let currentSchemaVersion = 1
        var schemaVersion: Int
        var stats: [String: Stat]

        init(schemaVersion: Int = Document.currentSchemaVersion, stats: [String: Stat]) {
            self.schemaVersion = schemaVersion
            self.stats = stats
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            stats = try c.decodeIfPresent([String: Stat].self, forKey: .stats) ?? [:]
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, stats
        }
    }

    public static let fileName = "command-usage-stats.json"
    public static let defaultFlushInterval: TimeInterval = 5.0

    private let fileURL: URL
    private let flushInterval: TimeInterval
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "devtype.commandusagestats", qos: .utility)

    private var stats: [String: Stat] = [:]
    private var dirty = false
    private var flushGeneration: UInt64 = 0
    private var terminateObserver: NSObjectProtocol?

    public init(fileURL: URL? = nil, flushInterval: TimeInterval = CommandUsageStatsStore.defaultFlushInterval) {
        if let fileURL {
            self.fileURL = fileURL
        } else if let env = ProcessInfo.processInfo.environment[SnippetStore.storeDirEnvKey], !env.isEmpty {
            self.fileURL = URL(fileURLWithPath: env, isDirectory: true)
                .appendingPathComponent(Self.fileName)
        } else {
            self.fileURL = SnippetStore.defaultLocalSupportDirectory
                .appendingPathComponent(Self.fileName)
        }
        self.flushInterval = max(0, flushInterval)
        stats = Self.loadFromDisk(fileURL: self.fileURL)
        installTerminateHook()
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    public var storeFileURL: URL { fileURL }

    public func recordUsage(for commandID: String, at date: Date = Date()) {
        let key = commandID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        lock.lock()
        var stat = stats[key] ?? Stat()
        stat.usageCount += 1
        stat.lastUsedAt = date
        stats[key] = stat
        dirty = true
        lock.unlock()
        scheduleFlush()
    }

    public func usageCount(for commandID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stats[commandID]?.usageCount ?? 0
    }

    public func lastUsedAt(for commandID: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return stats[commandID]?.lastUsedAt
    }

    public func rankBoost(for commandID: String) -> Int {
        lock.lock()
        let stat = stats[commandID]
        lock.unlock()
        guard let stat, stat.usageCount > 0 else { return 0 }
        var boost = 0
        var remaining = stat.usageCount
        while remaining > 0 && boost < 10 {
            boost += 1
            remaining /= 2
        }
        if let last = stat.lastUsedAt, Date().timeIntervalSince(last) < 60 * 60 * 24 * 7 {
            boost += 2
        }
        return min(boost, 12)
    }

    /// Most-recently-used command IDs, newest first.
    public func recentCommandIDs(limit: Int = 12) -> [String] {
        guard limit > 0 else { return [] }
        lock.lock()
        let snapshot = stats
        lock.unlock()
        let ordered = snapshot
            .filter { $0.value.lastUsedAt != nil }
            .sorted {
                ($0.value.lastUsedAt ?? .distantPast) > ($1.value.lastUsedAt ?? .distantPast)
            }
        return ordered.prefix(limit).map(\.key)
    }

    public func flush() {
        lock.lock()
        flushGeneration &+= 1
        lock.unlock()
        ioQueue.sync { self.writeIfDirty() }
    }

    private func scheduleFlush() {
        lock.lock()
        flushGeneration &+= 1
        let generation = flushGeneration
        lock.unlock()

        if flushInterval == 0 {
            ioQueue.async { [weak self] in self?.writeIfDirty() }
            return
        }

        ioQueue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isCurrent = generation == self.flushGeneration
            self.lock.unlock()
            guard isCurrent else { return }
            self.writeIfDirty()
        }
    }

    private func writeIfDirty() {
        lock.lock()
        guard dirty else {
            lock.unlock()
            return
        }
        let snapshot = stats
        dirty = false
        lock.unlock()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Document(stats: snapshot))
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            lock.lock()
            dirty = true
            lock.unlock()
            DevTypeLog.store.error(
                "[Store] Failed to write command usage stats: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func loadFromDisk(fileURL: URL) -> [String: Stat] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL), !data.isEmpty,
              let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return [:]
        }
        return document.stats
    }

    private func installTerminateHook() {
        #if canImport(AppKit)
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.flush()
        }
        #endif
    }
}
