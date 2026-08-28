import Foundation
import AVFoundation

public final class AudioBufferPool: @unchecked Sendable {
    public struct Chunk: Sendable {
        public let sequence: UInt64
        public let sampleTime: Double
        public let frameCount: AVAudioFrameCount
        public let pcmData: Data
    }

    private let capacity: Int
    private var bufferSlots: [Data]
    private var sequences: [UInt64]
    private var sampleTimes: [Double]
    private var frameCounts: [AVAudioFrameCount]
    private var writeHead: Int = 0
    private var readHead: Int = 0
    private var currentSequence: UInt64 = 0
    private let lock = NSLock()
    private let maxChunkByteSize: Int

    public init(capacity: Int = 128, maxChunkFrames: AVAudioFrameCount = 4096, bytesPerFrame: Int = 4) {
        self.capacity = capacity
        self.maxChunkByteSize = Int(maxChunkFrames) * bytesPerFrame
        self.bufferSlots = Array(repeating: Data(repeating: 0, count: self.maxChunkByteSize), count: capacity)
        self.sequences = Array(repeating: 0, count: capacity)
        self.sampleTimes = Array(repeating: 0.0, count: capacity)
        self.frameCounts = Array(repeating: 0, count: capacity)
    }

    /// Enqueues audio data from callback. Returns true if queued, false if dropped (overflow).
    public func enqueue(buffer: AVAudioPCMBuffer, sampleTime: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let nextWrite = (writeHead + 1) % capacity
        if nextWrite == readHead {
            // Buffer pool full - backpressure drop
            return false
        }

        currentSequence += 1
        let seq = currentSequence
        let frames = buffer.frameLength
        let byteCount = Int(frames) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)

        guard byteCount <= maxChunkByteSize, let channelData = buffer.floatChannelData else {
            return false
        }

        // Copy raw float bytes directly
        let data = Data(bytes: channelData[0], count: byteCount)
        bufferSlots[writeHead] = data
        sequences[writeHead] = seq
        sampleTimes[writeHead] = sampleTime
        frameCounts[writeHead] = frames

        writeHead = nextWrite
        return true
    }

    /// Dequeues available chunks for background serial writer.
    public func dequeueAll() -> [Chunk] {
        lock.lock()
        defer { lock.unlock() }

        var results: [Chunk] = []
        while readHead != writeHead {
            let chunk = Chunk(
                sequence: sequences[readHead],
                sampleTime: sampleTimes[readHead],
                frameCount: frameCounts[readHead],
                pcmData: bufferSlots[readHead]
            )
            results.append(chunk)
            readHead = (readHead + 1) % capacity
        }
        return results
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeHead = 0
        readHead = 0
        currentSequence = 0
    }
}
