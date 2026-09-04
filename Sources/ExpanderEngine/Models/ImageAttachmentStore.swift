import AppKit
import Foundation
import ImageIO

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

    public enum StoreError: LocalizedError, Equatable {
        case unreadableImage(String)
        case unsupportedImageType(String)
        /// §hardening: the payload exceeded `maxImportedImageBytes`. Sources come
        /// from untrusted imports (Espanso `image_path`), so a multi-GB "image" is
        /// refused before it is decoded or copied.
        case oversizedImage(String)
        case oversizedImageDimensions
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableImage(let p): return "Could not read image: \(p)"
            case .unsupportedImageType(let ext): return "Unsupported image type: \(ext)"
            case .oversizedImage(let p): return "Image exceeds the \(maxImportedImageBytes / 1_000_000) MB attachment limit: \(p)"
            case .oversizedImageDimensions:
                return "Image dimensions, frames, or decode work exceed the attachment limits."
            case .saveFailed(let p): return "Could not save image to: \(p)"
            }
        }
    }

    /// Extensions we accept when attaching/importing images.
    public static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "webp", "heic"]

    /// §hardening: hard ceiling on the byte size of an image accepted into the
    /// store, for both file imports (`importImage(from:)`) and raw payloads
    /// (`save(data:)`). The source of an import is dictated by untrusted configs,
    /// so the size is stat'ed *before* any decode/copy work happens.
    ///
    /// Deliberately a mutable `internal static var`: production code must treat
    /// it as a constant; only tests lower it (`@testable`) to exercise the
    /// refusal path without writing multi-GB fixtures.
    internal static var maxImportedImageBytes = 25 * 1024 * 1024
    /// Metadata-first decode bounds. Compressed byte size alone is insufficient:
    /// a tiny PNG/TIFF header can claim a bitmap large enough to exhaust memory
    /// when AppKit decodes it.
    internal static let maxImportedImageDimension = 16_384
    /// Mutable only so tests can exercise the pixel branch with a tiny valid
    /// image; production treats this as a constant like the byte ceiling above.
    internal static var maxImportedImagePixels = 64 * 1024 * 1024
    /// Multi-image containers are parsed by AppKit as one attachment. Bound both
    /// their metadata walk and their aggregate decoded pixel work. The aggregate
    /// budget is twice the per-frame ceiling: 128 megapixels in production.
    internal static let maxImportedImageFrameCount = 512
    internal static var maxImportedImageAggregatePixels: Int {
        guard maxImportedImagePixels <= Int.max / 2 else { return Int.max }
        return maxImportedImagePixels * 2
    }

    /// Validated, value-semantic attachment payload used by import previews.
    /// Holding this value performs no persistent write; a confirmed library
    /// commit promotes it with `save(prepared:)` and can roll that write back.
    internal struct PreparedImage: Equatable {
        let data: Data
        let preferredExtension: String
    }

    /// §3.7: returned by `url(forImagePath:)` when the path fails containment
    /// validation. Deterministic, inside the store, and can never exist — callers
    /// fail closed instead of reaching outside the store.
    private static let rejectedPathPlaceholder = ".devtype-invalid-image-path"

    private let lock = NSLock()
    /// Pinned at construction (tests, importers). When set, the store never
    /// follows the library location.
    private let explicitDirectory: URL?
    private let removeItemAtURL: (URL) throws -> Void
    /// Last directory adopted via `adoptLibraryLocation`.
    private var overrideDirectory: URL?

    /// - Parameter directory: override for tests; defaults to the Images folder
    ///   beside the active snippet store (or `DEVTYPE_STORE_DIR/Images`).
    public init(directory: URL? = nil) {
        self.explicitDirectory = directory
        self.removeItemAtURL = { try FileManager.default.removeItem(at: $0) }
    }

    /// Fault-injection seam for transactional import cleanup tests. Production
    /// callers keep using the source-compatible public initializer above.
    internal init(
        directory: URL? = nil,
        removeItemAtURL: @escaping (URL) throws -> Void
    ) {
        self.explicitDirectory = directory
        self.removeItemAtURL = removeItemAtURL
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
                "[Store] Could not create image directory \(DevTypeLog.errorMetadata(error), privacy: .public)"
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
                    "[Store] Could not migrate image \(DevTypeLog.errorMetadata(error), privacy: .public)"
                )
            }
        }
        DevTypeLog.store.notice(
            "[Store] Migrated \(copied, privacy: .public) image attachment(s) \(DevTypeLog.publicPathMetadata(target.path), privacy: .public)"
        )
    }

    /// Copies an image file into the store. Returns the stored file name.
    ///
    /// §hardening: the source is stat'ed first and refused above
    /// `maxImportedImageBytes` — before `NSImage` decoding or any copy, so an
    /// untrusted `image_path` cannot make the importer read a payload bomb.
    @discardableResult
    public func importImage(from sourceURL: URL) throws -> String {
        try save(prepared: prepareImage(from: sourceURL))
    }

    /// Reads and validates an attachment without touching the persistent image
    /// directory. The bounded read closes the stat/read race in which a source
    /// could grow after the initial size check.
    internal func prepareImage(from sourceURL: URL) throws -> PreparedImage {
        let ext = sourceURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw StoreError.unsupportedImageType(ext.isEmpty ? sourceURL.lastPathComponent : ext)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw StoreError.unreadableImage(sourceURL.path)
        }
        let byteCount = (attributes?[.size] as? Int64) ?? 0
        guard byteCount <= Self.maxImportedImageBytes else {
            throw StoreError.oversizedImage(sourceURL.path)
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.maxImportedImageBytes + 1) ?? Data()
        } catch {
            throw StoreError.unreadableImage(sourceURL.path)
        }
        guard data.count <= Self.maxImportedImageBytes else {
            throw StoreError.oversizedImage(sourceURL.path)
        }
        try Self.validateDecodedImageSize(data, sourceDescription: sourceURL.path)
        guard NSImage(data: data) != nil else {
            throw StoreError.unreadableImage(sourceURL.path)
        }
        return PreparedImage(data: data, preferredExtension: ext)
    }

    @discardableResult
    internal func save(prepared: PreparedImage) throws -> String {
        try save(data: prepared.data, preferredExtension: prepared.preferredExtension)
    }

    /// Writes raw image data into the store. Returns the stored file name.
    @discardableResult
    public func save(data: Data, preferredExtension: String = "png") throws -> String {
        let ext = preferredExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw StoreError.unsupportedImageType(ext)
        }
        // §hardening: same ceiling as `importImage(from:)` — refuse before decode.
        guard data.count <= Self.maxImportedImageBytes else {
            throw StoreError.oversizedImage("\(data.count) bytes")
        }
        try Self.validateDecodedImageSize(data, sourceDescription: "\(data.count) bytes")
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
        _ = deleteImageReportingResult(path: path)
    }

    internal enum DeletionResult: Equatable {
        case removed
        case failed
    }

    /// Result-bearing variant used by import transactions. It deliberately does
    /// not log the path or filesystem error: the transaction emits aggregate,
    /// content-free attempted/removed/failed counts instead.
    @discardableResult
    internal func deleteImageReportingResult(path: String) -> DeletionResult {
        guard !path.isEmpty, !path.hasPrefix("/") else { return .failed }
        guard let url = resolvedURL(forImagePath: path) else {
            // §3.7: `hasPrefix("/")` alone was the only guard here, so a relative
            // traversal deleted files outside the store.
            DevTypeLog.store.error(
                "[Store] Refused to delete image outside the attachment store \(DevTypeLog.publicPathMetadata(path), privacy: .public)"
            )
            return .failed
        }
        do {
            try removeItemAtURL(url)
            return .removed
        } catch {
            return .failed
        }
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

    /// Reads every frame's width/height from ImageIO without constructing an
    /// AppKit image. A first-frame-only check lets a later TIFF/GIF/HEIC frame
    /// carry the decompression bomb. Division guards attacker-controlled
    /// multiplication, and the aggregate ceiling bounds multi-frame decode work.
    private static func validateDecodedImageSize(
        _ data: Data,
        sourceDescription: String
    ) throws {
        let metadataOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, metadataOptions) else {
            throw StoreError.unreadableImage(sourceDescription)
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else {
            throw StoreError.unreadableImage(sourceDescription)
        }
        guard maxImportedImageFrameCount > 0,
              maxImportedImagePixels > 0,
              maxImportedImageAggregatePixels > 0,
              frameCount <= maxImportedImageFrameCount else {
            throw StoreError.oversizedImageDimensions
        }

        let maxDimension = UInt64(maxImportedImageDimension)
        let maxPixels = UInt64(maxImportedImagePixels)
        var remainingAggregatePixels = UInt64(maxImportedImageAggregatePixels)

        for frameIndex in 0 ..< frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                frameIndex,
                metadataOptions
            ) as NSDictionary?,
                let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
                let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value,
                width > 0,
                height > 0 else {
                throw StoreError.unreadableImage(sourceDescription)
            }

            guard width <= maxDimension,
                  height <= maxDimension,
                  width <= maxPixels,
                  height <= maxPixels / width else {
                throw StoreError.oversizedImageDimensions
            }

            let framePixels = width * height
            guard framePixels <= remainingAggregatePixels else {
                throw StoreError.oversizedImageDimensions
            }
            remainingAggregatePixels -= framePixels
        }
    }
}
