import AVFoundation
import CommonCrypto
import Foundation
import XCTest
import SourceTreeTestSupport
@testable import ExpanderEngine

/// Adversarial checks for the synchronous mic-buffer copy. No microphone.
final class AudioBufferPoolAdversarialTests: XCTestCase {
    private var layoutStorage: [UnsafeMutableRawPointer] = []

    deinit {
        for pointer in layoutStorage {
            pointer.deallocate()
        }
    }

    func testFloat64StereoSurvivesCallerMutation() throws {
        let pool = AudioBufferPool(capacity: 8, maxChunkFrames: 64, bytesPerFrame: 8)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat64,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let left: [Double] = [0.5, 1.5, 2.5, 3.5]
        let right: [Double] = [40, 41, 42, 43]
        writeDoubles(left, channel: 0, of: buffer)
        writeDoubles(right, channel: 1, of: buffer)

        let floatChannelDataIsNil = buffer.floatChannelData == nil
        XCTAssertTrue(
            pool.enqueue(buffer: buffer, sampleTime: 7),
            "float64 stereo must be copied, not dropped (floatChannelDataNil=\(floatChannelDataIsNil))"
        )
        writeDoubles([-9, -9, -9, -9], channel: 0, of: buffer)
        writeDoubles([-8, -8, -8, -8], channel: 1, of: buffer)

        let chunk = try XCTUnwrap(pool.dequeueAll().first)
        XCTAssertEqual(doubles(in: chunk.pcmData.prefix(32)), left)
        XCTAssertEqual(doubles(in: chunk.pcmData.dropFirst(32).prefix(32)), right)
        let rebuilt = try XCTUnwrap(chunk.makePCMBuffer(), "stored float64 could not be rebuilt")
        XCTAssertFalse(rebuilt === buffer)
        XCTAssertEqual(rebuilt.format.commonFormat, .pcmFormatFloat64)
        XCTAssertEqual(rebuilt.format.channelCount, 2)
        XCTAssertFalse(rebuilt.format.isInterleaved)
        XCTAssertEqual(readDoubles(channel: 0, of: rebuilt, count: 4), left)
        XCTAssertEqual(readDoubles(channel: 1, of: rebuilt, count: 4), right)
        XCTAssertEqual(pool.droppedFrames, 0)
    }

    func testInterleavedFloat64StereoSurvivesCallerMutation() throws {
        let pool = AudioBufferPool(capacity: 4, maxChunkFrames: 32, bytesPerFrame: 16)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat64,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let interleaved: [Double] = [0.5, 40, 1.5, 41, 2.5, 42, 3.5, 43]
        writeDoubles(interleaved, channel: 0, of: buffer)

        XCTAssertTrue(
            pool.enqueue(buffer: buffer, sampleTime: 1),
            "interleaved float64 must be copied (floatChannelDataNil=\(buffer.floatChannelData == nil))"
        )
        writeDoubles(Array(repeating: -1, count: 8), channel: 0, of: buffer)

        let chunk = try XCTUnwrap(pool.dequeueAll().first)
        XCTAssertEqual(doubles(in: chunk.pcmData), interleaved)
        let rebuilt = try XCTUnwrap(chunk.makePCMBuffer())
        XCTAssertTrue(rebuilt.format.isInterleaved)
        XCTAssertEqual(readDoubles(channel: 0, of: rebuilt, count: 8), interleaved)
    }

