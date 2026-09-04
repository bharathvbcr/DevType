import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// The owner of a sidecar's in-memory state, as the writer needs to see it.
///
/// Kept deliberately narrow: the writer never learns the shape of the document, only
/// how to take the bytes that are due and how to put the debt back when a write fails.
protocol SidecarPayloadSource: AnyObject {
    /// Snapshots and clears the pending flag under the owner's own lock, then encodes.
    ///
    /// Returns `nil` when nothing is pending. Throwing means the bytes were owed but
    /// could not be produced; the writer treats that exactly like a failed write, so the
    /// retry ladder covers an encode failure as well as an I/O one.
    func takePendingSidecarPayload() throws -> Data?

    /// Re-arms the pending flag after a failed write, so the retry has something to write.
    func reArmPendingSidecarPayload()
}

/// The write side of a device-local JSON sidecar: a debounce window, exactly one bounded
/// retry per failure, a terminate flush, and a generation token so overlapping writes
/// collapse into the newest one.
///
/// Both usage sidecars carried their own copy of all of this — `scheduleFlush` (200 parse
/// nodes), `writeIfDirty`, `persist` (104), `installTerminateHook` (88) and `flush` were
/// among the largest exact-clone groups in the engine. The retry ladder is the reason it
/// matters that there is now one of them: it was originally missing, and
/// `UsageStatsFlushRetryTests` had to describe the bug as "*both* stores re-armed `dirty`
/// but scheduled nothing".
final class DebouncedSidecarWriter {
    /// Weak so a store that goes out of scope in a test is not pinned by its own writer;
    /// the queued blocks then find no source and do nothing, exactly as the `[weak self]`
    /// captures in the two copies did.
    weak var source: (any SidecarPayloadSource)?

    let fileURL: URL

    /// Test seam: when set, replaces the atomic disk write so failure paths are reachable
    /// without a full disk. `nil` (the default) means production I/O.
    var writeInterceptor: ((Data) throws -> Void)?

    private let flushInterval: TimeInterval
    private let flushRetryDelay: TimeInterval
    private let ioQueue: DispatchQueue
    private let failureMessage: String

    private let lock = NSLock()
    /// Monotonic token: only the newest scheduled write is allowed to run.
    private var flushGeneration: UInt64 = 0
    private var terminateObserver: NSObjectProtocol?

    init(
        fileURL: URL,
        flushInterval: TimeInterval,
        flushRetryDelay: TimeInterval,
        queueLabel: String,
        failureMessage: String
    ) {
        self.fileURL = fileURL
        self.flushInterval = max(0, flushInterval)
        self.flushRetryDelay = max(0, flushRetryDelay)
        self.ioQueue = DispatchQueue(label: queueLabel, qos: .utility)
        self.failureMessage = failureMessage
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    /// Where a sidecar lives: the caller's override, else the store-directory environment
    /// override tests use, else the device-local support directory. Never the synced
    /// library directory — two Macs incrementing the same counter would otherwise produce
    /// a permanent iCloud conflict on the hot path.
    static func resolveFileURL(override: URL?, fileName: String) -> URL {
        if let override { return override }
        if let env = ProcessInfo.processInfo.environment[SnippetStore.storeDirEnvKey], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true).appendingPathComponent(fileName)
        }
        return SnippetStore.defaultLocalSupportDirectory.appendingPathComponent(fileName)
    }

    /// Flushes on app terminate. Call once the owner is fully initialised.
    func installTerminateHook() {
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

    /// Arms the debounce window. Newer calls supersede older ones.
    func schedule() {
        lock.lock()
        flushGeneration &+= 1
        let generation = flushGeneration
        lock.unlock()

        if flushInterval == 0 {
            ioQueue.async { [weak self] in self?.writeIfDirty() }
            return
        }

        ioQueue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            self?.writeIfCurrent(generation)
        }
    }

    /// Writes any pending changes synchronously. Call from `applicationWillTerminate`.
    func flush() {
        lock.lock()
        // Invalidate any in-flight debounced write so it cannot re-run after us.
        flushGeneration &+= 1
        lock.unlock()
        ioQueue.sync { self.writeIfDirty() }
    }

    private func writeIfCurrent(_ generation: UInt64) {
        lock.lock()
        let isCurrent = generation == flushGeneration
        lock.unlock()
        guard isCurrent else { return }
        writeIfDirty()
    }

    private func writeIfDirty() {
        guard let source else { return }
        do {
            guard let data = try source.takePendingSidecarPayload() else { return }
            try persist(data)
        } catch {
            // Re-arm and schedule exactly one bounded retry. Re-arming alone used to be
            // the whole story: with no flush pending, the counters sat unwritten until
            // some *later* mutation happened to schedule a tick — an indefinite data-loss
            // window after a transient failure. The generation guard collapses overlapping
            // retries the same way it dedupes debounced flushes: any newer mutation or
            // explicit `flush()` supersedes this retry, because that newer work owns the
            // write.
            source.reArmPendingSidecarPayload()
            lock.lock()
            let generation = flushGeneration
            lock.unlock()
            DevTypeLog.store.error(
                "\(self.failureMessage, privacy: .public) \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            ioQueue.asyncAfter(deadline: .now() + flushRetryDelay) { [weak self] in
                self?.writeIfCurrent(generation)
            }
        }
    }

    /// The atomic disk write, split out so tests can inject failures. Production path
    /// (`writeInterceptor == nil`) is unchanged.
    private func persist(_ data: Data) throws {
        if let writeInterceptor {
            try writeInterceptor(data)
            return
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
