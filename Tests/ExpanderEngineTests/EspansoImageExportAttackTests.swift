import AppKit
import XCTest
@testable import ExpanderEngine

/// Adversarial checks for Espanso image export and import containment.
/// Every fixture stays under the test temp directory. `ImageAttachmentStore.shared`
/// and `SnippetExporter.Options.default` are never used: both follow the live library.
final class EspansoImageExportAttackTests: XCTestCase {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-espanso-attack-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePNGData(seed: UInt8) throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8 + Int(seed),
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
            pixels[index] = seed &+ UInt8(index & 0xff)
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

    private func options(_ imageStore: ImageAttachmentStore?) -> SnippetExporter.Options {
        SnippetExporter.Options(includeDisabled: true, imageStore: imageStore)
    }

    private func imagePaths(in yaml: String) -> [String] {
        yaml.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("image_path:") else { return nil }
            var value = trimmed.dropFirst("image_path:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            } else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast())
            }
            return String(value)
        }
    }

    /// Invariants the claim makes, checked without trusting `isSafeImageRelativePath` alone.
    private func assertPublishedPath(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(path.isEmpty, file: file, line: line)
        XCTAssertFalse(path.hasPrefix("/"), "absolute image_path \(path)", file: file, line: line)
        XCTAssertFalse(path.hasPrefix("\\"), "backslash image_path \(path)", file: file, line: line)
        XCTAssertFalse(path.contains(".."), "dot-dot image_path \(path)", file: file, line: line)
        XCTAssertFalse(path.contains("\\"), "backslash image_path \(path)", file: file, line: line)
        XCTAssertFalse(path.contains("\n"), "newline image_path \(path)", file: file, line: line)
        XCTAssertFalse(path.contains("\r"), "cr image_path \(path)", file: file, line: line)
        XCTAssertFalse(path.contains("\0"), "nul image_path \(path)", file: file, line: line)
        XCTAssertTrue(path.hasPrefix("images/"), "not store-relative \(path)", file: file, line: line)
        XCTAssertFalse(path.hasSuffix("/"), "trailing slash \(path)", file: file, line: line)
        XCTAssertTrue(SnippetExporter.isSafeImageRelativePath(path), "product predicate rejected \(path)", file: file, line: line)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 2, "nested image_path \(path)", file: file, line: line)
        XCTAssertNotEqual(parts.last, "..", file: file, line: line)
        XCTAssertNotEqual(parts.last, ".", file: file, line: line)
    }

    private func assertYAMLDoesNotLeak(_ yaml: String, forbidden: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(yaml.contains(".."), "yaml contains ..\n\(yaml)", file: file, line: line)
        XCTAssertFalse(yaml.contains("\\"), "yaml contains backslash\n\(yaml)", file: file, line: line)
        XCTAssertFalse(yaml.contains("image_path: /"), file: file, line: line)
        XCTAssertFalse(yaml.contains("image_path: \"/"), file: file, line: line)
        XCTAssertFalse(yaml.contains("image_path: '/"), file: file, line: line)
        for secret in forbidden where !secret.isEmpty {
            XCTAssertFalse(yaml.contains(secret), "yaml leaked \(secret)", file: file, line: line)
        }
        for path in imagePaths(in: yaml) {
            assertPublishedPath(path, file: file, line: line)
        }
    }

    private func materialize(
        _ document: SnippetExporter.EspansoDirectoryDocument,
        in directory: URL
    ) throws {
        for file in document.files {
            assertYAMLDoesNotLeak(file.contents, forbidden: [])
            try Data(file.contents.utf8).write(to: directory.appendingPathComponent(file.fileName), options: .atomic)
        }
        for image in document.images {
            assertPublishedPath(image.relativePath)
            let folder = directory.appendingPathComponent("images", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = (image.relativePath as NSString).lastPathComponent
            let destination = folder.appendingPathComponent(name)
            try image.data.write(to: destination, options: .atomic)
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            XCTAssertNotEqual(values.isSymbolicLink, true, "export wrote a symlink for \(image.relativePath)")
            XCTAssertEqual(values.isRegularFile, true)
        }
    }

    private func importImages(from directory: URL, store: ImageAttachmentStore) throws -> EspansoImporter.ImportResult {
        try EspansoImporter.importFrom(directory, imageStore: store)
    }

    private func storedPayloads(_ store: ImageAttachmentStore) throws -> [Data] {
        let fm = FileManager.default
        let dir = store.imagesDirectory
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: dir.path).map { name in
            try Data(contentsOf: dir.appendingPathComponent(name))
        }
    }

    private func yamlQuote(_ raw: String) -> String {
        var escaped = ""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"\(escaped)\""
    }

    func testRealImageRoundTripsWithoutAbsoluteOrDotDotPaths() throws {
        let root = try makeTempDir("round")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        let png = try makePNGData(seed: 11)
        let storedName = try imageStore.save(data: png, preferredExtension: "png")
        let absolute = imageStore.url(forImagePath: storedName).path
        XCTAssertTrue(absolute.hasPrefix("/"))
        let group = SnippetGroup(name: "Images", snippets: [snippet(trigger: ":logo", imagePath: storedName)])

        let yaml = try SnippetExporter.espansoYAML(from: [group], options: options(imageStore))
        assertYAMLDoesNotLeak(yaml, forbidden: [absolute, imageStore.imagesDirectory.path])
        let paths = imagePaths(in: yaml)
        XCTAssertEqual(paths.count, 1)

        let csv = SnippetExporter.csv(from: [group], options: options(nil))
        XCTAssertTrue(csv.contains(storedName), "CSV stopped emitting the stored image name")
        XCTAssertFalse(csv.contains("images/\(storedName)"), "CSV was rewritten to an Espanso relative image path")
        XCTAssertFalse(csv.contains(absolute), "CSV published the absolute store path")

        let document = try SnippetExporter.espansoDirectoryDocument(from: [group], options: options(imageStore))
        XCTAssertEqual(document.images.count, 1)
        XCTAssertEqual(document.images.first?.data, png)
        XCTAssertEqual(document.images.first?.relativePath, paths.first)

        let exported = root.appendingPathComponent("match", isDirectory: true)
        try FileManager.default.createDirectory(at: exported, withIntermediateDirectories: true)
        try materialize(document, in: exported)
        let importedStore = ImageAttachmentStore(directory: root.appendingPathComponent("imported", isDirectory: true))
        let result = try importImages(from: exported, store: importedStore)
        XCTAssertEqual(result.imageCount, 1, "readable contained export imported zero images")
        XCTAssertEqual(result.skippedImage, 0)
        let imported = try XCTUnwrap(result.groups.flatMap(\.snippets).first { $0.triggerKeyword == ":logo" })
        XCTAssertEqual(try Data(contentsOf: importedStore.url(forImagePath: imported.imagePath)), png)
    }

    func testMissingAndAbsoluteImagesDoNotFallBackToSnippetImagePath() throws {
        let root = try makeTempDir("missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        try FileManager.default.createDirectory(at: imageStore.imagesDirectory, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.png")
        let secret = try makePNGData(seed: 21)
        try secret.write(to: outside, options: .atomic)
        let cases = [
            ":missing", "no-such-\(UUID().uuidString).png",
            ":absolute", outside.path,
            ":storeabs", imageStore.imagesDirectory.appendingPathComponent("missing.png").path,
            ":nilstore", "attachment-\(UUID().uuidString).png",
        ]
        for index in stride(from: 0, to: cases.count, by: 2) {
            let trigger = cases[index]
            let imagePath = cases[index + 1]
            let useStore: ImageAttachmentStore? = trigger == ":nilstore" ? nil : imageStore
            XCTAssertThrowsError(
                try SnippetExporter.espansoYAML(
                    from: [SnippetGroup(name: "Closed", snippets: [snippet(trigger: trigger, imagePath: imagePath)])],
                    options: options(useStore)
                ),
                "\(trigger) published an image_path"
            ) { error in
                guard case SnippetExporter.ExportError.imageUnavailable = error else {
                    return XCTFail("\(trigger): \(error)")
                }
                let rendered = String(describing: error) + ((error as? LocalizedError)?.errorDescription ?? "")
                XCTAssertFalse(rendered.contains(outside.path), "\(trigger) leaked the outside path")
                XCTAssertFalse(rendered.contains(imageStore.imagesDirectory.path), "\(trigger) leaked the store path")
                XCTAssertFalse(rendered.contains(imagePath), "\(trigger) fell back to snippet.imagePath")
            }
            XCTAssertThrowsError(
                try SnippetExporter.espansoDirectoryDocument(
                    from: [SnippetGroup(name: "Closed", snippets: [snippet(trigger: trigger, imagePath: imagePath)])],
                    options: options(useStore)
                )
            )
        }
    }

    func testSameSanitizedTruncatedNamesDoNotClobber() throws {
        let root = try makeTempDir("truncate")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        try FileManager.default.createDirectory(at: imageStore.imagesDirectory, withIntermediateDirectories: true)
        let first = try makePNGData(seed: 31)
        let second = try makePNGData(seed: 32)
        XCTAssertNotEqual(first, second)
        let stem = String(repeating: "a", count: 200)
        let firstName = stem + ".png"
        let secondName = stem + "ZZ.png"
        XCTAssertLessThanOrEqual(firstName.count, 255)
        try first.write(to: imageStore.imagesDirectory.appendingPathComponent(firstName), options: .atomic)
        try second.write(to: imageStore.imagesDirectory.appendingPathComponent(secondName), options: .atomic)

        let group = SnippetGroup(name: "Pics", snippets: [
            snippet(trigger: ":one", imagePath: firstName),
            snippet(trigger: ":two", imagePath: secondName),
        ])
        let document = try SnippetExporter.espansoDirectoryDocument(from: [group], options: options(imageStore))
        XCTAssertEqual(document.images.count, 2, "truncated names clobbered each other")
        XCTAssertNotEqual(document.images[0].relativePath, document.images[1].relativePath)
        XCTAssertEqual(document.images.map(\.data), [first, second])
        for image in document.images { assertPublishedPath(image.relativePath) }

        let exported = root.appendingPathComponent("match", isDirectory: true)
        try FileManager.default.createDirectory(at: exported, withIntermediateDirectories: true)
        try materialize(document, in: exported)
        let onDisk = try FileManager.default.contentsOfDirectory(
            at: exported.appendingPathComponent("images"),
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]
        )
        XCTAssertEqual(onDisk.count, 2)
        let importedStore = ImageAttachmentStore(directory: root.appendingPathComponent("imported", isDirectory: true))
        let result = try importImages(from: exported, store: importedStore)
        XCTAssertEqual(result.imageCount, 2)
        let byTrigger = Dictionary(uniqueKeysWithValues: result.groups.flatMap(\.snippets).map { ($0.triggerKeyword, $0) })
        XCTAssertEqual(try Data(contentsOf: importedStore.url(forImagePath: try XCTUnwrap(byTrigger[":one"]).imagePath)), first)
        XCTAssertEqual(try Data(contentsOf: importedStore.url(forImagePath: try XCTUnwrap(byTrigger[":two"]).imagePath)), second)
    }

    func testHostileStoredNamesNeverPublishDotDotOrAbsolutePaths() throws {
        let root = try makeTempDir("names")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        let png = try makePNGData(seed: 41)
        let images = imageStore.imagesDirectory
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside-secret.png")
        let secret = try makePNGData(seed: 99)
        try secret.write(to: outside, options: .atomic)

        let nested = images.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try png.write(to: nested.appendingPathComponent("slash.png"), options: .atomic)
        try png.write(to: images.appendingPathComponent("CON.png"), options: .atomic)
        try png.write(to: images.appendingPathComponent("..png"), options: .atomic)
        try png.write(to: images.appendingPathComponent("foo..bar.png"), options: .atomic)
        try png.write(to: images.appendingPathComponent("CON"), options: .atomic)
        let newlineName = "foo\nbar.png"
        try png.write(to: images.appendingPathComponent(newlineName), options: .atomic)
        let longName = String(repeating: "c", count: 300) + ".png"
        // APFS NAME_MAX is 255. A 300-character component cannot exist; the exporter
        // still must not turn that stored string into `..` or an absolute path.
        let longFileExists: Bool
        do {
            try png.write(to: images.appendingPathComponent(longName), options: .atomic)
            longFileExists = true
        } catch {
            longFileExists = false
        }
        let lookalikeName = "\u{FF0E}\u{FF0E}\u{FF0F}secret.png"
        try png.write(to: images.appendingPathComponent(lookalikeName), options: .atomic)

        let hostile: [(String, String, Bool)] = [
            (":dot", "..", false),
            (":dotonly", ".", false),
            (":empty", "", false),
            (":con", "CON", false),
            (":conpng", "CON.png", true),
            (":dotpng", "..png", true),
            (":foodot", "foo..bar.png", true),
            (":newline", newlineName, true),
            (":slash", "nested/slash.png", true),
            (":long", longName, longFileExists),
            (":look", lookalikeName, true),
            (":uni", "\u{FF0E}\u{FF0E}/\u{FF0E}\u{FF0E}/secret.png", false),
        ]
        for (trigger, imagePath, readable) in hostile {
            let group = SnippetGroup(name: "Names", snippets: [snippet(trigger: trigger, imagePath: imagePath)])
            do {
                let document = try SnippetExporter.espansoDirectoryDocument(from: [group], options: options(imageStore))
                for file in document.files {
                    assertYAMLDoesNotLeak(file.contents, forbidden: [outside.path, images.path, imagePath.contains("..") ? imagePath : ""])
                }
                for image in document.images {
                    assertPublishedPath(image.relativePath)
                    XCTAssertNotEqual(image.data, secret, "\(trigger) published bytes from outside the store")
                    if readable {
                        XCTAssertEqual(image.data, png, "\(trigger) did not copy the contained image")
                    }
                }
                if readable {
                    XCTAssertEqual(document.images.count, 1, "\(trigger) dropped a readable contained image")
                    let exported = root.appendingPathComponent("out-\(trigger.dropFirst())", isDirectory: true)
                    try FileManager.default.createDirectory(at: exported, withIntermediateDirectories: true)
                    try materialize(document, in: exported)
                    let importedStore = ImageAttachmentStore(directory: root.appendingPathComponent("imp-\(trigger.dropFirst())", isDirectory: true))
                    let result = try importImages(from: exported, store: importedStore)
                    XCTAssertEqual(result.imageCount, 1, "\(trigger) export imported zero images")
                    let imported = try XCTUnwrap(result.groups.flatMap(\.snippets).first)
                    XCTAssertEqual(try Data(contentsOf: importedStore.url(forImagePath: imported.imagePath)), png)
                    let payloads = try storedPayloads(importedStore)
                    XCTAssertFalse(payloads.contains(secret))
                }
            } catch {
                guard case SnippetExporter.ExportError.imageUnavailable = error else {
                    return XCTFail("\(trigger): \(error)")
                }
                let rendered = String(describing: error) + ((error as? LocalizedError)?.errorDescription ?? "")
                XCTAssertFalse(rendered.contains(outside.path), "\(trigger) leaked the outside path")
                XCTAssertFalse(rendered.contains(images.path), "\(trigger) leaked the store path")
                if imagePath.hasPrefix("/") || imagePath.contains("..") || imagePath.contains("\\") || imagePath.contains("\n") {
                    XCTAssertFalse(rendered.contains(imagePath), "\(trigger) echoed the unsafe imagePath")
                }
            }
        }
    }

    func testSymlinkInsideStoreIsCopiedOrRefusedWithoutEscape() throws {
        let root = try makeTempDir("inlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let imageStore = store(in: root)
        let images = imageStore.imagesDirectory
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let png = try makePNGData(seed: 51)
        let secret = try makePNGData(seed: 52)
        XCTAssertNotEqual(png, secret)
        let outside = root.appendingPathComponent("outside.png")
        try secret.write(to: outside, options: .atomic)
        try png.write(to: images.appendingPathComponent("real.png"), options: .atomic)
        let sub = images.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: sub.appendingPathComponent("link.png").path,
            withDestinationPath: "../real.png"
        )
        try FileManager.default.createSymbolicLink(
            atPath: images.appendingPathComponent("loop-a.png").path,
            withDestinationPath: "loop-b.png"
        )
        try FileManager.default.createSymbolicLink(
            atPath: images.appendingPathComponent("loop-b.png").path,
            withDestinationPath: "loop-a.png"
        )
        try FileManager.default.createSymbolicLink(
            atPath: images.appendingPathComponent("escape.png").path,
            withDestinationPath: outside.path
        )

        let group = SnippetGroup(name: "Links", snippets: [
            snippet(trigger: ":inside", imagePath: "sub/link.png"),
        ])
        do {
            let document = try SnippetExporter.espansoDirectoryDocument(from: [group], options: options(imageStore))
            XCTAssertEqual(document.images.count, 1)
            XCTAssertEqual(document.images.first?.data, png)
            let path = try XCTUnwrap(document.images.first?.relativePath)
            assertPublishedPath(path)
            for file in document.files {
                assertYAMLDoesNotLeak(file.contents, forbidden: [outside.path, images.path])
            }
            let exported = root.appendingPathComponent("match", isDirectory: true)
            try FileManager.default.createDirectory(at: exported, withIntermediateDirectories: true)
            try materialize(document, in: exported)
            let importedStore = ImageAttachmentStore(directory: root.appendingPathComponent("imported", isDirectory: true))
            let result = try importImages(from: exported, store: importedStore)
            XCTAssertEqual(result.imageCount, 1, "inside symlink export imported zero images")
            let imported = try XCTUnwrap(result.groups.flatMap(\.snippets).first)
            XCTAssertEqual(try Data(contentsOf: importedStore.url(forImagePath: imported.imagePath)), png)
            XCTAssertFalse(try storedPayloads(importedStore).contains(secret))
        } catch {
            guard case SnippetExporter.ExportError.imageUnavailable = error else {
                return XCTFail("inside symlink: \(error)")
            }
        }

        for trigger in [":escape", ":loop"] {
            let imagePath = trigger == ":escape" ? "escape.png" : "loop-a.png"
            XCTAssertThrowsError(
                try SnippetExporter.espansoDirectoryDocument(
                    from: [SnippetGroup(name: "Links", snippets: [snippet(trigger: trigger, imagePath: imagePath)])],
                    options: options(imageStore)
                ),
                "\(trigger) must not publish"
            ) { error in
                guard case SnippetExporter.ExportError.imageUnavailable = error else {
                    return XCTFail("\(trigger): \(error)")
                }
                let rendered = String(describing: error) + ((error as? LocalizedError)?.errorDescription ?? "")
                XCTAssertFalse(rendered.contains(outside.path))
            }
        }
    }

    func testImportRejectsTraversalAbsoluteAndSymlinkEscapes() throws {
        let root = try makeTempDir("import")
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = try makePNGData(seed: 61)
        let local = try makePNGData(seed: 62)
        let insideBar = try makePNGData(seed: 63)
        XCTAssertNotEqual(secret, local)
        XCTAssertNotEqual(secret, insideBar)

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try secret.write(to: outside.appendingPathComponent("secret.png"), options: .atomic)
        try secret.write(to: outside.appendingPathComponent("x.png"), options: .atomic)
        try secret.write(to: outside.appendingPathComponent("bar.png"), options: .atomic)
        try secret.write(to: root.appendingPathComponent("x.png"), options: .atomic)

        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try local.write(to: config.appendingPathComponent("local.png"), options: .atomic)
        try insideBar.write(to: config.appendingPathComponent("bar.png"), options: .atomic)
        let foo = config.appendingPathComponent("images/foo", isDirectory: true)
        try FileManager.default.createDirectory(at: foo, withIntermediateDirectories: true)

        let secretURL = outside.appendingPathComponent("secret.png")
        let paths: [(String, String)] = [
            (":abs", secretURL.path),
            (":dot", ".."),
            (":dotslash", "../"),
            (":trav", "images/../../outside/secret.png"),
            (":etc", "images/../../../../../../outside/secret.png"),
            (":imagesdot", "images/.."),
            (":dotx", "./../x.png"),
            (":trail", "local.png/"),
            (":foobarb", "images/foo/../../bar.png"),
            (":fooslash", "images/foo/../../bar.png/"),
            (":deep", "images/foo/../../../outside/secret.png"),
            (":lookslash", "images\u{FF0E}\u{FF0E}\u{2215}..\u{2215}outside\u{2215}secret.png"),
            (":fullwidth", "\u{FF0E}\u{FF0E}/\u{FF0E}\u{FF0E}/outside/secret.png"),
            (":fullsep", "images\u{FF0F}..\u{FF0F}..\u{FF0F}outside\u{FF0F}secret.png"),
            (":win", "images\\..\\..\\outside\\secret.png"),
            (":leadslash", "\\" + "outside\\secret.png"),
            (":fileurl", "file://" + secretURL.path),
            (":pct", "..%2F..%2Foutside%2Fsecret.png"),
            (":local", "local.png"),
        ]
        var lines = ["matches:"]
        for (trigger, path) in paths {
            lines.append("  - trigger: \(yamlQuote(trigger))")
            lines.append("    image_path: \(yamlQuote(path))")
        }
        try lines.joined(separator: "\n").write(to: config.appendingPathComponent("img.yml"), atomically: true, encoding: .utf8)

        let store = ImageAttachmentStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let result = try EspansoImporter.importFrom(config, imageStore: store)
        let byTrigger = Dictionary(uniqueKeysWithValues: result.groups.flatMap(\.snippets).map { ($0.triggerKeyword, $0) })
        let forbidden = [
            ":abs", ":dot", ":dotslash", ":trav", ":etc", ":imagesdot", ":dotx", ":deep",
            ":lookslash", ":fullwidth", ":fullsep", ":win", ":leadslash", ":fileurl", ":pct",
        ]
        for trigger in forbidden {
            XCTAssertNil(byTrigger[trigger], "\(trigger) imported an escaped image")
        }
        let localSnippet = try XCTUnwrap(byTrigger[":local"])
        XCTAssertEqual(try Data(contentsOf: store.url(forImagePath: localSnippet.imagePath)), local)
        if let bar = byTrigger[":foobarb"] {
            XCTAssertEqual(try Data(contentsOf: store.url(forImagePath: bar.imagePath)), insideBar)
        }
        if let slashed = byTrigger[":fooslash"] {
            XCTAssertEqual(try Data(contentsOf: store.url(forImagePath: slashed.imagePath)), insideBar)
        }
        if let trailed = byTrigger[":trail"] {
            XCTAssertEqual(try Data(contentsOf: store.url(forImagePath: trailed.imagePath)), local)
        }
        let payloads = try storedPayloads(store)
        XCTAssertFalse(payloads.contains(secret), "import stored the outside image: \(payloads.count) files")
        XCTAssertGreaterThanOrEqual(result.skippedImage, forbidden.count)

        try assertSymlinkImportDoesNotReadOutside(root: root, secret: secret, secretURL: secretURL)
        try assertNullByteImagePathDoesNotReadOutside(root: root, secret: secret, secretURL: secretURL)
    }

    private func assertSymlinkImportDoesNotReadOutside(root: URL, secret: Data, secretURL: URL) throws {
        let config = root.appendingPathComponent("linkconfig", isDirectory: true)
        let images = config.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: images.appendingPathComponent("link.png").path,
            withDestinationPath: secretURL.path
        )
        let linkedDir = root.appendingPathComponent("linked-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: config.appendingPathComponent("via").path,
            withDestinationPath: linkedDir.path
        )
        try secret.write(to: linkedDir.appendingPathComponent("secret.png"), options: .atomic)
        try """
        matches:
          - trigger: ":link"
            image_path: "images/link.png"
          - trigger: ":dirlink"
            image_path: "via/secret.png"
        """.write(to: config.appendingPathComponent("img.yml"), atomically: true, encoding: .utf8)

        let store = ImageAttachmentStore(directory: root.appendingPathComponent("linkstore", isDirectory: true))
        let result = try EspansoImporter.importFrom(config, imageStore: store)
        XCTAssertEqual(result.imageCount, 0, "symlink image_path was imported")
        XCTAssertEqual(result.skippedImage, 2)
        XCTAssertTrue(result.groups.flatMap(\.snippets).isEmpty)
        XCTAssertFalse(try storedPayloads(store).contains(secret))
    }

    private func assertNullByteImagePathDoesNotReadOutside(root: URL, secret: Data, secretURL: URL) throws {
        let config = root.appendingPathComponent("nulconfig", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let local = try makePNGData(seed: 64)
        try local.write(to: config.appendingPathComponent("local.png"), options: .atomic)
        var yaml = "matches:\n  - trigger: \":nul\"\n    image_path: \"local.png\u{0}/../../outside/secret.png\"\n"
        yaml = yaml.replacingOccurrences(of: "outside/secret.png", with: secretURL.path)
        try Data(yaml.utf8).write(to: config.appendingPathComponent("img.yml"), options: .atomic)
        let store = ImageAttachmentStore(directory: root.appendingPathComponent("nulstore", isDirectory: true))
        do {
            let result = try EspansoImporter.importFrom(config, imageStore: store)
            XCTAssertFalse(try storedPayloads(store).contains(secret), "nul image_path read outside bytes")
            XCTAssertEqual(result.imageCount, 0)
        } catch {
            XCTAssertFalse(try storedPayloads(store).contains(secret))
        }
    }
}
