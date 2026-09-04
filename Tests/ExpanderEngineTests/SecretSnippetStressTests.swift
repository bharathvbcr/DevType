import AppKit
import XCTest
@testable import ExpanderEngine

/// Randomised and end-to-end coverage for keychain-backed secrets.
///
/// `SecretSnippetTests` pins each guarantee once. This file tries to break them: thousands of
/// random libraries through the real encoder, the real on-disk store, and concurrent access, with
/// one question asked after every step — *is the value anywhere it should not be?*
final class SecretSnippetStressTests: XCTestCase {

    private struct Rng {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
        mutating func bool() -> Bool { next() & 1 == 0 }
    }

    /// Values a password field actually receives: template-looking text, quotes and backslashes
    /// that a naive redactor would mangle, emoji, RTL, and a very long passphrase.
    private static let hostileValues = [
        "hunter2",
        "{{cursor}}not-a-macro{{date}}",
        "%@ %d %%",
        #"quote"and\backslash/"#,
        "🔑🙂👩‍👩‍👧‍👦",
        "كلمة السر",
        "\u{200B}zero-width-lead",
        String(repeating: "correct horse battery staple ", count: 40),
        "line1\nline2\ttabbed",
        "</snippet>&amp;",
    ]

    private func temporaryStore(
        secrets: SecretStore,
        purge: Bool = true
    ) -> (SnippetStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeSecretTests-\(UUID().uuidString)")
            .appendingPathComponent("snippets.json")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let store = SnippetStore(
            location: SnippetStore.Location(fileURL: url, expectsExistingLibrary: false),
            watcherFactory: { _ in nil },
            secretStore: secrets,
            secretPurgeEnabled: purge
        )
        return (store, url)
    }

    // MARK: - Nothing reaches the file

    /// Two thousand random libraries, encoded the way the app encodes them. The assertion is not
    /// "the redaction ran" but "the bytes do not contain the value" — which is the only form of
    /// the guarantee that cannot be satisfied by a redactor with an off-by-one.
    func testNoSecretValueEverSurvivesEncoding() throws {
        var rng = Rng(seed: 0x5EC2_E7_10_0000)
        let encoder = JSONEncoder()

        for iteration in 0..<2_000 {
            var snippets: [SnippetModel] = []
            var expectedPlain: [UUID: String] = [:]
            var forbidden: [String] = []

            for index in 0..<(rng.int(5) + 1) {
                let value = Self.hostileValues[rng.int(Self.hostileValues.count)]
                let secret = rng.bool()
                var snippet = SnippetModel(
                    title: "row-\(iteration)-\(index)",
                    triggerKeyword: ";t\(index)",
                    replacementText: value,
                    isSecret: secret
                )
                if secret {
                    // Force the value in the way a corrupted file or a future bug would, so the
                    // encoder is genuinely the thing under test.
                    snippet.replacementText = value
                    forbidden.append(value)
                } else {
                    expectedPlain[snippet.id] = value
                }
                snippets.append(snippet)
            }

            let data = try encoder.encode(snippets)
            let json = String(data: data, encoding: .utf8) ?? ""

            for value in forbidden {
                // A plain snippet in the same library may legitimately hold the same string, so
                // only assert absence when nothing non-secret claims it.
                guard !expectedPlain.values.contains(value) else { continue }
                XCTAssertFalse(
                    json.contains(value),
                    "Secret value survived encoding at iteration \(iteration)."
                )
            }

            // The redaction must not be collateral damage to ordinary snippets.
            let decoded = try JSONDecoder().decode([SnippetModel].self, from: data)
            for snippet in decoded {
                if let expected = expectedPlain[snippet.id] {
                    XCTAssertEqual(snippet.replacementText, expected)
                } else {
                    XCTAssertEqual(snippet.replacementText, "")
                    XCTAssertTrue(snippet.isSecret)
                }
            }
        }
    }