    func testInterleavedFloat32StereoKeepsBothChannelsAfterMutation() throws {
        let pool = AudioBufferPool(capacity: 4, maxChunkFrames: 32, bytesPerFrame: 8)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let stride = buffer.stride
        for frame in 0..<4 {
            buffer.floatChannelData?[0][frame * stride] = Float(frame) + 0.5
            buffer.floatChannelData?[1][frame * stride] = Float(frame) + 10
        }
        let original = floats(in: Data(
            bytes: buffer.floatChannelData![0],
            count: 4 * MemoryLayout<Float>.size * 2
        ))

        XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: 2))
        for frame in 0..<4 {
            buffer.floatChannelData?[0][frame * stride] = -1
            buffer.floatChannelData?[1][frame * stride] = -2
        }

        let chunk = try XCTUnwrap(pool.dequeueAll().first)
        XCTAssertEqual(floats(in: chunk.pcmData), original)
        let rebuilt = try XCTUnwrap(chunk.makePCMBuffer())
        XCTAssertTrue(rebuilt.format.isInterleaved)
        XCTAssertEqual(rebuilt.format.channelCount, 2)
        let rebuiltStride = rebuilt.stride
        for frame in 0..<4 {
            XCTAssertEqual(rebuilt.floatChannelData?[0][frame * rebuiltStride], Float(frame) + 0.5)
            XCTAssertEqual(rebuilt.floatChannelData?[1][frame * rebuiltStride], Float(frame) + 10)
        }
    }

    func testStorableChannelLayoutTagIsPreserved() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo))
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            interleaved: false,
            channelLayout: layout
        ))
        let pool = AudioBufferPool(capacity: 4, maxChunkFrames: 16, bytesPerFrame: 8)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        buffer.floatChannelData?[0][0] = 0.25
        buffer.floatChannelData?[1][0] = 0.75
        let originalTag = try XCTUnwrap(buffer.format.channelLayout?.layoutTag)
        XCTAssertNotEqual(originalTag, kAudioChannelLayoutTag_UseChannelDescriptions)
        XCTAssertNotEqual(originalTag, kAudioChannelLayoutTag_UseChannelBitmap)

        XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: 0))
        buffer.floatChannelData?[0][0] = -1
        buffer.floatChannelData?[1][0] = -1

        let chunk = try XCTUnwrap(pool.dequeueAll().first)
        let rebuilt = try XCTUnwrap(chunk.makePCMBuffer())
        XCTAssertEqual(rebuilt.format.channelLayout?.layoutTag, originalTag)
        XCTAssertEqual(rebuilt.floatChannelData?[0][0], 0.25)
        XCTAssertEqual(rebuilt.floatChannelData?[1][0], 0.75)
    }

    func testDescriptionAndBitmapLayoutsDoNotAliasTheCaller() throws {
        let descriptionSentinel: AudioChannelLabel = 0x00F0_0D
        try assertLayoutDoesNotAlias(makeDescriptionLayout(), mutate: { layout in
            UnsafeMutablePointer(mutating: layout.layout)
                .pointee.mChannelDescriptions.mChannelLabel = descriptionSentinel
        }, aliased: { layout in
            layout.layout.pointee.mChannelDescriptions.mChannelLabel == descriptionSentinel
        })

        let bitmapSentinel = AudioChannelBitmap(rawValue: 0x00F0_0D)
        try assertLayoutDoesNotAlias(makeBitmapLayout(), mutate: { layout in
            UnsafeMutablePointer(mutating: layout.layout).pointee.mChannelBitmap = bitmapSentinel
        }, aliased: { layout in
            layout.layout.pointee.mChannelBitmap == bitmapSentinel
        })
    }

    func testOverflowDoesNotOverwriteAnUnreadSlotOrWakeADrainedWaiter() throws {
        let pool = AudioBufferPool(capacity: 3, maxChunkFrames: 32, bytesPerFrame: 4)
        var expected: [[Float]] = []
        for index in 0..<2 {
            let buffer = try monoBuffer(frames: 4)
            var samples: [Float] = []
            for frame in 0..<4 {
                let sample = Float(index * 10 + frame) + 0.5
                buffer.floatChannelData?[0][frame] = sample
                samples.append(sample)
            }
            XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: Double(index)))
            expected.append(samples)
        }
        for _ in 0..<2 {
            XCTAssertTrue(pool.waitForEnqueue(timeout: .now() + .seconds(1)))
        }

        let rejected = try monoBuffer(frames: 4)
        for frame in 0..<4 {
            rejected.floatChannelData?[0][frame] = 999
        }
        let waiter = WaitResult()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            started.signal()
            let woke = pool.waitForEnqueue(timeout: .now() + .milliseconds(350))
            waiter.store(woke)
            finished.signal()
        }.start()
        XCTAssertEqual(started.wait(timeout: .now() + .seconds(1)), .success)
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertFalse(pool.enqueue(buffer: rejected, sampleTime: 9))
        for frame in 0..<4 {
            rejected.floatChannelData?[0][frame] = -5
        }
        XCTAssertEqual(finished.wait(timeout: .now() + .seconds(2)), .success)
        XCTAssertFalse(waiter.value, "a drop signaled a waiter that had already consumed every queued wake")
        XCTAssertEqual(pool.droppedFrames, 4)

        let chunks = pool.dequeueAll()
        XCTAssertEqual(chunks.count, 2)
        for (chunk, samples) in zip(chunks, expected) {
            XCTAssertEqual(floats(in: chunk.pcmData), samples)
            XCTAssertFalse(floats(in: chunk.pcmData).contains(999))
        }
    }

    func testBatchedDequeueDoesNotLetTheWakeSemaphoreGrowWithoutBound() throws {
        let capacity = 4
        let usable = 3
        let pool = AudioBufferPool(capacity: capacity, maxChunkFrames: 8, bytesPerFrame: 4)
        let buffer = try monoBuffer(frames: 1)
        for cycle in 0..<30 {
            var expected: [Float] = []
            for slot in 0..<usable {
                let sample = Float(cycle * 10 + slot) + 0.25
                buffer.floatChannelData?[0][0] = sample
                XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: Double(slot)))
                expected.append(sample)
            }
            buffer.floatChannelData?[0][0] = -99
            XCTAssertTrue(pool.waitForEnqueue(timeout: .now() + .seconds(1)))
            let chunks = pool.dequeueAll()
            XCTAssertEqual(chunks.count, usable)
            for (chunk, sample) in zip(chunks, expected) {
                XCTAssertEqual(floats(in: chunk.pcmData), [sample])
            }
        }

        var spurious = 0
        while spurious < capacity + 8 {
            guard pool.waitForEnqueue(timeout: .now() + .milliseconds(30)) else { break }
            spurious += 1
            XCTAssertTrue(
                pool.dequeueAll().isEmpty,
                "a leftover wake must not observe a slot the reader already consumed"
            )
        }
        XCTAssertLessThanOrEqual(
            spurious,
            capacity,
            "wake semaphore grew to \(spurious) across batched dequeueAll; ring capacity is \(capacity)"
        )
    }

    func testZeroLengthNonFloatAndOversizedChunksAreDropsWithoutAliasing() throws {
        let pool = AudioBufferPool(capacity: 4, maxChunkFrames: 4, bytesPerFrame: 4)
        let kept = try monoBuffer(frames: 4)
        kept.floatChannelData?[0][0] = 0.5
        XCTAssertTrue(pool.enqueue(buffer: kept, sampleTime: 0))
        XCTAssertTrue(pool.waitForEnqueue(timeout: .now() + .seconds(1)))

        let empty = try monoBuffer(frames: 0)
        XCTAssertTrue(pool.enqueue(buffer: empty, sampleTime: 1))
        XCTAssertFalse(pool.waitForEnqueue(timeout: .now() + .milliseconds(40)))
        XCTAssertEqual(pool.droppedFrames, 0)

        guard let int16Format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let int16 = AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: 5) else {
            XCTFail("Failed to create an int16 buffer")
            return
        }
        int16.frameLength = 5
        int16.int16ChannelData?[0][0] = 1234
        XCTAssertFalse(pool.enqueue(buffer: int16, sampleTime: 2))
        int16.int16ChannelData?[0][0] = 0
        XCTAssertFalse(pool.waitForEnqueue(timeout: .now() + .milliseconds(40)))

        let oversized = try monoBuffer(frames: 5)
        oversized.floatChannelData?[0][0] = 77
        XCTAssertFalse(pool.enqueue(buffer: oversized, sampleTime: 3))
        oversized.floatChannelData?[0][0] = -1

        let stereoFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        ))
        let stereo = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 3))
        stereo.frameLength = 3
        stereo.floatChannelData?[0][0] = 11
        stereo.floatChannelData?[1][0] = 12
        XCTAssertFalse(
            pool.enqueue(buffer: stereo, sampleTime: 4),
            "two channels whose combined bytes exceed maxChunkByteSize are a drop"
        )

        XCTAssertEqual(pool.droppedFrames, 5 + 5 + 3)
        let chunks = pool.dequeueAll()
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(floats(in: chunks[0].pcmData).first, 0.5)
        let rebuilt = try XCTUnwrap(chunks[0].makePCMBuffer())
        XCTAssertEqual(rebuilt.floatChannelData?[0][0], 0.5)
    }

    func testFrameLengthBelowCapacityStillRebuildsTheValidFrames() throws {
        let pool = AudioBufferPool(capacity: 4, maxChunkFrames: 32, bytesPerFrame: 4)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 4
        for frame in 0..<4 {
            buffer.floatChannelData?[0][frame] = Float(frame) + 0.25
        }
        XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: 3))
        for frame in 0..<4 {
            buffer.floatChannelData?[0][frame] = -1
        }
        let chunk = try XCTUnwrap(pool.dequeueAll().first)
        XCTAssertEqual(chunk.frameCount, 4)
        let rebuilt = try XCTUnwrap(chunk.makePCMBuffer(), "a short frameLength inside a larger capacity must stay readable")
        XCTAssertEqual(rebuilt.frameLength, 4)
        for frame in 0..<4 {
            XCTAssertEqual(rebuilt.floatChannelData?[0][frame], Float(frame) + 0.25)
        }
    }

    func testDroppedFramesAccumulateTheRejectedFrameCount() throws {
        let pool = AudioBufferPool(capacity: 2, maxChunkFrames: 64, bytesPerFrame: 4)
        let first = try monoBuffer(frames: 1)
        XCTAssertTrue(pool.enqueue(buffer: first, sampleTime: 0))
        let droppedA = try monoBuffer(frames: 30)
        let droppedB = try monoBuffer(frames: 40)
        XCTAssertFalse(pool.enqueue(buffer: droppedA, sampleTime: 1))
        XCTAssertFalse(pool.enqueue(buffer: droppedB, sampleTime: 2))
        XCTAssertEqual(pool.droppedFrames, 70)
        let chunk = try XCTUnwrap(pool.dequeueAll().first)
        XCTAssertEqual(chunk.frameCount, 1)
        XCTAssertEqual(Saturating.adding(UInt64.max - 3, 5), UInt64.max)
    }

    func testHostileConfigurationClampsCapacityAndChunkSize() throws {
        let pool = AudioBufferPool(
            capacity: Int.min,
            maxChunkFrames: .max,
            bytesPerFrame: Int.max
        )
        let wide = AudioBufferPool(
            capacity: 10_000,
            maxChunkFrames: .max,
            bytesPerFrame: Int.max
        )
        var accepted = 0
        for index in 0..<64 {
            let buffer = try monoBuffer(frames: 1)
            buffer.floatChannelData?[0][0] = Float(index + 1)
            if wide.enqueue(buffer: buffer, sampleTime: Double(index)) {
                accepted += 1
            } else {
                break
            }
        }
        XCTAssertEqual(accepted, 15, "4 MiB chunks under a 64 MiB cap leave 15 usable slots")
        XCTAssertEqual(wide.droppedFrames, 1)
        let chunks = wide.dequeueAll()
        XCTAssertEqual(chunks.count, 15)
        XCTAssertEqual(floats(in: chunks[0].pcmData), [1])
        XCTAssertEqual(floats(in: chunks[14].pcmData), [15])
        XCTAssertFalse(chunks.contains { floats(in: $0.pcmData).contains(16) })

        let tiny = try monoBuffer(frames: 1)
        tiny.floatChannelData?[0][0] = 3
        XCTAssertTrue(pool.enqueue(buffer: tiny, sampleTime: 0))
        let second = try monoBuffer(frames: 1)
        second.floatChannelData?[0][0] = 4
        XCTAssertFalse(pool.enqueue(buffer: second, sampleTime: 1))
        XCTAssertEqual(floats(in: try XCTUnwrap(pool.dequeueAll().first).pcmData), [3])
    }

    func testEnqueueDequeueAndResetDoNotTearOrCrash() throws {
        let pool = AudioBufferPool(capacity: 8, maxChunkFrames: 128, bytesPerFrame: 4)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "audio-buffer-pool-race", attributes: .concurrent)
        let failures = FailureBox()
        for index in 0..<200 {
            let pattern = UInt32(index + 1)
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let buffer = try Self.monoBuffer(frames: 32)
                    let sample = Float(bitPattern: pattern)
                    for frame in 0..<32 {
                        buffer.floatChannelData?[0][frame] = sample
                    }
                    _ = pool.enqueue(buffer: buffer, sampleTime: Double(index))
                } catch {
                    failures.add("enqueue \(error)")
                }
            }
            group.enter()
            queue.async {
                defer { group.leave() }
                for chunk in pool.dequeueAll() {
                    let samples = Self.floats(in: chunk.pcmData)
                    guard let first = samples.first, samples.allSatisfy({ $0.bitPattern == first.bitPattern }) else {
                        failures.add("torn chunk sequence=\(chunk.sequence) count=\(samples.count)")
                        return
                    }
                }
                _ = pool.droppedFrames
                if index % 11 == 0 {
                    pool.reset()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(failures.values, [])
    }

    func testEnqueueBenchmarkOf2048FrameStereoFloat32() throws {
        let frames: AVAudioFrameCount = 2048
        let pool = AudioBufferPool(capacity: 64, maxChunkFrames: frames, bytesPerFrame: 8)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        buffer.floatChannelData?[0][0] = 0.25
        buffer.floatChannelData?[1][0] = 0.5
        for _ in 0..<8 {
            _ = pool.enqueue(buffer: buffer, sampleTime: 0)
            _ = pool.dequeueAll()
        }
        let iterations = 400
        var accepted = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations {
            buffer.floatChannelData?[0][0] = Float(index)
            if pool.enqueue(buffer: buffer, sampleTime: Double(index)) {
                accepted += 1
            }
            if index % 32 == 31 {
                _ = pool.dequeueAll()
            }
        }
        _ = pool.dequeueAll()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let nsPerCall = Double(elapsed) / Double(iterations)
        print(String(
            format: "BENCH AudioBufferPool.enqueue ns/call=%.1f shape=float32x2 noninterleaved frames=%d accepted=%d",
            nsPerCall,
            Int(frames),
            accepted
        ))
        XCTAssertEqual(accepted, iterations)
    }

    private func assertLayoutDoesNotAlias(
        _ layout: AVAudioChannelLayout?,
        mutate: (AVAudioChannelLayout) -> Void,
        aliased: (AVAudioChannelLayout) -> Bool
    ) throws {
        let channelLayout = try XCTUnwrap(layout)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: channelLayout
        ))
        let pool = AudioBufferPool(capacity: 4, maxChunkFrames: 16, bytesPerFrame: 8)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        buffer.floatChannelData?[0][0] = 0.5
        buffer.floatChannelData?[1][1] = 1.5
        let callerLayout = try XCTUnwrap(buffer.format.channelLayout)
        XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: 0))
        buffer.floatChannelData?[0][0] = -3
        buffer.floatChannelData?[1][1] = -4
        mutate(callerLayout)

        let chunk = try XCTUnwrap(pool.dequeueAll().first)
        XCTAssertEqual(chunk.pcmData.prefix(4).withUnsafeBytes { $0.load(as: Float.self) }, 0.5)
        let rebuilt = try XCTUnwrap(chunk.makePCMBuffer())
        XCTAssertEqual(rebuilt.floatChannelData?[0][0], 0.5)
        if let rebuiltLayout = rebuilt.format.channelLayout {
            XCTAssertFalse(rebuiltLayout.layout == callerLayout.layout)
            XCTAssertFalse(aliased(rebuiltLayout), "rebuilt layout observes the caller's mutated AudioChannelLayout")
        }
    }

    private func makeDescriptionLayout() -> AVAudioChannelLayout? {
        let count = 2
        let size = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
            + count * MemoryLayout<AudioChannelDescription>.size
        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<AudioChannelLayout>.alignment
        )
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        layoutStorage.append(memory)
        let layout = memory.assumingMemoryBound(to: AudioChannelLayout.self)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(count)
        withUnsafeMutablePointer(to: &layout.pointee.mChannelDescriptions) { pointer in
            let descriptions = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: AudioChannelDescription.self)
            descriptions[0].mChannelLabel = kAudioChannelLabel_Left
            descriptions[1].mChannelLabel = kAudioChannelLabel_Right
        }
        return AVAudioChannelLayout(layout: layout)
    }

    private func makeBitmapLayout() -> AVAudioChannelLayout? {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
        layout.mChannelBitmap = AudioChannelBitmap(rawValue: 1 | 2)
        return AVAudioChannelLayout(layout: &layout)
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

    private func monoBuffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        try Self.monoBuffer(frames: frames)
    }

    private static func floats(in data: Data) -> [Float] {
        guard !data.isEmpty else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func floats(in data: Data) -> [Float] {
        Self.floats(in: data)
    }

    private func doubles(in data: Data) -> [Double] {
        guard !data.isEmpty else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    }

    private func writeDoubles(_ values: [Double], channel: Int, of buffer: AVAudioPCMBuffer) {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let pointer = list[channel].mData!.assumingMemoryBound(to: Double.self)
        for (index, value) in values.enumerated() {
            pointer[index] = value
        }
    }

    private func readDoubles(channel: Int, of buffer: AVAudioPCMBuffer, count: Int) -> [Double] {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let pointer = list[channel].mData!.assumingMemoryBound(to: Double.self)
        return (0..<count).map { pointer[$0] }
    }
}

