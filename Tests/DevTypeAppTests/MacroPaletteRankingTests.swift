import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// The macro palette used to filter with a boolean `contains` in fixed catalogue order, so a
/// term hitting the category title counted as much as one hitting the macro's own name, and
/// usage counted for nothing. These tests pin the ranked replacement.
final class MacroPaletteRankingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CommandUsageStatsStore.shared.resetAll()
    }

    override func tearDown() {
        CommandUsageStatsStore.shared.resetAll()
        super.tearDown()
    }

    private func flat(_ sections: [MacroPaletteRanking.Section]) -> [MacroDescriptor] {
        sections.flatMap { $0.matches.map(\.descriptor) }
    }

    /// A term matching a macro's own name or token must outrank one that only brushes the
    /// description or the category heading.
    func testNameAndTokenBeatDescriptionAndCategory() {
        let sections = MacroPaletteRanking.rank(query: "uuid", loc: .shared, usageBoost: { _ in 0 })
        let results = flat(sections)
        XCTAssertFalse(results.isEmpty, "'uuid' must match something.")
        let top = results[0]
        XCTAssertTrue(
            top.token.lowercased().contains("uuid") || top.name(using: .shared).lowercased().contains("uuid"),
            "The best 'uuid' hit should be a uuid macro, got \(top.id)."
        )
    }

    /// Personalization: the palette now learns, and a heavily used macro rises among peers
    /// that are otherwise equally relevant.
    func testUsageLiftsAMacroAmongEquallyRelevantPeers() throws {
        let baseline = flat(MacroPaletteRanking.rank(query: "date", loc: .shared, usageBoost: { _ in 0 }))
        guard baseline.count > 1 else {
            throw XCTSkip("Needs at least two 'date' macros to show reordering.")
        }
        let underdog = baseline[1]

        let boosted = flat(MacroPaletteRanking.rank(
            query: "date",
            loc: .shared,
            usageBoost: { $0 == MacroPaletteRanking.usageID(underdog) ? 5000 : 0 }
        ))
        XCTAssertEqual(
            boosted.first?.id, underdog.id,
            "A heavily used macro must be able to overtake its peers."
        )
    }

    /// Browsing with an empty query must stay in catalogue order — a reference list that
    /// reshuffles itself is worse than one that does not.
    func testEmptyQueryPreservesCatalogueOrder() {
        let sections = MacroPaletteRanking.rank(
            query: "  ", loc: .shared,
            usageBoost: { _ in 999 }
        )
        XCTAssertEqual(
            sections.map(\.category), MacroCategory.allCases,
            "Browsing must not reorder categories."
        )
        for section in sections {
            XCTAssertEqual(
                section.matches.map(\.descriptor.id),
                MacroCatalog.descriptors(in: section.category).map(\.id),
                "Browsing must not reorder macros within a category."
            )
        }
    }

    /// The same coverage rule as the command palette: a word no macro understands costs
    /// coverage instead of vetoing the whole query.
    func testUnknownWordDoesNotEmptyTheResults() {
        let known = flat(MacroPaletteRanking.rank(query: "uuid", loc: .shared, usageBoost: { _ in 0 }))
        let padded = flat(MacroPaletteRanking.rank(query: "uuid zzzzqqq", loc: .shared, usageBoost: { _ in 0 }))
        XCTAssertFalse(known.isEmpty)
        XCTAssertFalse(padded.isEmpty, "An unknown extra word must not empty the palette.")
        XCTAssertEqual(padded.first?.id, known.first?.id, "It must not change the winner either.")
    }

    /// Macro usage shares a store with palette commands, so the keys must not collide.
    func testUsageIDsAreNamespaced() {
        let descriptor = MacroCatalog.all[0]
        XCTAssertTrue(MacroPaletteRanking.usageID(descriptor).hasPrefix("macro."))
    }
}
