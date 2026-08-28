import Foundation
import AppKit

public final class VoiceInsertionService: Sendable {
    public static let shared = VoiceInsertionService()

    private init() {}

    /// Delivers final voice transcript into the target field using TextInjectionPipeline.
    @MainActor
    public func deliver(
        text: String,
        targetLease: TargetLease,
        sessionID: VoiceSessionID,
        generation: SessionGeneration
    ) async -> DeliveryReceipt {
        let startTime = Date()

        // 1. Target Lease verification: Check if frontmost application PID matches targetLease PID
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            if targetLease.processIdentifier != 0 && frontmost.processIdentifier != targetLease.processIdentifier {
                return DeliveryReceipt(
                    sessionID: sessionID,
                    generation: generation,
                    targetLease: targetLease,
                    deliveredTextLength: 0,
                    evidenceQuality: .targetMismatch,
                    deliveredAt: Date(),
                    latencyMs: Date().timeIntervalSince(startTime) * 1000
                )
            }
        }

        // 2. Perform injection via TextInjectionPipeline
        let pipeline = TextInjectionPipeline.shared
        let snippet = SnippetModel(
            title: "Voice Dictation",
            triggerKeyword: "",
            replacementText: text
        )

        pipeline.inject(
            snippet: snippet,
            triggerLength: 0,
            swallowed: .notSwallowed,
            eraseCountOverride: 0,
            preResolvedText: text,
            secureClipboardPaste: false
        )

        let latency = Date().timeIntervalSince(startTime) * 1000
        return DeliveryReceipt(
            sessionID: sessionID,
            generation: generation,
            targetLease: targetLease,
            deliveredTextLength: text.count,
            evidenceQuality: .settledUnverifiedPaste,
            deliveredAt: Date(),
            latencyMs: latency
        )
    }
}
