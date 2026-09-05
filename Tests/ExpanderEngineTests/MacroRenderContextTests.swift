import XCTest
@testable import ExpanderEngine

final class MacroRenderContextTests: XCTestCase {
    func testContextPinsNestedSourceAndRejectsReuseForAnotherTemplate() {
        let context = MacroRenderContext(clipboardText: "")
        var lookups = 0
        let lookup: (String) -> String? = { _ in lookups += 1; return "version-\(lookups)" }
        let first = MacroRenderer.expand(content: "%snippet:a%", lookup: lookup, context: context)
        let second = MacroRenderer.expand(content: "%snippet:a%", lookup: lookup, context: context)
        XCTAssertEqual(first.text, "version-1")
        XCTAssertEqual(second.text, first.text)
        XCTAssertEqual(lookups, 1)
        let changed = MacroRenderer.expand(content: "a different template", context: context)
        XCTAssertTrue(changed.text.isEmpty)
        XCTAssertNotNil(changed.failure)
    }

    func testOneOperationKeepsDateClipboardAndVolatileValuesAcrossPreparation() throws {
        let suite = "devtype.macro.context.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let counters = MacroCounterStore(defaults: defaults)
        let context = MacroRenderContext(clipboardText: "fixed", now: Date(timeIntervalSince1970: 0),
            environment: MacroEnvironment(locale: Locale(identifier: "en_US_POSIX"), timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: 0)), counters: counters))
        let content = "%uuid% {{uuid}} %counter:x% {{counter:x}} {{random:hex:8}} {{date:yyyy}} {{clipboard}}"
        let first = MacroRenderer.expand(content: content, context: context)
        let second = MacroRenderer.expand(content: content, clipboardText: "changed", now: Date(), context: context)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.text.hasSuffix("1970 fixed"))
        XCTAssertEqual(counters.value(for: "x"), 1)
        let pieces = first.text.split(separator: " ")
        XCTAssertNotEqual(pieces[0], pieces[1], "Different UUID occurrences are distinct within one operation")
    }

    func testFillDiscoveryDoesNotReserveCountersAndFinalFillUsesPinnedSource() throws {
        let suite = "devtype.macro.fill.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let counters = MacroCounterStore(defaults: defaults)
        let context = MacroRenderContext(clipboardText: "", environment: MacroEnvironment(counters: counters))
        let content = "%counter:form% %filltext:name=X%"
        let preview = MacroRenderer.expand(content: content, context: context)
        XCTAssertTrue(preview.needsFillIn)
        XCTAssertEqual(counters.value(for: "form"), 0)
        let rendered = MacroRenderer.expand(content: content, fillValues: [0: "{{cursor}}"], context: context)
        XCTAssertEqual(rendered.text, "1 {{cursor}}")
        XCTAssertNil(rendered.cursorOffset)
        XCTAssertEqual(counters.value(for: "form"), 1)
    }
}
