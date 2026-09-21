import AppKit
import ExpanderEngine
import XCTest
@testable import DevTypeAppCore

@MainActor
final class ActivityCenterViewControllerTests: XCTestCase {
    private var tempDir: URL!
    private var storeURL: URL!
    private var testStore: ActivityHistoryStore!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storeURL = tempDir.appendingPathComponent("activity-test.json")
        testStore = ActivityHistoryStore(fileURL: storeURL)
    }

    override func tearDown() {
        if let window = ActivityCenterViewController.activeWindow {
            window.close()
        }
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testWindowStyleMaskIncludesMiniaturizable() {
        ActivityCenterViewController.show()
        guard let window = ActivityCenterViewController.activeWindow else {
            XCTFail("Activity Center window was not created")
            return
        }
        XCTAssertTrue(
            window.styleMask.contains(.miniaturizable),
            "Activity Center window should be miniaturizable like other DevType windows"
        )
    }

    func testRowViewDisablesTranslatesAutoresizingMaskIntoConstraintsOnTimeLabel() throws {
        let event = ActivityHistoryStore.ActivityEvent(
            category: .general,
            title: "Test Event",
            details: "Details for test"
        )
        let rowView = ActivityEventRowView(
            event: event,
            localization: LocalizationManager.shared,
            onAction: { _ in }
        )
        let labels = descendants(of: rowView).compactMap { $0 as? NSTextField }
        let timeLabel = try XCTUnwrap(labels.first { $0.font?.fontName.contains("Mono") == true || $0.textColor == DevTypeTheme.textTertiary })
        XCTAssertFalse(
            timeLabel.translatesAutoresizingMaskIntoConstraints,
            "timeLabel must disable translatesAutoresizingMaskIntoConstraints to prevent AutoLayout conflicts"
        )
        XCTAssertEqual(timeLabel.contentHuggingPriority(for: .horizontal), .required)
        XCTAssertEqual(timeLabel.contentCompressionResistancePriority(for: .horizontal), .required)
    }

    func testTableViewSupportsDoubleActionAndKeyboardNavigation() throws {
        let vc = ActivityCenterViewController()
        _ = vc.view
        let tableView = try XCTUnwrap(findTableView(in: vc.view))
        XCTAssertNotNil(tableView.doubleAction, "TableView should have a doubleAction configured for activating events")
        XCTAssertNotNil(tableView.target, "TableView should have a target configured")
        XCTAssertEqual(tableView.selectionHighlightStyle, .regular)
    }

    func testReopeningWindowReattachesObserversAndRefreshes() {
        ActivityCenterViewController.show()
        guard let window = ActivityCenterViewController.activeWindow,
              let vc = window.contentViewController as? ActivityCenterViewController else {
            XCTFail("Active window not present")
            return
        }

        // Close window to trigger disappearance / detachment
        window.performClose(nil)

        // Show window again
        ActivityCenterViewController.show()

        // Verify window is visible and active
        XCTAssertTrue(window.isVisible)

        // Verify observers are attached and ready to receive updates
        let event = ActivityHistoryStore.ActivityEvent(
            category: .expansion,
            title: "Reopen Test",
            details: "Event after reopening"
        )
        _ = ActivityHistoryStore.shared.recordBatch([event])
        NotificationCenter.default.post(name: ActivityHistoryStore.didUpdateNotification, object: nil)

        let tableView = findTableView(in: vc.view)
        XCTAssertGreaterThanOrEqual(tableView?.numberOfRows ?? 0, 1)

        // Cleanup
        _ = ActivityHistoryStore.shared.clear()
    }

    func testEmptyStateOverlayVisibleWhenEmptyAndHiddenWhenPopulated() throws {
        _ = ActivityHistoryStore.shared.clear()
        let vc = ActivityCenterViewController()
        _ = vc.view
        vc.reload()

        let emptyView = try XCTUnwrap(findEmptyStateView(in: vc.view))
        XCTAssertFalse(emptyView.isHidden, "Empty state overlay should be visible when history is empty")

        // Populate an event
        let event = ActivityHistoryStore.ActivityEvent(
            category: .general,
            title: "Populated Event",
            details: "Details"
        )
        _ = ActivityHistoryStore.shared.recordBatch([event])
        vc.reload()

        XCTAssertTrue(emptyView.isHidden, "Empty state overlay should be hidden when events exist")

        // Cleanup
        _ = ActivityHistoryStore.shared.clear()
    }

    func testClearButtonStateMatchesEmptyAndHealth() {
        _ = ActivityHistoryStore.shared.clear()
        let vc = ActivityCenterViewController()
        _ = vc.view
        vc.reload()

        let buttons = descendants(of: vc.view).compactMap { $0 as? CapsuleButton }
        let clearBtn = buttons.first { $0.title == LocalizationManager.shared.s("activity.clear") }
        XCTAssertNotNil(clearBtn)
        XCTAssertFalse(clearBtn?.isEnabled ?? true, "Clear button should be disabled when empty and healthy")

        // Populate an event
        let event = ActivityHistoryStore.ActivityEvent(
            category: .general,
            title: "Event to clear",
            details: "Details"
        )
        _ = ActivityHistoryStore.shared.recordBatch([event])
        vc.reload()

        XCTAssertTrue(clearBtn?.isEnabled ?? false, "Clear button should be enabled when events exist")

        // Cleanup
        _ = ActivityHistoryStore.shared.clear()
    }

    func testSingleItemDeletionViaOnDelete() throws {
        let id1 = UUID()
        let id2 = UUID()
        let event1 = ActivityHistoryStore.ActivityEvent(
            id: id1,
            category: .general,
            title: "Event 1",
            details: "Details 1"
        )
        let event2 = ActivityHistoryStore.ActivityEvent(
            id: id2,
            category: .ai,
            title: "Event 2",
            details: "Details 2"
        )
        _ = ActivityHistoryStore.shared.recordBatch([event1, event2])

        let vc = ActivityCenterViewController()
        _ = vc.view
        vc.reload()

        let tableView = try XCTUnwrap(findTableView(in: vc.view))
        XCTAssertEqual(tableView.numberOfRows, 2)

        // Select first row and delete
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tableView.onDelete()

        // One item should remain
        XCTAssertEqual(tableView.numberOfRows, 1)

        // Cleanup
        _ = ActivityHistoryStore.shared.clear()
    }

    func testEscapeKeyClosesWindow() throws {
        ActivityCenterViewController.show()
        let window = try XCTUnwrap(ActivityCenterViewController.activeWindow)
        let vc = try XCTUnwrap(window.contentViewController as? ActivityCenterViewController)
        let tableView = try XCTUnwrap(findTableView(in: vc.view))

        XCTAssertTrue(window.isVisible)
        tableView.onEscape()
        XCTAssertFalse(window.isVisible)
    }

    func testAutoLayoutDoesNotRaiseConstraintExceptionsAtVariousSizes() {
        let vc = ActivityCenterViewController()
        let window = NSWindow(contentViewController: vc)
        let testSizes: [NSSize] = [
            NSSize(width: 440, height: 320), // minimum size
            NSSize(width: 540, height: 420), // default size
            NSSize(width: 800, height: 600), // enlarged
            NSSize(width: 1200, height: 800) // wide display
        ]

        let event = ActivityHistoryStore.ActivityEvent(
            category: .secureInput,
            title: String(repeating: "Long Title ", count: 10),
            details: String(repeating: "Long Details ", count: 20),
            action: .openPermissionRecovery
        )
        _ = ActivityHistoryStore.shared.recordBatch([event])
        vc.reload()

        for size in testSizes {
            window.setContentSize(size)
            window.layoutIfNeeded()
            XCTAssertEqual(window.contentView?.frame.size.width, size.width)
        }

        // Cleanup
        _ = ActivityHistoryStore.shared.clear()
    }

    private func findTableView(in view: NSView) -> ActivityTableView? {
        if let tv = view as? ActivityTableView { return tv }
        for subview in view.subviews {
            if let found = findTableView(in: subview) { return found }
        }
        return nil
    }

    private func findEmptyStateView(in view: NSView) -> ActivityHistoryEmptyStateView? {
        if let empty = view as? ActivityHistoryEmptyStateView { return empty }
        for subview in view.subviews {
            if let found = findEmptyStateView(in: subview) { return found }
        }
        return nil
    }

    private func descendants(of view: NSView) -> [NSView] {
        var result: [NSView] = []
        for subview in view.subviews {
            result.append(subview)
            result.append(contentsOf: descendants(of: subview))
        }
        return result
    }
}
