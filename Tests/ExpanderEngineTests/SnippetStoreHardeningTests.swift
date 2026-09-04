import XCTest
@testable import ExpanderEngine

// §-audit hardening for `SnippetStore`'s write paths.
//
// Two guarantees pinned here:
//
// 1. `saveGroups` participates in the same `rmwLock` serialization as
//    `importGroups` / `saveSnippets`. Before the fix a direct save's
//    sanitize→write→purge sequence could interleave into an in-flight
//    read-modify-write: the import read its baseline, the direct save committed,
//    then the import wrote content computed *before* that commit — one confirmed
//    save silently vanished, and the trailing orphan purge could drop keychain
//    secrets for snippets the winner had just written.
//
// 2. An external change to the library file still updates the in-memory groups
//    and notifies group listeners exactly once, on the main thread (the watcher
//    path now decodes off-main; the listener contract is unchanged).

final class SnippetStoreSaveRaceTests: XCTestCase {

    private func makeTemporaryStore(
        purge: Bool = true
    ) -> (SnippetStore, SecretStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeSaveRace-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("snippets.json")
        let backing = InMemorySecretBackingStore()
        let secrets = SecretStore(backing: backing)
        let store = SnippetStore(
            location: SnippetStore.Location(fileURL: url, expectsExistingLibrary: false),
            watcherFactory: { _ in nil },
            secretStore: secrets,
            secretPurgeEnabled: purge
        )
        return (store, secrets, url)
    }

    private static func secretSnippet(_ id: UUID, trigger: String) -> SnippetModel {
        SnippetModel(
            id: id,
            title: "secret-\(trigger)",
            triggerKeyword: trigger,
            replacementText: "",
            isSecret: true
        )
    }

    /// A direct `saveGroups` carrying a large payload overlaps an `importGroups`
    /// launched while the direct save is mid-write. After the fix the two serialize:
    /// whichever runs second reads the first's committed state, so BOTH the direct
    /// save's marker group and the import's group survive. Before the fix the import
    /// computed its merge against a pre-commit baseline and its write landed after
    /// the direct save's — one of the two confirmed saves was silently reverted
    /// (and the trailing orphan purge dropped keychain secrets for snippets the
    /// winner had just written).
    ///
    /// The payload is deliberately large so the direct save's encode+write window
    /// (~hundreds of ms) reliably spans the importer's entire read-modify-write.
    func testDirectSaveAndOverlappingImportDoNotLoseEitherSide() {
        let (store, secrets, url) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        for round in 0..<6 {
            let markerID = UUID()
            // Staging a new secret and publishing its first library reference are one transaction.
            // Keep the outer per-ID lease until the direct save has landed; `SecretStore.store`
            // owns only the inner lease around the backing write itself.
            let markerLease = secrets.protectFromOrphanPurge(markerID)
            defer { markerLease.end() }
            secrets.store("marker-secret-\(round)", for: markerID)

            // Baseline for this round: whatever is committed plus unique filler so
            // every round forces a full multi-megabyte encode + coordinated write.
            var payload = store.loadGroups()
            var filler: [SnippetModel] = []
            for index in 0..<20_000 {
                filler.append(SnippetModel(
                    title: "filler-\(round)-\(index)",
                    triggerKeyword: ";f\(round)x\(index)",
                    replacementText: "payload \(round) \(index)"
                ))
            }
            payload.append(SnippetGroup(name: "Filler-\(round)", snippets: filler))
            payload.append(SnippetGroup(name: "Marker-\(round)", snippets: [
                Self.secretSnippet(markerID, trigger: ";mk\(round)")
            ]))

            // Launch the racer so it starts while the direct save is mid-flight,
            // and wait for ITS completion (not a fixed delay) before asserting:
            // serialized correctly, it lands after the direct save and must survive
            // everything that came before it.
            let racerFinished = expectation(description: "racer \(round) finished")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                let summary = store.importGroups([
                    SnippetGroup(name: "Probe-\(round)", snippets: [
                        SnippetModel(
                            title: "probe",
                            triggerKeyword: ";pb\(round)",
                            replacementText: "probe \(round)"
                        )
                    ])
                ], mode: .intoNewGroup)
                XCTAssertTrue(
                    summary.outcome.didSave,
                    "round \(round): racing import refused: \(summary.outcome)"
                )
                racerFinished.fulfill()
            }

            let outcome = store.saveGroups(payload)
            markerLease.end()
            XCTAssertTrue(outcome.didSave, "round \(round): direct save refused: \(outcome)")

            wait(for: [racerFinished], timeout: 30)

            let names = Set(store.loadGroups().map(\.name))
            XCTAssertTrue(
                names.contains("Marker-\(round)"),
                "round \(round): the direct save reported success but its marker group "
                    + "was reverted by the overlapping import. Committed: \(names.sorted())"
            )
            XCTAssertTrue(
                names.contains("Probe-\(round)"),
                "round \(round): the racing import reported success but its group was "
                    + "dropped by the overlapping direct save. Committed: \(names.sorted())"
            )

            // The audit's sharpest edge, checked on snippets that exist
            // continuously from here on (the marker was in every landed write of
            // this round): a stale loser's orphan purge must never delete a secret
            // belonging to a snippet the library still references. A snippet that
            // is deleted and later re-added may legitimately lose its secret —
            // that is eager-orphan-purge semantics, not this race.
            let live = store.loadGroups()
            for group in live where group.name == "Marker-\(round)" {
                for snippet in group.snippets {
                    XCTAssertNotNil(
                        secrets.secret(for: snippet.id),
                        "round \(round): marker snippet \(snippet.triggerKeyword) survived "
                            + "on disk but its keychain secret was purged by a racing save."
                    )
                }
            }
        }
    }
}

