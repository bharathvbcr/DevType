import Foundation

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
/// The engine the user selects for dictation. Each case maps to a provider in
/// `SpeechProviderRegistry` and a corrector in `CorrectionProviderRegistry` through
/// `VoiceSessionSnapshotFactory`.
public enum TranscriptionEngine: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Google Gemini 3.5 Transcribe — cloud-based, high accuracy, handles disfluency
    /// removal, self-correction collapse, punctuation, and formatting natively.
    case gemini = "gemini"
    /// Apple SFSpeechRecognizer with Local LLM (Apple Intelligence or Ollama/LM Studio) post-processing.
    /// 100% private, on-device, zero API key required.
    case localLLM = "local_llm"
    /// Apple SFSpeechRecognizer with deterministic rule-based cleanup. On-device, free.
    case appleSpeech = "apple_speech"
    /// A local `whisper.cpp` server on loopback. Higher accuracy than Apple Speech, fully
    /// offline, but requires the user to run the server themselves.
    case whisperLocal = "whisper_local"

    public var id: String { rawValue }

    /// Human-readable name for UI display.
    public var displayName: String {
        switch self {
        case .gemini: return "Gemini 3.5 Transcribe"
        case .localLLM: return "Local AI (On-Device)"
        case .appleSpeech: return "Apple Speech (Rule-based)"
        case .whisperLocal: return "Local Whisper (whisper.cpp)"
        }
    }

    /// Whether this engine requires a Gemini API key to function.
    public var requiresAPIKey: Bool {
        switch self {
        case .gemini: return true
        case .localLLM, .appleSpeech, .whisperLocal: return false
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
