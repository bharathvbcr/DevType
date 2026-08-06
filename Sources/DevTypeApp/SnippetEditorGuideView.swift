import AppKit
import ExpanderEngine

// MARK: - §1: new-snippet guide
//
// Two things new users get wrong, neither of which the editor ever said out loud:
//
//   1. THE TRIGGER RULE. Punctuation-leading triggers (`;sig`, `:eml`) fire the
//      instant the last character is typed. Bare words (`sig`) need a non-word
//      terminator first, unless Word Boundary is switched off. That rule lived
//      only in README.md and in `AbbreviationMatcher.match(characters:)`.
//      Here it is rendered LIVE against whatever the user has actually typed,
//      which beats any amount of static help text.
//
//   2. WHAT A SNIPPET CAN CONTAIN. Four one-click starters fill the form with a
//      working snippet so the first thing the user sees is a real example rather
//      than an empty box.
//
// The strip is shown only for new snippets (`existing == nil`), remembers its
// dismissal in UserDefaults, and is reachable again from the "?" button in the
// editor header — so dismissing is never permanent.

/// Describes what will actually happen with a given trigger.
///
/// Mirrors the three firing rules in `AbbreviationMatcher.match(characters:)`:
/// (1) non-word first character → immediate, (2) `requireWordBoundary == false`
/// → immediate suffix match, (3) otherwise `<boundary><trigger><terminator>`.
enum TriggerRuleDescription {

    static func text(
        for trigger: String,
        requireWordBoundary: Bool,
        loc: LocalizationManager
    ) -> String {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return loc.s("guide.trigger.empty")
        }
        // Rule (1): the matcher checks `!isWordCharacter(chars[start])`.
        if !AbbreviationMatcher.isWordCharacter(first) {
            return loc.s("guide.trigger.punctuation", trimmed)
        }
        // Rule (3) vs rule (2).
        return loc.s(requireWordBoundary ? "guide.trigger.word" : "guide.trigger.wordInstant", trimmed)
    }
}

/// A one-click example that fills the editor form.
struct SnippetStarterTemplate {
    let id: String
    let titleKey: String
    let symbol: String
    let trigger: String
    /// Snippet *content*, deliberately NOT routed through the string table.
    ///
    /// Localized values run through `String(format:)` whenever an argument is
    /// passed, and the en/ko/ja parity test compares format specifiers across
    /// tables — a body containing `%date:iso%` or `%|` reads as a `%d` / `%|`
    /// conversion and would either break that test or surface `%%` escapes to
    /// the user. Template bodies are data, not UI chrome, so they stay here.
    let replacement: String

    static let all: [SnippetStarterTemplate] = [
        SnippetStarterTemplate(
            id: "signature",
            titleKey: "guide.starter.signature",
            symbol: "signature",
            trigger: ";sig",
            replacement: "Best regards,\nAlex Rivera\nalex@example.com"
        ),
        SnippetStarterTemplate(
            id: "date",
            titleKey: "guide.starter.date",
            symbol: "calendar",
            trigger: ";today",
            // `%date:iso%` + the `%|` caret marker.
            replacement: "%date:iso% — %|"
        ),
        SnippetStarterTemplate(
            id: "fill",
            titleKey: "guide.starter.fill",
            symbol: "text.cursor",
            trigger: ";hi",
            // A single-line fill-in with a default, so the fill-in panel appears.
            replacement: "Hi %filltext:name=Name:default=there%,\n\n%|"
        ),
        SnippetStarterTemplate(
            id: "email",
            titleKey: "guide.starter.email",
            symbol: "envelope.fill",
            trigger: ":re",
            replacement: "Thanks for reaching out! %|\n\nBest,\nAlex"
        )
    ]
}

/// Quiet hint strip shown above the form for new snippets.
final class SnippetEditorGuideView: NSView {

    /// UserDefaults key required by the brief.
    static let dismissedDefaultsKey = "devtype.editor.guideDismissed"

