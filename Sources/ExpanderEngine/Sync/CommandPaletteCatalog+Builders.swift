import Foundation
import NaturalLanguage

extension CommandPaletteCatalog {

    static func dateCommands() -> [PaletteCommand] {
        [
            PaletteCommand(
                id: "date.today",
                section: .commands,
                trigger: "today",
                titleKey: "palette.date.today",
                subtitleKey: "palette.date.today.detail",
                aliases: ["today", "todays date", "today's date", "current date", "date now", "date"],
                action: .date(.offsetDays(0, format: "medium"))
            ),
            PaletteCommand(
                id: "date.tomorrow",
                section: .commands,
                trigger: "date+1",
                titleKey: "palette.date.tomorrow",
                subtitleKey: "palette.date.tomorrow.detail",
                aliases: [
                    "tomorrow", "tomorrows date", "tomorrow's date", "date+1", "date +1",
                    "next day", "next full date", "full date tomorrow"
                ],
                action: .date(.offsetDays(1, format: "full"))
            ),
            PaletteCommand(
                id: "date.yesterday",
                section: .commands,
                trigger: "date-1",
                titleKey: "palette.date.yesterday",
                subtitleKey: "palette.date.yesterday.detail",
                aliases: ["yesterday", "yesterdays date", "yesterday's date", "date-1", "date -1", "previous day"],
                action: .date(.offsetDays(-1, format: "medium"))
            ),
            PaletteCommand(
                id: "date.iso",
                section: .commands,
                trigger: "iso",
                titleKey: "palette.date.iso",
                subtitleKey: "palette.date.iso.detail",
                aliases: ["iso", "iso date", "iso8601", "yyyy-mm-dd", "sortable date"],
                action: .date(.iso)
            ),
            PaletteCommand(
                id: "date.time",
                section: .commands,
                trigger: "time",
                titleKey: "palette.date.time",
                subtitleKey: "palette.date.time.detail",
                aliases: ["time", "time now", "current time", "now", "clock"],
                action: .date(.timeNow)
            ),
            PaletteCommand(
                id: "date.datetime",
                section: .commands,
                trigger: "datetime",
                titleKey: "palette.date.datetime",
                subtitleKey: "palette.date.datetime.detail",
                aliases: ["datetime", "date and time", "timestamp", "date time"],
                action: .date(.datetime)
            ),
            PaletteCommand(
                id: "date.full",
                section: .commands,
                trigger: "full",
                titleKey: "palette.date.full",
                subtitleKey: "palette.date.full.detail",
                aliases: ["full date", "long date", "weekday date", "complete date"],
                action: .date(.full)
            ),
            PaletteCommand(
                id: "date.epoch",
                section: .commands,
                trigger: "epoch",
                titleKey: "palette.date.epoch",
                subtitleKey: "palette.date.epoch.detail",
                aliases: ["epoch", "unix time", "unix timestamp", "epoch seconds"],
                action: .date(.epoch)
            )
        ]
    }

