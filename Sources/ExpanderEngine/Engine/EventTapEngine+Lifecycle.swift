import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Tap start/stop, disable recovery and health monitor.
extension EventTapEngine {
    public func start() -> Bool {
        lock.lock()
        _hasAttemptedTapStart = true
        lock.unlock()
        let listenGranted = CGPreflightListenEventAccess()
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let axGranted = AXIsProcessTrustedWithOptions(axOptions)
        DevTypeLog.eventTap.info(
            "[EventTap] start begin listenPreflight=\(DevTypeLog.grantLabel(listenGranted), privacy: .public) ax=\(DevTypeLog.grantLabel(axGranted), privacy: .public)"
        )
        // `.defaultTap` (swallowing) needs Listen + Accessibility. Attempting create without AX
        // returns nil and used to be misreported as Tap Failed / identity mismatch.
        if !listenGranted || !axGranted {
            lock.lock()
            _isTapRunning = false
            lock.unlock()
            DevTypeLog.eventTap.error(
                "[EventTap] start refused — defaultTap requires Listen+Accessibility (listen=\(DevTypeLog.grantLabel(listenGranted), privacy: .public) ax=\(DevTypeLog.grantLabel(axGranted), privacy: .public))"
            )
            return false
        }
        tapLock.lock()
        let hadPort = _eventTapPort != nil
        tapLock.unlock()
        if hadPort {
            stop()
        }

        var mask: CGEventMask = 0
        mask |= 1 << CGEventType.keyDown.rawValue
        mask |= 1 << CGEventType.flagsChanged.rawValue
        mask |= 1 << CGEventType.leftMouseDown.rawValue
        mask |= 1 << CGEventType.rightMouseDown.rawValue
        mask |= 1 << CGEventType.otherMouseDown.rawValue

        let createdPort = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let port = createdPort else {
            lock.lock()
            _isTapRunning = false
            lock.unlock()
            DevTypeLog.eventTap.error(
                "[EventTap] start failed — CGEvent.tapCreate returned nil despite Listen+AX granted (check duplicate DevType processes / TCC identity)"
            )
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)

        // §1.1: attach to the dedicated tap thread's run loop so the callback (and everything it
        // synchronously touches) no longer runs on main. Falls back to the historical main
        // run loop if the worker did not come up, or if the kill switch is off.
        var targetRunLoop: CFRunLoop? = CFRunLoopGetMain()
        var onDedicatedThread = false
        if EventTapEngine.useDedicatedTapThread {
            if let workerLoop = tapThread.startAndWait() {
                targetRunLoop = workerLoop
                onDedicatedThread = true
            } else {
                DevTypeLog.eventTap.error(
                    "[EventTap] dedicated tap thread did not start — falling back to the main run loop"
                )
            }
        }

        CFRunLoopAddSource(targetRunLoop, source, .commonModes)
        CFRunLoopWakeUp(targetRunLoop)
        CGEvent.tapEnable(tap: port, enable: true)

        tapLock.lock()
        _eventTapPort = port
        _runLoopSource = source
        _tapRunLoop = targetRunLoop
        tapLock.unlock()

        lock.lock()
        _isTapRunning = true
        lock.unlock()
        // Refresh the AppKit-derived caches the callback depends on before the first key arrives.
        primeFrontmostContext()
        refreshInputSourceCache()
        KeyboardLayoutState.shared.refreshOnMain()
        startHealthMonitor()
        DevTypeLog.eventTap.info(
            "[EventTap] start success — defaultTap installed + health monitor (dedicatedThread=\(onDedicatedThread, privacy: .public))"
        )
        return true
    }

