import Foundation

/// Per-app mute denylist persisted under Application Support.
public final class AppMuteStore {
    public static let shared = AppMuteStore()

    private let fileURL: URL
    private let lock = NSLock()
    private var mutedBundleIDs: Set<String> = []
    private var listeners: [() -> Void] = []

    public init(fileURL: URL? = nil) {
        if let fileURL {
            let parent = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("DevType", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("muted-apps.json")
        }
        mutedBundleIDs = Self.loadFromDisk(fileURL: self.fileURL)
    }

    public func addListener(_ listener: @escaping () -> Void) {
        lock.lock()
        listeners.append(listener)
        lock.unlock()
    }

    public func isMuted(_ bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return mutedBundleIDs.contains(bundleID)
    }

    public func isFrontmostMuted() -> Bool {
        guard let id = AXContextChecker.shared.frontmostApplicationBundleIdentifier() else { return false }
        return isMuted(id)
    }

    public func allMuted() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return mutedBundleIDs.sorted()
    }

    public func mute(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        lock.lock()
        mutedBundleIDs.insert(bundleID)
        let snapshot = mutedBundleIDs
        let currentListeners = listeners
        lock.unlock()
        Self.saveToDisk(snapshot, fileURL: fileURL)
        currentListeners.forEach { $0() }
    }

    public func unmute(_ bundleID: String) {
        lock.lock()
        mutedBundleIDs.remove(bundleID)
        let snapshot = mutedBundleIDs
        let currentListeners = listeners
        lock.unlock()
        Self.saveToDisk(snapshot, fileURL: fileURL)
        currentListeners.forEach { $0() }
    }

    public func muteFrontmost() -> String? {
        guard let id = AXContextChecker.shared.frontmostApplicationBundleIdentifier() else { return nil }
        mute(id)
        return id
    }

    private static func loadFromDisk(fileURL: URL) -> Set<String> {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list.filter { !$0.isEmpty })
    }

    private static func saveToDisk(_ ids: Set<String>, fileURL: URL) {
        do {
            let data = try JSONEncoder().encode(ids.sorted())
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DevTypeLog.store.error(
                "[Store] Failed to save muted apps: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
