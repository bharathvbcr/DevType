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

    // MARK: - Reveal toggle

    /// Revealing swaps the concealed field for its plain twin rather than adding one, so the
    /// editor still authors exactly three fields and nothing walking the view tree finds a
    /// second copy of the value.
    func testRevealingSwapsTheFieldInPlaceAndLeavesNoSecondCopy() throws {
        let store = try store()
        let editor = SecretEditorController(existing: nil, store: store, resources: Values().access, onDismiss: {})
        _ = editor.view
        editor.valueField.stringValue = "synthetic-reveal"

        let reveal = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? NSButton }
            .first { $0.title == LocalizationManager.shared.s("secrets.value.show") })
        reveal.performClick(nil)

        XCTAssertEqual(editor.revealedField.stringValue, "synthetic-reveal", "the typed value must survive the swap")
        XCTAssertEqual(editor.valueField.stringValue, "", "the concealed twin must not keep a copy")
        XCTAssertEqual(editor.secretValue, "synthetic-reveal")

        let editable = descendants(editor.view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(editable.count, 3, "revealing must not add a fourth authored field")
        XCTAssertFalse(editable.contains { $0 is NSSecureTextField }, "the concealed twin must leave the tree")
        XCTAssertTrue(descendants(editor.view).compactMap { $0 as? NSButton }
            .contains { $0.title == LocalizationManager.shared.s("secrets.value.hide") })

        reveal.performClick(nil)
        XCTAssertEqual(editor.valueField.stringValue, "synthetic-reveal", "hiding must carry it back")
        XCTAssertEqual(editor.revealedField.stringValue, "", "the plain twin must not keep a copy")
        let afterHide = descendants(editor.view).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(afterHide.count, 3)
        XCTAssertTrue(afterHide.contains { $0 is NSSecureTextField })
    }

    /// A value typed while revealed must still be the value that is stored.
    func testASecretAuthoredWhileRevealedSavesAndClearsBothTwins() throws {
        let store = try store()
        let values = Values()
        var dismissed = false
        let editor = SecretEditorController(existing: nil, store: store, resources: values.access) { dismissed = true }
        _ = editor.view
        let reveal = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? NSButton }
            .first { $0.title == LocalizationManager.shared.s("secrets.value.show") })
        reveal.performClick(nil)
        editor.nameField.stringValue = "Revealed login"
        editor.revealedField.stringValue = "synthetic-revealed-value"
        editor.saveTapped()

        XCTAssertTrue(dismissed)
        let secret = try XCTUnwrap(store.loadSecrets().first)
        XCTAssertEqual(values.values[secret.id], "synthetic-revealed-value")
        XCTAssertEqual(editor.valueField.stringValue, "")
        XCTAssertEqual(editor.revealedField.stringValue, "", "a dismissed editor must keep no value anywhere")
        let data = try Data(contentsOf: store.activeLocationURL)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-revealed-value"))
    }

    /// Cancelling while revealed must not leave the value behind either.
    func testCancellingWhileRevealedClearsBothTwins() throws {
        let store = try store()
        let editor = SecretEditorController(existing: nil, store: store, resources: Values().access, onDismiss: {})
        _ = editor.view
        try XCTUnwrap(descendants(editor.view).compactMap { $0 as? NSButton }
            .first { $0.title == LocalizationManager.shared.s("secrets.value.show") }).performClick(nil)
        editor.revealedField.stringValue = "synthetic-abandoned"
        editor.cancelTapped()
        XCTAssertEqual(editor.revealedField.stringValue, "")
        XCTAssertEqual(editor.valueField.stringValue, "")
    }

    // MARK: - Revealing a stored value

    /// The editor never prefills, so Show on an already-stored secret used to flip the caption
    /// and the icon over a blank field while the notice claimed the value was on screen. It must
    /// fetch the stored value and put it there.
    func testShowingAStoredSecretAuthenticatesAndRevealsTheStoredValue() throws {
        let secret = SecretModel(title: "Work login")
        var gatedReads: [UUID] = []
        let editor = SecretEditorController(
            existing: secret, store: try store(secrets: [secret]), resources: Values().access,
            revealStoredValue: { snippet, completion in
                XCTAssertTrue(snippet.isSecret, "the reveal must take the gated secret path")
                gatedReads.append(snippet.id)
                completion(.success("synthetic-stored-value"))
            }, onDismiss: {})
        _ = editor.view
        XCTAssertEqual(editor.valueField.stringValue, "", "opening one must still never prefill")

        try revealButton(editor).performClick(nil)

        XCTAssertEqual(gatedReads, [secret.id], "exactly one gated read, for this secret")
        XCTAssertEqual(editor.revealedField.stringValue, "synthetic-stored-value")
        XCTAssertEqual(editor.secretValue, "synthetic-stored-value")
        XCTAssertTrue(descendants(editor.view).compactMap { $0 as? NSButton }
            .contains { $0.title == LocalizationManager.shared.s("secrets.value.hide") },
                      "the button must now offer Hide")
    }

    /// A dismissed prompt is not an empty secret. Nothing may reach the screen, and nothing may
    /// be said back to the user about a decision they just made themselves.
    func testACancelledPromptLeavesTheValueConcealedAndSaysNothing() throws {
        let secret = SecretModel(title: "Work login")
        let editor = SecretEditorController(
            existing: secret, store: try store(secrets: [secret]), resources: Values().access,
            revealStoredValue: { _, completion in completion(.failure(.authenticationCancelled)) },
            onDismiss: {})
        _ = editor.view

        try revealButton(editor).performClick(nil)

        XCTAssertEqual(editor.revealedField.stringValue, "", "no value may reach the screen")
        XCTAssertEqual(editor.secretValue, "")
        XCTAssertTrue(descendants(editor.view).compactMap { $0 as? NSTextField }
            .filter(\.isEditable).contains { $0 is NSSecureTextField },
                      "the concealed twin must still be the installed one")
        XCTAssertEqual(try errorText(editor), "", "the user's own cancellation is not an error")
        XCTAssertNoThrow(try revealButton(editor), "the button must still offer Show")
    }

    /// A locked keychain has not lost the value. Reporting it as a missing secret would send the
    /// user to re-enter something they still have, so each failure keeps the copy flow's wording.
    func testAFailedReadIsReportedAndKeepsTheValueConcealed() throws {
        let secret = SecretModel(title: "Work login")
        let cases: [(SecretMenuFlow.ResolveFailure, String)] = [
            (.keychainLocked, LocalizationManager.shared.s("secret.keychainLocked.message")),
            (.secretUnavailable, LocalizationManager.shared.s("secret.missing.message", "Work login")),
            (.selectionChanged, LocalizationManager.shared.s("manager.action.stale.message")),
            (.authenticationFailed("Biometry is locked out."), "Biometry is locked out.")
        ]
        for (failure, expected) in cases {
            let editor = SecretEditorController(
                existing: secret, store: try store(secrets: [secret]), resources: Values().access,
                revealStoredValue: { _, completion in completion(.failure(failure)) }, onDismiss: {})
            _ = editor.view

            try revealButton(editor).performClick(nil)

            XCTAssertEqual(try errorText(editor), expected, "\(failure) must explain itself")
            XCTAssertEqual(editor.secretValue, "", "\(failure) must not put a value on screen")
            XCTAssertTrue(descendants(editor.view).compactMap { $0 as? NSTextField }
                .filter(\.isEditable).contains { $0 is NSSecureTextField },
                          "\(failure) must leave the concealed twin installed")
        }
    }

    /// Showing what the user just typed is not a read of stored material, and neither is a second
    /// look at a value already fetched — neither may raise a prompt.
    func testRevealingDoesNotAskAgainForATypedOrAlreadyFetchedValue() throws {
        let secret = SecretModel(title: "Work login")
        var reads = 0
        let typed = SecretEditorController(
            existing: secret, store: try store(secrets: [secret]), resources: Values().access,
            revealStoredValue: { _, _ in reads += 1 }, onDismiss: {})
        _ = typed.view
        typed.valueField.stringValue = "typed-replacement"

        try revealButton(typed).performClick(nil)

        XCTAssertEqual(reads, 0, "a typed replacement is already on screen; nothing to fetch")
        XCTAssertEqual(typed.revealedField.stringValue, "typed-replacement")

        let fetched = SecretEditorController(
            existing: secret, store: try store(secrets: [secret]), resources: Values().access,
            revealStoredValue: { _, completion in reads += 1; completion(.success("synthetic-stored-value")) },
            onDismiss: {})
        _ = fetched.view
        try revealButton(fetched).performClick(nil)
        try XCTUnwrap(descendants(fetched.view).compactMap { $0 as? NSButton }
            .first { $0.title == LocalizationManager.shared.s("secrets.value.hide") }).performClick(nil)
        try revealButton(fetched).performClick(nil)

        XCTAssertEqual(reads, 1, "the stored value is fetched once, not once per toggle")
        XCTAssertEqual(fetched.revealedField.stringValue, "synthetic-stored-value")
    }

    /// The Show button, by the title the user reads.
    private func revealButton(_ editor: SecretEditorController) throws -> NSButton {
        try XCTUnwrap(descendants(editor.view).compactMap { $0 as? NSButton }
            .first { $0.title == LocalizationManager.shared.s("secrets.value.show") })
    }

    /// The editor's error line: the non-editable label drawn in the error colour.
    private func errorText(_ editor: SecretEditorController) throws -> String {
        try XCTUnwrap(descendants(editor.view).compactMap { $0 as? NSTextField }
            .first { !$0.isEditable && $0.textColor == .systemRed }).stringValue
    }

    // MARK: - Manager empty states and keyboard

    /// An empty library invites adding one; a search that matched nothing must not, because the
    /// user asked a different question.
    func testEmptyLibraryOffersAddWhileAnUnmatchedSearchDoesNot() throws {
        // The CTA lives inside the empty-state container, which is itself hidden when there are
        // rows — so "can the user see it" has to walk the ancestors, not read one flag.
        func ctaIsVisible(_ controller: NSViewController) throws -> Bool {
            let cta = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "secrets.empty.cta" })
            return !sequence(first: cta as NSView, next: \.superview).contains { $0.isHidden }
        }

        let empty = SecretManagerViewController(store: try store(), onCopy: { _ in }, onRepair: {})
        _ = empty.view
        XCTAssertTrue(try ctaIsVisible(empty), "an empty library must offer the way to fill it")

        let populated = SecretManagerViewController(
            store: try store(secrets: [SecretModel(title: "Bank login")]), onCopy: { _ in }, onRepair: {})
        _ = populated.view
        XCTAssertFalse(try ctaIsVisible(populated), "a populated list has nothing to prompt")

        let search = try XCTUnwrap(descendants(populated.view).compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "nothing-matches-this"
        search.sendAction(search.action, to: search.target)
        let table = try XCTUnwrap(descendants(populated.view).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertFalse(try ctaIsVisible(populated),
                       "a search that matched nothing must not answer with \"add one\"")
    }

    /// Return copies and Delete removes, but only from the list: bound as button key equivalents
    /// they would fire while the user was typing in the search field.
    func testTheListAnswersReturnAndDeleteWithoutTouchingTheSearchField() throws {
        let secret = SecretModel(title: "Bank login")
        let store = try store(secrets: [secret])
        var copied: [UUID] = []
        let manager = SecretManagerViewController(store: store, onCopy: { copied.append($0.id) }, onRepair: {})
        _ = manager.view
        let table = try XCTUnwrap(descendants(manager.view).compactMap { $0 as? NSTableView }.first)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        table.keyDown(with: try key(36))
        XCTAssertEqual(copied, [secret.id], "Return on the list must copy the selection")

        // The search field is an ordinary responder: the key equivalents must not be global.
        let search = try XCTUnwrap(descendants(manager.view).compactMap { $0 as? NSSearchField }.first)
        XCTAssertFalse(descendants(manager.view).compactMap { $0 as? NSButton }
            .contains { $0.keyEquivalent == "\u{7f}" || $0.keyEquivalent == "\u{8}" },
            "a delete key equivalent would fire while typing in \(search.className)")
    }

    private func key(_ code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "\r", charactersIgnoringModifiers: "\r",
                                       isARepeat: false, keyCode: code))
    }

    /// The shared empty state caps its subtitle at two lines and 280pt. A string that needs
    /// three is silently truncated, which would hide guidance in whichever language ran long —
    /// so every shipped table is measured, not just English.
    func testEveryLanguageEmptyStateSubtitleFitsTheSharedTwoLineCap() throws {
        let font = DevTypeTheme.font(11)
        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for key in ["secrets.empty.subtitle", "secrets.empty.noMatch.subtitle"] {
                let text = try XCTUnwrap(table[key])
                let bounding = (text as NSString).boundingRect(
                    with: NSSize(width: 280, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]
                )
                let lines = Int((bounding.height / font.boundingRectForFont.height).rounded(.up))
                XCTAssertLessThanOrEqual(
                    lines, 2,
                    "\(language.rawValue) \(key) needs \(lines) lines at 280pt and would truncate"
                )
            }
        }
    }

    func testSecretViewsFitTheirWindows() throws {
        try XCTSkipUnless(CGSessionCopyCurrentDictionary() != nil && !NSScreen.screens.isEmpty, "No WindowServer")
        let secret = SecretModel(title: "Synthetic work login", tags: ["work"])
        let store = try store(secrets: [secret])
        let editor = SecretEditorController(existing: secret, store: store, resources: Values().access, onDismiss: {})
        let manager = SecretManagerViewController(store: store, onCopy: { _ in }, onRepair: {})

        // The empty state adds a call-to-action button, and revealing adds the Hide button and a
        // notice line: both are states the populated editor and list never render, so both are
        // laid out here rather than assumed to fit.
        let emptyManager = SecretManagerViewController(store: try self.store(), onCopy: { _ in }, onRepair: {})
        let revealedEditor = SecretEditorController(existing: nil, store: store,
                                                    resources: Values().access, onDismiss: {})
        _ = revealedEditor.view
        try XCTUnwrap(descendants(revealedEditor.view).compactMap { $0 as? NSButton }
            .first { $0.title == LocalizationManager.shared.s("secrets.value.show") }).performClick(nil)

        for (name, controller, size) in [("editor", editor as NSViewController, NSSize(width: 480, height: 410)),
                                          ("editor-revealed", revealedEditor as NSViewController, NSSize(width: 480, height: 410)),
                                          ("manager", manager as NSViewController, NSSize(width: 620, height: 470)),
                                          ("manager-empty", emptyManager as NSViewController, NSSize(width: 620, height: 470))] {
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
