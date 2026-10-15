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

    // One ImageIO walk and one NSImage decode per accepted payload.
    private final class AttachmentValidationCounter {
        private(set) var metadata = 0
        private(set) var decodes = 0

        func inspectMetadata(_ data: Data, _ source: String) throws {
            metadata += 1
            try ImageAttachmentStore.validateDecodedImageSize(data, sourceDescription: source)
        }

        func decode(_ data: Data) -> NSImage? {
            decodes += 1
            return NSImage(data: data)
        }
    }

    func testImportImageValidatesAndDecodesOnce() throws {
        let sourceDir = try makeTempDir("once-src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let storeDir = try makeTempDir("once-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)

        let png = try makePNGData()
        let pngURL = sourceDir.appendingPathComponent("tiny.png")
        try png.write(to: pngURL)

        let first = AttachmentValidationCounter()
        let stored = try store.importImage(
            from: pngURL,
            inspectMetadata: first.inspectMetadata,
            decode: first.decode
        )
        XCTAssertEqual(first.metadata, 1)
        XCTAssertEqual(first.decodes, 1)
        let written = try Data(contentsOf: store.url(forImagePath: stored))
        XCTAssertEqual(written, png)
        XCTAssertNotNil(store.loadImage(path: stored))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).count, 1)

        let second = AttachmentValidationCounter()
        let storedAgain = try store.importImage(
            from: pngURL,
            inspectMetadata: second.inspectMetadata,
            decode: second.decode
        )
        XCTAssertEqual(second.metadata, 1)
        XCTAssertEqual(second.decodes, 1)
        XCTAssertNotEqual(storedAgain, stored)
        XCTAssertEqual(try Data(contentsOf: store.url(forImagePath: storedAgain)), png)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).count, 2)
    }

    func testPrepareThenSavePreparedValidatesAndDecodesOnce() throws {
        let sourceDir = try makeTempDir("prepared-src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let storeDir = try makeTempDir("prepared-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)

        let png = try makePNGData()
        let pngURL = sourceDir.appendingPathComponent("tiny.png")
        try png.write(to: pngURL)

        let counter = AttachmentValidationCounter()
        let prepared = try store.prepareImage(
            from: pngURL,
            inspectMetadata: counter.inspectMetadata,
            decode: counter.decode
        )
        let stored = try store.save(prepared: prepared)
        XCTAssertEqual(counter.metadata, 1)
        XCTAssertEqual(counter.decodes, 1)
        XCTAssertEqual(try Data(contentsOf: store.url(forImagePath: stored)), prepared.data)
        XCTAssertEqual(prepared.data, png)
        XCTAssertNotNil(store.loadImage(path: stored))
    }

    func testSavePreparedRefusesWhenCapDropsAfterPrepareWithoutDecodingAgain() throws {
        let cap = ImageAttachmentStore.maxImportedImageBytes
        defer { ImageAttachmentStore.maxImportedImageBytes = cap }

        let sourceDir = try makeTempDir("prepared-cap-src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let storeDir = try makeTempDir("prepared-cap-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)
        let pngURL = sourceDir.appendingPathComponent("tiny.png")
        try makePNGData().write(to: pngURL)

        let counter = AttachmentValidationCounter()
        let prepared = try store.prepareImage(
            from: pngURL,
            inspectMetadata: counter.inspectMetadata,
            decode: counter.decode
        )
        ImageAttachmentStore.maxImportedImageBytes = prepared.data.count - 1
        XCTAssertThrowsError(try store.save(prepared: prepared)) { error in
            XCTAssertEqual(
                error as? ImageAttachmentStore.StoreError,
                .oversizedImage("\(prepared.data.count) bytes")
            )
        }
        XCTAssertEqual(counter.metadata, 1)
        XCTAssertEqual(counter.decodes, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty)
    }

    func testSaveDataValidatesAndDecodesOnce() throws {
        let storeDir = try makeTempDir("save-once")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)
        let png = try makePNGData()
        let counter = AttachmentValidationCounter()

        let stored = try store.save(
            data: png,
            inspectMetadata: counter.inspectMetadata,
            decode: counter.decode
        )
        XCTAssertEqual(counter.metadata, 1)
        XCTAssertEqual(counter.decodes, 1)
        XCTAssertEqual(try Data(contentsOf: store.url(forImagePath: stored)), png)
        XCTAssertNotNil(store.loadImage(path: stored))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).count, 1)
    }

    func testSaveDataAboveLoweredCapSkipsMetadataDecodeAndWrite() throws {
        let cap = ImageAttachmentStore.maxImportedImageBytes
        defer { ImageAttachmentStore.maxImportedImageBytes = cap }

        let storeDir = try makeTempDir("save-cap")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)
        let png = try makePNGData()
        let counter = AttachmentValidationCounter()

        ImageAttachmentStore.maxImportedImageBytes = 10
        XCTAssertThrowsError(try store.save(
            data: png,
            inspectMetadata: counter.inspectMetadata,
            decode: counter.decode
        )) { error in
            guard case ImageAttachmentStore.StoreError.oversizedImage = error else {
                return XCTFail("expected oversizedImage, got \(error)")
            }
        }
        XCTAssertEqual(counter.metadata, 0)
        XCTAssertEqual(counter.decodes, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty)
    }

    func testImportImageAboveLoweredCapSkipsMetadataDecodeAndWrite() throws {
        let cap = ImageAttachmentStore.maxImportedImageBytes
        defer { ImageAttachmentStore.maxImportedImageBytes = cap }

        let sourceDir = try makeTempDir("import-cap-src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let storeDir = try makeTempDir("import-cap-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let pngURL = sourceDir.appendingPathComponent("tiny.png")
        try makePNGData().write(to: pngURL)

        let store = ImageAttachmentStore(directory: storeDir)
        let counter = AttachmentValidationCounter()
        ImageAttachmentStore.maxImportedImageBytes = 10
        XCTAssertThrowsError(try store.importImage(
            from: pngURL,
            inspectMetadata: counter.inspectMetadata,
            decode: counter.decode
        )) { error in
            guard case ImageAttachmentStore.StoreError.oversizedImage = error else {
                return XCTFail("expected oversizedImage, got \(error)")
            }
        }
        XCTAssertEqual(counter.metadata, 0)
        XCTAssertEqual(counter.decodes, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty)
    }

    func testUnsupportedExtensionSkipsMetadataAndDecode() throws {
        let sourceDir = try makeTempDir("bad-ext-src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let storeDir = try makeTempDir("bad-ext-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)
        let png = try makePNGData()

        for ext in ["exe", "txt"] {
            let counter = AttachmentValidationCounter()
            XCTAssertThrowsError(try store.save(
                data: png,
                preferredExtension: ext,
                inspectMetadata: counter.inspectMetadata,
                decode: counter.decode
            )) { error in
                XCTAssertEqual(
                    error as? ImageAttachmentStore.StoreError,
                    .unsupportedImageType(ext)
                )
            }
            XCTAssertEqual(counter.metadata, 0, ext)
            XCTAssertEqual(counter.decodes, 0, ext)

            let source = sourceDir.appendingPathComponent("payload.\(ext)")
            let prepareCounter = AttachmentValidationCounter()
            XCTAssertThrowsError(try store.prepareImage(
                from: source,
                inspectMetadata: prepareCounter.inspectMetadata,
                decode: prepareCounter.decode
            )) { error in
                XCTAssertEqual(
                    error as? ImageAttachmentStore.StoreError,
                    .unsupportedImageType(ext)
                )
            }
            XCTAssertEqual(prepareCounter.metadata, 0, ext)
            XCTAssertEqual(prepareCounter.decodes, 0, ext)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty)
    }

    func testMetadataRejectionSkipsDecodeAndWrite() throws {
        let sourceDir = try makeTempDir("meta-fail-src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let storeDir = try makeTempDir("meta-fail-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)
        let png = try makePNGData()
        let pngURL = sourceDir.appendingPathComponent("tiny.png")
        try png.write(to: pngURL)

        var saveDecodes = 0
        XCTAssertThrowsError(try store.save(
            data: png,
            inspectMetadata: { _, _ in
                throw ImageAttachmentStore.StoreError.oversizedImageDimensions
            },
            decode: { data in
                saveDecodes += 1
                return NSImage(data: data)
            }
        )) { error in
            XCTAssertEqual(error as? ImageAttachmentStore.StoreError, .oversizedImageDimensions)
        }
        XCTAssertEqual(saveDecodes, 0)

        var importDecodes = 0
        XCTAssertThrowsError(try store.importImage(
            from: pngURL,
            inspectMetadata: { _, _ in
                throw ImageAttachmentStore.StoreError.oversizedImageDimensions
            },
            decode: { data in
                importDecodes += 1
                return NSImage(data: data)
            }
        )) { error in
            XCTAssertEqual(error as? ImageAttachmentStore.StoreError, .oversizedImageDimensions)
        }
        XCTAssertEqual(importDecodes, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty)
    }

    func testNilDecodeThrowsUnreadableImageAfterMetadataAndWritesNothing() throws {
        let sourceDir = try makeTempDir("nil-decode-src")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let storeDir = try makeTempDir("nil-decode-store")
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = ImageAttachmentStore(directory: storeDir)
        let png = try makePNGData()
        let pngURL = sourceDir.appendingPathComponent("tiny.png")
        try png.write(to: pngURL)

        let saveCounter = AttachmentValidationCounter()
        var saveDecodes = 0
        XCTAssertThrowsError(try store.save(
            data: png,
            inspectMetadata: saveCounter.inspectMetadata,
            decode: { _ in
                XCTAssertEqual(saveCounter.metadata, 1)
                saveDecodes += 1
                return nil
            }
        )) { error in
            XCTAssertEqual(
                error as? ImageAttachmentStore.StoreError,
                .unreadableImage("\(png.count) bytes")
            )
        }
        XCTAssertEqual(saveCounter.metadata, 1)
        XCTAssertEqual(saveDecodes, 1)

        let importCounter = AttachmentValidationCounter()
        var importDecodes = 0
        XCTAssertThrowsError(try store.importImage(
            from: pngURL,
            inspectMetadata: importCounter.inspectMetadata,
            decode: { _ in
                XCTAssertEqual(importCounter.metadata, 1)
                importDecodes += 1
                return nil
            }
        )) { error in
            XCTAssertEqual(
                error as? ImageAttachmentStore.StoreError,
                .unreadableImage(pngURL.path)
            )
        }
        XCTAssertEqual(importCounter.metadata, 1)
        XCTAssertEqual(importDecodes, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storeDir.path).isEmpty)
    }
}
