import Foundation
import AVFoundation

public final class AudioBufferPool: @unchecked Sendable {
    public struct Chunk: Sendable {
        public let sequence: UInt64
        public let sampleTime: Double
        /// When the first frame was captured, in host-clock ticks (`mach_absolute_time`); 0 when
        /// the tap did not supply a valid host time.
        public let hostTime: UInt64
        public let frameCount: AVAudioFrameCount
        public let pcmData: Data
        public let sampleRate: Double
        public let channelCount: AVAudioChannelCount
        public let commonFormatRawValue: AVAudioCommonFormat.RawValue
        public let isInterleaved: Bool

        fileprivate let audioBufferByteCounts: [Int]
        fileprivate let streamDescription: StreamDescription
        fileprivate let channelLayoutTag: AudioChannelLayoutTag?

        /// A buffer the pool owns. The engine tap buffer must never be returned from here:
        /// AVAudioEngine reuses that storage on the next callback.
        public func makePCMBuffer() -> AVAudioPCMBuffer? {
            guard let commonFormat = AVAudioCommonFormat(rawValue: commonFormatRawValue),
                  commonFormat == .pcmFormatFloat32 || commonFormat == .pcmFormatFloat64
            else {
                return nil
            }
            var description = streamDescription.audioStreamBasicDescription
            let channelLayout = channelLayoutTag.flatMap { AVAudioChannelLayout(layoutTag: $0) }
            guard let format = AVAudioFormat(streamDescription: &description, channelLayout: channelLayout),
                  format.commonFormat == commonFormat,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameCount, 1))
            else {
                return nil
            }
            buffer.frameLength = frameCount
            let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard destination.count == audioBufferByteCounts.count else { return nil }
            var offset = 0
            for (index, audioBuffer) in destination.enumerated() {
                let count = audioBufferByteCounts[index]
                let (next, overflowed) = offset.addingReportingOverflow(count)
                guard !overflowed, next <= pcmData.count else { return nil }
                if count > 0 {
                    guard let destinationPointer = audioBuffer.mData, count <= Int(audioBuffer.mDataByteSize) else {
                        return nil
                    }
                    let copied = pcmData.withUnsafeBytes { raw -> Bool in
                        guard let base = raw.baseAddress else { return false }
                        destinationPointer.copyMemory(from: base.advanced(by: offset), byteCount: count)
                        return true
                    }
                    guard copied else { return nil }
                }
                offset = next
            }
            guard offset == pcmData.count else { return nil }
            return buffer
        }
    }

    fileprivate struct StreamDescription: Sendable {
        var sampleRate: Double
        var formatID: UInt32
        var formatFlags: UInt32
        var bytesPerPacket: UInt32
        var framesPerPacket: UInt32
        var bytesPerFrame: UInt32
        var channelsPerFrame: UInt32
        var bitsPerChannel: UInt32

        init(_ description: AudioStreamBasicDescription) {
            sampleRate = description.mSampleRate
            formatID = description.mFormatID
            formatFlags = description.mFormatFlags
            bytesPerPacket = description.mBytesPerPacket
            framesPerPacket = description.mFramesPerPacket
            bytesPerFrame = description.mBytesPerFrame
            channelsPerFrame = description.mChannelsPerFrame
            bitsPerChannel = description.mBitsPerChannel
        }

        var audioStreamBasicDescription: AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: formatID,
                mFormatFlags: formatFlags,
                mBytesPerPacket: bytesPerPacket,
                mFramesPerPacket: framesPerPacket,
                mBytesPerFrame: bytesPerFrame,
                mChannelsPerFrame: channelsPerFrame,
                mBitsPerChannel: bitsPerChannel,
                mReserved: 0
            )
        }
    }

    private struct OwnedPCM {
        let pcmData: Data
        let audioBufferByteCounts: [Int]
        let streamDescription: StreamDescription
        let channelLayoutTag: AudioChannelLayoutTag?
        let commonFormatRawValue: AVAudioCommonFormat.RawValue
        let isInterleaved: Bool
    }

    private let capacity: Int
    private var bufferSlots: [Data]
    private var sequences: [UInt64]
    private var sampleTimes: [Double]
    private var hostTimes: [UInt64]
    private var frameCounts: [AVAudioFrameCount]
    private var sampleRates: [Double]
    private var channelCounts: [AVAudioChannelCount]
    private var commonFormatRawValues: [AVAudioCommonFormat.RawValue]
    private var interleavedFlags: [Bool]
    private var audioBufferByteCounts: [[Int]]
    private var streamDescriptions: [StreamDescription]
    private var channelLayoutTags: [AudioChannelLayoutTag?]
    private var writeHead: Int = 0
    private var readHead: Int = 0
    private var currentSequence: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    /// The share of `droppedFrameCount` refused by the copy itself (oversized, non-float, or
    /// unreadable), as opposed to a full ring. A refusal repeats on every callback of that format.
    private var rejectedFrameCount: UInt64 = 0
    /// Enqueues not yet observed by `waitForEnqueue`. Cleared when `dequeueAll` empties the ring,
    /// so a batched drain cannot leave a counting semaphore credited once per chunk.
    private var pendingNotices: Int = 0
    /// `wakeWaiters` must unblock a drain even when the ring is empty. A lost `signal` before
    /// the waiter arrives stays latched until the next wait.
    private var wakeRequested = false
    private let condition = NSCondition()
    private let maxChunkByteSize: Int

    /// Prevent malformed configuration from turning a callback buffer into an allocation or
    /// modulo trap. The default ring remains unchanged; only hostile values are clamped.
    private static let minimumCapacity = 2
    private static let maximumCapacity = 4096
    private static let maximumChunkByteSize = 4 * 1024 * 1024
    private static let maximumStoredBytes = 64 * 1024 * 1024
    /// `installTap`'s `bufferSize` is advisory: AVAudioEngine documents a 100–400 ms range and
    /// macOS 27 delivers 4800-frame (100 ms) buffers at 48 kHz for a 2048-frame request. Size the
    /// chunk for a full second so no callback the engine may choose is refused by the copy.
    static let maximumCallbackSeconds: Double = 1
    private static let minimumCallbackFrames: AVAudioFrameCount = 4096

    /// A pool whose chunk bound fits every callback the microphone tap can deliver in `format`.
    /// The compile-time defaults are sized for 2048-frame mono buffers and refuse real hardware.
    public convenience init(capturing format: AVAudioFormat, capacity: Int = 128) {
        let bytesPerSample = format.commonFormat == .pcmFormatFloat64 ? 8 : 4
        let channels = max(1, Int(format.channelCount))
        let callbackFrames = format.sampleRate.isFinite && format.sampleRate > 0
            ? (format.sampleRate * Self.maximumCallbackSeconds).rounded(.up)
            : 0
        let frames = callbackFrames < Double(AVAudioFrameCount.max)
            ? max(Self.minimumCallbackFrames, AVAudioFrameCount(callbackFrames))
            : AVAudioFrameCount.max
        self.init(capacity: capacity, maxChunkFrames: frames, bytesPerFrame: bytesPerSample * channels)
    }

    public init(capacity: Int = 128, maxChunkFrames: AVAudioFrameCount = 4096, bytesPerFrame: Int = 4) {
        let requestedCapacity = min(max(Self.minimumCapacity, capacity), Self.maximumCapacity)
        let requestedFrames = max(1, Int(maxChunkFrames))
        let requestedBytesPerFrame = max(1, bytesPerFrame)
        let (requestedChunkByteSize, overflow) = requestedFrames.multipliedReportingOverflow(
            by: requestedBytesPerFrame
        )
        let chunkByteSize = min(
            overflow ? Self.maximumChunkByteSize : requestedChunkByteSize,
            Self.maximumChunkByteSize
        )
        let memoryLimitedCapacity = max(Self.minimumCapacity, Self.maximumStoredBytes / chunkByteSize)

        self.capacity = min(requestedCapacity, memoryLimitedCapacity)
        self.maxChunkByteSize = chunkByteSize
        let emptyDescription = StreamDescription(AudioStreamBasicDescription())
        self.bufferSlots = Array(repeating: Data(), count: self.capacity)
        self.sequences = Array(repeating: 0, count: self.capacity)
        self.sampleTimes = Array(repeating: 0.0, count: self.capacity)
        self.hostTimes = Array(repeating: 0, count: self.capacity)
        self.frameCounts = Array(repeating: 0, count: self.capacity)
        self.sampleRates = Array(repeating: 0, count: self.capacity)
        self.channelCounts = Array(repeating: 0, count: self.capacity)
        self.commonFormatRawValues = Array(repeating: AVAudioCommonFormat.otherFormat.rawValue, count: self.capacity)
        self.interleavedFlags = Array(repeating: false, count: self.capacity)
        self.audioBufferByteCounts = Array(repeating: [], count: self.capacity)
        self.streamDescriptions = Array(repeating: emptyDescription, count: self.capacity)
        self.channelLayoutTags = Array(repeating: nil, count: self.capacity)
    }

    /// Copies every float channel before returning. The caller may reuse `buffer` immediately.
    /// A zero-length buffer is ignored. Overflow and buffers that cannot be copied are drops:
    /// the ring slot a reader has not consumed is left unchanged.
    public func enqueue(buffer: AVAudioPCMBuffer, sampleTime: Double, hostTime: UInt64 = 0) -> Bool {
        enqueue(
            bufferList: UnsafePointer(buffer.mutableAudioBufferList),
            frameLength: buffer.frameLength,
            format: buffer.format,
            sampleTime: sampleTime,
            hostTime: hostTime
        )
    }

    /// The one copy every tap API goes through: the legacy tap hands an `AVAudioPCMBuffer`, the
    /// macOS 27 tap a read-only buffer that only exposes its `AudioBufferList`. The list is read,
    /// never retained, so the caller's storage may be reused as soon as this returns.
    public func enqueue(
        bufferList: UnsafePointer<AudioBufferList>,
        frameLength frames: AVAudioFrameCount,
        format: AVAudioFormat,
        sampleTime: Double,
        hostTime: UInt64 = 0
    ) -> Bool {
        if frames == 0 {
            return true
        }
        // Copy before the lock. NSLock/NSCondition are not recursive, and the memcpy must not
        // run while a reader is blocked on this pool's lock.
        let copied = copyFloatPCM(bufferList, format: format)

        condition.lock()
        defer { condition.unlock() }

        let nextWrite = (writeHead + 1) % capacity
        if nextWrite == readHead || copied == nil {
            droppedFrameCount = Saturating.adding(droppedFrameCount, UInt64(frames))
            if copied == nil {
                rejectedFrameCount = Saturating.adding(rejectedFrameCount, UInt64(frames))
            }
            return false
        }
        guard let copied else { return false }

        let wasEmpty = readHead == writeHead
        currentSequence = Saturating.incrementing(currentSequence)
        bufferSlots[writeHead] = copied.pcmData
        sequences[writeHead] = currentSequence
        sampleTimes[writeHead] = sampleTime
        hostTimes[writeHead] = hostTime
        frameCounts[writeHead] = frames
        sampleRates[writeHead] = format.sampleRate
        channelCounts[writeHead] = format.channelCount
        commonFormatRawValues[writeHead] = copied.commonFormatRawValue
        interleavedFlags[writeHead] = copied.isInterleaved
        audioBufferByteCounts[writeHead] = copied.audioBufferByteCounts
        streamDescriptions[writeHead] = copied.streamDescription
        channelLayoutTags[writeHead] = copied.channelLayoutTag
        writeHead = nextWrite
        pendingNotices += 1
        if wasEmpty {
            condition.signal()
        }
        return true
    }

    /// Blocks until a published chunk is still unnoticed, `wakeWaiters` runs, or `timeout` expires.
    /// Callers must not invoke this on the `DurableVoiceCapture` actor executor.
    func waitForEnqueue(timeout: DispatchTime) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(Self.seconds(until: timeout))
        while pendingNotices == 0 && !wakeRequested {
            if !condition.wait(until: deadline) {
                return false
            }
        }
        if pendingNotices > 0 {
            pendingNotices -= 1
            return true
        }
        wakeRequested = false
        return true
    }

    func wakeWaiters() {
        condition.lock()
        wakeRequested = true
        condition.signal()
        condition.unlock()
    }

    /// Frames rejected by overflow or by a copy that could not be made. Saturates.
    public var droppedFrames: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return droppedFrameCount
    }

    /// Frames the copy refused (oversized, non-float, or unreadable). Included in
    /// `droppedFrames`; a full ring is not counted here. Saturates.
    public var rejectedFrames: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return rejectedFrameCount
    }

    /// Dequeues available chunks for background serial writer.
    public func dequeueAll() -> [Chunk] {
        condition.lock()
        defer { condition.unlock() }

        var results: [Chunk] = []
        while readHead != writeHead {
            let chunk = Chunk(
                sequence: sequences[readHead],
                sampleTime: sampleTimes[readHead],
                hostTime: hostTimes[readHead],
                frameCount: frameCounts[readHead],
                pcmData: bufferSlots[readHead],
                sampleRate: sampleRates[readHead],
                channelCount: channelCounts[readHead],
                commonFormatRawValue: commonFormatRawValues[readHead],
                isInterleaved: interleavedFlags[readHead],
                audioBufferByteCounts: audioBufferByteCounts[readHead],
                streamDescription: streamDescriptions[readHead],
                channelLayoutTag: channelLayoutTags[readHead]
            )
            results.append(chunk)
            readHead = (readHead + 1) % capacity
        }
        pendingNotices = 0
        return results
    }

    public func reset() {
        condition.lock()
        defer { condition.unlock() }
        writeHead = 0
        readHead = 0
        currentSequence = 0
        droppedFrameCount = 0
        rejectedFrameCount = 0
        pendingNotices = 0
    }

    private static func seconds(until timeout: DispatchTime) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        let target = timeout.uptimeNanoseconds
        guard target > now else { return 0 }
        return Double(target - now) / 1_000_000_000
    }

    /// Float PCM only, copied from the audio buffer list for both widths. Anything else is a
    /// drop, not an alias.
    private func copyFloatPCM(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> OwnedPCM? {
        let commonFormat = format.commonFormat
        switch commonFormat {
        case .pcmFormatFloat32, .pcmFormatFloat64:
            break
        default:
            return nil
        }

        // Read-only: the mutable wrapper is only how Core Audio exposes iteration.
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard !source.isEmpty else { return nil }

        var counts: [Int] = []
        counts.reserveCapacity(source.count)
        var total = 0
        for audioBuffer in source {
            let count = Int(audioBuffer.mDataByteSize)
            if count > 0 && audioBuffer.mData == nil {
                return nil
            }
            let (sum, overflowed) = total.addingReportingOverflow(count)
            if overflowed || sum > maxChunkByteSize {
                return nil
            }
            total = sum
            counts.append(count)
        }

        var pcmData = Data(count: total)
        let copied = pcmData.withUnsafeMutableBytes { raw -> Bool in
            guard total == 0 || raw.baseAddress != nil else { return false }
            var offset = 0
            for (index, audioBuffer) in source.enumerated() {
                let count = counts[index]
                if count > 0 {
                    guard let sourcePointer = audioBuffer.mData, let base = raw.baseAddress else {
                        return false
                    }
                    base.advanced(by: offset).copyMemory(from: sourcePointer, byteCount: count)
                }
                offset += count
            }
            return true
        }
        guard copied else { return nil }

        let layoutTag = Self.storableLayoutTag(format.channelLayout?.layoutTag)
        return OwnedPCM(
            pcmData: pcmData,
            audioBufferByteCounts: counts,
            streamDescription: StreamDescription(format.streamDescription.pointee),
            channelLayoutTag: layoutTag,
            commonFormatRawValue: commonFormat.rawValue,
            isInterleaved: format.isInterleaved
        )
    }

    /// Tag initializers cannot represent description or bitmap layouts. Those fall back to the
    /// stream description alone rather than aliasing the caller's `AudioChannelLayout` memory.
    private static func storableLayoutTag(_ tag: AudioChannelLayoutTag?) -> AudioChannelLayoutTag? {
        guard let tag else { return nil }
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions || tag == kAudioChannelLayoutTag_UseChannelBitmap {
            return nil
        }
        return tag
    }
}