    static var isDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: dismissedDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: dismissedDefaultsKey) }
    }

    /// Height the editor reserves for this strip when it is visible.
    static let preferredHeight: CGFloat = 116

    private let loc: LocalizationManager
    private let onStarter: (SnippetStarterTemplate) -> Void
    private let onDismiss: () -> Void

    private let ruleLabel: NSTextField
    private var starterButtons: [NSButton] = []

    init(
        loc: LocalizationManager,
        onStarter: @escaping (SnippetStarterTemplate) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.loc = loc
        self.onStarter = onStarter
        self.onDismiss = onDismiss
        self.ruleLabel = DevTypeTheme.makeLabel(
            "",
            font: DevTypeTheme.font(11, .medium),
            color: DevTypeTheme.textSecondary,
            wrapping: true
        )
        super.init(frame: .zero)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 10
        layer?.backgroundColor = DevTypeTheme.contrastOverlay(0.05).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = DevTypeTheme.hairline.cgColor

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = DevTypeTheme.tintedSymbol("lightbulb", size: 11, weight: .semibold, color: DevTypeTheme.accentBright)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)

        let titleLabel = DevTypeTheme.makeLabel(
            loc.s("guide.title"),
            font: DevTypeTheme.font(11.5, .bold),
            color: DevTypeTheme.textPrimary
        )
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let hideButton = Self.makeGhostButton(
            title: loc.s("guide.hide"),
            symbol: "xmark",
            target: self,
            action: #selector(dismissTapped)
        )
        hideButton.toolTip = loc.s("guide.hide")
        hideButton.setAccessibilityLabel(loc.s("guide.hide"))

        ruleLabel.translatesAutoresizingMaskIntoConstraints = false
        ruleLabel.maximumNumberOfLines = 2
        // §4: colour alone never carries this; the sentence itself is the signal.
        ruleLabel.setAccessibilityLabel(loc.s("ax.editor.triggerStatus"))

        let startersCaption = DevTypeTheme.makeLabel(
            loc.s("guide.starters"),
            font: DevTypeTheme.font(10, .semibold),
            color: DevTypeTheme.textTertiary
        )
        startersCaption.translatesAutoresizingMaskIntoConstraints = false

        var builtStarters: [NSButton] = []
        for index in SnippetStarterTemplate.all.indices {
            let starter = SnippetStarterTemplate.all[index]
            let button = Self.makeGhostButton(
                title: loc.s(starter.titleKey),
                symbol: starter.symbol,
                target: self,
                action: #selector(starterTapped(_:))
            )
            button.tag = index
            button.toolTip = starter.trigger
            button.setAccessibilityLabel(loc.s(starter.titleKey))
            button.setAccessibilityHelp(starter.trigger)
            builtStarters.append(button)
        }
        starterButtons = builtStarters
        let startersRow = NSStackView(views: starterButtons)
        startersRow.orientation = .horizontal
        startersRow.alignment = .centerY
        startersRow.spacing = 6
        startersRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(hideButton)
        addSubview(ruleLabel)
        addSubview(startersCaption)
        addSubview(startersRow)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            hideButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            hideButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            ruleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            ruleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ruleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 7),

            startersCaption.leadingAnchor.constraint(equalTo: ruleLabel.leadingAnchor),
            startersCaption.topAnchor.constraint(equalTo: ruleLabel.bottomAnchor, constant: 8),

            startersRow.leadingAnchor.constraint(equalTo: ruleLabel.leadingAnchor),
            startersRow.topAnchor.constraint(equalTo: startersCaption.bottomAnchor, constant: 5),
            startersRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])

        // §4: a labelled container whose children stay individually reachable —
        // the rule sentence and the four starter buttons are all real content.
        setAccessibilityElement(true)
        setAccessibilityRole(NSAccessibility.Role.group)
        setAccessibilityLabel(loc.s("ax.editor.guide"))

        update(trigger: "", requireWordBoundary: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-renders the trigger rule for whatever the user has typed so far.
    func update(trigger: String, requireWordBoundary: Bool) {
        let text = TriggerRuleDescription.text(
            for: trigger,
            requireWordBoundary: requireWordBoundary,
            loc: loc
        )
        ruleLabel.stringValue = text
        ruleLabel.setAccessibilityValue(text)
    }

    @objc private func dismissTapped() { onDismiss() }

    @objc private func starterTapped(_ sender: NSButton) {
        guard SnippetStarterTemplate.all.indices.contains(sender.tag) else { return }
        onStarter(SnippetStarterTemplate.all[sender.tag])
    }

    /// Small ghost capsule shared by the dismiss and starter affordances.
    /// Matches the "+ Macros" / "Image…" buttons already in the editor.
    static func makeGhostButton(
        title: String,
        symbol: String?,
        target: AnyObject?,
        action: Selector?
    ) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.backgroundColor = DevTypeTheme.accent.withAlphaComponent(0.12).cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = DevTypeTheme.accent.withAlphaComponent(0.30).cgColor
        if let symbol {
            button.image = DevTypeTheme.tintedSymbol(symbol, size: 9, weight: .bold, color: DevTypeTheme.accentBright)
            button.imagePosition = .imageLeading
        }
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: DevTypeTheme.font(10, .semibold),
                .foregroundColor: DevTypeTheme.accentBright
            ]
        )
        button.target = target
        button.action = action
        button.setAccessibilityRole(NSAccessibility.Role.button)
        button.setAccessibilityLabel(title)
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }
}