final class SnippetStoreExternalReloadTests: XCTestCase {

    func testExternalReloadCannotAdvanceTheDigestPastAnInFlightMutationSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeExtMutationRace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snippets.json")
        let store = SnippetStore(fileURL: url)
        let baseline = [SnippetGroup(name: "General", snippets: [
            SnippetModel(title: "Baseline", triggerKeyword: ":base", replacementText: "one")
        ])]
        XCTAssertEqual(store.saveGroups(baseline), .saved)

        let mutationRead = DispatchSemaphore(value: 0)
        let allowMutation = DispatchSemaphore(value: 0)
        let reloadAttempted = DispatchSemaphore(value: 0)
        let reloadAdopted = DispatchSemaphore(value: 0)
        store.installConcurrencyProbeForTesting(.init(
            mutationDidRead: {
                mutationRead.signal()
                _ = allowMutation.wait(timeout: .now() + 8)
            },
            externalReloadWillAcquireMutationLock: { reloadAttempted.signal() },
            externalReloadDidAdopt: { reloadAdopted.signal() }
        ))
        defer { store.installConcurrencyProbeForTesting(nil) }

        let mutationFinished = expectation(description: "mutation finished")
        let resultLock = NSLock()
        var mutationResult: SnippetStore.GroupMutationResult?
        DispatchQueue.global(qos: .userInitiated).async {
            let result = store.mutateGroups { groups in
                groups[0].snippets[0].title = "Stale local edit"
                return true
            }
            resultLock.lock()
            mutationResult = result
            resultLock.unlock()
            mutationFinished.fulfill()
        }
        XCTAssertEqual(mutationRead.wait(timeout: .now() + 5), .success)

        let external = baseline + [SnippetGroup(name: "External", snippets: [
            SnippetModel(title: "External", triggerKeyword: ":external", replacementText: "keep")
        ])]
        try SnippetStore.encodeLibrary(external).write(to: url, options: .atomic)
        store.externalChangeDetected()
        XCTAssertEqual(reloadAttempted.wait(timeout: .now() + 5), .success)

