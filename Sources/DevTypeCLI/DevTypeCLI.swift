import ExpanderEngine
import Foundation

/// Command-line entry for agents and scripts.
///
/// Read commands never create a library. Secret values are never printed or accepted: a secret's
/// text lives in the keychain, and a shell argument would land in history. Expansion does not
/// read the pasteboard; pass `--clipboard` when a template needs that text.
public enum DevTypeCLI {
    public static func run(
        _ arguments: [String],
        store: SnippetStore? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        stdout: ((String) -> Void)? = nil,
        stderr: ((String) -> Void)? = nil,
        input: (() -> String?)? = nil
    ) -> Int32 {
        let session = CLISession(
            stdout: stdout ?? write(FileHandle.standardOutput),
            stderr: stderr ?? write(FileHandle.standardError),
            input: input ?? { readLine(strippingNewline: true) }
        )
        do {
            let parsed = try CLIArguments.parse(arguments)
            if parsed.help || parsed.positionals.isEmpty {
                session.writeOut(CLIHelp.text)
                return 0
            }
            session.json = parsed.json
            session.allowDisabled = parsed.allowDisabled
            return try dispatch(
                parsed,
                store: store,
                environment: environment,
                defaults: defaults,
                session: session
            )
        } catch let failure as CLIFailure {
            // Parse fails before `session.json` is assigned. `--json` earlier in the
            // argument list still has to make that failure a JSON object on stdout.
            if arguments.contains("--json") {
                session.json = true
            }
            session.fail(failure)
            return session.code
        } catch {
            session.fail(.failed("failed", error.localizedDescription))
            return session.code
        }
    }
}

enum CLIPaths {
    static func usesAppSupport(explicit: String?, environment: [String: String]) -> Bool {
        if let explicit, !explicit.isEmpty { return false }
        if let dir = environment[SnippetStore.storeDirEnvKey], !dir.isEmpty { return false }
        return true
    }

    static func libraryURL(
        explicit: String?,
        environment: [String: String],
        defaults: UserDefaults
    ) -> URL {
        if let explicit, !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }
        return SnippetStore.resolveLocation(environment: environment, defaults: defaults).fileURL
    }

    static func supportDirectory(library: URL, usesAppSupport: Bool) -> URL {
        usesAppSupport ? SnippetStore.defaultLocalSupportDirectory : library.deletingLastPathComponent()
    }
}

private func write(_ handle: FileHandle) -> (String) -> Void {
    { text in
        try? handle.write(contentsOf: Data(text.utf8))
    }
}

private enum CLIFailure: Error {
    case usage(String)
    case failed(String, String)
}

private struct CLIArguments {
    var json = false
    var allowDisabled = false
    var help = false
    var library: String?
    var options: [String: String] = [:]
    var positionals: [String] = []

    static let valued: Set<String> = [
        "library", "group", "trigger", "text", "title", "limit", "typed", "now", "clipboard",
        "enabled", "case-sensitive", "propagate-case", "word-boundary",
    ]

    static func parse(_ arguments: [String]) throws -> CLIArguments {
        var parsed = CLIArguments()
        var index = 0
        var ended = false
        while index < arguments.count {
            let token = arguments[index]
            if !ended, token == "--" {
                ended = true
                index += 1
                continue
            }
            if !ended, token.hasPrefix("-") {
                try consumeFlag(token, arguments: arguments, index: &index, parsed: &parsed)
                index += 1
                continue
            }
            parsed.positionals.append(token)
            index += 1
        }
        return parsed
    }

    private static func consumeFlag(
        _ token: String,
        arguments: [String],
        index: inout Int,
        parsed: inout CLIArguments
    ) throws {
        if token == "-h" {
            parsed.help = true
            return
        }
        guard token.hasPrefix("--"), token.count > 2 else {
            throw CLIFailure.usage("Unknown flag \(token).")
        }
        let raw = String(token.dropFirst(2))
        let name: String
        let inline: String?
        if let eq = raw.firstIndex(of: "=") {
            name = String(raw[..<eq])
            inline = String(raw[raw.index(after: eq)...])
        } else {
            name = raw
            inline = nil
        }
        guard !name.isEmpty else { throw CLIFailure.usage("Unknown flag \(token).") }
        switch name {
        case "json":
            guard inline == nil else { throw CLIFailure.usage("--json does not take a value.") }
            parsed.json = true
        case "help":
            guard inline == nil else { throw CLIFailure.usage("--help does not take a value.") }
            parsed.help = true
        case "allow-disabled":
            guard inline == nil else { throw CLIFailure.usage("--allow-disabled does not take a value.") }
            parsed.allowDisabled = true
        case _ where valued.contains(name):
            let value = try inline ?? takeValue(named: name, arguments: arguments, index: &index)
            if name == "library" {
                parsed.library = value
            } else {
                parsed.options[name] = value
            }
        default:
            throw CLIFailure.usage("Unknown flag --\(name).")
        }
    }

