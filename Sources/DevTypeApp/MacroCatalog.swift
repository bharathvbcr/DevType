import AppKit
import ExpanderEngine

// MARK: - §2: the macro catalogue
//
// The old `showMacroMenu` hardcoded nine `(title, rawToken)` tuples in a flat
// `NSMenu`. Every macro the engine gained after that menu was written — date
// arithmetic, case transforms, `%uuid%`, `%random:…%`, `%counter:…%`, the whole
// mustache half of the dual syntax — was invisible in the UI and therefore a
// dead feature. Nothing tied the menu to the parser, so the two drifted silently.
//
// This file is the fix: ONE table, with a live example provider per entry that
// runs the *real* engine (`MacroPreview`, `DynamicTemplateEngine`,
// `DateFormatLibrary`, `MacroRandom`) rather than a hardcoded sample string. If
// engine behaviour changes, the palette's examples change with it.
//
// Every token below was verified against source, not guessed:
//   • `MacroParser.delimitedKeywords`  — filltext, fillarea, fillpopup, fillpart,
//     snippet, key, date, random, counter, case, uuid   (`%keyword:body%`)
//   • `MacroParser.bareKeywords`       — `%fillpartend%`, `%caseend%`, `%uuid%`
//   • `MacroParser.parseDelimitedMacro` — `%@<offset>%` TextExpander date math
//   • `%|` and `%clipboard`            — no closing delimiter (TE quirk)
//   • `DateFormatLibrary.presets`      — the 16 named date formats
//   • `DateFormatLibrary.splitSpec`    — `iso:+1d` = preset + offset
//   • `MacroRandom.value(spec:)`       — `1-100`, `hex:8`, `a|b|c`
//   • `MacroCounterSpec.parse`         — `name`, `name:+5`
//   • `TextCaseTransform.named`        — upper / lower / title / sentence
//   • `HIDKeyPoster.keyCode(forTrailingKeyName:)` — enter, return, tab, escape, space
//   • `DynamicTemplateEngine` regexes  — {{date:…}}, {{time}}, {{clipboard}},
//     {{calc:…}}, {{uuid[:spec]}}, {{random[:spec]}}, {{counter[:spec]}},
//     {{upper:…}} / {{lower:…}} / {{title:…}} / {{sentence:…}}, {{cursor}}
//   • `MacroRenderer.resolveMustacheNested` — {{snippet:trigger}}

/// A stretch of `MacroDescriptor.token` the user is expected to type over.
///
/// §2: this is *data on the descriptor*, computed once when the catalogue is
/// built, so smart insertion never has to re-parse the inserted string to work
/// out what to select.
struct MacroPlaceholder: Equatable {
    /// UTF-16 offset from the start of `MacroDescriptor.token`.
    let offset: Int
    /// UTF-16 length. Zero means "put the caret here" (used for paired tokens).
    let length: Int
}

/// Palette sections, in display order.
enum MacroCategory: String, CaseIterable {
    case dateTime
    case cursorInput
    case fillIns
    case textTransforms
    case dynamic
    case keys
    case nested

    var titleKey: String {
        switch self {
        case .dateTime: return "macro.category.date"
        case .cursorInput: return "macro.category.cursor"
        case .fillIns: return "macro.category.fill"
        case .textTransforms: return "macro.category.transform"
        case .dynamic: return "macro.category.dynamic"
        case .keys: return "macro.category.keys"
        case .nested: return "macro.category.nested"
        }
    }
}

/// One row of the macro palette.
struct MacroDescriptor {

    /// Template markers. `⟦` / `⟧` (U+27E6 / U+27E7) appear in no macro syntax
    /// DevType understands, so a template can mark its editable spans inline and
    /// the initializer turns them into `placeholders` exactly once.
    static let placeholderOpen: Character = "\u{27E6}"
    static let placeholderClose: Character = "\u{27E7}"

    let id: String
    let category: MacroCategory
    /// Localization key for the display name (ignored when `literalName` is set).
    let nameKey: String
    /// Name that comes from the engine rather than the string table (date presets).
    let literalName: String?
    let detailKey: String
    /// Optional single argument substituted into the localized detail string.
    let detailArgument: String?
    /// The text actually inserted into the snippet body.
    let token: String
    let placeholders: [MacroPlaceholder]
    /// Extra untranslated search terms (syntax aliases, engine spec names).
    let keywords: String

    private let exampleProvider: (String) -> String