        // Before the fix reload advances the digest and adopts the external bytes while the
        // mutation is paused. With the shared lock it cannot adopt until the mutation refuses.
        XCTAssertEqual(
            reloadAdopted.wait(timeout: .now() + 0.2),
            .timedOut,
            "External adoption must wait behind the in-flight mutation boundary"
        )
        allowMutation.signal()
        wait(for: [mutationFinished], timeout: 8)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !store.loadGroups().contains(where: { $0.name == "External" }) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        resultLock.lock()
        let result = mutationResult
        resultLock.unlock()
        XCTAssertEqual(result, .refused(.blockedByRemoteChange))
        XCTAssertEqual(store.loadGroups(), external)
    }

    /// Simulated external edit (another device / a hand edit): bytes change under the
    /// store without going through its API. The store must pick the new content up,
    /// fire the group listener exactly once with it, and do so on the main thread —
    /// even though the decode itself no longer runs there.
    func testExternalWriteUpdatesGroupsAndFiresGroupListenerOnceOnMain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeExtReload-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("snippets.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SnippetStore(fileURL: url)

        let baseline = SnippetGroup(name: "General", snippets: [
            SnippetModel(title: "A", triggerKeyword: ":a", replacementText: "1")
        ])
        XCTAssertTrue(store.saveGroups([baseline]).didSave)

        final class Recorder {
            let lock = NSLock()
            var invocations: [(isMain: Bool, names: [String])] = []
        }
        let recorder = Recorder()
        _ = store.addGroupListener { groups in
            recorder.lock.lock()
            recorder.invocations.append((Thread.isMainThread, groups.map(\.name)))
            recorder.lock.unlock()
        }

        // External writer: raw bytes, no store involvement.
        let external = SnippetGroup(name: "ExtInvader", snippets: [
            SnippetModel(title: "E", triggerKeyword: ":ext", replacementText: "from-elsewhere")
        ])
        try SnippetStore.encodeLibrary([baseline, external]).write(to: url, options: .atomic)

        store.externalChangeDetected()

        // Deterministic settle: pump the run loop (listener notifications arrive on
        // the main queue) until the external group shows up or we time out.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            recorder.lock.lock()
            let saw = recorder.invocations.contains { $0.names.contains("ExtInvader") }
            recorder.lock.unlock()
            let loaded = store.loadGroups()
            if saw, loaded.contains(where: { $0.name == "ExtInvader" }) { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        recorder.lock.lock()
        let invocationsWithExternal = recorder.invocations.filter { $0.names.contains("ExtInvader") }
        recorder.lock.unlock()

        XCTAssertEqual(
            invocationsWithExternal.count, 1,
            "one coalesced external change must notify exactly once; got "
                + "\(recorder.invocations.debugDescription)"
        )
        XCTAssertEqual(invocationsWithExternal.first?.isMain, true,
                       "group listeners are notified on the main thread")
        XCTAssertTrue(
            store.loadGroups().contains(where: { $0.name == "ExtInvader" }),
            "in-memory groups must reflect the externally written library"
        )
    }
}

final class SnippetStoreAtomicGroupMutationTests: XCTestCase {
    private final class SuspendedFirstDeleteBacking: SecretBackingStore {
        private let lock = NSLock()
        private var storage: [String: String] = [:]
        private var didSuspendDelete = false
        let deleteStarted = DispatchSemaphore(value: 0)
        let allowDelete = DispatchSemaphore(value: 0)

        func set(_ value: String, account: String) -> OSStatus {
            lock.lock()
            storage[account] = value
            lock.unlock()
            return errSecSuccess
        }

        func value(account: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return storage[account]
        }

        func contains(account: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return storage[account] != nil
        }

        func delete(account: String) -> OSStatus {
            lock.lock()
            let shouldSuspend = !didSuspendDelete
            if shouldSuspend { didSuspendDelete = true }
            lock.unlock()

            if shouldSuspend {
                deleteStarted.signal()
                _ = allowDelete.wait(timeout: .now() + 8)
            }

            lock.lock()
            defer { lock.unlock() }
            return storage.removeValue(forKey: account) == nil
                ? errSecItemNotFound
                : errSecSuccess
        }

