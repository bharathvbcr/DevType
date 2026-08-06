import AppKit
import Foundation

/// Persistent storage for snippet image attachments.
///
/// Images are copied into a dedicated `Images/` directory next to the snippet
/// store so snippets stay self-contained (Espanso `image_path` targets and
/// user-picked files are duplicated, not referenced). `SnippetModel.imagePath`
/// stores just the file name inside this directory; absolute paths are passed
/// through for backwards compatibility.
public final class ImageAttachmentStore {
    public static let shared = ImageAttachmentStore()

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

    private let directory: URL

    /// - Parameter directory: override for tests; defaults to the Images folder
    ///   beside the active snippet store (or `DEVTYPE_STORE_DIR/Images`).
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let env = ProcessInfo.processInfo.environment[SnippetStore.storeDirEnvKey], !env.isEmpty {
            self.directory = URL(fileURLWithPath: env, isDirectory: true)
                .appendingPathComponent("Images", isDirectory: true)
        } else {
            self.directory = SnippetStore.defaultLocalSupportDirectory
                .appendingPathComponent("Images", isDirectory: true)
        }
    }

    public var imagesDirectory: URL { directory }

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
        try ensureDirectory()
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
        try ensureDirectory()
        let fileName = "\(UUID().uuidString).\(ext)"
        let target = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            throw StoreError.saveFailed(target.path)
        }
        return fileName
    }

    /// Resolves a stored `imagePath` (file name) to a file URL.
    /// Absolute paths pass through untouched.
    public func url(forImagePath path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return directory.appendingPathComponent(path)
    }

    public func loadImage(path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        return NSImage(contentsOf: url(forImagePath: path))
    }

    public func deleteImage(path: String) {
        guard !path.isEmpty, !path.hasPrefix("/") else { return }
        try? FileManager.default.removeItem(at: url(forImagePath: path))
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
