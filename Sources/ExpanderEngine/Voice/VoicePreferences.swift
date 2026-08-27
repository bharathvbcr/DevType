import Foundation

/// Persistence for Voice Dictation preferences (`devtype.voice.*`).
public enum VoicePreferences {
    public static let selectedModelKey = "devtype.voice.selectedModel"
    public static let toneKey = "devtype.voice.tone"
    public static let autoPunctuateKey = "devtype.voice.autoPunctuate"
    public static let removeDisfluenciesKey = "devtype.voice.removeDisfluencies"
    public static let handsFreeKey = "devtype.voice.handsFree"
    public static let soundFeedbackKey = "devtype.voice.soundFeedback"
    public static let realTimeTypingKey = "devtype.voice.realTimeTyping"
    public static let customDictionaryKey = "devtype.voice.customDictionary"
    public static let pushToTalkShortcutKey = "devtype.voice.hotkey"

    // MARK: - Selected Model

    public static var selectedModel: VoiceModelType {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedModelKey),
                  let model = VoiceModelType(rawValue: raw) else {
                return .voxtralMini4B
            }
            return model
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: selectedModelKey)
        }
    }

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

    public static var isHandsFreeModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: handsFreeKey) }
        set { UserDefaults.standard.set(newValue, forKey: handsFreeKey) }
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

    public static var isRealTimeTypingEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: realTimeTypingKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: realTimeTypingKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: realTimeTypingKey)
        }
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
        "voxtral": "Voxtral",
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

    public static let customVoiceTriggersKey = "devtype.voice.customTriggers"

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
        UserDefaults.standard.removeObject(forKey: selectedModelKey)
        UserDefaults.standard.removeObject(forKey: toneKey)
        UserDefaults.standard.removeObject(forKey: autoPunctuateKey)
        UserDefaults.standard.removeObject(forKey: removeDisfluenciesKey)
        UserDefaults.standard.removeObject(forKey: soundFeedbackKey)
        UserDefaults.standard.removeObject(forKey: realTimeTypingKey)
        UserDefaults.standard.removeObject(forKey: handsFreeKey)
        UserDefaults.standard.removeObject(forKey: customDictionaryKey)
        UserDefaults.standard.removeObject(forKey: customVoiceTriggersKey)
    }
}