    private static func takeValue(named name: String, arguments: [String], index: inout Int) throws -> String {
        let next = index + 1
        guard next < arguments.count else { throw CLIFailure.usage("Missing value for --\(name).") }
        index = next
        return arguments[next]
    }
}

private final class CLISession {
    var json = false
    var allowDisabled = false
    var code: Int32 = 0
    let stdout: (String) -> Void
    let stderr: (String) -> Void
    let input: () -> String?

    init(stdout: @escaping (String) -> Void, stderr: @escaping (String) -> Void, input: @escaping () -> String?) {
        self.stdout = stdout
        self.stderr = stderr
        self.input = input
    }

    func writeOut(_ text: String) {
        stdout(text.hasSuffix("\n") ? text : text + "\n")
    }

    func succeed(_ fields: [String: Any], human: String) throws {
        if json {
            var object = fields
            object["ok"] = true
            writeOut(try CLIJSON.string(object))
        } else {
            writeOut(human)
        }
    }

    func fail(_ failure: CLIFailure) {
        let codeName: String
        let message: String
        switch failure {
        case .usage(let text):
            codeName = "usage"
            message = text
            code = 2
        case .failed(let name, let text):
            codeName = name
            message = text
            code = 1
        }
        if json {
            let object: [String: Any] = ["ok": false, "error": codeName, "message": message]
            writeOut((try? CLIJSON.string(object)) ?? "{\"ok\":false,\"error\":\"failed\"}\n")
        } else {
            let line = "error: \(message)\n"
            stderr(line.hasSuffix("\n") ? line : line + "\n")
        }
    }
}

private enum CLIJSON {
    static func string(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CLIFailure.failed("failed", "Could not encode the command result.")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIFailure.failed("failed", "Could not encode the command result.")
        }
        return text + "\n"
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func date(from text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

private func dispatch(
    _ parsed: CLIArguments,
    store injected: SnippetStore?,
    environment: [String: String],
    defaults: UserDefaults,
    session: CLISession
) throws -> Int32 {
    let command = parsed.positionals[0]
    let rest = Array(parsed.positionals.dropFirst())
    switch command {
    case "help":
        session.writeOut(CLIHelp.text)
        return 0
    case "repl":
        guard rest.isEmpty else { throw CLIFailure.usage("repl takes no arguments.") }
        return try CLIRepl.run(
            store: injected,
            environment: environment,
            defaults: defaults,
            session: session,
            base: parsed
        )
    case "status":
        guard rest.isEmpty else { throw CLIFailure.usage("status takes no arguments.") }
        try CLICommands.status(parsed, store: injected, environment: environment, defaults: defaults, session: session)
    case "group":
        try CLICommands.group(rest, parsed: parsed, store: injected, environment: environment, defaults: defaults, session: session)
    case "secret":
        try CLICommands.secret(rest, parsed: parsed, store: injected, environment: environment, defaults: defaults, session: session)
    case "snippet":
        try CLICommands.snippet(rest, parsed: parsed, store: injected, environment: environment, defaults: defaults, session: session)
    case "expand":
        guard rest.isEmpty else { throw CLIFailure.usage("expand takes flags, not extra arguments.") }
        try CLICommands.expand(parsed, store: injected, environment: environment, defaults: defaults, session: session)
    default:
        throw CLIFailure.usage("Unknown command \(command). Run devtype-cli --help.")
    }
    return 0
}

private enum CLILibrary {
    static func url(
        _ parsed: CLIArguments,
        environment: [String: String],
        defaults: UserDefaults
    ) -> URL {
        CLIPaths.libraryURL(explicit: parsed.library, environment: environment, defaults: defaults)
    }

    static func existingFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CLIFailure.failed("library_missing", "No library at \(url.path).")
        }
        guard !isDirectory.boolValue else {
            throw CLIFailure.failed("library_not_file", "Library path is a directory: \(url.path).")
        }
    }