        func accounts() -> Set<String> {
            lock.lock()
            defer { lock.unlock() }
            return Set(storage.keys)
        }
    }
    private func makeStore() -> (SnippetStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeAtomicMutation-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SnippetStore(
            location: .init(
                fileURL: directory.appendingPathComponent("snippets.json"),
                expectsExistingLibrary: false
            ),
            watcherFactory: { _ in nil },
            secretPurgeEnabled: false
        )
        return (store, directory)
    }

    private func snippet(_ trigger: String, id: UUID = UUID()) -> SnippetModel {
        SnippetModel(id: id, title: trigger, triggerKeyword: trigger, replacementText: trigger)
    }

    func testAtomicMutationRebasesOntoLatestCommittedInProcessLibrary() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let originalID = UUID()
        let baseline = [SnippetGroup(name: "General", snippets: [snippet(":a", id: originalID)])]
        XCTAssertEqual(store.saveGroups(baseline), .saved)

        // This is the snapshot a long-lived editor or manager rendered.
        let staleSnapshot = store.loadGroups()
        var concurrent = staleSnapshot
        concurrent[0].snippets.append(snippet(":concurrent"))
        XCTAssertEqual(store.saveGroups(concurrent), .saved)

        let result = store.mutateGroups { latest in
            guard let index = latest[0].snippets.firstIndex(where: { $0.id == originalID }) else {
                return false
            }
            latest[0].snippets[index].enabled = false
            return true
        }

