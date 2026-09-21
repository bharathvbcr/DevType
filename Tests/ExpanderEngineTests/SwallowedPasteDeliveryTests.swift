import XCTest
@testable import ExpanderEngine

/// Cursor (and the VS Code family) bind ⌘V to `document.execCommand("paste")`. Electron reports
/// that command as failed and the desktop fallback does not insert the clipboard, so the trigger
/// — already erased — is replaced by nothing. The diagnostic for that failure is
/// `postedUnverified` plus "field unreadable" for `com.todesktop.230313mzl4w4u92`.
final class SwallowedPasteDeliveryTests: XCTestCase {

    private let cursor = "com.todesktop.230313mzl4w4u92"

    func testCursorExpansionIsTypedInsteadOfPasted() {
        XCTAssertTrue(AXWriteCapabilityStore.swallowsSyntheticPaste(bundleID: cursor))
        XCTAssertEqual(
            TextInjectionPipeline.insertAfterErase(bundleID: cursor, text: "hello"),
            .unicode
        )
    }

    func testVSCodeFamilyIsTypedAndOtherElectronHostsStillPaste() {
        let typed = [
            "com.microsoft.VSCode",
            "com.microsoft.VSCodeInsiders",
            "COM.MICROSOFT.VSCODE",
            "com.visualstudio.code",
            "com.visualstudio.code.oss"
        ]
        for bundle in typed {
            XCTAssertTrue(
                AXWriteCapabilityStore.swallowsSyntheticPaste(bundleID: bundle),
                bundle
            )
            XCTAssertEqual(
                TextInjectionPipeline.insertAfterErase(bundleID: bundle, text: "fn()"),
                .unicode,
                bundle
            )
        }

        let pasted = [
            "com.todesktop.other-app",
            "com.google.Chrome",
            "com.apple.Safari",
            "com.anthropic.claudefordesktop",
            "com.google.antigravity",
            "com.microsoft.Word",
            "com.google.Chrome.app.mjoklplbddabcmpepnokjaffbmgbkkgg",
            "",
            "   "
        ]
        for bundle in pasted {
            XCTAssertFalse(
                AXWriteCapabilityStore.swallowsSyntheticPaste(bundleID: bundle),
                bundle
            )
            XCTAssertEqual(
                TextInjectionPipeline.insertAfterErase(bundleID: bundle, text: "hello"),
                .clipboard,
                bundle
            )
        }
        XCTAssertEqual(
            TextInjectionPipeline.insertAfterErase(bundleID: nil, text: "hello"),
            .clipboard
        )
        XCTAssertEqual(
            TextInjectionPipeline.insertAfterErase(bundleID: cursor, text: "ls\n", shellLike: true),
            .clipboard
        )
    }

    func testEmptyExpansionDoesNotPasteAnEmptyClipboard() {
        XCTAssertEqual(
            TextInjectionPipeline.emptyExpansionDecision(text: "", cursorOffset: nil),
            .refuse
        )
        XCTAssertEqual(
            TextInjectionPipeline.emptyExpansionDecision(text: "", cursorOffset: -1),
            .refuse
        )
        XCTAssertEqual(
            TextInjectionPipeline.emptyExpansionDecision(text: "", cursorOffset: 0),
            .eraseOnly
        )
        XCTAssertEqual(
            TextInjectionPipeline.emptyExpansionDecision(text: " ", cursorOffset: nil),
            .insert
        )
        XCTAssertEqual(
            TextInjectionPipeline.emptyExpansionDecision(text: "body", cursorOffset: 1),
            .insert
        )
        XCTAssertEqual(
            TextInjectionPipeline.insertAfterErase(bundleID: cursor, text: ""),
            .nothing
        )
    }

    func testDestructiveControlsStayOffTheKeyPath() {
        XCTAssertNil(HIDKeyPoster.unicodeInsertEvents(for: "keep\u{0008}"))
        XCTAssertNil(HIDKeyPoster.unicodeInsertEvents(for: "\u{007F}"))
        XCTAssertNil(HIDKeyPoster.unicodeInsertEvents(for: "\u{0000}text"))
        XCTAssertNil(HIDKeyPoster.unicodeInsertEvents(for: "esc\u{001B}"))
        XCTAssertEqual(
            TextInjectionPipeline.insertAfterErase(bundleID: cursor, text: "a\u{0008}"),
            .clipboard
        )
    }

