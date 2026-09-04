import Foundation

/// Persistence for Voice Dictation preferences (`devtype.voice.*`).
public enum VoicePreferences {
    public static let toneKey = "devtype.voice.tone"
    public static let autoPunctuateKey = "devtype.voice.autoPunctuate"
    public static let removeDisfluenciesKey = "devtype.voice.removeDisfluencies"
    public static let soundFeedbackKey = "devtype.voice.soundFeedback"
    public static let realTimeTypingKey = "devtype.voice.realTimeTyping"
    public static let liveDeliveryModeKey = "devtype.voice.liveDeliveryMode"
    public static let customDictionaryKey = "devtype.voice.customDictionary"
    public static let pushToTalkShortcutKey = "devtype.voice.hotkey"
    public static let transcriptionEngineKey = "devtype.voice.transcriptionEngine"
    public static let verbatimModeKey = "devtype.voice.verbatimMode"
    public static let perAppToneOverridesKey = "devtype.voice.perAppToneOverrides"
    public static let localLLMEndpointKey = "devtype.voice.localLLMEndpoint"
    public static let localLLMModelKey = "devtype.voice.localLLMModel"
    public static let localLLMTimeoutKey = "devtype.voice.localLLMTimeout"
    public static let whisperEndpointKey = "devtype.voice.whisperEndpoint"
    public static let voiceTracingKey = "devtype.voice.tracing"
    public static let cloudAudioConsentKey = "devtype.voice.cloudAudioConsent"

    // MARK: - Tone