final class LiveSpeechStreamAdversarialTests: XCTestCase {
    func testPendingFloat64CopyIsIndependentOfTheCaller() throws {
        let stream = unavailableStream()
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat64,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for frame in 0..<4 {
            list[0].mData!.assumingMemoryBound(to: Double.self)[frame] = Double(frame) + 0.5
            list[1].mData!.assumingMemoryBound(to: Double.self)[frame] = Double(frame) + 20
        }

        stream.append(buffer)
        for frame in 0..<4 {
            list[0].mData!.assumingMemoryBound(to: Double.self)[frame] = -1
            list[1].mData!.assumingMemoryBound(to: Double.self)[frame] = -2
        }

        let pending = stream.pendingPCMBuffersForTesting()
        XCTAssertEqual(pending.count, 1)
        let stored = try XCTUnwrap(pending.first)
        XCTAssertFalse(stored === buffer)
        let storedList = UnsafeMutableAudioBufferListPointer(stored.mutableAudioBufferList)
        for frame in 0..<4 {
            XCTAssertEqual(storedList[0].mData!.assumingMemoryBound(to: Double.self)[frame], Double(frame) + 0.5)
            XCTAssertEqual(storedList[1].mData!.assumingMemoryBound(to: Double.self)[frame], Double(frame) + 20)
        }
    }

