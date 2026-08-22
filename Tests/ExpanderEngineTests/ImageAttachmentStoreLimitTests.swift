import AppKit
import XCTest
@testable import ExpanderEngine

// Image payload-bomb hardening: `ImageAttachmentStore` import/copy paths used
// to accept arbitrarily large files. The source of an import can be dictated
// by an untrusted Espanso `image_path`, so the store stats the source first and
// refuses anything above `maxImportedImageBytes` — before decoding or copying.

final class ImageAttachmentStoreLimitTests: XCTestCase {

    private var originalCap: Int {
        ImageAttachmentStore.maxImportedImageBytes
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-imglimit-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Mirrors the real-PNG helper in `ImageSnippetTests`.
    private func makePNGData() throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        return data
    }

    func testImportImageRefusesSourcesAboveTheCap() throws {
        let cap = originalCap
        defer { ImageAttachmentStore.maxImportedImageBytes = cap }

        let storeDir = try makeTempDir("store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let sourceDir = try makeTempDir("src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let pngURL = sourceDir.appendingPathComponent("tiny.png")
        try makePNGData().write(to: pngURL)

        let store = ImageAttachmentStore(directory: storeDir)

        // Refusal path (cap lowered so a small real PNG trips it).
        ImageAttachmentStore.maxImportedImageBytes = 10
        XCTAssertThrowsError(try store.importImage(from: pngURL)) { error in
            guard case ImageAttachmentStore.StoreError.oversizedImage = error else {
                return XCTFail("expected oversizedImage, got \(error)")
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty,
                      "nothing may be written for a refused image")

        // Success path once the ceiling is restored.
        ImageAttachmentStore.maxImportedImageBytes = cap
        let storedName = try store.importImage(from: pngURL)
        XCTAssertTrue(storedName.hasSuffix(".png"))
        XCTAssertNotNil(store.loadImage(path: storedName))
    }

    func testSaveRefusesPayloadsAboveTheCap() throws {
        let cap = originalCap
        defer { ImageAttachmentStore.maxImportedImageBytes = cap }

        let storeDir = try makeTempDir("store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)

        let png = try makePNGData()
        ImageAttachmentStore.maxImportedImageBytes = 10
        XCTAssertThrowsError(try store.save(data: png)) { error in
            guard case ImageAttachmentStore.StoreError.oversizedImage = error else {
                return XCTFail("expected oversizedImage, got \(error)")
            }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty)

        ImageAttachmentStore.maxImportedImageBytes = cap
        XCTAssertNotNil(store.loadImage(path: try store.save(data: png)))
    }

    /// End to end through the importer: an over-cap `image_path` counts as a
    /// skipped image instead of ballooning the attachment store.
    func testEspansoOverSizeImagePathIsSkipped() throws {
        let cap = originalCap
        defer { ImageAttachmentStore.maxImportedImageBytes = cap }

        let root = try makeTempDir("espanso")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDir = try makeTempDir("store")
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let pngURL = root.appendingPathComponent("pic.png")
        try makePNGData().write(to: pngURL)
        try """
        matches:
          - trigger: ":big"
            image_path: "pic.png"
          - trigger: ":ok"
            replace: "text still imports"
        """.write(to: root.appendingPathComponent("base.yml"), atomically: true, encoding: .utf8)

        let store = ImageAttachmentStore(directory: storeDir)

        ImageAttachmentStore.maxImportedImageBytes = 10
        let result = try EspansoImporter.importFrom(root, imageStore: store)

        XCTAssertEqual(result.imageCount, 0)
        XCTAssertEqual(result.skippedImage, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty)
        let snippet = result.groups.flatMap(\.snippets).first { $0.triggerKeyword == ":ok" }
        XCTAssertNotNil(snippet, "the rest of the batch must survive an oversized image")

        ImageAttachmentStore.maxImportedImageBytes = cap
        let normalResult = try EspansoImporter.importFrom(root, imageStore: store)
        XCTAssertEqual(normalResult.imageCount, 1, "under the default cap the image imports")
    }
}
