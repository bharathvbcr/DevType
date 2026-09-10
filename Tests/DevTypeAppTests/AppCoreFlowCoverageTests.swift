import AppKit
import Foundation
import LocalAuthentication
import XCTest
import ExpanderEngine
@testable import DevTypeAppCore

final class AppCoreFlowCoverageTests: XCTestCase {

    // MARK: - ShortcutReference

    func testShortcutReferenceCatalogAndProjection() {
        let loc = LocalizationManager.shared
        let entries = ShortcutReferenceCatalog.make(
            loc: loc,
            inlineSearch: DevTypeShortcut.inlineSearchDefault,
            aiPalette: DevTypeShortcut.aiPaletteDefault,
            voice: DevTypeShortcut.voiceDefault
        )
        XCTAssertFalse(entries.isEmpty)

        // Empty query keeps all
        let allProjection = ShortcutReferenceProjection(entries: entries, query: "")
        XCTAssertEqual(allProjection.entries.count, entries.count)
        XCTAssertFalse(allProjection.showsEmptyState)

        // Query that matches title or section
        let firstTitle = entries[0].title
        let filteredProjection = ShortcutReferenceProjection(entries: entries, query: firstTitle)
        XCTAssertFalse(filteredProjection.entries.isEmpty)
        XCTAssertFalse(filteredProjection.showsEmptyState)

        // Query with no match
        let emptyProjection = ShortcutReferenceProjection(entries: entries, query: "nonexistent-query-string-xyz-123")
        XCTAssertTrue(emptyProjection.entries.isEmpty)
        XCTAssertTrue(emptyProjection.showsEmptyState)

        _ = ShortcutReferenceWindowController.shared
    }

    // MARK: - SnippetThumbnailCache