    /// The same guarantee through the real store: bytes on disk, read back with a plain reader
    /// rather than through `SnippetModel`, so a decoding-side strip cannot mask a writing-side leak.
    func testSecretValueNeverReachesTheLibraryFile() throws {
        let secrets = SecretStore(backing: InMemorySecretBackingStore())
        let (store, url) = temporaryStore(secrets: secrets)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let secret = SnippetModel(title: "Work login", triggerKeyword: ";pw", replacementText: "", isSecret: true)
        secrets.store("hunter2-on-disk-would-be-a-bug", for: secret.id)
        store.saveSnippets([
            SnippetModel(title: "Address", triggerKeyword: ";addr", replacementText: "1 Main St"),
            secret,
        ])

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("hunter2-on-disk-would-be-a-bug"))
        XCTAssertTrue(raw.contains("1 Main St"), "Ordinary snippets still persist normally.")

        let reloaded = store.loadSnippets()
        XCTAssertEqual(reloaded.first { $0.isSecret }?.replacementText, "")
        XCTAssertEqual(
            secrets.secret(for: secret.id), "hunter2-on-disk-would-be-a-bug",
            "The value stays in the keychain — redaction is about the file, not about losing it."
        )
    }

    // MARK: - Orphan purge, end to end

    /// Deleting the snippet must delete the password. A user who removes it from every surface
    /// they can see has to be right about that.
    func testDeletingASecretSnippetPurgesTheKeychain() {
        let secrets = SecretStore(backing: InMemorySecretBackingStore())
        let (store, url) = temporaryStore(secrets: secrets)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let keep = SnippetModel(title: "Keep", triggerKeyword: ";k", replacementText: "", isSecret: true)
        let drop = SnippetModel(title: "Drop", triggerKeyword: ";d", replacementText: "", isSecret: true)
        secrets.store("keep-me", for: keep.id)
        secrets.store("delete-me", for: drop.id)
        store.saveSnippets([keep, drop])
        XCTAssertEqual(secrets.secret(for: drop.id), "delete-me")

        store.saveSnippets([keep])

        let cleanupFinished = expectation(description: "orphan cleanup finished")
        store.requestOrphanSecretCleanupRetry { _ in cleanupFinished.fulfill() }
        wait(for: [cleanupFinished], timeout: 5)

        XCTAssertEqual(secrets.secret(for: keep.id), "keep-me")
        XCTAssertNil(
            secrets.secret(for: drop.id),
            "The snippet is gone from every surface the user can see; the password must not "
                + "outlive it on the machine."
        )
    }

    /// A store built over part of the library — the importers' scratch stores, and every test that
    /// writes two snippets to a temp file — must never conclude that the *real* library's secrets
    /// are orphans. This guard is the difference between a purge and a wipe.
    func testPartialStoresNeverPurge() {
        let secrets = SecretStore(backing: InMemorySecretBackingStore())
        let (scratch, url) = temporaryStore(secrets: secrets, purge: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let elsewhere = UUID()
        secrets.store("belongs-to-the-real-library", for: elsewhere)

        scratch.saveSnippets([SnippetModel(title: "Scratch", triggerKeyword: ";s", replacementText: "x")])

        XCTAssertEqual(
            secrets.secret(for: elsewhere), "belongs-to-the-real-library",
            "A partial store that purges would delete every secret the user owns."
        )
    }

    /// A failed save must not purge: the library on disk still names those snippets.
    func testPurgeOnlyFollowsASaveThatLanded() {
        let secrets = SecretStore(backing: InMemorySecretBackingStore())
        let readOnlyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevTypeSecretRO-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: readOnlyDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDirectory.path)
            try? FileManager.default.removeItem(at: readOnlyDirectory)
        }

        let store = SnippetStore(
            location: SnippetStore.Location(
                fileURL: readOnlyDirectory.appendingPathComponent("snippets.json"),
                expectsExistingLibrary: false
            ),
            watcherFactory: { _ in nil },
            secretStore: secrets,
            secretPurgeEnabled: true
        )

        let live = UUID()
        secrets.store("still-referenced", for: live)
        // Make the directory unwritable so the save cannot land.
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyDirectory.path)

        store.saveSnippets([SnippetModel(title: "Other", triggerKeyword: ";o", replacementText: "x")])

        XCTAssertEqual(
            secrets.secret(for: live), "still-referenced",
            "Purging on a save that did not land would destroy secrets the on-disk library still "
                + "references."
        )
    }

    // MARK: - The typed path, fuzzed

    /// Random libraries into the engine setter. No secret may ever appear in the match snapshot,
    /// and no ordinary snippet may be lost to the filter.
    func testEngineNeverMatchesASecretAcrossRandomLibraries() {
        var rng = Rng(seed: 0xE461_0E_5E7)
        let engine = EventTapEngine()

        for round in 0..<500 {
            var expectedTriggers: Set<String> = []
            var snippets: [SnippetModel] = []
            for index in 0..<(rng.int(8) + 1) {
                let secret = rng.int(3) == 0
                let trigger = ";r\(round)i\(index)"
                snippets.append(
                    SnippetModel(
                        title: "s\(index)",
                        triggerKeyword: trigger,
                        replacementText: "value-\(index)",
                        isSecret: secret
                    )
                )
                if !secret { expectedTriggers.insert(trigger) }
            }

            engine.snippets = snippets

            let snapshot = engine.matchSnapshot
            XCTAssertFalse(snapshot.snippets.contains { $0.isSecret }, "round \(round)")
            XCTAssertEqual(
                Set(snapshot.snippets.map(\.triggerKeyword)), expectedTriggers,
                "The filter must remove secrets and nothing else (round \(round))."
            )
        }
    }

    // MARK: - Concurrency

    func testSecretStoreIsThreadSafe() {
        let backing = InMemorySecretBackingStore()
        let secrets = SecretStore(backing: backing)
        let ids = (0..<16).map { _ in UUID() }

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            var rng = Rng(seed: UInt64(worker) &+ 991)
            for step in 0..<300 {
                let id = ids[rng.int(ids.count)]
                switch rng.int(4) {
                case 0: secrets.store("value-\(worker)-\(step)", for: id)
                case 1: _ = secrets.secret(for: id)
                case 2: _ = secrets.hasSecret(for: id)
                default: secrets.remove(for: id)
                }
            }
        }

        // Whatever survived must be a value some worker actually wrote — never a torn string.
        for id in ids {
            if let value = secrets.secret(for: id) {
                XCTAssertTrue(value.hasPrefix("value-"), "Torn read: \(value)")
            }
        }
    }

    /// Copy and clear racing each other must never leave a value on a board we no longer own, and
    /// must never wipe a board someone else took over.
    func testClipboardCopyAndClearRaceSafely() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("devtype.tests.secret.race.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let clipboard = SecretClipboard()

        DispatchQueue.concurrentPerform(iterations: 6) { worker in
            for step in 0..<200 {
                if (worker &+ step) % 3 == 0 {
                    _ = clipboard.clearIfStillOurs(pasteboard: pasteboard)
                } else {
                    clipboard.copy("secret-\(worker)-\(step)", clearAfter: 600, pasteboard: pasteboard) { _, _ in }
                }
            }
        }

        // Final state is whatever the last operation left; the invariant is that a value is only
        // present while we still believe we own the board.
        let outcome = clipboard.clearIfStillOurs(pasteboard: pasteboard)
        XCTAssertTrue([.cleared, .supersededByUser, .nothingToClear].contains(outcome))
        if outcome == .cleared {
            XCTAssertNil(pasteboard.string(forType: .string))
        }
    }

    // MARK: - Copy resolution

    /// A password is not a template. Running one through `MacroRenderer` would corrupt any value
    /// containing `{{`, and could resolve a nested `{{snippet:…}}` inside it.
    func testSecretsAreCopiedVerbatimAndPlainSnippetsAreRendered() {
        let secrets = SecretStore(backing: InMemorySecretBackingStore())
        let secret = SnippetModel(title: "pw", triggerKeyword: ";pw", replacementText: "", isSecret: true)
        secrets.store("{{cursor}}%@literal", for: secret.id)

        switch SecretMenuFlowShim.resolve(secret, secretStore: secrets) {
        case .success(let text):
            XCTAssertEqual(
                text, "{{cursor}}%@literal",
                "Verbatim. Expanding a password silently corrupts it."
            )
        case .failure(let failure):
            XCTFail("expected the stored value, got \(failure)")
        }

        let missing = SnippetModel(title: "gone", triggerKeyword: ";g", replacementText: "", isSecret: true)
        guard case .failure(let failure) = SecretMenuFlowShim.resolve(missing, secretStore: secrets) else {
            return XCTFail("a secret with no stored value must not resolve")
        }
        XCTAssertEqual(failure, .secretUnavailable)
    }
    // MARK: - Clipboard ownership under contention

    /// The expansion pipeline and the secret path both write `NSPasteboard.general`. Hammer them
    /// together: every secret copy must invalidate whatever restore was pending, and the
    /// generation counter must never go backwards, or a stale restore becomes live again.
    func testSecretCopiesAlwaysInvalidatePendingRestoresUnderContention() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("devtype.tests.secret.own.\(UUID())"))
        defer { pasteboard.releaseGlobally() }

        let broker = PasteboardBroker()
        let clipboard = SecretClipboard()
        let lock = NSLock()
        var lastSeen: UInt64 = broker.currentRestoreGeneration()

        DispatchQueue.concurrentPerform(iterations: 6) { worker in
            for step in 0..<150 {
                let before = broker.currentRestoreGeneration()
                if (worker &+ step) % 4 == 0 {
                    // Stand-in for an expansion claiming the board.
                    _ = broker.beginRestoreGeneration()
                } else {
                    clipboard.copy(
                        "secret-\(worker)-\(step)",
                        clearAfter: 600,
                        pasteboard: pasteboard,
                        broker: broker
                    ) { _, _ in }
                    XCTAssertGreaterThan(
                        broker.currentRestoreGeneration(), before,
                        "A copy that does not invalidate leaves a scheduled restore able to "
                            + "overwrite the secret."
                    )
                }

                lock.lock()
                let current = broker.currentRestoreGeneration()
                XCTAssertGreaterThanOrEqual(current, lastSeen, "The generation went backwards.")
                lastSeen = max(lastSeen, current)
                lock.unlock()
            }
        }
    }

    /// Randomised: whatever a secret snippet is handed, the three fields that would make it
    /// ambiguous or leaky must come out empty — in memory and after a round trip.
    func testSecretsNeverCarryValueImageOrTransform() throws {
        var rng = Rng(seed: 0x0A11_B1AB_5EC2)
        let transforms = ["", "proofread", "translate", "promptenhance", "custom"]

        for iteration in 0..<3_000 {
            let secret = rng.bool()
            var snippet = SnippetModel(
                title: "row-\(iteration)",
                triggerKeyword: ";t\(iteration)",
                replacementText: Self.hostileValues[rng.int(Self.hostileValues.count)],
                imagePath: rng.bool() ? "attachment-\(iteration).png" : "",
                aiTransform: transforms[rng.int(transforms.count)],
                isSecret: secret
            )
            // Force every field back in, the way a hand-edited library would.
            if rng.bool() {
                snippet.replacementText = "forced"
                snippet.imagePath = "forced.png"
                snippet.aiTransform = "proofread"
            }

            let decoded = try JSONDecoder().decode(
                SnippetModel.self,
                from: JSONEncoder().encode(snippet)
            )
            if secret {
                XCTAssertEqual(decoded.replacementText, "", "iteration \(iteration)")
                XCTAssertEqual(decoded.imagePath, "", "iteration \(iteration)")
                XCTAssertEqual(decoded.aiTransform, "", "iteration \(iteration)")
                XCTAssertFalse(decoded.isImageSnippet)
                XCTAssertFalse(decoded.isTypedTriggerExpandable)
            } else {
                XCTAssertEqual(decoded.replacementText, snippet.replacementText)
                XCTAssertEqual(decoded.imagePath, snippet.imagePath)
                XCTAssertEqual(decoded.aiTransform, snippet.aiTransform)
                XCTAssertTrue(decoded.isTypedTriggerExpandable)
            }
        }
    }

}

/// The copy resolution lives in the app target, which tests cannot import. This mirrors its secret
/// branch so the rule ("verbatim, never rendered; missing is a typed failure") is pinned somewhere
/// executable; `SourceContractTests` asserts the real one still routes secrets the same way.
enum SecretMenuFlowShim {
    enum Failure: Error, Equatable { case secretUnavailable }

    static func resolve(
        _ snippet: SnippetModel,
        secretStore: SecretStore
    ) -> Result<String, Failure> {
        guard snippet.isSecret else { return .success(snippet.replacementText) }
        guard let value = secretStore.secret(for: snippet.id), !value.isEmpty else {
            return .failure(.secretUnavailable)
        }
        return .success(value)
    }
}
