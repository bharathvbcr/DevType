import AppKit
import ExpanderEngine
import UniformTypeIdentifiers

// MARK: - §0.4 (UI half) — the door finally swings both ways
//
// Import was fully built (TextExpander + Espanso auto-detect) but there was no
// `NSSavePanel` anywhere in `Sources/`. This adds one, offering the formats
// the engine can produce:
//
//   • DevType JSON     — `SnippetStore.exportLibraryData(groups:)` (round-trips exactly)
//   • Espanso YAML     — `SnippetExporter.data(from:format:.espansoYAML)`
//   • Espanso folder   — `SnippetExporter.espansoYAMLFiles(from:)`, one file per group
//   • CSV              — `SnippetExporter.data(from:format:.csv)`
//
// It is also the escape hatch when the store latches its write-blocked state
// (§1.4 / §0.3): export reads the in-memory library, so it works even when
// saving is refused.

enum LibraryExporter {

    /// Owns destination choice through the final filesystem result, so menu, Preferences, and
    /// manager entry points cannot stack save panels or race two exports. Cancelling the panel
    /// releases admission without ever starting serialization.
    private static let operationGate = SnippetOperationGate()

    /// Formats offered in the save panel's accessory popup.
    enum Choice: Int, CaseIterable {
        case json
        case espansoYAML
        /// One Espanso match file per group, written into a directory. This is the layout
        /// Espanso actually reads from `match/`, and the one users keep in version control —
        /// a single concatenated document is convenient to hand around but not to install.
        case espansoDirectory
        case csv

        var displayName: String {
            switch self {
            case .json: return LocalizationManager.shared.s("export.json")
            case .espansoYAML: return SnippetExporter.Format.espansoYAML.displayName
            case .espansoDirectory: return LocalizationManager.shared.s("export.espansoDirectory")
            case .csv: return SnippetExporter.Format.csv.displayName
            }
        }

        var fileExtension: String {
            switch self {
            case .json: return "json"
            case .espansoYAML: return SnippetExporter.Format.espansoYAML.fileExtension
            case .espansoDirectory: return ""
            case .csv: return SnippetExporter.Format.csv.fileExtension
            }
        }

        var suggestedFileName: String {
            switch self {
            case .json: return LocalizationManager.shared.s("export.json.file")
            case .espansoYAML: return SnippetExporter.Format.espansoYAML.suggestedFileName
            case .espansoDirectory: return LocalizationManager.shared.s("export.espansoDirectory.file")
            case .csv: return SnippetExporter.Format.csv.suggestedFileName
            }
        }

        var contentType: UTType {
            switch self {
            case .json: return .json
            case .espansoYAML: return UTType(filenameExtension: "yml") ?? .plainText
            case .espansoDirectory: return .folder
            case .csv: return .commaSeparatedText
            }
        }
    }

    /// Presents the save panel and writes the chosen format.
    /// `window` makes it a sheet; pass `nil` from the menu bar.
    ///
    /// `restrictedTo` limits the export to those snippet IDs — the manager's bulk bar
    /// passes its selection so "Export…" under an "N selected" label writes N snippets
    /// rather than the whole library. `nil` (the default) exports everything.
    static func present(
        from window: NSWindow?,
        store: SnippetStore = .shared,
        restrictedTo selectedIDs: Set<UUID>? = nil
    ) {
        let loc = LocalizationManager.shared
        guard operationGate.begin() else {
            DevTypeAlert.info(
                title: loc.s("export.inprogress.title"),
                message: loc.s("export.inprogress.message"),
                window: window
            )
            return
        }

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
        let formatSession = LibraryExportFormatSession(onChange: syncPanel)
        popup.target = formatSession
        popup.action = #selector(LibraryExportFormatSession.changed(_:))
        syncPanel()

        // NSSavePanel retains its completion handler, while NSControl does not promise to retain
        // its target. Capture the per-panel session so the target remains alive until this panel
        // finishes without relying on mutable global callback state.
        let finish: (NSApplication.ModalResponse) -> Void = { [formatSession] response in
            _ = formatSession
            guard response == .OK, let url = panel.url else {
                operationGate.finish()
                return
            }
            let choice = Choice(rawValue: popup.selectedTag()) ?? .json
            beginWrite(
                choice: choice,
                to: url,
                store: store,
                window: window,
                restrictedTo: selectedIDs
            )
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.begin(completionHandler: finish)
        }
    }

