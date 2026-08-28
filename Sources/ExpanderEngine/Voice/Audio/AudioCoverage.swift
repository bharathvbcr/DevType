import Foundation

public struct AudioCoverage: Codable, Sendable, Equatable {
    public var acceptedFrames: Int64
    public var writtenFrames: Int64
    public var providerConsumedFrames: Int64
    public var droppedFrames: Int64
    public var firstSequenceNumber: UInt64
    public var lastSequenceNumber: UInt64
    public var detectedGaps: Int
    public var sampleRate: Double
    public var channelCount: Int
    public var bytesPerFrame: Int
    public var isComplete: Bool

    public init(
        acceptedFrames: Int64 = 0,
        writtenFrames: Int64 = 0,
        providerConsumedFrames: Int64 = 0,
        droppedFrames: Int64 = 0,
        firstSequenceNumber: UInt64 = 0,
        lastSequenceNumber: UInt64 = 0,
        detectedGaps: Int = 0,
        sampleRate: Double = 16000,
        channelCount: Int = 1,
        bytesPerFrame: Int = 2,
        isComplete: Bool = true
    ) {
        self.acceptedFrames = acceptedFrames
        self.writtenFrames = writtenFrames
        self.providerConsumedFrames = providerConsumedFrames
        self.droppedFrames = droppedFrames
        self.firstSequenceNumber = firstSequenceNumber
        self.lastSequenceNumber = lastSequenceNumber
        self.detectedGaps = detectedGaps
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bytesPerFrame = bytesPerFrame
        self.isComplete = isComplete
    }
}
