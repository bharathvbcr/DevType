import AppKit
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

@MainActor
final class CoreUXRegressionTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func testHomePauseButtonTogglesTheCanonicalEngineState() throws {
        let defaults = UserDefaults.standard
        let canonicalKey = ProcessIdentity.userPausedDefaultsKey
        let legacyKey = "devtype.expansionPaused"
        let oldCanonical = defaults.object(forKey: canonicalKey)
        let oldLegacy = defaults.object(forKey: legacyKey)
        let engine = EventTapEngine()
        defer {
            restore(oldCanonical, forKey: canonicalKey, in: defaults)
            restore(oldLegacy, forKey: legacyKey, in: defaults)
        }

        defaults.removeObject(forKey: legacyKey)
        engine.isEnabled = false
        let controller = HomeViewController(engine: engine, resumeTap: {})
        let buttons = descendants(of: controller.view).compactMap { $0 as? NSButton }
        let pauseButton = try XCTUnwrap(buttons.first {
            $0.action == NSSelectorFromString("statusActionTapped")
        })

        pauseButton.performClick(nil)

        XCTAssertTrue(engine.isEnabled, "Home Resume must change the running engine, not a second defaults key")
        XCTAssertFalse(defaults.bool(forKey: canonicalKey), "The engine owns the persisted inverse pause flag")
        XCTAssertNil(defaults.object(forKey: legacyKey), "Home must retire its disconnected pause key")
    }

    func testHomeUsesThePreferencesHeadingAndPinsItsDocumentToTheViewport() throws {
        _ = NSApplication.shared
        let controller = HomeViewController(engine: EventTapEngine(), resumeTap: {})
        let scroll = try XCTUnwrap(controller.view as? NSScrollView)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 720, height: 620))
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()

        let labels = descendants(of: scroll).compactMap { $0 as? NSTextField }
        XCTAssertFalse(
            labels.contains { $0.stringValue == LocalizationManager.shared.s("prefs.tab.home") },
            "Preferences already renders the page heading outside the Home scroll view"
        )
        XCTAssertFalse(
            labels.contains { $0.stringValue == LocalizationManager.shared.s("prefs.tab.home.subtitle") },
            "Preferences already renders the page subtitle outside the Home scroll view"
        )

        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(document.frame.width, scroll.contentView.bounds.width, accuracy: 0.5)
    }

    func testSynchronousLocalAIPreviewCompletesBeforePresentationReturns() throws {
        _ = NSApplication.shared
        AIPreviewPanel.close()
        defer { AIPreviewPanel.close() }

        AIPreviewPanel.present(
            input: "**bold**",
            kind: .removeMarkdown,
            sourceApp: nil,
            onReplace: { _, _ in XCTFail("Presenting a preview must not replace automatically") }
        )

        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? NSPanel }.first { panel in
            guard panel.isVisible, let content = panel.contentView else { return false }
            return !self.descendants(of: content).compactMap { $0 as? NSTextView }.isEmpty
        })
        let views = descendants(of: try XCTUnwrap(panel.contentView))
        let result = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        let spinner = try XCTUnwrap(views.compactMap { $0 as? NSProgressIndicator }.first)
        let replace = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first {
            $0.action == NSSelectorFromString("replaceTapped")
        })

        XCTAssertEqual(result.string, "bold")
        XCTAssertTrue(spinner.isHidden)
        XCTAssertTrue(replace.isEnabled)
    }

    func testVoiceHUDCopyPreservesTheExactCanonicalTranscript() throws {
        _ = NSApplication.shared
        var copied: String?
        let hud = VoiceHUDPanel(clipboardWriter: {
            copied = $0
            return true
        })
        defer {
            ToastPanel.dismiss()
            hud.hide()
        }
        let text = String(repeating: "Long dictation 🧪 ", count: 12) + "\nsecond\tline"
        let segments = [
            TranscriptDiffEngine.Segment(text: "Long", isCut: false),
            TranscriptDiffEngine.Segment(text: "discarded", isCut: true)
        ]
        let copy = try XCTUnwrap(descendants(of: try XCTUnwrap(hud.contentView))
            .compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("copyTranscript") })

        hud.updateState(.success(text: text, diffSegments: segments))
        copy.performClick(nil)

        XCTAssertEqual(copied, text, "Copy must preserve length, whitespace, Unicode, and the final text behind a diff")
    }

    func testVoiceHUDCompactButtonExposesItsCurrentActionToAssistiveTechnology() throws {
        _ = NSApplication.shared
        let hud = VoiceHUDPanel()
        defer { hud.hide() }
        let buttons = descendants(of: try XCTUnwrap(hud.contentView))
            .compactMap { $0 as? NSButton }
        let compact = try XCTUnwrap(buttons.first {
            $0.action == NSSelectorFromString("toggleCompact")
        })
        let localization = LocalizationManager.shared

        XCTAssertTrue(buttons.allSatisfy { $0.accessibilityRole() == .button })
        XCTAssertEqual(compact.toolTip, localization.s("voice.hud.compact"))
        XCTAssertEqual(compact.accessibilityLabel(), localization.s("voice.hud.compact"))

        compact.performClick(nil)

        let expandTitle = localization.s("voice.hud.expand")
        XCTAssertNotEqual(expandTitle, "voice.hud.expand", "The inverse compact action must be localized")
        XCTAssertEqual(compact.toolTip, expandTitle)
        XCTAssertEqual(compact.accessibilityLabel(), expandTitle)
    }

    func testPinningCancelsAnAlreadyScheduledTerminalDismiss() throws {
        _ = NSApplication.shared
        let hud = VoiceHUDPanel()
        defer { hud.hide() }
        let pin = try XCTUnwrap(descendants(of: try XCTUnwrap(hud.contentView))
            .compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("togglePin") })

        hud.updateState(.success(text: "complete"))
        pin.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(
            VoiceHUDPresentationTiming.successHoldDuration
                + VoiceHUDPresentationTiming.fadeOutDuration
                + 0.2
        ))

        XCTAssertTrue(hud.isVisible, "Pinning must invalidate a terminal-state dismiss already in flight")
    }

    func testUnpinningAnActiveRecordingDoesNotScheduleATerminalDismiss() throws {
        _ = NSApplication.shared
        let hud = VoiceHUDPanel()
        defer {
            hud.updateState(.success(text: "")) // stops the recording timer
            hud.hide()
        }
        let pin = try XCTUnwrap(descendants(of: try XCTUnwrap(hud.contentView))
            .compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("togglePin") })

        pin.performClick(nil)
        hud.updateState(.listening(modelName: "Test Engine"))
        pin.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(
            VoiceHUDPresentationTiming.successHoldDuration
                + VoiceHUDPresentationTiming.fadeOutDuration
                + 0.2
        ))

        XCTAssertTrue(hud.isVisible, "Unpinning while listening must not apply a success-state timeout")
    }

    func testPinningDuringTerminalFadeInvalidatesItsCompletion() throws {
        _ = NSApplication.shared
        let hud = VoiceHUDPanel()
        defer { hud.hide() }
        let pin = try XCTUnwrap(descendants(of: try XCTUnwrap(hud.contentView))
            .compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("togglePin") })

        hud.updateState(.success(text: "complete"))
        RunLoop.main.run(until: Date().addingTimeInterval(
            VoiceHUDPresentationTiming.successHoldDuration
                + VoiceHUDPresentationTiming.fadeOutDuration / 2
        ))
        pin.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(
            VoiceHUDPresentationTiming.fadeOutDuration + 0.2
        ))

        XCTAssertTrue(hud.isVisible, "Pinning during the fade must invalidate its pending orderOut")
        XCTAssertEqual(hud.alphaValue, 1, accuracy: 0.001)
    }
}
