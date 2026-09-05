import Foundation

/// §8.1 / §3.4: every injection timing constant in one place.
///
/// These used to be scattered across `TextInjectionPipeline` as a mix of named statics and bare
/// literals (`0.015` before ⌘V, `0.04` before the arrows, `count * 0.002 + 0.01` after backspaces,
/// two `usleep(15_000)` inside ⌘V). They are all guesses, and a guess that is invisible cannot be
/// tuned. Naming them is the precondition for `InjectTimingStore`, which replaces the two that
/// actually matter — restore delay and paste hold timeout — with a measured per-app value.
public enum InjectTiming {
    // MARK: - Clipboard restore

    /// Payload-size heuristic: bytes per second of assumed pasteboard read throughput.
    public static let restoreDelayBytesPerSecond: Double = 40_000
    /// Floor for an app we know nothing about. Raised from 0.10 → 0.15 historically so slow
    /// Chromium/Electron hosts can read the pasteboard before we restore the user's clipboard.
    public static let restoreDelayFloor: TimeInterval = 0.15
    public static let restoreDelayCeiling: TimeInterval = 0.45
    /// §3.4: once an app has a measured p90 delivery latency it may drop below the blind floor,
    /// but never below this — CGEvent posting itself is asynchronous.
    public static let restoreDelayAdaptiveFloor: TimeInterval = 0.05

    // MARK: - Paste delivery

    /// Settle between ⌘V and the first AX delivery check (while our text is still on the board).
    public static let pasteDeliverySettleDelay: TimeInterval = 0.05
    /// Max time to hold our pasteboard contents waiting for AX to become readable / catch up.
    public static let pasteDeliveryHoldTimeout: TimeInterval = 0.35
    /// §3.4: bounds for the learned hold timeout.
    public static let pasteDeliveryHoldTimeoutFloor: TimeInterval = 0.15
    public static let pasteDeliveryHoldTimeoutCeiling: TimeInterval = 1.20
    /// Longer hold for password-field secure clipboard paste so the user can press ⌘V if
    /// synthetic paste is dropped under Secure Input.
    public static let secureClipboardPasteHoldTimeout: TimeInterval = 8.0
    /// First ⌘V + one retry when AX proves the field did not change.
    public static let pasteDeliveryMaxAttempts = 2
    /// Settle delay for the deferred AX re-verification pass after unverified HID paste.
    public static let pasteReverifyDelay: TimeInterval = 0.25
    /// §3.4: p90 delivery latency is multiplied by this to pick a restore delay.
    public static let deliverySafetyFactor: Double = 1.5
    /// §3.4: …and by this to pick a hold timeout (we would rather wait than report a false miss).
    public static let holdTimeoutSafetyFactor: Double = 2.5

    // MARK: - Payload residency (§8.12)

    /// How long our payload stays on the pasteboard when **nothing ever proved the host read it**.
    ///
    /// Deliberately longer than `pasteDeliveryHoldTimeout`. The hold timeout answers "how long do
    /// we keep *asking* AX whether the text landed"; residency answers "how long must the bytes
    /// stay readable so ⌘V has something to paste". Those were the same number, which inverted the
    /// risk: hosts AX cannot read (Electron / Chromium) end the hold soonest and are also the
    /// slowest to consume the board, so the user's clipboard went back *before* the paste — and
    /// the host pasted the restored contents instead of the snippet.
    public static let unverifiedPayloadResidencyFloor: TimeInterval = 0.45
    /// Hard cap on residency, stall extensions included. Past this the user's clipboard being
    /// wrong is the bigger harm, and a host this far behind has almost certainly dropped the key.
    public static let unverifiedPayloadResidencyCeiling: TimeInterval = 2.0
    /// Re-probe interval while the target app is not answering AX at all (see
    /// `PasteboardBroker.shouldExtendResidencyForStalledHost`).
    public static let stalledHostResidencyProbeInterval: TimeInterval = 0.15

    // MARK: - Image paste

    /// §3.4 bug: the *text* formula (`bytes / 40_000`) saturates instantly on image data — a 1 MB
    /// image computed 25 s and clamped to the 0.45 s ceiling, so the number was pure noise. Image
    /// bytes say almost nothing about how long the host needs to read the board, so scale far more
    /// gently and clamp to a window sized for image decode rather than for a string copy.
    public static let imageRestoreDelayBytesPerSecond: Double = 8_000_000
    public static let imageRestoreDelayFloor: TimeInterval = 0.25
    public static let imageRestoreDelayCeiling: TimeInterval = 1.0
    /// How long the image stays on the pasteboard while we wait for AX evidence of delivery.
    public static let imageDeliveryHoldTimeout: TimeInterval = 0.5

    // MARK: - HID posting

