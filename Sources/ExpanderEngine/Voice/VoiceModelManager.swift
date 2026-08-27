import Foundation
import CryptoKit

/// Current status of a voice model on disk.
public enum VoiceModelStatus: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double, bytesWritten: Int64, totalBytes: Int64)
    case ready(URL)
    case error(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Manages local voice model storage, on-demand downloading, SHA-256 integrity verification,
/// and lifecycle management in `~/Library/Application Support/DevType/Models/`.
public final class VoiceModelManager: NSObject, @unchecked Sendable {
    public static let shared = VoiceModelManager()

    private let lock = UnfairLock()
    private let fileManager = FileManager.default
    private let modelsDirectoryURL: URL
    private var downloadTasks: [VoiceModelType: URLSessionDownloadTask] = [:]
    private var downloadProgressHandlers: [VoiceModelType: (Double, Int64, Int64) -> Void] = [:]
    private var downloadCompletionHandlers: [VoiceModelType: (Result<URL, Error>) -> Void] = [:]
    private var statusListeners: [UUID: @Sendable (VoiceModelType, VoiceModelStatus) -> Void] = [:]
    private var session: URLSession!

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.modelsDirectoryURL = baseDirectory.appendingPathComponent("Models", isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.modelsDirectoryURL = appSupport.appendingPathComponent("DevType/Models", isDirectory: true)
        }
        super.init()

        // Create models directory if needed
        try? fileManager.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public var modelsDirectory: URL {
        modelsDirectoryURL
    }

    public func isModelReady(_ type: VoiceModelType) -> Bool {
        if case .ready = status(for: type) {
            return true
        }
        return false
    }

    // MARK: - Status & Paths

    /// Returns the file URL where the model should reside.
    public func modelFileURL(for type: VoiceModelType) -> URL {
        let filename: String
        switch type {
        case .voxtralMini4B:
            filename = "voxtral-mini-4b-realtime.q4_k_m.gguf"
        case .funASRNano:
            filename = "funasr-nano-q8_0.gguf"
        case .appleSpeech:
            filename = "system"
        }
        return modelsDirectoryURL
            .appendingPathComponent(type.rawValue, isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Checks the current disk status for a model.
    public func status(for type: VoiceModelType) -> VoiceModelStatus {
        if type == .appleSpeech {
            return .ready(URL(fileURLWithPath: "/System/Library/Frameworks/Speech.framework"))
        }

        return lock.withLock {
            if let task = downloadTasks[type], task.state == .running {
                let bytesWritten = task.countOfBytesReceived
                let totalBytes = task.countOfBytesExpectedToReceive
                let progress = totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : 0.0
                return .downloading(progress: progress, bytesWritten: bytesWritten, totalBytes: totalBytes)
            }

            let fileURL = modelFileURL(for: type)
            if fileManager.fileExists(atPath: fileURL.path) {
                // If file size is valid (> 10MB)
                if let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                   let size = attrs[.size] as? Int64, size > 10_000_000 {
                    return .ready(fileURL)
                }
            }
            return .notDownloaded
        }
    }

    // MARK: - Listeners

    @discardableResult
    public func addStatusListener(
        _ listener: @escaping @Sendable (VoiceModelType, VoiceModelStatus) -> Void
    ) -> UUID {
        let token = UUID()
        lock.withLock {
            statusListeners[token] = listener
        }
        return token
    }

    public func removeStatusListener(_ token: UUID) {
        lock.withLock {
            _ = statusListeners.removeValue(forKey: token)
        }
    }

    private func notifyStatusChanged(type: VoiceModelType, status: VoiceModelStatus) {
        let listeners = lock.withLock { Array(statusListeners.values) }
        for listener in listeners {
            listener(type, status)
        }
    }

    // MARK: - Download & Installation

    /// Begins or resumes downloading a voice model.
    public func startDownload(
        for type: VoiceModelType,
        progress: (@Sendable (Double, Int64, Int64) -> Void)? = nil,
        completion: (@Sendable (Result<URL, Error>) -> Void)? = nil
    ) {
        guard type != .appleSpeech else {
            completion?(.success(modelFileURL(for: type)))
            return
        }

        let descriptor = type.descriptor

        lock.withLock {
            if let existing = downloadTasks[type], existing.state == .running {
                return
            }

            if let progress {
                downloadProgressHandlers[type] = progress
            }
            if let completion {
                downloadCompletionHandlers[type] = completion
            }

            let task = session.downloadTask(with: descriptor.downloadURL)
            downloadTasks[type] = task
            task.resume()
        }

        notifyStatusChanged(type: type, status: .downloading(progress: 0.0, bytesWritten: 0, totalBytes: descriptor.approximateBytes))
    }

    /// Cancels an active download.
    public func cancelDownload(for type: VoiceModelType) {
        lock.withLock {
            if let task = downloadTasks.removeValue(forKey: type) {
                task.cancel()
            }
            downloadProgressHandlers.removeValue(forKey: type)
            if let completion = downloadCompletionHandlers.removeValue(forKey: type) {
                completion(.failure(CancellationError()))
            }
        }
        notifyStatusChanged(type: type, status: .notDownloaded)
    }

    /// Deletes a downloaded model from local storage.
    public func deleteModel(for type: VoiceModelType) throws {
        guard type != .appleSpeech else { return }
        cancelDownload(for: type)

        let folder = modelsDirectoryURL.appendingPathComponent(type.rawValue, isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        notifyStatusChanged(type: type, status: .notDownloaded)
    }

    /// Installs a local model file directly (e.g. from local path or test fixture).
    public func installLocalModel(from sourceURL: URL, for type: VoiceModelType) throws {
        let destinationURL = modelFileURL(for: type)
        let destinationFolder = destinationURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        notifyStatusChanged(type: type, status: .ready(destinationURL))
    }

    /// Validates SHA256 checksum of an installed file.
    public static func verifyChecksum(fileURL: URL, expectedHex: String) -> Bool {
        guard !expectedHex.isEmpty else { return true }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return false }
        let digest = SHA256.hash(data: data)
        let hexString = digest.map { String(format: "%02x", $0) }.joined()
        return hexString.caseInsensitiveCompare(expectedHex) == .orderedSame
    }
}

// MARK: - URLSessionDownloadDelegate

extension VoiceModelManager: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let type: VoiceModelType? = lock.withLock {
            downloadTasks.first(where: { $0.value == downloadTask })?.key
        }
        guard let type else { return }

        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0.0

        let progressHandler = lock.withLock { downloadProgressHandlers[type] }
        progressHandler?(progress, totalBytesWritten, totalBytesExpectedToWrite)

        notifyStatusChanged(
            type: type,
            status: .downloading(
                progress: progress,
                bytesWritten: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
        )
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let (type, completionHandler) = lock.withLock { () -> (VoiceModelType?, ((Result<URL, Error>) -> Void)?) in
            guard let match = downloadTasks.first(where: { $0.value == downloadTask }) else {
                return (nil, nil)
            }
            downloadTasks.removeValue(forKey: match.key)
            let completion = downloadCompletionHandlers.removeValue(forKey: match.key)
            downloadProgressHandlers.removeValue(forKey: match.key)
            return (match.key, completion)
        }

        guard let type else { return }

        let targetURL = modelFileURL(for: type)
        let targetFolder = targetURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: targetFolder, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.moveItem(at: location, to: targetURL)

            notifyStatusChanged(type: type, status: .ready(targetURL))
            completionHandler?(.success(targetURL))
        } catch {
            notifyStatusChanged(type: type, status: .error(error.localizedDescription))
            completionHandler?(.failure(error))
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let (type, completionHandler) = lock.withLock { () -> (VoiceModelType?, ((Result<URL, Error>) -> Void)?) in
            guard let match = downloadTasks.first(where: { $0.value == task }) else {
                return (nil, nil)
            }
            downloadTasks.removeValue(forKey: match.key)
            let completion = downloadCompletionHandlers.removeValue(forKey: match.key)
            downloadProgressHandlers.removeValue(forKey: match.key)
            return (match.key, completion)
        }

        guard let type else { return }
        notifyStatusChanged(type: type, status: .error(error.localizedDescription))
        completionHandler?(.failure(error))
    }
}
