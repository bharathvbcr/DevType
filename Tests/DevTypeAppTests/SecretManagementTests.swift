import AppKit
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

@MainActor
final class SecretManagementTests: XCTestCase {
    private final class Values {
        var values: [UUID: String] = [:]
        var reads = 0
        var writes = 0
        var unavailable = false
        var failWrite = false
        var access: SnippetEditResourceAccess {
            .init(importImage: { _ in .failure(.unavailable) }, deleteImage: { _ in .failure(.unavailable) },
                  readSecret: { [self] id in
                      reads += 1
                      if unavailable { return .unavailable }
                      return values[id].map(SnippetEditSecretSnapshot.value) ?? .missing
                  }, storeSecret: { [self] value, id in
                      writes += 1
                      if failWrite { return .failure(.unavailable) }
                      values[id] = value
                      return .success(())
                  }, removeSecret: { [self] id in values.removeValue(forKey: id); return .success(()) },
                  protectSecretFromOrphanPurge: { _ in nil })
        }
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private func store(secrets: [SecretModel] = [], snippets: [SnippetModel] = []) throws -> SnippetStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode(SnippetDocument(groups: [SnippetGroup(name: "General", snippets: snippets)],
                                                secrets: secrets)).write(to: file)
        let suite = "SecretManagementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        return SnippetStore(location: .init(fileURL: file, expectsExistingLibrary: true),
                            deviceDefaults: defaults, localSupportDirectory: directory,
                            secretStore: SecretStore(backing: InMemorySecretBackingStore()))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testEditorCreatesSecretWithoutTriggerOrSnippetAndNeverPrefillsValue() throws {
        let store = try store()
        let values = Values()
        var dismissed = false
        let editor = SecretEditorController(existing: nil, store: store, resources: values.access) { dismissed = true }
        let fields = descendants(editor.view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(fields.count, 3, "Only name, secure value and tags are authored")
        XCTAssertTrue(fields.contains { $0 is NSSecureTextField })
        XCTAssertTrue(descendants(editor.view).compactMap { $0 as? NSButton }
            .contains { $0.title == LocalizationManager.shared.s("secrets.save") })
        XCTAssertEqual(values.reads, 0)
        editor.nameField.stringValue = "Synthetic login"
        editor.valueField.stringValue = "synthetic-{{verbatim}}"
        editor.saveTapped()
        XCTAssertTrue(dismissed)
        let secret = try XCTUnwrap(store.loadSecrets().first)
        XCTAssertEqual(values.values[secret.id], "synthetic-{{verbatim}}")
        XCTAssertEqual(secret.displayTitle, "Synthetic login")
        XCTAssertTrue(store.loadSnippetGroups().flatMap(\.snippets).isEmpty)
        XCTAssertEqual(editor.valueField.stringValue, "")
        let data = try Data(contentsOf: store.activeLocationURL)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-{{verbatim}}"))
    }

    func testEmptyNameEmptyValueAndOversizedNameCannotCreateASecret() throws {
        let store = try store()
        let values = Values()
        let editor = SecretEditorController(existing: nil, store: store, resources: values.access) { XCTFail("Invalid draft dismissed") }
        _ = editor.view
        editor.saveTapped()
        editor.nameField.stringValue = "Login"
        editor.saveTapped()
        editor.nameField.stringValue = String(repeating: "x", count: 257)
        editor.valueField.stringValue = "synthetic"
        editor.saveTapped()
        XCTAssertTrue(store.loadSecrets().isEmpty)
        XCTAssertEqual(values.writes, 0)
    }

    func testCancelDropsDraftWithoutWritingOrChangingSnippets() throws {
        let plain = SnippetModel(title: "Code", triggerKeyword: ";code", replacementText: "original")
        let store = try store(snippets: [plain])
        let before = try Data(contentsOf: store.activeLocationURL)
        let values = Values()
        var dismissed = false
        let editor = SecretEditorController(existing: nil, store: store, resources: values.access) { dismissed = true }
        _ = editor.view
        editor.valueField.stringValue = "discard synthetic"
        editor.cancelTapped()
        XCTAssertTrue(dismissed)
        XCTAssertEqual(editor.valueField.stringValue, "")
        XCTAssertEqual(values.writes, 0)
        XCTAssertEqual(try Data(contentsOf: store.activeLocationURL), before)
    }

    func testMetadataEditKeepsStoredValueAndAppScope() throws {
        let secret = SecretModel(title: "Old", includeApps: ["com.allowed"], excludeApps: ["com.blocked"])
        let store = try store(secrets: [secret])
        let values = Values()
        values.values[secret.id] = "synthetic"
        var dismissed = false
        let editor = SecretEditorController(existing: secret, store: store, resources: values.access) { dismissed = true }
        _ = editor.view
        XCTAssertEqual(editor.valueField.stringValue, "")
        XCTAssertEqual(values.reads, 0)
        editor.nameField.stringValue = "Renamed"
        editor.saveTapped()
        XCTAssertTrue(dismissed)
        XCTAssertEqual(values.writes, 0)
        XCTAssertEqual(values.values[secret.id], "synthetic")
        let updated = try XCTUnwrap(store.loadSecrets().first)
        XCTAssertEqual(updated.id, secret.id)
        XCTAssertEqual(updated.title, "Renamed")
        XCTAssertEqual(updated.includeApps, secret.includeApps)
        XCTAssertEqual(updated.excludeApps, secret.excludeApps)
    }

    func testFailedPersistenceRollsBackReplacementAndPreservesNewerMetadata() throws {
        let secret = SecretModel(title: "Old")
        let store = try store(secrets: [secret])
        let values = Values()
        values.values[secret.id] = "original synthetic"
        let editor = SecretEditorController(existing: secret, store: store, resources: values.access) { XCTFail("Stale draft dismissed") }
        _ = editor.view
        editor.valueField.stringValue = "replacement synthetic"
        var newer = secret
        newer.title = "Concurrent rename"
        _ = store.mutateGroups { SecretLibraryEdit.applying(newer, replacing: secret, to: &$0) }
        editor.saveTapped()
        XCTAssertEqual(values.values[secret.id], "original synthetic")
        XCTAssertEqual(store.loadSecrets(), [newer])
    }

    func testUnavailableFallbackAndFailedValueWriteLeaveMetadataUntouched() throws {
        let secret = SecretModel(title: "Login")
        for unavailable in [true, false] {
            let store = try store(secrets: [secret])
            let before = try Data(contentsOf: store.activeLocationURL)
            let values = Values()
            values.values[secret.id] = "original synthetic"
            values.unavailable = unavailable
            values.failWrite = !unavailable
            let editor = SecretEditorController(existing: secret, store: store, resources: values.access) { XCTFail("Failed save dismissed") }
            _ = editor.view
            editor.valueField.stringValue = "replacement synthetic"
            editor.saveTapped()
            XCTAssertEqual(values.values[secret.id], "original synthetic")
            XCTAssertEqual(try Data(contentsOf: store.activeLocationURL), before)
            XCTAssertFalse(descendants(editor.view).compactMap { $0 as? NSTextField }
                .filter { !$0.isEditable }.allSatisfy { $0.stringValue.isEmpty })
        }
    }

    func testManagerListsOnlySecretsAndOffersMouseCopyAndExistingRepairRoute() throws {
        let secret = SecretModel(title: "Synthetic login")
        let store = try store(secrets: [secret], snippets: [SnippetModel(title: "Code", triggerKeyword: ";code", replacementText: "code")])
        var copied: SecretModel?
        var repairs = 0
        let manager = SecretManagerViewController(store: store, onCopy: { copied = $0 }, onRepair: { repairs += 1 })
        let views = descendants(manager.view)
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 1)
        let buttons = views.compactMap { $0 as? NSButton }
        let copy = try XCTUnwrap(buttons.first { $0.title == LocalizationManager.shared.s("menu.copySecret") })
        XCTAssertFalse(copy.isEnabled)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(copy.isEnabled)
        copy.performClick(nil)
        XCTAssertEqual(copied, secret)
        try XCTUnwrap(buttons.first { $0.title == LocalizationManager.shared.s("secrets.repair") }).performClick(nil)
        XCTAssertEqual(repairs, 1)
        let search = try XCTUnwrap(views.compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "Code"
        search.sendAction(search.action, to: search.target)
        XCTAssertEqual(table.numberOfRows, 0)
    }

    func testFilteringCannotRetargetAnExistingSelectionToAnotherSecret() throws {
        let first = SecretModel(title: "Alpha")
        let second = SecretModel(title: "Beta")
        let store = try store(secrets: [first, second])
        var copied: [UUID] = []
        let manager = SecretManagerViewController(store: store, onCopy: { copied.append($0.id) }, onRepair: {})
        let views = descendants(manager.view)
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        let search = try XCTUnwrap(views.compactMap { $0 as? NSSearchField }.first)
        let copy = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == LocalizationManager.shared.s("menu.copySecret") })
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        search.stringValue = "Beta"
        search.sendAction(search.action, to: search.target)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.selectedRow, -1, "Filtering out Alpha must not select Beta in the same row")
        XCTAssertFalse(copy.isEnabled)
        copy.performClick(nil)
        XCTAssertTrue(copied.isEmpty)
    }

    func testDeletingSecretMetadataPreservesSnippetAndRefusesStaleDeletion() {
        let secret = SecretModel(title: "Login")
        let plain = SnippetModel(title: "Code", triggerKeyword: ";code", replacementText: "code")
        let original = [SnippetGroup(name: "General", snippets: [plain])]
        var groups = SnippetDocument(groups: original, secrets: [secret]).transactionGroups
        var stale = secret
        stale.title = "Old title"
        XCTAssertFalse(SecretLibraryEdit.applying(nil, replacing: stale, to: &groups))
        XCTAssertTrue(SecretLibraryEdit.applying(nil, replacing: secret, to: &groups))
        XCTAssertEqual(groups, original)
    }

    func testSnippetCreationWithOnlySecretsUsesAnOrdinaryGroupAndPreservesSecrets() throws {
        let secret = SecretModel(title: "Login")
        let groups = SnippetDocument(groups: [], secrets: [secret]).transactionGroups
        let plain = SnippetModel(title: "Code", triggerKeyword: ";code", replacementText: "code")
        let after = try XCTUnwrap(SnippetLibraryEdit.applying(snippet: plain, existingID: nil,
            chosenGroupID: nil, fallbackGroupID: groups.first?.id, to: groups))
        let document = SnippetDocument(groups: after)
        XCTAssertEqual(document.groups.first?.name, SnippetDocument.defaultGroupName)
        XCTAssertEqual(document.groups.flatMap(\.snippets), [plain])
        XCTAssertEqual(document.secrets, [secret])
        XCTAssertNoThrow(try JSONEncoder().encode(document))
    }

    func testSecretViewsFitTheirWindows() throws {
        try XCTSkipUnless(CGSessionCopyCurrentDictionary() != nil && !NSScreen.screens.isEmpty, "No WindowServer")
        let secret = SecretModel(title: "Synthetic work login", tags: ["work"])
        let store = try store(secrets: [secret])
        let editor = SecretEditorController(existing: secret, store: store, resources: Values().access, onDismiss: {})
        let manager = SecretManagerViewController(store: store, onCopy: { _ in }, onRepair: {})
        for (name, controller, size) in [("editor", editor as NSViewController, NSSize(width: 480, height: 410)),
                                          ("manager", manager as NSViewController, NSSize(width: 620, height: 470))] {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            controller.view.layoutSubtreeIfNeeded()
            for button in descendants(controller.view).compactMap({ $0 as? NSButton }) where !button.isHidden {
                let frame = button.convert(button.bounds, to: controller.view)
                XCTAssertTrue(controller.view.bounds.contains(frame), "\(name): \(button.title) must remain visible")
            }
            if let directory = ProcessInfo.processInfo.environment["DEVTYPE_SECRET_UI_SNAPSHOT_DIR"] {
                let view = controller.view
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("secret-\(name).png"))
            }
        }
    }
}
