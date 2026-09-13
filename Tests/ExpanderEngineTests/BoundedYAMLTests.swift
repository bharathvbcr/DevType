import XCTest
@testable import ExpanderEngine

/// Admission for untrusted YAML. Two of these inputs are things the generic `Yams.load` path
/// could not survive: a complex mapping key force-unwrapped the process out of existence
/// (`Yams/Constructor.swift:435`, verified against the pinned 5.4.0), and nested aliases
/// expanded multiplicatively because the byte budget upstream bounds the file rather than what
/// the file expands into. Both arrive before the user has confirmed anything.
final class BoundedYAMLTests: XCTestCase {

    private func load(_ yaml: String) throws -> [String: Any] {
        try BoundedYAML.loadDictionary(data: Data(yaml.utf8))
    }

    // MARK: - The shapes that used to be fatal

    /// Legal YAML, and the exact document that traps `Yams.load`. A thrown error is the whole
    /// point: there is no `catch` that would have saved the process before this.
    func testComplexMappingKeyThrowsInsteadOfTrapping() throws {
        let yaml = """
        ? [a, b]
        : value
        name: pack
        """

        XCTAssertThrowsError(try load(yaml)) { error in
            XCTAssertEqual(error as? BoundedYAML.Failure, .unsupportedKey)
        }
    }

    /// A mapping used as a key reaches the same force unwrap.
    func testMappingMappingKeyThrowsInsteadOfTrapping() throws {
        let yaml = """
        ? {a: 1}
        : value
        """

        XCTAssertThrowsError(try load(yaml)) { error in
            XCTAssertEqual(error as? BoundedYAML.Failure, .unsupportedKey)
        }
    }

    /// A complex key nested inside a value, rather than at the root, is the same trap one level
    /// down — the walk has to refuse it wherever it appears.
    func testNestedComplexKeyThrows() throws {
        let yaml = """
        matches:
          - trigger: ":hi"
            meta:
              ? [a, b]
              : value
        """

        XCTAssertThrowsError(try load(yaml)) { error in
            XCTAssertEqual(error as? BoundedYAML.Failure, .unsupportedKey)
        }
    }

    /// Six levels of ten-fold aliasing: ~300 bytes that ask for a million nodes. The file sails
    /// through every byte budget upstream because the file really is 300 bytes.
    func testAliasAmplificationIsRefused() throws {
        let yaml = """
        a: &a ["x","x","x","x","x","x","x","x","x","x"]
        b: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a,*a]
        c: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b,*b]
        d: &d [*c,*c,*c,*c,*c,*c,*c,*c,*c,*c]
        e: &e [*d,*d,*d,*d,*d,*d,*d,*d,*d,*d]
        f: [*e,*e,*e,*e,*e,*e,*e,*e,*e,*e]
        """
        XCTAssertLessThan(yaml.utf8.count, 400, "the point is that the source is tiny")

        let started = Date()
        XCTAssertThrowsError(try load(yaml)) { error in
            XCTAssertEqual(error as? BoundedYAML.Failure, .tooManyNodes)
        }
        // Refused by the budget rather than by finishing the expansion.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5.0)
    }

    /// A merge chain is the same amplifier wearing a different hat, so it is spent from the
    /// same budget.
    func testMergeChainAmplificationIsRefused() throws {
        var yaml = "base: &l0 {k: v}\n"
        for level in 1...16 {
            let previous = "*l\(level - 1)"
            yaml += "l\(level): &l\(level)\n"
            yaml += "  <<: [\(Array(repeating: previous, count: 4).joined(separator: ", "))]\n"
            yaml += "  k\(level): v\n"
        }
        yaml += "top:\n  <<: *l16\n"

        XCTAssertThrowsError(try load(yaml)) { error in
            XCTAssertEqual(error as? BoundedYAML.Failure, .tooManyNodes)
        }
    }

    func testDeepNestingIsRefused() throws {
        let depth = BoundedYAML.maximumDepth + 10
        let yaml = "root: " + String(repeating: "[", count: depth) + String(repeating: "]", count: depth)

        XCTAssertThrowsError(try load(yaml)) { error in
            XCTAssertEqual(error as? BoundedYAML.Failure, .tooDeep)
        }
    }

    // MARK: - What ordinary packs rely on, unchanged

    /// Scalar typing is still Yams'. The importer reads these back with `as? String`,
    /// `as? Bool` and `as? Int`, so a change here would quietly drop fields.
    func testScalarTypesMatchTheGenericLoader() throws {
        let dict = try load("""
        name: pack
        enabled: true
        count: 42
        ratio: 1.5
        nothing: ~
        quoted: "true"
        """)

        XCTAssertEqual(dict["name"] as? String, "pack")
        XCTAssertEqual(dict["enabled"] as? Bool, true)
        XCTAssertEqual(dict["count"] as? Int, 42)
        XCTAssertEqual(dict["ratio"] as? Double, 1.5)
        XCTAssertTrue(dict["nothing"] is NSNull)
        XCTAssertEqual(dict["quoted"] as? String, "true")
    }

    /// The shape the Espanso importer actually walks: `matches:` as an array of dictionaries.
    func testNestedMatchShapeCastsAsTheImporterExpects() throws {
        let dict = try load("""
        matches:
          - trigger: ":hello"
            replace: "Hello World"
            word: true
          - trigger: ":bye"
            replace: "Goodbye"
        """)

        let matches = try XCTUnwrap(dict["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0]["trigger"] as? String, ":hello")
        XCTAssertEqual(matches[0]["word"] as? Bool, true)
        XCTAssertEqual(matches[1]["replace"] as? String, "Goodbye")
    }

    /// Aliases within budget are a legitimate way to write a pack and still work.
    func testModestAliasesStillResolve() throws {
        let dict = try load("""
        common: &common "Best regards"
        matches:
          - trigger: ":sig"
            replace: *common
          - trigger: ":signature"
            replace: *common
        """)

        let matches = try XCTUnwrap(dict["matches"] as? [[String: Any]])
        XCTAssertEqual(matches[0]["replace"] as? String, "Best regards")
        XCTAssertEqual(matches[1]["replace"] as? String, "Best regards")
    }

    /// Merge keys keep working, and a key written in the mapping still beats the merged one.
    func testMergeKeysExpandAndLocalKeysWin() throws {
        let dict = try load("""
        defaults: &defaults
          word: true
          replace: "default"
        entry:
          <<: *defaults
          replace: "specific"
        """)

        let entry = try XCTUnwrap(dict["entry"] as? [String: Any])
        XCTAssertEqual(entry["word"] as? Bool, true, "merged key should survive")
        XCTAssertEqual(entry["replace"] as? String, "specific", "written key should win")
    }

    func testNonMappingRootYieldsEmptyDictionary() throws {
        XCTAssertTrue(try load("- a\n- b").isEmpty)
        XCTAssertTrue(try load("").isEmpty)
    }

    func testMalformedYAMLStillThrowsRatherThanReturningEmpty() {
        XCTAssertThrowsError(try load("a: [1, 2\nb: {"))
    }
}
