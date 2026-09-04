import AppKit
import ImageIO
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

    /// Rewrites only the PNG IHDR dimensions and its CRC. The encoded payload
    /// stays tiny, reproducing a decompression bomb without allocating the
    /// claimed bitmap in the test process.
    private func makePNGData(claimingWidth width: UInt32, height: UInt32) throws -> Data {
        var bytes = [UInt8](try makePNGData())
        guard bytes.count >= 33, Array(bytes[12 ..< 16]) == Array("IHDR".utf8) else {
            throw NSError(domain: "tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected PNG layout"])
        }

        func writeBigEndian(_ value: UInt32, at offset: Int) {
            bytes[offset] = UInt8((value >> 24) & 0xFF)
            bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
            bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 3] = UInt8(value & 0xFF)
        }

        writeBigEndian(width, at: 16)
        writeBigEndian(height, at: 20)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes[12 ..< 29] {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
        writeBigEndian(crc ^ 0xFFFF_FFFF, at: 29)
        return Data(bytes)
    }

    private func makeJPEGData() throws -> Data {
        let rep = NSBitmapImageRep(data: try makePNGData())
        guard let data = rep?.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw NSError(domain: "tests", code: 3, userInfo: [NSLocalizedDescriptionKey: "JPEG encode failed"])
        }
        return data
    }

    private func makeMultiFrameTIFFData(frameSizes: [(width: Int, height: Int)]) throws -> Data {
        let output = NSMutableData()
        guard !frameSizes.isEmpty,
              let destination = CGImageDestinationCreateWithData(
                  output,
                  "public.tiff" as CFString,
                  frameSizes.count,
                  nil
              ) else {
            throw NSError(domain: "tests", code: 4, userInfo: [NSLocalizedDescriptionKey: "TIFF destination failed"])
        }

        for size in frameSizes {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: size.width,
                pixelsHigh: size.height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let image = rep.cgImage else {
                throw NSError(domain: "tests", code: 5, userInfo: [NSLocalizedDescriptionKey: "TIFF frame failed"])
            }
            CGImageDestinationAddImage(destination, image, nil)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "tests", code: 6, userInfo: [NSLocalizedDescriptionKey: "TIFF finalize failed"])
        }
        return output as Data
    }

    func testMetadataRejectsOversizedLaterFrameForFileAndRawDataPaths() throws {
        let originalPixelCap = ImageAttachmentStore.maxImportedImagePixels
        defer { ImageAttachmentStore.maxImportedImagePixels = originalPixelCap }
        ImageAttachmentStore.maxImportedImagePixels = 16

        let data = try makeMultiFrameTIFFData(frameSizes: [
            (width: 4, height: 4),
            (width: 5, height: 4),
        ])
        let sourceDir = try makeTempDir("multiframe-src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let source = sourceDir.appendingPathComponent("later-frame-bomb.tiff")
        try data.write(to: source)

        let storeDir = try makeTempDir("multiframe-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)

        XCTAssertThrowsError(try store.importImage(from: source)) { error in
            XCTAssertEqual(error as? ImageAttachmentStore.StoreError, .oversizedImageDimensions)
        }
        XCTAssertThrowsError(try store.save(data: data, preferredExtension: "tiff")) { error in
            XCTAssertEqual(error as? ImageAttachmentStore.StoreError, .oversizedImageDimensions)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty)
    }

    func testMetadataRejectsExcessiveFrameCountBeforeAppKitDecode() throws {
        let data = try makeMultiFrameTIFFData(
            frameSizes: Array(
                repeating: (width: 1, height: 1),
                count: ImageAttachmentStore.maxImportedImageFrameCount + 1
            )
        )
        let storeDir = try makeTempDir("frame-count-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)

        XCTAssertThrowsError(try store.save(data: data, preferredExtension: "tiff")) { error in
            XCTAssertEqual(error as? ImageAttachmentStore.StoreError, .oversizedImageDimensions)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty)
    }

    func testMetadataBoundsAggregateFramePixelsAndPreservesInBudgetTIFF() throws {
        let originalPixelCap = ImageAttachmentStore.maxImportedImagePixels
        defer { ImageAttachmentStore.maxImportedImagePixels = originalPixelCap }
        ImageAttachmentStore.maxImportedImagePixels = 16

        let overBudget = try makeMultiFrameTIFFData(frameSizes: [
            (width: 4, height: 4),
            (width: 4, height: 4),
            (width: 4, height: 4),
        ])
        let storeDir = try makeTempDir("aggregate-frame-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)

        XCTAssertEqual(ImageAttachmentStore.maxImportedImageAggregatePixels, 32)
        XCTAssertThrowsError(try store.save(data: overBudget, preferredExtension: "tiff")) { error in
            XCTAssertEqual(error as? ImageAttachmentStore.StoreError, .oversizedImageDimensions)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty)

        let atBudget = try makeMultiFrameTIFFData(frameSizes: [
            (width: 4, height: 4),
            (width: 4, height: 4),
        ])
        let stored = try store.save(data: atBudget, preferredExtension: "tiff")
        XCTAssertNotNil(store.loadImage(path: stored))
    }

    func testMetadataRejectsTinyFilesClaimingExcessiveDecodedDimensionsOrPixels() throws {
        let originalPixelCap = ImageAttachmentStore.maxImportedImagePixels
        defer { ImageAttachmentStore.maxImportedImagePixels = originalPixelCap }
        let sourceDir = try makeTempDir("dimension-src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let store = ImageAttachmentStore(directory: try makeTempDir("dimension-store"))
        defer { try? FileManager.default.removeItem(at: store.imagesDirectory) }

        let tooWide = sourceDir.appendingPathComponent("too-wide.png")
        try makePNGData(
            claimingWidth: UInt32(ImageAttachmentStore.maxImportedImageDimension + 1),
            height: 1
        ).write(to: tooWide)
        XCTAssertThrowsError(try store.importImage(from: tooWide)) { error in
            XCTAssertEqual(error as? ImageAttachmentStore.StoreError, .oversizedImageDimensions)
        }

        let tooManyPixels = sourceDir.appendingPathComponent("too-many-pixels.png")
        ImageAttachmentStore.maxImportedImagePixels = 15
        try makePNGData().write(to: tooManyPixels)
        XCTAssertThrowsError(try store.importImage(from: tooManyPixels)) { error in
            XCTAssertEqual(error as? ImageAttachmentStore.StoreError, .oversizedImageDimensions)
        }
    }

    func testMetadataGatePreservesNormalPNGAndJPEGImports() throws {
        let sourceDir = try makeTempDir("normal-format-src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let storeDir = try makeTempDir("normal-format-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)

        let fixtures: [(String, Data)] = [
            ("normal.png", try makePNGData()),
            ("normal.jpg", try makeJPEGData()),
        ]
        for (name, data) in fixtures {
            let source = sourceDir.appendingPathComponent(name)
            try data.write(to: source)
            let stored = try store.importImage(from: source)
            XCTAssertNotNil(store.loadImage(path: stored), name)
        }
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