    static func open(
        _ parsed: CLIArguments,
        environment: [String: String],
        defaults: UserDefaults,
        create: Bool
    ) throws -> (store: SnippetStore, created: Bool) {
        let url = url(parsed, environment: environment, defaults: defaults)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists {
            guard !isDirectory.boolValue else {
                throw CLIFailure.failed("library_not_file", "Library path is a directory: \(url.path).")
            }
        } else if !create {
            throw CLIFailure.failed("library_missing", "No library at \(url.path).")
        }
        if !exists {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let appSupport = CLIPaths.usesAppSupport(explicit: parsed.library, environment: environment)
        let store = SnippetStore(
            location: SnippetStore.Location(fileURL: url, expectsExistingLibrary: exists),
            deviceDefaults: defaults,
            localSupportDirectory: CLIPaths.supportDirectory(library: url, usesAppSupport: appSupport),
            watcherFactory: { _ in nil },
            secretStore: SecretStore(backing: InMemorySecretBackingStore()),
            secretPurgeEnabled: false
        )
        return (store, !exists)
    }

    static func store(
        _ parsed: CLIArguments,
        injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        create: Bool
    ) throws -> (store: SnippetStore, created: Bool) {
        if let injected { return (injected, false) }
        return try open(parsed, environment: environment, defaults: defaults, create: create)
    }
}

private struct SnippetPlace {
    var group: Int
    var snippet: Int
}

private enum CLISnippets {
    static func places(matching ref: String, in groups: [SnippetGroup]) -> [SnippetPlace] {
        if let id = UUID(uuidString: ref) {
            return walk(groups) { $0.id == id }
        }
        let exact = walk(groups) { $0.triggerKeyword == ref }
        if !exact.isEmpty { return exact }
        return walk(groups) {
            $0.triggerKeyword.compare(ref, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private static func walk(_ groups: [SnippetGroup], where matches: (SnippetModel) -> Bool) -> [SnippetPlace] {
        var found: [SnippetPlace] = []
        for group in groups.indices {
            for snippet in groups[group].snippets.indices where matches(groups[group].snippets[snippet]) {
                found.append(SnippetPlace(group: group, snippet: snippet))
            }
        }
        return found
    }

    static func one(matching ref: String, in groups: [SnippetGroup]) throws -> SnippetPlace {
        let found = places(matching: ref, in: groups)
        if found.isEmpty { throw CLIFailure.failed("not_found", "No snippet matches \(ref).") }
        if found.count > 1 {
            let ids = found.map { groups[$0.group].snippets[$0.snippet].id.uuidString }.joined(separator: ", ")
            throw CLIFailure.failed("ambiguous", "\(ref) matches more than one snippet: \(ids).")
        }
        return found[0]
    }

    static func userGroupIndex(named name: String, in groups: [SnippetGroup]) -> Int? {
        groups.firstIndex { group in
            group.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && !group.snippets.contains(where: \.isSecret)
        }
    }

    /// Exact trigger text always collides. A case-insensitive pair also collides when neither
    /// snippet opted into case sensitivity. Secrets count: `get` would otherwise be ambiguous.
    static func triggerTaken(
        _ trigger: String,
        caseSensitive: Bool,
        in groups: [SnippetGroup],
        ignoring id: UUID? = nil
    ) -> Bool {
        groups.contains { group in
            group.snippets.contains { snippet in
                if let id, snippet.id == id { return false }
                if snippet.triggerKeyword == trigger { return true }
                let folded = snippet.triggerKeyword.compare(
                    trigger,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
                return folded && !snippet.isCaseSensitive && !caseSensitive
            }
        }
    }

    static func isSecretGroup(named name: String, in groups: [SnippetGroup]) -> Bool {
        groups.contains { group in
            group.snippets.contains(where: \.isSecret)
                && group.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    static func object(_ snippet: SnippetModel, group: SnippetGroup, score: Int? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "id": snippet.id.uuidString,
            "trigger": snippet.triggerKeyword,
            "title": snippet.title,
            "label": snippet.label,
            "group": group.name,
            "groupId": group.id.uuidString,
            "enabled": snippet.enabled,
            "groupEnabled": group.enabled,
            "secret": snippet.isSecret,
            "caseSensitive": snippet.isCaseSensitive,
            "propagateCase": snippet.propagateCase,
            "wordBoundary": snippet.requireWordBoundary,
            "plainText": snippet.isPlainText,
            "createdAt": CLIJSON.iso(snippet.createdAt),
            "updatedAt": CLIJSON.iso(snippet.updatedAt),
        ]
        if let score { object["score"] = score }
        guard !snippet.isSecret else { return object }
        object["replacement"] = snippet.replacementText
        if !snippet.imagePath.isEmpty { object["image"] = snippet.imagePath }
        if !snippet.tags.isEmpty { object["tags"] = snippet.tags }
        return object
    }

    static func line(_ snippet: SnippetModel, group: SnippetGroup) -> String {
        var flags: [String] = []
        if snippet.isSecret { flags.append("secret") }
        if !snippet.enabled || !group.enabled { flags.append("disabled") }
        if !snippet.imagePath.isEmpty && !snippet.isSecret { flags.append("image") }
        let suffix = flags.isEmpty ? "" : "\t" + flags.joined(separator: ",")
        return "\(snippet.id.uuidString)\t\(snippet.triggerKeyword)\t\(snippet.displayTitle)\t\(group.name)\(suffix)"
    }
}

private enum CLICommands {
    static func status(
        _ parsed: CLIArguments,
        store injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession
    ) throws {
        let opened = try CLILibrary.store(parsed, injected: injected, environment: environment, defaults: defaults, create: false)
        let groups = opened.store.loadSnippetGroups()
        let snippets = groups.flatMap(\.snippets)
        let secrets = opened.store.loadSecrets()
        let fields: [String: Any] = [
            "library": opened.store.activeLocationURL.path,
            "groups": groups.count,
            "snippets": snippets.count,
            "secrets": secrets.count,
        ]
        let human = """
        library: \(opened.store.activeLocationURL.path)
        groups: \(groups.count)
        snippets: \(snippets.count)
        secrets: \(secrets.count)
        """
        try session.succeed(fields, human: human)
    }

    static func group(
        _ rest: [String],
        parsed: CLIArguments,
        store injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession
    ) throws {
        guard rest == ["list"] else { throw CLIFailure.usage("Usage: devtype-cli group list") }
        let opened = try CLILibrary.store(parsed, injected: injected, environment: environment, defaults: defaults, create: false)
        let rows: [[String: Any]] = opened.store.loadSnippetGroups().map { group in
            [
                "id": group.id.uuidString,
                "name": group.name,
                "enabled": group.enabled,
                "snippets": group.snippets.count,
            ]
        }
        let human = rows.map { row in
            let name = row["name"] as? String ?? ""
            let count = row["snippets"] as? Int ?? 0
            let enabled = (row["enabled"] as? Bool) == true ? "" : "\tdisabled"
            return "\(name)\t\(count)\(enabled)"
        }.joined(separator: "\n")
        try session.succeed(["groups": rows], human: human.isEmpty ? "(no groups)" : human)
    }

    /// Metadata only. A secret has no trigger and its value stays in the keychain, which this
    /// command does not open.
    static func secret(
        _ rest: [String],
        parsed: CLIArguments,
        store injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession
    ) throws {
        guard rest == ["list"] else { throw CLIFailure.usage("Usage: devtype-cli secret list") }
        let opened = try CLILibrary.store(parsed, injected: injected, environment: environment, defaults: defaults, create: false)
        let secrets = opened.store.loadSecrets()
        let rows: [[String: Any]] = secrets.map { secret in
            var row: [String: Any] = [
                "id": secret.id.uuidString,
                "title": secret.title,
                "label": secret.label,
                "enabled": secret.enabled,
                "createdAt": CLIJSON.iso(secret.createdAt),
                "updatedAt": CLIJSON.iso(secret.updatedAt),
            ]
            if !secret.tags.isEmpty { row["tags"] = secret.tags }
            return row
        }
        let lines = secrets.map { secret in
            let enabled = secret.enabled ? "" : "\tdisabled"
            return "\(secret.id.uuidString)\t\(secret.displayTitle)\(enabled)"
        }
        try session.succeed(["secrets": rows], human: lines.isEmpty ? "(no secrets)" : lines.joined(separator: "\n"))
    }

    static func snippet(
        _ rest: [String],
        parsed: CLIArguments,
        store injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession
    ) throws {
        guard let verb = rest.first else { throw CLIFailure.usage("Usage: devtype-cli snippet list|search|get|add|set|remove") }
        let args = Array(rest.dropFirst())
        switch verb {
        case "list":
            try list(args, parsed: parsed, store: injected, environment: environment, defaults: defaults, session: session)
        case "search":
            try search(args, parsed: parsed, store: injected, environment: environment, defaults: defaults, session: session)
        case "get":
            try get(args, parsed: parsed, store: injected, environment: environment, defaults: defaults, session: session)
        case "add":
            try add(args, parsed: parsed, store: injected, environment: environment, defaults: defaults, session: session)
        case "set":
            try set(args, parsed: parsed, store: injected, environment: environment, defaults: defaults, session: session)
        case "remove":
            try remove(args, parsed: parsed, store: injected, environment: environment, defaults: defaults, session: session)
        default:
            throw CLIFailure.usage("Unknown snippet command \(verb).")
        }
    }

    private static func list(
        _ args: [String],
        parsed: CLIArguments,
        store injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession
    ) throws {
        guard args.isEmpty else { throw CLIFailure.usage("snippet list takes no positional arguments.") }
        let limit = try optionalLimit(parsed)
        let opened = try CLILibrary.store(parsed, injected: injected, environment: environment, defaults: defaults, create: false)
        let groups = opened.store.loadSnippetGroups()
        if let wanted = parsed.options["group"],
           !groups.contains(where: {
               $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
           }) {
            throw CLIFailure.failed("group_not_found", "No group named \(wanted).")
        }
        var rows: [[String: Any]] = []
        var lines: [String] = []
        for group in groups {
            if let wanted = parsed.options["group"],
               group.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
                continue
            }
            for snippet in group.snippets {
                rows.append(CLISnippets.object(snippet, group: group))
                lines.append(CLISnippets.line(snippet, group: group))
                if let limit, rows.count >= limit { break }
            }
            if let limit, rows.count >= limit { break }
        }
        try session.succeed(["snippets": rows], human: lines.isEmpty ? "(no snippets)" : lines.joined(separator: "\n"))
    }

    private static func search(
        _ args: [String],
        parsed: CLIArguments,
        store injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession
    ) throws {
        let query = args.joined(separator: " ")
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIFailure.usage("Usage: devtype-cli snippet search <query>")
        }
        if let issue = SnippetSearch.queryIssue(for: query) {
            throw CLIFailure.failed("invalid_query", issue.message())
        }
        let limit = try optionalLimit(parsed)
        let opened = try CLILibrary.store(parsed, injected: injected, environment: environment, defaults: defaults, create: false)
        let snapshot = opened.store.loadGroupsWithRevision()
        let groups = SnippetDocument(groups: snapshot.groups).groups
        let hits = SnippetSearch.run(
            query: query,
            in: groups,
            includeDisabled: true,
            limit: limit,
            revision: snapshot.revision,
            libraryID: opened.store.searchCacheIdentity
        )
        let rows = hits.map { CLISnippets.object($0.snippet, group: group(named: $0.groupName, id: $0.groupID, fallback: $0.snippet), score: $0.score) }
        let lines = hits.map { CLISnippets.line($0.snippet, group: group(named: $0.groupName, id: $0.groupID, fallback: $0.snippet)) }
        func group(named name: String, id: UUID, fallback: SnippetModel) -> SnippetGroup {
            snapshot.groups.first { $0.id == id } ?? SnippetGroup(id: id, name: name, snippets: [fallback])
        }
        try session.succeed(["snippets": rows], human: lines.isEmpty ? "(no matches)" : lines.joined(separator: "\n"))
    }

    private static func get(
        _ args: [String],
        parsed: CLIArguments,
        store injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession
    ) throws {
        guard args.count == 1 else { throw CLIFailure.usage("Usage: devtype-cli snippet get <id-or-trigger>") }
        let opened = try CLILibrary.store(parsed, injected: injected, environment: environment, defaults: defaults, create: false)
        let groups = opened.store.loadGroups()
        let place = try CLISnippets.one(matching: args[0], in: groups)
        let group = groups[place.group]
        let snippet = group.snippets[place.snippet]
        let human = snippet.isSecret
            ? "id: \(snippet.id.uuidString)\ntrigger: \(snippet.triggerKeyword)\ntitle: \(snippet.title)\ngroup: \(group.name)\nsecret: true"
            : "id: \(snippet.id.uuidString)\ntrigger: \(snippet.triggerKeyword)\ntitle: \(snippet.title)\ngroup: \(group.name)\nenabled: \(snippet.enabled)\n\n\(snippet.replacementText)"
        try session.succeed(["snippet": CLISnippets.object(snippet, group: group)], human: human)
    }

    private static func add(
        _ args: [String],
        parsed: CLIArguments,
        store injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession
    ) throws {
        guard args.isEmpty else { throw CLIFailure.usage("snippet add takes flags, not positional arguments.") }
        guard let trigger = parsed.options["trigger"], !trigger.isEmpty else {
            throw CLIFailure.usage("snippet add requires --trigger.")
        }
        guard let text = parsed.options["text"] else { throw CLIFailure.usage("snippet add requires --text.") }
        let title = parsed.options["title"] ?? trigger
        let enabled = try boolFlag("enabled", parsed: parsed) ?? true
        let caseSensitive = try boolFlag("case-sensitive", parsed: parsed) ?? false
        let propagate = try boolFlag("propagate-case", parsed: parsed) ?? false
        let boundary = try boolFlag("word-boundary", parsed: parsed) ?? true
        let groupName = parsed.options["group"] ?? SnippetDocument.defaultGroupName
        guard !groupName.isEmpty else { throw CLIFailure.usage("--group cannot be empty.") }
        let opened = try CLILibrary.store(parsed, injected: injected, environment: environment, defaults: defaults, create: true)
        let createdID = UUID()
        var groupCreated = false
        var rejected = CLIFailure.failed("duplicate_trigger", "A snippet already uses the trigger \(trigger).")
        let result = opened.store.mutateGroups { groups in
            if CLISnippets.triggerTaken(trigger, caseSensitive: caseSensitive, in: groups) {
                return false
            }
            let snippet = SnippetModel(
                id: createdID,
                title: title,
                triggerKeyword: trigger,
                replacementText: text,
                isCaseSensitive: caseSensitive,
                propagateCase: propagate,
                requireWordBoundary: boundary,
                enabled: enabled
            )
            if let index = CLISnippets.userGroupIndex(named: groupName, in: groups) {
                groups[index].snippets.append(snippet)
            } else if CLISnippets.isSecretGroup(named: groupName, in: groups) {
                rejected = .failed("secret_refused", "Cannot add a snippet to the secret group.")
                return false
            } else {
                groups.append(SnippetGroup(name: groupName, snippets: [snippet]))
                groupCreated = true
            }
            return true
        }
        switch result {
        case .saved, .unchanged:
            break
        case .rejected:
            throw rejected
        case .refused(let outcome):
            throw saveFailure(outcome)
        }
        let groups = opened.store.loadGroups()
        guard let place = CLISnippets.places(matching: createdID.uuidString, in: groups).first else {
            throw CLIFailure.failed("failed", "The snippet was saved but could not be read back.")
        }
        try session.succeed(
            [
                "snippet": CLISnippets.object(groups[place.group].snippets[place.snippet], group: groups[place.group]),
                "seededExamples": opened.created,
                "groupCreated": groupCreated,
            ],
            human: "added \(trigger) \(createdID.uuidString)"
        )
    }

    private static func set(
        _ args: [String],
        parsed: CLIArguments,
        store injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession
    ) throws {
        guard args.count == 1 else { throw CLIFailure.usage("Usage: devtype-cli snippet set <id-or-trigger> [--text ...] [--title ...] [--trigger ...] [--group ...]") }
        let changes = parsed.options.keys.contains { ["text", "title", "trigger", "group", "enabled", "case-sensitive", "propagate-case", "word-boundary"].contains($0) }
        guard changes else { throw CLIFailure.usage("snippet set needs at least one of --text, --title, --trigger, --group, --enabled, --case-sensitive, --propagate-case, --word-boundary.") }
        if let trigger = parsed.options["trigger"], trigger.isEmpty {
            throw CLIFailure.usage("--trigger cannot be empty.")
        }
        if let group = parsed.options["group"], group.isEmpty {
            throw CLIFailure.usage("--group cannot be empty.")
        }
        let enabled = try boolFlag("enabled", parsed: parsed)
        let caseSensitive = try boolFlag("case-sensitive", parsed: parsed)
        let propagate = try boolFlag("propagate-case", parsed: parsed)
        let boundary = try boolFlag("word-boundary", parsed: parsed)
        let opened = try CLILibrary.store(parsed, injected: injected, environment: environment, defaults: defaults, create: false)
        var reason = "not_found"
        var message = "No snippet matches \(args[0])."
        var editedID = ""
        let result = opened.store.mutateGroups { groups in
            let place: SnippetPlace
            do {
                place = try CLISnippets.one(matching: args[0], in: groups)
            } catch let failure as CLIFailure {
                if case .failed(let code, let text) = failure {
                    reason = code
                    message = text
                }
                return false
            } catch {
                return false
            }
            if groups[place.group].snippets[place.snippet].isSecret {
                reason = "secret_refused"
                message = "Secret snippets cannot be changed from the command line."
                return false
            }
            var snippet = groups[place.group].snippets[place.snippet]
            if let text = parsed.options["text"] { snippet.replacementText = text }
            if let title = parsed.options["title"] { snippet.title = title }
            if let trigger = parsed.options["trigger"] { snippet.triggerKeyword = trigger }
            if let enabled { snippet.enabled = enabled }
            if let caseSensitive { snippet.isCaseSensitive = caseSensitive }
            if let propagate { snippet.propagateCase = propagate }
            if let boundary { snippet.requireWordBoundary = boundary }
            snippet.updatedAt = Date()
            if CLISnippets.triggerTaken(snippet.triggerKeyword, caseSensitive: snippet.isCaseSensitive, in: groups, ignoring: snippet.id) {
                reason = "duplicate_trigger"
                message = "A snippet already uses the trigger \(snippet.triggerKeyword)."
                return false
            }
            editedID = snippet.id.uuidString
            let destination = parsed.options["group"]
            let stays = destination == nil || groups[place.group].name.compare(
                destination ?? "",
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
            if stays {
                groups[place.group].snippets[place.snippet] = snippet
                return true
            }
            guard let destination else { return false }
            groups[place.group].snippets.remove(at: place.snippet)
            if let index = CLISnippets.userGroupIndex(named: destination, in: groups) {
                groups[index].snippets.append(snippet)
            } else if CLISnippets.isSecretGroup(named: destination, in: groups) {
                reason = "secret_refused"
                message = "Cannot move a snippet into the secret group."
                return false
            } else {
                groups.append(SnippetGroup(name: destination, snippets: [snippet]))
            }
            return true
        }
        switch result {
        case .saved, .unchanged:
            let groups = opened.store.loadGroups()
            let place = try CLISnippets.one(matching: editedID, in: groups)
            let snippet = groups[place.group].snippets[place.snippet]
            try session.succeed(
                ["snippet": CLISnippets.object(snippet, group: groups[place.group])],
                human: "updated \(snippet.triggerKeyword)"
            )
        case .rejected:
            throw CLIFailure.failed(reason, message)
        case .refused(let outcome):
            throw saveFailure(outcome)
        }
    }

    private static func remove(
        _ args: [String],
        parsed: CLIArguments,
        store injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession
    ) throws {
        guard args.count == 1 else { throw CLIFailure.usage("Usage: devtype-cli snippet remove <id-or-trigger>") }
        let opened = try CLILibrary.store(parsed, injected: injected, environment: environment, defaults: defaults, create: false)
        var reason = "not_found"
        var message = "No snippet matches \(args[0])."
        var removedID = ""
        let result = opened.store.mutateGroups { groups in
            let place: SnippetPlace
            do {
                place = try CLISnippets.one(matching: args[0], in: groups)
            } catch let failure as CLIFailure {
                if case .failed(let code, let text) = failure {
                    reason = code
                    message = text
                }
                return false
            } catch {
                return false
            }
            if groups[place.group].snippets[place.snippet].isSecret {
                reason = "secret_refused"
                message = "Secret snippets cannot be removed from the command line."
                return false
            }
            removedID = groups[place.group].snippets[place.snippet].id.uuidString
            groups[place.group].snippets.remove(at: place.snippet)
            return true
        }
        switch result {
        case .saved, .unchanged:
            try session.succeed(["removed": removedID], human: "removed \(removedID)")
        case .rejected:
            throw CLIFailure.failed(reason, message)
        case .refused(let outcome):
            throw saveFailure(outcome)
        }
    }

    static func expand(
        _ parsed: CLIArguments,
        store injected: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession
    ) throws {
        let trigger = parsed.options["trigger"]
        let inline = parsed.options["text"]
        switch (trigger, inline) {
        case (.some, .some):
            throw CLIFailure.usage("expand takes either --trigger or --text, not both.")
        case (nil, nil):
            throw CLIFailure.usage("expand requires --trigger or --text.")
        default:
            break
        }
        let now = try parsed.options["now"].map { text -> Date in
            guard let date = CLIJSON.date(from: text) else {
                throw CLIFailure.usage("--now expects an ISO-8601 timestamp.")
            }
            return date
        } ?? Date()
        let clipboard = parsed.options["clipboard"] ?? ""
        let content: String
        let shape: TriggerCaseShape
        if let inline {
            content = inline
            shape = .asWritten
        } else if let trigger {
            let opened = try CLILibrary.store(parsed, injected: injected, environment: environment, defaults: defaults, create: false)
            let groups = opened.store.loadGroups()
            let place = try CLISnippets.one(matching: trigger, in: groups)
            let group = groups[place.group]
            let snippet = group.snippets[place.snippet]
            if snippet.isSecret {
                throw CLIFailure.failed("secret_refused", "Secret snippets cannot be expanded from the command line.")
            }
            if snippet.isImageSnippet {
                throw CLIFailure.failed("image_snippet", "Image snippets are pasted by the app, not expanded as text.")
            }
            if (!snippet.enabled || !group.enabled) && !session.allowDisabled {
                throw CLIFailure.failed("disabled", "The snippet is disabled. Pass --allow-disabled to expand it anyway.")
            }
            content = snippet.replacementText
            shape = TriggerCaseShape.forExpansion(of: snippet, typedTrigger: parsed.options["typed"])
            let lookup = nestedLookup(groups)
            try render(content: content, lookup: lookup, clipboard: clipboard, now: now, shape: shape, session: session)
            return
        } else {
            throw CLIFailure.usage("expand requires --trigger or --text.")
        }
        try render(content: content, lookup: { _ in nil }, clipboard: clipboard, now: now, shape: shape, session: session)
    }

    private static func render(
        content: String,
        lookup: @escaping (String) -> String?,
        clipboard: String,
        now: Date,
        shape: TriggerCaseShape,
        session: CLISession
    ) throws {
        let rendered = MacroRenderer.expand(
            content: content,
            lookup: lookup,
            clipboardText: clipboard,
            now: now,
            caseShape: shape
        )
        if let failure = rendered.failure {
            throw CLIFailure.failed("render_failed", failure.message)
        }
        let fields: [String: Any] = [
            "text": rendered.text,
            "cursorOffset": rendered.cursorOffset ?? NSNull(),
            "needsFillIn": rendered.needsFillIn,
            "fillFields": rendered.fillFields.map(fillObject),
            "trailingKeys": rendered.trailingKeys,
        ]
        try session.succeed(fields, human: rendered.text)
    }

    private static func nestedLookup(_ groups: [SnippetGroup]) -> (String) -> String? {
        var table: [String: String] = [:]
        for group in groups where group.enabled {
            for snippet in group.snippets where snippet.enabled && !snippet.isSecret && !snippet.triggerKeyword.isEmpty {
                if table[snippet.triggerKeyword] == nil {
                    table[snippet.triggerKeyword] = snippet.replacementText
                }
            }
        }
        return { table[$0] }
    }

    private static func fillObject(_ field: FillField) -> [String: Any] {
        let kind: String
        var object: [String: Any] = [
            "id": field.id,
            "name": field.name,
            "default": field.defaultValue,
        ]
        switch field.kind {
        case .text: kind = "text"
        case .area: kind = "area"
        case .part: kind = "part"
        case .popup(let options):
            kind = "popup"
            object["options"] = options
        }
        object["kind"] = kind
        return object
    }

    private static func optionalLimit(_ parsed: CLIArguments) throws -> Int? {
        guard let raw = parsed.options["limit"] else { return nil }
        guard let value = Int(raw), value > 0, value <= 100_000 else {
            throw CLIFailure.usage("--limit expects a positive integer up to 100000.")
        }
        return value
    }

    private static func boolFlag(_ name: String, parsed: CLIArguments) throws -> Bool? {
        guard let raw = parsed.options[name] else { return nil }
        switch raw.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: throw CLIFailure.usage("--\(name) expects true or false.")
        }
    }

    private static func saveFailure(_ outcome: SnippetStore.SaveOutcome) -> CLIFailure {
        switch outcome {
        case .saved, .savedWithoutBackup:
            return .failed("failed", "The library reported a save that did not commit.")
        case .blockedByNewerSchema:
            return .failed("save_refused", "The library was written by a newer DevType. Nothing was written.")
        case .blockedByRemoteChange:
            return .failed("save_refused", "The library changed on disk. Nothing was written.")
        case .failed(let message):
            return .failed("save_refused", message)
        }
    }
}

private enum CLIRepl {
    static func run(
        store: SnippetStore?,
        environment: [String: String],
        defaults: UserDefaults,
        session: CLISession,
        base: CLIArguments
    ) throws -> Int32 {
        // stderr, so a --json session's stdout stays a sequence of command results.
        session.stderr("devtype-cli repl. Type help or quit.\n")
        while let line = session.input() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed == "quit" || trimmed == "exit" { return 0 }
            if trimmed == "repl" {
                session.fail(.usage("Already in the repl."))
                continue
            }
            // Each line is parsed on its own. Without the session flags, `snippet list`
            // inside `devtype-cli --library <file> repl` would open the app's library.
            _ = DevTypeCLI.run(
                inheriting(base, line: split(trimmed)),
                store: store,
                environment: environment,
                defaults: defaults,
                stdout: session.stdout,
                stderr: session.stderr,
                input: session.input
            )
        }
        return 0
    }

    /// Session flags apply to every line. A flag written on the line wins.
    static func inheriting(_ base: CLIArguments, line: [String]) -> [String] {
        var prefix: [String] = []
        if base.json, !line.contains("--json") {
            prefix.append("--json")
        }
        if base.allowDisabled, !line.contains("--allow-disabled") {
            prefix.append("--allow-disabled")
        }
        if let library = base.library, !line.contains(where: { $0 == "--library" || $0.hasPrefix("--library=") }) {
            prefix.append(contentsOf: ["--library", library])
        }
        return prefix + line
    }

    /// Splits one line on whitespace, keeping single- or double-quoted spans.
    static func split(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", quote != nil {
                escaped = true
                continue
            }
            if let active = quote, character == active {
                quote = nil
                parts.append(current)
                current = ""
                continue
            }
            if quote == nil, character == "'" || character == "\"" {
                quote = character
                continue
            }
            if quote == nil, character == " " || character == "\t" {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

private enum CLIHelp {
    static let text = """
    devtype-cli — operate a DevType snippet library

    Reads and writes the library DevType itself uses. A missing library is left
    uncreated until `snippet add`. The first add on a new file also writes
    DevType's built-in examples. Secrets have no trigger and no body: `secret list`
    prints metadata, and set, remove, and expand refuse a secret id. Values stay
    in the keychain. Expansion does not read the pasteboard.

      devtype-cli [--json] [--library <file>] <command>

    Commands
      status
      group list
      secret list
      snippet list [--group <name>] [--limit <n>]
      snippet search <query> [--limit <n>]
                  a query that starts with - follows --
      snippet get <id-or-trigger>
      snippet add --trigger <trigger> --text <body> [--title <title>] [--group <name>]
                  [--enabled true|false] [--case-sensitive true|false]
                  [--propagate-case true|false] [--word-boundary true|false]
      snippet set <id-or-trigger> [--text <body>] [--title <title>] [--trigger <trigger>]
                  [--group <name>] [--enabled true|false] [--case-sensitive true|false]
                  [--propagate-case true|false] [--word-boundary true|false]
      snippet remove <id-or-trigger>
      expand (--trigger <trigger> | --text <body>) [--typed <typed>] [--now <iso8601>]
             [--clipboard <text>] [--allow-disabled]
      repl     keeps --json, --library, and --allow-disabled for each line

    --json prints one JSON object. Without it, expand prints the rendered text.
    ./Scripts/devtype runs the built binary.
    """
}
