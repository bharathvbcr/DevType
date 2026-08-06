import AppKit
import Foundation

/// Persistent storage for snippet image attachments.
///
/// Images are copied into a dedicated `Images/` directory next to the snippet
/// store so snippets stay self-contained (Espanso `image_path` targets and
/// user-picked files are duplicated, not referenced). `SnippetModel.imagePath`
/// stores just the file name inside this directory; absolute paths are passed
/// through for backwards compatibility.
///
/// §3.7: the directory is resolved **on every access** from
/// `SnippetStore.activeLibraryDirectory`. It used to be captured once in `init`,
/// and because this is a singleton that meant the very first access froze it at
/// the default local Application Support path forever — so after
/// `saveSnippetsAs(toDirectory:)` moved the library into iCloud, snippets synced
/// but images did not, and every image snippet was broken on a second Mac.
public final class ImageAttachmentStore {
    public static let shared = ImageAttachmentStore()

    /// §3.7: posted after the store starts pointing at a new directory.
    /// `userInfo["directory"]` holds the new `URL`.
    public static let didChangeDirectoryNotification = Notification.Name("devtype.imageStore.didChangeDirectory")

    public enum StoreError: LocalizedError {
        case unreadableImage(String)
        case unsupportedImageType(String)
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableImage(let p): return "Could not read image: \(p)"
            case .unsupportedImageType(let ext): return "Unsupported image type: \(ext)"
            case .saveFailed(let p): return "Could not save image to: \(p)"
            }
        }
    }

    /// Extensions we accept when attaching/importing images.
    public static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "webp", "heic"]

    /// §3.7: returned by `url(forImagePath:)` when the path fails containment
    /// validation. Deterministic, inside the store, and can never exist — callers
    /// fail closed instead of reaching outside the store.
    private static let rejectedPathPlaceholder = ".devtype-invalid-image-path"

    private let lock = NSLock()
    /// Pinned at construction (tests, importers). When set, the store never
    /// follows the library location.
    private let explicitDirectory: URL?
    /// Last directory adopted via `adoptLibraryLocation`.
    private var overrideDirectory: URL?

    /// - Parameter directory: override for tests; defaults to the Images folder
    ///   beside the active snippet store (or `DEVTYPE_STORE_DIR/Images`).
    public init(directory: URL? = nil) {
        self.explicitDirectory = directory
    }

    public var imagesDirectory: URL { resolvedDirectory() }

    /// §3.7: resolution order — pinned directory, adopted directory, environment
    /// override, active library location, default local support directory.
    private func resolvedDirectory() -> URL {
        lock.lock()
        let pinned = explicitDirectory
        let adopted = overrideDirectory
        lock.unlock()

        if let pinned { return pinned }
        if let adopted { return adopted }
        if let env = ProcessInfo.processInfo.environment[SnippetStore.storeDirEnvKey], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
                .appendingPathComponent("Images", isDirectory: true)
        }
        if let active = SnippetStore.activeLibraryDirectory {
            return active.appendingPathComponent("Images", isDirectory: true)
        }
        return SnippetStore.defaultLocalSupportDirectory
            .appendingPathComponent("Images", isDirectory: true)
    }

    /// §3.7: point the store at the directory beside `libraryFileURL`, copying any
    /// images that lived beside the previous library. Called by
    /// `SnippetStore.relocate` so images follow the library to and from iCloud.
    /// A store constructed with an explicit directory ignores this.
    public func adoptLibraryLocation(_ libraryFileURL: URL, migratingFrom oldImagesDirectory: URL? = nil) {
        let target = libraryFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Images", isDirectory: true)
        let previous = oldImagesDirectory ?? resolvedDirectory()

        lock.lock()
        let isPinned = explicitDirectory != nil
        if !isPinned { overrideDirectory = target }
        lock.unlock()
        guard !isPinned else { return }

        if previous.standardizedFileURL.path != target.standardizedFileURL.path {
            migrateImages(from: previous, to: target)
        }

        NotificationCenter.default.post(
            name: Self.didChangeDirectoryNotification,
            object: self,
            userInfo: ["directory": target]
        )
    }

    /// Copies (never moves) so the previous location keeps working as a fallback
    /// if the relocation is later undone.
    private func migrateImages(from source: URL, to target: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path),
              let names = try? fm.contentsOfDirectory(atPath: source.path),
              !names.isEmpty else {
            return
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            DevTypeLog.store.error(
                "[Store] Could not create image directory \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        var copied = 0
        for name in names where !name.hasPrefix(".") {
            let destination = target.appendingPathComponent(name)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.copyItem(at: source.appendingPathComponent(name), to: destination)
                copied += 1
            } catch {
                DevTypeLog.store.error(
                    "[Store] Could not migrate image \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        DevTypeLog.store.notice(
            "[Store] Migrated \(copied, privacy: .public) image attachment(s) to \(target.path, privacy: .public)"
        )
    }

    /// Copies an image file into the store. Returns the stored file name.
    @discardableResult
    public func importImage(from sourceURL: URL) throws -> String {
        let ext = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw StoreError.unsupportedImageType(ext.isEmpty ? sourceURL.lastPathComponent : ext)
        }
        guard NSImage(contentsOf: sourceURL) != nil else {
            throw StoreError.unreadableImage(sourceURL.path)
        }
        let directory = resolvedDirectory()
        try ensureDirectory(directory)
        let fileName = "\(UUID().uuidString).\(ext)"
        let target = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: target)
        } catch {
            throw StoreError.saveFailed(target.path)
        }
        return fileName
    }

    /// Writes raw image data into the store. Returns the stored file name.
    @discardableResult
    public func save(data: Data, preferredExtension: String = "png") throws -> String {
        let ext = preferredExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw StoreError.unsupportedImageType(ext)
        }
        guard NSImage(data: data) != nil else {
            throw StoreError.unreadableImage("\(data.count) bytes")
        }
        let directory = resolvedDirectory()
        try ensureDirectory(directory)
        let fileName = "\(UUID().uuidString).\(ext)"
        let target = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw StoreError.saveFailed(target.path)
        }
        return fileName
    }

    /// §3.7: containment-checked resolution. Returns `nil` when `path` escapes the
    /// store. A hand-edited `imagePath: "../../../x"` used to resolve happily,
    /// because this appended without any traversal check.
    public func resolvedURL(forImagePath path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        // Legacy absolute references (Espanso `image_path`, hand-written configs)
        // are read-only pass-throughs and are never deleted or collected.
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard !path.contains("..") else { return nil }

        let directory = resolvedDirectory().standardizedFileURL
        let candidate = directory.appendingPathComponent(path).standardizedFileURL
        let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard candidate.path.hasPrefix(base), candidate.path != directory.path else { return nil }
        return candidate
    }

    /// Resolves a stored `imagePath` (file name) to a file URL.
    /// Absolute paths pass through untouched.
    public func url(forImagePath path: String) -> URL {
        if let resolved = resolvedURL(forImagePath: path) { return resolved }
        return resolvedDirectory().appendingPathComponent(Self.rejectedPathPlaceholder)
    }

    public func loadImage(path: String) -> NSImage? {
        guard !path.isEmpty, let url = resolvedURL(forImagePath: path) else { return nil }
        return NSImage(contentsOf: url)
    }

    public func deleteImage(path: String) {
        guard !path.isEmpty, !path.hasPrefix("/") else { return }
        guard let url = resolvedURL(forImagePath: path) else {
            // §3.7: `hasPrefix("/")` alone was the only guard here, so a relative
            // traversal deleted files outside the store.
            DevTypeLog.store.error(
                "[Store] Refused to delete image outside the attachment store: \(path, privacy: .public)"
            )
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Orphan collection (§3.7)

    /// §3.7: removes stored images no snippet references any more. Nothing in the
    /// app did this before — `SnippetEditorSheet` only deleted on *replace*, so
    /// deleting a snippet leaked its attachment forever.
    ///
    /// - Parameters:
    ///   - referencedPaths: every `SnippetModel.imagePath` still in the library.
    ///   - dryRun: report what would be removed without touching the disk.
    /// - Returns: the file names removed (or that would be), sorted.
    @discardableResult
    public func collectOrphans(referencedPaths: Set<String>, dryRun: Bool = false) -> [String] {
        let directory = resolvedDirectory()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }

        var referencedNames = Set<String>()
        for path in referencedPaths where !path.isEmpty && !path.hasPrefix("/") {
            referencedNames.insert((path as NSString).lastPathComponent)
        }

        var removed: [String] = []
        for name in names {
            guard !name.hasPrefix("."), !referencedNames.contains(name) else { continue }
            // Only ever touch files we could have written ourselves.
            guard Self.supportedExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            removed.append(name)
            if !dryRun {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        if !removed.isEmpty && !dryRun {
            DevTypeLog.store.notice(
                "[Store] Collected \(removed.count, privacy: .public) orphaned image attachment(s)"
            )
        }
        return removed.sorted()
    }

    @discardableResult
    public func collectOrphans(for groups: [SnippetGroup], dryRun: Bool = false) -> [String] {
        let referenced = Set(groups.flatMap(\.snippets).map(\.imagePath).filter { !$0.isEmpty })
        return collectOrphans(referencedPaths: referenced, dryRun: dryRun)
    }

    private func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