    init(
        id: String,
        category: MacroCategory,
        nameKey: String = "",
        literalName: String? = nil,
        detailKey: String,
        detailArgument: String? = nil,
        template: String,
        keywords: String = "",
        example: @escaping (String) -> String = { _ in "" }
    ) {
        let parsed = Self.parseTemplate(template)
        self.id = id
        self.category = category
        self.nameKey = nameKey
        self.literalName = literalName
        self.detailKey = detailKey
        self.detailArgument = detailArgument
        self.token = parsed.token
        self.placeholders = parsed.placeholders
        self.keywords = keywords
        self.exampleProvider = example
    }

    /// Rendered by the real engine at display time; never a hardcoded string.
    var example: String {
        exampleProvider(token).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func name(using loc: LocalizationManager) -> String {
        if let literalName { return literalName }
        return loc.s(nameKey)
    }

    func detail(using loc: LocalizationManager) -> String {
        if let detailArgument { return loc.s(detailKey, detailArgument) }
        return loc.s(detailKey)
    }

    /// Splits `"%date:⟦iso⟧%"` into `("%date:iso%", [offset 6, length 3])`.
    private static func parseTemplate(_ template: String) -> (token: String, placeholders: [MacroPlaceholder]) {
        var token = ""
        var placeholders: [MacroPlaceholder] = []
        var openOffset: Int?
        for character in template {
            if character == placeholderOpen {
                openOffset = token.utf16.count
                continue
            }
            if character == placeholderClose {
                if let start = openOffset {
                    placeholders.append(MacroPlaceholder(offset: start, length: token.utf16.count - start))
                }
                openOffset = nil
                continue
            }
            token.append(character)
        }
        return (token, placeholders)
    }
}

// MARK: - Catalogue

enum MacroCatalog {

    /// Every macro the palette can insert, grouped by category in display order.
    static let all: [MacroDescriptor] = buildAll()

    static func descriptors(in category: MacroCategory) -> [MacroDescriptor] {
        all.filter { $0.category == category }
    }

    // MARK: Example providers
    //
    // All three are side-effect free. That is load-bearing: `MacroPreview` peeks
    // counters instead of advancing them, and `MacroRandom` / `uuidValue` are
    // pure. Rendering `{{counter:…}}` or `{{random:…}}` through
    // `DynamicTemplateEngine` would advance the live counter and poison
    // `MacroVolatileStore` for a real expansion happening in the same half
    // second, so those entries route around it.

    /// TextExpander-syntax example via the editor's own side-effect-free renderer.
    fileprivate static func teExample(_ token: String) -> String {
        MacroPreview.render(token)
    }

    /// Mustache-syntax example. `clipboardText: ""` is passed explicitly so the
    /// palette never reads `NSPasteboard` just to draw a row.
    fileprivate static func mustacheExample(_ token: String) -> String {
        DynamicTemplateEngine.shared.resolve(token, clipboardText: "").text
    }

    /// Counter values are *peeked*, never advanced.
    fileprivate static func counterExample(_ name: String) -> String {
        String(MacroCounterStore.shared.value(for: name))
    }

    // MARK: Table

    private static func buildAll() -> [MacroDescriptor] {
        var result: [MacroDescriptor] = []
        result.append(contentsOf: dateTime())
        result.append(contentsOf: cursorInput())
        result.append(contentsOf: fillIns())
        result.append(contentsOf: textTransforms())
        result.append(contentsOf: dynamicValues())
        result.append(contentsOf: keys())
        result.append(contentsOf: nested())
        return result
    }

    // MARK: Date & time