    func testSnippetThumbnailCache() {
        let cache = SnippetThumbnailCache.shared
        cache.removeAll()

        // Empty path returns nil
        XCTAssertNil(cache.cachedThumbnail(for: ""))
        XCTAssertNil(cache.thumbnail(for: "") { _ in })

        // Scaled image logic
        let validImage = NSImage(size: NSSize(width: 100, height: 50))
        validImage.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 100, height: 50))
        validImage.unlockFocus()

        let scaled = SnippetThumbnailCache.scaledForTesting(validImage, toEdge: 32)
        XCTAssertNotNil(scaled)
        XCTAssertEqual(scaled?.size.width, 32)
        XCTAssertEqual(scaled?.size.height, 16)

        // Invalid scales
        XCTAssertNil(SnippetThumbnailCache.scaledForTesting(validImage, toEdge: 0))
        XCTAssertNil(SnippetThumbnailCache.scaledForTesting(validImage, toEdge: -5))
        XCTAssertNil(SnippetThumbnailCache.scaledForTesting(NSImage(size: .zero), toEdge: 32))

        // Store and hit cache
        if let scaled {
            cache.storeForTesting(scaled, path: "test.png", edge: SnippetThumbnailCache.thumbnailEdge)
            XCTAssertNotNil(cache.cachedThumbnail(for: "test.png"))

            var callbackCalled = false
            let hit = cache.thumbnail(for: "test.png") { _ in
                callbackCalled = true
            }
            XCTAssertNotNil(hit)
            XCTAssertFalse(callbackCalled, "Hit should return synchronously without calling async completion")

            // Invalidation
            cache.invalidate(path: "test.png")
            XCTAssertNil(cache.cachedThumbnail(for: "test.png"))
            cache.invalidate(path: "") // no-op
        }

        // Real async load path via ImageAttachmentStore
        let testImg = NSImage(size: NSSize(width: 40, height: 40))
        testImg.lockFocus()
        NSColor.blue.drawSwatch(in: NSRect(x: 0, y: 0, width: 40, height: 40))
        testImg.unlockFocus()
        if let tiff = testImg.tiffRepresentation,
           let path = try? ImageAttachmentStore.shared.save(data: tiff) {
            let exp = expectation(description: "load thumbnail")
            _ = cache.thumbnail(for: path) { thumb in
                XCTAssertNotNil(thumb)
                exp.fulfill()
            }
            waitForExpectations(timeout: 2.0)
            ImageAttachmentStore.shared.deleteImage(path: path)
        }
    }

    // MARK: - AlertPresenter

    @MainActor
    func testAlertPresenterComponents() {
        // DevTypeScrollableAlert with default and custom buttons
        let defaultAlert = DevTypeScrollableAlert(
            title: "Title",
            message: "Message",
            scrollTitle: "Scroll Title",
            scrollableText: "Scroll Body",
            style: .informational,
            buttons: []
        )
        XCTAssertEqual(defaultAlert.alert.messageText, "Title")
        XCTAssertEqual(defaultAlert.alert.buttons.count, 1)

        let customAlert = DevTypeScrollableAlert(
            title: "Title 2",
            message: "Message 2",
            scrollTitle: "Notes",
            scrollableText: "Long notes",
            style: .warning,
            buttons: ["First", "Second"]
        )
        XCTAssertEqual(customAlert.alert.buttons.count, 2)
        XCTAssertEqual(customAlert.alert.alertStyle, .warning)

        // SnippetOperationGate
        let gate = SnippetOperationGate()
        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.begin(), "Second begin should fail while active")
        gate.finish()
        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(gate.begin())
        gate.finish()

        // DevTypeAlert.confirm branches
        var confirmed = false
        var cancelled = false
        var capturedConfirmHandler: ((Int) -> Void)?
        DevTypeAlert.presenterOverride = { _, _, _, _, _, handler in
            capturedConfirmHandler = handler
        }
        defer { DevTypeAlert.presenterOverride = nil }

        DevTypeAlert.confirm(
            title: "Confirm Delete",
            message: "Are you sure?",
            confirmTitle: "Delete",
            destructive: true,
            onCancel: { cancelled = true },
            onConfirm: { confirmed = true }
        )

        capturedConfirmHandler?(0)
        XCTAssertTrue(confirmed)
        XCTAssertFalse(cancelled)

        confirmed = false
        capturedConfirmHandler?(1)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(confirmed)

        // DevTypeScrollableAlert closeTapped
        customAlert.performSelector(onMainThread: Selector(("closeTapped")), with: nil, waitUntilDone: true)
    }

    // MARK: - SecretMenuFlow

    func testSecretMenuFlowResolveForCopy() {
        // Normal text snippet
        let textSnippet = SnippetModel(
            title: "Greeting",
            triggerKeyword: ";hi",
            replacementText: "Hello there!"
        )
        let textResult = SecretMenuFlow.resolveForCopy(textSnippet)
        XCTAssertEqual(textResult, .success("Hello there!"))

        // Empty text snippet
        let emptySnippet = SnippetModel(
            title: "Empty",
            triggerKeyword: ";empty",
            replacementText: ""
        )
        let emptyResult = SecretMenuFlow.resolveForCopy(emptySnippet)
        XCTAssertEqual(emptyResult, .failure(.emptySnippet))

        // Image snippet
        let imageSnippet = SnippetModel(
            title: "Image",
            triggerKeyword: ";img",
            replacementText: "",
            imagePath: "attachment.png"
        )
        let imageResult = SecretMenuFlow.resolveForCopy(imageSnippet)
        XCTAssertEqual(imageResult, .failure(.imageSnippet("attachment.png")))

        // Secret snippet
        let secretSnippet = SnippetModel(
            title: "API Key",
            triggerKeyword: ";key",
            replacementText: "",
            isSecret: true
        )
        let secretResult = SecretMenuFlow.resolveForCopy(secretSnippet)
        // With real Keychain in tests, it might be locked or secret unavailable
        switch secretResult {
        case .failure(.secretUnavailable), .failure(.keychainLocked):
            break // Expected outcomes
        case .success:
            break
        default:
            XCTFail("Unexpected result: \(secretResult)")
        }
    }

    func testSecretMenuFlowResolveWithBiometrics() {
        let textSnippet = SnippetModel(
            title: "Greeting",
            triggerKeyword: ";hi",
            replacementText: "Hello there!"
        )

        // Non-secret snippet resolves directly without gating
        let exp1 = expectation(description: "resolve text snippet")
        SecretMenuFlow.resolve(textSnippet, preferenceEnabled: false) { result in
            XCTAssertEqual(result, .success("Hello there!"))
            exp1.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        // Secret snippet with pending migration
        let secretSnippet = SnippetModel(
            title: "Password",
            triggerKeyword: ";pwd",
            replacementText: "",
            isSecret: true
        )
        let exp2 = expectation(description: "resolve migration required")
        SecretMenuFlow.resolve(
            secretSnippet,
            preferenceEnabled: false,
            pendingMigration: { [secretSnippet.id] }
        ) { result in
            XCTAssertEqual(result, .failure(.migrationRequired(pendingCount: 1)))
            exp2.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        // Mock BiometricGate authorized
        let authGate = BiometricGate(authenticator: StubBiometricAuthenticator(outcomes: [.authorized]))
        let exp3 = expectation(description: "resolve with mock authorized gate")
        SecretMenuFlow.resolve(
            secretSnippet,
            gate: authGate,
            preferenceEnabled: true,
            pendingMigration: { [] }
        ) { result in
            // Continues to resolveForCopy
            switch result {
            case .failure(.secretUnavailable), .failure(.keychainLocked):
                break
            case .success:
                break
            default:
                XCTFail("Unexpected result: \(result)")
            }
            exp3.fulfill()
        }
        waitForExpectations(timeout: 2.0)

        // Mock BiometricGate cancelled
        let cancelGate = BiometricGate(authenticator: StubBiometricAuthenticator(outcomes: [.cancelled]))
        let exp4 = expectation(description: "resolve with mock cancelled gate")
        SecretMenuFlow.resolve(
            secretSnippet,
            gate: cancelGate,
            preferenceEnabled: true,
            pendingMigration: { [] }
        ) { result in
            XCTAssertEqual(result, .failure(.authenticationCancelled))
            exp4.fulfill()
        }
        waitForExpectations(timeout: 2.0)
    }

    // MARK: - PermissionDiagnosticsController

    func testDiagnosticReportProjection() {
        let sampleReport = """
        [Permission] Snapshot: listen=granted ax=granted
        [Inject] Timing: p90=50ms
        [App] Launch completed
        """

        let unfiltered = DiagnosticReportProjection.make(report: sampleReport, query: "")
        XCTAssertFalse(unfiltered.isFiltered)
        XCTAssertEqual(unfiltered.matchingLineCount, 3)
        XCTAssertEqual(unfiltered.totalLineCount, 3)
        XCTAssertTrue(unfiltered.isCopyable)

        let filtered = DiagnosticReportProjection.make(report: sampleReport, query: "timing")
        XCTAssertTrue(filtered.isFiltered)
        XCTAssertEqual(filtered.matchingLineCount, 1)
        XCTAssertEqual(filtered.totalLineCount, 3)
        XCTAssertTrue(filtered.text.contains("[Inject] Timing"))
        XCTAssertTrue(filtered.isCopyable)

        let emptyResult = DiagnosticReportProjection.make(report: sampleReport, query: "missing-token")
        XCTAssertTrue(emptyResult.isFiltered)
        XCTAssertEqual(emptyResult.matchingLineCount, 0)
        XCTAssertFalse(emptyResult.isCopyable)
    }

    // MARK: - SnippetEditTransaction

    func testSnippetEditResourceAccessLiveAndReceipt() {
        let live = SnippetEditResourceAccess.live

        // Empty image path and absolute path
        if case .success = live.deleteImage("") {} else { XCTFail("Expected success") }
        if case .success = live.deleteImage("/absolute/path.png") {} else { XCTFail("Expected success") }

        // Read secret for random UUID
        let secretSnap = live.readSecret(UUID())
        XCTAssertTrue(secretSnap == .missing || secretSnap == .unavailable)

        // Protect secret from orphan purge
        _ = live.protectSecretFromOrphanPurge(UUID())

        // Receipt default cleanup image
        let receipt = SnippetEditorPersistenceReceipt(
            outcome: .saved,
            rollback: { .saved },
            finalize: {}
        )
        XCTAssertEqual(receipt.cleanupImage("dummy.png", { _ in true }), .removed)
        XCTAssertEqual(receipt.cleanupImage("dummy.png", { _ in false }), .failed)
    }

    @MainActor
    func testPermissionDiagnosticsControllerViewAndActions() {
        let controller = PermissionDiagnosticsController()
        _ = controller.view

        let evidence1 = PermissionDiagnosticsController.Evidence(
            bundleID: "com.test.app",
            appPath: "/Applications/Test.app",
            cdHash: "abcdef0123456789",
            designatedRequirement: "identifier \"com.test.app\"",
            siblingPaths: ["/Applications/Test2.app"],
            injectHealth: "ok"
        )
        controller.apply(evidence1)

        let evidence2 = PermissionDiagnosticsController.Evidence(
            bundleID: "com.test.app",
            appPath: "/Applications/Test.app",
            cdHash: "abcdef0123456789",
            designatedRequirement: nil,
            siblingPaths: [],
            injectHealth: "ok"
        )
        controller.apply(evidence2)

        let search = NSSearchField()
        search.stringValue = "query"
        controller.performSelector(onMainThread: Selector(("logFilterChanged:")), with: search, waitUntilDone: true)
        controller.didBecomeVisible()
        controller.performSelector(onMainThread: Selector(("copyDiagnosticLogs")), with: nil, waitUntilDone: true)
        controller.performSelector(onMainThread: Selector(("refreshDiagnosticLogs")), with: nil, waitUntilDone: true)
    }
}
