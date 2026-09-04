import Foundation
import XCTest

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
}
