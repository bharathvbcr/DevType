import AVFoundation
import Foundation
import XCTest
import SourceTreeTestSupport
@testable import ExpanderEngine

final class AudioBufferPoolCopyTests: XCTestCase {
    func testEnqueueKeepsEveryChannelAfterTheSourceBufferIsMutated() throws {
        let pool = AudioBufferPool(capacity: 8, maxChunkFrames: 64, bytesPerFrame: 4)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4) else {
            XCTFail("Failed to create a stereo buffer")
            return
        }
        buffer.frameLength = 4
        for frame in 0..<4 {
            buffer.floatChannelData?[0][frame] = Float(frame) + 0.25
            buffer.floatChannelData?[1][frame] = Float(frame) + 40
        }

        XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: 12.5))
        for frame in 0..<4 {
            buffer.floatChannelData?[0][frame] = -1
            buffer.floatChannelData?[1][frame] = -2
        }

        let chunk = try XCTUnwrap(pool.dequeueAll().first)
        XCTAssertEqual(
            chunk.pcmData.count,
            4 * 4 * 2,
            "Both non-interleaved channels must be copied before enqueue returns"
        )
        let channel0 = chunk.pcmData.prefix(16)
        let channel1 = chunk.pcmData.dropFirst(16).prefix(16)
        XCTAssertEqual(Self.floats(in: channel0), [0.25, 1.25, 2.25, 3.25])
        XCTAssertEqual(Self.floats(in: channel1), [40, 41, 42, 43])

        let rebuilt = try XCTUnwrap(chunk.makePCMBuffer())
        XCTAssertFalse(rebuilt === buffer)
        XCTAssertTrue(rebuilt.format.isEqual(format))
        XCTAssertEqual(rebuilt.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(rebuilt.format.channelCount, 2)
        XCTAssertFalse(rebuilt.format.isInterleaved)
        for frame in 0..<4 {
            XCTAssertEqual(rebuilt.floatChannelData?[0][frame], Float(frame) + 0.25)
            XCTAssertEqual(rebuilt.floatChannelData?[1][frame], Float(frame) + 40)
        }
    }

    func testOverflowCountsRejectedFramesAndLeavesQueuedBytesUntouched() throws {
        let pool = AudioBufferPool(capacity: 4, maxChunkFrames: 32, bytesPerFrame: 4)
        var sources: [AVAudioPCMBuffer] = []
        var expected: [[Float]] = []
        for index in 0..<3 {
            let buffer = try Self.monoBuffer(frames: 4)
            var samples: [Float] = []
            for frame in 0..<4 {
                let sample = Float(index * 10 + frame) + 0.5
                buffer.floatChannelData?[0][frame] = sample
                samples.append(sample)
            }
            XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: Double(index)))
            sources.append(buffer)
            expected.append(samples)
        }

        let rejected = try Self.monoBuffer(frames: 9)
        rejected.floatChannelData?[0][0] = 123
        XCTAssertFalse(pool.enqueue(buffer: rejected, sampleTime: 3))
        XCTAssertEqual(pool.droppedFrames, 9)
        let rejectedAgain = try Self.monoBuffer(frames: 2)
        XCTAssertFalse(pool.enqueue(buffer: rejectedAgain, sampleTime: 4))
        XCTAssertEqual(pool.droppedFrames, 11)

        for source in sources {
            source.floatChannelData?[0][0] = -99
        }
        rejected.floatChannelData?[0][0] = -99

        let chunks = pool.dequeueAll()
        XCTAssertEqual(chunks.count, 3)
        for (chunk, samples) in zip(chunks, expected) {
            let rebuilt = try XCTUnwrap(chunk.makePCMBuffer())
            for frame in 0..<4 {
                XCTAssertEqual(rebuilt.floatChannelData?[0][frame], samples[frame])
            }
        }
    }

    func testZeroLengthEnqueueDoesNotCountAsOverflow() throws {
        let pool = AudioBufferPool(capacity: 2, maxChunkFrames: 32, bytesPerFrame: 4)
        let queued = try Self.monoBuffer(frames: 4)
        queued.floatChannelData?[0][0] = 0.25
        XCTAssertTrue(pool.enqueue(buffer: queued, sampleTime: 0))

        let empty = try Self.monoBuffer(frames: 0)
        XCTAssertTrue(pool.enqueue(buffer: empty, sampleTime: 1))
        XCTAssertEqual(pool.droppedFrames, 0)

        let rejected = try Self.monoBuffer(frames: 3)
        XCTAssertFalse(pool.enqueue(buffer: rejected, sampleTime: 2))
        XCTAssertEqual(pool.droppedFrames, 3)
        XCTAssertTrue(pool.enqueue(buffer: empty, sampleTime: 3))
        XCTAssertEqual(pool.droppedFrames, 3)

        let chunk = try XCTUnwrap(pool.dequeueAll().first)
        let rebuilt = try XCTUnwrap(chunk.makePCMBuffer())
        XCTAssertEqual(rebuilt.floatChannelData?[0][0], 0.25)
    }

    func testNonFloatEnqueueDropsInsteadOfAliasingCallerMemory() throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6) else {
            XCTFail("Failed to create an int16 buffer")
            return
        }
        buffer.frameLength = 6
        buffer.int16ChannelData?[0][0] = 1234
        buffer.int16ChannelData?[1][0] = 5678
        let pool = AudioBufferPool(capacity: 4, maxChunkFrames: 32, bytesPerFrame: 4)
        XCTAssertFalse(pool.enqueue(buffer: buffer, sampleTime: 0))
        XCTAssertEqual(pool.droppedFrames, 6)
        XCTAssertTrue(pool.dequeueAll().isEmpty)
        buffer.int16ChannelData?[0][0] = 0
        buffer.int16ChannelData?[1][0] = 0
        XCTAssertTrue(pool.dequeueAll().isEmpty)
    }

    func testOversizedChunkIsADrop() throws {
        let pool = AudioBufferPool(capacity: 4, maxChunkFrames: 2, bytesPerFrame: 4)
        let buffer = try Self.monoBuffer(frames: 4)
        XCTAssertFalse(pool.enqueue(buffer: buffer, sampleTime: 0))
        XCTAssertEqual(pool.droppedFrames, 4)
        XCTAssertTrue(pool.dequeueAll().isEmpty)
    }

    /// macOS 27 ignores `installTap(bufferSize: 2048)` and delivers 4800 frames (100 ms) at
    /// 48 kHz. The default pool's 4096-frame bound refused every such callback, so dictation
    /// recorded nothing and reported "No speech detected".
    func testDefaultPoolRefusesTheTapBufferMacOS27Delivers() throws {
        let pool = AudioBufferPool()
        let buffer = try Self.hardwareBuffer(sampleRate: 48_000, channels: 1, frames: 4800)
        XCTAssertFalse(pool.enqueue(buffer: buffer, sampleTime: 0))
        XCTAssertEqual(pool.rejectedFrames, 4800)
    }

    func testFormatSizedPoolAcceptsEveryTapBufferSizeTheEngineMayChoose() throws {
        let cases: [(rate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount)] = [
            (48_000, 1, 4800),   // 100 ms, observed on macOS 27.0.1
            (48_000, 1, 19_200), // 400 ms, the documented ceiling
            (44_100, 1, 4410),
            (48_000, 2, 4800),
            (96_000, 1, 38_400),
            (16_000, 1, 2048),
        ]
        for item in cases {
            let buffer = try Self.hardwareBuffer(
                sampleRate: item.rate,
                channels: item.channels,
                frames: item.frames
            )
            let pool = AudioBufferPool(capturing: buffer.format)
            XCTAssertTrue(
                pool.enqueue(buffer: buffer, sampleTime: 0),
                "\(item.rate) Hz × \(item.channels) ch × \(item.frames) frames was refused"
            )
            XCTAssertEqual(pool.droppedFrames, 0)
            let chunk = try XCTUnwrap(pool.dequeueAll().first)
            XCTAssertEqual(chunk.frameCount, item.frames)
            XCTAssertNotNil(chunk.makePCMBuffer())
        }
    }

    func testFormatSizedPoolAcceptsFloat64() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat64,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let pool = AudioBufferPool(capturing: format)
        XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: 0))
        XCTAssertEqual(pool.rejectedFrames, 0)
    }

    func testRingOverflowIsNotCountedAsARejectedCopy() throws {
        let pool = AudioBufferPool(capacity: 2, maxChunkFrames: 8, bytesPerFrame: 4)
        XCTAssertTrue(pool.enqueue(buffer: try Self.monoBuffer(frames: 4), sampleTime: 0))
        XCTAssertFalse(pool.enqueue(buffer: try Self.monoBuffer(frames: 4), sampleTime: 1))
        XCTAssertEqual(pool.droppedFrames, 4)
        XCTAssertEqual(pool.rejectedFrames, 0)

        _ = pool.dequeueAll()
        XCTAssertFalse(pool.enqueue(buffer: try Self.monoBuffer(frames: 16), sampleTime: 2))
        XCTAssertEqual(pool.droppedFrames, 20)
        XCTAssertEqual(pool.rejectedFrames, 16)

        pool.reset()
        XCTAssertEqual(pool.rejectedFrames, 0)
    }

    func testEnqueueBenchmarkOf2048FrameMonoBuffer() throws {
        let frames: AVAudioFrameCount = 2048
        let pool = AudioBufferPool(capacity: 4096, maxChunkFrames: frames, bytesPerFrame: 4)
        let buffer = try Self.monoBuffer(frames: frames)
        buffer.floatChannelData?[0][0] = 0.1
        for _ in 0..<20 {
            _ = pool.enqueue(buffer: buffer, sampleTime: 0)
        }
        _ = pool.dequeueAll()

        let iterations = 1000
        var accepted = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            buffer.floatChannelData?[0][0] = Float(index)
            if pool.enqueue(buffer: buffer, sampleTime: Double(index)) {
                accepted += 1
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let nsPerCall = Double(elapsed) / Double(iterations)
        print(String(format: "BENCH AudioBufferPool.enqueue ns/call=%.1f accepted=%d", nsPerCall, accepted))
        XCTAssertEqual(accepted, iterations)
    }

    private static func monoBuffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)))
        buffer.frameLength = frames
        return buffer
    }

    /// The shape `AVAudioInputNode` taps deliver: Float32, non-interleaved.
    static func hardwareBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData?[channel][frame] = sinf(Float(frame) * 0.05) * 0.5
            }
        }
        return buffer
    }

    private static func floats(in data: Data) -> [Float] {
        data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}

