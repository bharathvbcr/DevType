// Adapted from SnipKey Kit (MIT) — Copyright 2026 SnipKey contributors

import Foundation

public protocol StoreWatching: AnyObject {
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}

public final class DirectoryWatcher: StoreWatching {

    public var onChange: (() -> Void)?

    /// §2.5: one atomic save produces several `.write`/`.rename` events, and every
    /// one of the app's own writes trips this watcher. Events are coalesced over
    /// this window so the store does a single digest check per burst instead of
    /// one per event. Set to `0` for immediate delivery.
    ///
    /// Assign before `start()`; it is read on the watcher queue afterwards.
    public var debounceInterval: TimeInterval = 0.15

    private let directoryURL: URL
    private let queue = DispatchQueue(label: "devtype.store.watcher")
    private var source: DispatchSourceFileSystemObject?
    /// Only the newest scheduled delivery is allowed to run. Mutated exclusively
    /// on `queue`, which is serial.
    private var pendingGeneration: UInt64 = 0

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func start() {
        stop()
        try? FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true
        )
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        // The cancel handler closes exactly the descriptor *this* source was created with.
        // The old shape closed a shared `descriptor` field, so a queued cancel from a rapid
        // stop→start could close the replacement's fresh fd — leaking one and killing the
        // other. Per-source capture makes that impossible by construction.
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.scheduleChange() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    /// Runs on `queue` (serial), so the generation counter needs no lock.
    private func scheduleChange() {
        pendingGeneration &+= 1
        let generation = pendingGeneration
        let interval = debounceInterval
        guard interval > 0 else {
            onChange?()
            return
        }
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, generation == self.pendingGeneration else { return }
            self.onChange?()
        }
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
