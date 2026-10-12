import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

/// Counting seams for the UI-side performance work: Preferences open cost, conflict-scan reuse,
/// per-language formatter caching, Activity row reuse, and the small one-call-site fixes.
@MainActor
final class UIPerformanceReuseTests: XCTestCase {

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// `LocalizationManager.language` persists to the shared defaults key, so a test that
    /// switches language must put the stored value back or it leaks into every later test.
    private var savedLanguage: String?

    override func setUp() {
        super.setUp()
        savedLanguage = UserDefaults.standard.string(forKey: LocalizationManager.deviceKey)
    }

    override func tearDown() {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: LocalizationManager.deviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LocalizationManager.deviceKey)
        }
        super.tearDown()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Preferences open

    private func freshPreferences() -> PreferencesWindowController {
        _ = NSApplication.shared
        return PreferencesWindowController()
    }

    private func viewController(of controller: PreferencesWindowController) throws -> PreferencesViewController {
        try XCTUnwrap(controller.window?.contentViewController as? PreferencesViewController)
    }

    func testOpeningPreferencesFirstTimeReloadsAllExactlyOnce() throws {
        let controller = freshPreferences()
        controller.show(tab: .ai, hotkeyManager: nil)
        defer { controller.window?.close() }
        let prefs = try viewController(of: controller)

        XCTAssertEqual(prefs.reloadAllCount, 1, "viewDidLoad, viewWillAppear and show() each reloaded")
        // The tab selected on open is populated by being built, then left alone by the pass.
        XCTAssertEqual(prefs.paneReloadCounts[.ai], 1, "first AI presentation reloaded twice")
    }

    func testFirstAdvancedPresentationDoesNotReloadTwice() throws {
        let controller = freshPreferences()
        controller.show(tab: .advanced, hotkeyManager: nil)
        defer { controller.window?.close() }
        let prefs = try viewController(of: controller)

        XCTAssertEqual(prefs.paneReloadCounts[.advanced], 1)
    }

    func testReopeningVisiblePreferencesStillReloadsOnce() throws {
        let controller = freshPreferences()
        controller.show(tab: .general, hotkeyManager: nil)
        defer { controller.window?.close() }
        let prefs = try viewController(of: controller)
        let before = prefs.reloadAllCount

        controller.show(tab: nil, hotkeyManager: nil)
        XCTAssertEqual(prefs.reloadAllCount, before + 1, "reopening must still refresh current state")

        controller.window?.close()
        controller.show(tab: nil, hotkeyManager: nil)
        XCTAssertEqual(prefs.reloadAllCount, before + 2)
    }

    func testRapidOpenCloseKeepsOneReloadPerOpen() throws {
        let controller = freshPreferences()
        controller.show(tab: .general, hotkeyManager: nil)
        defer { controller.window?.close() }
        let prefs = try viewController(of: controller)
        let before = prefs.reloadAllCount
        for _ in 0..<5 {
            controller.window?.close()
            controller.show(tab: nil, hotkeyManager: nil)
        }
        XCTAssertEqual(prefs.reloadAllCount, before + 5)
    }

    func testReselectingAnAlreadyBuiltLiveTabStillRefreshesIt() throws {
        let controller = freshPreferences()
        controller.show(tab: .advanced, hotkeyManager: nil)
        defer { controller.window?.close() }
        let prefs = try viewController(of: controller)
        prefs.select(.general)
        let before = prefs.paneReloadCounts[.advanced] ?? 0
        prefs.select(.advanced)
        XCTAssertEqual(prefs.paneReloadCounts[.advanced], before + 1, "diagnostics tabs must stay live on select")
    }

    // MARK: - Conflict scan cache

    private func makeStore(_ triggers: [String]) throws -> (SnippetStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("library.json")
        var group = SnippetGroup(name: "G")
        group.snippets = triggers.map {
            SnippetModel(title: $0, triggerKeyword: $0, replacementText: "body \($0)")
        }
        try JSONEncoder().encode(SnippetDocument(groups: [group])).write(to: file)
        return (SnippetStore(fileURL: file), directory)
    }

    func testTriggerConflictsAreComputedOncePerLibraryRevision() throws {
        let (store, directory) = try makeStore([":a", ":a"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TriggerConflictsCache()

        let first = cache.conflicts(in: store, detectionEnabled: true)
        let second = cache.conflicts(in: store, detectionEnabled: true)
        let third = cache.conflicts(in: store, detectionEnabled: true)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, third)
        XCTAssertEqual(cache.computeCount, 1)
    }

    func testTriggerConflictsRecomputeWhenTheLibraryChanges() throws {
        let (store, directory) = try makeStore([":a", ":a"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TriggerConflictsCache()
        XCTAssertFalse(cache.conflicts(in: store, detectionEnabled: true).isEmpty)

        var groups = store.loadGroups()
        groups[0].snippets = [groups[0].snippets[0]]
        XCTAssertEqual(store.saveGroups(groups), .saved)

        XCTAssertTrue(cache.conflicts(in: store, detectionEnabled: true).isEmpty, "stale conflicts served after save")
        XCTAssertEqual(cache.computeCount, 2)
    }

    func testDisabledDetectionNeverScans() throws {
        let (store, directory) = try makeStore([":a", ":a"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TriggerConflictsCache()
        XCTAssertTrue(cache.conflicts(in: store, detectionEnabled: false).isEmpty)
        XCTAssertEqual(cache.computeCount, 0)
        XCTAssertFalse(cache.conflicts(in: store, detectionEnabled: true).isEmpty)
    }

    // MARK: - Formatter cache

    func testStatsFormattersAreBuiltOncePerLanguage() {
        _ = NSApplication.shared
        let cache = LocalizedFormatterCache.shared
        cache.removeAll()
        let localization = LocalizationManager()
        localization.language = .ko
        let formatter = StatsLocalizedFormatter(localization: localization)
        let before = cache.buildCount

        for value in 0..<50 { _ = formatter.number(value) }
        XCTAssertEqual(cache.buildCount - before, 1)
    }

    func testFormatterCacheFollowsLanguageSwitch() {
        _ = NSApplication.shared
        LocalizedFormatterCache.shared.removeAll()
        let localization = LocalizationManager()
        let formatter = StatsLocalizedFormatter(localization: localization)

        localization.language = .en
        let english = formatter.number(1_234_567)
        localization.language = .ja
        let japanese = formatter.relativeDate(Date(timeIntervalSince1970: 0), relativeTo: Date(timeIntervalSince1970: 3_600))
        localization.language = .en
        XCTAssertEqual(formatter.number(1_234_567), english)

        let expected = RelativeDateTimeFormatter()
        expected.locale = Locale(identifier: "ja")
        expected.unitsStyle = .abbreviated
        XCTAssertEqual(
            japanese,
            expected.localizedString(for: Date(timeIntervalSince1970: 0), relativeTo: Date(timeIntervalSince1970: 3_600))
        )
    }

    func testActivityTimestampsShareOneFormatterAndStillFollowLanguage() {
        _ = NSApplication.shared
        LocalizedFormatterCache.shared.removeAll()
        let localization = LocalizationManager()
        let before = LocalizedFormatterCache.shared.buildCount
        let event = ActivityHistoryStore.ActivityEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            category: .general,
            title: "t",
            details: "d"
        )

        localization.language = .en
        let en = ActivityEventRowPresentation(event: event, localization: localization).timestampText
        _ = ActivityEventRowPresentation(event: event, localization: localization)
        _ = ActivityEventRowPresentation(event: event, localization: localization)
        XCTAssertEqual(LocalizedFormatterCache.shared.buildCount - before, 1)

        localization.language = .ko
        let ko = ActivityEventRowPresentation(event: event, localization: localization).timestampText
        XCTAssertNotEqual(en, ko, "language switch must not serve the previous language's formatter")
        XCTAssertEqual(LocalizedFormatterCache.shared.buildCount - before, 2)
    }

    // MARK: - Activity rows

    func testActivityTableDequeuesRowsByCategoryIdentifier() throws {
        let text = try source("Sources/DevTypeAppCore/ActivityCenterViewController.swift")
        XCTAssertTrue(text.contains("tableView.makeView(withIdentifier: identifier, owner: self)"))
        let row = ActivityEventRowView(
            event: ActivityHistoryStore.ActivityEvent(category: .expansion, title: "T", details: "D"),
            localization: .shared,
            onAction: { _ in }
        )
        XCTAssertEqual(row.identifier, ActivityEventRowView.reuseIdentifier(for: .expansion))
        XCTAssertNotEqual(
            ActivityEventRowView.reuseIdentifier(for: .expansion),
            ActivityEventRowView.reuseIdentifier(for: .voice),
            "the card tint is fixed per row, so categories must not share a reuse queue"
        )
    }

    func testConfiguringARowReplacesEveryFieldAndTheActionButton() throws {
        _ = NSApplication.shared
        let withAction = ActivityHistoryStore.ActivityEvent(
            category: .general, title: "First", details: "one", action: .openLab
        )
        let plain = ActivityHistoryStore.ActivityEvent(category: .general, title: "Second", details: "two")
        let row = ActivityEventRowView(event: withAction, localization: .shared, onAction: { _ in })
        var received: [String] = []

        row.configure(event: plain, localization: .shared, onAction: { received.append($0.title) })
        let labels = descendants(of: row).compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains("Second"))
        XCTAssertFalse(labels.contains("First"))
        let button = try XCTUnwrap(descendants(of: row).compactMap { $0 as? CapsuleButton }.first)
        XCTAssertTrue(button.isHidden, "a reused row kept the previous event's action button")

        row.configure(event: withAction, localization: .shared, onAction: { received.append($0.title) })
        XCTAssertFalse(button.isHidden)
        button.performClick(nil)
        XCTAssertEqual(received, ["First"], "the button must report the row's current event")
    }

    func testActivityViewWillAppearReloadsTheTableOnce() throws {
        let text = try source("Sources/DevTypeAppCore/ActivityCenterViewController.swift")
        let range = try XCTUnwrap(text.range(of: "override func viewWillAppear()"))
        let body = String(text[range.lowerBound...].prefix(260))
        XCTAssertFalse(body.contains("refreshLocalization()"), "viewWillAppear reloaded twice")
        XCTAssertTrue(body.contains("applyLocalizedChrome()"))
    }

    // MARK: - One-call-site fixes

    func testHomeLoadsGroupsOncePerEditorPresentation() throws {
        let text = try source("Sources/DevTypeAppCore/HomeViewController.swift")
        let count = text.components(separatedBy: "store.loadGroups()").count - 1
        XCTAssertEqual(count, 2, "newSnippetTapped and templatesTapped each read the library once")
        XCTAssertFalse(text.contains("currentGroupID: self.store.loadGroups()"))
        XCTAssertFalse(text.contains("currentGroupID: store.loadGroups()"))
    }

    func testNestedSnippetResolverIsCachedByLibraryRevision() throws {
        let text = try source("Sources/DevTypeAppCore/AppDelegate.swift")
        XCTAssertFalse(text.contains("NestedSnippetResolver(snippets: SnippetStore.shared.loadSnippets())"))
        XCTAssertFalse(text.contains("NestedSnippetResolver(\n            snippets: SnippetStore.shared.loadSnippets()"))
        XCTAssertTrue(text.contains("cached.revision == revision"))
    }

    func testSecretsWindowRestoresItsFrame() throws {
        let text = try source("Sources/DevTypeAppCore/AppDelegate.swift")
        let range = try XCTUnwrap(text.range(of: "@objc func openSecretManager"))
        let body = String(text[range.lowerBound...].prefix(1_200))
        XCTAssertTrue(body.contains("dtRestoreFrame(named: \"DevTypeSecretsWindow\")"))
        XCTAssertFalse(body.contains("window.center()"))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