    /// Settle between writing the pasteboard and posting ⌘V.
    public static let prePasteSettleDelay: TimeInterval = 0.015
    /// Settle between the inject and the caret-positioning arrows.
    public static let preArrowSettleDelay: TimeInterval = 0.04
    /// Gap between Command-down / V / Command-up. Was two `usleep(15_000)` calls — 30 ms of hard
    /// main-thread block per paste. `HIDKeyPoster.postCmdVKeyEventsAsync` schedules instead.
    public static let cmdVModifierGap: TimeInterval = 0.015
    public static let backspacePerKeyDelay: TimeInterval = 0.002
    public static let backspaceTrailingDelay: TimeInterval = 0.01
    public static let arrowPerKeyDelay: TimeInterval = 0.0015
    public static let arrowTrailingDelay: TimeInterval = 0.005

    /// Most left-arrow presses one expansion may post to place the caret.
    ///
    /// The HID fallback runs wherever AX cannot set the caret — Chrome, VS Code, every Electron
    /// host, which is the majority path — and nothing used to bound it. A 400-character snippet
    /// with the cursor macro near the start posted 400 arrow keys and waited
    /// `count * arrowPerKeyDelay` (~600 ms) before completing.
    ///
    /// The latency is the smaller problem. Four hundred arrow presses into an editor with vim
    /// mode, an open autocomplete popup, or a multi-cursor selection do something other than
    /// move the caret, and the user has no way to tell that is what happened. Past this bound
    /// the snippet still lands correctly and the caret simply stays at the end — which is what
    /// an expander without cursor support does anyway.
    ///
    /// 120 covers a line or two of prose, which is what `%|` is actually used for.
    public static let maxCursorArrowKeys = 120

    /// Whether a caret move of `count` arrow presses may be posted.
    ///
    /// Separated from the pipeline so the policy is testable without an event tap and a live
    /// host, and so there is one place that answers it.
    public static func allowsCursorArrows(count: Int) -> Bool {
        count > 0 && count <= maxCursorArrowKeys
    }

    // MARK: - Guards

    /// Settle delay before re-checking a failed erase precondition. Focus and AX state lag behind
    /// AppKit after a panel closes or an app activates, and a stale read must not cost an expand.
    public static let erasePreconditionRetryDelay: TimeInterval = 0.03
    /// §1.3: hard upper bound on one inject. Generous — the secure-clipboard path legitimately
    /// holds for `secureClipboardPasteHoldTimeout` (8 s) before restoring.
    public static let injectCompletionTimeout: TimeInterval = 10.0
    /// §1.7: delay before retrying a pasteboard restore whose write did not land.
    public static let pasteboardRestoreRetryDelay: TimeInterval = 0.05
    public static let maxPasteboardRestoreAttempts = 3
    /// §3.1: how long after an expansion `undoLastExpansion()` still reverts it.
    public static let undoExpansionWindow: TimeInterval = 2.0

    /// UserDefaults key for a user-tunable undo window, in seconds. Unset →
    /// `undoExpansionWindow`. Read per use (only on backspace, never per keystroke).
    public static let undoWindowDefaultsKey = "DevTypeUndoWindowSeconds"

    /// Clamp bounds for the override. A window this short fires only on an immediate
    /// regret; past five seconds a stale record is more hazard than help.
    public static let undoWindowFloor: TimeInterval = 0.5
    public static let undoWindowCeiling: TimeInterval = 5.0

    /// Pure clamp for `effectiveUndoWindow`. Values outside the bounds snap to them;
    /// non-positive / non-finite values fall back to the shipped default.
    public static func clampedUndoWindow(_ raw: Double) -> TimeInterval {
        guard raw.isFinite, raw > 0 else { return undoExpansionWindow }
        return min(undoWindowCeiling, max(undoWindowFloor, raw))
    }

    /// The window actually in force: the user's override when set, else 2.0 s.
    public static var effectiveUndoWindow: TimeInterval {
        clampedUndoWindow(UserDefaults.standard.double(forKey: undoWindowDefaultsKey))
    }
}

/// §3.4: per-app measured paste-delivery latency, persisted next to `AXWriteCapabilityStore`.
///
/// Every timing constant above is a fixed guess, yet the system already **measures** the quantity
/// that matters: `PasteboardBroker.runPasteHoldLoop` knows `elapsed` at the exact moment AX
/// confirms the paste landed. Keeping a bounded per-bundle sample set of that number lets a fast
/// native app stop paying the blind 0.15 s restore floor, and lets a slow Electron host hold the
/// pasteboard long enough to actually be reliable — without either being hardcoded.
///
/// Unknown apps get exactly the previous constants, so this can only change behaviour for an app
/// DevType has successfully pasted into at least `minSamplesForConfidence` times.
public final class InjectTimingStore {
    public static let shared = InjectTimingStore(fileURL: InjectTimingStore.defaultFileURL())