    /// Removes the tap. Safe from any thread, including the tap thread itself — `CFRunLoop` is the
    /// one Core Foundation class documented as thread-safe. The worker thread is left parked (it
    /// holds a keep-alive port) so a later `start()` does not have to churn threads; use
    /// `shutdownTapThread()` for a full teardown.
    public func stop() {
        pipeline.cancelCurrentInjection()
        let wasRunning = isTapRunning
        stopHealthMonitor()

        tapLock.lock()
        let port = _eventTapPort
        let source = _runLoopSource
        let loop = _tapRunLoop
        _eventTapPort = nil
        _runLoopSource = nil
        _tapRunLoop = nil
        tapLock.unlock()

        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source {
            // Falls back to main only for the degenerate case where the tap was installed on the
            // main run loop (kill switch off / worker thread failed to start).
            let hostLoop: CFRunLoop? = loop ?? CFRunLoopGetMain()
            CFRunLoopRemoveSource(hostLoop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let port {
            CFMachPortInvalidate(port)
        }
        if let loop {
            CFRunLoopWakeUp(loop)
        }

        lock.lock()
        _isTapRunning = false
        lock.unlock()
        // With the tap gone, nothing can observe or cancel a live hold — its debounce timer
        // would fire into a field DevType is no longer watching.
        heldCoordinator.cancelAll(reason: .unobservedInput)
        if wasRunning {
            DevTypeLog.eventTap.info("[EventTap] stop — tap removed")
        }
    }

    /// §1.1: full teardown of the dedicated tap thread. `stop()` alone leaves it parked.
    public func shutdownTapThread() {
        stop()
        tapThread.shutdown()
    }

    /// True when the tap source is attached to the dedicated §1.1 thread rather than main.
    public var isTapOnDedicatedThread: Bool {
        tapLock.lock()
        let loop = _tapRunLoop
        tapLock.unlock()
        guard let loop, let worker = tapThread.runLoop else { return false }
        return loop === worker
    }

    public func reEnableTap() {
        tapLock.lock()
        let port = _eventTapPort
        tapLock.unlock()
        guard let port else { return }
        // §2.10: the loud, counted line lives in `handleTapDisabled`; this stays quiet so a
        // re-enable storm does not drown the log it is trying to explain.
        DevTypeLog.eventTap.debug("[EventTap] tapEnable(true)")
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// §2.10: counted, rate-limited handling for `tapDisabledByTimeout` / `ByUserInput`.
    ///
    /// The old code re-enabled and logged one indistinguishable `notice`, which hid the fact that
    /// `byTimeout` means *our callback was too slow* — the actionable failure mode, and the one
    /// §1.1 exists to fix. Repeated timeouts in a short window now escalate to a full tap
    /// reinstall, with exponential backoff so a persistent problem cannot become a reinstall loop.
    ///
    /// Runs on the tap thread; the reinstall itself is hopped to main because it creates a new
    /// mach port and run loop source.
    public func handleTapDisabled(reason: TapDisableReason) {
        // The system disabled the tap, so keystrokes have been flowing straight to the field
        // unseen. A live hold's erase count is now unverifiable-by-construction — and its
        // timeout quiescence check is blind for the same reason the hold is (no events, no
        // marks). Cancel before anything else; the trigger stays literal.
        heldCoordinator.cancelAll(reason: .unobservedInput)
        let now = Date()

        counterLock.lock()
        switch reason {
        case .timeout:
            _tapDisableCounters.byTimeout += 1
            _tapDisableCounters.lastTimeoutAt = now
            _recentTimeoutStamps.append(now)
            _recentTimeoutStamps.removeAll {
                now.timeIntervalSince($0) > EventTapEngine.tapDisableEscalationWindow
            }
        case .userInput:
            _tapDisableCounters.byUserInput += 1
            _tapDisableCounters.lastUserInputAt = now
        case .unspecified:
            break
        }
        _tapDisableCounters.reEnables += 1
        let burst = _recentTimeoutStamps.count
        var escalate = false
        if reason == .timeout, burst >= EventTapEngine.tapDisableEscalationThreshold {
            let allowedAt = _nextReinstallAllowedAt ?? Date.distantPast
            if now >= allowedAt {
                escalate = true
                _tapDisableCounters.escalatedReinstalls += 1
                _nextReinstallAllowedAt = now.addingTimeInterval(_reinstallBackoff)
                _reinstallBackoff = min(
                    _reinstallBackoff * 2,
                    EventTapEngine.tapReinstallMaxBackoff
                )
                _recentTimeoutStamps.removeAll()
            }
        }
        let counters = _tapDisableCounters
        counterLock.unlock()

        // Cheap and safe from the tap thread: flip the enable bit back on immediately.
        reEnableTap()

        let reasonLabel: String
        switch reason {
        case .timeout: reasonLabel = "tapDisabledByTimeout"
        case .userInput: reasonLabel = "tapDisabledByUserInput"
        case .unspecified: reasonLabel = "tapDisabled"
        }

        if reason == .timeout {
            DevTypeLog.eventTap.error(
                "[EventTap] \(reasonLabel, privacy: .public) — callback exceeded the system budget (burst=\(burst, privacy: .public) \(counters.summaryLine, privacy: .public))"
            )
        } else {
            DevTypeLog.eventTap.notice(
                "[EventTap] \(reasonLabel, privacy: .public) re-enabled (\(counters.summaryLine, privacy: .public))"
            )
        }

        guard escalate else { return }
        DevTypeLog.eventTap.error(
            "[EventTap] \(burst, privacy: .public) timeout disables within \(EventTapEngine.tapDisableEscalationWindow, privacy: .public)s — reinstalling the tap"
        )
        DispatchQueue.main.async { [weak self] in
            self?.reinstallFromHealthMonitor(reason: "tapDisabledByTimeout burst")
        }
    }

    /// Starts a main-queue timer that re-enables or reinstalls an inert CGEvent tap.
    /// Called automatically from `start()`; safe to call again (resets the timer).
    public func startHealthMonitor() {
        stopHealthMonitor()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + healthCheckInterval,
            repeating: healthCheckInterval,
            leeway: EventTapEngine.healthCheckLeeway
        )
        timer.setEventHandler { [weak self] in
            self?.checkTapHealth()
        }
        healthTimer = timer
        timer.resume()
    }

    private func stopHealthMonitor() {
        healthTimer?.cancel()
        healthTimer = nil
    }

    /// If the tap is expected to be live but `tapIsEnabled` is false (or the port is gone),
    /// try `tapEnable` then a full reinstall. Addresses silent disable after timeout/re-sign.
    private func checkTapHealth() {
        // A live tap with matching suspended is *also* a total expansion outage, and the tap
        // health check is the only thing already running on a timer that can notice. Checked
        // before the port checks below so an orphaned suspension is recovered even while the tap
        // itself is perfectly healthy — which is exactly how it presents.
        recoverOrphanedSuspensions(isDevTypeFrontmost: isDevTypeFrontmost())

        lock.lock()
        let expectRunning = _isTapRunning
        let userEnabled = _isEnabled
        lock.unlock()
        guard expectRunning, userEnabled else { return }

        // §1.11: never touch `_eventTapPort` unlocked — the tap thread reads it from `reEnableTap`.
        tapLock.lock()
        let currentPort = _eventTapPort
        tapLock.unlock()

        guard let port = currentPort else {
            DevTypeLog.eventTap.notice(
                "[EventTap] health: port missing while expected running — reinstalling"
            )
            // No tap, no observation — any hold armed before the port vanished is blind.
            heldCoordinator.cancelAll(reason: .unobservedInput)
            reinstallFromHealthMonitor(reason: "nil port")
            return
        }

        if CGEvent.tapIsEnabled(tap: port) {
            return
        }

        DevTypeLog.eventTap.notice(
            "[EventTap] health: tapIsEnabled=false — attempting tapEnable then reinstall"
        )
        // The tap was silently inert for up to one health interval — keystrokes reached the
        // field unseen, so any live hold is miscounted by construction.
        heldCoordinator.cancelAll(reason: .unobservedInput)
        CGEvent.tapEnable(tap: port, enable: true)
        if !CGEvent.tapIsEnabled(tap: port) {
            reinstallFromHealthMonitor(reason: "inert tap")
        } else {
            DevTypeLog.eventTap.info("[EventTap] health: tap re-enabled without reinstall")
        }
    }

    private func reinstallFromHealthMonitor(reason: String) {
        let snapshot = PermissionCoordinator.shared.cachedSnapshot
        if snapshot.blocksDefaultEventTap {
            DevTypeLog.eventTap.error(
                "[EventTap] health: reinstall skipped — Listen/AX missing (\(reason)); clearing running flag"
            )
            lock.lock()
            _isTapRunning = false
            lock.unlock()
            notifyTapHealthChanged()
            return
        }

        let ok = start()
        if !ok {
            DevTypeLog.eventTap.error(
                "[EventTap] health: reinstall failed after \(reason) (possible TCC revoke / identity)"
            )
            notifyTapHealthChanged()
        } else {
            DevTypeLog.eventTap.info("[EventTap] health: reinstall succeeded after \(reason)")
            notifyTapHealthChanged()
        }
    }

    private func notifyTapHealthChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.onTapHealthChanged?()
        }
    }
}
