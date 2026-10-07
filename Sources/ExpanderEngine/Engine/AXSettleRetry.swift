import Foundation

/// §8.3: the one settle-and-retry policy for AX reads that can fail transiently.
///
/// Two owners used to hand-write this — `EraseExecutor.evaluateErasePrecondition` and
/// `AXContextChecker.queryFocusedElement` — and they drifted into opposite shapes. The erase guard
/// was fixed to retry only off main; the focus query kept retrying *only on* main, by sleeping
/// there for the settle delay while the event tap could not run, and never retried off main.
/// Both now ask this type, so the rule cannot diverge again:
///
/// * one retry, after `delay`, only when the caller says the first answer is retryable;
/// * the **synchronous** form sleeps for the settle only off main. On main it returns the first
///   answer — blocking main is exactly what starves the tap;
/// * the **asynchronous** form gives main-thread callers the retry by scheduling it instead;
/// * the **bounded poll** (`poll`) is the multi-attempt wait for the Chromium rescue, under the
///   same rule: it sleeps only off main, and on main returns the first answer unpolled.
///
/// The attempt closure receives its 0-based index so a caller can escalate its own budget on the
/// retry (the focus query does), and decides for itself which thread it runs on.
public struct AXSettleRetry {
    /// Settle before the single retry. Focus and AX state lag AppKit after a panel closes or an
    /// app activates; 30 ms is long enough for that and short enough to be unnoticeable.
    public static let settleDelay: TimeInterval = 0.03

    public let delay: TimeInterval
    let isMainThread: () -> Bool
    let sleep: (TimeInterval) -> Void
    /// Runs `work` on main after the delay. Injected so tests can run the retry inline.
    let scheduleOnMain: (TimeInterval, @escaping () -> Void) -> Void

    public static let live = AXSettleRetry()

    public init(delay: TimeInterval = AXSettleRetry.settleDelay) {
        self.init(
            delay: delay,
            isMainThread: { Thread.isMainThread },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            scheduleOnMain: { delay, work in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        )
    }

    init(
        delay: TimeInterval = AXSettleRetry.settleDelay,
        isMainThread: @escaping () -> Bool,
        sleep: @escaping (TimeInterval) -> Void,
        scheduleOnMain: @escaping (TimeInterval, @escaping () -> Void) -> Void
    ) {
        self.delay = delay
        self.isMainThread = isMainThread
        self.sleep = sleep
        self.scheduleOnMain = scheduleOnMain
    }

    /// Synchronous form. Off main: attempt, settle, retry once. On main: the first answer only —
    /// a main-thread caller that needs the retry uses `run(_:retryIf:completion:)`.
    public func run<T>(_ attempt: (Int) -> T, retryIf shouldRetry: (T) -> Bool) -> T {
        let first = attempt(0)
        guard shouldRetry(first), !isMainThread() else { return first }
        sleep(delay)
        return attempt(1)
    }

    /// Asynchronous form, retry available from any thread and blocking none. `completion` runs
    /// synchronously on the calling thread when no retry is needed (the common case), and on main
    /// after the settle when one is.
    public func run<T>(
        _ attempt: @escaping (Int) -> T,
        retryIf shouldRetry: (T) -> Bool,
        completion: @escaping (T) -> Void
    ) {
        let first = attempt(0)
        guard shouldRetry(first) else {
            completion(first)
            return
        }
        scheduleOnMain(delay) { completion(attempt(1)) }
    }

    /// The settle alone, for a caller whose retry condition is only known after its own
    /// continuation ran (the erase guard's re-read after a possible write).
    public func afterSettle(_ work: @escaping () -> Void) {
        scheduleOnMain(delay, work)
    }

    /// What a `poll` did. `skippedOnMain` keeps "never polled because the caller was on main"
    /// distinguishable from "polled and the deadline had already passed" — both are zero polls.
    public struct PollOutcome<T> {
        public let last: T
        public let polls: Int
        public let skippedOnMain: Bool
    }

    /// Bounded poll for state that appears some time after a trigger — the Chromium tree after
    /// `AXManualAccessibility` is switched on. Same rule as the synchronous `run`: it settles
    /// only off main. On main it returns `first` untouched, because the poll *is* the main-thread
    /// stall this type exists to forbid; a caller that needs the poll runs off main.
    ///
    /// Bounded twice: by `maxPolls`, so a stalled or injected clock cannot spin it, and by
    /// `deadline`. Stops at the first answer `isDone` accepts.
    public func poll<T>(
        from first: T,
        every interval: TimeInterval,
        maxPolls: Int,
        until deadline: Date,
        now: () -> Date = Date.init,
        _ attempt: () -> T,
        stopWhen isDone: (T) -> Bool
    ) -> PollOutcome<T> {
        guard !isMainThread() else {
            return PollOutcome(last: first, polls: 0, skippedOnMain: true)
        }
        var last = first
        var polls = 0
        while polls < maxPolls, !isDone(last), now() < deadline {
            sleep(interval)
            polls += 1
            last = attempt()
        }
        return PollOutcome(last: last, polls: polls, skippedOnMain: false)
    }
}
