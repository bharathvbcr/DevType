/// Admits one holder at a time, refusing rather than queueing.
///
/// `PaletteToolRouter` and `SnippetTagSuggester` each declared a byte-identical private
/// `Latch` actor. They stay *separate instances* — palette routing and tag suggestion must
/// not contend with each other — but there is now one implementation of the rule.
///
/// Refusing is the point: a fast typist would otherwise stack model calls behind a latch
/// that queues, and every one of them would answer a query the user has already replaced.
///
/// Callers release explicitly on both paths rather than in a `defer`. A deferred release is
/// ordered *after* the caller resumes, so a second call made straight away found the latch
/// still held and was dropped as if the model were busy; `defer` cannot `await`, so the
/// release is spelled out instead.
public actor SingleFlightLatch {
    private var busy = false

    public init() {}

    /// `true` when the caller now holds the latch and must release it.
    public func acquire() -> Bool {
        if busy { return false }
        busy = true
        return true
    }

    public func release() { busy = false }

    /// Return by the caller's deadline, but retain admission until the actual work exits.
    /// Swift cancellation is cooperative: releasing admission at timeout would permit an
    /// unlimited backlog of engines that ignore cancellation. Invalid deadlines admit no work.
    func run<Output: Sendable>(
        timeout: Double,
        operation: @escaping @Sendable () async throws -> Output?
    ) async throws -> Output? {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, acquire() else { return nil }
        let race = DeadlineResult<Output>()
        let work = Task {
            let result: Result<Output?, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await operation())
            } catch { result = .failure(error) }
            self.release()
            await race.finish(result)
        }
        let timer = Task {
            do { try await Task.sleep(nanoseconds: UInt64(min(timeout, 60) * 1_000_000_000)) }
            catch { return }
            await race.finish(.success(nil), stopWork: true)
        }
        await race.register(work: work, timer: timer)
        let result = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            Task { await race.finish(.failure(CancellationError()), stopWork: true) }
        }
        try Task.checkCancellation()
        return try result.get()
    }
}

/// Owns exactly one response continuation and two task handles. No detached reader or queued
/// model call survives except the single admitted operation if it ignores cancellation.
private actor DeadlineResult<Output: Sendable> {
    private var result: Result<Output?, Error>?
    private var delivered = false
    private var waiter: CheckedContinuation<Result<Output?, Error>, Never>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func register(work: Task<Void, Never>, timer: Task<Void, Never>) {
        guard result == nil else {
            work.cancel()
            timer.cancel()
            return
        }
        self.work = work
        self.timer = timer
    }

    func wait() async -> Result<Output?, Error> {
        if delivered, let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }

    func finish(_ result: Result<Output?, Error>, stopWork: Bool = false) async {
        guard self.result == nil else { return }
        self.result = result
        if stopWork {
            work?.cancel()
            // Give cooperative engines a short cleanup grace before the caller resumes.
            // The grace is bounded even when the engine never checks cancellation.
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        timer?.cancel()
        timer = nil
        work = nil
        delivered = true
        waiter?.resume(returning: result)
        waiter = nil
    }
}
