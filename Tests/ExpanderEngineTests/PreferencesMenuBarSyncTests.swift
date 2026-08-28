import XCTest
@testable import ExpanderEngine

final class PreferencesMenuBarSyncTests: XCTestCase {

    func testPreferencesChangedNotificationPostedAndReceived() {
        let expectation = expectation(description: "devTypePreferencesChanged notification received")
        let observer = NotificationCenter.default.addObserver(
            forName: .devTypePreferencesChanged,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .devTypePreferencesChanged, object: nil)
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testLanguageChangedNotificationPostedAndReceived() {
        let expectation = expectation(description: "devTypeLanguageChanged notification received")
        let observer = NotificationCenter.default.addObserver(
            forName: .devTypeLanguageChanged,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        NotificationCenter.default.post(name: .devTypeLanguageChanged, object: nil)
        wait(for: [expectation], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testConflictDetectionTogglePersistsAndReads() {
        let initial = SnippetStore.isConflictDetectionEnabled
        defer { SnippetStore.isConflictDetectionEnabled = initial }

        SnippetStore.isConflictDetectionEnabled = false
        XCTAssertFalse(SnippetStore.isConflictDetectionEnabled)

        SnippetStore.isConflictDetectionEnabled = true
        XCTAssertTrue(SnippetStore.isConflictDetectionEnabled)
    }
}