final class DurableVoiceCaptureTapCopyTests: XCTestCase {
    /// Both tap APIs — the macOS 27 throwing tap and the legacy one — must copy synchronously
    /// into the pool and capture nothing else.
    func testInstallTapDoesNotPassTheEngineBufferIntoATask() throws {
        let source = try SourceTree.text("Sources/ExpanderEngine/Voice/Audio/CaptureInput.swift")
        for marker in ["installAudioTap(onBus:", "installTap(onBus:"] {
            guard let start = source.range(of: marker) else {
                return XCTFail("CaptureInput must install the microphone tap through \(marker)")
            }
            let lineStart = source[..<start.lowerBound].lastIndex(of: "\n").map { source.index(after: $0) }
                ?? source.startIndex
            let indent = String(source[lineStart..<start.lowerBound].prefix { $0 == " " })
            let tail = source[start.lowerBound...]
            guard let end = tail.range(of: "\n\(indent)}") else {
                return XCTFail("Could not isolate the \(marker) closure")
            }
            let closure = String(tail[..<end.upperBound])
            XCTAssertFalse(
                closure.contains("Task"),
                "\(marker): the tap must copy synchronously and must not hop the engine buffer onto a Task"
            )
            XCTAssertFalse(
                closure.contains("handleAudioCallback"),
                "\(marker): the tap must not retain the engine buffer for later processing"
            )
            XCTAssertTrue(
                closure.contains(".enqueue("),
                "\(marker): the tap must hand the engine buffer to AudioBufferPool.enqueue before returning"
            )
            XCTAssertFalse(
                closure.contains("self"),
                "\(marker): the tap must capture the pool, not the actor, so the realtime thread does not hop actors"
            )
        }
        let capture = try SourceTree.text("Sources/ExpanderEngine/Voice/Audio/DurableVoiceCapture.swift")
        XCTAssertTrue(
            capture.contains("segment.pool.droppedFrames"),
            "Artifact gapCount must include frames the pool rejected"
        )
    }

