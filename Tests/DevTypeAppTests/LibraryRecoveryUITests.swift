import AppKit
import XCTest
@testable import ExpanderEngine
@testable import DevTypeAppCore

/// The UI halves of library recovery: the read-blocked "Replace with Defaults" flow names the
/// backup it kept (or says why nothing was replaced), and Preferences ▸ Snippets offers
/// "Restore from Backup…". Alerts are driven through `DevTypeAlert.presenterOverride`.
final class LibraryRecoveryUITests: XCTestCase {

    private struct Shown {
        let title: String
        let message: String
        let buttons: [String]
    }

    private var root: URL!
    private let loc = LocalizationManager.shared

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devtype-recovery-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        DevTypeAlert.presenterOverride = nil
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            for case let relative as String in walker {
                try? FilePermissions.setPOSIX(root.appendingPathComponent(relative), 0o700)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// An unreadable library, as the read-blocked condition sees it.
    private func unreadableStore() throws -> (SnippetStore, Data) {
        let file = root.appendingPathComponent("snippets.json")
        let original = try SnippetStore.exportLibraryData(groups: [
            SnippetGroup(name: "Mine", snippets: [SnippetModel(title: "m", triggerKeyword: "mine", replacementText: "x")])
        ])
        try original.write(to: file)
        try FilePermissions.setPOSIX(file, 0)
        if FileManager.default.isReadableFile(atPath: file.path) {
            throw XCTSkip("this process can read a mode-000 file")
        }
        let store = SnippetStore(
            location: .init(fileURL: file, expectsExistingLibrary: false),
            localSupportDirectory: root,
            watcherFactory: { _ in nil }
        )
        XCTAssertTrue(store.isLibraryReadFailed)
        return (store, original)
    }

    /// Answers each alert with the scripted button index and records what it showed.
    private func script(_ answers: [Int]) -> () -> [Shown] {
        var shown: [Shown] = []
        var remaining = answers
        DevTypeAlert.presenterOverride = { title, message, _, buttons, _, handler in
            shown.append(Shown(title: title, message: message, buttons: buttons))
            let answer = remaining.isEmpty ? buttons.count - 1 : remaining.removeFirst()
            handler?(answer)
        }
        return { shown }
    }

    func testReadBlockedOverwriteNamesTheBackupLocation() throws {
        let (store, original) = try unreadableStore()
        // Read-blocked alert → "Replace with Defaults" (index 2); confirm (0); result alert (0).
        let shown = script([2, 0, 0])

        LibraryHealthPresenter.present(.readBlocked(reason: "unreadable"), window: nil, store: store)

        let alerts = shown()
        XCTAssertEqual(alerts.map(\.title), [
            loc.s("library.blocked.title"),
            loc.s("library.overwrite.confirm.title"),
            loc.s("library.overwrite.done.title"),
        ])
        let backup = try XCTUnwrap(store.libraryBackups().first { $0.kind == .preOverwrite }?.url)
        XCTAssertEqual(alerts.last?.message, loc.s("library.overwrite.done.backup", backup.path),
                       "the result must name where the replaced library went")
        XCTAssertEqual(alerts.last?.buttons, [loc.s("common.ok"), loc.s("common.revealInFinder")])
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertFalse(store.isLibraryReadFailed)
    }

    func testRefusedOverwriteSaysSoAndKeepsSavingPaused() throws {
        let (store, _) = try unreadableStore()
        let backups = root.appendingPathComponent("Backups")
        try? FileManager.default.removeItem(at: backups)
        try Data("not a directory".utf8).write(to: backups)
        let shown = script([2, 0, 0])

        LibraryHealthPresenter.present(.readBlocked(reason: "unreadable"), window: nil, store: store)

        let last = try XCTUnwrap(shown().last)
        XCTAssertEqual(last.title, loc.s("library.overwrite.failed.title"))
        XCTAssertTrue(store.isLibraryReadFailed,
                      "a refused overwrite must not clear the latch — the next save would replace the file")
    }

    func testRecoveryStringsResolveInEveryLanguage() {
        var keys = [
            "library.overwrite.confirm.message",
            "library.overwrite.done.title",
            "library.overwrite.done.backup",
            "library.overwrite.done.noBackup",
            "library.overwrite.failed.title",
            "library.overwrite.failed.body",
            "prefs.snippets.restore",
            "prefs.snippets.restore.message",
            "prefs.snippets.restore.none",
            "prefs.snippets.restore.item",
            "prefs.snippets.restore.item.unreadable",
            "prefs.snippets.restore.confirm",
            "prefs.snippets.restore.reveal",
            "prefs.snippets.restore.done.title",
            "prefs.snippets.restore.done.body",
            "prefs.snippets.restore.failed.title",
        ]
        keys += LibraryBackupStore.Kind.allCases.map { "prefs.snippets.restore.kind.\($0.rawValue)" }
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for key in keys {
                XCTAssertNotNil(table[key], "\(key) is missing from the \(language.rawValue) table")
            }
            XCTAssertEqual(table["library.overwrite.done.backup"]?.components(separatedBy: "%@").count, 2,
                           "\(language.rawValue): the backup path placeholder is missing")
        }
    }

    func testSnippetsPreferencesOfferRestoreFromBackup() throws {
        let pane = SnippetsPreferencesViewController()
        let buttons = allSubviews(of: pane.view).compactMap { $0 as? CapsuleButton }
        let restore = try XCTUnwrap(
            buttons.first { $0.title == loc.s("prefs.snippets.restore") },
            "Preferences ▸ Snippets has no Restore from Backup… button"
        )
        XCTAssertEqual(restore.action, NSSelectorFromString("restoreFromBackupClicked"))
        XCTAssertTrue(restore.target === pane)
    }

    func testRestoreChooserRowsNameDateCountAndReason() {
        let pane = SnippetsPreferencesViewController()
        let date = Date(timeIntervalSince1970: 1_791_547_200)
        let restorable = SnippetStore.LibraryBackup(
            url: URL(fileURLWithPath: "/b"), createdAt: date, kind: .save, snippetCount: 7
        )
        let torn = SnippetStore.LibraryBackup(
            url: URL(fileURLWithPath: "/c"), createdAt: date, kind: .corrupted, snippetCount: nil
        )
        let stamp = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium)
        XCTAssertEqual(
            pane.restoreItemTitle(for: restorable),
            loc.s("prefs.snippets.restore.item", stamp, 7, loc.s("prefs.snippets.restore.kind.save"))
        )
        XCTAssertEqual(
            pane.restoreItemTitle(for: torn),
            loc.s("prefs.snippets.restore.item.unreadable", stamp, loc.s("prefs.snippets.restore.kind.corrupted"))
        )
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }
}