    private static func dateTime() -> [MacroDescriptor] {
        // The 16 named presets come straight from `DateFormatLibrary.presets`, so
        // adding a preset to the engine adds a palette row for free.
        var result: [MacroDescriptor] = DateFormatLibrary.presets.map { preset in
            MacroDescriptor(
                id: "date.preset.\(preset.id)",
                category: .dateTime,
                literalName: preset.title,
                detailKey: "macro.date.preset.detail",
                detailArgument: preset.title,
                template: "%date:\(preset.id)%",
                keywords: "date time \(preset.id) \(preset.title)",
                example: { MacroCatalog.teExample($0) }
            )
        }

        result.append(MacroDescriptor(
            id: "date.offset",
            category: .dateTime,
            nameKey: "macro.date.offset",
            detailKey: "macro.date.offset.detail",
            // `DateFormatLibrary.splitSpec` reads everything after the LAST colon
            // as the offset, so `iso:+1d` is preset `iso` shifted by one day.
            template: "%date:⟦iso⟧:⟦+1d⟧%",
            keywords: "date offset arithmetic tomorrow yesterday relative +1d -2w +1y -3M",
            example: { MacroCatalog.teExample($0) }
        ))
        result.append(MacroDescriptor(
            id: "date.teOffset",
            category: .dateTime,
            nameKey: "macro.date.teOffset",
            detailKey: "macro.date.teOffset.detail",
            // `%@<offset>%` — TextExpander writes the unit uppercase.
            template: "%@⟦+1D⟧%",
            keywords: "date offset textexpander tomorrow relative",
            example: { MacroCatalog.teExample($0) }
        ))
        result.append(MacroDescriptor(
            id: "date.pattern",
            category: .dateTime,
            nameKey: "macro.date.pattern",
            detailKey: "macro.date.pattern.detail",
            template: "%date:⟦yyyy-MM-dd⟧%",
            keywords: "date custom pattern dateformatter unicode",
            example: { MacroCatalog.teExample($0) }
        ))
        result.append(MacroDescriptor(
            id: "date.mustache",
            category: .dateTime,
            nameKey: "macro.date.mustache",
            detailKey: "macro.date.mustache.detail",
            template: "{{date}}",
            keywords: "date mustache",
            example: { MacroCatalog.mustacheExample($0) }
        ))
        result.append(MacroDescriptor(
            id: "date.mustacheFormat",
            category: .dateTime,
            nameKey: "macro.date.mustacheFormat",
            detailKey: "macro.date.mustacheFormat.detail",
            template: "{{date:⟦iso⟧}}",
            keywords: "date mustache preset iso us eu full",
            example: { MacroCatalog.mustacheExample($0) }
        ))
        result.append(MacroDescriptor(
            id: "date.mustacheOffset",
            category: .dateTime,
            nameKey: "macro.date.mustacheOffset",
            detailKey: "macro.date.mustacheOffset.detail",
            template: "{{date:⟦iso⟧:⟦+1d⟧}}",
            keywords: "date mustache offset arithmetic tomorrow",
            example: { MacroCatalog.mustacheExample($0) }
        ))
        result.append(MacroDescriptor(
            id: "time.mustache",
            category: .dateTime,
            nameKey: "macro.time.mustache",
            detailKey: "macro.time.mustache.detail",
            template: "{{time}}",
            keywords: "time clock mustache",
            example: { MacroCatalog.mustacheExample($0) }
        ))
        return result
    }

    // MARK: Cursor & input

    private static func cursorInput() -> [MacroDescriptor] {
        [
            MacroDescriptor(
                id: "cursor.te",
                category: .cursorInput,
                nameKey: "editor.macro.cursor",
                detailKey: "macro.cursor.detail",
                // No closing delimiter — `MacroParser` matches the bare prefix `%|`.
                template: "%|",
                keywords: "cursor caret position textexpander"
            ),
            MacroDescriptor(
                id: "cursor.mustache",
                category: .cursorInput,
                nameKey: "macro.cursor.mustache",
                detailKey: "macro.cursor.mustache.detail",
                template: "{{cursor}}",
                keywords: "cursor caret position mustache"
            ),
            MacroDescriptor(
                id: "clipboard.te",
                category: .cursorInput,
                nameKey: "editor.macro.clipboard",
                detailKey: "macro.clipboard.detail",
                // Also no closing delimiter (documented TextExpander quirk).
                template: "%clipboard",
                keywords: "clipboard paste pasteboard textexpander",
                example: { MacroCatalog.teExample($0) }
            ),
            MacroDescriptor(
                id: "clipboard.mustache",
                category: .cursorInput,
                nameKey: "macro.clipboard.mustache",
                detailKey: "macro.clipboard.mustache.detail",
                template: "{{clipboard}}",
                keywords: "clipboard paste pasteboard mustache"
            )
        ]
    }

    // MARK: Fill-ins

