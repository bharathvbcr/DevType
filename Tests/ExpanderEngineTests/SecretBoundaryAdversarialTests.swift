import Foundation
import XCTest
@testable import ExpanderEngine

/// Attacks on the secret/snippet boundary.
///
/// Every test here starts from a shape the ordinary code paths do not produce — a secret that
/// kept a value in memory, a group squatting on the reserved projection identifier, a secret that
/// still carries a trigger — and asserts the boundary holds anyway. The point is not that these
/// shapes are expected; it is that the invariant must not depend on them being absent.
final class SecretBoundaryAdversarialTests: XCTestCase {

    // MARK: - Helpers

    /// A secret that kept the fields `SnippetModel.init` would have cleared.
    ///
    /// `isSecret` is set *after* construction, so the initialiser's scrubbing never runs. This is
    /// the worst in-memory shape a programming error could produce.
    private func leakySecret(
        trigger: String = ";pw",
        body: String = "hunter2-do-not-serialize",
        image: String = "leak.png",
        transform: String = "rewrite"
    ) -> SnippetModel {
        var model = SnippetModel(title: "Leaky", triggerKeyword: trigger, replacementText: body,
                                 imagePath: image, aiTransform: transform)
        model.isSecret = true
        return model
    }

    private func library(_ data: Data) throws -> (store: SnippetStore, secrets: SecretStore, file: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "SecretBoundaryAdversarialTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = directory.appendingPathComponent("library.json")
        try data.write(to: file)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let secrets = SecretStore(backing: InMemorySecretBackingStore())
        let store = SnippetStore(location: .init(fileURL: file, expectsExistingLibrary: true),
                                 deviceDefaults: defaults, localSupportDirectory: directory,
                                 secretStore: secrets, secretPurgeEnabled: true)
        return (store, secrets, file)
    }

    // MARK: - A value that exists in memory must not reach any durable surface

    /// The struct retains what was assigned behind the initialiser's back — that is the premise,
    /// not the defect. The defect would be any of it surviving the document boundary.
    func testASecretHoldingAValueInMemoryCannotCarryItIntoTheDocument() throws {
        let leaky = leakySecret()
        XCTAssertFalse(leaky.replacementText.isEmpty, "premise: the value is present in memory")

        let document = SnippetDocument(groups: [SnippetGroup(name: "General", snippets: [leaky])])

        XCTAssertEqual(document.secrets.count, 1, "it must be re-homed as independent metadata")
        XCTAssertTrue(document.groups.flatMap(\.snippets).isEmpty, "and must leave the snippet groups")

        let adapter = try XCTUnwrap(document.secrets.first).snippetAdapter
        XCTAssertTrue(adapter.replacementText.isEmpty)
        XCTAssertTrue(adapter.imagePath.isEmpty)
        XCTAssertTrue(adapter.aiTransform.isEmpty)
        XCTAssertTrue(adapter.triggerKeyword.isEmpty)
        XCTAssertFalse(adapter.isTypedTriggerExpandable)
    }