    func testPendingCopyOfAShortFrameLengthDoesNotKeepTheCallerBuffer() throws {
        let stream = unavailableStream()
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 4
        for frame in 0..<4 {
            buffer.floatChannelData?[0][frame] = Float(frame) + 0.5
            buffer.floatChannelData?[1][frame] = Float(frame) + 8
        }

        stream.append(buffer)
        for frame in 0..<4 {
            buffer.floatChannelData?[0][frame] = -1
            buffer.floatChannelData?[1][frame] = -2
        }

        let pending = stream.pendingPCMBuffersForTesting()
        XCTAssertEqual(pending.count, 1, "frameLength below frameCapacity must be copied, not dropped")
        let stored = try XCTUnwrap(pending.first)
        XCTAssertFalse(stored === buffer)
        XCTAssertEqual(stored.frameLength, 4)
        for frame in 0..<4 {
            XCTAssertEqual(stored.floatChannelData?[0][frame], Float(frame) + 0.5)
            XCTAssertEqual(stored.floatChannelData?[1][frame], Float(frame) + 8)
        }
    }

    private func unavailableStream() -> LiveSpeechStream {
        let runtime = AppleOnDeviceSpeechRuntime(
            isAvailable: { false },
            supportsOnDeviceRecognition: { true },
            startRecognition: { _, _ in
                AppleSpeechTaskHandle(cancel: {})
            }
        )
        return LiveSpeechStream(runtime: runtime, onSegment: { _ in }, onFailure: { _ in })
    }
}

