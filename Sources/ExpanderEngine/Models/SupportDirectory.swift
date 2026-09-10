import Foundation

/// Where DevType keeps its device-local files.
///
/// Seven places resolved this independently, in three shapes that had drifted apart:
/// `SnippetStore.defaultLocalSupportDirectory`, `AppMuteStore.init`,
/// `VoiceDiagnosticsRecorder.supportDirectory`, `AXWriteCapabilityStore.defaultFileURL`,
/// `InjectTiming.defaultFileURL`, `VoiceSessionStore.init` and `VoiceRecoveryService`
/// (twice, for the same subdirectory). Two of them fell back to
/// `URL(fileURLWithPath: NSTemporaryDirectory())` while the rest used
/// `FileManager.default.temporaryDirectory` — the same location today, and precisely the
/// kind of drift that makes a later change to one of them not a change to the others.
///
/// Nothing here creates directories: callers that need the directory to exist already
/// create it themselves, at the moment they are about to write.
public enum SupportDirectory {
    /// SwiftPM/Xcode tests exercise shared stores as well as isolated fixtures. Resolving
    /// production paths there lets synthetic failures and learned AX verdicts leak into the
    /// installed app. Detect the loaded test bundle, including release-mode test runs, and
    /// give every default store the same process-local scratch root.
    static var testDirectory: URL? = {
        guard Bundle.allBundles.contains(where: { $0.bundleURL.pathExtension == "xctest" }) else {
            return nil
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("DevType-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("DevType", isDirectory: true)
    }()

    /// `~/Library/Application Support/DevType`, or a temporary directory when the system
    /// cannot name an Application Support directory at all — which is a sandbox or
    /// migration edge case, not a normal one. Falling back keeps a diagnostic sidecar
    /// writable instead of failing the feature that wanted to record something.
    public static var devType: URL {
        if let testDirectory { return testDirectory }
        return (FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("DevType", isDirectory: true)
    }

    /// `~/Library/Application Support/DevType/VoiceSessions`: recovery artifacts for
    /// dictation sessions, written with `0o700` by the store that owns them.
    public static var voiceSessions: URL {
        devType.appendingPathComponent("VoiceSessions", isDirectory: true)
    }

    /// A file directly inside `devType`.
    public static func file(_ name: String) -> URL {
        devType.appendingPathComponent(name)
    }
}
