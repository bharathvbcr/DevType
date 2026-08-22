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