    static func textOpCommands() -> [PaletteCommand] {
        let specs: [(PaletteTextOp, String, String, String, [String])] = [
            (.upper, "upper", "palette.tool.upper", "palette.tool.upper.detail", ["uppercase", "upper case", "caps", "all caps"]),
            (.lower, "lower", "palette.tool.lower", "palette.tool.lower.detail", ["lowercase", "lower case"]),
            (.title, "titlecase", "palette.tool.title", "palette.tool.title.detail", ["title case", "capitalize"]),
            (.sentence, "sentence", "palette.tool.sentence", "palette.tool.sentence.detail", ["sentence case"]),
            (.snake, "snake", "palette.tool.snake", "palette.tool.snake.detail", ["snake case", "snake_case", "underscores"]),
            (.kebab, "kebab", "palette.tool.kebab", "palette.tool.kebab.detail", ["kebab case", "kebab-case", "slug", "hyphens"]),
            (.camel, "camel", "palette.tool.camel", "palette.tool.camel.detail", ["camel case", "camelCase", "identifier"]),
            (.pascal, "pascal", "palette.tool.pascal", "palette.tool.pascal.detail", ["pascal case", "PascalCase", "class name"]),
            (.sortLines, "sort", "palette.tool.sort", "palette.tool.sort.detail", ["sort lines", "sort lines a-z"]),
            (.dedupeLines, "dedupe", "palette.tool.dedupe", "palette.tool.dedupe.detail", ["dedupe", "unique lines", "remove duplicates"]),
            (.trimLines, "trim", "palette.tool.trim", "palette.tool.trim.detail", ["trim", "trim lines", "strip whitespace"]),
            (.numberLines, "number", "palette.tool.number", "palette.tool.number.detail", ["number lines", "line numbers"]),
            (.base64Encode, "b64", "palette.tool.b64enc", "palette.tool.b64enc.detail", ["base64", "base64 encode"]),
            (.base64Decode, "b64d", "palette.tool.b64dec", "palette.tool.b64dec.detail", ["base64 decode"]),
            (.urlEncode, "urlenc", "palette.tool.urlenc", "palette.tool.urlenc.detail", ["url encode", "percent encode"]),
            (.urlDecode, "urldec", "palette.tool.urldec", "palette.tool.urldec.detail", ["url decode"]),
            (.htmlEscape, "htmlenc", "palette.tool.htmlenc", "palette.tool.htmlenc.detail", ["html escape", "html encode"]),
            (.htmlUnescape, "htmldec", "palette.tool.htmldec", "palette.tool.htmldec.detail", ["html unescape", "html decode"]),
            (.jsonPretty, "json", "palette.tool.jsonpretty", "palette.tool.jsonpretty.detail", ["json pretty", "pretty json", "format json"]),
            (.jsonCompact, "jsonc", "palette.tool.jsoncompact", "palette.tool.jsoncompact.detail", ["json compact", "minify json"]),
            (.sha256, "sha256", "palette.tool.sha256", "palette.tool.sha256.detail", ["sha256", "hash", "sha-256"]),
            (.md5, "md5", "palette.tool.md5", "palette.tool.md5.detail", ["md5", "md5 hash"])
        ]
        return specs.map { op, trigger, title, detail, aliases in
            PaletteCommand(
                id: "tool.\(op.rawValue)",
                section: .commands,
                trigger: trigger,
                titleKey: title,
                subtitleKey: detail,
                aliases: [trigger] + aliases,
                action: .textOp(op)
            )
        }
    }

    static func generateCommands() -> [PaletteCommand] {
        [
            PaletteCommand(
                id: "tool.uuid",
                section: .commands,
                trigger: "uuid",
                titleKey: "palette.tool.uuid",
                subtitleKey: "palette.tool.uuid.detail",
                aliases: ["uuid", "guid", "generate uuid"],
                action: .generate(.uuid)
            ),
            PaletteCommand(
                id: "tool.lorem",
                section: .commands,
                trigger: "lorem",
                titleKey: "palette.tool.lorem",
                subtitleKey: "palette.tool.lorem.detail",
                aliases: ["lorem", "lorem ipsum", "placeholder text"],
                action: .generate(.lorem)
            ),
            PaletteCommand(
                id: "tool.password",
                section: .commands,
                trigger: "password",
                titleKey: "palette.tool.password",
                subtitleKey: "palette.tool.password.detail",
                aliases: ["password", "random password", "generate password"],
                action: .generate(.password)
            )
        ]
    }

