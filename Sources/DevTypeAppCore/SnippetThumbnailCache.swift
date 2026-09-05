import AppKit
import ExpanderEngine

/// Row-sized thumbnails for image snippets, decoded once and kept.
///
/// An image snippet's row used to read `🖼 <imagePath>` — a picture glyph and a filename. Every
/// other snippet type shows its actual content: text snippets show the replacement, secrets show
/// a deliberate mask. The one type whose content is inherently visual was the one that did not
/// show it, so telling two image snippets apart meant opening both.
///
/// Decoding on demand in `tableView(_:viewFor:row:)` would put a disk read and a full image
/// decode on the scroll path — there was no image cache anywhere in the app — so thumbnails are
/// produced off the main thread, at row size, and cached.
///
/// The cache is keyed on image path plus the requested pixel size. `NSCache` evicts under memory
/// pressure on its own, which is the right policy for decoded images: a dropped thumbnail costs
/// one re-decode, and holding them all costs memory the user did not ask to spend.
final class SnippetThumbnailCache {

    static let shared = SnippetThumbnailCache()

    /// Longest edge of a stored thumbnail, in points.
    static let thumbnailEdge: CGFloat = 32

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.devtype.thumbnails", qos: .userInitiated)
    /// Paths with a decode already in flight, so a fast scroll does not queue the same work
    /// once per row that passes under the cursor.
    private var inFlight: Set<String> = []
    private let lock = NSLock()

    private init() {
        // Bounded by count as well as by memory pressure: a library of thousands of image
        // snippets should not be able to fill the cache just by being scrolled through.
        cache.countLimit = 400
    }

    private func key(_ path: String, edge: CGFloat) -> NSString {
        "\(path)@\(Int(edge))" as NSString
    }

    /// A cached thumbnail, if one is already decoded. Never touches the disk.
    func cachedThumbnail(for path: String, edge: CGFloat = SnippetThumbnailCache.thumbnailEdge) -> NSImage? {
        guard !path.isEmpty else { return nil }
        return cache.object(forKey: key(path, edge: edge))
    }

    /// Cached thumbnail if present; otherwise decodes off the main thread and calls `completion`
    /// on the main thread when it lands.
    ///
    /// `completion` is not called when the decode fails or when one is already in flight for
    /// this path — the caller has already drawn its placeholder and has nothing to undo.
    func thumbnail(
        for path: String,
        edge: CGFloat = SnippetThumbnailCache.thumbnailEdge,
        completion: @escaping (NSImage) -> Void
    ) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let hit = cache.object(forKey: key(path, edge: edge)) { return hit }

        lock.lock()
        let alreadyRunning = !inFlight.insert(path).inserted
        lock.unlock()
        guard !alreadyRunning else { return nil }

        queue.async { [weak self] in
            guard let self else { return }
            let thumbnail = ImageAttachmentStore.shared.loadImage(path: path)
                .flatMap { Self.scaled($0, toEdge: edge) }

            self.lock.lock()
            self.inFlight.remove(path)
            self.lock.unlock()

            guard let thumbnail else { return }
            self.cache.setObject(thumbnail, forKey: self.key(path, edge: edge))
            DispatchQueue.main.async { completion(thumbnail) }
        }
        return nil
    }

    /// Drops a path's thumbnails. Call when the underlying image is replaced or deleted.
    func invalidate(path: String) {
        guard !path.isEmpty else { return }
        // Only the sizes this app actually asks for; there is one.
        cache.removeObject(forKey: key(path, edge: Self.thumbnailEdge))
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// Test seam for the scaling rule, which has no other entry point that avoids the disk.
    static func scaledForTesting(_ image: NSImage, toEdge edge: CGFloat) -> NSImage? {
        scaled(image, toEdge: edge)
    }

    /// Test seam: seeds the cache without decoding a file.
    func storeForTesting(_ image: NSImage, path: String, edge: CGFloat) {
        cache.setObject(image, forKey: key(path, edge: edge))
    }

    /// Aspect-preserving downscale onto a square canvas, so rows line up regardless of the
    /// source image's proportions.
    private static func scaled(_ image: NSImage, toEdge edge: CGFloat) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(edge / size.width, edge / size.height, 1)
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard target.width >= 1, target.height >= 1 else { return nil }

        let thumbnail = NSImage(size: target)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        thumbnail.unlockFocus()
        return thumbnail
    }
}
