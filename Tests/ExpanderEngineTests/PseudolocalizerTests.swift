import XCTest
@testable import ExpanderEngine

/// The pseudolocale mode exists for layout checks; it is only useful if it never changes what
/// `String(format:)` consumes. These tests use an independent specifier pattern rather than the
/// one inside `Pseudolocalizer`, so a bug there cannot hide itself.
final class PseudolocalizerTests: XCTestCase {

    private static let specifierPattern = try! NSRegularExpression(
        pattern: #"%(\d+\$)?[-+ 0#']*(\d+|\*)?(\.(\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA%]"#
    )

    private func specifiers(_ string: String) -> [String] {
        let range = NSRange(string.startIndex..., in: string)
        return Self.specifierPattern.matches(in: string, range: range).map {
            String(string[Range($0.range, in: string)!])
        }
    }

    private func strippingSpecifiers(_ string: String) -> String {
        let range = NSRange(string.startIndex..., in: string)
        return Self.specifierPattern.stringByReplacingMatches(in: string, range: range, withTemplate: "")
    }

    func testAccentsBracketsAndExpands() {
        let output = Pseudolocalizer.transform("Cancel")
        XCTAssertTrue(output.hasPrefix("["))
        XCTAssertTrue(output.hasSuffix("]"))
        XCTAssertTrue(output.contains("Çáñçéļ"), output)
        XCTAssertGreaterThanOrEqual(Double(output.count), Double("Cancel".count) * 1.3)
    }

    func testEmptyStringStaysEmpty() {
        XCTAssertEqual(Pseudolocalizer.transform(""), "")
    }

    func testFormatSpecifiersSurviveVerbatimAndInOrder() {
        let source = "%1$@ moved %2$lld items (%.1f%%) — %d left, %@ next"
        let output = Pseudolocalizer.transform(source)
        XCTAssertEqual(specifiers(output), ["%1$@", "%2$lld", "%.1f", "%%", "%d", "%@"])
    }

    func testPseudolocalizedFormatConsumesTheSameArguments() {
        let source = "Deleted %d snippets from %@"
        let output = Pseudolocalizer.transform(source)
        let rendered = String(format: output, 7, "Work")
        XCTAssertTrue(rendered.contains("7"), rendered)
        XCTAssertTrue(rendered.contains("Work"), rendered)
    }

    /// Every shipped English string keeps its exact specifier sequence and loses every plain
    /// ASCII letter, so the mode both preserves formatting and exposes hard-coded English.
    func testEveryShippedEnglishStringKeepsItsSpecifiers() {
        let english = LocalizationManager.stringTable(for: .en)
        XCTAssertFalse(english.isEmpty)
        var failures: [String] = []
        for (key, value) in english {
            let output = Pseudolocalizer.transform(value)
            if specifiers(output) != specifiers(value) {
                failures.append("\(key): specifiers changed")
            }
            if strippingSpecifiers(output).unicodeScalars.contains(where: { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) {
                failures.append("\(key): unaccented ASCII letters remain")
            }
        }
        XCTAssertEqual(failures.sorted(), [])
    }

    func testEnabledByEnvironmentOrDefaults() throws {
        let suite = "PseudolocalizerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(Pseudolocalizer.isEnabled(environment: [:], defaults: defaults))
        XCTAssertTrue(Pseudolocalizer.isEnabled(environment: ["DEVTYPE_PSEUDOLOCALE": "1"], defaults: defaults))
        XCTAssertFalse(Pseudolocalizer.isEnabled(environment: ["DEVTYPE_PSEUDOLOCALE": "0"], defaults: defaults))
        defaults.set(true, forKey: Pseudolocalizer.defaultsKey)
        XCTAssertTrue(Pseudolocalizer.isEnabled(environment: [:], defaults: defaults))
        XCTAssertFalse(
            Pseudolocalizer.isEnabled(environment: ["DEVTYPE_PSEUDOLOCALE": "no"], defaults: defaults),
            "an explicit environment value overrides the stored default for one launch"
        )
    }

    func testManagerAppliesThePseudolocaleToLookupsAndPlurals() {
        let saved = UserDefaults.standard.string(forKey: LocalizationManager.deviceKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: LocalizationManager.deviceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
            }
        }
        let english = LocalizationManager.stringTable(for: .en)
        let pluralKey = english.keys.filter { $0.hasSuffix(".one") }.sorted().first
        let manager = LocalizationManager(pseudolocalize: true)
        manager.language = .en

        XCTAssertEqual(manager.s("common.cancel"), Pseudolocalizer.transform("Cancel"))
        if let pluralKey, let format = english[pluralKey] {
            let base = String(pluralKey.dropLast(".one".count))
            XCTAssertEqual(
                manager.plural(base, count: 1, arguments: []),
                Pseudolocalizer.transform(format)
            )
        } else {
            XCTFail("expected at least one plural key")
        }

        let plain = LocalizationManager(pseudolocalize: false)
        XCTAssertEqual(plain.s("common.cancel"), "Cancel")
    }
}