        guard case .saved(let before, let after) = result else {
            return XCTFail("Expected an atomic save, got \(result)")
        }
        XCTAssertEqual(before, concurrent)
        XCTAssertEqual(after, store.loadGroups())
        XCTAssertFalse(after[0].snippets.first(where: { $0.id == originalID })?.enabled ?? true)
        XCTAssertNotNil(after[0].snippets.first(where: { $0.triggerKeyword == ":concurrent" }))
    }

    func testConditionalReplacementRefusesStaleUndoWithoutOverwritingNewWork() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = snippet(":a")
        let baseline = [SnippetGroup(name: "General", snippets: [original])]
        XCTAssertEqual(store.saveGroups(baseline), .saved)

        let edit = store.mutateGroups { groups in
            groups[0].snippets[0].enabled = false
            return true
        }
        guard case .saved(let before, let edited) = edit else {
            return XCTFail("Expected initial edit to save")
        }

        var concurrent = edited
        concurrent[0].snippets.append(snippet(":new"))
        XCTAssertEqual(store.saveGroups(concurrent), .saved)

        let undo = store.replaceGroups(ifCurrent: edited, with: before)
        guard case .rejected(let current) = undo else {
            return XCTFail("A stale whole-library undo must be rejected, got \(undo)")
        }
        XCTAssertEqual(current, concurrent)
        XCTAssertEqual(store.loadGroups(), concurrent)
    }

    func testRejectedAndUnchangedMutationsNeverWriteOrNotify() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let baseline = [SnippetGroup(name: "General", snippets: [snippet(":a")])]
        XCTAssertEqual(store.saveGroups(baseline), .saved)
        var notifications = 0
        let token = store.addGroupListener { _ in notifications += 1 }
        defer { store.removeListener(token: token) }
        // Registration delivers the current snapshot by contract; measure only the mutations.
        notifications = 0

        let rejected = store.mutateGroups { _ in false }
        let unchanged = store.mutateGroups { _ in true }

        guard case .rejected(let rejectedCurrent) = rejected else {
            return XCTFail("Expected rejected mutation")
        }
        guard case .unchanged(let unchangedCurrent) = unchanged else {
            return XCTFail("Expected unchanged mutation")
        }
        XCTAssertEqual(rejectedCurrent, baseline)
        XCTAssertEqual(unchangedCurrent, baseline)
        XCTAssertEqual(notifications, 0)
    }

    func testResetToDefaultsUsesTheAtomicWholeLibraryMutation() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let custom = [SnippetGroup(name: "Custom", snippets: [snippet(":custom")])]
        XCTAssertEqual(store.saveGroups(custom), .saved)

        let result = store.resetToDefaults()

        guard case .saved(let before, let after) = result else {
            return XCTFail("Expected reset to save, got \(result)")
        }
        XCTAssertEqual(before, custom)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].name, SnippetDocument.defaultGroupName)
        XCTAssertEqual(after[0].snippets.count, store.defaultSnippets().count)
        XCTAssertEqual(store.loadGroups(), after)
    }

    func testConditionalAttachmentCleanupRetainsAPathThatWasRereferenced() {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = "shared.png"
        let original = SnippetModel(
            title: "Original",
            triggerKeyword: ":original",
            replacementText: "",
            imagePath: path
        )
        XCTAssertEqual(
            store.saveGroups([SnippetGroup(name: "General", snippets: [original])]),
            .saved
        )
        _ = store.mutateGroups { groups in
            groups[0].snippets.removeAll()
            return true
        }
        let mutationRead = DispatchSemaphore(value: 0)
        let allowMutation = DispatchSemaphore(value: 0)
        let cleanupAttempted = DispatchSemaphore(value: 0)
        store.installConcurrencyProbeForTesting(.init(
            mutationDidRead: {
                mutationRead.signal()
                _ = allowMutation.wait(timeout: .now() + 8)
            },
            attachmentCleanupWillAcquireMutationLock: { cleanupAttempted.signal() }
        ))
        defer { store.installConcurrencyProbeForTesting(nil) }

        let rereferenceFinished = expectation(description: "re-reference committed")
        let cleanupFinished = expectation(description: "cleanup decided")
        let resultLock = NSLock()
        var rereference: SnippetStore.GroupMutationResult?
        var cleanup: SnippetStore.ImageCleanupResult?
        var deleted: [String] = []
        DispatchQueue.global(qos: .userInitiated).async {
            let result = store.mutateGroups { groups in
                groups[0].snippets.append(SnippetModel(
                    title: "Concurrent reference",
                    triggerKeyword: ":concurrent",
                    replacementText: "",
                    imagePath: path
                ))
                return true
            }
            resultLock.lock()
            rereference = result
            resultLock.unlock()
            rereferenceFinished.fulfill()
        }
        XCTAssertEqual(mutationRead.wait(timeout: .now() + 5), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = store.deleteImageIfUnreferenced(path) { candidate in
                resultLock.lock()
                deleted.append(candidate)
                resultLock.unlock()
                return true
            }
            resultLock.lock()
            cleanup = result
            resultLock.unlock()
            cleanupFinished.fulfill()
        }
        XCTAssertEqual(cleanupAttempted.wait(timeout: .now() + 5), .success)
        allowMutation.signal()
        wait(for: [rereferenceFinished, cleanupFinished], timeout: 8)

        resultLock.lock()
        let rereferenceResult = rereference
        let cleanupResult = cleanup
        let deletedPaths = deleted
        resultLock.unlock()
        guard case .saved = rereferenceResult else {
            return XCTFail("Expected concurrent reference to save, got \(String(describing: rereferenceResult))")
        }
        XCTAssertEqual(cleanupResult, .retainedReferenced)
        XCTAssertTrue(deletedPaths.isEmpty)
    }

    func testFailedSecretPurgeIsSurfacedAndExplicitlyRetryable() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeSecretPurgeRetry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let backing = InMemorySecretBackingStore()
        let secrets = SecretStore(backing: backing)
        let orphan = UUID()
        guard case .success = secrets.store("do-not-log-this-value", for: orphan) else {
            return XCTFail("Expected the test secret to be stored")
        }
        let store = SnippetStore(
            location: .init(
                fileURL: directory.appendingPathComponent("snippets.json"),
                expectsExistingLibrary: false
            ),
            watcherFactory: { _ in nil },
            secretStore: secrets,
            secretPurgeEnabled: true
        )

        backing.forcedStatus = errSecInteractionNotAllowed
        XCTAssertEqual(
            store.saveGroups([SnippetGroup(name: "General", snippets: [snippet(":live")])]),
            .saved
        )
        let failedPass = expectation(description: "failed cleanup recorded")
        store.requestOrphanSecretCleanupRetry { _ in failedPass.fulfill() }
        wait(for: [failedPass], timeout: 5)
        XCTAssertEqual(store.pendingSecretCleanupCount, 1)
        XCTAssertTrue(secrets.hasSecret(for: orphan))

        backing.forcedStatus = nil
        XCTAssertEqual(
            store.retryOrphanSecretCleanup(),
            .init(attempted: 1, removed: 1, failed: 0)
        )
        XCTAssertEqual(store.pendingSecretCleanupCount, 0)
        XCTAssertFalse(secrets.hasSecret(for: orphan))
    }

    func testSuspendedSecretDeleteDoesNotBlockUnrelatedWorkAndSerializesSameIDStaging() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeSecretPurgeNonblocking-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let backing = SuspendedFirstDeleteBacking()
        let secrets = SecretStore(backing: backing)
        let rereferencedID = UUID()
        if case .failure(let failure) = secrets.store("must-survive", for: rereferencedID) {
            return XCTFail("Could not stage the race fixture: \(failure)")
        }
        let store = SnippetStore(
            location: .init(
                fileURL: directory.appendingPathComponent("snippets.json"),
                expectsExistingLibrary: false
            ),
            watcherFactory: { _ in nil },
            secretStore: secrets,
            secretPurgeEnabled: true
        )

        let baselineSnippet = snippet(":base")
        let firstSaveReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = store.saveGroups([SnippetGroup(name: "General", snippets: [baselineSnippet])])
            firstSaveReturned.signal()
        }

        XCTAssertEqual(backing.deleteStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(
            firstSaveReturned.wait(timeout: .now() + 1),
            .success,
            "A save must return after persistence/notification, not after a stalled secret delete."
        )

        // A raw caller that did not stage/protect the selected secret cannot safely publish it
        // after purge has claimed that ID. Refuse immediately rather than waiting while holding
        // the library's RMW lock (which would transitively freeze unrelated saves).
        let resultLock = NSLock()
        let rawRereferenceFinished = DispatchSemaphore(value: 0)
        var rawRereferenceResult: SnippetStore.GroupMutationResult?
        DispatchQueue.global(qos: .userInitiated).async {
            let result = store.mutateGroups { groups in
                groups[0].snippets.append(SnippetModel(
                    id: rereferencedID,
                    title: "Unstaged re-reference",
                    triggerKeyword: ":unstaged",
                    replacementText: "",
                    isSecret: true
                ))
                return true
            }
            resultLock.lock()
            rawRereferenceResult = result
            resultLock.unlock()
            rawRereferenceFinished.signal()
        }
        guard rawRereferenceFinished.wait(timeout: .now() + 1) == .success else {
            backing.allowDelete.signal()
            return XCTFail("An unprotected same-ID re-reference must fail fast, not hold the RMW lock.")
        }
        resultLock.lock()
        let refusedRereference = rawRereferenceResult
        resultLock.unlock()
        guard let refusedRereference,
              case .refused(.failed(_)) = refusedRereference else {
            backing.allowDelete.signal()
            return XCTFail("Expected an unprotected same-ID re-reference to be refused.")
        }

        // The suspended delete is claimed only for `rereferencedID`. Neither another secret ID nor
        // an ordinary library commit may queue behind that backing-store I/O.
        let laterOrphanID = UUID()
        let unrelatedSecretFinished = DispatchSemaphore(value: 0)
        var unrelatedSecretStored = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result = secrets.store("remove-eventually", for: laterOrphanID)
            resultLock.lock()
            if case .success = result {
                unrelatedSecretStored = true
            } else {
                unrelatedSecretStored = false
            }
            resultLock.unlock()
            unrelatedSecretFinished.signal()
        }
        guard unrelatedSecretFinished.wait(timeout: .now() + 1) == .success else {
            backing.allowDelete.signal()
            return XCTFail("An unrelated secret store must not wait behind a suspended delete.")
        }
        resultLock.lock()
        let didStoreUnrelatedSecret = unrelatedSecretStored
        resultLock.unlock()
        XCTAssertTrue(didStoreUnrelatedSecret)

        let unrelatedSnippet = snippet(":unrelated")
        let secondMutationReturned = DispatchSemaphore(value: 0)
        var secondResult: SnippetStore.GroupMutationResult?
        DispatchQueue.global(qos: .userInitiated).async {
            let result = store.mutateGroups { groups in
                groups[0].snippets.append(unrelatedSnippet)
                return true
            }
            resultLock.lock()
            secondResult = result
            resultLock.unlock()
            secondMutationReturned.signal()
        }
        XCTAssertEqual(
            secondMutationReturned.wait(timeout: .now() + 1),
            .success,
            "A second mutation must not wait behind a suspended cleanup pass."
        )
        resultLock.lock()
        let committedResult = secondResult
        resultLock.unlock()
        guard case .saved = committedResult else {
            backing.allowDelete.signal()
            return XCTFail("Expected the unrelated mutation to commit, got \(String(describing: committedResult))")
        }

        // The same-ID path has the opposite contract. Once purge has crossed its irreversible
        // decision point, staging waits for deletion to finish; the later write then wins before
        // its library reference is published. This deterministically exercises the old
        // check-to-delete race without relying on a restorative write that could itself fail.
        let sameIDFinished = DispatchSemaphore(value: 0)
        let sameIDLeaseAcquired = DispatchSemaphore(value: 0)
        var replacementStored = false
        var rereferenceResult: SnippetStore.GroupMutationResult?
        DispatchQueue.global(qos: .userInitiated).async {
            let lease = secrets.protectFromOrphanPurge(rereferencedID)
            sameIDLeaseAcquired.signal()
            let storeResult = secrets.store("replacement-wins", for: rereferencedID)
            let mutationResult = store.mutateGroups { groups in
                groups[0].snippets.append(SnippetModel(
                    id: rereferencedID,
                    title: "Re-referenced",
                    triggerKeyword: ":again",
                    replacementText: "",
                    isSecret: true
                ))
                return true
            }
            lease.end()
            resultLock.lock()
            if case .success = storeResult {
                replacementStored = true
            } else {
                replacementStored = false
            }
            rereferenceResult = mutationResult
            resultLock.unlock()
            sameIDFinished.signal()
        }
        XCTAssertEqual(
            sameIDLeaseAcquired.wait(timeout: .now() + 0.2),
            .timedOut,
            "Same-ID staging must not cross an in-flight irreversible delete."
        )

        backing.allowDelete.signal()
        guard sameIDFinished.wait(timeout: .now() + 5) == .success else {
            return XCTFail("Same-ID staging did not resume after deletion finished.")
        }
        resultLock.lock()
        let didStoreReplacement = replacementStored
        let committedRereference = rereferenceResult
        resultLock.unlock()
        XCTAssertTrue(didStoreReplacement)
        guard case .saved = committedRereference else {
            return XCTFail("Expected same-ID staging to commit after deletion, got \(String(describing: committedRereference))")
        }

        let cleanupFinished = DispatchSemaphore(value: 0)
        let summaryLock = NSLock()
        var finalSummary: SecretStore.PurgeSummary?
        store.requestOrphanSecretCleanupRetry { summary in
            summaryLock.lock()
            finalSummary = summary
            summaryLock.unlock()
            cleanupFinished.signal()
        }
        guard cleanupFinished.wait(timeout: .now() + 5) == .success else {
            return XCTFail("The coalesced cleanup retry did not report completion.")
        }

        summaryLock.lock()
        let observedSummary = finalSummary
        summaryLock.unlock()
        XCTAssertEqual(observedSummary?.failed, 0)
        XCTAssertEqual(secrets.secret(for: rereferencedID), "replacement-wins")
        XCTAssertFalse(secrets.hasSecret(for: laterOrphanID))
        XCTAssertEqual(store.pendingSecretCleanupCount, 0)
    }

    func testAsyncSecretCleanupRequestsAreSingleFlightWithOneCoalescedTrailingPass() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeSecretPurgeSingleFlight-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SnippetStore(
            location: .init(
                fileURL: directory.appendingPathComponent("snippets.json"),
                expectsExistingLibrary: false
            ),
            watcherFactory: { _ in nil },
            secretStore: SecretStore(backing: InMemorySecretBackingStore()),
            secretPurgeEnabled: true
        )
        let firstPassStarted = DispatchSemaphore(value: 0)
        let allowFirstPass = DispatchSemaphore(value: 0)
        let counterLock = NSLock()
        var passCount = 0
        store.installConcurrencyProbeForTesting(.init(
            secretCleanupRetryDidBeginPass: {
                counterLock.lock()
                passCount += 1
                let current = passCount
                counterLock.unlock()
                if current == 1 {
                    firstPassStarted.signal()
                    _ = allowFirstPass.wait(timeout: .now() + 8)
                }
            }
        ))
        defer { store.installConcurrencyProbeForTesting(nil) }

        let completed = expectation(description: "coalesced cleanup completed")
        store.requestOrphanSecretCleanupRetry { _ in completed.fulfill() }
        XCTAssertEqual(firstPassStarted.wait(timeout: .now() + 5), .success)
        for _ in 0..<100 {
            store.requestOrphanSecretCleanupRetry()
        }
        allowFirstPass.signal()
        wait(for: [completed], timeout: 8)

        counterLock.lock()
        let observedPasses = passCount
        counterLock.unlock()
        XCTAssertEqual(observedPasses, 2)
    }
}