final class DurableVoiceCaptureAdversarialTests: XCTestCase {
    func testTapClosureHasNoTaskAndDrainStartsOnlyAfterEngineStart() throws {
        let source = try SourceTree.text("Sources/ExpanderEngine/Voice/Audio/DurableVoiceCapture.swift")
        let marker = "installTap(onBus:"
        let start = try XCTUnwrap(source.range(of: marker))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "\n        }"))
        let closure = String(tail[..<end.upperBound])
        XCTAssertFalse(closure.contains("Task"))
        XCTAssertFalse(closure.contains("async"))
        XCTAssertTrue(closure.contains(".enqueue("))

        let engineStart = try XCTUnwrap(source.range(of: "try engine.start()"))
        let drainStart = try XCTUnwrap(source.range(of: "captureDrain.start()"))
        XCTAssertLessThan(engineStart.lowerBound, drainStart.lowerBound)
        let between = source[engineStart.upperBound..<drainStart.lowerBound]
        XCTAssertTrue(between.contains("writer.finalize()"))
        XCTAssertEqual(between.components(separatedBy: ".finalize()").count - 1, 1)
        XCTAssertFalse(between.contains("captureDrain.start()"))
        XCTAssertTrue(source.contains("private static let drainJoinTimeout: TimeInterval = 2"))
        XCTAssertTrue(source.contains("stopAndJoin(timeout: Self.drainJoinTimeout)"))
    }

    func testCancelJoinIsBoundedAndFinalizesTheWriterOnce() throws {
        let directory = try makeDirectory(named: "drain-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try CAFSessionWriter(
            outputURL: directory.appendingPathComponent("capture.caf"),
            sampleRate: 16_000,
            channelCount: 1
        )
        let pool = AudioBufferPool(capacity: 8, maxChunkFrames: 128, bytesPerFrame: 4)
        let sourceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let converter = try XCTUnwrap(AVAudioConverter(from: sourceFormat, to: writer.targetFormat))
        let drain = PCMCaptureDrain(
            pool: pool,
            writer: writer,
            converter: converter,
            targetFormat: writer.targetFormat,
            onPCMBuffer: nil,
            onLevel: nil
        )
        for index in 0..<4 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 32))
            buffer.frameLength = 32
            buffer.floatChannelData?[0][0] = Float(index + 1)
            XCTAssertTrue(pool.enqueue(buffer: buffer, sampleTime: Double(index)))
        }
        drain.start()
        let group = DispatchGroup()
        for index in 0..<40 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 32) else {
                    return
                }
                buffer.frameLength = 32
                buffer.floatChannelData?[0][0] = Float(index + 1)
                _ = pool.enqueue(buffer: buffer, sampleTime: Double(index))
            }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let outcome = drain.stopAndJoin(timeout: 2)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertNil(outcome.joinFailure, outcome.joinFailure?.redactedDetail ?? "")
        XCTAssertNil(outcome.captureError, outcome.captureError?.redactedDetail ?? "")
        XCTAssertGreaterThan(outcome.acceptedFrames, 0)
        XCTAssertLessThan(elapsed, 1.5)
        let secondStarted = DispatchTime.now().uptimeNanoseconds
        let second = drain.stopAndJoin(timeout: 2)
        let secondElapsed = Double(DispatchTime.now().uptimeNanoseconds - secondStarted) / 1_000_000_000
        XCTAssertNil(second.joinFailure)
        XCTAssertLessThan(secondElapsed, 0.5)
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let stats = try writer.finalize()
        XCTAssertGreaterThan(stats.byteCount, 0)
        XCTAssertThrowsError(try writer.finalize())
    }

    func testMismatchedWriteDoesNotPublishACleanRecording() throws {
        let directory = try makeDirectory(named: "partial-write")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try CAFSessionWriter(
            outputURL: directory.appendingPathComponent("capture.caf"),
            sampleRate: 16_000,
            channelCount: 1
        )
        let good = try Self.int16Buffer(format: writer.targetFormat, frames: 8, seed: 1)
        try writer.write(buffer: good)
        let floatFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let bad = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: 8))
        bad.frameLength = 8
        bad.floatChannelData?[0][0] = 0.5
        XCTAssertThrowsError(try writer.write(buffer: bad))

        let pool = AudioBufferPool(capacity: 4, maxChunkFrames: 32, bytesPerFrame: 8)
        XCTAssertTrue(pool.enqueue(buffer: bad, sampleTime: 0))
        bad.floatChannelData?[0][0] = -1
        let drain = PCMCaptureDrain(
            pool: pool,
            writer: writer,
            converter: nil,
            targetFormat: nil,
            onPCMBuffer: nil,
            onLevel: nil
        )
        drain.start()
        let outcome = drain.stopAndJoin(timeout: 2)
        XCTAssertNotNil(outcome.captureError, "a failed CAF write must not look like a clean drain")
        XCTAssertEqual(outcome.acceptedFrames, 0, "frames from the thrown write must not be accepted")
        XCTAssertNil(outcome.joinFailure)

        do {
            let stats = try writer.finalize()
            XCTAssertEqual(stats.totalFrames, 8)
            XCTAssertNotEqual(stats.totalFrames, 16)
            let file = try AVAudioFile(forReading: writer.outputURL)
            XCTAssertEqual(file.length, 8)
        } catch {
            XCTFail("sealing the prefix must not pretend the failed chunk was written: \(error)")
        }
        XCTAssertThrowsError(try writer.finalize())
    }

    func testUnicodeAndOddCAFPathsRoundTripOrFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-adv-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("音声 マイク .. café")
        defer { try? FileManager.default.removeItem(at: root) }
        let newlineURL = directory.appendingPathComponent("line\nbreak.caf")
        do {
            let oddWriter = try CAFSessionWriter(outputURL: newlineURL, sampleRate: 16_000, channelCount: 1)
            let oddBuffer = try Self.int16Buffer(format: oddWriter.targetFormat, frames: 4, seed: 2)
            try oddWriter.write(buffer: oddBuffer)
            let oddStats = try oddWriter.finalize()
            XCTAssertEqual(oddStats.totalFrames, 4)
            XCTAssertTrue(FileManager.default.fileExists(atPath: newlineURL.path))
            XCTAssertThrowsError(try oddWriter.finalize())
        } catch {
            _ = error
        }
        let url = directory.appendingPathComponent("キャプチャ 🎤 café.caf")
        let writer = try CAFSessionWriter(outputURL: url, sampleRate: 16_000, channelCount: 1)
        let buffer = try Self.int16Buffer(format: writer.targetFormat, frames: 8, seed: 3)
        try writer.write(buffer: buffer)
        let stats = try writer.finalize()
        XCTAssertEqual(stats.totalFrames, 8)
        XCTAssertGreaterThan(stats.byteCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)
        var samples = [Int16](repeating: 0, count: 8)
        let channels = try XCTUnwrap(buffer.int16ChannelData)
        for index in 0..<8 {
            samples[index] = channels[0][index]
        }
        samples.withUnsafeBytes { raw in
            _ = CC_SHA256_Update(&context, raw.baseAddress, CC_LONG(raw.count))
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(stats.sha256Hex, hex, "finalized hash must match the int16 samples actually written")
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 8)
        XCTAssertThrowsError(try writer.finalize())
    }

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-adv-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func int16Buffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        seed: Int
    ) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.int16ChannelData)
        let stride = buffer.stride
        for frame in 0..<Int(frames) {
            channels[0][frame * stride] = Int16(seed * 100 + frame)
        }
        return buffer
    }
}

private final class WaitResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func store(_ value: Bool) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func add(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
