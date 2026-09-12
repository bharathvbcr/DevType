import Foundation
import XCTest
@testable import ExpanderEngine
@testable import DevTypeAppCore

final class SecretIsolationStressTests: XCTestCase {
    private struct Random {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(bound))
        }
    }

    private func fixture() throws -> (SnippetStore, SecretStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode(SnippetDocument(groups: [])).write(to: file)
        let suite = "SecretIsolationStressTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let values = SecretStore(backing: ConsolidatedSecretBackingStore(
            fileURL: directory.appendingPathComponent("synthetic.enc"), tier: InMemorySecretBackingStore(),
            diagnostics: SecretAccessDiagnostics()))
        let store = SnippetStore(location: .init(fileURL: file, expectsExistingLibrary: true),
            deviceDefaults: defaults, localSupportDirectory: directory, secretStore: values, secretPurgeEnabled: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        return (store, values)
    }

    private func save(_ candidate: SecretModel, replacing existing: SecretModel?, value: String?,
                      store: SnippetStore, values: SecretStore, refuse: Bool = false) -> SnippetEditTransactionOutcome {
        SnippetEditTransaction(resources: .using(secretStore: values)).save(
            snippet: candidate.snippetAdapter, existing: existing?.snippetAdapter,
            pickedImageURL: nil, secretIntent: value.map(SnippetEditSecretIntent.set) ?? .unchanged, groupID: nil
        ) { _, _ in
            if refuse { return .refused(.blockedByRemoteChange) }
            return .mutating(store: store, mutation: { groups in
                SecretLibraryEdit.applying(candidate, replacing: existing, to: &groups)
            }, finalize: { _, _ in })
        }
    }

    /// Scales the campaign for an on-demand soak without slowing the ordinary suite.
    /// `DEVTYPE_SECRET_STRESS=8 swift test --filter SecretIsolationStress` runs 8x the seeds.
    private var stressMultiplier: Int {
        max(1, Int(ProcessInfo.processInfo.environment["DEVTYPE_SECRET_STRESS"] ?? "") ?? 1)
    }

    /// Every payload carries this marker, and nothing else in the fixture does. If a value ever
    /// reaches the library file, the marker is what survives JSON escaping to prove it.
    private static let valueCanary = "synthetic-"

    func testSeededWholeLibraryOperationsPreserveEveryCommittedSecret() throws {
        let payloads = ["synthetic-{{clipboard}}", "synthetic-\u{0}-\n", "synthetic-🔑e\u{301}", "synthetic-秘密"]
        for seed in 1...(16 * stressMultiplier) {
            let (store, values) = try fixture()
            var random = Random(state: UInt64(seed))
            var expected: [UUID: (SecretModel, String)] = [:]
            for step in 0..<80 {
                let operation = expected.isEmpty ? 0 : random.next(8)
                let existing = expected.values.sorted { $0.0.id.uuidString < $1.0.id.uuidString }.first
                switch operation {
                case 0:
                    let secret = SecretModel(title: "Secret \(seed)-\(step)", tags: ["test"])
                    let value = payloads[random.next(payloads.count)] + "-\(seed)-\(step)"
                    XCTAssertEqual(save(secret, replacing: nil, value: value, store: store, values: values), .committed)
                    expected[secret.id] = (secret, value)
                case 1, 2, 3:
                    let (old, oldValue) = try XCTUnwrap(existing)
                    var changed = old
                    changed.title = "Changed \(seed)-\(step)"
                    changed.enabled.toggle()
                    changed.updatedAt = Date(timeIntervalSince1970: Double(1_900_000_000 + step))
                    let value = operation == 2 ? nil : payloads[random.next(payloads.count)] + "-\(step)"
                    let result = save(changed, replacing: old, value: value, store: store, values: values, refuse: operation == 3)
                    if operation == 3 {
                        XCTAssertEqual(result, .failed(.persistence(.blockedByRemoteChange)))
                    } else {
                        XCTAssertEqual(result, .committed)
                        expected[old.id] = (changed, value ?? oldValue)
                    }
                case 4:
                    let (old, _) = try XCTUnwrap(existing)
                    let result = store.mutateGroups { SecretLibraryEdit.applying(nil, replacing: old, to: &$0) }
                    XCTAssertTrue(result.saveOutcome?.didSave == true)
                    expected.removeValue(forKey: old.id)
                case 5:
                    let snippet = SnippetModel(title: "Code", triggerKeyword: ";s\(seed)x\(step)", replacementText: "ordinary")
                    XCTAssertTrue(store.importGroups([SnippetGroup(name: "Secrets", snippets: [snippet])], mode: .replaceGroup).outcome.didSave)
                case 6:
                    XCTAssertTrue(store.resetToDefaults().saveOutcome?.didSave == true)
                default:
                    let decoded = try SnippetStore.decodeDocument(from: store.exportLibraryData())
                    XCTAssertEqual(Set(decoded.secrets), Set(expected.values.map { $0.0 }))
                }
                let cleanup = store.retryOrphanSecretCleanup()
                XCTAssertEqual(cleanup.pending, 0, "seed \(seed), step \(step)")
                let rawLibrary = try Data(contentsOf: store.activeLocationURL)
                let document = try SnippetStore.decodeDocument(from: rawLibrary)
                XCTAssertEqual(Set(document.secrets), Set(expected.values.map { $0.0 }), "seed \(seed), step \(step)")
                XCTAssertTrue(document.groups.flatMap(\.snippets).allSatisfy { !$0.isSecret })

                // No secret value may reach the library bytes, in any escaping.
                let libraryText = String(decoding: rawLibrary, as: UTF8.self)
                XCTAssertFalse(libraryText.contains(Self.valueCanary),
                               "seed \(seed), step \(step): a secret value reached the library file")

                // The transaction projection every mutation walks resolves groups by identity, so a
                // duplicate ID would silently retarget a write.
                let groupIDs = document.transactionGroups.map(\.id)
                XCTAssertEqual(Set(groupIDs).count, groupIDs.count,
                               "seed \(seed), step \(step): duplicate group IDs in the projection")
                XCTAssertFalse(document.groups.contains { $0.id == SnippetDocument.secretGroupID },
                               "seed \(seed), step \(step): a user group holds the reserved ID")
                for (id, entry) in expected {
                    XCTAssertEqual(values.secret(for: id), entry.1, "seed \(seed), step \(step)")
                }
            }
        }
    }

    func testConcurrentEditorsImportsAndCleanupAgreeOnMetadataAndValue() throws {
        let (store, values) = try fixture()
        let originals = (0..<4).map { SecretModel(title: "Initial \($0)") }
        for secret in originals {
            XCTAssertEqual(save(secret, replacing: nil, value: "synthetic-\(secret.title)", store: store, values: values), .committed)
        }
        let finished = expectation(description: "eight concurrent writers complete")
        finished.expectedFulfillmentCount = 8
        let countLock = NSLock()
        var committed = 0
        var refused = 0
        for worker in 0..<8 {
            DispatchQueue.global().async {
                for step in 0..<30 {
                    let id = originals[(worker + step) % originals.count].id
                    guard let old = store.loadSecrets().first(where: { $0.id == id }) else {
                        XCTFail("A live secret disappeared"); break
                    }
                    var candidate = old
                    candidate.title = "Worker \(worker) step \(step)"
                    candidate.updatedAt = Date(timeIntervalSince1970: Double(1_900_000_000 + worker * 100 + step))
                    let result = self.save(candidate, replacing: old, value: "synthetic-\(candidate.title)", store: store, values: values)
                    countLock.lock()
                    switch result {
                    case .committed: committed += 1
                    case .failed(.persistence(.blockedByRemoteChange)): refused += 1
                    default: XCTFail("Unexpected transaction result: \(result)")
                    }
                    countLock.unlock()
                    if step % 7 == 0 {
                        let snippet = SnippetModel(title: "Code", triggerKeyword: ";w\(worker)x\(step)", replacementText: "ordinary")
                        XCTAssertTrue(store.importGroups([SnippetGroup(name: "Code", snippets: [snippet])], mode: .merge).outcome.didSave)
                    }
                    if step % 5 == 0 { _ = store.retryOrphanSecretCleanup() }
                }
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 45)
        countLock.lock()
        let counts = (committed, refused)
        countLock.unlock()
        XCTAssertEqual(counts.0 + counts.1, 240)
        XCTAssertGreaterThan(counts.0, 0)
        let final = store.loadSecrets()
        XCTAssertEqual(Set(final.map(\.id)), Set(originals.map(\.id)))
        for secret in final { XCTAssertEqual(values.secret(for: secret.id), "synthetic-\(secret.title)") }
        XCTAssertEqual(store.retryOrphanSecretCleanup().pending, 0)
    }
}
