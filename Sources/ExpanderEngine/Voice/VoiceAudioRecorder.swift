import AVFoundation
import Foundation

/// Audio capture and live metering engine with millisecond-1 crash journaling inspired by Jot.
public final class VoiceAudioRecorder: @unchecked Sendable {
    public static let shared = VoiceAudioRecorder()

    private let lock = UnfairLock()
    private var audioEngine: AVAudioEngine?
    private var isRecording = false
    private var audioFileHandle: FileHandle?
    private var journalURL: URL?
    private var latestFinalizedURL: URL?
    private var totalBytesRecorded: Int64 = 0
    private var currentLevel: Float = 0.0
    private var activeSessionUUID: UUID?
    private let cacheDirectoryURL: URL
    private var configChangeObserver: NSObjectProtocol?

    /// Handler called with smoothed audio level (0.0 to 1.0) for live waveform visualization.
    public var onAudioLevelUpdate: (@Sendable (Float) -> Void)?

    /// Handler called with live 16kHz PCM audio buffers for real-time streaming speech recognition.
    public var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public var voiceCacheDirectory: URL {
        cacheDirectoryURL
    }

    public var targetAudioFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    }

    public init(cacheDirectory: URL? = nil) {
        if let cacheDirectory {
            self.cacheDirectoryURL = cacheDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.cacheDirectoryURL = appSupport.appendingPathComponent("DevType/VoiceCache", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.cacheDirectoryURL, withIntermediateDirectories: true)
        setupAudioConfigurationObserver()
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupAudioConfigurationObserver() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleAudioConfigurationChange()
        }
    }

    private func handleAudioConfigurationChange() {
        lock.withLock {
            guard isRecording, let engine = audioEngine else { return }
            DevTypeLog.app.info("[Voice] Audio hardware configuration changed mid-recording; restarting engine")
            if !engine.isRunning {
                try? engine.start()
            }
        }
    }

    public func cleanupOldJournals() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("active_session_") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Permissions

    /// Checks whether microphone permission is granted.
    public static func checkMicrophonePermission() -> Bool {
        if #available(macOS 14.0, *) {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
        return true
    }

    /// Requests microphone access from the user.
    public static func requestMicrophonePermission(completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    // MARK: - Recording Lifecycle

    /// Begins recording audio from the default input device.
    /// Sets up live buffering and immediate disk journaling to protect against crashes.
    public func startRecording() throws {
        try lock.withLock {
            guard !isRecording else { return }

            let sessionID = UUID()
            self.activeSessionUUID = sessionID

            let engine = AVAudioEngine()
            self.audioEngine = engine

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            guard inputFormat.sampleRate > 0 else {
                throw NSError(domain: "VoiceAudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid audio hardware format"])
            }

            // Target format: 16kHz Mono 16-bit PCM
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: true
            ) else {
                throw NSError(domain: "VoiceAudioRecorder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create 16kHz audio format"])
            }

            guard let formatConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw NSError(domain: "VoiceAudioRecorder", code: -3, userInfo: [NSLocalizedDescriptionKey: "Audio converter configuration failed"])
            }

            // Setup millisecond-1 journal file
            let activeJournal = cacheDirectoryURL.appendingPathComponent("active_session_\(sessionID.uuidString).pcm")
            FileManager.default.createFile(atPath: activeJournal.path, contents: nil)
            guard let fileHandle = try? FileHandle(forWritingTo: activeJournal) else {
                throw NSError(domain: "VoiceAudioRecorder", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to create journal file"])
            }

            self.audioFileHandle = fileHandle
            self.journalURL = activeJournal
            self.totalBytesRecorded = 0

            let bufferSize: AVAudioFrameCount = 1024

            inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }

                // 1. Calculate live RMS audio power for waveform UI
                let level = Self.calculateRMS(buffer: buffer)
                self.lock.withLock { self.currentLevel = level }
                self.onAudioLevelUpdate?(level)

                // 2. Convert to 16kHz 16-bit mono PCM and journal directly to disk
                let ratio = 16000.0 / inputFormat.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

                var error: NSError?
                var isDone = false
                formatConverter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if isDone {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    isDone = true
                    outStatus.pointee = .haveData
                    return buffer
                }

                if error == nil && convertedBuffer.frameLength > 0 {
                    let byteCount = Int(convertedBuffer.frameLength) * 2
                    if let int16Data = convertedBuffer.int16ChannelData?[0] {
                        let data = Data(bytes: int16Data, count: byteCount)
                        self.lock.withLock {
                            if let handle = self.audioFileHandle {
                                try? handle.write(contentsOf: data)
                                self.totalBytesRecorded += Int64(byteCount)
                            }
                        }
                    }
                    self.onAudioBuffer?(convertedBuffer)
                }
            }

            do {
                try engine.start()
                self.isRecording = true
            } catch {
                // Atomic cleanup on start failure
                inputNode.removeTap(onBus: 0)
                try? fileHandle.close()
                try? FileManager.default.removeItem(at: activeJournal)
                self.audioEngine = nil
                self.audioFileHandle = nil
                self.journalURL = nil
                self.isRecording = false
                throw error
            }
        }
    }

    /// Stops recording and finalizes the audio data into a standard WAV file.
    public func stopRecording() -> URL? {
        lock.withLock {
            guard isRecording else { return latestFinalizedURL }

            if let engine = audioEngine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                self.audioEngine = nil
            }

            if let handle = audioFileHandle {
                try? handle.close()
                self.audioFileHandle = nil
            }

            self.isRecording = false
            self.currentLevel = 0.0

            guard let journal = journalURL, FileManager.default.fileExists(atPath: journal.path) else {
                return nil
            }

            let sessionID = activeSessionUUID?.uuidString ?? UUID().uuidString
            let finalWavURL = cacheDirectoryURL.appendingPathComponent("session_\(sessionID).wav")

            if let rawData = try? Data(contentsOf: journal), rawData.count > 0 {
                let wavData = Self.createWavData(fromPCM: rawData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
                try? wavData.write(to: finalWavURL)
                try? FileManager.default.removeItem(at: journal)
                self.journalURL = nil
                self.latestFinalizedURL = finalWavURL
                return finalWavURL
            }

            try? FileManager.default.removeItem(at: journal)
            self.journalURL = nil
            return nil
        }
    }

    /// Cancels recording and discards the active audio journal.
    public func cancelRecording() {
        lock.withLock {
            if let engine = audioEngine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                self.audioEngine = nil
            }

            if let handle = audioFileHandle {
                try? handle.close()
                self.audioFileHandle = nil
            }

            if let journal = journalURL {
                try? FileManager.default.removeItem(at: journal)
                self.journalURL = nil
            }

            self.isRecording = false
            self.currentLevel = 0.0
            self.activeSessionUUID = nil
        }
    }

    /// Checks if there is any unfinalized audio from a previous crash/unexpected termination.
    public func checkForCrashRecoveredAudio() -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectoryURL, includingPropertiesForKeys: nil) else {
            return nil
        }

        let journalFiles = files.filter { $0.lastPathComponent.hasPrefix("active_session_") && $0.pathExtension == "pcm" }
        guard let latestJournal = journalFiles.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first else {
            return nil
        }

        guard let rawData = try? Data(contentsOf: latestJournal), rawData.count > 3200 else {
            try? FileManager.default.removeItem(at: latestJournal)
            return nil
        }

        let recoveredWavURL = cacheDirectoryURL.appendingPathComponent("recovered_session_\(UUID().uuidString).wav")
        let wavData = Self.createWavData(fromPCM: rawData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        try? wavData.write(to: recoveredWavURL)
        try? FileManager.default.removeItem(at: latestJournal)
        return recoveredWavURL
    }

    // MARK: - Level Metering & Utilities

    private static func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0.0 }
        let frames = buffer.frameLength
        guard frames > 0 else { return 0.0 }

        var sum: Float = 0.0
        for i in 0..<Int(frames) {
            let sample = channelData[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frames))
        let db = 20 * log10(max(rms, 0.0001))
        let minDb: Float = -45.0
        let maxDb: Float = -3.0
        let normalized = (db - minDb) / (maxDb - minDb)
        return min(max(normalized, 0.0), 1.0)
    }

    /// Generates standard 44-byte RIFF/WAV header around raw 16-bit PCM bytes.
    public static func createWavData(fromPCM pcmData: Data, sampleRate: Int32, channels: Int16, bitsPerSample: Int16) -> Data {
        var header = Data()
        let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let subchunk2Size = Int32(pcmData.count)
        let chunkSize = 36 + subchunk2Size

        // RIFF chunk descriptor
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
        header.append(contentsOf: "WAVE".utf8)

        // "fmt " sub-chunk
        header.append(contentsOf: "fmt ".utf8)
        let subchunk1Size: Int32 = 16
        header.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian) { Data($0) })
        let audioFormat: Int16 = 1 // PCM
        header.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // "data" sub-chunk
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: subchunk2Size.littleEndian) { Data($0) })
        header.append(pcmData)

        return header
    }
}
