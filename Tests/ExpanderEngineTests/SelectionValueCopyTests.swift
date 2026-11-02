import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// The value-slice rung may copy `kAXValue` only when `kAXNumberOfCharacters` is an `Int` at or
/// below `maxSliceableDocumentCharacters`. Attribute reads are supplied here; nothing in this
/// file calls Accessibility.
final class SelectionValueCopyTests: XCTestCase {
    private final class Reads {
        private(set) var attributes: [String] = []

        func append(_ attribute: String) {
            attributes.append(attribute)
        }

        var copiedValue: Bool {
            attributes.contains(kAXValueAttribute as String)
        }
    }

    private func slice(
        count: CFTypeRef?,
        value: CFTypeRef? = "abcdefghij" as NSString,
        range: CFRange = CFRange(location: 0, length: 4),
        reads: Reads
    ) -> String? {
        SelectionReader.copyValueSubstring(utf16Range: range) { attribute in
            reads.append(attribute)
            if attribute == (kAXNumberOfCharactersAttribute as String) {
                return count
            }
            if attribute == (kAXValueAttribute as String) {
                return value
            }
            XCTFail("unexpected attribute \(attribute)")
            return nil
        }
    }

    func testMissingCharacterCountDoesNotCopyTheWholeValue() {
        let reads = Reads()
        let sliced = slice(count: nil, reads: reads)
        XCTAssertNil(sliced)
        XCTAssertFalse(
            reads.copiedValue,
            "kAXValue must not be copied when kAXNumberOfCharacters is missing"
        )
        XCTAssertEqual(reads.attributes, [kAXNumberOfCharactersAttribute as String])
    }

    func testNonIntegerCharacterCountDoesNotCopyTheWholeValue() {
        let reads = Reads()
        let sliced = slice(count: "not-a-count" as NSString, reads: reads)
        XCTAssertNil(sliced)
        XCTAssertFalse(
            reads.copiedValue,
            "kAXValue must not be copied when kAXNumberOfCharacters is not an Int"
        )
        XCTAssertEqual(reads.attributes, [kAXNumberOfCharactersAttribute as String])
    }

    func testCharacterCountAtTheCapStillCopiesAndSlicesTheValue() {
        let reads = Reads()
        let cap = SelectionReader.maxSliceableDocumentCharacters
        let sliced = slice(count: NSNumber(value: cap), reads: reads)
        XCTAssertEqual(sliced, "abcd")
        XCTAssertTrue(reads.copiedValue)
        XCTAssertEqual(
            reads.attributes,
            [kAXNumberOfCharactersAttribute as String, kAXValueAttribute as String]
        )
    }

    func testCharacterCountPastTheCapDoesNotCopyTheValue() {
        let reads = Reads()
        let past = SelectionReader.maxSliceableDocumentCharacters + 1
        let sliced = slice(count: NSNumber(value: past), reads: reads)
        XCTAssertNil(sliced)
        XCTAssertFalse(
            reads.copiedValue,
            "kAXValue must not be copied when the character count is past the document cap"
        )
        XCTAssertEqual(reads.attributes, [kAXNumberOfCharactersAttribute as String])
    }
}