final class SnippetStoreImportModeTests: XCTestCase {

    func testDuplicateImportModeAlwaysAssignsFreshGroupIdentities() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeImportIdentity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnippetStore(fileURL: directory.appendingPathComponent("snippets.json"))
        let vendorGroupID = UUID()
        let incoming = [SnippetGroup(
            id: vendorGroupID,
            name: "Stable Vendor Group",
            snippets: [SnippetModel(title: "Imported", triggerKeyword: ":imported", replacementText: "v")]
        )]

        XCTAssertTrue(store.importGroups(incoming, mode: .intoNewGroup).outcome.didSave)
        XCTAssertTrue(store.importGroups(incoming, mode: .intoNewGroup).outcome.didSave)

        let imported = store.loadGroups().filter { $0.name.hasPrefix("Stable Vendor Group") }
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(Set(imported.map(\.id)).count, imported.count)
        XCTAssertFalse(imported.contains(where: { $0.id == vendorGroupID }))
    }

    func testSkipConflictsPreservesExistingMatchAndAddsOnlyNewSnippets() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeImportMode-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SnippetStore(fileURL: directory.appendingPathComponent("snippets.json"))
        let existing = SnippetModel(title: "Local", triggerKeyword: ";same", replacementText: "keep me")
        XCTAssertTrue(store.saveGroups([SnippetGroup(name: "General", snippets: [existing])]).didSave)

        let incoming = [
            SnippetGroup(name: "General", snippets: [
                SnippetModel(title: "Imported", triggerKeyword: ";same", replacementText: "do not overwrite"),
                SnippetModel(title: "New", triggerKeyword: ";new", replacementText: "append me")
            ])
        ]

        let summary = store.importGroups(incoming, mode: .skipConflicts)
        XCTAssertTrue(summary.outcome.didSave)
        XCTAssertEqual(summary.snippetsAdded, 1)
        XCTAssertEqual(summary.snippetsUnchanged, 1)
        let snippets = store.loadGroups().flatMap(\.snippets)
        XCTAssertEqual(snippets.first(where: { $0.triggerKeyword == ";same" })?.replacementText, "keep me")
        XCTAssertEqual(snippets.first(where: { $0.triggerKeyword == ";new" })?.replacementText, "append me")
    }
}
