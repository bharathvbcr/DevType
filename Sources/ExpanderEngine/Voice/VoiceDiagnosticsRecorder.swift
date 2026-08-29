import Foundation

/// Opt-in trace of the live dictation path, written to a local file.
///
/// The unified log carries lengths and outcomes, which is enough to see *that* text was
/// erased but not always *why*. Reproducing an erase needs the actual sequence: which
/// segment arrived, what the assembler made of it, what the reconciler decided. That
/// requires the transcript, and a transcript is exactly what must not go into a system log
/// that other software can read.
///
/// So it goes here instead: off by default, written only to a file in the app's own
/// container, and only while the user has switched it on to capture a problem.
public final class VoiceDiagnosticsRecorder: @unchecked Sendable {
    public static let shared = VoiceDiagnosticsRecorder()

    /// Cap on the trace file. A dictation produces a few hundred lines; this is generous
    /// for several sessions and small enough to attach to a bug report.
    public static let maxBytes = 4 * 1024 * 1024

    private let lock = UnfairLock()
    private let queue = DispatchQueue(label: "com.devtype.voice.diagnostics", qos: .utility)
    private lazy var encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private init() {}

    // MARK: - Location

    public static var traceURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevType", isDirectory: true)
        return base.appendingPathComponent("voice-trace.jsonl")
    }

    /// Whether tracing is on. Off by default — this records what the user dictated.
    public var isEnabled: Bool {
        get { VoicePreferences.isVoiceTracingEnabled }
        set { VoicePreferences.isVoiceTracingEnabled = newValue }
    }

    // MARK: - Events

    /// One line of the trace. Field names are short because these are read as a column of
    /// JSON, often hundreds at a time.
    public struct Event: Codable, Sendable {
        public let at: Date
        public let kind: String
        /// Segment identity, when the event concerns one.
        public let segment: String?
        public let revision: UInt64?
        public let finality: String?
        /// The dictated text at this point. Present only because the whole purpose of this
        /// file is to reproduce a text defect.
        public let text: String?
        /// Assembler view.
        public let settled: String?
        public let active: String?
        public let cumulative: String?
        /// Reconciler decision.
        public let committedLength: Int?
        public let volatileLength: Int?
        public let erase: Int?
        public let inject: String?
        public let suppressed: Bool?
        public let note: String?
    }

    // MARK: - Recording

    public func record(
        _ kind: String,
        segment: SpeechSegment? = nil,
        settled: String? = nil,
        active: String? = nil,
        cumulative: String? = nil,
        committedLength: Int? = nil,
        volatileLength: Int? = nil,
        erase: Int? = nil,
        inject: String? = nil,
        suppressed: Bool? = nil,
        note: String? = nil
    ) {
        guard isEnabled else { return }

        let event = Event(
            at: Date(),
            kind: kind,
            segment: segment?.segmentID,
            revision: segment?.revision,
            finality: segment.map { $0.finality == .final ? "final" : "volatile" },
            text: segment?.text,
            settled: settled,
            active: active,
            cumulative: cumulative,
            committedLength: committedLength,
            volatileLength: volatileLength,
            erase: erase,
            inject: inject,
            suppressed: suppressed,
            note: note
        )

        queue.async { [weak self] in
            self?.append(event)
        }
    }

    private func append(_ event: Event) {
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)   // newline

        let url = Self.traceURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        lock.withLock {
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? data.write(to: url)
                return
            }
            defer { try? handle.close() }

            // Roll over rather than growing without bound; a stale first half is worth less
            // than a bounded file the user can actually attach.
            if (try? handle.seekToEnd()).map({ $0 > UInt64(Self.maxBytes) }) == true {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: data)
        }
    }

    // MARK: - Retrieval

    /// The trace as text, newest last. `nil` when nothing has been recorded.
    public func read() -> String? {
        guard let data = try? Data(contentsOf: Self.traceURL),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    public func clear() {
        lock.withLock {
            try? FileManager.default.removeItem(at: Self.traceURL)
        }
    }

    /// Marks a session boundary so separate dictations are distinguishable in the file.
    public func beginSession(engine: String, realTimeTyping: Bool) {
        record(
            "session.begin",
            note: "engine=\(engine) realTimeTyping=\(realTimeTyping)"
        )
    }
}