    public static let persistenceFileName = "inject-timing.json"
    public static let persistenceSchemaVersion = 1
    /// Bounded ring per bundle — recent behaviour matters, a year of history does not.
    public static let maxSamplesPerBundle = 32
    /// Below this many samples the measurement is noise; keep the blind defaults.
    public static let minSamplesForConfidence = 4
    /// Samples outside this range are discarded as measurement artifacts (debugger stops, sleep).
    public static let maxPlausibleLatency: TimeInterval = 5.0

    /// §2.4: `os_unfair_lock`, not `NSLock` — consulted from the inject path.
    private let lock = UnfairLock()
    private var samples: [String: [Double]] = [:]

    /// `nil` disables persistence (tests, and the plain `init()`).
    private let fileURL: URL?
    private let ioQueue = DispatchQueue(label: "com.devtype.injecttiming.io", qos: .utility)
    private var savePending = false

    /// In-memory store, so tests stay isolated from the file `shared` owns.
    public convenience init() {
        self.init(fileURL: nil)
    }

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL {
            let parent = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            samples = Self.loadFromDisk(fileURL: fileURL)
        }
    }

    /// `~/Library/Application Support/DevType/inject-timing.json` (AppMuteStore's pattern).
    public static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("DevType", isDirectory: true)
        return dir.appendingPathComponent(persistenceFileName)
    }

    // MARK: - Recording

    /// Records one observed "⌘V posted → AX confirmed the text landed" interval.
    public func recordDeliveryLatency(_ seconds: TimeInterval, bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty, bundleID != "nil" else { return }
        guard seconds >= 0, seconds <= Self.maxPlausibleLatency else { return }
        lock.lock()
        var bucket = samples[bundleID] ?? []
        bucket.append(seconds)
        if bucket.count > Self.maxSamplesPerBundle {
            bucket.removeFirst(bucket.count - Self.maxSamplesPerBundle)
        }
        samples[bundleID] = bucket
        lock.unlock()
        scheduleSave()
    }

    // MARK: - Queries

    /// p90 of observed delivery latency, or `nil` while the sample set is too small to trust.
    public func p90DeliveryLatency(bundleID: String?) -> TimeInterval? {
        guard let bundleID, !bundleID.isEmpty, bundleID != "nil" else { return nil }
        lock.lock()
        let bucket = samples[bundleID]
        lock.unlock()
        guard let bucket, bucket.count >= Self.minSamplesForConfidence else { return nil }
        return Self.percentile(0.9, of: bucket)
    }

    /// Nearest-rank percentile. Pure so the adaptation math is unit-testable.
    public static func percentile(_ fraction: Double, of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(fraction, 0), 1)
        let rank = Int((clamped * Double(sorted.count - 1)).rounded())
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// Blind, size-only restore delay — the pre-§3.4 behaviour, kept as the unknown-app default.
    public static func blindRestoreDelay(payloadBytes: Int) -> TimeInterval {
        let calculated = Double(max(0, payloadBytes)) / InjectTiming.restoreDelayBytesPerSecond
        return max(InjectTiming.restoreDelayFloor, min(InjectTiming.restoreDelayCeiling, calculated))
    }

    /// How long to keep our payload on the pasteboard before restoring the user's clipboard.
    /// Unknown app → identical to `blindRestoreDelay`.
    public func restoreDelay(bundleID: String?, payloadBytes: Int) -> TimeInterval {
        let sizeBased = Double(max(0, payloadBytes)) / InjectTiming.restoreDelayBytesPerSecond
        guard let p90 = p90DeliveryLatency(bundleID: bundleID) else {
            return Self.blindRestoreDelay(payloadBytes: payloadBytes)
        }
        let learnedFloor = max(
            InjectTiming.restoreDelayAdaptiveFloor,
            p90 * InjectTiming.deliverySafetyFactor
        )
        return min(InjectTiming.restoreDelayCeiling, max(learnedFloor, sizeBased))
    }

    /// §8.12: how long the payload must stay on the pasteboard when the paste ended with **no**
    /// delivery evidence — `.unavailable` (AX cannot read the host) or `.failed`.
    ///
    /// Learned samples may only ever *lengthen* this. `restoreDelay` lets a measured p90 pull the
    /// delay below the blind floor, which is right when AX confirmed the paste — the confirmation
    /// is proof the host already read the board. It is exactly wrong here: a p90 recorded while an
    /// app was AX-confirmable says nothing about the same app today reporting nothing at all, and
    /// using it shrank Claude Desktop's residency to 0.15 s. Evidence may shorten a wait; the
    /// *memory* of evidence may not.
    /// - Parameter atLeast: a floor the caller has already committed to — the 8 s window a secure
    ///   clipboard paste keeps open for a manual ⌘V. It is applied *after* the ceiling clamp, so
    ///   this function can only ever lengthen a caller's promise. Making it a parameter rather
    ///   than leaving callers to `max` the result is deliberate: a forgotten `max` at one call
    ///   site would silently clamp that 8 s window down to the 2 s ceiling.
    public func unverifiedPayloadResidency(
        bundleID: String?,
        payloadBytes: Int,
        atLeast: TimeInterval = 0
    ) -> TimeInterval {
        Self.unverifiedPayloadResidency(
            blindDelay: Self.blindRestoreDelay(payloadBytes: payloadBytes),
            p90: p90DeliveryLatency(bundleID: bundleID),
            atLeast: atLeast
        )
    }

    /// Pure form of `unverifiedPayloadResidency`.
    public static func unverifiedPayloadResidency(
        blindDelay: TimeInterval,
        p90: TimeInterval?,
        atLeast: TimeInterval = 0
    ) -> TimeInterval {
        let learned = max(0, p90 ?? 0) * InjectTiming.deliverySafetyFactor
        let candidate = max(InjectTiming.unverifiedPayloadResidencyFloor, max(blindDelay, learned))
        return max(atLeast, min(InjectTiming.unverifiedPayloadResidencyCeiling, candidate))
    }

    /// How long the hold loop keeps polling AX before giving up unverified.
    public func holdTimeout(bundleID: String?) -> TimeInterval {
        guard let p90 = p90DeliveryLatency(bundleID: bundleID) else {
            return InjectTiming.pasteDeliveryHoldTimeout
        }
        let scaled = p90 * InjectTiming.holdTimeoutSafetyFactor
        return min(
            InjectTiming.pasteDeliveryHoldTimeoutCeiling,
            max(InjectTiming.pasteDeliveryHoldTimeoutFloor, scaled)
        )
    }

    /// Image payload bytes are a terrible proxy for host read time — see `InjectTiming`.
    public static func imageRestoreDelay(payloadBytes: Int) -> TimeInterval {
        let sizeBased = Double(max(0, payloadBytes)) / InjectTiming.imageRestoreDelayBytesPerSecond
        return min(
            InjectTiming.imageRestoreDelayCeiling,
            max(InjectTiming.imageRestoreDelayFloor, sizeBased)
        )
    }

    /// Diagnostic block for `DiagnosticReport`.
    public func summaryLines() -> [String] {
        lock.lock()
        let snapshot = samples
        lock.unlock()
        guard !snapshot.isEmpty else { return ["(no paste latency samples recorded)"] }
        var lines: [String] = ["Measured paste delivery latency (p90):"]
        for (bundle, values) in snapshot.sorted(by: { $0.key < $1.key }) {
            guard let p90 = Self.percentile(0.9, of: values) else { continue }
            let confident = values.count >= Self.minSamplesForConfidence ? "" : " (low confidence)"
            let ms = Int((p90 * 1000).rounded())
            lines.append("  \(bundle): \(ms) ms over \(values.count) samples\(confident)")
        }
        return lines
    }

    /// Test / recovery hook.
    public func reset() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        guard let fileURL else { return }
        lock.lock()
        if savePending {
            lock.unlock()
            return
        }
        savePending = true
        lock.unlock()

        // Coalesce a burst of samples into one write, off the inject path entirely.
        ioQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.savePending = false
            let snapshot = self.samples
            self.lock.unlock()
            Self.saveToDisk(snapshot, fileURL: fileURL)
        }
    }

    private struct PersistedFile: Codable {
        var version: Int
        /// bundle ID -> recent delivery latencies, seconds.
        var samples: [String: [Double]]
    }

    private static func loadFromDisk(fileURL: URL) -> [String: [Double]] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(PersistedFile.self, from: data) else {
            return [:]
        }
        guard file.version <= persistenceSchemaVersion else {
            DevTypeLog.inject.notice(
                "[Inject] inject-timing file schema \(file.version, privacy: .public) is newer than \(persistenceSchemaVersion, privacy: .public) — ignoring"
            )
            return [:]
        }
        var result: [String: [Double]] = [:]
        for (bundle, values) in file.samples {
            guard !bundle.isEmpty else { continue }
            let clean = values.filter { $0 >= 0 && $0 <= maxPlausibleLatency }
            guard !clean.isEmpty else { continue }
            result[bundle] = Array(clean.suffix(maxSamplesPerBundle))
        }
        return result
    }

    private static func saveToDisk(_ samples: [String: [Double]], fileURL: URL) {
        let file = PersistedFile(version: persistenceSchemaVersion, samples: samples)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            DevTypeLog.inject.error(
                "[Inject] Failed to persist inject timing samples \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
        }
    }
}
