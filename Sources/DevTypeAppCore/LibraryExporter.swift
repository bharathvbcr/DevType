import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

// MARK: - §0.4 (UI half) — the door finally swings both ways
//
// Import was fully built (TextExpander + Espanso auto-detect) but there was no
// `NSSavePanel` anywhere in `Sources/`. This adds one, offering the three formats
// the engine can now produce:
//
//   • DevType JSON  — `SnippetStore.exportLibraryData()` (round-trips exactly)
//   • Espanso YAML  — `SnippetExporter.data(from:format:.espansoYAML)`
//   • CSV           — `SnippetExporter.data(from:format:.csv)`
//
// It is also the escape hatch when the store latches its write-blocked state
// (§1.4 / §0.3): export reads the in-memory library, so it works even when
// saving is refused.

enum LibraryExporter {

    /// Formats offered in the save panel's accessory popup.
    enum Choice: Int, CaseIterable {
        case json
        case espansoYAML
        case csv

        var displayName: String {
            switch self {
            case .json: return LocalizationManager.shared.s("export.json")
            case .espansoYAML: return SnippetExporter.Format.espansoYAML.displayName
            case .csv: return SnippetExporter.Format.csv.displayName
            }
        }

        var fileExtension: String {
            switch self {
            case .json: return "json"
            case .espansoYAML: return SnippetExporter.Format.espansoYAML.fileExtension
            case .csv: return SnippetExporter.Format.csv.fileExtension
            }
        }

        var suggestedFileName: String {
            switch self {
            case .json: return LocalizationManager.shared.s("export.json.file")
            case .espansoYAML: return SnippetExporter.Format.espansoYAML.suggestedFileName
            case .csv: return SnippetExporter.Format.csv.suggestedFileName
            }
        }

        var contentType: UTType {
            switch self {
            case .json: return .json
            case .espansoYAML: return UTType(filenameExtension: "yml") ?? .plainText
            case .csv: return .commaSeparatedText
            }
        }
    }

    /// Presents the save panel and writes the chosen format.
    /// `window` makes it a sheet; pass `nil` from the menu bar.
    static func present(from window: NSWindow?, store: SnippetStore = .shared) {
        let loc = LocalizationManager.shared
        let panel = NSSavePanel()
        panel.title = loc.s("export.title")
        panel.prompt = loc.s("export.prompt")
        panel.message = loc.s("export.message")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 25), pullsDown: false)
        for choice in Choice.allCases {
            popup.addItem(withTitle: choice.displayName)
            popup.lastItem?.tag = choice.rawValue
        }
        popup.selectItem(at: 0)
        popup.setAccessibilityLabel(loc.s("export.format"))

        // Accessory view: a labelled format picker above the panel's buttons.
        let label = DevTypeTheme.makeLabel(
            loc.s("export.format"),
            font: DevTypeTheme.font(12, .medium),
            color: .labelColor
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 44))
        accessory.addSubview(label)
        accessory.addSubview(popup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: accessory.trailingAnchor, constant: -16),
            popup.centerYAnchor.constraint(equalTo: accessory.centerYAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        panel.accessoryView = accessory

        // Keep the suggested name and allowed type in step with the popup.
        let syncPanel: () -> Void = {
            let choice = Choice(rawValue: popup.selectedTag()) ?? .json
            panel.nameFieldStringValue = choice.suggestedFileName
            panel.allowedContentTypes = [choice.contentType]
        }
        popup.target = FormatSyncBox.shared
        popup.action = #selector(FormatSyncBox.changed(_:))
        FormatSyncBox.shared.onChange = syncPanel
        syncPanel()

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            FormatSyncBox.shared.onChange = nil
            guard response == .OK, let url = panel.url else { return }
            let choice = Choice(rawValue: popup.selectedTag()) ?? .json
            write(choice: choice, to: url, store: store, window: window)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.begin(completionHandler: finish)
        }
    }

    private static func write(
        choice: Choice,
        to url: URL,
        store: SnippetStore,
        window: NSWindow?
    ) {
        let loc = LocalizationManager.shared
        let groups = store.loadGroups()
        do {
            let data: Data
            switch choice {
            case .json:
                data = try store.exportLibraryData()
            case .espansoYAML:
                data = try SnippetExporter.data(from: groups, format: .espansoYAML)
            case .csv:
                data = try SnippetExporter.data(from: groups, format: .csv)
            }
            try data.write(to: url, options: .atomic)
            let count = groups.reduce(0) { $0 + $1.snippets.count }
            DevTypeLog.app.info(
                "[Export] wrote \(count, privacy: .public) snippets format=\(choice.fileExtension, privacy: .public)"
            )
            DevTypeAlert.info(
                title: loc.s("export.done.title"),
                message: loc.s("export.done.body", count, url.path),
                window: window
            )
        } catch {
            DevTypeLog.app.error(
                "[Export] failed: \(error.localizedDescription, privacy: .public)"
            )
            DevTypeAlert.warn(
                title: loc.s("export.failed.title"),
                message: error.localizedDescription,
                window: window
            )
        }
    }
}

/// `NSPopUpButton` needs an ObjC target; the exporter is an enum, so this tiny
/// box carries the action. One shared instance is enough — only one save panel
/// can be up at a time.
private final class FormatSyncBox: NSObject {
    static let shared = FormatSyncBox()
    var onChange: (() -> Void)?

    @objc func changed(_ sender: NSPopUpButton) {
        onChange?()
    }
}