    private static func fillIns() -> [MacroDescriptor] {
        [
            MacroDescriptor(
                id: "fill.text",
                category: .fillIns,
                nameKey: "editor.macro.filltext",
                detailKey: "macro.filltext.detail",
                template: "%filltext:name=⟦Field⟧%",
                keywords: "fill filltext input single line prompt",
                example: { MacroCatalog.teExample($0) }
            ),
            MacroDescriptor(
                id: "fill.textDefault",
                category: .fillIns,
                nameKey: "macro.filltextDefault",
                detailKey: "macro.filltextDefault.detail",
                template: "%filltext:name=⟦Field⟧:default=⟦Value⟧%",
                keywords: "fill filltext default prefilled input",
                example: { MacroCatalog.teExample($0) }
            ),
            MacroDescriptor(
                id: "fill.area",
                category: .fillIns,
                nameKey: "editor.macro.fillarea",
                detailKey: "macro.fillarea.detail",
                template: "%fillarea:name=⟦Details⟧%",
                keywords: "fill fillarea multiline textarea input",
                example: { MacroCatalog.teExample($0) }
            ),
            MacroDescriptor(
                id: "fill.popup",
                category: .fillIns,
                nameKey: "editor.macro.fillpopup",
                detailKey: "macro.fillpopup.detail",
                // Everything between `name=` and `default=` is an option, per
                // `MacroParser.makeToken`.
                template: "%fillpopup:name=⟦Choice⟧:⟦Option A⟧:⟦Option B⟧:default=⟦Option A⟧%",
                keywords: "fill fillpopup menu choice options select",
                example: { MacroCatalog.teExample($0) }
            ),
            MacroDescriptor(
                id: "fill.part",
                category: .fillIns,
                nameKey: "editor.macro.fillpart",
                detailKey: "macro.fillpart.detail",
                // Paired token. The empty `⟦⟧` is a caret stop between the two
                // markers, so Tab lands the user where the body actually goes.
                template: "%fillpart:name=⟦Section⟧:default=⟦yes⟧%\n⟦⟧\n%fillpartend%",
                keywords: "fill fillpart optional section toggle fillpartend"
            )
        ]
    }

    // MARK: Text transforms

    private static func textTransforms() -> [MacroDescriptor] {
        // Sample body is deliberately lower case so the rendered example actually
        // demonstrates the transform.
        let sample = "sample text"
        var result: [MacroDescriptor] = []
        let transforms: [(TextCaseTransform, String)] = [
            (.upper, "macro.case.upper"),
            (.lower, "macro.case.lower"),
            (.title, "macro.case.title"),
            (.sentence, "macro.case.sentence")
        ]
        for (transform, nameKey) in transforms {
            // TextExpander block form: `%case:upper%…%caseend%`.
            result.append(MacroDescriptor(
                id: "case.te.\(transform.rawValue)",
                category: .textTransforms,
                nameKey: nameKey,
                detailKey: "macro.case.detail",
                template: "%case:\(transform.rawValue)%⟦\(sample)⟧%caseend%",
                keywords: "case \(transform.rawValue) transform textexpander caseend",
                example: { MacroCatalog.teExample($0) }
            ))
        }
        for (transform, nameKey) in transforms {
            // Mustache inline form: `{{upper:…}}`.
            result.append(MacroDescriptor(
                id: "case.mustache.\(transform.rawValue)",
                category: .textTransforms,
                nameKey: nameKey,
                detailKey: "macro.mustacheCase.detail",
                template: "{{\(transform.rawValue):⟦\(sample)⟧}}",
                keywords: "case \(transform.rawValue) transform mustache",
                example: { MacroCatalog.mustacheExample($0) }
            ))
        }
        return result
    }

    // MARK: Dynamic values

