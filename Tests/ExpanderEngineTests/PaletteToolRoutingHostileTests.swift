import XCTest
@testable import ExpanderEngine

/// Adversarial checks for the palette false-success fix.
///
/// `resolveDatePhrase` and `runMacro` are synchronous. They do not suspend, so
/// cancellation is not a path on these functions. `route` still drops a throw.
final class PaletteToolRoutingTestsHostile: XCTestCase {

    private var savedAI = false
    private var savedRouting = false
    private var savedAIObject: Any?
    private var savedRoutingObject: Any?

    override func setUp() {
        super.setUp()
        savedAIObject = UserDefaults.standard.object(forKey: AIPreferences.enabledKey)
        savedRoutingObject = UserDefaults.standard.object(forKey: AIPreferences.semanticRoutingEnabledKey)
        savedAI = AIPreferences.isEnabled
        savedRouting = AIPreferences.isSemanticRoutingEnabled
        AIPreferences.isEnabled = true
        AIPreferences.isSemanticRoutingEnabled = true
    }

    override func tearDown() {
        if let savedAIObject {
            UserDefaults.standard.set(savedAIObject, forKey: AIPreferences.enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AIPreferences.enabledKey)
        }
        // The setter also publishes SelectionMonitor. Re-remove only when the key was absent,
        // because the setter always writes a bool.
        AIPreferences.isEnabled = savedAI
        if savedAIObject == nil {
            UserDefaults.standard.removeObject(forKey: AIPreferences.enabledKey)
        }
        let routingKey = AIPreferences.semanticRoutingEnabledKey
        if let savedRoutingObject {
            UserDefaults.standard.set(savedRoutingObject, forKey: routingKey)
        } else {
            UserDefaults.standard.removeObject(forKey: routingKey)
        }
        XCTAssertEqual(AIPreferences.isSemanticRoutingEnabled, savedRouting)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: routingKey), savedRouting)
        super.tearDown()
    }

    // MARK: - Dates

    func testParserMissesAreNotTodayAndDoNotEcho() async {
        let phrases = [
            "",
            " ",
            "   \n\t",
            "\n\n",
            "\u{00A0}\u{00A0}",
            "today",
            "TODAY",
            " today ",
            "today\n",
            "tomorrow",
            "TOMORROW",
            "yesterday",
            "friday",
            "next  friday",
            "nextfriday",
            "next\nfriday",
            "next\rfriday",
            "next\u{2028}friday",
            "2026-10-13",
            "2026-10-13\n",
            "3rd of October",
            "ngày mai",
            "Ngày Mai",
            "غدا",
            "מחר",
            "\u{202E}today",
            "\u{200F}2026-10-13",
            "today\u{200F}",
            "+3d\nextra",
            "medium",
            "iso",
            "full",
            "time",
            "datetime",
            " medium ",
            " iso ",
            "+0d",
            "-0d",
            "date+0",
            "date+0d",
            "0d",
            String(repeating: "日", count: 80),
        ]
        let formats = ["medium", "iso", "full", "time", "datetime"]
        for phrase in phrases {
            let label = phrase.debugDescription
            XCTAssertNil(CommandPaletteCatalog.parseTypedQuery(phrase), "typed \(label)")
            XCTAssertNil(CommandPaletteCatalog.parseRelativeDayQuery(phrase), "relative \(label)")
            for format in formats {
                let today = CommandPaletteCatalog.resolveDate(.offsetDays(0, format: format))
                let resolved = PaletteToolRouter.resolveDatePhrase(phrase: phrase, format: format)
                XCTAssertNil(resolved, "\(label) \(format)")
                XCTAssertNotEqual(resolved, today, "miss must not be today (\(label), \(format))")
                XCTAssertNotEqual(resolved, phrase, "miss must not echo (\(label), \(format))")
                XCTAssertNotEqual(
                    resolved,
                    phrase.trimmingCharacters(in: .whitespacesAndNewlines),
                    "miss must not echo trimmed (\(label), \(format))"
                )
                await assertToolDateMatches(phrase: phrase, format: format, resolved: resolved, label: label)
            }
        }
    }

    /// Parsed as math or a custom instruction, or a zero offset the day parser rejects.
    /// Still not a date, so the tool must not invent today.
    func testNonDateTypedQueriesAreNotToday() async {
        let phrases = ["=today", "=2+2", "> tomorrow", ">today"]
        for phrase in phrases {
            XCTAssertNotNil(CommandPaletteCatalog.parseTypedQuery(phrase), phrase)
            XCTAssertNil(CommandPaletteCatalog.parseRelativeDayQuery(phrase), phrase)
            for format in ["medium", "iso", "full", "time", "datetime"] {
                let today = CommandPaletteCatalog.resolveDate(.offsetDays(0, format: format))
                let resolved = PaletteToolRouter.resolveDatePhrase(phrase: phrase, format: format)
                XCTAssertNil(resolved, "\(phrase) \(format)")
                XCTAssertNotEqual(resolved, today, phrase)
                XCTAssertNotEqual(resolved, phrase, phrase)
                await assertToolDateMatches(phrase: phrase, format: format, resolved: resolved, label: phrase)
            }
        }
    }

    func testParserHitsReturnTheCatalogDate() async {
        let dayShifting = [
            "+3d",
            "+1d",
            // Natural offsets are the same day count as +3d. A newline between the
            // number and the unit is whitespace, the same way `+\n3d` is a hit.
            "in 3 days",
            "in 3\ndays",
            "  +3d  ",
            "\n+3d\n",
            "+3D",
            "date+1",
            "date+3d",
            "DATE + 2",
            "+3w",
            "next friday",
            "Next Friday",
            "NEXT FRIDAY",
            "next friday date",
            "next friday\n",
            "next full date",
            "full date tomorrow",
            "\u{00A0}+3d\u{00A0}",
            "\u{2028}+3d",
            // U+200B is trimmed by the parser, and `\s` in the day regex matches a newline.
            "\u{200B}+3d",
            "+\n3d",
        ]
        let otherHits = ["+1h", "+1H", "+3M", "+3m"]
        for phrase in dayShifting + otherHits {
            let expected = catalogDate(for: phrase)
            XCTAssertNotNil(expected, "fixture must be a parser hit: \(phrase.debugDescription)")
            let resolved = PaletteToolRouter.resolveDatePhrase(phrase: phrase, format: "iso")
            XCTAssertEqual(resolved, expected, phrase)
            XCTAssertNotNil(resolved, phrase)
            XCTAssertNotEqual(resolved, phrase, "hit must be a formatted date, not the phrase")
            XCTAssertNotEqual(
                resolved,
                phrase.trimmingCharacters(in: .whitespacesAndNewlines),
                phrase
            )
            if dayShifting.contains(phrase) {
                for format in ["medium", "iso", "full", "time", "datetime"] {
                    XCTAssertNotEqual(
                        resolved,
                        CommandPaletteCatalog.resolveDate(.offsetDays(0, format: format)),
                        "\(phrase) must not be today \(format)"
                    )
                }
            }
            await assertToolDateMatches(phrase: phrase, format: "iso", resolved: resolved, label: phrase)
        }
    }

    func testNearMissDoesNotReuseARealHit() {
        let friday = PaletteToolRouter.resolveDatePhrase(phrase: "next friday", format: "full")
        XCTAssertNotNil(friday)
        for phrase in ["next\nfriday", "next  friday", "nextfriday", "friday", "tomorrow"] {
            let resolved = PaletteToolRouter.resolveDatePhrase(phrase: phrase, format: "full")
            XCTAssertNil(resolved, phrase)
            XCTAssertNotEqual(resolved, friday, phrase)
        }
    }

    func testRouterSourceDoesNotResolveAMissAsToday() throws {
        let source = try String(contentsOf: routerSourceURL(), encoding: .utf8)
        XCTAssertFalse(
            source.contains("offsetDays(0"),
            "resolveDatePhrase must not call resolveDate(.offsetDays(0)) on a miss"
        )
        XCTAssertFalse(source.contains("return arguments.text"))
        XCTAssertFalse(source.contains("return text"))
        let dateBody = try functionBody("resolveDatePhrase", in: source)
        XCTAssertTrue(dateBody.contains("return nil"))
        XCTAssertFalse(dateBody.contains("offsetDays(0"))
        let macroBody = try functionBody("runMacro", in: source)
        XCTAssertTrue(macroBody.contains("return nil"))
        XCTAssertFalse(macroBody.contains("return text"))
    }

    // MARK: - Macros

    func testKnownAliasesTransformAndDoNotUseIdentityAsProof() async {
        let upperIDs = [
            "uppercase",
            "UPPERCASE",
            " upper ",
            "uppercase ",
            "UpperCase",
            "upper",
            "UPPER",
            "upper\n",
            "\nupper\n",
        ]
        for id in upperIDs {
            let changed = PaletteToolRouter.runMacro(operation: id, text: "ab")
            XCTAssertEqual(changed, "AB", id.debugDescription)
            XCTAssertNotEqual(changed, "ab", id.debugDescription)
            XCTAssertEqual(changed, PaletteTextOps.apply(.upper, to: "ab"), id.debugDescription)
            // Already-upper input stays "AB". That equality is not evidence the op ran.
            XCTAssertEqual(PaletteToolRouter.runMacro(operation: id, text: "AB"), "AB", id.debugDescription)
            await assertToolMacroMatches(operation: id, text: "ab", resolved: changed)
        }
        for id in ["lower", "lowercase", " LOWER ", "LowerCase"] {
            let changed = PaletteToolRouter.runMacro(operation: id, text: "AB")
            XCTAssertEqual(changed, "ab", id)
            XCTAssertNotEqual(changed, "AB", id)
            await assertToolMacroMatches(operation: id, text: "AB", resolved: changed)
        }
        let sorted = PaletteToolRouter.runMacro(operation: "sortLines", text: "b\na")
        XCTAssertEqual(sorted, "a\nb")
        XCTAssertEqual(PaletteToolRouter.runMacro(operation: " SORTLINES ", text: "b\na"), "a\nb")
        let encoded = Data("ab".utf8).base64EncodedString()
        XCTAssertEqual(PaletteToolRouter.runMacro(operation: "base64Encode", text: "ab"), encoded)
        XCTAssertNotEqual(encoded, "ab")
        XCTAssertEqual(PaletteToolRouter.runMacro(operation: "BASE64ENCODE", text: "ab"), encoded)
        await assertToolMacroMatches(operation: "sortLines", text: "b\na", resolved: sorted)
        await assertToolMacroMatches(operation: "base64Encode", text: "ab", resolved: encoded)
    }

    func testUnknownIdsDoNotEchoAndDoNotPrefixMatch() async {
        let longID = String(repeating: "u", count: 10_000)
        XCTAssertEqual(longID.count, 10_000)
        let overCapNulls = "upper" + String(repeating: "\u{0000}", count: 60)
        XCTAssertEqual(overCapNulls.count, 65)
        let ids = [
            "",
            "   ",
            "uppercase now",
            "uppercase\textra",
            "uppercase\nnow",
            "no-such-op",
            "upper;rm",
            "upper rm",
            "..",
            longID,
            overCapNulls,
            "upperbound",
            "uppercaseX",
            "uppercaseextra",
            "base64",
            "base64Enc",
            "sha",
            "sha256extra",
            "json",
            "jsonPrettyX",
            "sort",
            "sortLinesX",
            "html",
            "md",
            "camelCaseExtra",
            "upper\u{0000}extra",
        ]
        for id in ids {
            let label = id.count > 80 ? "\(id.count) chars" : id.debugDescription
            XCTAssertNil(PaletteTextOp.resolved(from: id), label)
            XCTAssertNotEqual(PaletteTextOp.resolved(from: id), .upper, label)
            XCTAssertNotEqual(PaletteTextOp.resolved(from: id), .base64Encode, label)
            XCTAssertNotEqual(PaletteTextOp.resolved(from: id), .sortLines, label)
            let result = PaletteToolRouter.runMacro(operation: id, text: "ab")
            XCTAssertNil(result, label)
            XCTAssertNotEqual(result, "ab", "unknown id must not echo (\(label))")
            await assertToolMacroMatches(operation: id, text: "ab", resolved: result)
        }
    }

    /// NUL and other non-letters are not aliases. Folding them away must not select `upper`.
    func testNullAndPunctuationAreNotFoldedIntoARealOp() async {
        let ids = [
            "upper\u{0000}",
            "upper\u{0000}case",
            "upper" + String(repeating: "\u{0000}", count: 59),
            "upper.",
            "u.p.p.e.r",
            "(upper)",
            "upper!",
            "upper🎉",
            "upper\ncase",
        ]
        var accepted: [String] = []
        for id in ids {
            let op = PaletteTextOp.resolved(from: id)
            let result = PaletteToolRouter.runMacro(operation: id, text: "ab")
            if op != nil || result != nil {
                accepted.append(
                    "\(id.debugDescription) → op \(String(describing: op)) result \(String(describing: result))"
                )
            }
            XCTAssertNotEqual(result, "ab", "must not echo \(id.debugDescription)")
            await assertToolMacroMatches(operation: id, text: "ab", resolved: result)
        }
        XCTAssertEqual(
            accepted,
            [],
            "unknown ids were executed as a real text op"
        )
    }

    /// Fullwidth letters and interior combining marks stay in the id.
    /// Trailing whitespace still selects the alias. An interior space does not.
    func testFullwidthCombiningAndInteriorSpaceDoNotFalseMatch() async {
        let fullwidthUpper = "\u{FF35}\u{FF30}\u{FF30}\u{FF25}\u{FF32}"
        let fullwidthAlias = "\u{FF35}\u{FF30}\u{FF30}\u{FF25}\u{FF32}\u{FF23}\u{FF21}\u{FF33}\u{FF25}"
        let fullwidthLowerAlias = "\u{FF55}\u{FF50}\u{FF50}\u{FF45}\u{FF52}\u{FF43}\u{FF41}\u{FF53}\u{FF45}"
        let rejected = [
            fullwidthUpper,
            fullwidthAlias,
            fullwidthLowerAlias,
            "upp\u{FF45}r",
            "upper\u{FF43}ase",
            "uppe\u{0301}r",
            "upper\u{0301}case",
            "s\u{0301}ortLines",
            "sort\u{0301}Lines",
            "upper case",
            "UPPER CASE",
            "upper\u{00A0}case",
            "upper\u{3000}case",
        ]
        var accepted: [String] = []
        for id in rejected {
            let op = PaletteTextOp.resolved(from: id)
            let result = PaletteToolRouter.runMacro(operation: id, text: "ab")
            if op != nil || result != nil {
                accepted.append(
                    "\(id.debugDescription) → op \(String(describing: op)) result \(String(describing: result))"
                )
            }
            XCTAssertNotEqual(result, "ab", "must not echo \(id.debugDescription)")
            await assertToolMacroMatches(operation: id, text: "ab", resolved: result)
        }
        XCTAssertEqual(accepted, [], "compatibility or interior marks selected a real text op")

        XCTAssertEqual(PaletteTextOp.resolved(from: "UPPERCASE "), .upper)
        XCTAssertEqual(PaletteToolRouter.runMacro(operation: "UPPERCASE ", text: "ab"), "AB")
        await assertToolMacroMatches(operation: "UPPERCASE ", text: "ab", resolved: "AB")

        XCTAssertEqual(PaletteTextOp.resolved(from: "SortLines"), .sortLines)
        let sorted = PaletteTextOps.apply(.sortLines, to: "b\na")
        XCTAssertEqual(PaletteToolRouter.runMacro(operation: "SortLines", text: "b\na"), sorted)
        await assertToolMacroMatches(operation: "SortLines", text: "b\na", resolved: sorted)
    }

    func testEmptyOrThrownRouteDoesNotBecomeARow() async {
        XCTAssertNil(PaletteToolRouter.sanitize(""))
        XCTAssertNil(PaletteToolRouter.sanitize("\n"))
        XCTAssertNil(PaletteToolRouter.sanitize(" \t\n"))
        XCTAssertNil(PaletteToolRouter.sanitize("\u{2028}"))
        XCTAssertNil(PaletteToolRouter.sanitize("today\u{2028}tomorrow"))
        let query = "find a snippet please"
        let empty = await PaletteToolRouter.route(query: query) { _ in "" }
        XCTAssertNil(empty)
        let blank = await PaletteToolRouter.route(query: query) { _ in "  \n" }
        XCTAssertNil(blank)
        let split = await PaletteToolRouter.route(query: query) { _ in "today\u{2028}tomorrow" }
        XCTAssertNil(split)
        let dateRefusal = await PaletteToolRouter.route(query: query) { _ in
            throw PaletteToolRouter.Refusal.unrecognizedDate
        }
        XCTAssertNil(dateRefusal)
        let macroRefusal = await PaletteToolRouter.route(query: "uppercase the selection") { _ in
            throw PaletteToolRouter.Refusal.unknownOperation
        }
        XCTAssertNil(macroRefusal)
    }

    func testRemovingSemanticRoutingKeyReadsFalse() {
        let key = AIPreferences.semanticRoutingEnabledKey
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertNotNil(
            UserDefaults.standard.object(forKey: key),
            "explicit false still stores a value; that is not the same as removing the key"
        )
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
        XCTAssertFalse(AIPreferences.isSemanticRoutingEnabled)
        AIPreferences.isEnabled = true
        XCTAssertFalse(PaletteToolRouter.shouldAttemptRouting(query: "what is tomorrow"))
    }

    /// Pure functions only. No new async wait, so there is nothing to cancel.
    func testConcurrentPureDecisionsStayStable() {
        let phrases = ["+3d", "today", "next friday", "iso", "medium", "+1h", ""]
        let expectedDates = Dictionary(uniqueKeysWithValues: phrases.map {
            ($0, PaletteToolRouter.resolveDatePhrase(phrase: $0, format: "iso"))
        })
        let expectedUpper = PaletteToolRouter.runMacro(operation: "uppercase", text: "ab")
        XCTAssertEqual(expectedUpper, "AB")
        let lock = NSLock()
        var failures: [String] = []
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "palette.hostile.pure", attributes: .concurrent)
        for _ in 0..<100 {
            group.enter()
            queue.async {
                for phrase in phrases {
                    let got = PaletteToolRouter.resolveDatePhrase(phrase: phrase, format: "iso")
                    if got != expectedDates[phrase] {
                        lock.lock()
                        failures.append("date \(phrase.debugDescription)")
                        lock.unlock()
                    }
                }
                if PaletteToolRouter.runMacro(operation: "uppercase", text: "ab") != "AB" {
                    lock.lock()
                    failures.append("upper")
                    lock.unlock()
                }
                if PaletteToolRouter.runMacro(operation: "no-such-op", text: "ab") != nil {
                    lock.lock()
                    failures.append("unknown")
                    lock.unlock()
                }
                if PaletteToolRouter.runMacro(operation: "upperbound", text: "ab") != nil {
                    lock.lock()
                    failures.append("prefix")
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(failures, [])
    }

    // MARK: - Helpers

    private func catalogDate(for phrase: String) -> String? {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if let typed = CommandPaletteCatalog.parseTypedQuery(phrase) {
            switch typed {
            case .relativeDays(let days, let format, _):
                return CommandPaletteCatalog.resolveDate(.offsetDays(days, format: format))
            case .relativeOffset(let offset, let format, _):
                return CommandPaletteCatalog.resolveDate(.offset(offset, format: format))
            default:
                break
            }
        }
        if let relative = CommandPaletteCatalog.parseRelativeDayQuery(phrase) {
            return CommandPaletteCatalog.resolveDate(
                .offsetDays(relative.days, format: relative.format)
            )
        }
        return nil
    }

    private func routerSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ExpanderEngine/AI/PaletteToolRouter.swift")
    }

    private func functionBody(_ name: String, in source: String) throws -> String {
        guard let marker = source.range(of: "func \(name)") else {
            throw XCTSkip("missing \(name)")
        }
        let tail = source[marker.lowerBound...]
        guard let open = tail.firstIndex(of: "{") else {
            XCTFail("missing brace for \(name)")
            return ""
        }
        var depth = 0
        var index = open
        while index < tail.endIndex {
            let character = tail[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(tail[open...index])
                }
            }
            index = tail.index(after: index)
        }
        XCTFail("unbalanced \(name)")
        return ""
    }

    private func assertToolDateMatches(
        phrase: String,
        format: String,
        resolved: String?,
        label: String
    ) async {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        let tool = PaletteToolRouter.ResolveDateTool()
        let toolResult = try? await tool.call(
            arguments: .init(phrase: phrase, format: format)
        )
        XCTAssertEqual(toolResult, resolved, label)
        #endif
    }

    private func assertToolMacroMatches(operation: String, text: String, resolved: String?) async {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        let tool = PaletteToolRouter.RunMacroTool()
        let toolResult = try? await tool.call(
            arguments: .init(operation: operation, text: text)
        )
        XCTAssertEqual(toolResult, resolved, operation.debugDescription)
        #endif
    }
}