    /// Narrows the library to `selectedIDs`, preserving each surviving group's metadata
    /// (name, symbol, colour, app scoping) so a re-import lands snippets back where they were.
    /// Groups left with nothing selected are dropped rather than exported empty.
    /// `nil` means "no restriction" and returns the library untouched.
    static func restrict(_ groups: [SnippetGroup], to selectedIDs: Set<UUID>?) -> [SnippetGroup] {
        guard let selectedIDs else { return groups }
        return groups.compactMap { group in
            var trimmed = group
            trimmed.snippets = group.snippets.filter { selectedIDs.contains($0.id) }
            return trimmed.snippets.isEmpty ? nil : trimmed
        }
    }

    /// Writes one Espanso match file per group into `directory`.
    ///
    /// The whole export is staged in a sibling temporary directory and moved into place at
    /// the end, so a failure part-way through cannot leave the user with a directory holding
    /// half their library — the same all-or-nothing contract the single-file formats get from
    /// an atomic write. An existing directory at `url` is replaced only once the new one is
    /// complete.
    static func writeEspansoDirectory(groups: [SnippetGroup], to directory: URL) throws {
        let files = try SnippetExporter.espansoYAMLFiles(from: groups)
        let fm = FileManager.default
        let staging = directory
            .deletingLastPathComponent()
            .appendingPathComponent(".devtype-export-\(UUID().uuidString)")

        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in files {
                try Data(file.contents.utf8).write(
                    to: staging.appendingPathComponent(file.fileName),
                    options: .atomic
                )
            }
            if fm.fileExists(atPath: directory.path) {
                _ = try fm.replaceItemAt(directory, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: directory)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func beginWrite(
        choice: Choice,
        to url: URL,
        store: SnippetStore,
        window: NSWindow?,
        restrictedTo selectedIDs: Set<UUID>?
    ) {
        let loc = LocalizationManager.shared
        let progress = DevTypeProgressPresentation.present(
            title: loc.s("export.progress.title"),
            message: loc.s("export.progress.message", choice.displayName),
            window: window
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                let groups = restrict(store.loadGroups(), to: selectedIDs)
                return try write(choice: choice, groups: groups, to: url)
            }
            DispatchQueue.main.async {
                progress.dismiss()
                operationGate.finish()
                report(outcome, choice: choice, window: window, loc: loc)
            }
        }
    }

    /// Synchronous filesystem seam used by the background operation and focused tests. A count is
    /// returned only after serialization and the atomic file/directory operation completes.
    @discardableResult
    static func write(
        choice: Choice,
        groups: [SnippetGroup],
        to url: URL
    ) throws -> Int {
        switch choice {
        case .json:
            try SnippetStore.exportLibraryData(groups: groups).write(to: url, options: .atomic)
        case .espansoYAML:
            try SnippetExporter.data(from: groups, format: .espansoYAML).write(to: url, options: .atomic)
        case .csv:
            try SnippetExporter.data(from: groups, format: .csv).write(to: url, options: .atomic)
        case .espansoDirectory:
            try writeEspansoDirectory(groups: groups, to: url)
        }
        return groups.reduce(0) { $0 + $1.snippets.count }
    }

    private static func report(
        _ outcome: Result<Int, Error>,
        choice: Choice,
        window: NSWindow?,
        loc: LocalizationManager
    ) {
        switch outcome {
        case .success(let count):
            DevTypeLog.app.info(
                "[Export] wrote \(count, privacy: .public) snippets format=\(choice.fileExtension, privacy: .public)"
            )
            DevTypeAlert.info(
                title: loc.s("export.done.title"),
                message: loc.s("export.done.body", count, choice.displayName),
                window: window
            )
        case .failure(let error):
            DevTypeLog.app.error(
                "[Export] failed \(DevTypeLog.errorMetadata(error), privacy: .public)"
            )
            DevTypeAlert.warn(
                title: loc.s("export.failed.title"),
                message: failureMessage(for: error, choice: choice, loc: loc),
                window: window
            )
        }
    }

    /// Finite, localized error projection. Neither arbitrary serializer details nor filesystem
    /// paths from `NSError.userInfo` are allowed into the alert.
    static func failureMessage(
        for error: Error,
        choice: Choice,
        loc: LocalizationManager
    ) -> String {
        if error is SnippetExporter.ExportError {
            return loc.s("export.failed.encoding", choice.displayName)
        }

        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: cocoaError.code) {
            case .fileWriteOutOfSpace:
                return loc.s("export.failed.space", choice.displayName)
            case .fileWriteNoPermission, .fileWriteVolumeReadOnly, .fileNoSuchFile:
                return loc.s("export.failed.access", choice.displayName)
            default:
                break
            }
        }
        return loc.s("export.failed.generic", choice.displayName)
    }
}

/// Per-panel target/action bridge. Keeping the callback local avoids mutable global presentation
/// state even though the exporter admits only one user flow at a time.
final class LibraryExportFormatSession: NSObject {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    @objc func changed(_ sender: NSPopUpButton) {
        onChange()
    }
}