    private static func dynamicValues() -> [MacroDescriptor] {
        [
            MacroDescriptor(
                id: "uuid.te",
                category: .dynamic,
                nameKey: "macro.uuid",
                detailKey: "macro.uuid.detail",
                template: "%uuid%",
                keywords: "uuid guid identifier random id",
                example: { _ in MacroEnvironment.default.uuidValue(spec: "") }
            ),
            MacroDescriptor(
                id: "uuid.short",
                category: .dynamic,
                nameKey: "macro.uuidShort",
                detailKey: "macro.uuidShort.detail",
                template: "%uuid:⟦short⟧%",
                keywords: "uuid short lower compact identifier id",
                example: { _ in MacroEnvironment.default.uuidValue(spec: "short") }
            ),
            MacroDescriptor(
                id: "uuid.mustache",
                category: .dynamic,
                nameKey: "macro.uuid",
                detailKey: "macro.uuid.detail",
                template: "{{uuid}}",
                keywords: "uuid guid identifier mustache",
                example: { _ in MacroEnvironment.default.uuidValue(spec: "") }
            ),
            MacroDescriptor(
                id: "random.range",
                category: .dynamic,
                nameKey: "macro.randomRange",
                detailKey: "macro.randomRange.detail",
                template: "%random:⟦1-100⟧%",
                keywords: "random number range integer",
                example: { _ in MacroRandom.value(spec: "1-100") }
            ),
            MacroDescriptor(
                id: "random.hex",
                category: .dynamic,
                nameKey: "macro.randomHex",
                detailKey: "macro.randomHex.detail",
                template: "%random:hex:⟦8⟧%",
                keywords: "random hex alnum digits letters token string",
                example: { _ in MacroRandom.value(spec: "hex:8") }
            ),
            MacroDescriptor(
                id: "random.choice",
                category: .dynamic,
                nameKey: "macro.randomChoice",
                detailKey: "macro.randomChoice.detail",
                template: "%random:⟦alpha|beta|gamma⟧%",
                keywords: "random choice pick option list pipe",
                example: { _ in MacroRandom.value(spec: "alpha|beta|gamma") }
            ),
            MacroDescriptor(
                id: "random.mustache",
                category: .dynamic,
                nameKey: "macro.randomRange",
                detailKey: "macro.randomRange.detail",
                template: "{{random:⟦1-100⟧}}",
                keywords: "random number range mustache",
                example: { _ in MacroRandom.value(spec: "1-100") }
            ),
            MacroDescriptor(
                id: "counter.te",
                category: .dynamic,
                nameKey: "macro.counter",
                detailKey: "macro.counter.detail",
                template: "%counter:⟦invoice⟧%",
                keywords: "counter increment sequence number invoice",
                example: { _ in MacroCatalog.counterExample("invoice") }
            ),
            MacroDescriptor(
                id: "counter.step",
                category: .dynamic,
                nameKey: "macro.counterStep",
                detailKey: "macro.counterStep.detail",
                // `MacroCounterSpec.parse` reads a trailing `:+N` / `:-N` as the step.
                template: "%counter:⟦invoice⟧:⟦+5⟧%",
                keywords: "counter step increment sequence",
                example: { _ in MacroCatalog.counterExample("invoice") }
            ),
            MacroDescriptor(
                id: "counter.mustache",
                category: .dynamic,
                nameKey: "macro.counter",
                detailKey: "macro.counter.detail",
                template: "{{counter:⟦invoice⟧}}",
                keywords: "counter increment sequence mustache",
                example: { _ in MacroCatalog.counterExample("invoice") }
            ),
            MacroDescriptor(
                id: "calc.mustache",
                category: .dynamic,
                nameKey: "macro.calc",
                detailKey: "macro.calc.detail",
                template: "{{calc: ⟦12 * 4⟧}}",
                keywords: "calc calculate math arithmetic sum mustache",
                example: { MacroCatalog.mustacheExample($0) }
            )
        ]
    }

    // MARK: Trailing keys

    private static func keys() -> [MacroDescriptor] {
        // Names accepted by `HIDKeyPoster.keyCode(forTrailingKeyName:)`.
        [
            MacroDescriptor(
                id: "key.enter",
                category: .keys,
                nameKey: "editor.macro.keyEnter",
                detailKey: "macro.key.detail",
                template: "%key:enter%",
                keywords: "key enter return newline send"
            ),
            MacroDescriptor(
                id: "key.tab",
                category: .keys,
                nameKey: "editor.macro.keyTab",
                detailKey: "macro.key.detail",
                template: "%key:tab%",
                keywords: "key tab next field"
            ),
            MacroDescriptor(
                id: "key.escape",
                category: .keys,
                nameKey: "macro.keyEscape",
                detailKey: "macro.key.detail",
                template: "%key:escape%",
                keywords: "key escape esc dismiss"
            ),
            MacroDescriptor(
                id: "key.space",
                category: .keys,
                nameKey: "macro.keySpace",
                detailKey: "macro.key.detail",
                template: "%key:space%",
                keywords: "key space bar"
            )
        ]
    }

    // MARK: Nested snippets

    private static func nested() -> [MacroDescriptor] {
        [
            MacroDescriptor(
                id: "snippet.te",
                category: .nested,
                nameKey: "editor.macro.nested",
                detailKey: "macro.nested.detail",
                template: "%snippet:⟦TRIGGER⟧%",
                keywords: "snippet nested include reference trigger",
                example: { MacroCatalog.teExample($0) }
            ),
            MacroDescriptor(
                id: "snippet.mustache",
                category: .nested,
                nameKey: "editor.macro.nested",
                detailKey: "macro.nested.detail",
                template: "{{snippet:⟦trigger⟧}}",
                keywords: "snippet nested include reference mustache"
            )
        ]
    }
}
