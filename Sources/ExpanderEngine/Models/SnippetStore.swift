import CryptoKit
import Foundation

/// On-disk envelope for snippets. Versioned so future fields can migrate without wiping user data.
public struct SnippetDocument: Codable, Equatable {
    public static let currentSchemaVersion = 2
    public static let defaultGroupName = "General"

    public var schemaVersion: Int
    public var groups: [SnippetGroup]

    /// Flattened snippets for engine / legacy callers.
    public var snippets: [SnippetModel] {
        groups.flatMap(\.snippets)
    }

    public init(schemaVersion: Int = SnippetDocument.currentSchemaVersion, groups: [SnippetGroup]) {
        self.schemaVersion = schemaVersion
        self.groups = groups
    }

    /// Convenience: wrap a flat snippet list in the default group (v1 migration shape).
    public init(schemaVersion: Int = SnippetDocument.currentSchemaVersion, snippets: [SnippetModel]) {
        self.schemaVersion = schemaVersion
        self.groups = [SnippetGroup(name: Self.defaultGroupName, snippets: snippets)]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, groups, snippets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if let decodedGroups = try container.decodeIfPresent([SnippetGroup].self, forKey: .groups) {
            groups = decodedGroups
        } else if let legacySnippets = try container.decodeIfPresent([SnippetModel].self, forKey: .snippets) {
            groups = [SnippetGroup(name: Self.defaultGroupName, snippets: legacySnippets)]
        } else {
            groups = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(groups, forKey: .groups)
    }
}

public final class SnippetStore {
    public static let shared = SnippetStore()

    public enum LoadIssue: Equatable {
        case corrupted(backupURL: URL)
    }

    public enum SaveOutcome: Equatable {
        case saved
        case blockedByNewerSchema
        case blockedByRemoteChange
        case failed(String)

        public var didSave: Bool { self == .saved }
    }

    public struct Location: Equatable {
        public let fileURL: URL
        /// User explicitly chose this path (iCloud sync folder, Link, Save As).
        public let expectsExistingLibrary: Bool

        public init(fileURL: URL, expectsExistingLibrary: Bool) {
            self.fileURL = fileURL
            self.expectsExistingLibrary = expectsExistingLibrary
        }
    }

    public struct RelocationResult: Equatable {
        public let success: Bool
        public let backupURL: URL?
        public let message: String?
        public let activeLocation: URL
    }

    public enum DeviceStateKey {
        public static let storeLocationPath = "devtype.storeFileURL"
    }

    public static let storeDirEnvKey = "DEVTYPE_STORE_DIR"
    public static let syncedFileName = "DevType-snippets.json"

    private enum FileDigest: Equatable {
        case absent
        case unreadable
        case sha(String)
    }

    private let lock = NSLock()
    /// Dedicated lock for `_saveBlocked` — NSLock is not re-entrant, so we
    /// cannot reuse `lock` here: `loadGroupsUnlocked` holds `lock` and calls
    /// `writeGroupsToDisk`, which also needs to touch `_saveBlocked`.
    /// Lock ordering rule: `lock` may be held while acquiring `saveBlockLock`,
    /// but never the reverse.
    private let saveBlockLock = NSLock()
    private var listeners: [UUID: ([SnippetModel]) -> Void] = [:]
    private var groupListeners: [UUID: ([SnippetGroup]) -> Void] = [:]
    private var _cachedGroups: [SnippetGroup]?
    private var _lastLoadIssue: LoadIssue?
    private var _saveBlocked: SaveOutcome?

    private var fileURL: URL
    private var expectsExistingLibrary: Bool
    private let deviceDefaults: UserDefaults
    private let localSupportDirectory: URL
    private var localDefaultURL: URL { localSupportDirectory.appendingPathComponent("snippets.json") }

    private let watcherFactory: (URL) -> StoreWatching?
    private var watcher: StoreWatching?
    private let digestLock = NSLock()
    private var savedDigest: FileDigest = .absent
    private var isApplyingExternalState = false

