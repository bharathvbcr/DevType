import XCTest
@testable import ExpanderEngine

// Import-confinement hardening. An untrusted Espanso config must not be able to
// make the importer read arbitrary user-readable files — neither through
// `imports:` targets nor through `image_path` payloads. Relative references
// inside the importing file's directory keep working exactly as before;
// absolute targets and `..` escapes are refused (and reported), and one
// malformed imported file must not abort the whole batch.

final class EspansoImportContainmentTests: XCTestCase {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devtype-contain-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Mirrors the real-PNG helper in `ImageSnippetTests` so refusals cannot be
    /// explained away as "the payload was not an image anyway".
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

    // MARK: - `imports:` confinement

    /// Absolute and `..`-escaping `imports:` targets must never be read, even
    /// when they exist on disk. This is the arbitrary-file-read hole: an
    /// untrusted package used to lift any `.yml` the user could read.
    func testImportsOutsideConfigDirectoryAreNotFollowed() throws {
        let root = try makeTempDir("imports")
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try """
        matches:
          - trigger: ":exfiltrated"
            replace: "top secret"
        """.write(to: outside.appendingPathComponent("victim.yml"), atomically: true, encoding: .utf8)

        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        imports:
          - "\(outside.appendingPathComponent("victim.yml").path)"
          - "../outside/victim.yml"
          - "_notes.txt"
        matches:
          - trigger: ":main"
            replace: "M"
        """.write(to: config.appendingPathComponent("main.yml"), atomically: true, encoding: .utf8)
        try """
        matches:
          - trigger: ":good"
            replace: "G"
        """.write(to: config.appendingPathComponent("good.yml"), atomically: true, encoding: .utf8)

        let result = try EspansoImporter.importFrom(config)
        let triggers = Set(result.groups.flatMap(\.snippets).map(\.triggerKeyword))

        XCTAssertEqual(triggers, [":main", ":good"], "nothing outside the config may be read")
        XCTAssertEqual(result.skippedUnsafeImports, 3,
                       "absolute, `..`-escaping and non-YAML targets must each be counted")
    }

    /// The relative-import behavior the fixtures depend on must stay identical.
    func testRelativeImportsStillResolve() throws {
        let root = try makeTempDir("relimports")
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        imports:
          - "./_helper.yml"
          - "nested/deep.yml"
        matches:
          - trigger: ":main"
            replace: "M"
        """.write(to: root.appendingPathComponent("main.yml"), atomically: true, encoding: .utf8)
        try """
        matches:
          - trigger: ":helper"
            replace: "H"
        """.write(to: root.appendingPathComponent("_helper.yml"), atomically: true, encoding: .utf8)
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try """
        matches:
          - trigger: ":deep"
            replace: "D"
        """.write(to: nested.appendingPathComponent("deep.yml"), atomically: true, encoding: .utf8)

        let result = try EspansoImporter.importFrom(root.appendingPathComponent("main.yml"))
        let triggers = Set(result.groups.flatMap(\.snippets).map(\.triggerKeyword))
        XCTAssertEqual(triggers, [":main", ":helper", ":deep"])
    }

    // MARK: - `image_path` confinement

    /// An absolute `image_path` pointing at a **real image** outside the config
    /// used to be copied into the attachment store — the exfiltration primitive.
    func testAbsoluteImagePathOutsideConfigIsNotCopied() throws {
        let root = try makeTempDir("imgabs")
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let leakedPNG = outside.appendingPathComponent("leak.png")
        try makePNGData().write(to: leakedPNG)

        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try """
        matches:
          - trigger: ":steal"
            image_path: "\(leakedPNG.path)"
        """.write(to: config.appendingPathComponent("img.yml"), atomically: true, encoding: .utf8)

        let storeDir = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = ImageAttachmentStore(directory: storeDir)

        let result = try EspansoImporter.importFrom(config, imageStore: store)

        XCTAssertEqual(result.imageCount, 0, "an absolute image_path must not be copied")
        XCTAssertEqual(result.skippedImage, 1, "the refusal must surface through the usual skip counter")
        XCTAssertTrue(result.groups.flatMap(\.snippets).isEmpty)
        let copied = try FileManager.default.contentsOfDirectory(atPath: storeDir.path)
        XCTAssertTrue(copied.isEmpty, "nothing may land in the attachment store: \(copied)")
    }

    /// Same hole via relative traversal: `../` past the importing file's
    /// directory must be refused while plain relative names keep working.
    func testDotDotImagePathEscapeIsRejectedButPlainRelativeStillWorks() throws {
        let root = try makeTempDir("imgdotdot")
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try makePNGData().write(to: outside.appendingPathComponent("escape.png"))

        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try makePNGData().write(to: config.appendingPathComponent("local.png"))
        try """
        matches:
          - trigger: ":escape"
            image_path: "../outside/escape.png"
          - trigger: ":local"
            image_path: "local.png"
        """.write(to: config.appendingPathComponent("img.yml"), atomically: true, encoding: .utf8)

        let storeDir = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = ImageAttachmentStore(directory: storeDir)

        let result = try EspansoImporter.importFrom(config, imageStore: store)

        let byTrigger = Dictionary(uniqueKeysWithValues:
            result.groups.flatMap(\.snippets).map { ($0.triggerKeyword, $0) })
        XCTAssertNil(byTrigger[":escape"], "a `..` escape must not be copied")
        XCTAssertNotNil(try XCTUnwrap(byTrigger[":local"]), "plain relative image_path keeps working")
        XCTAssertEqual(result.imageCount, 1)
        XCTAssertEqual(result.skippedImage, 1)
    }

    // MARK: - Per-file parse resilience

    /// One malformed file reached via `imports:` used to abort the entire
    /// import; its siblings must survive and the failure must be reported.
    func testMalformedImportedFileDoesNotAbortBatch() throws {
        let dir = try makeTempDir("parsefail")
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
        imports:
          - "./bad.yml"
          - "./good.yml"
        matches:
          - trigger: ":base"
            replace: "B"
        """.write(to: dir.appendingPathComponent("base.yml"), atomically: true, encoding: .utf8)
        try "matches: [unclosed\n".write(to: dir.appendingPathComponent("bad.yml"), atomically: true, encoding: .utf8)
        try """
        matches:
          - trigger: ":good"
            replace: "G"
        """.write(to: dir.appendingPathComponent("good.yml"), atomically: true, encoding: .utf8)

        let result = try EspansoImporter.importFrom(dir.appendingPathComponent("base.yml"))
        let triggers = Set(result.groups.flatMap(\.snippets).map(\.triggerKeyword))

        XCTAssertEqual(triggers, [":base", ":good"], "siblings of the malformed file must survive")
        XCTAssertEqual(result.skippedParseFailed, 1,
                       "the parse failure must be reported through the skip counter")
        XCTAssertEqual(result.totalSkipped, 1)
    }

    /// The resilience above is scoped to `imports:` siblings — a broken
    /// top-level entry file must keep failing the import loudly.
    func testTopLevelEntryFileParseFailureStillThrows() throws {
        let dir = try makeTempDir("topfail")
        defer { try? FileManager.default.removeItem(at: dir) }

        try "matches: [unclosed\n".write(to: dir.appendingPathComponent("broken.yml"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try EspansoImporter.importFrom(dir.appendingPathComponent("broken.yml")))
    }
}
