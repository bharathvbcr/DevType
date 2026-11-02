import ApplicationServices
import XCTest
@testable import ExpanderEngine

/// The value-slice rung may copy `kAXValue` only when `kAXNumberOfCharacters` is a whole number
/// from zero through `maxSliceableDocumentCharacters`, including a whole-valued double. A
/// missing count, a boolean, a fraction, or a negative refuses the copy. Attribute reads are
/// supplied here; nothing in this file calls Accessibility.
final class SelectionValueCopyTests: XCTestCase {
    private final class Reads {
        private(set) var attributes: [String] = []
        private(set) var calls = 0

        func append(_ attribute: String) {
            calls += 1
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

    /// Zero is an `Int` at or below the cap. The copy is allowed; a later change must not flip that silently.
    func testZeroCharacterCountIsWithinTheCapSoTheValueIsCopied() {
        let reads = Reads()
        let sliced = slice(count: NSNumber(value: 0), reads: reads)
        XCTAssertEqual(sliced, "abcd")
        XCTAssertTrue(
            reads.copiedValue,
            "a zero character count is an Int at or below the cap, so kAXValue is copied"
        )
        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(
            reads.attributes,
            [kAXNumberOfCharactersAttribute as String, kAXValueAttribute as String]
        )
    }

    func testNSNumberBooleanTrueDoesNotCopyTheValue() {
        assertValueCopyRefused(
            count: NSNumber(value: true),
            "kAXValue must not be copied when kAXNumberOfCharacters is an NSNumber boolean true; a boolean is not an Int character count"
        )
    }

    func testNSNumberBooleanFalseDoesNotCopyTheValue() {
        assertValueCopyRefused(
            count: NSNumber(value: false),
            "kAXValue must not be copied when kAXNumberOfCharacters is an NSNumber boolean false; a boolean is not an Int character count"
        )
    }

    func testCFBooleanTrueDoesNotCopyTheValue() {
        assertValueCopyRefused(
            count: kCFBooleanTrue,
            "kAXValue must not be copied when kAXNumberOfCharacters is kCFBooleanTrue; a boolean is not an Int character count"
        )
    }

    func testCFBooleanFalseDoesNotCopyTheValue() {
        assertValueCopyRefused(
            count: kCFBooleanFalse,
            "kAXValue must not be copied when kAXNumberOfCharacters is kCFBooleanFalse; a boolean is not an Int character count"
        )
    }

    func testFractionalDoubleCharacterCountDoesNotCopyTheValue() {
        assertValueCopyRefused(
            count: NSNumber(value: 1.5),
            "kAXValue must not be copied when kAXNumberOfCharacters is a Double NSNumber (1.5); a floating-point count is not an Int"
        )
    }

    func testIntegralDoubleCharacterCountCopiesAndSlicesTheValue() {
        let reads = Reads()
        let sliced = slice(count: NSNumber(value: 2_000_000.0), reads: reads)
        XCTAssertEqual(sliced, "abcd")
        XCTAssertTrue(
            reads.copiedValue,
            "a whole-valued double at the cap is a document length, so kAXValue is copied"
        )
        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(
            reads.attributes,
            [kAXNumberOfCharactersAttribute as String, kAXValueAttribute as String]
        )
    }

    func testFractionalCFNumberDoesNotCopyTheValue() {
        let doubleNumber = cfNumber(1.5, type: .doubleType)
        let floatNumber = cfNumber(Float(1.5), type: .float32Type)
        XCTAssertTrue(CFNumberIsFloatType(doubleNumber))
        XCTAssertTrue(CFNumberIsFloatType(floatNumber))
        assertValueCopyRefused(
            count: doubleNumber,
            "kAXValue must not be copied when kAXNumberOfCharacters is a float64 CFNumber (1.5); a non-integer CFNumber is not an Int"
        )
        assertValueCopyRefused(
            count: floatNumber,
            "kAXValue must not be copied when kAXNumberOfCharacters is a float32 CFNumber (1.5); a non-integer CFNumber is not an Int"
        )
    }

    func testIntegralValuedFloatCFNumberCopiesAndSlicesTheValue() {
        let number = cfNumber(2_000_000.0, type: .doubleType)
        XCTAssertTrue(CFNumberIsFloatType(number))
        let reads = Reads()
        let sliced = slice(count: number, reads: reads)
        XCTAssertEqual(sliced, "abcd")
        XCTAssertTrue(
            reads.copiedValue,
            "a whole-valued float64 CFNumber at the cap is a document length, so kAXValue is copied"
        )
        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(
            reads.attributes,
            [kAXNumberOfCharactersAttribute as String, kAXValueAttribute as String]
        )
    }

    func testNegativeCharacterCountDoesNotCopyTheValue() {
        assertValueCopyRefused(
            count: NSNumber(value: -1),
            "kAXValue must not be copied when kAXNumberOfCharacters is -1; a negative count does not bound the document"
        )
    }

    func testIntMinCharacterCountDoesNotCopyTheValue() {
        assertValueCopyRefused(
            count: NSNumber(value: Int.min),
            "kAXValue must not be copied when kAXNumberOfCharacters is Int.min; a negative count does not bound the document"
        )
    }

    func testEmojiValueSlicesOnUTF16OffsetsAndASplitSurrogateDoesNotTrap() {
        let text = "a🙂b"
        XCTAssertEqual(text.utf16.count, 4)
        XCTAssertEqual(text.count, 3)
        XCTAssertNotEqual(text.utf16.count, text.count)

        let emojiReads = Reads()
        let emoji = slice(
            count: NSNumber(value: text.utf16.count),
            value: text as NSString,
            range: CFRange(location: 1, length: 2),
            reads: emojiReads
        )
        XCTAssertEqual(emoji, "🙂")
        XCTAssertEqual(emojiReads.calls, 2)
        XCTAssertTrue(emojiReads.copiedValue)

        for location in [1, 2] {
            let reads = Reads()
            let half = slice(
                count: NSNumber(value: text.utf16.count),
                value: text as NSString,
                range: CFRange(location: location, length: 1),
                reads: reads
            )
            XCTAssertEqual(
                half,
                "\u{FFFD}",
                "a range that splits a surrogate at UTF-16 location \(location) must not trap"
            )
            XCTAssertEqual((half as NSString?)?.length, 1)
            XCTAssertEqual(reads.calls, 2)
        }
    }

    func testOutOfBoundsRangeReturnsNilAndDoesNotTrap() {
        let text = "a🙂b" as NSString
        let ranges = [
            CFRange(location: -1, length: 1),
            CFRange(location: 0, length: 0),
            CFRange(location: 0, length: -1),
            CFRange(location: text.length, length: 1),
            CFRange(location: 0, length: text.length + 1),
            CFRange(location: 3, length: 2),
            CFRange(location: Int.max, length: 1),
            CFRange(location: 0, length: Int.max),
        ]
        for range in ranges {
            let reads = Reads()
            let sliced = slice(
                count: NSNumber(value: text.length),
                value: text,
                range: range,
                reads: reads
            )
            XCTAssertNil(
                sliced,
                "location=\(range.location) length=\(range.length) must return nil and must not trap"
            )
            XCTAssertEqual(reads.calls, 2, "a legal count still copies before the range is refused")
            XCTAssertTrue(reads.copiedValue)
        }
    }

    func testAttributedStringValueSlicesWhenTheCountIsALegalInt() {
        let reads = Reads()
        let attributed = NSAttributedString(string: "abcdefghij")
        let sliced = slice(count: NSNumber(value: 10), value: attributed, reads: reads)
        XCTAssertEqual(sliced, "abcd")
        XCTAssertTrue(reads.copiedValue)
        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(
            reads.attributes,
            [kAXNumberOfCharactersAttribute as String, kAXValueAttribute as String]
        )

        let emojiReads = Reads()
        let emoji = slice(
            count: NSNumber(value: 4),
            value: NSAttributedString(string: "a🙂b"),
            range: CFRange(location: 1, length: 2),
            reads: emojiReads
        )
        XCTAssertEqual(emoji, "🙂")
        XCTAssertEqual(emojiReads.calls, 2)
    }

    func testEmptyStringValueWithALegalCountDoesNotTrap() {
        let reads = Reads()
        let sliced = slice(
            count: NSNumber(value: 4),
            value: "" as NSString,
            range: CFRange(location: 0, length: 1),
            reads: reads
        )
        XCTAssertNil(sliced)
        XCTAssertTrue(
            reads.copiedValue,
            "a legal count still copies an empty kAXValue"
        )
        XCTAssertEqual(reads.calls, 2)
        XCTAssertEqual(
            reads.attributes,
            [kAXNumberOfCharactersAttribute as String, kAXValueAttribute as String]
        )
    }

    /// An unusable count asks the closure for `kAXNumberOfCharacters` only — never `kAXValue`,
    /// and never a second, unexpected attribute.
    func testUnusableCountInvokesTheCopyClosureOnce() {
        let reads = Reads()
        var unexpected: [String] = []
        let sliced = SelectionReader.copyValueSubstring(
            utf16Range: CFRange(location: 0, length: 4)
        ) { attribute in
            reads.append(attribute)
            if attribute == (kAXNumberOfCharactersAttribute as String) {
                return "not-a-count" as NSString
            }
            unexpected.append(attribute)
            return "should-not-be-read" as NSString
        }
        XCTAssertNil(sliced)
        XCTAssertEqual(reads.calls, 1)
        XCTAssertTrue(
            unexpected.isEmpty,
            "unusable count must not ask for \(unexpected); kAXValue must not be copied"
        )
        XCTAssertFalse(reads.copiedValue)
        XCTAssertEqual(reads.attributes, [kAXNumberOfCharactersAttribute as String])
    }

    private func assertValueCopyRefused(
        count: CFTypeRef?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reads = Reads()
        let sliced = slice(count: count, reads: reads)
        XCTAssertNil(sliced, message, file: file, line: line)
        XCTAssertFalse(reads.copiedValue, message, file: file, line: line)
        XCTAssertEqual(
            reads.calls,
            1,
            "\(message) (closure calls=\(reads.calls) attributes=\(reads.attributes))",
            file: file,
            line: line
        )
        XCTAssertEqual(
            reads.attributes,
            [kAXNumberOfCharactersAttribute as String],
            message,
            file: file,
            line: line
        )
    }

    private func cfNumber(_ value: Double, type: CFNumberType) -> CFNumber {
        var storage = value
        guard let number = CFNumberCreate(kCFAllocatorDefault, type, &storage) else {
            preconditionFailure("CFNumberCreate failed")
        }
        return number
    }

    private func cfNumber(_ value: Float, type: CFNumberType) -> CFNumber {
        var storage = value
        guard let number = CFNumberCreate(kCFAllocatorDefault, type, &storage) else {
            preconditionFailure("CFNumberCreate failed")
        }
        return number
    }
}
