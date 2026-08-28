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

// MARK: - Transcription Engine Selection

/// The transcription backend to use for voice dictation.
/// Replaces `VoiceModelType` as the primary engine selector — `VoiceModelType` is
/// retained for backward-compatible preferences migration but `.voxtralMini4B` and
/// `.funASRNano` are inert (GGUF inference was never wired up).
public enum TranscriptionEngine: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Google Gemini 3.5 Transcribe — cloud-based, high accuracy, handles disfluency
    /// removal, self-correction collapse, punctuation, and formatting natively.
    case gemini = "gemini"
    /// Apple SFSpeechRecognizer with Local LLM (Apple Intelligence or Ollama/LM Studio) post-processing.
    /// 100% private, on-device, zero API key required.
    case localLLM = "local_llm"
    /// Apple SFSpeechRecognizer — on-device/free, uses rule-based `SmartDictationEngine` post-processing.
    case appleSpeech = "apple_speech"

    public var id: String { rawValue }

    /// Human-readable name for UI display.
    public var displayName: String {
        switch self {
        case .gemini: return "Gemini 3.5 Transcribe"
        case .localLLM: return "Local AI (On-Device)"
        case .appleSpeech: return "Apple Speech (Rule-based)"
        }
    }

    /// Whether this engine requires a Gemini API key to function.
    public var requiresAPIKey: Bool {
        switch self {
        case .gemini: return true
        case .localLLM, .appleSpeech: return false
        }
    }
}

// MARK: - Per-App Tone Category (Jot PromptV1 Pattern)

/// Automatic tone category inferred from the frontmost app's bundle ID.
/// Sent as part of the Gemini steering prompt so the model formats transcription
/// output appropriately for the context (email vs. chat vs. code).
public enum ToneCategory: String, CaseIterable, Sendable {
    case email
    case workChat
    case personalChat
    case code
    case neutral

    /// The steering prompt fragment for this tone category.
    public var promptBlock: String {
        switch self {
        case .email:
            return "Tone: professional email. Complete sentences; keep greetings and sign-offs as spoken."
        case .workChat:
            return "Tone: casual-professional chat message. No trailing period on a single-sentence message."
        case .personalChat:
            return "Tone: informal message. Keep contractions and slang as spoken. No trailing period."
        case .code:
            return "Technical dictation. Preserve identifiers, file names, and casing conventions like camelCase or snake_case exactly as spoken."
        case .neutral:
            return ""
        }
    }

    /// Resolves a tone category from a macOS app bundle identifier.
    public static func category(forBundleID bundleID: String?) -> ToneCategory {
        guard let bundleID else { return .neutral }
        switch bundleID {
        case "com.apple.mail",
             "com.google.Gmail",
             "com.readdle.smartemail-Mac",
             "com.superhuman.electron",
             "com.microsoft.Outlook":
            return .email
        case "com.tinyspeck.slackmacgap",
             "com.microsoft.teams2",
             "com.hnc.Discord",
             "ru.keepcoder.Telegram",
             "net.whatsapp.WhatsApp",
             "com.facebook.archon":
            return .workChat
        case "com.apple.MobileSMS":
            return .personalChat
        case "com.apple.Terminal",
             "com.apple.dt.Xcode",
             "com.microsoft.VSCode",
             "com.googlecode.iterm2",
             "dev.warp.Warp-Stable",
             "com.jetbrains.intellij",
             "com.sublimetext.4":
            return .code
        default:
            return .neutral
        }
    }
}
