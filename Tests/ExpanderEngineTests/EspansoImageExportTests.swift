import AppKit
import XCTest
@testable import ExpanderEngine

/// Espanso image export must round-trip through `EspansoImporter`, which rejects an
/// absolute `image_path` and any path containing `..` or a leading backslash.
final class EspansoImageExportTests: XCTestCase {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-espanso-export-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePNGData(seed: UInt8) throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4 + Int(seed),
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep, let pixels = rep.bitmapData else {
            throw NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG buffer failed"])
        }
        let byteCount = rep.bytesPerRow * rep.pixelsHigh
        for index in 0..<byteCount {
            pixels[index] = seed
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        return png
    }

    private func store(in root: URL) -> ImageAttachmentStore {
        ImageAttachmentStore(directory: root.appendingPathComponent("Images", isDirectory: true))
    }

    private func snippet(trigger: String, imagePath: String) -> SnippetModel {
        SnippetModel(title: trigger, triggerKeyword: trigger, replacementText: "", imagePath: imagePath)
    }

    private func imagePaths(in yaml: String) -> [String] {
        yaml.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("image_path:") else { return nil }
            var value = trimmed.dropFirst("image_path:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return String(value)
        }
    }

    private func assertSafeRelative(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(SnippetExporter.isSafeImageRelativePath(path), "unsafe image_path \(path)", file: file, line: line)
        XCTAssertFalse(path.hasPrefix("/"), file: file, line: line)
        XCTAssertFalse(path.hasPrefix("\\"), file: file, line: line)
        XCTAssertFalse(path.contains(".."), file: file, line: line)
        XCTAssertFalse(path.contains("\\"), file: file, line: line)
        XCTAssertTrue(path.hasPrefix("\(SnippetExporter.espansoImageDirectoryName)/"), file: file, line: line)
    }

