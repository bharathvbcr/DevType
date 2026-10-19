import SourceTreeTestSupport
import XCTest

/// The reader every source contract goes through: a type's family is `Type.swift` plus its
/// `Type+*.swift` siblings, and nothing else.
final class SourceTreeTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceTreeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("Sources/Mod"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(
            to: base.appendingPathComponent("Sources/Mod/\(name)"), atomically: true, encoding: .utf8)
    }

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    func testPrimaryOnlyIsReadAlone() throws {
        try write("Thing.swift", "primary")
        let files = try SourceTree.files("Sources/Mod/Thing.swift", in: base)
        XCTAssertEqual(names(files), ["Thing.swift"])
        XCTAssertEqual(try SourceTree.text("Sources/Mod/Thing.swift", in: base), "primary")
    }

    func testSiblingsFollowThePrimaryInNameOrder() throws {
        try write("Thing.swift", "P")
        try write("Thing+Zeta.swift", "Z")
        try write("Thing+Alpha.swift", "A")
        let files = try SourceTree.files("Sources/Mod/Thing.swift", in: base)
        XCTAssertEqual(names(files), ["Thing.swift", "Thing+Alpha.swift", "Thing+Zeta.swift"])
        XCTAssertEqual(try SourceTree.text("Sources/Mod/Thing.swift", in: base), "P\nA\nZ")
    }

    func testAPrefixWithoutAPlusIsADifferentType() throws {
        try write("Thing.swift", "P")
        try write("Thing+Role.swift", "R")
        try write("ThingOther.swift", "OTHER")
        try write("Other+Thing.swift", "OTHER2")
        let text = try SourceTree.text("Sources/Mod/Thing.swift", in: base)
        XCTAssertEqual(text, "P\nR")
        XCTAssertFalse(text.contains("OTHER"))
    }

    func testAMissingPrimaryThrowsEvenWhenSiblingsExist() throws {
        try write("Thing+Role.swift", "R")
        XCTAssertThrowsError(try SourceTree.files("Sources/Mod/Thing.swift", in: base)) { error in
            XCTAssertTrue(error is SourceTree.MissingSourceError)
        }
        XCTAssertThrowsError(try SourceTree.text("Sources/Mod/Thing.swift", in: base))
    }

    func testAHitInASiblingIsAttributedToItsPrimary() throws {
        try write("Thing.swift", "P")
        try write("Thing+Role.swift", "R")
        try write("NSView+Helper.swift", "H")
        XCTAssertEqual(SourceTree.familyPrimary(of: "Sources/Mod/Thing+Role.swift", in: base), "Sources/Mod/Thing.swift")
        XCTAssertEqual(SourceTree.familyPrimary(of: "Sources/Mod/Thing.swift", in: base), "Sources/Mod/Thing.swift")
        // No `NSView.swift` here: an extension of a type declared elsewhere owns itself.
        XCTAssertEqual(SourceTree.familyPrimary(of: "Sources/Mod/NSView+Helper.swift", in: base), "Sources/Mod/NSView+Helper.swift")
    }

    func testTheRepositoryRootIsTheCheckoutThatHoldsThisReader() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: SourceTree.root.appendingPathComponent("Package.swift").path))
    }
}
