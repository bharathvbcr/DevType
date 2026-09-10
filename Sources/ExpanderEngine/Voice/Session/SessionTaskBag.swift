import Foundation

public final class SessionTaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var pendingDeliveryCount = 0
    private var pendingDeliveryBytes = 0
    public let sessionID: VoiceSessionID
    private var storedGeneration: SessionGeneration
    public var generation: SessionGeneration {
        lock.lock()
        defer { lock.unlock() }
        return storedGeneration
    }

    public init(sessionID: VoiceSessionID, generation: SessionGeneration = SessionGeneration(rawValue: 1)) {
        self.sessionID = sessionID
        self.storedGeneration = generation
    }

    public func add(_ task: Task<Void, Never>) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        tasks[id] = task
        return id
    }

    public func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        tasks.removeValue(forKey: id)
    }

    @discardableResult
    public func advanceGenerationAndCancelAll() -> SessionGeneration {
        lock.lock()
        storedGeneration = storedGeneration.next()
        let nextGeneration = storedGeneration
        let retiringTasks = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        // Task.cancel() invokes cancellation handlers synchronously. Those handlers can
        // inspect this bag, so invoke them only after publishing retirement and unlocking.
        for task in retiringTasks { task.cancel() }
        return nextGeneration
    }

    public func isCurrentGeneration(_ testGeneration: SessionGeneration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedGeneration == testGeneration
    }

    /// Main-thread congestion must not turn bounded provider state into an unbounded
    /// backlog of captured revisions. Reservations survive retirement until callbacks drain.
    func reserveLiveDelivery(bytes: Int, generation: SessionGeneration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedGeneration == generation, bytes >= 0,
              pendingDeliveryCount < SpeechSegment.maximumSegments,
              bytes <= SpeechSegment.maximumTranscriptBytes - pendingDeliveryBytes else { return false }
        pendingDeliveryCount += 1
        pendingDeliveryBytes += bytes
        return true
    }

    func releaseLiveDelivery(bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        pendingDeliveryCount -= 1
        pendingDeliveryBytes -= bytes
    }
}
