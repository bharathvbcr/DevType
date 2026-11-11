import ExpanderEngine
import XCTest
@testable import DevTypeCLI

final class DevTypeCLITests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-cli-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    private var library: URL { directory.appendingPathComponent("snippets.json") }

    private func run(
        _ arguments: [String],
        store: SnippetStore? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        input: (() -> String?)? = nil
    ) -> (code: Int32, out: String, err: String) {
        var out = ""
        var err = ""
        let code = DevTypeCLI.run(
            arguments,
            store: store,
            environment: environment,
            stdout: { out += $0 },
            stderr: { err += $0 },
            input: input
        )
        return (code, out, err)
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func scratchStore() -> SnippetStore {
        SnippetStore(
            location: SnippetStore.Location(fileURL: library, expectsExistingLibrary: false),
            localSupportDirectory: directory,
            watcherFactory: { _ in nil },
            secretStore: SecretStore(backing: InMemorySecretBackingStore()),
            secretPurgeEnabled: false
        )
    }

    func testHelpAndUnknownCommand() {
        let help = run(["--help"])
        XCTAssertEqual(help.code, 0)
        XCTAssertTrue(help.out.contains("snippet add"))
        XCTAssertTrue(help.err.isEmpty)

        let unknown = run(["--json", "nope"])
        XCTAssertEqual(unknown.code, 2)
        XCTAssertTrue(unknown.err.isEmpty)
        let body = try? jsonObject(unknown.out)
        XCTAssertEqual(body?["ok"] as? Bool, false)
        XCTAssertEqual(body?["error"] as? String, "usage")
    }

    func testReadDoesNotCreateALibrary() {
        let missing = run(["--json", "--library", library.path, "status"])
        XCTAssertEqual(missing.code, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        let body = try? jsonObject(missing.out)
        XCTAssertEqual(body?["error"] as? String, "library_missing")

        let invalid = run(["--library", library.path, "snippet", "add", "--text", "x"])
        XCTAssertEqual(invalid.code, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertTrue(invalid.err.contains("--trigger"))
    }

    func testAddListGetSetRemoveRoundTrip() throws {
        let added = run([
            "--json", "--library", library.path,
            "snippet", "add", "--trigger", ":cli", "--text", "from-cli", "--title", "CLI",
        ])
        XCTAssertEqual(added.code, 0, added.err + added.out)
        let addedBody = try jsonObject(added.out)
        XCTAssertEqual(addedBody["ok"] as? Bool, true)
        XCTAssertEqual(addedBody["seededExamples"] as? Bool, true)
        let snippet = try XCTUnwrap(addedBody["snippet"] as? [String: Any])
        XCTAssertEqual(snippet["trigger"] as? String, ":cli")
        XCTAssertEqual(snippet["replacement"] as? String, "from-cli")
        let id = try XCTUnwrap(snippet["id"] as? String)

        let listed = run(["--json", "--library", library.path, "snippet", "list"])
        XCTAssertEqual(listed.code, 0, listed.out)
        let rows = try XCTUnwrap((try jsonObject(listed.out))["snippets"] as? [[String: Any]])
        let triggers = Set(rows.compactMap { $0["trigger"] as? String })
        XCTAssertTrue(triggers.contains(":cli"))
        XCTAssertTrue(triggers.contains(":eml"))

        let fetched = run(["--json", "--library", library.path, "snippet", "get", id])
        XCTAssertEqual((try jsonObject(fetched.out))["ok"] as? Bool, true)

        let updated = run([
            "--json", "--library", library.path, "snippet", "set", ":cli",
            "--text", "changed", "--group", "Notes",
        ])
        XCTAssertEqual(updated.code, 0, updated.out)
        let updatedSnippet = try XCTUnwrap((try jsonObject(updated.out))["snippet"] as? [String: Any])
        XCTAssertEqual(updatedSnippet["replacement"] as? String, "changed")
        XCTAssertEqual(updatedSnippet["group"] as? String, "Notes")

        let duplicate = run([
            "--json", "--library", library.path, "snippet", "add",
            "--trigger", ":eml", "--text", "other",
        ])
        XCTAssertEqual(duplicate.code, 1)
        XCTAssertEqual((try jsonObject(duplicate.out))["error"] as? String, "duplicate_trigger")

        let removed = run(["--json", "--library", library.path, "snippet", "remove", ":cli"])
        XCTAssertEqual(removed.code, 0, removed.out)
        let gone = run(["--json", "--library", library.path, "snippet", "get", ":cli"])
        XCTAssertEqual((try jsonObject(gone.out))["error"] as? String, "not_found")
        XCTAssertTrue(triggers.contains(":eml"))
        let still = run(["--json", "--library", library.path, "snippet", "get", ":eml"])
        XCTAssertEqual(still.code, 0)
    }

    func testSecretIsListedAndRefused() throws {
        let store = scratchStore()
        let secret = SnippetModel(
            title: "Mailbox",
            triggerKeyword: ":pw",
            replacementText: "hunter2",
            isSecret: true
        )
        XCTAssertEqual(secret.replacementText, "")
        let kept = SnippetModel(title: "Hi", triggerKeyword: ":hi", replacementText: "hello")
        let outcome = store.saveGroups([
            SnippetGroup(name: "General", snippets: [kept, secret]),
        ])
        XCTAssertTrue(outcome.didSave, String(describing: outcome))

        let listed = run(["--json", "snippet", "list"], store: store)
        XCTAssertEqual(listed.code, 0, listed.out)
        XCTAssertFalse(listed.out.contains("hunter2"))
        let rows = try XCTUnwrap((try jsonObject(listed.out))["snippets"] as? [[String: Any]])
        XCTAssertFalse(rows.contains { ($0["secret"] as? Bool) == true })
        XCTAssertTrue(rows.contains { $0["trigger"] as? String == ":hi" })

        let secretList = run(["--json", "secret", "list"], store: store)
        XCTAssertEqual(secretList.code, 0, secretList.out)
        XCTAssertFalse(secretList.out.contains("hunter2"))
        let secretRows = try XCTUnwrap((try jsonObject(secretList.out))["secrets"] as? [[String: Any]])
        let secretRow = try XCTUnwrap(secretRows.first { $0["title"] as? String == "Mailbox" })
        XCTAssertNil(secretRow["replacement"])
        XCTAssertNil(secretRow["trigger"])
        let secretID = try XCTUnwrap(secretRow["id"] as? String)

        let fetched = run(["--json", "snippet", "get", secretID], store: store)
        let fetchedSnippet = try XCTUnwrap((try jsonObject(fetched.out))["snippet"] as? [String: Any])
        XCTAssertEqual(fetchedSnippet["secret"] as? Bool, true)
        XCTAssertNil(fetchedSnippet["replacement"])
        XCTAssertFalse(fetched.out.contains("hunter2"))

        let changed = run(["--json", "snippet", "set", secretID, "--text", "nope"], store: store)
        XCTAssertEqual((try jsonObject(changed.out))["error"] as? String, "secret_refused")
        let removed = run(["--json", "snippet", "remove", secretID], store: store)
        XCTAssertEqual((try jsonObject(removed.out))["error"] as? String, "secret_refused")
        let expanded = run(["--json", "expand", "--trigger", secretID], store: store)
        XCTAssertEqual((try jsonObject(expanded.out))["error"] as? String, "secret_refused")

        let added = run([
            "--json", "snippet", "add", "--trigger", ":other", "--text", "plain",
        ], store: store)
        XCTAssertEqual(added.code, 0, added.out)

        let reloaded = SnippetStore(
            location: SnippetStore.Location(fileURL: library, expectsExistingLibrary: true),
            localSupportDirectory: directory,
            watcherFactory: { _ in nil },
            secretStore: SecretStore(backing: InMemorySecretBackingStore()),
            secretPurgeEnabled: false
        )
        XCTAssertEqual(reloaded.loadSecrets().map(\.title), ["Mailbox"])
        let secrets = reloaded.loadSnippets().filter(\.isSecret)
        XCTAssertEqual(secrets.map(\.triggerKeyword), [""])
        XCTAssertEqual(secrets.map(\.replacementText), [""])
        XCTAssertTrue(reloaded.loadSnippets().contains { $0.triggerKeyword == ":other" })
        XCTAssertFalse(reloaded.loadSnippets().contains { $0.replacementText.contains("hunter2") })
    }

    func testExpandUsesTheRendererAndDoesNotCreateALibrary() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now)
        let content = "Y{{date:yyyy}} {{cursor}}"
        let expected = MacroRenderer.expand(content: content, clipboardText: "", now: now)
        let rendered = run(["--json", "--library", library.path, "expand", "--text", content, "--now", stamp])
        XCTAssertEqual(rendered.code, 0, rendered.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        let body = try jsonObject(rendered.out)
        XCTAssertEqual(body["text"] as? String, expected.text)
        XCTAssertEqual(body["cursorOffset"] as? Int, expected.cursorOffset)
        XCTAssertFalse(rendered.out.contains("{{cursor}}"))
    }

    func testExpandTriggerPropagatesCase() throws {
        let added = run([
            "--json", "--library", library.path, "snippet", "add",
            "--trigger", ":hi", "--text", "hello", "--propagate-case", "true",
        ])
        XCTAssertEqual(added.code, 0, added.out)
        let rendered = run([
            "--json", "--library", library.path, "expand",
            "--trigger", ":hi", "--typed", "HELLO",
        ])
        XCTAssertEqual(rendered.code, 0, rendered.out)
        XCTAssertEqual((try jsonObject(rendered.out))["text"] as? String, "HELLO")

        let off = run([
            "--json", "--library", library.path, "snippet", "set", ":hi", "--enabled", "false",
        ])
        XCTAssertEqual(off.code, 0, off.out)
        let refused = run(["--json", "--library", library.path, "expand", "--trigger", ":hi"])
        XCTAssertEqual((try jsonObject(refused.out))["error"] as? String, "disabled")
        let allowed = run([
            "--json", "--library", library.path, "--allow-disabled", "expand", "--trigger", ":hi",
        ])
        XCTAssertEqual(allowed.code, 0, allowed.out)
    }

    func testLibraryFlagDoesNotUseTheAppSupportBackupDirectory() {
        XCTAssertTrue(CLIPaths.usesAppSupport(explicit: nil, environment: [:]))
        XCTAssertFalse(CLIPaths.usesAppSupport(explicit: library.path, environment: [:]))
        XCTAssertFalse(CLIPaths.usesAppSupport(explicit: nil, environment: [SnippetStore.storeDirEnvKey: directory.path]))
        let resolved = CLIPaths.libraryURL(explicit: library.path, environment: [:], defaults: UserDefaults())
        XCTAssertEqual(resolved.path, library.path)
        let support = CLIPaths.supportDirectory(library: library, usesAppSupport: false)
        XCTAssertEqual(support.path, directory.path)
    }

    func testReplRunsACommand() throws {
        let store = scratchStore()
        _ = store.saveGroups([
            SnippetGroup(name: "General", snippets: [
                SnippetModel(title: "Hi", triggerKeyword: ":hi", replacementText: "hello"),
            ]),
        ])
        var lines = ["snippet search hi --json", "quit"]
        let result = run(["repl"], store: store, input: { lines.isEmpty ? nil : lines.removeFirst() })
        XCTAssertEqual(result.code, 0, result.err + result.out)
        XCTAssertTrue(result.out.contains("\"trigger\" : \":hi\"") || result.out.contains("\"trigger\": \":hi\""))
        XCTAssertFalse(result.out.contains("devtype-cli repl"))
        XCTAssertTrue(result.err.contains("devtype-cli repl"))
    }

    /// A repl line is parsed alone. The session's library has to travel with it, or `status`
    /// opens whatever `DEVTYPE_STORE_DIR` or the app defaults name.
    func testReplKeepsTheSessionLibraryAndJSON() throws {
        let added = run([
            "--library", library.path, "snippet", "add", "--trigger", ":hi", "--text", "hello",
        ])
        XCTAssertEqual(added.code, 0, added.err)
        let missing = directory.appendingPathComponent("missing.json")
        let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
        let isolated = [SnippetStore.storeDirEnvKey: elsewhere.path]
        var lines = ["status", "quit"]
        let result = run(
            ["--json", "--library", missing.path, "repl"],
            environment: isolated,
            input: { lines.isEmpty ? nil : lines.removeFirst() }
        )
        XCTAssertEqual(result.code, 0, result.err + result.out)
        XCTAssertTrue(result.out.contains("library_missing"))
        XCTAssertTrue(result.out.contains("missing.json"))
        XCTAssertFalse(result.out.contains("elsewhere"))
        XCTAssertFalse(result.out.contains("devtype-cli repl"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("snippets.json").path))

        lines = ["status", "quit"]
        let kept = run(
            ["--json", "--library", library.path, "repl"],
            environment: isolated,
            input: { lines.isEmpty ? nil : lines.removeFirst() }
        )
        XCTAssertEqual(kept.code, 0, kept.err + kept.out)
        let body = try jsonObject(kept.out)
        XCTAssertEqual(body["ok"] as? Bool, true)
        XCTAssertEqual(body["library"] as? String, library.path)
    }

    func testReplLineCanOverrideTheLibraryAndKeepsAllowDisabled() throws {
        let other = directory.appendingPathComponent("other.json")
        let first = run([
            "--json", "--library", library.path, "snippet", "add",
            "--trigger", ":hi", "--text", "hello", "--enabled", "false",
        ])
        XCTAssertEqual(first.code, 0, first.out)
        let second = run([
            "--json", "--library", other.path, "snippet", "add",
            "--trigger", ":yo", "--text", "there",
        ])
        XCTAssertEqual(second.code, 0, second.out)

        var lines = ["status --library '\(other.path)'", "expand --trigger :hi", "quit"]
        let result = run(
            ["--json", "--library", library.path, "--allow-disabled", "repl"],
            environment: [SnippetStore.storeDirEnvKey: directory.appendingPathComponent("elsewhere").path],
            input: { lines.isEmpty ? nil : lines.removeFirst() }
        )
        XCTAssertEqual(result.code, 0, result.err + result.out)
        let objects = try jsonObjects(result.out)
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0]["library"] as? String, other.path)
        XCTAssertEqual(objects[1]["text"] as? String, "hello")
    }

    func testDirectoryLibraryIsRefusedAndSearchValidatesBeforeOpening() throws {
        let folder = directory.appendingPathComponent("not-a-file", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let status = run(["--json", "--library", folder.path, "status"])
        XCTAssertEqual(status.code, 1)
        XCTAssertEqual((try jsonObject(status.out))["error"] as? String, "library_not_file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("snippets.json").path))

        let invalid = run(["--json", "snippet", "search", "--", "-tag:"])
        XCTAssertEqual(invalid.code, 1)
        XCTAssertTrue(invalid.err.isEmpty)
        XCTAssertEqual((try jsonObject(invalid.out))["error"] as? String, "invalid_query")

        // `-tag:` is a flag until `--`. The failure is still JSON because `--json` came first.
        let flagged = run(["--json", "snippet", "search", "-tag:"])
        XCTAssertEqual(flagged.code, 2)
        XCTAssertTrue(flagged.err.isEmpty)
        XCTAssertEqual((try jsonObject(flagged.out))["error"] as? String, "usage")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testDistinctCaseSensitiveSpellingsAreAmbiguousWhenFolded() throws {
        let upper = run([
            "--json", "--library", library.path, "snippet", "add",
            "--trigger", "Hi", "--text", "upper", "--case-sensitive", "true",
        ])
        XCTAssertEqual(upper.code, 0, upper.out)
        let lower = run([
            "--json", "--library", library.path, "snippet", "add",
            "--trigger", "hi", "--text", "lower", "--case-sensitive", "true",
        ])
        XCTAssertEqual(lower.code, 0, lower.out)
        let folded = run(["--json", "--library", library.path, "snippet", "get", "HI"])
        XCTAssertEqual((try jsonObject(folded.out))["error"] as? String, "ambiguous")
        let exact = run(["--json", "--library", library.path, "snippet", "get", "Hi"])
        let snippet = try XCTUnwrap((try jsonObject(exact.out))["snippet"] as? [String: Any])
        XCTAssertEqual(snippet["replacement"] as? String, "upper")
    }

    func testExpandRefusesImageAndDisabledGroup() throws {
        let store = scratchStore()
        let outcome = store.saveGroups([
            SnippetGroup(name: "General", snippets: [
                SnippetModel(title: "Shot", triggerKeyword: ":img", replacementText: "", imagePath: "/tmp/shot.png"),
            ]),
            SnippetGroup(name: "Paused", enabled: false, snippets: [
                SnippetModel(title: "Off", triggerKeyword: ":off", replacementText: "nope"),
            ]),
        ])
        XCTAssertTrue(outcome.didSave, String(describing: outcome))
        let image = run(["--json", "expand", "--trigger", ":img"], store: store)
        XCTAssertEqual((try jsonObject(image.out))["error"] as? String, "image_snippet")
        let hidden = run(["--json", "expand", "--trigger", ":off"], store: store)
        XCTAssertEqual((try jsonObject(hidden.out))["error"] as? String, "disabled")
        let allowed = run(["--json", "--allow-disabled", "expand", "--trigger", ":off"], store: store)
        XCTAssertEqual((try jsonObject(allowed.out))["text"] as? String, "nope")
    }

    /// `--library` is an override only as a real flag. A flag-shaped token is not the value of
    /// `--text` or `--group`, and a token after search `--` does not drop the session library.
    func testInheritedLibraryFlagIsNotAValueOrSearchToken() throws {
        let elsewhere = directory.appendingPathComponent("default-store", isDirectory: true)
        let defaultLibrary = elsewhere.appendingPathComponent("snippets.json")
        let isolated = [SnippetStore.storeDirEnvKey: elsewhere.path]
        let seeded = run([
            "--json", "--library", defaultLibrary.path,
            "snippet", "add", "--trigger", ":hi", "--text", "hello",
        ], environment: isolated)
        XCTAssertEqual(seeded.code, 0, seeded.err + seeded.out)
        let beforeDefault = try Data(contentsOf: defaultLibrary)

        let stolenText = run([
            "--json", "snippet", "set", ":hi", "--text", "--library=owned",
        ], environment: isolated)
        XCTAssertEqual(stolenText.code, 2, stolenText.out + stolenText.err)
        XCTAssertEqual((try jsonObject(stolenText.out))["error"] as? String, "usage")
        XCTAssertEqual(try Data(contentsOf: defaultLibrary), beforeDefault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "owned"))

        let stolenGroup = run([
            "--json", "snippet", "set", ":hi", "--group", "--library=owned",
        ], environment: isolated)
        XCTAssertEqual(stolenGroup.code, 2, stolenGroup.out + stolenGroup.err)
        XCTAssertEqual(try Data(contentsOf: defaultLibrary), beforeDefault)

        let session = run([
            "--json", "--library", library.path,
            "snippet", "add", "--trigger", ":hi", "--text", "session",
        ], environment: isolated)
        XCTAssertEqual(session.code, 0, session.err + session.out)
        var lines = [
            "snippet search session -- --library=owned",
            "snippet set :hi --text=--library=owned",
            "quit",
        ]
        let repl = run(
            ["--json", "--library", library.path, "repl"],
            environment: isolated,
            input: { lines.isEmpty ? nil : lines.removeFirst() }
        )
        XCTAssertEqual(repl.code, 0, repl.err + repl.out)
        let objects = try topLevelJSONObjects(repl.out)
        XCTAssertEqual(objects.count, 2, repl.out)
        XCTAssertEqual(objects[0]["ok"] as? Bool, true)
        let hits = try XCTUnwrap(objects[0]["snippets"] as? [[String: Any]])
        XCTAssertTrue(hits.contains { $0["trigger"] as? String == ":hi" }, repl.out)
        let updated = try XCTUnwrap(objects[1]["snippet"] as? [String: Any])
        XCTAssertEqual(updated["replacement"] as? String, "--library=owned")
        XCTAssertEqual(try Data(contentsOf: defaultLibrary), beforeDefault)
        let sessionBytes = try Data(contentsOf: library)
        XCTAssertTrue(String(decoding: sessionBytes, as: UTF8.self).contains("--library=owned"))
        XCTAssertFalse(String(decoding: beforeDefault, as: UTF8.self).contains("--library=owned"))
    }

    /// Creating a library must not publish the built-in examples before the add is accepted,
    /// and an evicted iCloud placeholder is not a brand-new file to fill with those examples.
    func testRejectedCreateDoesNotSeedDemosOrAdoptEvictedLibrary() throws {
        let duplicate = run([
            "--json", "--library", library.path,
            "snippet", "add", "--trigger", ":eml", "--text", "other",
        ])
        XCTAssertEqual(duplicate.code, 1, duplicate.out + duplicate.err)
        XCTAssertEqual((try jsonObject(duplicate.out))["error"] as? String, "duplicate_trigger")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))

        let evicted = directory.appendingPathComponent("evicted.json")
        let placeholder = evicted.deletingLastPathComponent()
            .appendingPathComponent(".\(evicted.lastPathComponent).icloud")
        FileManager.default.createFile(atPath: placeholder.path, contents: Data("placeholder".utf8))
        let adopted = run([
            "--json", "--library", evicted.path,
            "snippet", "add", "--trigger", ":eml", "--text", "other",
        ])
        XCTAssertEqual(adopted.code, 1, adopted.out + adopted.err)
        let adoptedBody = try jsonObject(adopted.out)
        XCTAssertEqual(adoptedBody["error"] as? String, "save_refused")
        XCTAssertEqual(adoptedBody["message"] as? String, "Library not available at configured location")
        XCTAssertFalse(FileManager.default.fileExists(atPath: evicted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: placeholder.path))
        XCTAssertNotEqual(adoptedBody["error"] as? String, "duplicate_trigger")
    }

    /// An undecodable library is a failed read. Whitespace is an empty library and stays on disk.
    func testStatusSurfacesUndecodableLibraryAndKeepsWhitespace() throws {
        let blank = Data(" \n\t \r\n".utf8)
        try blank.write(to: library)
        let empty = run(["--json", "--library", library.path, "status"])
        XCTAssertEqual(empty.code, 0, empty.err + empty.out)
        let emptyBody = try jsonObject(empty.out)
        XCTAssertEqual(emptyBody["ok"] as? Bool, true)
        XCTAssertEqual(emptyBody["snippets"] as? Int, 0)
        XCTAssertEqual(emptyBody["groups"] as? Int, 0)
        XCTAssertEqual(try Data(contentsOf: library), blank)

        let corrupt = Data("{\"snippets\":".utf8)
        let corruptURL = directory.appendingPathComponent("corrupt.json")
        try corrupt.write(to: corruptURL)
        let failed = run(["--json", "--library", corruptURL.path, "status"])
        XCTAssertEqual(failed.code, 1, failed.out + failed.err)
        let failedBody = try jsonObject(failed.out)
        XCTAssertEqual(failedBody["ok"] as? Bool, false)
        XCTAssertEqual(failedBody["error"] as? String, "library_unreadable")
        XCTAssertNil(failedBody["snippets"])
        XCTAssertEqual(try Data(contentsOf: corruptURL), corrupt)

        let again = run(["--json", "--library", corruptURL.path, "status"])
        XCTAssertEqual(again.code, 1, again.out)
        XCTAssertEqual((try jsonObject(again.out))["error"] as? String, "library_unreadable")
        XCTAssertEqual(try Data(contentsOf: corruptURL), corrupt)
        let reloaded = SnippetStore(
            location: SnippetStore.Location(fileURL: corruptURL, expectsExistingLibrary: true),
            localSupportDirectory: directory.appendingPathComponent("corrupt-support", isDirectory: true),
            watcherFactory: { _ in nil },
            secretStore: SecretStore(backing: InMemorySecretBackingStore()),
            secretPurgeEnabled: false
        )
        XCTAssertTrue(reloaded.isLibraryReadFailed)
        XCTAssertEqual(try Data(contentsOf: corruptURL), corrupt)
    }

    /// Flag-shaped tokens stay flags. Inline `=` values and tokens after `--` do not retarget the session library.
    func testAdversarialFlagValuesDoNotRetargetOrWrite() throws {
        defer { try? FileManager.default.removeItem(atPath: "owned") }
        let session = directory.appendingPathComponent("session lib.json")
        let evil = directory.appendingPathComponent("evil.json")
        let elsewhere = directory.appendingPathComponent("env-fallback", isDirectory: true)
        let isolated = [SnippetStore.storeDirEnvKey: elsewhere.path]
        let seeded = run([
            "--json", "--library", session.path,
            "snippet", "add", "--trigger", ":hi", "--text", "session-marker",
        ], environment: isolated)
        XCTAssertEqual(seeded.code, 0, seeded.err + seeded.out)
        XCTAssertEqual((try jsonObject(seeded.out))["seededExamples"] as? Bool, true)
        let evilSeed = run([
            "--json", "--library", evil.path,
            "snippet", "add", "--trigger", ":hi", "--text", "evil-marker",
        ], environment: isolated)
        XCTAssertEqual(evilSeed.code, 0, evilSeed.err + evilSeed.out)
        let sessionBefore = try Data(contentsOf: session)
        let evilBefore = try Data(contentsOf: evil)
        let triggers = try listedTriggers(session, environment: isolated)
        XCTAssertEqual(triggers, [":eml", ":func", ":hello", ":hi", ":tdate"])

        let stolen = run([
            "--json", "--library", session.path,
            "snippet", "set", ":hi", "--text", "--library=\(evil.path)",
        ], environment: isolated)
        XCTAssertEqual(stolen.code, 2, stolen.out + stolen.err)
        XCTAssertEqual((try jsonObject(stolen.out))["error"] as? String, "usage")
        assertFileEquals(session, sessionBefore, "stolen --text")
        assertFileEquals(evil, evilBefore, "stolen --text evil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "owned"))

        let inline = run([
            "--json", "--library", session.path,
            "snippet", "set", ":hi", "--text=--library=\(evil.path)",
        ], environment: isolated)
        XCTAssertEqual(inline.code, 0, inline.out + inline.err)
        let inlineSnippet = try XCTUnwrap((try jsonObject(inline.out))["snippet"] as? [String: Any])
        XCTAssertEqual(inlineSnippet["replacement"] as? String, "--library=\(evil.path)")
        assertFileEquals(evil, evilBefore, "inline text must not touch evil")

        let restore = run([
            "--json", "--library", session.path,
            "snippet", "set", ":hi", "--text", "session-marker",
        ], environment: isolated)
        XCTAssertEqual(restore.code, 0, restore.out + restore.err)
        let restored = try Data(contentsOf: session)

        let singleDash = run([
            "--json", "--library", session.path,
            "snippet", "set", ":hi", "--text", "-n",
        ], environment: isolated)
        XCTAssertEqual(singleDash.code, 0, singleDash.out + singleDash.err)
        XCTAssertEqual(
            ((try jsonObject(singleDash.out))["snippet"] as? [String: Any])?["replacement"] as? String,
            "-n"
        )
        let putBack = run([
            "--json", "--library", session.path,
            "snippet", "set", ":hi", "--text", "session-marker",
        ], environment: isolated)
        XCTAssertEqual(putBack.code, 0, putBack.out)
        assertFileEquals(evil, evilBefore, "single-dash value")

        let fresh = directory.appendingPathComponent("fresh-add.json")
        let refusedAdd = run([
            "--json", "--library", fresh.path,
            "snippet", "add", "--trigger", ":x", "--text", "--library=owned",
        ], environment: isolated)
        XCTAssertEqual(refusedAdd.code, 2, refusedAdd.out + refusedAdd.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "owned"))
        let inlineAdd = run([
            "--json", "--library", fresh.path,
            "snippet", "add", "--trigger", ":x", "--text=--library=owned", "--group=--library=\(evil.path)",
        ], environment: isolated)
        XCTAssertEqual(inlineAdd.code, 0, inlineAdd.out + inlineAdd.err)
        let addedSnippet = try XCTUnwrap((try jsonObject(inlineAdd.out))["snippet"] as? [String: Any])
        XCTAssertEqual(addedSnippet["replacement"] as? String, "--library=owned")
        XCTAssertEqual(addedSnippet["group"] as? String, "--library=\(evil.path)")
        XCTAssertEqual((try jsonObject(inlineAdd.out))["seededExamples"] as? Bool, true)
        assertFileEquals(evil, evilBefore, "inline add")
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("snippets.json").path))

        var lines = [
            "snippet search session-marker -- --library=\(evil.path)",
            "snippet get -- :hi",
            "snippet get :hi --library '\(evil.path)'",
            "snippet set :hi --group='--library=\(evil.path)'",
            "snippet set :hi --text --library=\(evil.path)",
            "snippet search session-marker -- --library=\(evil.path)",
            "quit",
        ]
        let repl = run(
            ["--json", "--library", session.path, "repl"],
            environment: isolated,
            input: { lines.isEmpty ? nil : lines.removeFirst() }
        )
        XCTAssertEqual(repl.code, 0, repl.err + repl.out)
        XCTAssertTrue(repl.err.contains("devtype-cli repl"))
        XCTAssertFalse(repl.out.contains("devtype-cli repl"))
        let objects = try topLevelJSONObjects(repl.out)
        XCTAssertEqual(objects.count, 6, repl.out)
        XCTAssertEqual(objects[0]["ok"] as? Bool, true, repl.out)
        let searchHits = try XCTUnwrap(objects[0]["snippets"] as? [[String: Any]])
        XCTAssertTrue(searchHits.contains { ($0["replacement"] as? String) == "session-marker" }, repl.out)
        XCTAssertFalse(searchHits.contains { ($0["replacement"] as? String) == "evil-marker" }, repl.out)
        let got = try XCTUnwrap(objects[1]["snippet"] as? [String: Any])
        XCTAssertEqual(got["replacement"] as? String, "session-marker")
        let overridden = try XCTUnwrap(objects[2]["snippet"] as? [String: Any])
        XCTAssertEqual(overridden["replacement"] as? String, "evil-marker")
        XCTAssertEqual(objects[3]["ok"] as? Bool, true, repl.out)
        let grouped = try XCTUnwrap(objects[3]["snippet"] as? [String: Any])
        XCTAssertEqual(grouped["group"] as? String, "--library=\(evil.path)")
        XCTAssertEqual(grouped["replacement"] as? String, "session-marker")
        XCTAssertEqual(objects[4]["ok"] as? Bool, false)
        XCTAssertEqual(objects[4]["error"] as? String, "usage")
        XCTAssertEqual(objects[5]["ok"] as? Bool, true, repl.out)
        assertFileEquals(evil, evilBefore, "repl must not rewrite evil")
        let sessionAfter = try Data(contentsOf: session)
        XCTAssertNotEqual(sessionAfter, restored)
        XCTAssertFalse(String(decoding: sessionAfter, as: UTF8.self).contains("evil-marker"))
        let reread = run(["--json", "--library", session.path, "snippet", "get", ":hi"], environment: isolated)
        let rereadSnippet = try XCTUnwrap((try jsonObject(reread.out))["snippet"] as? [String: Any])
        XCTAssertEqual(rereadSnippet["group"] as? String, "--library=\(evil.path)")
        XCTAssertEqual(rereadSnippet["replacement"] as? String, "session-marker")
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("snippets.json").path))

        let leadingSpace = run([
            "--json", "--library", session.path,
            "snippet", "set", ":hi", "--text", " --library=\(evil.path)",
        ], environment: isolated)
        XCTAssertEqual(leadingSpace.code, 0, leadingSpace.out + leadingSpace.err)
        XCTAssertEqual(
            ((try jsonObject(leadingSpace.out))["snippet"] as? [String: Any])?["replacement"] as? String,
            " --library=\(evil.path)"
        )
        assertFileEquals(evil, evilBefore, "leading space")
    }

    /// Eviction, symlinks, odd paths, and a rejected create must not publish demo bytes.
    func testAdversarialEvictionSymlinksAndCreate() throws {
        let fm = FileManager.default
        let isolated = [SnippetStore.storeDirEnvKey: directory.appendingPathComponent("env-fallback-2").path]

        let parent = directory.appendingPathComponent("my cloud", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let evicted = parent.appendingPathComponent("e victed.json")
        let placeholder = evicted.deletingLastPathComponent()
            .appendingPathComponent(".\(evicted.lastPathComponent).icloud")
        let placeholderBytes = Data("keep-me-évicted".utf8)
        fm.createFile(atPath: placeholder.path, contents: placeholderBytes)
        let duplicate = run([
            "--json", "--library", evicted.path,
            "snippet", "add", "--trigger", ":eml", "--text", "other",
        ], environment: isolated)
        XCTAssertEqual(duplicate.code, 1, duplicate.out + duplicate.err)
        XCTAssertEqual((try jsonObject(duplicate.out))["error"] as? String, "save_refused")
        XCTAssertNotEqual((try jsonObject(duplicate.out))["error"] as? String, "duplicate_trigger")
        XCTAssertFalse(fm.fileExists(atPath: evicted.path))
        assertFileEquals(placeholder, placeholderBytes, "placeholder after :eml")
        let freshTrigger = run([
            "--json", "--library", evicted.path + "/",
            "snippet", "add", "--trigger", ":not-a-demo", "--text", "nope",
        ], environment: isolated)
        XCTAssertEqual(freshTrigger.code, 1, freshTrigger.out + freshTrigger.err)
        XCTAssertEqual((try jsonObject(freshTrigger.out))["error"] as? String, "save_refused")
        XCTAssertFalse(fm.fileExists(atPath: evicted.path))
        assertFileEquals(placeholder, placeholderBytes, "placeholder after fresh trigger")
        let status = run(["--json", "--library", evicted.path, "status"], environment: isolated)
        XCTAssertEqual(status.code, 1, status.out + status.err)
        XCTAssertEqual((try jsonObject(status.out))["error"] as? String, "library_missing")
        XCTAssertFalse(fm.fileExists(atPath: evicted.path))
        assertFileEquals(placeholder, placeholderBytes, "placeholder after status")

        let absent = directory.appendingPathComponent("really-absent.json")
        let created = run([
            "--json", "--library", absent.path,
            "snippet", "add", "--trigger", ":mine", "--text", "body",
        ], environment: isolated)
        XCTAssertEqual(created.code, 0, created.out + created.err)
        XCTAssertEqual((try jsonObject(created.out))["seededExamples"] as? Bool, true)
        XCTAssertEqual(try listedTriggers(absent, environment: isolated), [":eml", ":func", ":hello", ":mine", ":tdate"])

        let nested = directory.appendingPathComponent("brand-new-parent").appendingPathComponent("snippets.json")
        let rejected = run([
            "--json", "--library", nested.path,
            "snippet", "add", "--trigger", ":eml", "--text", "other",
        ], environment: isolated)
        XCTAssertEqual(rejected.code, 1, rejected.out + rejected.err)
        XCTAssertEqual((try jsonObject(rejected.out))["error"] as? String, "duplicate_trigger")
        XCTAssertFalse(fm.fileExists(atPath: nested.path))
        let nestedParent = nested.deletingLastPathComponent()
        if fm.fileExists(atPath: nestedParent.path) {
            let kids = try fm.subpathsOfDirectory(atPath: nestedParent.path)
            XCTAssertEqual(kids, [], "rejected create left \(kids)")
        }

        let unicode = directory.appendingPathComponent("my lib").appendingPathComponent("ライブラリ.json")
        let unicodeAdd = run([
            "--json", "--library", unicode.path,
            "snippet", "add", "--trigger", ":uni", "--text", "ユニコード",
        ], environment: isolated)
        XCTAssertEqual(unicodeAdd.code, 0, unicodeAdd.out + unicodeAdd.err)
        XCTAssertEqual(try listedTriggers(unicode, environment: isolated), [":eml", ":func", ":hello", ":tdate", ":uni"])
        let fetched = run(["--json", "--library", unicode.path, "snippet", "get", ":uni"], environment: isolated)
        XCTAssertEqual(
            ((try jsonObject(fetched.out))["snippet"] as? [String: Any])?["replacement"] as? String,
            "ユニコード"
        )

        let slashTarget = directory.appendingPathComponent("slash.json")
        let slashAdd = run([
            "--json", "--library", slashTarget.path + "/",
            "snippet", "add", "--trigger", ":slash", "--text", "slash-body",
        ], environment: isolated)
        XCTAssertEqual(slashAdd.code, 0, slashAdd.out + slashAdd.err)
        var slashDir: ObjCBool = true
        XCTAssertTrue(fm.fileExists(atPath: slashTarget.path, isDirectory: &slashDir))
        XCTAssertFalse(slashDir.boolValue)
        let slashBefore = try Data(contentsOf: slashTarget)
        let slashStatus = run(["--json", "--library", slashTarget.path + "/", "status"], environment: isolated)
        XCTAssertEqual(slashStatus.code, 0, slashStatus.out + slashStatus.err)
        XCTAssertGreaterThan((try jsonObject(slashStatus.out))["snippets"] as? Int ?? 0, 0)
        assertFileEquals(slashTarget, slashBefore, "trailing-slash status")

        let missingSlash = directory.appendingPathComponent("nope.json")
        let missingStatus = run(["--json", "--library", missingSlash.path + "/", "status"], environment: isolated)
        XCTAssertEqual(missingStatus.code, 1)
        XCTAssertEqual((try jsonObject(missingStatus.out))["error"] as? String, "library_missing")
        XCTAssertFalse(fm.fileExists(atPath: missingSlash.path))

        let realDir = directory.appendingPathComponent("real-dir", isDirectory: true)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        let linkDir = directory.appendingPathComponent("link-dir")
        try fm.createSymbolicLink(atPath: linkDir.path, withDestinationPath: realDir.path)
        let dirStatus = run(["--json", "--library", linkDir.path, "status"], environment: isolated)
        XCTAssertEqual((try jsonObject(dirStatus.out))["error"] as? String, "library_not_file")
        let dirAdd = run([
            "--json", "--library", linkDir.path,
            "snippet", "add", "--trigger", ":x", "--text", "x",
        ], environment: isolated)
        XCTAssertEqual((try jsonObject(dirAdd.out))["error"] as? String, "library_not_file")
        XCTAssertFalse(fm.fileExists(atPath: realDir.appendingPathComponent("snippets.json").path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: linkDir.path), realDir.path)

        let danglingTarget = directory.appendingPathComponent("missing-target.json")
        let dangling = directory.appendingPathComponent("dangling.json")
        try fm.createSymbolicLink(atPath: dangling.path, withDestinationPath: danglingTarget.path)
        let danglingStatus = run(["--json", "--library", dangling.path, "status"], environment: isolated)
        XCTAssertEqual((try jsonObject(danglingStatus.out))["error"] as? String, "library_missing")
        XCTAssertFalse(fm.fileExists(atPath: danglingTarget.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dangling.path), danglingTarget.path)
        let danglingReject = run([
            "--json", "--library", dangling.path,
            "snippet", "add", "--trigger", ":eml", "--text", "other",
        ], environment: isolated)
        XCTAssertEqual(danglingReject.code, 1, danglingReject.out + danglingReject.err)
        XCTAssertEqual((try jsonObject(danglingReject.out))["error"] as? String, "duplicate_trigger")
        XCTAssertFalse(fm.fileExists(atPath: danglingTarget.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dangling.path), danglingTarget.path)

        let createTarget = directory.appendingPathComponent("create-target.json")
        let createLink = directory.appendingPathComponent("dangling-create.json")
        try fm.createSymbolicLink(atPath: createLink.path, withDestinationPath: createTarget.path)
        let createdViaLink = run([
            "--json", "--library", createLink.path,
            "snippet", "add", "--trigger", ":via-link", "--text", "through-symlink",
        ], environment: isolated)
        XCTAssertEqual(createdViaLink.code, 0, createdViaLink.out + createdViaLink.err)
        var createdDir: ObjCBool = true
        XCTAssertTrue(fm.fileExists(atPath: createLink.path, isDirectory: &createdDir))
        XCTAssertFalse(createdDir.boolValue)
        let viaTriggers = try listedTriggers(createLink, environment: isolated)
        XCTAssertTrue(viaTriggers.contains(":via-link"), viaTriggers.joined(separator: ","))
        XCTAssertTrue(viaTriggers.contains(":eml"), viaTriggers.joined(separator: ","))

        let loopA = directory.appendingPathComponent("loop-a")
        let loopB = directory.appendingPathComponent("loop-b")
        try fm.createSymbolicLink(atPath: loopA.path, withDestinationPath: loopB.path)
        try fm.createSymbolicLink(atPath: loopB.path, withDestinationPath: loopA.path)
        let loopAdd = run([
            "--json", "--library", loopA.path,
            "snippet", "add", "--trigger", ":eml", "--text", "other",
        ], environment: isolated)
        XCTAssertEqual(loopAdd.code, 1, loopAdd.out + loopAdd.err)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: loopA.path), loopB.path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: loopB.path), loopA.path)

        let reads = directory.appendingPathComponent("reads.json")
        let commands: [[String]] = [
            ["status"],
            ["group", "list"],
            ["secret", "list"],
            ["snippet", "list"],
            ["snippet", "search", "hi"],
            ["snippet", "get", ":eml"],
            ["snippet", "set", ":eml", "--text", "x"],
            ["snippet", "remove", ":eml"],
            ["expand", "--trigger", ":eml"],
        ]
        for command in commands {
            let result = run(["--json", "--library", reads.path] + command, environment: isolated)
            XCTAssertNotEqual(result.code, 0, "\(command) \(result.out) \(result.err)")
            XCTAssertFalse(fm.fileExists(atPath: reads.path), command.joined(separator: " "))
        }
        let inlineExpand = run(["--json", "--library", reads.path, "expand", "--text", "plain"], environment: isolated)
        XCTAssertEqual(inlineExpand.code, 0, inlineExpand.out)
        XCTAssertFalse(fm.fileExists(atPath: reads.path))

        let appSeed = directory.appendingPathComponent("app-seed.json")
        let store = SnippetStore(fileURL: appSeed)
        XCTAssertTrue(fm.fileExists(atPath: appSeed.path))
        XCTAssertTrue(store.loadSnippets().contains { $0.triggerKeyword == ":eml" })

        let roParent = directory.appendingPathComponent("ro-parent", isDirectory: true)
        try fm.createDirectory(at: roParent, withIntermediateDirectories: true)
        let roLib = roParent.appendingPathComponent("snippets.json")
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roParent.path) }
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: roParent.path)
        let roAdd = run([
            "--json", "--library", roLib.path,
            "snippet", "add", "--trigger", ":x", "--text", "hi",
        ], environment: isolated)
        XCTAssertNotEqual(roAdd.code, 0, roAdd.out + roAdd.err)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: roParent.path)
        XCTAssertFalse(fm.fileExists(atPath: roLib.path), roAdd.out + roAdd.err)
        let roKids = try fm.subpathsOfDirectory(atPath: roParent.path)
        XCTAssertEqual(roKids, [], "read-only create left \(roKids)")
    }

    /// Undecodable libraries fail status and keep their original bytes, including after a later write attempt.
    func testAdversarialUnreadableLibrariesKeepOriginalBytes() throws {
        let isolated = [SnippetStore.storeDirEnvKey: directory.appendingPathComponent("env-fallback-3").path]
        let cases: [(String, Data, Bool)] = [
            ("nul.json", Data(repeating: 0, count: 64), false),
            ("truncated.json", Data("{\"snippets\":".utf8), false),
            ("truncated-array.json", Data("[{".utf8), false),
            ("leading-ws.json", Data(" \n{\"snippets\":".utf8), false),
            ("ff.json", Data(repeating: 0xFF, count: 32), false),
            ("true.json", Data("true".utf8), false),
            ("garbage.json", Data(repeating: UInt8(ascii: "x"), count: 256 * 1024), false),
            ("spaces.json", Data(repeating: UInt8(ascii: " "), count: 256 * 1024), true),
            ("whitespace.json", Data(" \n\t\r\u{000B}\u{000C}\n".utf8), true),
            ("empty.json", Data(), true),
            ("legacy-empty.json", Data("[]".utf8), true),
        ]
        for (name, payload, readable) in cases {
            let url = directory.appendingPathComponent(name)
            try payload.write(to: url)
            let status = run(["--json", "--library", url.path, "status"], environment: isolated)
            assertFileEquals(url, payload, name)
            let body = try jsonObject(status.out)
            if readable {
                XCTAssertEqual(status.code, 0, "\(name) \(status.out) \(status.err)")
                XCTAssertEqual(body["ok"] as? Bool, true, name)
                XCTAssertEqual(body["snippets"] as? Int, 0, name)
                if name != "legacy-empty.json" {
                    XCTAssertEqual(body["groups"] as? Int, 0, name)
                }
            } else {
                XCTAssertEqual(status.code, 1, "\(name) \(status.out) \(status.err)")
                XCTAssertEqual(body["ok"] as? Bool, false, name)
                XCTAssertEqual(body["error"] as? String, "library_unreadable", name)
                XCTAssertNil(body["snippets"], name)
                let again = run(["--json", "--library", url.path, "status"], environment: isolated)
                XCTAssertEqual(again.code, 1, name)
                XCTAssertEqual((try jsonObject(again.out))["error"] as? String, "library_unreadable")
                assertFileEquals(url, payload, "\(name) second status")
                let human = run(["--library", url.path, "status"], environment: isolated)
                XCTAssertEqual(human.code, 1, human.out + human.err)
                XCTAssertFalse(human.out.contains("snippets: 0"), human.out)
                XCTAssertTrue(human.err.contains("error:"), human.err)
                assertFileEquals(url, payload, "\(name) human status")
            }
        }

        let corrupt = directory.appendingPathComponent("mutate.json")
        let original = Data("{\"snippets\":".utf8)
        try original.write(to: corrupt)
        let attempts: [[String]] = [
            ["snippet", "add", "--trigger", ":x", "--text", "hijack"],
            ["snippet", "set", ":eml", "--text", "hijack"],
            ["snippet", "remove", ":eml"],
            ["snippet", "list"],
            ["group", "list"],
            ["secret", "list"],
            ["expand", "--trigger", ":eml"],
        ]
        for command in attempts {
            let result = run(["--json", "--library", corrupt.path] + command, environment: isolated)
            assertFileEquals(corrupt, original, command.joined(separator: " ") + " " + result.out)
            if command.first == "snippet" && command.dropFirst().first == "add" {
                XCTAssertNotEqual(result.code, 0, result.out + result.err)
            }
        }

        let linkTarget = directory.appendingPathComponent("linked-corrupt.json")
        try original.write(to: linkTarget)
        let link = directory.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: linkTarget.path)
        let viaLink = run(["--json", "--library", link.path, "status"], environment: isolated)
        XCTAssertEqual(viaLink.code, 1, viaLink.out + viaLink.err)
        XCTAssertEqual((try jsonObject(viaLink.out))["error"] as? String, "library_unreadable")
        assertFileEquals(linkTarget, original, "symlink target")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), linkTarget.path)

        let clipPlain = run(["--json", "expand", "--text", "clip[%clipboard]{{clipboard}}end"], environment: isolated)
        XCTAssertEqual(clipPlain.code, 0, clipPlain.out + clipPlain.err)
        XCTAssertEqual((try jsonObject(clipPlain.out))["text"] as? String, "clip[]end")
        let clipFlag = run([
            "--json", "expand", "--text", "clip[%clipboard]{{clipboard}}end",
            "--clipboard", "SENTINEL4d7038",
        ], environment: isolated)
        XCTAssertEqual((try jsonObject(clipFlag.out))["text"] as? String, "clip[SENTINEL4d7038]SENTINEL4d7038end")
    }

    private func listedTriggers(_ url: URL, environment: [String: String]) throws -> [String] {
        let listed = run(["--json", "--library", url.path, "snippet", "list"], environment: environment)
        XCTAssertEqual(listed.code, 0, listed.out + listed.err)
        let rows = try XCTUnwrap((try jsonObject(listed.out))["snippets"] as? [[String: Any]])
        return rows.compactMap { $0["trigger"] as? String }.sorted()
    }

    private func assertFileEquals(
        _ url: URL,
        _ before: Data,
        _ note: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let after = try Data(contentsOf: url)
            XCTAssertTrue(
                after == before,
                "\(note): \(after.count) bytes vs \(before.count); head \(Array(after.prefix(16)))",
                file: file,
                line: line
            )
        } catch {
            XCTFail("\(note): \(error)", file: file, line: line)
        }
    }

    /// Pretty-printed objects one after another, including ones whose last value is itself an object.
    /// Splitting on a column-zero `}` drops that closer when the nested value already ends in `}`.
    private func topLevelJSONObjects(_ text: String) throws -> [[String: Any]] {
        var objects: [[String: Any]] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let start {
                    objects.append(try jsonObject(String(text[start...index])))
                }
            }
            index = text.index(after: index)
        }
        return objects
    }

    /// Pretty-printed objects, one after another. `JSONSerialization` accepts one value, so split
    /// where one object's closing brace ends and the next object begins.
    private func jsonObjects(_ text: String) throws -> [[String: Any]] {
        var objects: [[String: Any]] = []
        for piece in text.components(separatedBy: "\n}\n") {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let object = trimmed.hasSuffix("}") ? trimmed : trimmed + "}"
            objects.append(try jsonObject(object))
        }
        return objects
    }
}
