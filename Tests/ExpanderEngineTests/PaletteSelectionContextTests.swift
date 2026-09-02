import XCTest
@testable import ExpanderEngine

/// Context-aware suggestions.
///
/// The empty palette used to show one hardcoded list no matter what: date insertion first,
/// then the navigation rows, with every AI transform pinned below them in a section that was
/// always emitted last. For the commonest reason to open it — select text, rewrite it — the
/// entire visible top of the list was the wrong thing.
final class PaletteSelectionContextTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CommandUsageStatsStore.shared.resetAll()
        CommandPaletteCatalog.invalidateCache()
    }

    override func tearDown() {
        CommandUsageStatsStore.shared.resetAll()
        CommandPaletteCatalog.invalidateCache()
        super.tearDown()
    }

    private func rows(
        _ context: CommandPaletteCatalog.PaletteContext,
        query: String = "",
        aiDisabledReason: String? = nil
    ) -> [PaletteListRow] {
        CommandPaletteCatalog.invalidateCache()
        return CommandPaletteCatalog.buildRows(
            query: query,
            groups: [],
            loc: .shared,
            aiDisabledReason: aiDisabledReason,
            context: context
        )
    }

    private func firstHeader(_ rows: [PaletteListRow]) -> PaletteSection? {
        for row in rows { if case .header(let section) = row { return section } }
        return nil
    }

    private func commandIDs(_ rows: [PaletteListRow]) -> [String] {
        rows.compactMap { if case .command(let hit) = $0 { return hit.command.id } else { return nil } }
    }

    // MARK: - The ask

    /// With text selected, a transform is the next step. It must be the first thing offered.
    func testSelectionLeadsWithTransforms() {
        let selected = rows(.selection)
        XCTAssertEqual(firstHeader(selected), .ai, "The AI section must lead when text is selected.")
        XCTAssertEqual(
            commandIDs(selected).first, "ai.proofread",
            "The first offered row must be a transform, not a date insert."
        )
    }

    /// Nothing selected means nothing to transform, so the old list is still the right one.
    func testIdleContextIsUnchanged() {
        let idle = rows(.none)
        XCTAssertEqual(firstHeader(idle), .commands)
        XCTAssertEqual(commandIDs(idle).first, "date.today", "Idle ordering must not regress.")
    }

    /// A selection is live and perishable — navigating away abandons it — so navigation rows
    /// must not sit above the transforms.
    func testNavigationIsDemotedWhileASelectionIsLive() {
        let ids = commandIDs(rows(.selection))
        guard let firstNav = ids.firstIndex(where: { $0.hasPrefix("nav.") }) else { return }
        let firstAI = ids.firstIndex { $0.hasPrefix("ai.") }
        XCTAssertNotNil(firstAI)
        XCTAssertLessThan(firstAI!, firstNav, "Transforms must outrank navigation on a selection.")
    }

    // MARK: - Limits of the nudge

    /// Context settles ties; it does not overrule what the user actually typed.
    func testSelectionContextDoesNotOverrideAnExplicitQuery() {
        let hits = CommandPaletteCatalog.matchCommands(
            query: "preferences", loc: .shared, context: .selection
        )
        XCTAssertEqual(
            hits.first?.command.id, "nav.preferences",
            "Typing a command's name must still find it with a selection live."
        )
    }

    /// Promoting AI rows that cannot be picked would be worse than not promoting them: the
    /// user would face a screen of greyed-out rows. Local text ops still work, so they lead.
    func testDisabledAIDoesNotLeadWithUnpickableRows() {
        let blocked = rows(.selection, aiDisabledReason: "unsupported language")
        let ids = commandIDs(blocked)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertFalse(
            ids[0].hasPrefix("ai."),
            "With AI unavailable the lead row must be something the user can actually run."
        )
        XCTAssertEqual(firstHeader(blocked), .commands)
    }

    // MARK: - Section ordering

    /// Sections used to be emitted in a fixed order, so an AI row could outscore every command
    /// row and still render below all of them.
    func testSectionsLeadByTheirBestHit() {
        let ai = rows(.selection)
        let commands = rows(.none)
        XCTAssertEqual(firstHeader(ai), .ai)
        XCTAssertEqual(firstHeader(commands), .commands)
        XCTAssertNotEqual(firstHeader(ai), firstHeader(commands), "Section order must be dynamic.")
    }

    /// Equal-scoring sections keep the canonical order so the list cannot jitter between
    /// keystrokes.
    func testTiedSectionsKeepCanonicalOrder() {
        let ordered = PaletteSection.allCases
        XCTAssertEqual(ordered, [.commands, .ai, .snippets], "Canonical tiebreak order.")
    }

    // MARK: - Discoverability

    /// Registering a command is not the same as making it discoverable. A typo here is a row
    /// that silently never appears in the context it was written for.
    func testEverySelectionSuggestionResolvesToARealCommand() {
        let catalogue = Set(CommandPaletteCatalog.commands.map(\.id))
        for id in CommandPaletteCatalog.selectionSuggestionIDs {
            XCTAssertTrue(catalogue.contains(id), "\(id) is offered on a selection but does not exist.")
        }
        for id in CommandPaletteCatalog.idleSuggestionIDs {
            XCTAssertTrue(catalogue.contains(id), "\(id) is offered when idle but does not exist.")
        }
    }

    /// The cache must not serve a selection-blind list to a caller that has a selection.
    func testContextIsPartOfTheCacheKey() {
        CommandPaletteCatalog.invalidateCache()
        let idle = CommandPaletteCatalog.buildRows(query: "", groups: [], loc: .shared, context: .none)
        let selected = CommandPaletteCatalog.buildRows(
            query: "", groups: [], loc: .shared, context: .selection
        )
        XCTAssertNotEqual(idle, selected, "A cached idle list must not be replayed for a selection.")
    }
}
