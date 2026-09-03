import Foundation

/// Per-app mute denylist persisted under Application Support.
public final class AppMuteStore {
    public static let shared = AppMuteStore()

    private let fileURL: URL
    private let lock = NSLock()
    /// Serializes disk persistence so the write order equals the mutation order.
    /// The mutation happens under `lock` and its write is *enqueued* under the
    /// same lock (the FIFO queue then makes disk order equal enqueue order), while
    /// the I/O itself runs off-lock and callers wait only until their own write
    /// has landed. See `persistSynchronized`.
    private let persistenceQueue = DispatchQueue(label: "devtype.mutestore.persist", qos: .utility)
    private var mutedBundleIDs: Set<String> = []
    private var listeners: [() -> Void] = []

    /// Test seam: replaces the disk persistence step so ordering properties can be
    /// observed without depending on real I/O timing. `nil` (the default) means
    /// production saves.
    var persistOverride: ((_ ids: Set<String>, _ fileURL: URL) -> Void)?

    public init(fileURL: URL? = nil) {
        if let fileURL {
            let parent = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
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

    public func allMuted() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return mutedBundleIDs.sorted()
    }

    public func mute(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        persistSynchronized { locked in
            locked.insert(bundleID)
        }
        // Listeners fire after the write lands, as they always have.
    }

    public func unmute(_ bundleID: String) {
        persistSynchronized { locked in
            locked.remove(bundleID)
        }
    }

    /// Applies one mutation under `lock`, persists the resulting set on
    /// `persistenceQueue`, and returns only once that write has landed.
    ///
    /// The enqueue happens while `lock` is held, so queue order equals mutation
    /// order and the FIFO queue makes disk order equal queue order — last write
    /// wins. Before this, the write ran unlocked on whatever thread called in,
    /// so two writers could persist out of order and an older snapshot could win
    /// the file. The caller waits outside the lock for the queued write: the
    /// historical contract is that `mute`/`unmute` return with the file already
    /// updated (a fresh instance reads back what was just written), and the
    /// payloads are tiny, so the wait is the cost the old synchronous write paid
    /// anyway — just off the lock and correctly ordered.
    /// Ceiling on the synchronous wait for a mute write. Generous for a payload measured in
    /// bytes: this exists to convert a hang into a logged degradation, not to police latency.
    static let persistTimeout: TimeInterval = 2.0

    private func persistSynchronized(_ mutate: (inout Set<String>) -> Void) {
        let written = DispatchSemaphore(value: 0)
        lock.lock()
        mutate(&mutedBundleIDs)
        let snapshot = mutedBundleIDs
        let currentListeners = listeners
        // Snapshot both by value: an override swapped in later applies to later
        // writes only, and `fileURL` never changes after init.
        let override = persistOverride
        let url = fileURL
        persistenceQueue.async {
            if let override {
                override(snapshot, url)
            } else {
                Self.saveToDisk(snapshot, fileURL: url)
            }
            written.signal()
        }
        lock.unlock()
        // Bounded, for the same reason §1.3 bounded the inject queue's `group.wait()`: this is
        // reached from menu actions on the main thread, and an untimed wait turns one stalled
        // write — a full disk, a network-mounted home directory, a wedged persist override —
        // into a permanently beachballed app with nothing in the log. The mutation is already
        // live in memory, so on timeout the mute still takes effect and the listeners still
        // fire; only the on-disk copy is late, and the next write supersedes it.
        if written.wait(timeout: .now() + Self.persistTimeout) == .timedOut {
            DevTypeLog.app.error(
                "[Mute] persist did not land within \(Self.persistTimeout, privacy: .public)s — the in-memory change stands, the file is behind"
            )
        }
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
