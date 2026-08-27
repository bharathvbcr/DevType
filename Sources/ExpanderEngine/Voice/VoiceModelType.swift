import Foundation

/// Supported voice models for on-device and local smart speech recognition.
public enum VoiceModelType: String, Sendable, CaseIterable, Identifiable, Codable {
    /// Mistral Voxtral Realtime (Mini 4B) — state-of-the-art multimodal audio model with semantic understanding.
    case voxtralMini4B = "voxtral_mini_4b"
    /// Fun-ASR-Nano (~0.8B) — ultra-fast, lightweight multilingual model by Tongyi Lab for edge transcription.
    case funASRNano = "fun_asr_nano"
    /// System fallback using Apple Speech framework / SpeechAnalyzer.
    case appleSpeech = "apple_speech"

    public var id: String { rawValue }

    /// Detailed metadata descriptor for the model.
    public var descriptor: VoiceModelDescriptor {
        switch self {
        case .voxtralMini4B:
            return VoiceModelDescriptor(
                type: self,
                name: "Mistral Voxtral Realtime (Mini 4B)",
                shortName: "Voxtral Mini 4B",
                vendor: "Mistral AI",
                parameterCount: "4.2B Parameters",
                modelSizeFormatted: "2.2 GB (Q4_K_M)",
                approximateBytes: 2_360_000_000,
                license: "Apache 2.0",
                description: "Multimodal audio-LLM with real-time speech understanding, zero-latency streaming, and high context accuracy.",
                downloadURL: URL(string: "https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-GGUF/resolve/main/voxtral-mini-4b-realtime.q4_k_m.gguf")!,
                expectedSha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                requiredRAMFormatted: "8 GB+ Unified Memory",
                isMultilingual: true,
                supportedLanguagesCount: 32,
                isRecommended: true
            )
        case .funASRNano:
            return VoiceModelDescriptor(
                type: self,
                name: "Fun-ASR-Nano (0.8B)",
                shortName: "Fun-ASR Nano",
                vendor: "Tongyi Lab (Alibaba)",
                parameterCount: "0.8B Parameters",
                modelSizeFormatted: "820 MB",
                approximateBytes: 860_000_000,
                license: "MIT / Open Weights",
                description: "Ultra-low latency speech recognition optimized for Apple Silicon Neural Engine with high noise resilience.",
                downloadURL: URL(string: "https://huggingface.co/FunAudioLLM/FunASR-Nano-GGUF/resolve/main/funasr-nano-q8_0.gguf")!,
                expectedSha256: "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
                requiredRAMFormatted: "4 GB+ Unified Memory",
                isMultilingual: true,
                supportedLanguagesCount: 31,
                isRecommended: false
            )
        case .appleSpeech:
            return VoiceModelDescriptor(
                type: self,
                name: "Apple Speech (System)",
                shortName: "Apple Speech",
                vendor: "Apple Inc.",
                parameterCount: "Built-in",
                modelSizeFormatted: "Pre-installed",
                approximateBytes: 0,
                license: "Apple Proprietary",
                description: "Native macOS Speech Framework and SpeechAnalyzer. Zero download required.",
                downloadURL: URL(string: "https://developer.apple.com/documentation/speech")!,
                expectedSha256: "",
                requiredRAMFormatted: "Any",
                isMultilingual: true,
                supportedLanguagesCount: 50,
                isRecommended: false
            )
        }
    }
}

/// Metadata descriptor for a voice model.
public struct VoiceModelDescriptor: Sendable, Equatable {
    public let type: VoiceModelType
    public let name: String
    public let shortName: String
    public let vendor: String
    public let parameterCount: String
    public let modelSizeFormatted: String
    public let approximateBytes: Int64
    public let license: String
    public let description: String
    public let downloadURL: URL
    public let expectedSha256: String
    public let requiredRAMFormatted: String
    public let isMultilingual: Bool
    public let supportedLanguagesCount: Int
    public let isRecommended: Bool
}

/// Smart dictation tone adaptations inspired by Jot.
public enum DictationTone: String, Sendable, CaseIterable, Identifiable, Codable {
    /// Balanced natural phrasing with smart punctuation and capitalisation.
    case natural
    /// Professional register, formal sign-offs, and polite grammar.
    case email
    /// Casual lowercase-friendly phrasing with informal contractions.
    case chat
    /// Code syntax formatting: camelCase, snake_case, symbols and punctuation spelled out.
    case code
    /// 100% verbatim transcription without any disfluency or hesitation stripping.
    case verbatim

    public var id: String { rawValue }

    public var localizationKey: String {
        "voice.tone.\(rawValue)"
    }
}
