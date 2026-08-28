import Foundation

public protocol SpeechRecognizer: Sendable {
    var descriptor: SpeechProviderDescriptor { get }
    func probe() async -> ProviderReadiness
    func transcribe(_ request: SpeechRequest) -> AsyncThrowingStream<SpeechEvent, Error>
    func cancel(sessionID: VoiceSessionID) async
}
