import AppKit
import ExpanderEngine
import Foundation
import XCTest
@testable import DevTypeAppCore

@MainActor
final class UpdateStatusRefreshTests: XCTestCase {
    private var preferencesSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/DevTypeAppCore/PreferencesWindowController.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    func testUpdateStatusRefreshesFromCompletionStateInsteadOfATimingGuess() throws {
        let source = try preferencesSource

        XCTAssertTrue(source.contains("UpdatePreferences.didChangeNotification"))
        XCTAssertFalse(
            source.contains("deadline: .now() + 1.5"),
            "Network completion must drive the status refresh; a fixed delay can fire too early or late."
        )
    }

    func testLongReleaseNotesAreBoundedScrollableAndKeepDismissalsReachable() throws {
        _ = NSApplication.shared
        let notes = (0..<300).map { "Release note \($0)" }.joined(separator: "\n")
        let presentation = DevTypeScrollableAlert(
            title: "DevType 9.9.9 is Available",
            message: "You are running 1.0.0.",
            scrollTitle: "Release Notes",
            scrollableText: notes,
            style: .informational,
            buttons: ["View Release", "Skip This Version", "Later"]
        )

        presentation.alert.layout()
        let accessory = try XCTUnwrap(presentation.alert.accessoryView)
        accessory.layoutSubtreeIfNeeded()
        let views = descendants(of: accessory)
        let scroll = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        let close = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "updates.available.close"
        })

        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertEqual(textView.string, notes, "The complete release notes must remain reachable")
        XCTAssertGreaterThan(
            textView.frame.height,
            scroll.contentSize.height,
            "A long release body must overflow inside the scroll view rather than grow the alert"
        )
        XCTAssertFalse(
            presentation.alert.informativeText.contains(notes),
            "Long notes must not be placed in NSAlert's unbounded informative-text region"
        )
        XCTAssertLessThanOrEqual(accessory.frame.height, 320)
        XCTAssertGreaterThan(close.frame.minY, scroll.frame.maxY, "Close must stay above the scroll region")
        XCTAssertEqual(close.title, LocalizationManager.shared.s("common.close"))
        XCTAssertEqual(close.keyEquivalent, "\u{1b}")
        XCTAssertNotNil(close.action)
        XCTAssertEqual(presentation.alert.buttons.count, 3, "Bottom actions must remain outside the scroll region")
    }

    func testTopCloseDismissesTheStandaloneMenuBarModal() throws {
        _ = NSApplication.shared
        let presentation = DevTypeScrollableAlert(
            title: "Update Available",
            message: "Summary",
            scrollTitle: "Release Notes",
            scrollableText: String(repeating: "Long notes\n", count: 100),
            style: .informational,
            buttons: ["View Release", "Skip This Version", "Later"]
        )
        let accessory = try XCTUnwrap(presentation.alert.accessoryView)
        let close = try XCTUnwrap(descendants(of: accessory).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "updates.available.close"
        })
        var response: Int?

        DispatchQueue.main.async {
            close.performClick(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard NSApp.modalWindow === presentation.alert.window else { return }
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        presentation.present(window: nil) {
            response = $0
        }

        XCTAssertEqual(response, -1, "Top Close must resolve as dismissal, never as an update action")
        XCTAssertFalse(presentation.alert.window.isVisible)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