    func testDrainJoinPublishesAnOwnedBufferAndFinalizesTheWriterOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcm-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try CAFSessionWriter(
            outputURL: directory.appendingPathComponent("capture.caf"),
            sampleRate: 16_000,
            channelCount: 1
        )
        let sourceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 64))
        source.frameLength = 64
        source.floatChannelData?[0][0] = 0.5
        let pool = AudioBufferPool(capacity: 8, maxChunkFrames: 128, bytesPerFrame: 4)
        XCTAssertTrue(pool.enqueue(buffer: source, sampleTime: 1))
        source.floatChannelData?[0][0] = -1

        let published = PublishedBuffer()
        let converter = AVAudioConverter(from: sourceFormat, to: writer.targetFormat)
        let drain = PCMCaptureDrain(
            pool: pool,
            writer: writer,
            converter: converter,
            targetFormat: writer.targetFormat,
            onPCMBuffer: { buffer in
                published.store(buffer)
            },
            onLevel: { _ in }
        )
        drain.start()
        let first = drain.stopAndJoin(timeout: 2)
        let second = drain.stopAndJoin(timeout: 2)
        XCTAssertNil(first.joinFailure)
        XCTAssertNil(first.captureError, first.captureError?.redactedDetail ?? "")
        XCTAssertNil(second.joinFailure)
        let publishedBuffer = try XCTUnwrap(published.buffer)
        XCTAssertFalse(publishedBuffer === source)
        XCTAssertEqual(publishedBuffer.format.commonFormat, .pcmFormatInt16)
        let stats = try writer.finalize()
        XCTAssertGreaterThan(stats.totalFrames, 0)
        XCTAssertThrowsError(try writer.finalize())
    }

    /// End to end through the path `startCapture` builds: a 48 kHz tap buffer of the size
    /// macOS 27 delivers must reach the 16 kHz recording and the live recognizer.
    func testHardwareSizedTapBuffersReachTheRecording() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcm-drain-hw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = try CAFSessionWriter(
            outputURL: directory.appendingPathComponent("capture.caf"),
            sampleRate: 16_000,
            channelCount: 1
        )
        let first = try AudioBufferPoolCopyTests.hardwareBuffer(sampleRate: 48_000, channels: 1, frames: 4800)
        let pool = AudioBufferPool(capturing: first.format)
        for index in 0..<10 {
            let buffer = try AudioBufferPoolCopyTests.hardwareBuffer(sampleRate: 48_000, channels: 1, frames: 4800)
            XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: Double(index * 4800)))
        }

        let published = PublishedBuffer()
        let drain = PCMCaptureDrain(
            pool: pool,
            writer: writer,
            converter: AVAudioConverter(from: first.format, to: writer.targetFormat),
            targetFormat: writer.targetFormat,
            onPCMBuffer: { buffer in published.store(buffer) },
            onLevel: { _ in }
        )
        drain.start()
        let outcome = drain.stopAndJoin(timeout: 2)
        XCTAssertNil(outcome.joinFailure)
        XCTAssertNil(outcome.captureError, outcome.captureError?.redactedDetail ?? "")
        XCTAssertEqual(pool.droppedFrames, 0)
        XCTAssertNotNil(published.buffer, "the live recognizer never received audio")
        let stats = try writer.finalize()
        // One second at 48 kHz is exactly 16 000 frames at 16 kHz once the converter's withheld
        // tail is flushed at stop. Without the flush this came out 20 frames short.
        XCTAssertEqual(stats.totalFrames, 16_000)
        XCTAssertEqual(outcome.acceptedFrames, 16_000)
    }

    func testRefusedCopiesFailAsAudioEncodingNotAsNoSpeech() throws {
        XCTAssertNil(DurableVoiceCapture.rejectedAudioFailure(rejectedFrames: 0, acceptedFrames: 0))

        let nothingKept = try XCTUnwrap(
            DurableVoiceCapture.rejectedAudioFailure(rejectedFrames: 72_000, acceptedFrames: 0)
        )
        XCTAssertEqual(nothingKept.code, .audioEncodingFailed)
        XCTAssertEqual(nothingKept.artifactState, .absent)

        let someKept = try XCTUnwrap(
            DurableVoiceCapture.rejectedAudioFailure(rejectedFrames: 4800, acceptedFrames: 16_000)
        )
        XCTAssertEqual(someKept.code, .audioEncodingFailed)
        XCTAssertEqual(someKept.artifactState, .partial)
    }

    func testEmptyRecordingIsNoSpeechOnlyWhenNothingWasDropped() {
        XCTAssertEqual(DurableVoiceCapture.emptyCaptureFailure(droppedFrames: 0).code, .zeroFramesCaptured)
        XCTAssertEqual(DurableVoiceCapture.emptyCaptureFailure(droppedFrames: 9600).code, .captureBackpressure)
    }

    func testStartCaptureSizesThePoolFromTheHardwareFormat() throws {
        let source = try SourceTree.text("Sources/ExpanderEngine/Voice/Audio/DurableVoiceCapture.swift")
        XCTAssertTrue(
            source.contains("AudioBufferPool(capturing: input.format)"),
            "the pool must be sized from the format the tap delivers"
        )
        XCTAssertFalse(
            source.contains("bufferPool.reset()"),
            "reusing the default-sized pool refuses 100 ms hardware buffers"
        )
    }
}