    public static var tone: DictationTone {
        get {
            guard let raw = UserDefaults.standard.string(forKey: toneKey),
                  let tone = DictationTone(rawValue: raw) else {
                return .natural
            }
            return tone
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: toneKey)
        }
    }

    // MARK: - Formatting Options

    public static var isAutoPunctuateEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoPunctuateKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: autoPunctuateKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoPunctuateKey)
        }
    }

    public static var isRemoveDisfluenciesEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: removeDisfluenciesKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: removeDisfluenciesKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: removeDisfluenciesKey)
        }
    }

    public static var isSoundFeedbackEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: soundFeedbackKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: soundFeedbackKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: soundFeedbackKey)
        }
    }

    /// What dictation does with recognized speech *while the user is still speaking*.
    ///
    /// Recognizing and typing are separate decisions, and conflating them cost the middle
    /// option. Live recognition is what fills the HUD; live typing is what mutates the
    /// user's document. Wanting the first without the second is the common case — you can
    /// see that it heard you, and your document changes exactly once, at the end, with the
    /// proofread text.
    public enum LiveDeliveryMode: String, CaseIterable, Sendable {
        /// Words are typed into the document as they are recognized, then reconciled against
        /// the corrected transcript at the end. Immediate, but the document is rewritten
        /// under the caret mid-sentence.
        case typeAsYouSpeak

        /// Words appear only in the dictation HUD. The document receives the finished,
        /// proofread transcript in a single insertion when the session ends.
        case previewInHUD

        /// No live recognition at all. The HUD shows only that it is listening, and the
        /// document receives the finished transcript in one insertion.
        case insertAtEnd

        /// Whether this mode needs the live recognizer running during capture.
        ///
        /// `insertAtEnd` is the only one that does not, and that has a real cost: no preview,
        /// and the separate Speech Recognition grant is not needed for the preview's sake.
        public var usesLiveRecognition: Bool { self != .insertAtEnd }

        /// Whether this mode writes into the user's document during capture.
        public var typesWhileSpeaking: Bool { self == .typeAsYouSpeak }

        public var localizationKey: String {
            switch self {
            case .typeAsYouSpeak: return "prefs.voice.liveDelivery.typeAsYouSpeak"
            case .previewInHUD: return "prefs.voice.liveDelivery.previewInHUD"
            case .insertAtEnd: return "prefs.voice.liveDelivery.insertAtEnd"
            }
        }
    }

    public static var liveDeliveryMode: LiveDeliveryMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: liveDeliveryModeKey),
               let mode = LiveDeliveryMode(rawValue: raw) {
                return mode
            }
            // Migration from the original boolean. An existing "off" meant no live
            // recognition at all, so it maps to `insertAtEnd` — the setting keeps doing
            // exactly what it did before rather than silently gaining a preview.
            if UserDefaults.standard.object(forKey: realTimeTypingKey) != nil {
                return UserDefaults.standard.bool(forKey: realTimeTypingKey)
                    ? .typeAsYouSpeak
                    : .insertAtEnd
            }
            return .typeAsYouSpeak
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: liveDeliveryModeKey)
            // Kept in step so a downgrade, or any reader still on the boolean, sees a value
            // that agrees with the mode rather than a stale one.
            UserDefaults.standard.set(newValue.typesWhileSpeaking, forKey: realTimeTypingKey)
        }
    }

    /// Whether dictation types into the document while the user speaks.
    ///
    /// Thin accessor over `liveDeliveryMode`, which is the canonical setting.
    public static var isRealTimeTypingEnabled: Bool {
        get { liveDeliveryMode.typesWhileSpeaking }
        set { liveDeliveryMode = newValue ? .typeAsYouSpeak : .insertAtEnd }
    }

    // MARK: - Custom Dictionary

    public static var customDictionary: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: customDictionaryKey),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return defaultDictionary
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: customDictionaryKey)
            }
        }
    }

    public static let defaultDictionary: [String: String] = [
        "dev type": "DevType",
        "fun asr": "Fun-ASR",
        "k8s": "Kubernetes",
        "swift pm": "SwiftPM",
        "gemini": "Gemini"
    ]

    public static func addDictionaryEntry(spoken: String, replacement: String) {
        let cleanSpoken = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSpoken.isEmpty, !cleanReplacement.isEmpty else { return }

        var dict = customDictionary
        dict[cleanSpoken] = cleanReplacement
        customDictionary = dict
    }

    public static func removeDictionaryEntry(spoken: String) {
        var dict = customDictionary
        dict.removeValue(forKey: spoken)
        customDictionary = dict
    }

    // MARK: - Transcription Engine

    /// The explicitly selected transcription engine. Fresh installs default to the local Apple
    /// recognizer; choosing Gemini never silently changes providers when credentials are missing.
    public static var transcriptionEngine: TranscriptionEngine {
        get {
            guard let raw = UserDefaults.standard.string(forKey: transcriptionEngineKey),
                  let engine = TranscriptionEngine(rawValue: raw) else {
                return .appleSpeech
            }
            return engine
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: transcriptionEngineKey)
        }
    }

    /// The effective engine preserves the user's explicit provider choice. Provider-specific
    /// prerequisites are enforced by the typed preflight and again at the provider boundary.
    public static var effectiveEngine: TranscriptionEngine {
        effectiveEngine(preferred: transcriptionEngine, keyState: GeminiAPIKeyStore.readState())
    }

    /// Compatibility seam for callers that already obtained credential state. Credential state
    /// affects readiness, not provider identity; a missing key is not consent to invoke Apple.
    public static func effectiveEngine(
        preferred: TranscriptionEngine,
        keyState: GeminiAPIKeyStore.ReadState
    ) -> TranscriptionEngine {
        _ = keyState
        return preferred
    }

    /// Explicit acknowledgement required before a cloud recognizer uploads recorded audio.
    /// Selecting an engine or saving an API key is not consent by itself.
    public static var hasCloudAudioConsent: Bool {
        get { UserDefaults.standard.bool(forKey: cloudAudioConsentKey) }
        set { UserDefaults.standard.set(newValue, forKey: cloudAudioConsentKey) }
    }

    // MARK: - Verbatim Mode

    /// When enabled, bypasses all model cleanup — raw transcript only.
    public static var isVerbatimModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: verbatimModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: verbatimModeKey) }
    }

    // MARK: - Per-App Tone Overrides

    /// User-customizable bundle-id → ToneCategory overrides.
    /// Augments `ToneCategory.category(forBundleID:)` with user preferences.
    public static var perAppToneOverrides: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: perAppToneOverridesKey),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: perAppToneOverridesKey)
            }
        }
    }

    /// Resolves the effective tone category for a given app, checking user overrides first.
    public static func effectiveToneCategory(forBundleID bundleID: String?) -> ToneCategory {
        if let bundleID,
           let overrideRaw = perAppToneOverrides[bundleID],
           let override = ToneCategory(rawValue: overrideRaw) {
            return override
        }
        return ToneCategory.category(forBundleID: bundleID)
    }

    // MARK: - Local LLM Configuration

    /// The local OpenAI-compatible or Ollama endpoint URL (e.g. `http://localhost:11434/v1/chat/completions` or `http://localhost:1234/v1/chat/completions`).
    /// Whether the trace defaults on when the user has never chosen.
    ///
    /// This records what the user dictates, so release builds must keep it off unless the
    /// user explicitly enables it in Voice preferences. `Scripts/release-preflight.sh`
    /// independently enforces this privacy boundary.
    public static let voiceTracingDefaultsOn = false

    /// Records the live dictation path — including the dictated text — to a local file.
    /// See `VoiceDiagnosticsRecorder`.
    public static var isVoiceTracingEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: voiceTracingKey) != nil else {
                return voiceTracingDefaultsOn
            }
            return UserDefaults.standard.bool(forKey: voiceTracingKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: voiceTracingKey) }
    }

    public static let defaultWhisperEndpoint = URL(string: "http://127.0.0.1:8080/inference")!
    public static let defaultLocalLLMEndpoint = URL(string: "http://localhost:11434/v1/chat/completions")!

    /// Endpoint of a local `whisper.cpp` server. Both persisted values and writes are constrained
    /// here, then checked again by the transport. A stale or externally-written remote default is
    /// removed and heals to the loopback default before any provider can observe it.
    public static var whisperEndpoint: URL {
        get {
            validatedStoredEndpoint(forKey: whisperEndpointKey, fallback: defaultWhisperEndpoint)
        }
        set {
            _ = setWhisperEndpoint(newValue)
        }
    }

    @discardableResult
    public static func setWhisperEndpoint(_ endpoint: URL) -> Bool {
        setLocalEndpoint(endpoint, forKey: whisperEndpointKey)
    }

    public static var localLLMEndpoint: URL {
        get {
            validatedStoredEndpoint(forKey: localLLMEndpointKey, fallback: defaultLocalLLMEndpoint)
        }
        set {
            _ = setLocalLLMEndpoint(newValue)
        }
    }

    @discardableResult
    public static func setLocalLLMEndpoint(_ endpoint: URL) -> Bool {
        setLocalEndpoint(endpoint, forKey: localLLMEndpointKey)
    }

    private static func setLocalEndpoint(_ endpoint: URL, forKey key: String) -> Bool {
        guard LocalEndpointSecurity.isValid(endpoint) else { return false }
        UserDefaults.standard.set(endpoint.absoluteString, forKey: key)
        return true
    }

    private static func validatedStoredEndpoint(forKey key: String, fallback: URL) -> URL {
        guard let string = UserDefaults.standard.string(forKey: key) else { return fallback }
        guard let endpoint = URL(string: string), LocalEndpointSecurity.isValid(endpoint) else {
            UserDefaults.standard.removeObject(forKey: key)
            return fallback
        }
        return endpoint
    }

    /// The model name identifier to pass to the local LLM server (e.g. `llama3.2`, `qwen2.5`, `mistral`).
    public static var localLLMModel: String {
        get {
            UserDefaults.standard.string(forKey: localLLMModelKey) ?? "llama3.2"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: localLLMModelKey)
        }
    }

    /// Watchdog timeout in seconds for local LLM cleanup before falling back to raw transcript.
    /// Keeps user dictation fast and responsive (default: 3.0s).
    public static var localLLMTimeout: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: localLLMTimeoutKey)
            return val > 0 ? val : 3.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: localLLMTimeoutKey)
        }
    }

    public static let customVoiceTriggersKey = "devtype.voice.customTriggers"
    public static let voiceWakeWordsKey = "devtype.voice.wakeWords"
    public static let proofreadBeforeInsertKey = "devtype.voice.proofreadBeforeInsert"

    /// Runs an Apple Intelligence proofread pass over every dictation before it is inserted.
    ///
    /// Off by default: it adds a round trip before the text lands, and the deterministic
    /// cleanup is already enough for most dictation. Worth turning on when what you dictate
    /// goes somewhere it will be read — email, documentation, a pull request.
    ///
    /// It replaces the correction stage rather than adding a second pass, so it inherits the
    /// protected spans, the validator and the fallback-to-raw that stage already has.
    public static var isProofreadBeforeInsertEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: proofreadBeforeInsertKey) }
        set { UserDefaults.standard.set(newValue, forKey: proofreadBeforeInsertKey) }
    }

    /// Words that mark an utterance as a command rather than dictation: "dev rewrite this".
    ///
    /// A wake word is optional — "rewrite this" still works — but speaking one makes the
    /// intent unambiguous, which matters when the thing being dictated could itself read as
    /// a command.
    public static var voiceCommandWakeWords: [String] {
        get {
            guard let stored = UserDefaults.standard.stringArray(forKey: voiceWakeWordsKey),
                  !stored.isEmpty else {
                return ["dev", "ai"]
            }
            return stored
        }
        set { UserDefaults.standard.set(newValue, forKey: voiceWakeWordsKey) }
    }

    // MARK: - Custom Voice AI Triggers

    public static var customVoiceTriggers: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: customVoiceTriggersKey),
                  let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
                return defaultVoiceTriggers
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: customVoiceTriggersKey)
            }
        }
    }

    public static let defaultVoiceTriggers: [String: String] = [
        "rephrase": "paraphrase",
        "rewrite": "rewrite",
        "expand": "expand",
        "condense": "condense",
        "merge": "mergerewrite",
        "merge notes": "mergerewrite",
        "prompt enhance": "promptenhance",
        "enhance prompt": "promptenhance",
        "proofread": "proofread",
        "fix grammar": "proofread",
        "explain code": "explaincode",
        "docstring": "docstring",
        "document code": "docstring",
        "fix bug": "fixcode",
        "fix code": "fixcode",
        "to json": "tojson",
        "unit tests": "unittests",
        "git commit": "gitcommit",
        "explain regex": "explainregex",
        "sql query": "sqlquery"
    ]

    public static func addVoiceTrigger(phrase: String, action: String) {
        let cleanPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanAction = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanPhrase.isEmpty, !cleanAction.isEmpty else { return }

        var triggers = customVoiceTriggers
        triggers[cleanPhrase] = cleanAction
        customVoiceTriggers = triggers
    }

    public static func removeVoiceTrigger(phrase: String) {
        let cleanPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var triggers = customVoiceTriggers
        triggers.removeValue(forKey: cleanPhrase)
        customVoiceTriggers = triggers
    }

    public static func resetAllForTesting() {
        UserDefaults.standard.removeObject(forKey: toneKey)
        UserDefaults.standard.removeObject(forKey: autoPunctuateKey)
        UserDefaults.standard.removeObject(forKey: removeDisfluenciesKey)
        UserDefaults.standard.removeObject(forKey: soundFeedbackKey)
        UserDefaults.standard.removeObject(forKey: realTimeTypingKey)
        UserDefaults.standard.removeObject(forKey: liveDeliveryModeKey)
        UserDefaults.standard.removeObject(forKey: customDictionaryKey)
        UserDefaults.standard.removeObject(forKey: customVoiceTriggersKey)
        UserDefaults.standard.removeObject(forKey: voiceWakeWordsKey)
        UserDefaults.standard.removeObject(forKey: proofreadBeforeInsertKey)
        UserDefaults.standard.removeObject(forKey: transcriptionEngineKey)
        UserDefaults.standard.removeObject(forKey: verbatimModeKey)
        UserDefaults.standard.removeObject(forKey: perAppToneOverridesKey)
        UserDefaults.standard.removeObject(forKey: localLLMEndpointKey)
        UserDefaults.standard.removeObject(forKey: localLLMModelKey)
        UserDefaults.standard.removeObject(forKey: localLLMTimeoutKey)
        UserDefaults.standard.removeObject(forKey: whisperEndpointKey)
        UserDefaults.standard.removeObject(forKey: voiceTracingKey)
        UserDefaults.standard.removeObject(forKey: cloudAudioConsentKey)
    }
}
