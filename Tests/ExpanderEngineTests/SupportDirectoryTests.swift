import Foundation
import XCTest
@testable import ExpanderEngine

final class SupportDirectoryTests: XCTestCase {
    func testTestProcessCannotResolveTheInstalledAppsSupportDirectory() throws {
        let realDirectory = try XCTUnwrap(FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first).appendingPathComponent("DevType", isDirectory: true).standardizedFileURL
        XCTAssertNotEqual(SupportDirectory.devType.standardizedFileURL, realDirectory)
        XCTAssertTrue(SupportDirectory.devType.standardizedFileURL.path.hasPrefix(
            FileManager.default.temporaryDirectory.standardizedFileURL.path
        ))
        XCTAssertEqual(SupportDirectory.devType, SupportDirectory.devType,
                       "Shared stores must resolve one stable directory for the test process.")
    }

    func testDefaultDiagnosticAndRecoveryPathsStayInsideTheTestRoot() {
        let root = SupportDirectory.devType
        XCTAssertEqual(VoiceDiagnosticsRecorder.terminalManifestURL.deletingLastPathComponent(), root)
        XCTAssertEqual(VoiceDiagnosticsRecorder.traceURL.deletingLastPathComponent(), root)
        XCTAssertEqual(SupportDirectory.voiceSessions.deletingLastPathComponent(), root)
        XCTAssertEqual(SnippetStore.defaultLocalSupportDirectory, root)
        XCTAssertEqual(InjectTimingStore.defaultFileURL().deletingLastPathComponent(), root)
    }

    func testSharedVoiceRecorderPersistsOnlyInTheIsolatedRoot() throws {
        let root = SupportDirectory.devType.standardizedFileURL
        guard root.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path) else {
            return XCTFail("Refusing to run a persistence test against the installed app's data.")
        }
        let diagnostic = VoiceTerminalDiagnostic(
            outcome: .cancelled, code: .cancelled, stage: .audioCapture,
            provider: .audioCapture, locality: .onDevice, recoverability: .notApplicable
        )
        let recorder = VoiceDiagnosticsRecorder.shared
        XCTAssertEqual(recorder.recordTerminal(diagnostic), .persisted)
        XCTAssertTrue(recorder.recentTerminalDiagnostics().contains(diagnostic))
        let bytes = try Data(contentsOf: VoiceDiagnosticsRecorder.terminalManifestURL)
        XCTAssertFalse(bytes.isEmpty)
        XCTAssertEqual(VoiceDiagnosticsRecorder.terminalManifestURL.deletingLastPathComponent().standardizedFileURL, root)
    }
}
