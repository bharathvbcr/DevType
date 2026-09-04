import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

final class VoiceTerminalDiagnosticsPreferencesTests: XCTestCase {
    func testDeleteActionInvokesTheTypedRecorderOperationExactlyOnce() {
        var calls = 0

        let presentation = VoiceTerminalDiagnosticsDeletionPresentation.perform {
            calls += 1
            return .succeeded
        }

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(presentation.statusKey, "prefs.voice.terminalDiagnostics.status.deleted")
        XCTAssertFalse(presentation.isWarning)
        XCTAssertNil(presentation.alertTitleKey)
        XCTAssertNil(presentation.alertMessageKey)
    }

    func testDeleteActionMapsFailureAndNotAttemptedToExplicitWarnings() {
        for status in [
            VoiceDiagnosticsRecorder.IOStatus.failed(.delete),
            .notAttempted,
        ] {
            let presentation = VoiceTerminalDiagnosticsDeletionPresentation.perform { status }

            XCTAssertEqual(
                presentation.statusKey,
                "prefs.voice.terminalDiagnostics.status.deleteFailed"
            )
            XCTAssertTrue(presentation.isWarning)
            XCTAssertEqual(
                presentation.alertTitleKey,
                "prefs.voice.terminalDiagnostics.deleteFailed.title"
            )
            XCTAssertEqual(
                presentation.alertMessageKey,
                "prefs.voice.terminalDiagnostics.deleteFailed.message"
            )
        }
    }

    func testTerminalDiagnosticsDeletionCopyExistsInEveryLanguage() {
        let keys = [
            "prefs.voice.terminalDiagnostics.delete",
            "prefs.voice.terminalDiagnostics.hint",
            "prefs.voice.terminalDiagnostics.status.deleted",
            "prefs.voice.terminalDiagnostics.status.deleteFailed",
            "prefs.voice.terminalDiagnostics.deleteFailed.title",
            "prefs.voice.terminalDiagnostics.deleteFailed.message",
        ]

        for language in AppLanguage.concreteCases {
            let table = LocalizationManager.stringTable(for: language)
            for key in keys {
                XCTAssertNotNil(table[key], "\(language.rawValue) missing \(key)")
            }
        }
    }

    func testPreferencesWiresTheTerminalDeletionButtonToTheRecorder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/DevTypeAppCore/PreferencesWindowController.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("#selector(deleteVoiceTerminalDiagnostics)"))
        XCTAssertTrue(source.contains("deleteTerminalDiagnostics()"))
        XCTAssertTrue(source.contains("prefs.voice.terminalDiagnostics.hint"))
    }
}
