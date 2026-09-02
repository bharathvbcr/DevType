import Foundation
import ExpanderEngine

/// One row in the snippet-manager “Add from Template” sheet.
///
/// Bodies intentionally stay as data (not localization table values) — same reason as
/// `SnippetStarterTemplate`: `%date:…%` / `%|` would trip format-specifier parity.
struct SnippetTemplate: Equatable {
    enum Section: String {
        case ai
        case general
    }

    let id: String
    let section: Section
    /// Localization key for the row title. AI rows use `AITransformKind.localizationKey`.
    let titleKey: String
    let symbol: String
    let trigger: String
    let replacement: String
    /// Built-in kind raw value, or empty for plain snippets.
    let aiTransform: String

    func makeDraft(loc: LocalizationManager) -> SnippetModel {
        let title = loc.s(titleKey)
        return SnippetModel(
            title: title,
            triggerKeyword: trigger,
            replacementText: replacement,
            isCaseSensitive: false,
            requireWordBoundary: true,
            isPlainText: true,
            enabled: true,
            aiTransform: aiTransform
        )
    }
}

enum SnippetTemplateCatalog {
    /// Suggested typed triggers for each built-in AI kind (punctuation-leading → instant fire).
    static func defaultTrigger(for kind: AITransformKind) -> String {
        switch kind {
        case .proofread: return ":fix"
        case .rewrite: return ":rw"
        case .paraphrase: return ":pp"
        case .expand: return ":exp"
        case .condense: return ":cd"
        case .mergeRewrite: return ":mrg"
        case .formal: return ":frm"
        case .friendly: return ":fr"
        case .bulletize: return ":bul"
        case .promptEnhance: return ":pe"
        case .explainCode: return ":code"
        case .generateDocstring: return ":doc"
        case .fixCode: return ":debug"
        case .toJson: return ":json"
        case .generateUnitTests: return ":test"
        case .gitCommitMessage: return ":commit"
        case .explainRegex: return ":regex"
        case .sqlQuery: return ":sql"
        case .translate: return ":tr"
        case .translateTelugu: return ":tte"
        case .translateHindi: return ":thi"
        case .removeMarkdown: return ":md"
        case .toMarkdown: return ":tomd"
        case .custom: return ":ai"
        }
    }

    static func aiInstruction(for kind: AITransformKind) -> String {
        let label: String
        switch kind {
        case .proofread: label = "Proofread"
        case .rewrite: label = "Rewrite"
        case .paraphrase: label = "Paraphrase"
        case .expand: label = "Expand"
        case .condense: label = "Condense"
        case .mergeRewrite: label = "Merge & Rewrite"
        case .formal: label = "Make Formal"
        case .friendly: label = "Make Friendly"
        case .bulletize: label = "Bullet List"
        case .promptEnhance: label = "Prompt Enhance"
        case .explainCode: label = "Explain Code"
        case .generateDocstring: label = "Generate Docstring"
        case .fixCode: label = "Fix Bugs & Errors"
        case .toJson: label = "Convert to JSON"
        case .generateUnitTests: label = "Write Unit Tests"
        case .gitCommitMessage: label = "Git Commit Message"
        case .explainRegex: label = "Explain Regex"
        case .sqlQuery: label = "Generate SQL Query"
        case .translate: label = "Translate to English"
        case .translateTelugu: label = "Translate to Telugu"
        case .translateHindi: label = "Translate to Hindi"
        case .removeMarkdown: label = "Remove Markdown"
        case .toMarkdown: label = "Format as Markdown"
        case .custom: label = "Custom"
        }
        return "Select text, then type this trigger. DevType applies “\(label)” on-device (Preferences → AI)."
    }

    static var all: [SnippetTemplate] {
        aiTemplates + generalTemplates
    }

    static var aiTemplates: [SnippetTemplate] {
        AITransformKind.builtInPalette.map { kind in
            SnippetTemplate(
                id: "ai.\(kind.rawValue)",
                section: .ai,
                titleKey: kind.localizationKey,
                symbol: "sparkles",
                trigger: defaultTrigger(for: kind),
                replacement: aiInstruction(for: kind),
                aiTransform: kind.rawValue
            )
        }
    }

    static var generalTemplates: [SnippetTemplate] {
        [
            SnippetTemplate(
                id: "general.signature",
                section: .general,
                titleKey: "manager.template.general.signature",
                symbol: "signature",
                trigger: ";sig",
                replacement: "Best regards,\nAlex Rivera\nalex@example.com",
                aiTransform: ""
            ),
            SnippetTemplate(
                id: "general.date",
                section: .general,
                titleKey: "manager.template.general.date",
                symbol: "calendar",
                trigger: ";today",
                replacement: "%date:iso% — %|",
                aiTransform: ""
            ),
            SnippetTemplate(
                id: "general.fill",
                section: .general,
                titleKey: "manager.template.general.fill",
                symbol: "text.cursor",
                trigger: ";hi",
                replacement: "Hi %filltext:name=Name:default=there%,\n\n%|",
                aiTransform: ""
            ),
            SnippetTemplate(
                id: "general.clipboard",
                section: .general,
                titleKey: "manager.template.general.clipboard",
                symbol: "doc.on.clipboard",
                trigger: ";clip",
                replacement: "%clipboard",
                aiTransform: ""
            ),
            SnippetTemplate(
                id: "general.nested",
                section: .general,
                titleKey: "manager.template.general.nested",
                symbol: "arrow.triangle.branch",
                trigger: ";wrap",
                replacement: "Note:\n%snippet:;sig%\n\n%|",
                aiTransform: ""
            ),
            SnippetTemplate(
                id: "general.email",
                section: .general,
                titleKey: "manager.template.general.email",
                symbol: "envelope.fill",
                trigger: ":re",
                replacement: "Thanks for reaching out! %|\n\nBest,\nAlex",
                aiTransform: ""
            )
        ]
    }
}
