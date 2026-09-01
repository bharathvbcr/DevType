import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// Every localization key the UI layer *names* must exist in every shipped string table.
///
/// `LocalizationManager.lookup` ends in `?? key`: a key that is not in the table is not an
/// error, it is a label that reads `"macro.category.date"` to the user. `LocalizationParityTests`
/// (in `ExpanderEngineTests`) proves the three tables agree with *each other* — it cannot see a
/// key that all three are missing because the only mention of it lives in `DevTypeAppCore`.
///
/// This is the half of the check that needed the UI to be importable, which is why
/// `DevTypeAppCore` was split out of the `DevTypeApp` executable target.
final class AppStringKeyCoverageTests: XCTestCase {

    private lazy var tables: [(AppLanguage, [String: String])] =
        AppLanguage.concreteCases.map { ($0, LocalizationManager.stringTable(for: $0)) }

    /// Fails once per (key, language) so a missing translation names itself.
    private func assertResolves(
        _ key: String,
        origin: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (language, table) in tables {
            XCTAssertNotNil(
                table[key],
                "\(origin) names \"\(key)\", missing from the \(language.rawValue) table — "
                    + "the UI would render the raw key",
                file: file,
                line: line
            )
        }
    }

    func testTablesAreLoaded() {
        XCTAssertEqual(tables.count, 3)
        for (language, table) in tables {
            XCTAssertFalse(table.isEmpty, "\(language.rawValue) table is empty")
        }
    }

    func testMacroCategoryTitleKeysResolve() {
        for category in MacroCategory.allCases {
            assertResolves(category.titleKey, origin: "MacroCategory.\(category.rawValue)")
        }
    }

    /// `nameKey` is empty when `literalName` supplies the row's title instead (e.g. `%|%`),
    /// so only non-empty keys are required to resolve — but a descriptor must have one or
    /// the other, or the palette row has no title at all.
    func testMacroDescriptorKeysResolve() {
        for descriptor in MacroCatalog.all {
            XCTAssertTrue(
                !descriptor.nameKey.isEmpty || descriptor.literalName != nil,
                "macro \"\(descriptor.id)\" has neither a nameKey nor a literalName"
            )
            if !descriptor.nameKey.isEmpty {
                assertResolves(descriptor.nameKey, origin: "macro \"\(descriptor.id)\".nameKey")
            }
            XCTAssertFalse(
                descriptor.detailKey.isEmpty,
                "macro \"\(descriptor.id)\" has no detailKey"
            )
            assertResolves(descriptor.detailKey, origin: "macro \"\(descriptor.id)\".detailKey")
        }
    }

    func testSnippetTemplateTitleKeysResolve() {
        XCTAssertFalse(SnippetTemplateCatalog.all.isEmpty)
        for template in SnippetTemplateCatalog.all {
            assertResolves(template.titleKey, origin: "template \"\(template.id)\"")
        }
    }

    /// A `%@`-bearing format reached with no argument renders the literal `%@`. Every descriptor
    /// that passes a `detailArgument` must therefore have a placeholder in all three languages,
    /// and every one that passes none must have a placeholder in none of them.
    func testMacroDetailFormatsMatchTheirArgumentArity() {
        for descriptor in MacroCatalog.all {
            let expectsArgument = descriptor.detailArgument != nil
            for (language, table) in tables {
                guard let format = table[descriptor.detailKey] else { continue }
                XCTAssertEqual(
                    format.contains("%@"),
                    expectsArgument,
                    "macro \"\(descriptor.id)\" \(expectsArgument ? "passes" : "passes no")"
                        + " detailArgument, but the \(language.rawValue) format"
                        + " \(format.contains("%@") ? "has" : "has no") %@"
                )
            }
        }
    }
}
