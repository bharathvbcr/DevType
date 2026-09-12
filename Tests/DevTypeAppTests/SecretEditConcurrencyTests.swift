import Foundation
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

final class SecretEditConcurrencyTests: XCTestCase {
    private func stores() throws -> (SecretStore, SecretStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("synthetic.enc")
        let tier = InMemorySecretBackingStore()
        return (SecretStore(backing: ConsolidatedSecretBackingStore(fileURL: archive, tier: tier)),
                SecretStore(backing: ConsolidatedSecretBackingStore(fileURL: archive, tier: tier)))
    }

    func testTwoEditorTransactionsCannotRollbackOverACompetingWriter() throws {
        let (first, second) = try stores()
        let secret = SecretModel(title: "Synthetic").snippetAdapter
        XCTAssertNoThrow(try first.store("original", for: secret.id).get())
        let snapshotRead = DispatchSemaphore(value: 0)
        let continueFirst = DispatchSemaphore(value: 0)
        let contenderStarted = DispatchSemaphore(value: 0)
        let contenderFinished = DispatchSemaphore(value: 0)
        let firstFinished = expectation(description: "first edit compensated")
        let secondFinished = expectation(description: "second edit committed")
        var firstAccess = SnippetEditResourceAccess.using(secretStore: first)
        let read = firstAccess.readSecret
        firstAccess.readSecret = { id in
            let result = read(id)
            snapshotRead.signal()
            XCTAssertEqual(continueFirst.wait(timeout: .now() + 8), .success)
            return result
        }
        let firstTransaction = SnippetEditTransaction(resources: firstAccess)
        let secondTransaction = SnippetEditTransaction(resources: .using(secretStore: second))
        DispatchQueue.global().async {
            let outcome = firstTransaction.save(snippet: secret, existing: secret, pickedImageURL: nil,
                                                secretIntent: .set("losing edit"), groupID: nil) { _, _ in
                .refused(.blockedByRemoteChange)
            }
            XCTAssertEqual(outcome, .failed(.persistence(.blockedByRemoteChange)))
            firstFinished.fulfill()
        }
        XCTAssertEqual(snapshotRead.wait(timeout: .now() + 8), .success)
        DispatchQueue.global().async {
            contenderStarted.signal()
            let outcome = secondTransaction.save(snippet: secret, existing: secret, pickedImageURL: nil,
                                                 secretIntent: .set("winning edit"), groupID: nil) { _, _ in
                .init(outcome: .saved, rollback: { .saved }, finalize: {})
            }
            XCTAssertEqual(outcome, .committed)
            contenderFinished.signal()
            secondFinished.fulfill()
        }
        XCTAssertEqual(contenderStarted.wait(timeout: .now() + 8), .success)
        XCTAssertEqual(contenderFinished.wait(timeout: .now() + 0.15), .timedOut,
                       "The contender must not enter between snapshot and compensation")
        continueFirst.signal()
        // Also release a later conditional compensation read, when present.
        continueFirst.signal()
        wait(for: [firstFinished, secondFinished], timeout: 12)
        XCTAssertEqual(first.secret(for: secret.id), "winning edit")
    }

    func testAWriteThatMutatesThenReportsFailureIsStillCompensated() throws {
        let (store, _) = try stores()
        let secret = SecretModel(title: "Synthetic").snippetAdapter
        XCTAssertNoThrow(try store.store("original", for: secret.id).get())
        var access = SnippetEditResourceAccess.using(secretStore: store)
        let write = access.storeSecret
        access.storeSecret = { value, id in
            let result = write(value, id)
            return value == "staged" ? .failure(.unavailable) : result
        }
        let transaction = SnippetEditTransaction(resources: access)
        XCTAssertEqual(transaction.save(snippet: secret, existing: secret, pickedImageURL: nil,
                                        secretIntent: .set("staged"), groupID: nil) { _, _ in
            XCTFail("Failed value write must never publish metadata")
            return .refused(.blockedByRemoteChange)
        }, .failed(.secretWrite))
        XCTAssertEqual(store.secret(for: secret.id), "original")
    }

