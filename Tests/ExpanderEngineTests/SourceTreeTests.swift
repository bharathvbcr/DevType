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

    func testATypeMovedToItsOwnFileIsReadOnlyWhenTheContractNamesIt() throws {
        try write("Thing.swift", "P")
        try write("Thing+Role.swift", "R")
        try write("ThingMode.swift", "MOVED")
        try write("ThingMode+Extra.swift", "MOVEDEXTRA")
        XCTAssertEqual(try SourceTree.text("Sources/Mod/Thing.swift", in: base), "P\nR")
        XCTAssertEqual(
            try SourceTree.text("Sources/Mod/Thing.swift", including: ["Sources/Mod/ThingMode.swift"], in: base),
            "P\nR\nMOVED\nMOVEDEXTRA"
        )
        XCTAssertThrowsError(
            try SourceTree.text("Sources/Mod/Thing.swift", including: ["Sources/Mod/Gone.swift"], in: base)
        ) { error in
            XCTAssertTrue(error is SourceTree.MissingSourceError)
        }
    }

    // MARK: - functionBody

    func testFunctionBodyReturnsTheDeclarationAndNothingAfterIt() throws {
        let text = """
        extension Thing {
            func first(_ x: Int) -> Int {
                if x > 0 { return 1 }
                return 0
            }

            func second() { call() }
        }
        """
        let body = try SourceTree.functionBody("func first(", in: text)
        XCTAssertEqual(body, """
        func first(_ x: Int) -> Int {
                if x > 0 { return 1 }
                return 0
            }
        """)
        XCTAssertFalse(body.contains("second"))
    }

    func testFunctionBodyMatchesAMemberWhateverItsAccessModifier() throws {
        // A split widens `private func` to internal; the anchor without a modifier finds both.
        XCTAssertEqual(try SourceTree.functionBody("func a(", in: "private func a() { x() }"), "func a() { x() }")
        XCTAssertEqual(try SourceTree.functionBody("func a(", in: "func a() { x() }"), "func a() { x() }")
    }

    func testFunctionBodyIgnoresBracesInStringsAndComments() throws {
        let text = ##"""
        func tricky(label: String = "}") {
            let a = "{{cursor}} }"
            let b = "interp \(dict["}"] ?? "{") end"
            let c = #"raw } \#(1) {"#
            let d = """
                multi } line {
                """
            // } line comment
            /* } /* nested { */ block } */
            run()
        }
        func after() { done() }
        """##
        let body = try SourceTree.functionBody("func tricky(", in: text)
        XCTAssertTrue(body.hasSuffix("run()\n}"), body)
        XCTAssertFalse(body.contains("func after"))
    }

    func testFunctionBodySkipsBracesInsideTheParameterList() throws {
        let text = "func f(handler: () -> Void = { work() }, other: Int) -> [String: Int] where T: P {\n    body()\n}\nfunc g() {}"
        let body = try SourceTree.functionBody("func f(", in: text)
        XCTAssertTrue(body.hasSuffix("body()\n}"), body)
    }

    func testFunctionBodyThrowsWhenTheSignatureIsMissingOrAmbiguous() {
        XCTAssertThrowsError(try SourceTree.functionBody("func nope(", in: "func a() {}")) { error in
            guard case SourceTree.FunctionBodyError.missing = error else { return XCTFail("\(error)") }
        }
        let twice = "func dup() { one() }\nextension X { func dup() { two() } }"
        XCTAssertThrowsError(try SourceTree.functionBody("func dup(", in: twice)) { error in
            guard case SourceTree.FunctionBodyError.ambiguous(_, let count) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(count, 2)
        }
    }

    func testFunctionBodyThrowsForABodylessOrUnbalancedDeclaration() {
        let requirement = "protocol P {\n    func need()\n}\nfunc other() { x() }"
        XCTAssertThrowsError(try SourceTree.functionBody("func need(", in: requirement)) { error in
            guard case SourceTree.FunctionBodyError.noBody = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try SourceTree.functionBody("func open(", in: "func open() {\n    if x {\n")) { error in
            guard case SourceTree.FunctionBodyError.unbalanced = error else { return XCTFail("\(error)") }
        }
    }

    func testFunctionBodyFindsAFunctionWhoseNeighbourLivesInAnotherFile() throws {
        // The shape a two-marker slice cannot survive: `later` sorts before `first` once a split
        // puts them in different extension files, so a slice from `first` to `later` is inverted.
        try write("Thing.swift", "final class Thing {}")
        try write("Thing+Alpha.swift", "extension Thing {\n    func later() { l() }\n}")
        try write("Thing+Beta.swift", "extension Thing {\n    func first() {\n        f()\n    }\n}")
        let text = try SourceTree.text("Sources/Mod/Thing.swift", in: base)
        let startOfFirst = try XCTUnwrap(text.range(of: "func first("))
        let startOfLater = try XCTUnwrap(text.range(of: "func later("))
        XCTAssertGreaterThan(startOfFirst.lowerBound, startOfLater.lowerBound, "the two-marker slice would be inverted")
        XCTAssertEqual(try SourceTree.functionBody("func first(", in: text), "func first() {\n        f()\n    }")
    }

    func testTheRepositoryRootIsTheCheckoutThatHoldsThisReader() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: SourceTree.root.appendingPathComponent("Package.swift").path))
    }
}
