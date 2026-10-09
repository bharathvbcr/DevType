import Foundation

/// The Preferences window's source: `PreferencesWindowController.swift` plus every tab controller
/// under `Sources/DevTypeAppCore/Preferences/`, concatenated in path order.
///
/// Source-contract tests read this rather than one file, so a contract holds wherever the tab that
/// owns the code lives, and a "must not contain" check still covers the whole Preferences surface.
/// `DevTypeAppTests` carries the same fixture; test targets cannot share a source file.
enum PreferencesSource {
    static func read() throws -> String {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DevTypeAppCore")
        let directory = core.appendingPathComponent("Preferences")
        let tabs = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        // An empty directory would make every "must not contain" contract pass vacuously.
        guard !tabs.isEmpty else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: directory.path])
        }
        let files = [core.appendingPathComponent("PreferencesWindowController.swift")] + tabs
        return try files
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }
}