    static func aiAliases(for kind: AITransformKind) -> [String] {
        switch kind {
        case .proofread:
            // No Telugu / Hindi aliases: the on-device model cannot proofread either
            // language — it answers in native script or trips Apple's guardrail — and
            // an alias for something that only ever errors is worse than no alias.
            // Translation between them still works; those rows own it.
            return [
                "proofread", "proof read", "proof-read", "fix spelling", "fix grammar",
                "grammar", "spelling", "correct", "typo", "typos"
            ]
        case .rewrite:
            return ["rewrite", "re-write", "rephrase", "clarify", "make clearer", "improve writing"]
        case .paraphrase:
            return ["paraphrase", "reword", "say differently", "other words"]
        case .expand:
            return ["expand", "elaborate", "longer", "add detail", "flesh out"]
        case .condense:
            return [
                "condense", "shorten", "shorter", "make shorter", "make it shorter",
                "summarize", "summary", "tighter", "brief", "less wordy", "trim"
            ]
        case .mergeRewrite:
            // "merge" leads because that is the distinct verb; "condense"/"summarize"
            // are deliberately absent so they keep resolving to `condense`, which is a
            // different job on a single passage.
            return [
                "merge", "merge and rewrite", "merge rewrite", "combine", "consolidate",
                "merge bullets", "combine bullets", "resume points", "resume bullets",
                "condense info", "merge notes", "merge points", "combine notes"
            ]
        case .formal:
            return [
                "formal", "make formal", "make this formal", "professional",
                "make professional", "business tone"
            ]
        case .friendly:
            return [
                "friendly", "make friendly", "make this friendly", "casual",
                "warm", "approachable"
            ]
        case .bulletize:
            return ["bulletize", "bullets", "bullet list", "make a list", "to bullets", "bullet points"]
        case .promptEnhance:
            return [
                "prompt enhance", "enhance prompt", "improve prompt", "better prompt",
                "promptenhance", "prompt"
            ]
        case .explainCode:
            return [
                "explain code", "code explanation", "what does this code do", "understand code",
                "code walkthrough", "explain function"
            ]
        case .generateDocstring:
            return [
                "docstring", "generate docstring", "document code", "documentation",
                "add comments", "swift doc", "jsdoc", "doc comments"
            ]
        case .fixCode:
            return [
                "fix code", "fix bugs", "debug", "debug code", "find bug", "correct code",
                "fix syntax error", "refactor code"
            ]
        case .toJson:
            return [
                "to json", "convert to json", "parse json", "make json", "format json",
                "json object", "json string"
            ]
        case .generateUnitTests:
            return [
                "unit tests", "write unit tests", "generate tests", "test cases", "create tests",
                "xctest", "jest", "pytest"
            ]
        case .gitCommitMessage:
            return [
                "git commit", "commit message", "generate commit", "git message", "commit note",
                "conventional commit"
            ]
        case .explainRegex:
            return [
                "explain regex", "regular expression", "regex explanation", "what does this regex do",
                "regex breakdown", "pattern explanation"
            ]
        case .sqlQuery:
            return [
                "sql query", "generate sql", "write sql", "database query", "select query",
                "postgres", "mysql", "sql schema"
            ]
        case .translate:
            return [
                "translate", "translation", "translate to english", "to english",
                "english", "telugu", "hindi", "telugu to english", "hindi to english",
                "tenglish", "hinglish", "romanized telugu", "romanized hindi",
                "convert to english", "meaning in english", "what does this mean"
            ]
        case .translateTelugu:
            return [
                "telugu", "to telugu", "in telugu", "english to telugu",
                "translate to telugu", "say in telugu", "tenglish", "romanized telugu"
            ]
        case .translateHindi:
            return [
                "hindi", "to hindi", "in hindi", "english to hindi",
                "translate to hindi", "say in hindi", "hinglish", "romanized hindi"
            ]
        case .toMarkdown:
            return [
                "to markdown", "format as markdown", "convert to markdown", "make markdown",
                "markdownify", "markdown", "md", "add formatting", "format text",
                "markdown format", "md format", "structure as markdown", "prettify",
                "add headings", "add bullets"
            ]
        case .toTable:
            return [
                "to table", "format as table", "make a table", "markdown table",
                "convert to table", "table", "tabular", "as a table", "rows and columns"
            ]
        case .removeMarkdown:
            return [
                "remove markdown", "markdown removal", "strip markdown", "markdown",
                "md", "unmarkdown", "plain text", "to plain text", "plaintext",
                "remove formatting", "strip formatting", "remove bold", "remove asterisks",
                "clean markdown", "demarkdown", "unformat"
            ]
        case .custom:
            return ["custom"]
        }
    }
}
