import AppKit
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// Directory export is synchronous: `writeEspansoDirectory` returns only after staging
/// is moved into place or removed. There is no cancellation wait around the replace.
final class EspansoImageDirectoryAttackTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-espanso-dir-attack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
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

    private func imagePaths(in yaml: String) -> [String] {
        yaml.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("image_path:") else { return nil }
            return String(trimmed.dropFirst("image_path:".count).trimmingCharacters(in: .whitespaces))
        }
    }

    private func assertNoStaging() throws {
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("devtype-export") }
        XCTAssertTrue(leftovers.isEmpty, "staging directory leaked: \(leftovers)")
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [:] }
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = url.path.replacingOccurrences(of: directory.path, with: "")
            files[relative] = try Data(contentsOf: url)
        }
        return files
    }

    func testDirectoryExportRoundTripsDistinctBytesAndReplacesOnlyWhenComplete() throws {
        let images = root.appendingPathComponent("Images", isDirectory: true)
        let imageStore = ImageAttachmentStore(directory: images)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let first = try makePNGData(seed: 3)
        let second = try makePNGData(seed: 4)
        try first.write(to: images.appendingPathComponent("photo.png"), options: .atomic)
        try second.write(to: images.appendingPathComponent("photo!.png"), options: .atomic)
        let group = SnippetGroup(name: "Pics", snippets: [
            SnippetModel(title: ":one", triggerKeyword: ":one", replacementText: "", imagePath: "photo.png"),
            SnippetModel(title: ":two", triggerKeyword: ":two", replacementText: "", imagePath: "photo!.png"),
        ])
        let target = root.appendingPathComponent("match", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: target.appendingPathComponent("stale.txt"))

        try LibraryExporter.writeEspansoDirectory(
            groups: [group],
            to: target,
            options: SnippetExporter.Options(imageStore: imageStore)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("stale.txt").path))
        let yamlURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).first { $0.pathExtension == "yml" }
        )
        let yaml = try String(contentsOf: yamlURL, encoding: .utf8)
        let paths = imagePaths(in: yaml)
        XCTAssertEqual(paths.count, 2)
        XCTAssertNotEqual(paths[0], paths[1])
        for path in paths {
            XCTAssertFalse(path.hasPrefix("/"))
            XCTAssertFalse(path.contains(".."))
            XCTAssertFalse(path.contains("\\"))
            XCTAssertTrue(path.hasPrefix("images/"))
        }
        XCTAssertFalse(yaml.contains(images.path))
        let imageDir = target.appendingPathComponent("images", isDirectory: true)
        let written = try FileManager.default.contentsOfDirectory(at: imageDir, includingPropertiesForKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(written.count, 2)
        var bytes: [Data] = []
        for url in written {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            XCTAssertNotEqual(values.isSymbolicLink, true)
            XCTAssertEqual(values.isRegularFile, true)
            bytes.append(try Data(contentsOf: url))
        }
        XCTAssertTrue(bytes.contains(first))
        XCTAssertTrue(bytes.contains(second))
        try assertNoStaging()

        let importedStore = ImageAttachmentStore(directory: root.appendingPathComponent("imported", isDirectory: true))
        let result = try EspansoImporter.importFrom(target, imageStore: importedStore)
        XCTAssertEqual(result.imageCount, 2, "directory export imported zero images")
        let byTrigger = Dictionary(uniqueKeysWithValues: result.groups.flatMap(\.snippets).map { ($0.triggerKeyword, $0) })
        XCTAssertEqual(try Data(contentsOf: importedStore.url(forImagePath: try XCTUnwrap(byTrigger[":one"]).imagePath)), first)
        XCTAssertEqual(try Data(contentsOf: importedStore.url(forImagePath: try XCTUnwrap(byTrigger[":two"]).imagePath)), second)
    }

    func testUnreadableImageLeavesExistingDestinationAndRemovesStaging() throws {
        let images = root.appendingPathComponent("Images", isDirectory: true)
        let imageStore = ImageAttachmentStore(directory: images)
        let readable = try makePNGData(seed: 5)
        let blocked = try makePNGData(seed: 6)
        let storedReadable = try imageStore.save(data: readable, preferredExtension: "png")
        let storedBlocked = try imageStore.save(data: blocked, preferredExtension: "png")
        let blockedURL = imageStore.url(forImagePath: storedBlocked)
        XCTAssertTrue(blockedURL.path.hasPrefix(root.path), "refusing to chmod outside the temp dir")
        let originalMode = try FileManager.default.attributesOfItem(atPath: blockedURL.path)[.posixPermissions] as? NSNumber
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0)], ofItemAtPath: blockedURL.path)
        defer {
            if let originalMode {
                try? FileManager.default.setAttributes([.posixPermissions: originalMode], ofItemAtPath: blockedURL.path)
            } else {
                try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: blockedURL.path)
            }
        }
        do {
            _ = try Data(contentsOf: blockedURL)
            XCTFail("mode 000 did not make the temp image unreadable; the attack was not exercised")
            return
        } catch {
            // The owner cannot read the temp file. Export must fail closed.
        }

        let target = root.appendingPathComponent("match", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("sentinel.txt")
        try Data("keep".utf8).write(to: sentinel)
        let before = try snapshot(target)
        let group = SnippetGroup(name: "Pics", snippets: [
            SnippetModel(title: ":ok", triggerKeyword: ":ok", replacementText: "", imagePath: storedReadable),
            SnippetModel(title: ":blocked", triggerKeyword: ":blocked", replacementText: "", imagePath: storedBlocked),
        ])

        XCTAssertThrowsError(try LibraryExporter.writeEspansoDirectory(
            groups: [group],
            to: target,
            options: SnippetExporter.Options(imageStore: imageStore)
        )) { error in
            guard case SnippetExporter.ExportError.imageUnavailable(let trigger) = error else {
                return XCTFail("expected imageUnavailable, got \(error)")
            }
            XCTAssertEqual(trigger, ":blocked")
            let rendered = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertFalse(rendered.contains(blockedURL.path))
            XCTAssertFalse(rendered.contains(root.path))
        }
        XCTAssertEqual(try snapshot(target), before)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("images").path))
        try assertNoStaging()
    }

    func testMissingImageDoesNotCreateOrModifyDestination() throws {
        let images = root.appendingPathComponent("Images", isDirectory: true)
        let imageStore = ImageAttachmentStore(directory: images)
        let png = try makePNGData(seed: 7)
        let stored = try imageStore.save(data: png, preferredExtension: "png")
        let group = SnippetGroup(name: "Pics", snippets: [
            SnippetModel(title: ":ok", triggerKeyword: ":ok", replacementText: "", imagePath: stored),
            SnippetModel(title: ":gone", triggerKeyword: ":gone", replacementText: "", imagePath: "missing-\(UUID().uuidString).png"),
        ])

        let fresh = root.appendingPathComponent("fresh-match", isDirectory: true)
        XCTAssertThrowsError(try LibraryExporter.writeEspansoDirectory(
            groups: [group],
            to: fresh,
            options: SnippetExporter.Options(imageStore: imageStore)
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "failed export created the destination")
        try assertNoStaging()

        let target = root.appendingPathComponent("match", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("sentinel.txt"))
        let before = try snapshot(target)
        XCTAssertThrowsError(try LibraryExporter.writeEspansoDirectory(
            groups: [group],
            to: target,
            options: SnippetExporter.Options(imageStore: imageStore)
        ))
        XCTAssertEqual(try snapshot(target), before)
        try assertNoStaging()
    }

    func testOutsideSymlinkRefusesAndLeavesDestinationUntouched() throws {
        let images = root.appendingPathComponent("Images", isDirectory: true)
        let imageStore = ImageAttachmentStore(directory: images)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let secret = try makePNGData(seed: 8)
        let outside = root.appendingPathComponent("outside.png")
        try secret.write(to: outside, options: .atomic)
        try FileManager.default.createSymbolicLink(
            atPath: images.appendingPathComponent("link.png").path,
            withDestinationPath: outside.path
        )
        let inside = try makePNGData(seed: 9)
        try inside.write(to: images.appendingPathComponent("real.png"), options: .atomic)
        let sub = images.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: sub.appendingPathComponent("in.png").path,
            withDestinationPath: "../real.png"
        )

        let target = root.appendingPathComponent("match", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("sentinel.txt"))
        let before = try snapshot(target)
        XCTAssertThrowsError(try LibraryExporter.writeEspansoDirectory(
            groups: [SnippetGroup(name: "Links", snippets: [
                SnippetModel(title: ":link", triggerKeyword: ":link", replacementText: "", imagePath: "link.png"),
            ])],
            to: target,
            options: SnippetExporter.Options(imageStore: imageStore)
        ))
        XCTAssertEqual(try snapshot(target), before)
        XCTAssertEqual(try Data(contentsOf: outside), secret)
        try assertNoStaging()

        let insideTarget = root.appendingPathComponent("inside-match", isDirectory: true)
        do {
            try LibraryExporter.writeEspansoDirectory(
                groups: [SnippetGroup(name: "Links", snippets: [
                    SnippetModel(title: ":in", triggerKeyword: ":in", replacementText: "", imagePath: "sub/in.png"),
                ])],
                to: insideTarget,
                options: SnippetExporter.Options(imageStore: imageStore)
            )
            let yaml = try String(contentsOf: try XCTUnwrap(
                FileManager.default.contentsOfDirectory(at: insideTarget, includingPropertiesForKeys: nil).first { $0.pathExtension == "yml" }
            ), encoding: .utf8)
            for path in imagePaths(in: yaml) {
                XCTAssertFalse(path.hasPrefix("/"))
                XCTAssertFalse(path.contains(".."))
                XCTAssertFalse(path.contains("\\"))
            }
            XCTAssertFalse(yaml.contains(outside.path))
            let imageFiles = try FileManager.default.contentsOfDirectory(
                at: insideTarget.appendingPathComponent("images"),
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]
            )
            XCTAssertEqual(imageFiles.count, 1)
            let values = try imageFiles[0].resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            XCTAssertNotEqual(values.isSymbolicLink, true, "directory export wrote the symlink itself")
            XCTAssertEqual(try Data(contentsOf: imageFiles[0]), inside)
            let importedStore = ImageAttachmentStore(directory: root.appendingPathComponent("imported", isDirectory: true))
            let result = try EspansoImporter.importFrom(insideTarget, imageStore: importedStore)
            XCTAssertEqual(result.imageCount, 1, "inside symlink directory export imported zero images")
            let imported = try XCTUnwrap(result.groups.flatMap(\.snippets).first)
            XCTAssertEqual(try Data(contentsOf: importedStore.url(forImagePath: imported.imagePath)), inside)
            try assertNoStaging()
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: insideTarget.path))
            try assertNoStaging()
            guard case SnippetExporter.ExportError.imageUnavailable = error else {
                return XCTFail("inside symlink: \(error)")
            }
        }
    }
}
