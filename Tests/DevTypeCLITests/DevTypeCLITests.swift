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
