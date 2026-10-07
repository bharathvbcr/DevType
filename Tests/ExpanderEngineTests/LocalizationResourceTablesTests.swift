import XCTest
@testable import ExpanderEngine

/// The UI strings are `.strings` resource tables loaded at runtime, not Swift dictionaries.
///
/// `LocalizationParityTests` checks the tables against each other through `stringTable(for:)`;
/// this file checks the resource files themselves: that the shipped bundle is the source tree,
/// that every language carries the same tables, and that the loader reports bad data instead of
/// quietly dropping it. A Swift dictionary literal traps on a duplicate key, so the old tables
/// could not hold one; a `.strings` file silently keeps the last, so that invariant is enforced
/// here instead.
final class LocalizationResourceTablesTests: XCTestCase {

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/ExpanderEngine/Localization/Resources", isDirectory: true)

    private func sourceTables(_ language: AppLanguage) throws -> [URL] {
        let directory = Self.sourceRoot.appendingPathComponent("\(language.rawValue).lproj")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "strings" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testShippedTablesLoadWithoutDiagnostics() {
        XCTAssertEqual(LocalizationTables.shared.diagnostics, [])
        for language in AppLanguage.concreteCases {
            XCTAssertFalse(LocalizationManager.stringTable(for: language).isEmpty, language.rawValue)
        }
    }

    func testEveryLanguageCarriesTheSameTables() throws {
        let english = try sourceTables(.en).map(\.lastPathComponent)
        XCTAssertFalse(english.isEmpty)
        for language in AppLanguage.concreteCases {
            XCTAssertEqual(try sourceTables(language).map(\.lastPathComponent), english, language.rawValue)
            XCTAssertEqual(
                LocalizationTables.shared.tableNames[language].map { $0.map { $0 + ".strings" } },
                english,
                "\(language.rawValue): the built bundle does not carry the source tree's tables"
            )
        }
    }

    /// The bundle a test run loads is built from `Sources/…/Resources`; a stale or partial copy
    /// would let the parity tests pass against data that is not what the repository holds.
    func testLoadedTablesEqualTheSourceTreeFiles() throws {
        for language in AppLanguage.concreteCases {
            var merged: [String: String] = [:]
            for file in try sourceTables(language) {
                let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil)
                let entries = try XCTUnwrap(plist as? [String: String], file.lastPathComponent)
                merged.merge(entries) { first, _ in first }
            }
            XCTAssertEqual(merged, LocalizationManager.stringTable(for: language), language.rawValue)
        }
    }

    func testNoKeyIsDefinedTwiceInTheSourceFiles() throws {
        let keyLine = try NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*="#, options: .anchorsMatchLines)
        for language in AppLanguage.concreteCases {
            var origin: [String: String] = [:]
            var duplicates: [String] = []
            for file in try sourceTables(language) {
                let text = try String(contentsOf: file, encoding: .utf8)
                let range = NSRange(text.startIndex..., in: text)
                for match in keyLine.matches(in: text, range: range) {
                    let key = String(text[Range(match.range(at: 1), in: text)!])
                    if let first = origin[key] {
                        duplicates.append("\(key) (\(first), \(file.lastPathComponent))")
                    } else {
                        origin[key] = file.lastPathComponent
                    }
                }
            }
            XCTAssertEqual(duplicates, [], "\(language.rawValue) defines keys twice")
            XCTAssertEqual(origin.count, LocalizationManager.stringTable(for: language).count, language.rawValue)
        }
    }

    // MARK: - Loader reports bad data

    private func makeBundle(_ files: [String: String]) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalizationTables-\(UUID().uuidString).bundle", isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return (try XCTUnwrap(Bundle(url: root)), root)
    }

    func testLoaderMergesTablesPerLanguage() throws {
        let (bundle, root) = try makeBundle([
            "en.lproj/A.strings": #""a.one" = "One";"#,
            "en.lproj/B.strings": #""b.two" = "Two \"quoted\"\n";"#,
            "ko.lproj/A.strings": #""a.one" = "하나";"#,
            "ja.lproj/A.strings": #""a.one" = "一";"#
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let loaded = LocalizationTables.load(from: bundle)
        XCTAssertEqual(loaded.diagnostics, [])
        XCTAssertEqual(loaded.tables[.en], ["a.one": "One", "b.two": "Two \"quoted\"\n"])
        XCTAssertEqual(loaded.tables[.ko], ["a.one": "하나"])
        XCTAssertEqual(loaded.tableNames[.en], ["A", "B"])
    }

    func testLoaderReportsDuplicateMalformedAndMissingTables() throws {
        let (bundle, root) = try makeBundle([
            "en.lproj/A.strings": #""shared" = "first";"#,
            "en.lproj/B.strings": #""shared" = "second";"#,
            "ko.lproj/A.strings": #""broken" = "no terminator""#
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let loaded = LocalizationTables.load(from: bundle)
        XCTAssertEqual(loaded.tables[.en], ["shared": "first"], "the first table (by name) wins, deterministically")
        XCTAssertTrue(loaded.diagnostics.contains { $0.contains("\"shared\" is defined in both A and B") }, "\(loaded.diagnostics)")
        XCTAssertTrue(loaded.diagnostics.contains { $0.hasPrefix("ko/A.strings: malformed") }, "\(loaded.diagnostics)")
        XCTAssertTrue(loaded.diagnostics.contains("ja.lproj has no .strings tables"), "\(loaded.diagnostics)")
    }

    func testStringTableIsNeverPseudolocalized() {
        // Setting `language` persists to UserDefaults; leave no trace.
        let saved = UserDefaults.standard.string(forKey: LocalizationManager.deviceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: LocalizationManager.deviceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
            }
        }
        let manager = LocalizationManager(pseudolocalize: true)
        manager.language = .en
        XCTAssertEqual(LocalizationManager.stringTable(for: .en)["common.cancel"], "Cancel")
        XCTAssertNotEqual(manager.s("common.cancel"), "Cancel")
    }
}