    func testUnicodePlanPreservesGraphemesNewlinesAndTabs() {
        let family = "👨‍👩‍👧‍👦"
        let events = HIDKeyPoster.unicodeInsertEvents(for: "a\r\nb\t\(family)e\u{0301}")
        XCTAssertEqual(
            events,
            [
                .text("a"),
                .text("\n"),
                .text("b"),
                .text("\t"),
                .text(family),
                .text("e\u{0301}")
            ]
        )
        XCTAssertEqual(HIDKeyPoster.unicodeInsertEvents(for: ""), [])
        XCTAssertEqual(
            HIDKeyPoster.unicodeInsertEvents(for: "\n\n"),
            [.text("\n"), .text("\n")]
        )
        XCTAssertEqual(
            HIDKeyPoster.unicodeInsertEvents(for: "\r\n\r\n"),
            [.text("\n"), .text("\n")]
        )
        XCTAssertEqual(
            HIDKeyPoster.unicodeInsertEvents(for: "\n\r"),
            [.text("\n"), .text("\n")]
        )
    }

    func testDeliveryStopsOnFailureCancellationAndCrossesTheBurstCap() {
        let events = Array(repeating: HIDKeyPoster.UnicodeInsertEvent.text("a"), count: 10)
        XCTAssertEqual(
            HIDKeyPoster.deliverUnicodeInsert(events: [], shouldContinue: { true }, post: { _ in true }),
            0
        )
        XCTAssertEqual(
            HIDKeyPoster.deliverUnicodeInsert(events: events, shouldContinue: { true }, post: { _ in true }),
            10
        )
        XCTAssertEqual(
            HIDKeyPoster.deliverUnicodeInsert(events: events, shouldContinue: { false }, post: { _ in true }),
            0
        )

        var seen = 0
        let stopped = HIDKeyPoster.deliverUnicodeInsert(events: events, shouldContinue: { true }) { _ in
            seen += 1
            return seen < 4
        }
        XCTAssertEqual(stopped, 3)

        var allowed = 2
        let cancelled = HIDKeyPoster.deliverUnicodeInsert(events: events, shouldContinue: {
            allowed > 0
        }) { _ in
            allowed -= 1
            return true
        }
        XCTAssertEqual(cancelled, 2)

        let burst = HIDKeyPoster.maxKeyPairsPerBurst
        let wide = Array(repeating: HIDKeyPoster.UnicodeInsertEvent.text("x"), count: burst + 3)
        var posts = 0
        let delivered = HIDKeyPoster.deliverUnicodeInsert(events: wide, shouldContinue: { true }) { event in
            posts += 1
            if case .text(let text) = event {
                XCTAssertEqual(text, "x")
            } else {
                XCTFail("burst carried a key")
            }
            return true
        }
        XCTAssertEqual(delivered, burst + 3)
        XCTAssertEqual(posts, burst + 3)

        var failAt = burst + 1
        let partial = HIDKeyPoster.deliverUnicodeInsert(events: wide, shouldContinue: { true }) { _ in
            failAt -= 1
            return failAt > 0
        }
        XCTAssertEqual(partial, burst)
    }

    func testLongAndAdversarialBodiesRoundTripWithoutSplittingClusters() {
        let body = String(repeating: "a\n", count: 3000) + "e\u{0301}" + "👨‍👩‍👧‍👦" + "\t"
        let events = HIDKeyPoster.unicodeInsertEvents(for: body)
        XCTAssertNotNil(events)
        var rebuilt = ""
        for event in events ?? [] {
            switch event {
            case .text(let text):
                rebuilt.append(text)
                let allowedControls: Set<UInt32> = [0x09, 0x0A]
                XCTAssertFalse(text.unicodeScalars.contains {
                    let value = $0.value
                    return (value < 0x20 || value == 0x7F) && !allowedControls.contains(value)
                })
            case .key(let code):
                XCTFail("newline and tab must be characters, not key \(code)")
            }
        }
        let expected = String(repeating: "a\n", count: 3000) + "e\u{0301}" + "👨‍👩‍👧‍👦" + "\t"
        XCTAssertEqual(rebuilt, expected)

        let controls = [0x01, 0x02, 0x07, 0x0B, 0x0C, 0x0E, 0x1B, 0x1F, 0x7F].compactMap {
            Unicode.Scalar(UInt32($0))
        }
        for scalar in controls {
            XCTAssertNil(
                HIDKeyPoster.unicodeInsertEvents(for: "safe\(String(scalar))"),
                "U+\(String(scalar.value, radix: 16))"
            )
        }
    }
}