final class LiveSpeechStreamPendingBufferTests: XCTestCase {
    func testAppendStoresAnIndependentCopyWhenNoRecognitionRequestIsActive() {
        let starts = NSLockCounter()
        let runtime = AppleOnDeviceSpeechRuntime(
            isAvailable: { false },
            supportsOnDeviceRecognition: { true },
            startRecognition: { _, _ in
                starts.increment()
                return AppleSpeechTaskHandle(cancel: {})
            }
        )
        let stream = LiveSpeechStream(
            runtime: runtime,
            onSegment: { _ in },
            onFailure: { _ in }
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8) else {
            XCTFail("Failed to create a stereo buffer")
            return
        }
        buffer.frameLength = 8
        for frame in 0..<8 {
            buffer.floatChannelData?[0][frame] = Float(frame) + 0.5
            buffer.floatChannelData?[1][frame] = Float(frame) + 40
        }

        stream.append(buffer)
        for frame in 0..<8 {
            buffer.floatChannelData?[0][frame] = -3
            buffer.floatChannelData?[1][frame] = -4
        }

        let pending = stream.pendingPCMBuffersForTesting()
        XCTAssertEqual(starts.value, 0)
        XCTAssertEqual(pending.count, 1)
        guard let stored = pending.first else { return }
        XCTAssertFalse(stored === buffer)
        for frame in 0..<8 {
            XCTAssertEqual(stored.floatChannelData?[0][frame], Float(frame) + 0.5)
            XCTAssertEqual(stored.floatChannelData?[1][frame], Float(frame) + 40)
        }
    }
}

private final class PublishedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: AVAudioPCMBuffer?

    func store(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        storage = buffer
        lock.unlock()
    }

    var buffer: AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class NSLockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
