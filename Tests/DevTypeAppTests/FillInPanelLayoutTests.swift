import AppKit
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

@MainActor
final class FillInPanelLayoutTests: XCTestCase {
    func testLargeMixedFormUsesOneScrollableFieldRegionAndKeepsActionsVisible() throws {
        _ = NSApplication.shared
        let fields = (0..<20).map { index in
            FillField(
                id: index,
                name: "Field \(index)",
                kind: index.isMultiple(of: 3) ? .area : .text,
                defaultValue: "value \(index)"
            )
        }
        var completionCount = 0
        let panel = FillInPanel.present(title: "Large form", fields: fields) { _ in
            completionCount += 1
        }
        defer {
            panel.close()
            XCTAssertEqual(completionCount, 1)
        }

        panel.contentView?.layoutSubtreeIfNeeded()
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let formScroll = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first { scroll in
            guard let document = scroll.documentView else { return false }
            let inputs = descendants(of: document).filter {
                $0 is NSTextField || $0 is NSTextView || $0 is NSPopUpButton || $0 is NSSwitch
            }
            return inputs.count >= fields.count
        })

        XCTAssertTrue(formScroll.hasVerticalScroller)
        XCTAssertLessThanOrEqual(panel.contentLayoutRect.height, 540)
        XCTAssertGreaterThan(
            formScroll.documentView?.fittingSize.height ?? 0,
            formScroll.contentSize.height,
            "A large form should scroll rather than compress or clip its fields"
        )

        let actions = views.compactMap { $0 as? NSButton }.filter {
            $0.action == NSSelectorFromString("submitTapped")
                || $0.action == NSSelectorFromString("cancelTapped")
        }
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(actions.allSatisfy { !$0.isHidden && $0.window === panel })
    }

    func testSingleMultilineFieldGetsEnoughUsableViewportHeight() throws {
        _ = NSApplication.shared
        let panel = FillInPanel.present(
            title: "One area",
            fields: [FillField(id: 1, name: "Notes", kind: .area, defaultValue: "")]
        ) { _ in }
        defer { panel.close() }

        panel.contentView?.layoutSubtreeIfNeeded()
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let editor = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        let actions = views.compactMap { $0 as? NSButton }.filter {
            $0.action == NSSelectorFromString("submitTapped")
                || $0.action == NSSelectorFromString("cancelTapped")
        }

        XCTAssertGreaterThanOrEqual(editor.enclosingScrollView?.frame.height ?? 0, 80)
        XCTAssertEqual(actions.count, 2)
        XCTAssertTrue(actions.allSatisfy { !$0.isHidden })
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
