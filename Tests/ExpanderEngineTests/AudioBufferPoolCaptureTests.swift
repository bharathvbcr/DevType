import AVFoundation
import Foundation
import XCTest
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

    private static func floats(in data: Data) -> [Float] {
        data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}

final class DurableVoiceCaptureTapCopyTests: XCTestCase {
    func testInstallTapDoesNotPassTheEngineBufferIntoATask() throws {
        let source = try String(
            contentsOf: Self.captureSourceURL,
            encoding: .utf8
        )
        let marker = "installTap(onBus:"
        guard let start = source.range(of: marker) else {
            return XCTFail("DurableVoiceCapture must install the microphone tap")
        }
        let tail = source[start.lowerBound...]
        guard let end = tail.range(of: "\n        }") else {
            return XCTFail("Could not isolate the installTap closure")
        }
        let closure = String(tail[..<end.upperBound])
        XCTAssertFalse(
            closure.contains("Task"),
            "The tap must copy synchronously and must not hop the engine buffer onto a Task"
        )
        XCTAssertFalse(
            closure.contains("handleAudioCallback"),
            "The tap must not retain the engine AVAudioPCMBuffer for later processing"
        )
        XCTAssertTrue(
            closure.contains(".enqueue("),
            "The tap must hand the engine buffer to AudioBufferPool.enqueue before returning"
        )
        XCTAssertFalse(
            closure.contains("self"),
            "The tap must capture the pool, not the actor, so the realtime thread does not hop actors"
        )
        XCTAssertTrue(
            source.contains("bufferPool.droppedFrames"),
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

    private static var captureSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ExpanderEngine/Voice/Audio/DurableVoiceCapture.swift")
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