    func testPendingCompensationRetainsOrphanProtectionUntilCancelSucceeds() throws {
        let (store, _) = try stores()
        let secret = SecretModel(title: "Synthetic").snippetAdapter
        var access = SnippetEditResourceAccess.using(secretStore: store)
        let remove = access.removeSecret
        var failRemoval = true
        access.removeSecret = { id in failRemoval ? .failure(.unavailable) : remove(id) }
        let transaction = SnippetEditTransaction(resources: access)
        XCTAssertEqual(transaction.save(snippet: secret, existing: nil, pickedImageURL: nil,
                                        secretIntent: .set("staged"), groupID: nil) { _, _ in
            .refused(.blockedByRemoteChange)
        }, .failed(.rollback))
        XCTAssertEqual(store.purgeOrphans(keeping: []).attempted, 0)
        XCTAssertTrue(store.hasSecret(for: secret.id))
        failRemoval = false
        XCTAssertEqual(transaction.cancel(), .clean)
        XCTAssertFalse(store.hasSecret(for: secret.id))
    }

    func testUnavailableTransactionDoesNotRunResourceOrMetadataOperations() throws {
        let (store, _) = try stores()
        let secret = SecretModel(title: "Synthetic").snippetAdapter
        var access = SnippetEditResourceAccess.using(secretStore: store)
        access.performSecretTransaction = { _ in false }
        access.readSecret = { _ in XCTFail("A refused transaction must not read values"); return .missing }
        access.storeSecret = { _, _ in XCTFail("A refused transaction must not write values"); return .failure(.unavailable) }
        let transaction = SnippetEditTransaction(resources: access)
        XCTAssertEqual(transaction.save(snippet: secret, existing: nil, pickedImageURL: nil,
                                        secretIntent: .set("staged"), groupID: nil) { _, _ in
            XCTFail("A refused transaction must not publish metadata")
            return .refused(.blockedByRemoteChange)
        }, .failed(.secretWrite))
        XCTAssertEqual(transaction.cancel(), .clean)
        XCTAssertFalse(store.hasSecret(for: secret.id))
    }

    func testMetadataQueriesRemainAvailableDuringAValueTransaction() throws {
        let (store, _) = try stores()
        let id = UUID()
        XCTAssertNoThrow(try store.store("synthetic", for: id).get())
        let queried = DispatchSemaphore(value: 0)
        XCTAssertTrue(store.performExclusiveTransaction {
            DispatchQueue.global().async {
                XCTAssertTrue(store.hasSecret(for: id))
                queried.signal()
            }
            XCTAssertEqual(queried.wait(timeout: .now() + 2), .success,
                           "Metadata must not wait behind the editor's value transaction")
        })
    }

    func testDelayedCompensationCannotOverwriteANewerValue() throws {
        let (store, _) = try stores()
        let secret = SecretModel(title: "Synthetic").snippetAdapter
        XCTAssertNoThrow(try store.store("original", for: secret.id).get())
        var access = SnippetEditResourceAccess.using(secretStore: store)
        let write = access.storeSecret
        var failCompensation = true
        access.storeSecret = { value, id in
            if value == "original", failCompensation { return .failure(.unavailable) }
            return write(value, id)
        }
        let transaction = SnippetEditTransaction(resources: access)
        XCTAssertEqual(transaction.save(snippet: secret, existing: secret, pickedImageURL: nil,
                                        secretIntent: .set("staged"), groupID: nil) { _, _ in
            .refused(.blockedByRemoteChange)
        }, .failed(.rollback))
        XCTAssertNoThrow(try store.store("newer committed value", for: secret.id).get())
        failCompensation = false
        XCTAssertEqual(transaction.cancel(), .clean)
        XCTAssertEqual(store.secret(for: secret.id), "newer committed value")
    }
}
