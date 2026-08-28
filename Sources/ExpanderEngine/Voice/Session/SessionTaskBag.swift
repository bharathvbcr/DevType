import Foundation

public final class SessionTaskBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    public let sessionID: VoiceSessionID
    private(set) public var generation: SessionGeneration

    public init(sessionID: VoiceSessionID, generation: SessionGeneration = SessionGeneration(rawValue: 1)) {
        self.sessionID = sessionID
        self.generation = generation
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
        defer { lock.unlock() }
        generation = generation.next()
        for (_, task) in tasks {
            task.cancel()
        }
        tasks.removeAll()
        return generation
    }

    public func isCurrentGeneration(_ testGeneration: SessionGeneration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == testGeneration
    }
}