    private func materialize(
        _ document: SnippetExporter.EspansoDirectoryDocument,
        in directory: URL
    ) throws {
        for file in document.files {
            try Data(file.contents.utf8).write(to: directory.appendingPathComponent(file.fileName), options: .atomic)
        }
        for image in document.images {
            assertSafeRelative(image.relativePath)
            let folder = directory.appendingPathComponent(SnippetExporter.espansoImageDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = (image.relativePath as NSString).lastPathComponent
            try image.data.write(to: folder.appendingPathComponent(name), options: .atomic)
        }
    }

    func testEspansoYAMLWritesARelativeImagePath() throws {
        let root = try makeTempDir("relative")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        let png = try makePNGData(seed: 4)
        let storedName = try imageStore.save(data: png, preferredExtension: "png")
        let group = SnippetGroup(name: "Images", snippets: [snippet(trigger: ":logo", imagePath: storedName)])
        let options = SnippetExporter.Options(imageStore: imageStore)

        let yaml = try SnippetExporter.espansoYAML(from: [group], options: options)
        let paths = imagePaths(in: yaml)
        XCTAssertEqual(paths.count, 1)
        assertSafeRelative(try XCTUnwrap(paths.first))
        XCTAssertFalse(yaml.contains(imageStore.imagesDirectory.path), "store path leaked into YAML: \(yaml)")

        let document = try SnippetExporter.espansoDirectoryDocument(from: [group], options: options)
        XCTAssertEqual(document.images.count, 1)
        XCTAssertEqual(document.images.first?.data, png)
        XCTAssertEqual(document.images.first?.relativePath, paths.first)

        let exported = root.appendingPathComponent("match", isDirectory: true)
        try FileManager.default.createDirectory(at: exported, withIntermediateDirectories: true)
        try materialize(document, in: exported)

        let importedStore = ImageAttachmentStore(directory: root.appendingPathComponent("imported", isDirectory: true))
        let result = try EspansoImporter.importFrom(exported, imageStore: importedStore)
        XCTAssertEqual(result.imageCount, 1)
        XCTAssertEqual(result.skippedImage, 0)
        let imported = try XCTUnwrap(result.groups.flatMap(\.snippets).first { $0.triggerKeyword == ":logo" })
        XCTAssertTrue(imported.isImageSnippet)
        let roundTrip = try Data(contentsOf: importedStore.url(forImagePath: imported.imagePath))
        XCTAssertEqual(roundTrip, png)
    }

    func testUnicodeAndOddAttachmentNamesAreSanitizedAndRoundTrip() throws {
        let root = try makeTempDir("unicode")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        let png = try makePNGData(seed: 9)
        let oddName = "café 図 (1).png"
        try FileManager.default.createDirectory(at: imageStore.imagesDirectory, withIntermediateDirectories: true)
        try png.write(to: imageStore.imagesDirectory.appendingPathComponent(oddName), options: .atomic)

        let group = SnippetGroup(name: "Odd", snippets: [snippet(trigger: ":odd", imagePath: oddName)])
        let document = try SnippetExporter.espansoDirectoryDocument(
            from: [group],
            options: SnippetExporter.Options(imageStore: imageStore)
        )
        let path = try XCTUnwrap(document.images.first?.relativePath)
        assertSafeRelative(path)
        XCTAssertEqual(path, "images/caf1.png")
        XCTAssertFalse(path.contains(".."))
        XCTAssertEqual(document.images.first?.data, png)

        let exported = root.appendingPathComponent("match", isDirectory: true)
        try FileManager.default.createDirectory(at: exported, withIntermediateDirectories: true)
        try materialize(document, in: exported)
        let importedStore = ImageAttachmentStore(directory: root.appendingPathComponent("imported", isDirectory: true))
        let result = try EspansoImporter.importFrom(exported, imageStore: importedStore)
        XCTAssertEqual(result.imageCount, 1)
        let imported = try XCTUnwrap(result.groups.flatMap(\.snippets).first)
        XCTAssertEqual(try Data(contentsOf: importedStore.url(forImagePath: imported.imagePath)), png)
    }

    func testNamesThatWouldSanitizeToDotDotAreRefused() throws {
        let root = try makeTempDir("dotdot-name")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        let png = try makePNGData(seed: 3)
        try FileManager.default.createDirectory(at: imageStore.imagesDirectory, withIntermediateDirectories: true)
        let storedName = ".. café.png"
        try png.write(to: imageStore.imagesDirectory.appendingPathComponent(storedName), options: .atomic)
        let group = SnippetGroup(name: "Odd", snippets: [snippet(trigger: ":dots", imagePath: storedName)])

        XCTAssertThrowsError(try SnippetExporter.espansoYAML(
            from: [group],
            options: SnippetExporter.Options(imageStore: imageStore)
        )) { error in
            guard case SnippetExporter.ExportError.imageUnavailable = error else {
                return XCTFail("expected imageUnavailable, got \(error)")
            }
            let description = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertFalse(description.contains(".."))
            XCTAssertFalse(description.contains("/"))
        }
    }

    func testDuplicateSanitizedNamesWithDifferentBytesAreDisambiguated() throws {
        let root = try makeTempDir("dupe")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        let first = try makePNGData(seed: 1)
        let second = try makePNGData(seed: 2)
        XCTAssertNotEqual(first, second)
        try FileManager.default.createDirectory(at: imageStore.imagesDirectory, withIntermediateDirectories: true)
        try first.write(to: imageStore.imagesDirectory.appendingPathComponent("photo.png"), options: .atomic)
        try second.write(to: imageStore.imagesDirectory.appendingPathComponent("photo!.png"), options: .atomic)

        let group = SnippetGroup(name: "Pics", snippets: [
            snippet(trigger: ":one", imagePath: "photo.png"),
            snippet(trigger: ":two", imagePath: "photo!.png"),
        ])
        let document = try SnippetExporter.espansoDirectoryDocument(
            from: [group],
            options: SnippetExporter.Options(imageStore: imageStore)
        )
        XCTAssertEqual(document.images.map(\.relativePath), ["images/photo.png", "images/photo-2.png"])
        XCTAssertEqual(document.images.map(\.data), [first, second])
        for image in document.images { assertSafeRelative(image.relativePath) }

        let exported = root.appendingPathComponent("match", isDirectory: true)
        try FileManager.default.createDirectory(at: exported, withIntermediateDirectories: true)
        try materialize(document, in: exported)
        let importedStore = ImageAttachmentStore(directory: root.appendingPathComponent("imported", isDirectory: true))
        let result = try EspansoImporter.importFrom(exported, imageStore: importedStore)
        XCTAssertEqual(result.imageCount, 2)
        let byTrigger = Dictionary(uniqueKeysWithValues: result.groups.flatMap(\.snippets).map { ($0.triggerKeyword, $0) })
        XCTAssertEqual(try Data(contentsOf: importedStore.url(forImagePath: try XCTUnwrap(byTrigger[":one"]).imagePath)), first)
        XCTAssertEqual(try Data(contentsOf: importedStore.url(forImagePath: try XCTUnwrap(byTrigger[":two"]).imagePath)), second)
    }

    func testSameBytesShareOneRelativeFile() throws {
        let root = try makeTempDir("same")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        let png = try makePNGData(seed: 7)
        try FileManager.default.createDirectory(at: imageStore.imagesDirectory, withIntermediateDirectories: true)
        try png.write(to: imageStore.imagesDirectory.appendingPathComponent("photo.png"), options: .atomic)
        try png.write(to: imageStore.imagesDirectory.appendingPathComponent("photo!.png"), options: .atomic)
        let group = SnippetGroup(name: "Pics", snippets: [
            snippet(trigger: ":one", imagePath: "photo.png"),
            snippet(trigger: ":two", imagePath: "photo!.png"),
        ])
        let document = try SnippetExporter.espansoDirectoryDocument(
            from: [group],
            options: SnippetExporter.Options(imageStore: imageStore)
        )
        XCTAssertEqual(document.images.count, 1)
        XCTAssertEqual(document.images.first?.relativePath, "images/photo.png")
        let paths = document.files.flatMap { imagePaths(in: $0.contents) }
        XCTAssertEqual(paths, ["images/photo.png", "images/photo.png"])
    }

    func testAbsoluteMissingDotDotAndOutsideSymlinkAreNotPublished() throws {
        let root = try makeTempDir("closed")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        let png = try makePNGData(seed: 5)
        let storedName = try imageStore.save(data: png, preferredExtension: "png")
        let absolute = imageStore.url(forImagePath: storedName).path
        XCTAssertTrue(absolute.hasPrefix("/"))

        let outside = root.appendingPathComponent("outside.png")
        try png.write(to: outside, options: .atomic)
        try FileManager.default.createDirectory(at: imageStore.imagesDirectory, withIntermediateDirectories: true)
        let link = imageStore.imagesDirectory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let cases: [(String, String)] = [
            (":absolute", absolute),
            (":missing", "missing.png"),
            (":escape", "../outside.png"),
            (":link", "link.png"),
        ]
        for (trigger, imagePath) in cases {
            let group = SnippetGroup(name: "Closed", snippets: [snippet(trigger: trigger, imagePath: imagePath)])
            XCTAssertThrowsError(try SnippetExporter.espansoDirectoryDocument(
                from: [group],
                options: SnippetExporter.Options(imageStore: imageStore)
            ), "\(trigger) must not export") { error in
                guard case SnippetExporter.ExportError.imageUnavailable = error else {
                    return XCTFail("\(trigger): expected imageUnavailable, got \(error)")
                }
                let rendered = String(describing: error) + ((error as? LocalizedError)?.errorDescription ?? "")
                XCTAssertFalse(rendered.contains(absolute), "\(trigger) leaked the store path")
                XCTAssertFalse(rendered.contains(outside.path), "\(trigger) leaked the outside path")
                XCTAssertFalse(rendered.contains("\\"), "\(trigger) published a backslash")
            }
        }
    }

    func testBackslashInTheStoredFileNameIsNotWritten() throws {
        let root = try makeTempDir("winname")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        let png = try makePNGData(seed: 6)
        try FileManager.default.createDirectory(at: imageStore.imagesDirectory, withIntermediateDirectories: true)
        let storedName = "foo\\bar.png"
        let url = URL(fileURLWithPath: imageStore.imagesDirectory.path + "/" + storedName)
        try png.write(to: url, options: .atomic)
        let group = SnippetGroup(name: "Win", snippets: [snippet(trigger: ":win", imagePath: storedName)])
        let document = try SnippetExporter.espansoDirectoryDocument(
            from: [group],
            options: SnippetExporter.Options(imageStore: imageStore)
        )
        let path = try XCTUnwrap(document.images.first?.relativePath)
        assertSafeRelative(path)
        XCTAssertEqual(path, "images/bar.png")
        XCTAssertFalse(document.files.contains { $0.contents.contains("\\") })
    }
}
