import Foundation
import Security
import XCTest
@testable import ExpanderEngine

final class IndependentSecretTests: XCTestCase {
    private struct LegacyDocument: Encodable {
        let schemaVersion = 2
        let groups: [SnippetGroup]
    }

    private final class UnreadableFallback: SecretBackingStore {
        let ids: Set<String>
        private let lock = NSLock()
        private var accesses = 0
        var valueAccesses: Int { lock.lock(); defer { lock.unlock() }; return accesses }
        init(ids: [UUID]) { self.ids = Set(ids.map(\.uuidString)) }
        func set(_ value: String, account: String) -> OSStatus {
            lock.lock(); accesses += 1; lock.unlock()
            return errSecAuthFailed
        }
        func value(account: String) -> String? {
            lock.lock(); accesses += 1; lock.unlock()
            return nil
        }
        func contains(account: String) -> Bool { ids.contains(account) }
        func delete(account: String) -> OSStatus {
            lock.lock(); accesses += 1; lock.unlock()
            return errSecAuthFailed
        }
        func accounts() -> Set<String> { ids }
    }

    private func fixture(data: Data, backing: SecretBackingStore = InMemorySecretBackingStore()) throws -> SnippetStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "IndependentSecretTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = directory.appendingPathComponent("library.json")
        try data.write(to: file)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        return SnippetStore(location: .init(fileURL: file, expectsExistingLibrary: true),
                            deviceDefaults: defaults, localSupportDirectory: directory,
                            secretStore: SecretStore(backing: backing), secretPurgeEnabled: true)
    }

    func testCleanupDoesNotTrustCacheAfterAnUnobservedExternalSecretReference() throws {
        let secret = SecretModel(title: "External")
        let backing = InMemorySecretBackingStore(seed: [secret.id.uuidString: "synthetic"])
        let store = try fixture(data: JSONEncoder().encode(SnippetDocument(groups: [])), backing: backing)
        XCTAssertTrue(store.loadSecrets().isEmpty)
        let external = try JSONEncoder().encode(SnippetDocument(groups: [], secrets: [secret]))
        try external.write(to: store.activeLocationURL, options: .atomic)
        let result = store.retryOrphanSecretCleanup()
        XCTAssertEqual(result.attempted, 0, "An unobserved external write invalidates cleanup authority")
        XCTAssertEqual(result.deferred, 1)
        XCTAssertEqual(store.pendingSecretCleanupCount, 1)
        XCTAssertTrue(backing.contains(account: secret.id.uuidString))
        XCTAssertEqual(try Data(contentsOf: store.activeLocationURL), external)
    }

    func testBareArrayRejectsDuplicateSecretIDsBeforeBecomingAUsableLibrary() throws {
        let secret = SecretModel(title: "Duplicate").snippetAdapter
        let raw = try JSONEncoder().encode([secret, secret])
        XCTAssertThrowsError(try SnippetStore.decodeDocument(from: raw))
        let store = try fixture(data: raw)
        XCTAssertTrue(store.isLibraryReadFailed)
        XCTAssertEqual(try Data(contentsOf: store.activeLocationURL), raw)
    }

    func testDamagedOrAmbiguousEnvelopeCannotBecomeAnEmptyLibrary() throws {
        let damaged = [
            #"{}"#, #"{"schemaVersion":3,"groups":[]}"#,
            #"{"schemaVersion":3,"groups":[],"secrets":null}"#,
            #"{"schemaVersion":3,"groups":null,"secrets":[]}"#,
            #"{"schemaVersion":2,"groups":[],"snippets":[]}"#,
            #"{"schemaVersion":0,"groups":[]}"#
        ]
        for json in damaged {
            let raw = Data(json.utf8)
            XCTAssertThrowsError(try SnippetStore.decodeDocument(from: raw), json)
            let store = try fixture(data: raw)
            XCTAssertTrue(store.isLibraryReadFailed, json)
            XCTAssertFalse(store.saveGroups([]).didSave, json)
            XCTAssertEqual(try Data(contentsOf: store.activeLocationURL), raw)
        }
    }

    func testFlatSaveCanAddSnippetToASecretOnlyLibrary() throws {
        let secret = SecretModel(title: "Work")
        let backing = InMemorySecretBackingStore(seed: [secret.id.uuidString: "synthetic"])
        let store = try fixture(data: JSONEncoder().encode(SnippetDocument(groups: [], secrets: [secret])), backing: backing)
        let snippet = SnippetModel(title: "Code", triggerKeyword: ";code", replacementText: "code")
        XCTAssertTrue(store.saveSnippets(store.loadSnippets() + [snippet]).didSave)
        XCTAssertEqual(store.loadSecrets(), [secret])
        XCTAssertEqual(store.loadSnippetGroups().flatMap(\.snippets), [snippet])
        XCTAssertEqual(store.retryOrphanSecretCleanup().attempted, 0)
    }

    func testSnippetRoutingCannotBeShadowedByASecretWithNoTrigger() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw XCTSkip("Foundation Models tool API requires macOS 26") }
        let secret = SecretModel(title: "Shared").snippetAdapter
        let snippet = SnippetModel(title: "Shared helper", triggerKeyword: ";code", replacementText: "code")
        let groups = SnippetDocument(groups: [SnippetGroup(name: "Code", snippets: [snippet, secret])]).transactionGroups
        let tool = PaletteToolRouter.FindSnippetTool(groupsProvider: { groups })
        let result = try await tool.call(arguments: .init(query: "Shared"))
        XCTAssertEqual(result, ";code")
        #else
        throw XCTSkip("Foundation Models SDK unavailable")
        #endif
    }

    func testDisabledSecretsNeverAppearInTheCopyMenu() {
        let enabled = SecretModel(title: "Enabled").snippetAdapter
        let disabled = SecretModel(title: "Disabled", enabled: false).snippetAdapter
        XCTAssertEqual(SecretMenuEntryPolicy.entries(from: [disabled, enabled]).map(\.id), [enabled.id])
    }

    func testMetadataMigrationPreservesFiveUnreadableFallbackSecretsWithoutValueAccess() throws {
        let secrets = (0..<5).map {
            SnippetModel(title: "Login \($0)", triggerKeyword: ";old\($0)", replacementText: "", isSecret: true)
        }
        let backing = UnreadableFallback(ids: secrets.map(\.id))
        let raw = try JSONEncoder().encode(LegacyDocument(groups: [SnippetGroup(name: "Work", snippets: secrets)]))
        let store = try fixture(data: raw, backing: backing)
        XCTAssertEqual(Set(store.loadSecrets().map(\.id)), Set(secrets.map(\.id)))
        XCTAssertEqual(try Data(contentsOf: store.activeLocationURL), raw, "Load must be read-only")
        XCTAssertTrue(store.saveGroups(store.loadGroups()).didSave)
        XCTAssertEqual(store.retryOrphanSecretCleanup().attempted, 0)
        XCTAssertEqual(backing.valueAccesses, 0, "Metadata migration must not read, overwrite or delete fallback values")
        let persisted = try SnippetStore.decodeDocument(from: Data(contentsOf: store.activeLocationURL))
        XCTAssertEqual(persisted.schemaVersion, 3)
        XCTAssertEqual(persisted.secrets.count, 5)
        XCTAssertTrue(persisted.groups.flatMap(\.snippets).isEmpty)
    }

    func testMigrationRetainsLabelsDatesTagsAndEffectiveAppRestrictions() throws {
        let legacy = SnippetModel(title: "Login", label: "Work login", triggerKeyword: ";pw", replacementText: "",
                                  tags: ["work"], includeApps: ["com.allowed"], excludeApps: ["com.denied"], isSecret: true)
        let group = SnippetGroup(name: "Work", enabled: false, includeApps: ["com.other"], snippets: [legacy])
        let decoded = try SnippetStore.decodeDocument(from: JSONEncoder().encode(LegacyDocument(groups: [group])))
        let secret = try XCTUnwrap(decoded.secrets.first)
        XCTAssertEqual(secret.id, legacy.id)
        XCTAssertEqual(secret.displayTitle, legacy.displayTitle)
        XCTAssertEqual(secret.createdAt, legacy.createdAt)
        XCTAssertEqual(secret.updatedAt, legacy.updatedAt)
        XCTAssertEqual(secret.tags, legacy.tags)
        XCTAssertEqual(secret.excludeApps, legacy.excludeApps)
        XCTAssertFalse(secret.enabled, "Extraction must never widen a disabled or disjoint group scope")
        XCTAssertEqual(secret.snippetAdapter.triggerKeyword, "")
    }

    func testLegacyFlatAndBareLibrariesMigrateAndResaveIdempotently() throws {
        let secret = SnippetModel(title: "", triggerKeyword: ";old-name", replacementText: "", isSecret: true)
        let bare = try JSONEncoder().encode([secret])
        let flat = Data(("{\"schemaVersion\":1,\"snippets\":" + String(decoding: bare, as: UTF8.self) + "}").utf8)
        for data in [bare, flat] {
            let migrated = try SnippetStore.decodeDocument(from: data)
            XCTAssertEqual(migrated.secrets.first?.id, secret.id)
            XCTAssertEqual(migrated.secrets.first?.displayTitle, ";old-name")
            let once = try JSONEncoder().encode(migrated)
            let twice = try JSONEncoder().encode(SnippetStore.decodeDocument(from: once))
            XCTAssertEqual(try SnippetStore.decodeDocument(from: once), try SnippetStore.decodeDocument(from: twice))
        }
    }

    func testSnippetResetAndSameNamedGroupImportRetainIndependentSecrets() throws {
        let secret = SecretModel(title: "Work")
        let backing = InMemorySecretBackingStore(seed: [secret.id.uuidString: "synthetic"])
        let store = try fixture(data: JSONEncoder().encode(SnippetDocument(groups: [], secrets: [secret])), backing: backing)
        guard case .saved = store.resetToDefaults() else { return XCTFail("Reset should save") }
        XCTAssertEqual(store.loadSecrets(), [secret])
        let imported = SnippetGroup(name: "Secrets", snippets: [SnippetModel(title: "Code", triggerKeyword: ";code", replacementText: "code")])
        XCTAssertTrue(store.importGroups([imported], mode: .replaceGroup).outcome.didSave)
        XCTAssertEqual(store.loadSecrets(), [secret])
        XCTAssertEqual(store.retryOrphanSecretCleanup().attempted, 0)
        XCTAssertTrue(backing.contains(account: secret.id.uuidString))
        XCTAssertTrue(store.loadSnippetGroups().flatMap(\.snippets).allSatisfy { !$0.isSecret })
    }

    func testDuplicateSecretIdentifiersFailClosedAndPreserveRawLibrary() throws {
        let secret = SecretModel(title: "Work")
        XCTAssertThrowsError(try JSONEncoder().encode(SnippetDocument(groups: [], secrets: [secret, secret])))
        let data = try JSONEncoder().encode(secret)
        let record = String(decoding: data, as: UTF8.self)
        let corrupt = Data("{\"schemaVersion\":3,\"groups\":[],\"secrets\":[\(record),\(record)]}".utf8)
        let store = try fixture(data: corrupt)
        XCTAssertTrue(store.isLibraryReadFailed)
        XCTAssertFalse(store.saveGroups([]).didSave)
        XCTAssertEqual(try Data(contentsOf: store.activeLocationURL), corrupt)
    }
    func testIndependentSecretRoundTripIsSearchableWithoutTrigger() throws {
        let secret = SecretModel(title: "Work login")
        let data = try JSONEncoder().encode(SnippetDocument(groups: [], secrets: [secret]))
        let decoded = try SnippetStore.decodeDocument(from: data)
        XCTAssertEqual(decoded.secrets, [secret])
        XCTAssertTrue(decoded.groups.isEmpty)
        XCTAssertEqual(decoded.transactionGroups.flatMap(\.snippets).map(\.id), [secret.id])
        let hits = SnippetSearch.run(query: "Work", in: decoded.transactionGroups, includeDisabled: false)
        XCTAssertEqual(hits.map(\.snippet.id), [secret.id])
    }

    func testBlankPaletteListsTriggerFreeSecretsButNotIncompleteSnippets() {
        let secret = SecretModel(title: "Work login")
        let incomplete = SnippetModel(title: "Draft", triggerKeyword: "", replacementText: "draft")
        let groups = SnippetDocument(groups: [SnippetGroup(name: "General", snippets: [incomplete])],
                                     secrets: [secret]).transactionGroups
        let rows = CommandPaletteCatalog.buildRows(query: "", groups: groups, commandLimit: 0)
        let ids = rows.compactMap { row -> UUID? in
            if case .snippet(let hit) = row { return hit.snippet.id }
            return nil
        }
        XCTAssertEqual(ids, [secret.id])
    }
    func testLibrarySerializesSecretsOutsideSnippetGroupsWithoutTriggers() throws {
        let secret = SnippetModel(title: "Work login", triggerKeyword: ";old-password",
                                  replacementText: "", isSecret: true)
        let plain = SnippetModel(title: "Address", triggerKeyword: ";address", replacementText: "Main St")
        let data = try SnippetStore.exportLibraryData(groups: [SnippetGroup(name: "General", snippets: [plain, secret])])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try XCTUnwrap(object["groups"] as? [[String: Any]])
        let snippets = groups.flatMap { $0["snippets"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(snippets.count, 1, "Secrets must not be bundled in snippet groups")
        let secrets = try XCTUnwrap(object["secrets"] as? [[String: Any]])
        XCTAssertEqual(secrets.count, 1)
        XCTAssertEqual(secrets.first?["id"] as? String, secret.id.uuidString)
        XCTAssertNil(secrets.first?["triggerKeyword"])
        XCTAssertNil(secrets.first?["replacementText"])
    }
}
