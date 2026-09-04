import AppKit
import XCTest
@testable import ExpanderEngine

final class ImageSnippetTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-img-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func removeTempDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

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

    @discardableResult
    private func writePNG(named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try makePNGData().write(to: url)
        return url
    }

    // MARK: - ImageAttachmentStore

    func testStoreImportLoadDeleteRoundTrip() throws {
        let dir = try makeTempDir("store")
        defer { removeTempDir(dir) }
        let srcDir = try makeTempDir("src")
        defer { removeTempDir(srcDir) }

        let store = ImageAttachmentStore(directory: dir)
        let source = try writePNG(named: "logo.png", in: srcDir)

        let storedName = try store.importImage(from: source)
        XCTAssertFalse(storedName.isEmpty)
        XCTAssertTrue(storedName.hasSuffix(".png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(forImagePath: storedName).path))

        XCTAssertNotNil(store.loadImage(path: storedName))

        store.deleteImage(path: storedName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(forImagePath: storedName).path))
    }

    func testStoreRejectsUnsupportedExtension() throws {
        let dir = try makeTempDir("store")
        defer { removeTempDir(dir) }
        let srcDir = try makeTempDir("src")
        defer { removeTempDir(srcDir) }

        let text = srcDir.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)

        let store = ImageAttachmentStore(directory: dir)
        XCTAssertThrowsError(try store.importImage(from: text)) { error in
            guard case ImageAttachmentStore.StoreError.unsupportedImageType = error else {
                return XCTFail("expected unsupportedImageType, got \(error)")
            }
        }
    }

    func testStoreRejectsUnreadableImage() throws {
        let dir = try makeTempDir("store")
        defer { removeTempDir(dir) }
        let srcDir = try makeTempDir("src")
        defer { removeTempDir(srcDir) }

        let fake = srcDir.appendingPathComponent("fake.png")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: fake)

        let store = ImageAttachmentStore(directory: dir)
        XCTAssertThrowsError(try store.importImage(from: fake)) { error in
            guard case ImageAttachmentStore.StoreError.unreadableImage = error else {
                return XCTFail("expected unreadableImage, got \(error)")
            }
        }
    }

    func testSaveDataRoundTrip() throws {
        let dir = try makeTempDir("store")
        defer { removeTempDir(dir) }
        let store = ImageAttachmentStore(directory: dir)

        let name = try store.save(data: makePNGData(), preferredExtension: "png")
        XCTAssertNotNil(store.loadImage(path: name))
    }

    // MARK: - SnippetModel imagePath

    func testSnippetModelCodableRoundTripWithImagePath() throws {
        let snippet = SnippetModel(
            title: "Logo",
            triggerKeyword: ":logo",
            replacementText: "",
            imagePath: "abc.png"
        )
        let data = try JSONEncoder().encode(snippet)
        let decoded = try JSONDecoder().decode(SnippetModel.self, from: data)
        XCTAssertEqual(decoded, snippet)
        XCTAssertTrue(decoded.isImageSnippet)
        XCTAssertEqual(decoded.imagePath, "abc.png")
    }

    func testSnippetModelDecodesLegacyWithoutImagePath() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "title": "Plain",
            "triggerKeyword": ":hi",
            "replacementText": "Hello",
            "isCaseSensitive": false,
            "requireWordBoundary": true,
            "isPlainText": true,
            "enabled": true,
            "createdAt": Date().timeIntervalSinceReferenceDate,
            "updatedAt": Date().timeIntervalSinceReferenceDate,
            "usageCount": 0
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(SnippetModel.self, from: data)
        XCTAssertEqual(decoded.imagePath, "")
        XCTAssertFalse(decoded.isImageSnippet)
    }

    // MARK: - Espanso image_path import

    func testEspansoImagePathImportsAsImageSnippet() throws {
        let espansoDir = try makeTempDir("espanso")
        defer { removeTempDir(espansoDir) }
        let storeDir = try makeTempDir("imgstore")
        defer { removeTempDir(storeDir) }

        let imageURL = try writePNG(named: "pic.png", in: espansoDir)
        let yaml = """
        matches:
          - trigger: ":logo"
            image_path: "\(imageURL.lastPathComponent)"
            label: "Logo"
        """
        try yaml.write(to: espansoDir.appendingPathComponent("images.yml"), atomically: true, encoding: .utf8)

        let store = ImageAttachmentStore(directory: storeDir)
        let result = try EspansoImporter.importFrom(espansoDir, imageStore: store)

        XCTAssertEqual(result.imageCount, 1)
        XCTAssertEqual(result.skippedImage, 0)
        let snippet = result.groups.flatMap(\.snippets).first { $0.triggerKeyword == ":logo" }
        let unwrapped = try XCTUnwrap(snippet)
        XCTAssertTrue(unwrapped.isImageSnippet)
        XCTAssertEqual(unwrapped.replacementText, "")
        XCTAssertEqual(unwrapped.label, "Logo")
        // The image was copied into the store (self-contained).
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(forImagePath: unwrapped.imagePath).path))
        XCTAssertNotNil(store.loadImage(path: unwrapped.imagePath))
    }

    func testEspansoMissingImageIsSkipped() throws {
        let espansoDir = try makeTempDir("espanso")
        defer { removeTempDir(espansoDir) }
        let storeDir = try makeTempDir("imgstore")
        defer { removeTempDir(storeDir) }

        let yaml = """
        matches:
          - trigger: ":gone"
            image_path: "does-not-exist.png"
        """
        try yaml.write(to: espansoDir.appendingPathComponent("broken.yml"), atomically: true, encoding: .utf8)

        let store = ImageAttachmentStore(directory: storeDir)
        let result = try EspansoImporter.importFrom(espansoDir, imageStore: store)

        XCTAssertEqual(result.imageCount, 0)
        XCTAssertEqual(result.skippedImage, 1)
        XCTAssertTrue(result.groups.flatMap(\.snippets).isEmpty)
    }

    func testUnifiedImporterImportsEspansoImages() throws {
        let espansoDir = try makeTempDir("espanso")
        defer { removeTempDir(espansoDir) }
        let storeDir = try makeTempDir("imgstore")
        defer { removeTempDir(storeDir) }

        _ = try writePNG(named: "dot.png", in: espansoDir)
        let yaml = """
        matches:
          - trigger: ":dot"
            image_path: "dot.png"
        """
        try yaml.write(to: espansoDir.appendingPathComponent("img.yml"), atomically: true, encoding: .utf8)

        let store = ImageAttachmentStore(directory: storeDir)
        let result = try SnippetImporter.importFrom(espansoDir, imageStore: store)

        XCTAssertEqual(result.kind, .espanso)
        XCTAssertEqual(result.imageCount, 1)
        XCTAssertTrue(result.notes.contains(.imageMatchImported(1)))
    }
}
