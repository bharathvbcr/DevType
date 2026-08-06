import Foundation

/// §1.1: Dedicated `userInteractive` thread owning a `CFRunLoop` for the CGEvent tap source.
///
/// The tap source used to be attached to `CFRunLoopGetMain()`, which meant every
/// `Thread.sleep`, synchronous AX IPC, `NSWorkspace` call and JSON disk write reachable from the
/// callback was a **system-wide keyboard stall** — and the direct cause of `tapDisabledByTimeout`.
///
/// The thread parks in `CFRunLoopRun()` and stays alive across tap stop/start cycles (a run loop
/// with no live input sources returns immediately, so a mach port is kept installed to hold it
/// open). `shutdown()` is safe from any thread.
public final class TapRunLoopThread {
    private let stateLock = UnfairLock()
    private var _runLoop: CFRunLoop?
    private var _stopRequested = false
    private var _thread: Thread?
    private let ready = DispatchSemaphore(value: 0)

    /// Bounded wait for the worker's run loop to come up. Callers fall back to the main run loop.
    public static let defaultStartTimeout: TimeInterval = 2.0

    public init() {}

    /// The worker run loop, or `nil` when the thread is not up.
    public var runLoop: CFRunLoop? {
        stateLock.withLock { _runLoop }
    }

    public var isRunning: Bool {
        stateLock.withLock { _runLoop != nil }
    }

    /// Starts the thread (idempotent) and blocks the caller until its run loop exists.
    /// Returns `nil` if the run loop did not come up within `timeout`.
    @discardableResult
    public func startAndWait(timeout: TimeInterval = TapRunLoopThread.defaultStartTimeout) -> CFRunLoop? {
        stateLock.lock()
        if let existing = _runLoop {
            stateLock.unlock()
            return existing
        }
        if _thread != nil {
            // A previous start is still spinning up — just wait for it.
            stateLock.unlock()
            _ = ready.wait(timeout: .now() + timeout)
            return runLoop
        }
        _stopRequested = false
        let thread = Thread { [weak self] in
            self?.threadMain()
        }
        thread.name = "com.devtype.eventtap"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 512 * 1024
        _thread = thread
        stateLock.unlock()

        thread.start()
        _ = ready.wait(timeout: .now() + timeout)
        return runLoop
    }

    /// Stops the run loop and lets the thread exit. Safe to call from any thread, including
    /// from inside the tap callback itself.
    public func shutdown() {
        stateLock.lock()
        _stopRequested = true
        let loop = _runLoop
        stateLock.unlock()
        guard let loop else { return }
        CFRunLoopStop(loop)
        CFRunLoopWakeUp(loop)
    }

    private func threadMain() {
        let current = CFRunLoopGetCurrent()

        // `CFRunLoopRun()` returns immediately when the loop has no input sources, and the tap
        // source is only added *after* `startAndWait` returns. Park a mach port so the loop stays
        // open both before the source is installed and after `EventTapEngine.stop()` removes it.
        let keepAlive = NSMachPort()
        RunLoop.current.add(keepAlive, forMode: .common)

        stateLock.lock()
        _runLoop = current
        stateLock.unlock()
        ready.signal()

        var spinGuard = 0
        while true {
            stateLock.lock()
            let stop = _stopRequested
            stateLock.unlock()
            if stop { break }

            let startedAt = Date()
            autoreleasepool {
                // Returns when `CFRunLoopStop` is called. The outer loop re-checks the flag so a
                // spurious stop (or a transient sourceless state) cannot silently kill the tap.
                CFRunLoopRun()
            }

            // Defensive: `CFRunLoopRun()` returns *immediately* if the loop has no live input
            // sources. The keep-alive port should prevent that, but a userInteractive thread
            // spinning a whole core would be a far worse bug than a slightly slow tap.
            if Date().timeIntervalSince(startedAt) < 0.001 {
                spinGuard += 1
                if spinGuard == 10 {
                    DevTypeLog.eventTap.error(
                        "[EventTap] tap run loop returned immediately 10× — throttling to avoid a spin"
                    )
                }
                if spinGuard >= 10 {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            } else {
                spinGuard = 0
            }
        }

        RunLoop.current.remove(keepAlive, forMode: .common)
        stateLock.lock()
        _runLoop = nil
        _thread = nil
        stateLock.unlock()
    }
}
