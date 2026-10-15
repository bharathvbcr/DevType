import AppKit
import XCTest
@testable import ExpanderEngine

/// Shared fixtures for clone groups that used to be copied into individual test files.
/// Assertions stay in those files; this only holds the setup they already shared.

enum TestPNG {
    static func makePNGData() throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        return data
    }
}

/// SplitMix64 whose seed is the first state, with no warmup step.
/// `SplitMix64` in DeterministicRandom.swift adds the increment once in `init`; these
/// fixtures were written against the unwarmed generator and must not share that sequence.
/// `int` treats a non-positive bound as 1, matching the secret-stress generators.
/// `index` traps on an empty collection, matching the selection-cache generator.
struct RawSplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }

    mutating func index(_ count: Int) -> Int {
        precondition(count > 0)
        return Int(next() % UInt64(count))
    }

    mutating func bool() -> Bool { next() & 1 == 0 }

    mutating func pick<T>(_ values: [T]) -> T { values[index(values.count)] }
}

final class CountingBackspacePoster: BackspacePosting {
    var counts: [Int] = []
    func sendBackspaces(count: Int) -> Int { counts.append(count); return count }
    func sendBackspacesAsync(count: Int, completion: @escaping (Bool) -> Void) {
        counts.append(count)
        completion(true)
    }
}

final class WriteOnlyMasterTier: SecretBackingStore {
    let inner = InMemorySecretBackingStore()
    func set(_ value: String, account: String) -> OSStatus {
        inner.set(value, account: account)
    }
    func value(account: String) -> String? {
        account == ConsolidatedSecretBackingStore.masterKeyAccount
            ? nil
            : inner.value(account: account)
    }
    func contains(account: String) -> Bool { inner.contains(account: account) }
    func delete(account: String) -> OSStatus { inner.delete(account: account) }
    func accounts() -> Set<String> { inner.accounts() }
}

func prefixTriggerSnippet(
    _ trigger: String,
    caseSensitive: Bool = false,
    requireWordBoundary: Bool = true,
    enabled: Bool = true
) -> SnippetModel {
    var snippet = SnippetModel(
        title: trigger,
        triggerKeyword: trigger,
        replacementText: "x",
        isCaseSensitive: caseSensitive,
        requireWordBoundary: requireWordBoundary
    )
    snippet.enabled = enabled
    return snippet
}

func scopedSnippet(
    title: String,
    trigger: String,
    replacement: String,
    include: [String] = [],
    exclude: [String] = []
) -> SnippetModel {
    var snippet = SnippetModel(title: title, triggerKeyword: trigger, replacementText: replacement)
    snippet.includeApps = include
    snippet.excludeApps = exclude
    return snippet
}

struct TaggerPreferenceGuard {
    var savedMaster: Any?
    var savedOwn: Any?

    mutating func enableBoth() {
        savedMaster = UserDefaults.standard.object(forKey: AIPreferences.enabledKey)
        savedOwn = UserDefaults.standard.object(forKey: SnippetTagSuggester.enabledKey)
        UserDefaults.standard.set(true, forKey: AIPreferences.enabledKey)
        UserDefaults.standard.set(true, forKey: SnippetTagSuggester.enabledKey)
    }

    func restore() {
        UserDefaults.standard.set(savedMaster, forKey: AIPreferences.enabledKey)
        UserDefaults.standard.set(savedOwn, forKey: SnippetTagSuggester.enabledKey)
    }
}

enum LanguageDefaultsFixture {
    static func current() -> Any? {
        UserDefaults.standard.object(forKey: LocalizationManager.deviceKey)
    }

    static func restore(_ previous: Any?) {
        if let previous {
            UserDefaults.standard.set(previous, forKey: LocalizationManager.deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
        }
    }
}

enum VoiceDiagnosticsFixture {
    static func makeRecorder(in directory: URL) -> VoiceDiagnosticsRecorder {
        VoiceDiagnosticsRecorder(
            traceURL: directory.appendingPathComponent("voice-trace.jsonl"),
            terminalManifestURL: directory.appendingPathComponent("voice-terminal-manifest.json")
        )
    }

    static func posixPermissions(at url: URL) throws -> Int {
        let value = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        return value.intValue & 0o777
    }
}
