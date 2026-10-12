import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

/// An export is a copy for sharing; it must never land on the live library file.
final class LibraryExportDestinationGuardTests: XCTestCase {
    private var root: URL!
    private var library: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("devtype-export-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        library = root.appendingPathComponent("snippets.json")
        try Data("library".utf8).write(to: library)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func export(to url: URL, choice: LibraryExporter.Choice = .json) throws {
        try LibraryExporter.write(
            choice: choice,
            groups: [SnippetGroup(name: "G", snippets: [SnippetModel(title: "t", triggerKeyword: "t", replacementText: "r")])],
            to: url,
            protecting: library
        )
    }

    private func assertRefused(_ url: URL, choice: LibraryExporter.Choice = .json, line: UInt = #line) {
        XCTAssertThrowsError(try export(to: url, choice: choice), line: line) {
            XCTAssertEqual($0 as? LibraryExporter.ExportError, .destinationIsActiveLibrary, line: line)
        }
        XCTAssertEqual(try? Data(contentsOf: library), Data("library".utf8), "the library was overwritten", line: line)
    }

    func testRefusesTheLibraryFileItself() { assertRefused(library) }

    func testRefusesANonStandardizedSpellingOfTheLibraryPath() {
        assertRefused(root.appendingPathComponent("sub/../snippets.json"))
    }

    func testRefusesASymlinkPointingAtTheLibrary() throws {
        let link = root.appendingPathComponent("shared-export.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library)
        assertRefused(link)
    }

    func testRefusesAFolderExportThatWouldReplaceTheFolderHoldingTheLibrary() {
        assertRefused(root, choice: .espansoDirectory)
    }

    func testAnUnrelatedDestinationStillWrites() throws {
        let other = root.appendingPathComponent("export.json")
        try export(to: other)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(try Data(contentsOf: library), Data("library".utf8))
    }
}