    func testASecretHoldingAValueInMemoryCannotSerializeItToTheLibrary() throws {
        let document = SnippetDocument(groups: [SnippetGroup(name: "General", snippets: [leakySecret()])])
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(document), encoding: .utf8))

        XCTAssertFalse(json.contains("hunter2-do-not-serialize"), "a value reached the library JSON")
        XCTAssertFalse(json.contains("leak.png"))
        XCTAssertFalse(json.contains("rewrite"))
        XCTAssertFalse(json.contains(";pw"), "a secret must not publish a trigger either")
    }

    /// The save path, not just the in-memory projection: what lands on disk is what a backup,
    /// an export, or a support bundle would carry.
    func testASecretHoldingAValueInMemoryCannotSerializeItThroughARealSave() throws {
        let (store, secretStore, file) = try library(try JSONEncoder().encode(SnippetDocument(groups: [])))
        let leaky = leakySecret()
        // Publishing metadata that references a value-less secret is refused on purpose (see
        // `testPublishingASecretWithNoStoredValueIsRefused`), so store the value the way the
        // editor's transaction does before the metadata save.
        XCTAssertNoThrow(try secretStore.store("hunter2-do-not-serialize", for: leaky.id).get())
        XCTAssertTrue(store.saveSnippets([leaky]).didSave)

        let onDisk = try XCTUnwrap(String(data: try Data(contentsOf: file), encoding: .utf8))
        XCTAssertFalse(onDisk.contains("hunter2-do-not-serialize"), "a value reached the library file")
        XCTAssertFalse(onDisk.contains("leak.png"))
        XCTAssertFalse(onDisk.contains(";pw"))
        XCTAssertEqual(store.loadSecrets().count, 1, "the secret itself must survive as metadata")
        XCTAssertTrue(store.loadSnippetGroups().flatMap(\.snippets).isEmpty)
    }

    /// Metadata must never outlive its value: a secret whose value was never stored would be an
    /// orphan the copy path could only fail on. The save is refused rather than half-committed.
    func testPublishingASecretWithNoStoredValueIsRefused() throws {
        let (store, _, file) = try library(try JSONEncoder().encode(SnippetDocument(groups: [])))
        let before = try Data(contentsOf: file)

        XCTAssertFalse(store.saveSnippets([leakySecret()]).didSave)

        XCTAssertEqual(try Data(contentsOf: file), before, "a refused save must not touch the library")
        XCTAssertTrue(store.loadSecrets().isEmpty)
    }

    // MARK: - The matcher door

    /// The engine filters at its setter. A secret that still carries a trigger must not become
    /// typeable just because the trigger is non-empty.
    func testTheMatcherRefusesASecretEvenWhenItStillCarriesATrigger() {
        let engine = EventTapEngine()
        let ordinary = SnippetModel(title: "Ordinary", triggerKeyword: ";ok", replacementText: "fine")
        engine.snippets = [leakySecret(), ordinary]

        XCTAssertEqual(engine.snippets.map(\.id), [ordinary.id],
                       "a secret reached the matcher's snapshot")
        XCTAssertFalse(engine.snippets.contains { $0.isSecret })
    }

    /// Nested `{{snippet:…}}` resolution is the other door into expansion.
    func testNestedResolutionRefusesASecretEvenWhenItStillCarriesATriggerAndBody() {
        let resolver = NestedSnippetResolver(snippets: [leakySecret()])
        XCTAssertNil(resolver.replacement(for: ";pw"))
        XCTAssertNil(resolver.replacement(for: ""))
    }

    // MARK: - The reserved projection identifier

    /// `transactionGroups` appends the secret projection under a reserved ID. A user group that
    /// somehow holds that ID must not produce two groups sharing it: every mutation resolves a
    /// group by `firstIndex(where: { $0.id == ... })`, so a duplicate silently retargets writes.
    func testAGroupSquattingOnTheReservedIDKeepsItsSnippetsWithoutDuplicatingTheProjection() throws {
        let ordinary = SnippetModel(title: "Ordinary", triggerKeyword: ";o", replacementText: "o")
        let document = SnippetDocument(
            groups: [SnippetGroup(id: SnippetDocument.secretGroupID, name: "Squatter", snippets: [ordinary])],
            secrets: [SecretModel(title: "Secret")]
        )

        XCTAssertEqual(document.groups.count, 1)
        let rehomed = try XCTUnwrap(document.groups.first)
        XCTAssertNotEqual(rehomed.id, SnippetDocument.secretGroupID, "the reserved ID must be surrendered")
        XCTAssertEqual(rehomed.snippets.map(\.id), [ordinary.id], "user snippets must not be dropped")

        let ids = document.transactionGroups.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "the projection produced duplicate group IDs")
        XCTAssertEqual(ids.filter { $0 == SnippetDocument.secretGroupID }.count, 1)

        // And the document is now well-formed enough to persist, rather than failing every save.
        XCTAssertNoThrow(try JSONEncoder().encode(document))
    }

    /// A group holding only secrets under the reserved ID is the projection round-tripping back
    /// in, not user data: it is folded away rather than re-homed.
    func testTheProjectionGroupRoundTripsWithoutAccumulatingEmptyGroups() throws {
        let secret = SecretModel(title: "Secret")
        let once = SnippetDocument(groups: [], secrets: [secret])
        let twice = SnippetDocument(groups: once.transactionGroups)
        let thrice = SnippetDocument(groups: twice.transactionGroups)

        XCTAssertEqual(twice.secrets, [secret])
        XCTAssertEqual(thrice.secrets, [secret])
        XCTAssertTrue(thrice.groups.isEmpty, "the projection must not accumulate as a user group")
        XCTAssertEqual(thrice.transactionGroups.count, 1)
    }

    /// Disk is untrusted input: the reserved ID must still be refused there rather than re-homed,
    /// because a file claiming it is malformed, not recoverable user intent.
    func testTheReservedIDIsStillRejectedWhenItArrivesFromDisk() throws {
        let payload: [String: Any] = [
            "schemaVersion": 3,
            "groups": [["id": SnippetDocument.secretGroupID.uuidString, "name": "Squatter", "snippets": []]],
            "secrets": []
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertThrowsError(try JSONDecoder().decode(SnippetDocument.self, from: data))
    }

    // MARK: - Backup and share are different documents

    /// The backup envelope must keep secret *metadata* (losing it on restore would strand the
    /// user's secrets) and must never keep a value. The share envelope must keep neither.
    ///
    /// These two live one method apart on the same type and differ only in `loadGroups()` versus
    /// `loadSnippetGroups()`, which is exactly why the distinction is pinned rather than trusted.
    func testTheBackupEnvelopeKeepsSecretMetadataWhileTheShareEnvelopeKeepsNothing() throws {
        let (store, secretStore, _) = try library(try JSONEncoder().encode(SnippetDocument(groups: [])))
        let secret = SecretModel(title: "Bank login", tags: ["finance"])
        let snippet = SnippetModel(title: "Sig", triggerKeyword: ";sig", replacementText: "Regards")
        XCTAssertNoThrow(try secretStore.store("hunter2-do-not-serialize", for: secret.id).get())
        XCTAssertTrue(store.saveGroups(
            SnippetDocument(groups: [SnippetGroup(name: "General", snippets: [snippet])],
                            secrets: [secret]).transactionGroups
        ).didSave)

        // Backup: metadata present, value absent.
        let backup = try XCTUnwrap(String(data: try store.exportLibraryData(), encoding: .utf8))
        XCTAssertTrue(backup.contains("Bank login"), "a backup that drops secrets cannot restore them")
        XCTAssertFalse(backup.contains("hunter2-do-not-serialize"), "a value reached the backup")

        // Share: no secret record at all.
        let shared = try XCTUnwrap(String(
            data: try SnippetStore.exportLibraryData(groups: store.loadSnippetGroups()),
            encoding: .utf8
        ))
        XCTAssertFalse(shared.contains("Bank login"), "a shared export named a secret")
        XCTAssertFalse(shared.contains("finance"))
        XCTAssertFalse(shared.contains("hunter2-do-not-serialize"))
        XCTAssertTrue(shared.contains(";sig"), "the ordinary snippet must still be exported")
    }

    // MARK: - Differential round-trip fuzz

    /// Randomised libraries mixing snippets and secrets must survive save → load with both sets
    /// preserved exactly, and with no secret value or trigger anywhere in the bytes.
    func testRandomisedLibrariesRoundTripWithBothCollectionsIntact() throws {
        var seed: UInt64 = 0x5EC2_E7A1_0BAD_F00D
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(bound, 1)))
        }

        for iteration in 0..<200 {
            var snippets: [SnippetModel] = []
            var secrets: [SecretModel] = []
            for index in 0..<next(6) {
                snippets.append(SnippetModel(title: "S\(index)", triggerKeyword: ";t\(iteration)x\(index)",
                                             replacementText: "body\(index)"))
            }
            for index in 0..<next(5) {
                secrets.append(SecretModel(title: "K\(index)", enabled: next(2) == 0,
                                           tags: next(2) == 0 ? ["tag\(index)"] : []))
            }
            // Occasionally smuggle in a secret that kept a value in memory.
            if next(3) == 0 { snippets.append(leakySecret(trigger: ";leak\(iteration)")) }

            let groups = snippets.isEmpty ? [] : [SnippetGroup(name: "General", snippets: snippets)]
            let document = SnippetDocument(groups: groups, secrets: secrets)

            let data = try JSONEncoder().encode(document)
            let decoded = try JSONDecoder().decode(SnippetDocument.self, from: data)

            XCTAssertEqual(Set(decoded.secrets.map(\.id)), Set(document.secrets.map(\.id)),
                           "iteration \(iteration): secret set changed across a round trip")
            XCTAssertEqual(Set(decoded.groups.flatMap(\.snippets).map(\.id)),
                           Set(document.groups.flatMap(\.snippets).map(\.id)),
                           "iteration \(iteration): snippet set changed across a round trip")
            XCTAssertFalse(decoded.groups.flatMap(\.snippets).contains { $0.isSecret },
                           "iteration \(iteration): a secret stayed inside a snippet group")

            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(json.contains("hunter2-do-not-serialize"),
                           "iteration \(iteration): a secret value reached the bytes")
            XCTAssertFalse(json.contains(";leak\(iteration)"),
                           "iteration \(iteration): a secret trigger reached the bytes")

            let ids = decoded.transactionGroups.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "iteration \(iteration): duplicate group IDs")
        }
    }
}