    /// Set when the last disk load recovered from corrupt JSON. Cleared after UI consumes it.
    public var lastLoadIssue: LoadIssue? {
        lock.lock()
        defer { lock.unlock() }
        return _lastLoadIssue
    }

    public var activeLocationURL: URL { fileURL }

    public var isUsingConfiguredLocation: Bool { expectsExistingLibrary }

    public var allSnippets: [SnippetModel] {
        loadSnippets()
    }

    public static var defaultLocalSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevType", isDirectory: true)
    }

    public static func resolveLocation(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Location {
        if let dir = environment[storeDirEnvKey], !dir.isEmpty {
            return Location(
                fileURL: URL(fileURLWithPath: dir, isDirectory: true)
                    .appendingPathComponent("snippets.json"),
                expectsExistingLibrary: false
            )
        }
        if let path = defaults.string(forKey: DeviceStateKey.storeLocationPath), !path.isEmpty {
            return Location(fileURL: URL(fileURLWithPath: path), expectsExistingLibrary: true)
        }
        return Location(
            fileURL: defaultLocalSupportDirectory.appendingPathComponent("snippets.json"),
            expectsExistingLibrary: false
        )
    }

    static func defaultWatcherFactory(_ fileURL: URL) -> StoreWatching? {
        let directoryWatcher = DirectoryWatcher(directoryURL: fileURL.deletingLastPathComponent())
        guard isUbiquitousLocation(fileURL) else { return directoryWatcher }
        return CompositeWatcher([directoryWatcher, MetadataQueryWatcher(fileURL: fileURL)])
    }

    static func isUbiquitousLocation(_ fileURL: URL) -> Bool {
        if let values = try? fileURL.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            return true
        }
        let directory = fileURL.deletingLastPathComponent()
        if let values = try? directory.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            return true
        }
        let path = fileURL.path
        return path.contains("com~apple~CloudDocs") || path.contains("/Mobile Documents/")
    }

    public convenience init() {
        self.init(fileURL: nil)
    }

    /// Tests and harnesses: pass a temp-file URL; omit for default Application Support location.
    public convenience init(fileURL: URL? = nil, deviceDefaults: UserDefaults = .standard) {
        if let fileURL {
            let parent = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            self.init(
                location: Location(fileURL: fileURL, expectsExistingLibrary: false),
                deviceDefaults: deviceDefaults,
                watcherFactory: { _ in nil }
            )
        } else {
            self.init(
                location: SnippetStore.resolveLocation(defaults: deviceDefaults),
                deviceDefaults: deviceDefaults,
                watcherFactory: SnippetStore.defaultWatcherFactory
            )
        }
    }

    public init(
        location: Location,
        deviceDefaults: UserDefaults = .standard,
        localSupportDirectory: URL = SnippetStore.defaultLocalSupportDirectory,
        watcherFactory: @escaping (URL) -> StoreWatching? = { _ in nil }
    ) {
        self.fileURL = location.fileURL
        self.expectsExistingLibrary = location.expectsExistingLibrary
        self.deviceDefaults = deviceDefaults
        self.localSupportDirectory = localSupportDirectory
        self.watcherFactory = watcherFactory

        let loaded = Self.loadFrom(location)
        _cachedGroups = loaded.groups
        _lastLoadIssue = loaded.loadIssue
        saveBlockLock.lock()
        _saveBlocked = loaded.blocked
        saveBlockLock.unlock()
        setLastKnownDigest(loaded.digest)

        if (_cachedGroups ?? []).isEmpty && !expectsExistingLibrary {
            _cachedGroups = loadGroupsUnlocked()
        }

        self.watcher = watcherFactory(fileURL)
        startWatching()
    }

    deinit { watcher?.stop() }

    public func consumeLastLoadIssue() -> LoadIssue? {
        lock.lock()
        defer { lock.unlock() }
        let issue = _lastLoadIssue
        _lastLoadIssue = nil
        return issue
    }

    @discardableResult
    public func addListener(_ listener: @escaping ([SnippetModel]) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        listeners[token] = listener
        let current = _cachedGroups?.flatMap(\.snippets) ?? loadGroupsUnlocked().flatMap(\.snippets)
        lock.unlock()
        listener(current)
        return token
    }

    @discardableResult
    public func addGroupListener(_ listener: @escaping ([SnippetGroup]) -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        groupListeners[token] = listener
        let current = _cachedGroups ?? loadGroupsUnlocked()
        lock.unlock()
        listener(current)
        return token
    }

    public func removeListener(token: UUID) {
        lock.lock()
        listeners.removeValue(forKey: token)
        groupListeners.removeValue(forKey: token)
        lock.unlock()
    }

    public func loadSnippets() -> [SnippetModel] {
        loadGroups().flatMap(\.snippets)
    }

    public func loadGroups() -> [SnippetGroup] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = _cachedGroups {
            return cached
        }
        let groups = loadGroupsUnlocked()
        _cachedGroups = groups
        return groups
    }

    private struct Loaded {
        var groups: [SnippetGroup] = []
        var digest: FileDigest = .absent
        var loadIssue: LoadIssue?
        var blocked: SaveOutcome?
    }

    private func loadGroupsUnlocked() -> [SnippetGroup] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            if expectsExistingLibrary {
                return []
            }
            let defaults = Self.sanitizeGroups([SnippetGroup(name: SnippetDocument.defaultGroupName, snippets: defaultSnippets())])
            writeGroupsToDisk(defaults, force: true)
            return defaults
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            DevTypeLog.store.error(
                "[Store] Failed to read snippets from \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return Self.sanitizeGroups([SnippetGroup(name: SnippetDocument.defaultGroupName, snippets: defaultSnippets())])
        }

        if data.isEmpty || String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            return []
        }

        do {
            let document = try Self.decodeDocument(from: data)
            if document.schemaVersion > SnippetDocument.currentSchemaVersion {
                saveBlockLock.lock()
                _saveBlocked = .blockedByNewerSchema
                saveBlockLock.unlock()
            }
            return Self.sanitizeGroups(document.groups)
        } catch {
            DevTypeLog.store.error(
                "[Store] Failed to decode snippets from \(self.fileURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            let backupURL = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            _lastLoadIssue = .corrupted(backupURL: backupURL)
            let defaults = Self.sanitizeGroups([SnippetGroup(name: SnippetDocument.defaultGroupName, snippets: defaultSnippets())])
            writeGroupsToDisk(defaults, force: true)
            return defaults
        }
    }

    /// Decodes versioned `SnippetDocument`, v1 `snippets` envelope, or legacy bare `[SnippetModel]` arrays.
    public static func decodeSnippets(from data: Data) throws -> [SnippetModel] {
        try decodeDocument(from: data).snippets
    }

    public static func decodeDocument(from data: Data) throws -> SnippetDocument {
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(SnippetDocument.self, from: data) {
            return document
        }
        let legacySnippets = try decoder.decode([SnippetModel].self, from: data)
        return SnippetDocument(snippets: legacySnippets)
    }

    public func saveSnippets(_ snippets: [SnippetModel]) {
        lock.lock()
        let existing = _cachedGroups ?? loadGroupsUnlocked()
        lock.unlock()

        let sanitized = Self.sanitize(snippets)
        var updated = existing

        if updated.isEmpty {
            updated = [SnippetGroup(name: SnippetDocument.defaultGroupName, snippets: sanitized)]
        } else if updated.count == 1 {
            updated[0].snippets = sanitized
        } else {
            var byID: [UUID: SnippetModel] = [:]
            for snippet in sanitized { byID[snippet.id] = snippet }
            let keepIDs = Set(sanitized.map(\.id))
            var placed = Set<UUID>()
            for gi in updated.indices {
                for si in updated[gi].snippets.indices {
                    let id = updated[gi].snippets[si].id
                    if let replacement = byID[id] {
                        updated[gi].snippets[si] = replacement
                        placed.insert(id)
                    }
                }
                updated[gi].snippets.removeAll { !keepIDs.contains($0.id) }
            }
            let orphans = sanitized.filter { !placed.contains($0.id) }
            if !orphans.isEmpty {
                if let generalIndex = updated.firstIndex(where: { $0.name == SnippetDocument.defaultGroupName }) {
                    updated[generalIndex].snippets.append(contentsOf: orphans)
                } else {
                    updated.insert(SnippetGroup(name: SnippetDocument.defaultGroupName, snippets: orphans), at: 0)
                }
            }
        }

        saveGroups(updated)
    }

    @discardableResult
    public func saveGroups(_ groups: [SnippetGroup]) -> SaveOutcome {
        let sanitized = Self.sanitizeGroups(groups)
        lock.lock()
        _cachedGroups = sanitized
        let snippetListeners = listeners
        let groupListenersCopy = groupListeners
        lock.unlock()

        let outcome = writeGroupsToDisk(sanitized)
        let flat = sanitized.flatMap(\.snippets)
        for listener in snippetListeners.values { listener(flat) }
        for listener in groupListenersCopy.values { listener(sanitized) }
        return outcome
    }

    @discardableResult
    public func importGroups(_ imported: [SnippetGroup]) -> SaveOutcome {
        var current = loadGroups()
        for group in imported {
            if let idx = current.firstIndex(where: { $0.name == group.name }) {
                current[idx] = group
            } else {
                current.append(group)
            }
        }
        return saveGroups(current)
    }

    public func incrementUsage(for snippetID: UUID) {
        var groups = loadGroups()
        var changed = false
        for gi in groups.indices {
            for si in groups[gi].snippets.indices where groups[gi].snippets[si].id == snippetID {
                groups[gi].snippets[si].usageCount += 1
                groups[gi].snippets[si].updatedAt = Date()
                changed = true
            }
        }
        if changed {
            _ = saveGroups(groups)
        }
    }

    @discardableResult
    private func writeGroupsToDisk(_ groups: [SnippetGroup], force: Bool = false) -> SaveOutcome {
        if !force, let blocked = blockedReason() { return blocked }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let document = SnippetDocument(groups: groups)
            let data = try encoder.encode(document)

            if !force {
                let onDisk = Self.currentDigest(at: fileURL)
                guard onDisk == lastKnownDigest() else {
                    saveBlockLock.lock()
                    _saveBlocked = .blockedByRemoteChange
                    saveBlockLock.unlock()
                    return .blockedByRemoteChange
                }
            }

            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            setLastKnownDigest(.sha(Self.sha256(of: data)))
            saveBlockLock.lock()
            _saveBlocked = nil
            saveBlockLock.unlock()
            return .saved
        } catch {
            DevTypeLog.store.error(
                "[Store] Failed to save snippets: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }
    }

    private func blockedReason() -> SaveOutcome? {
        saveBlockLock.lock()
        defer { saveBlockLock.unlock() }
        return _saveBlocked
    }

    private func lastKnownDigest() -> FileDigest {
        digestLock.lock()
        defer { digestLock.unlock() }
        return savedDigest
    }

    private func setLastKnownDigest(_ digest: FileDigest) {
        digestLock.lock()
        savedDigest = digest
        digestLock.unlock()
    }

    private static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func currentDigest(at url: URL) -> FileDigest {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let raw = try? Data(contentsOf: url) else { return .unreadable }
        return .sha(sha256(of: raw))
    }

    private static func loadFrom(_ location: Location) -> Loaded {
        var out = Loaded()
        guard FileManager.default.fileExists(atPath: location.fileURL.path) else {
            if location.expectsExistingLibrary {
                out.blocked = .failed("Library not available at configured location")
            }
            return out
        }
        do {
            let raw = try Data(contentsOf: location.fileURL)
            out.digest = .sha(sha256(of: raw))
            let document = try decodeDocument(from: raw)
            out.groups = document.groups
            if document.schemaVersion > SnippetDocument.currentSchemaVersion {
                out.blocked = .blockedByNewerSchema
            }
        } catch {
            let backupURL = location.fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: location.fileURL, to: backupURL)
            out.loadIssue = .corrupted(backupURL: backupURL)
        }
        return out
    }

    // MARK: - External change detection

    private func startWatching() {
        guard let watcher else { return }
        watcher.onChange = { [weak self] in
            DispatchQueue.main.async { self?.externalChangeDetected() }
        }
        watcher.start()
    }

    func externalChangeDetected() {
        let onDisk = Self.currentDigest(at: fileURL)
        guard onDisk != lastKnownDigest() else { return }
        reloadFromDisk()
    }

    private func reloadFromDisk() {
        isApplyingExternalState = true
        defer { isApplyingExternalState = false }

        let loaded = Self.loadFrom(Location(fileURL: fileURL, expectsExistingLibrary: expectsExistingLibrary))
        setLastKnownDigest(loaded.digest)
        saveBlockLock.lock()
        _saveBlocked = loaded.blocked
        saveBlockLock.unlock()

        lock.lock()
        _cachedGroups = loaded.groups
        let snippetListeners = listeners
        let groupListenersCopy = groupListeners
        lock.unlock()

        let flat = loaded.groups.flatMap(\.snippets)
        for listener in snippetListeners.values { listener(flat) }
        for listener in groupListenersCopy.values { listener(loaded.groups) }
    }

    // MARK: - Store location switching

    @discardableResult
    public func saveSnippetsAs(toDirectory directory: URL) -> RelocationResult {
        let target = directory.appendingPathComponent(Self.syncedFileName)
        var backup: URL?
        if FileManager.default.fileExists(atPath: target.path),
           let existing = try? Data(contentsOf: target), !existing.isEmpty {
            backup = writeBackup(existing, tag: "pre-save-as")
        }
        let groups = loadGroups()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let raw = try? encoder.encode(SnippetDocument(groups: groups)) else {
            return RelocationResult(success: false, backupURL: backup, message: "Could not encode library.", activeLocation: fileURL)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try raw.write(to: target, options: .atomic)
        } catch {
            return RelocationResult(success: false, backupURL: backup, message: error.localizedDescription, activeLocation: fileURL)
        }
        deviceDefaults.set(target.path, forKey: DeviceStateKey.storeLocationPath)
        return relocate(to: Location(fileURL: target, expectsExistingLibrary: true), backupURL: backup)
    }

    @discardableResult
    public func linkToSnippets(at target: URL) -> RelocationResult {
        let localBackup = exportCurrentLibrary(tag: "local-before-link")
        deviceDefaults.set(target.path, forKey: DeviceStateKey.storeLocationPath)
        return relocate(to: Location(fileURL: target, expectsExistingLibrary: true), backupURL: localBackup)
    }

    @discardableResult
    public func stopSyncing() -> RelocationResult {
        var backup: URL?
        if FileManager.default.fileExists(atPath: localDefaultURL.path),
           let existing = try? Data(contentsOf: localDefaultURL), !existing.isEmpty {
            backup = writeBackup(existing, tag: "pre-stop-sync")
        }
        let groups = loadGroups()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let raw = try? encoder.encode(SnippetDocument(groups: groups)) else {
            return RelocationResult(success: false, backupURL: backup, message: "Could not encode library.", activeLocation: fileURL)
        }
        do {
            try FileManager.default.createDirectory(at: localDefaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try raw.write(to: localDefaultURL, options: .atomic)
        } catch {
            return RelocationResult(success: false, backupURL: backup, message: error.localizedDescription, activeLocation: fileURL)
        }
        deviceDefaults.removeObject(forKey: DeviceStateKey.storeLocationPath)
        return relocate(to: Location(fileURL: localDefaultURL, expectsExistingLibrary: false), backupURL: backup)
    }

    @discardableResult
    private func relocate(to location: Location, backupURL: URL?) -> RelocationResult {
        watcher?.stop()
        fileURL = location.fileURL
        expectsExistingLibrary = location.expectsExistingLibrary
        lock.lock()
        _cachedGroups = nil
        lock.unlock()
        let groups = loadGroups()
        watcher = watcherFactory(fileURL)
        startWatching()
        let flat = groups.flatMap(\.snippets)
        lock.lock()
        let snippetListeners = listeners
        let groupListenersCopy = groupListeners
        lock.unlock()
        for listener in snippetListeners.values { listener(flat) }
        for listener in groupListenersCopy.values { listener(groups) }
        return RelocationResult(success: true, backupURL: backupURL, message: nil, activeLocation: fileURL)
    }

    private func exportCurrentLibrary(tag: String) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let raw = try? encoder.encode(SnippetDocument(groups: loadGroups())) else { return nil }
        return writeBackup(raw, tag: tag)
    }

    private func writeBackup(_ raw: Data, tag: String) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
        let url = localSupportDirectory.appendingPathComponent("devtype-backup-\(tag)-\(formatter.string(from: Date())).json")
        do {
            try FileManager.default.createDirectory(at: localSupportDirectory, withIntermediateDirectories: true)
            try raw.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Unified import: auto-detects TextExpander vs Espanso and merges the
    /// resulting groups into the library. Single entry point for the UI.
    @discardableResult
    public func importSnippets(from url: URL) throws -> SnippetImporter.ImportResult {
        let result = try SnippetImporter.importFrom(url)
        _ = importGroups(result.groups)
        return result
    }

    /// Imports TextExpander data from a folder URL.
    @discardableResult
    public func importTextExpander(from folder: URL) throws -> TEImporter.ImportResult {
        let result = try TEImporter.importFolder(folder)
        _ = importGroups(result.groups)
        return result
    }

    /// Imports Espanso matches (Tier A static) from a config root, match folder, package, or YAML file.
    @discardableResult
    public func importEspanso(from url: URL) throws -> EspansoImporter.ImportResult {
        let result = try EspansoImporter.importFrom(url)
        _ = importGroups(result.groups)
        return result
    }

    /// Drops empty triggers and de-duplicates by trigger (first wins, case-sensitive key).
    public static func sanitize(_ snippets: [SnippetModel]) -> [SnippetModel] {
        var seen = Set<String>()
        var result: [SnippetModel] = []
        for snippet in snippets {
            let trigger = snippet.triggerKeyword
            guard !trigger.isEmpty else { continue }
            if seen.contains(trigger) { continue }
            seen.insert(trigger)
            result.append(snippet)
        }
        return result
    }

    public static func sanitizeGroups(_ groups: [SnippetGroup]) -> [SnippetGroup] {
        groups.map { group in
            var copy = group
            copy.snippets = sanitize(group.snippets)
            return copy
        }
    }

    public func defaultSnippets() -> [SnippetModel] {
        return [
            SnippetModel(title: "Email Address", triggerKeyword: ":eml", replacementText: "user@devtype.app", isCaseSensitive: false, requireWordBoundary: true),
            SnippetModel(title: "Current Date", triggerKeyword: ":tdate", replacementText: "Today is {{date:yyyy-MM-dd}}", isCaseSensitive: false, requireWordBoundary: false),
            SnippetModel(title: "Greeting Template", triggerKeyword: ":hello", replacementText: "Hello, thanks for reaching out!\n\nBest regards,\nDevType Team", isCaseSensitive: false, requireWordBoundary: true),
            SnippetModel(title: "Function Signature", triggerKeyword: ":func", replacementText: "func {{cursor}}() {\n    // Implementation\n}", isCaseSensitive: false, requireWordBoundary: true)
        ]
    }

    public func search(_ query: String, limit: Int? = nil) -> [SearchHit] {
        SnippetSearch.run(query: query, in: loadGroups(), includeDisabled: false, limit: limit)
    }
}
