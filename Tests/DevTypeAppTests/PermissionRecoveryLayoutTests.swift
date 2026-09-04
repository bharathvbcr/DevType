import AppKit
import XCTest
@testable import DevTypeAppCore

/// Regression coverage for permission UI defects that are otherwise only visible after the
/// window has shipped. These checks intentionally exercise DevType's real minimum/default size.
final class PermissionRecoveryLayoutTests: XCTestCase {
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    func testPermissionRecoveryLabelsFitAtDefaultWindowSize() {
        _ = NSApplication.shared
        let controller = PermissionRecoveryController()
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        PermissionRecoveryWindowLayout.apply(to: window)
        window.contentView?.layoutSubtreeIfNeeded()
        controller.view.layoutSubtreeIfNeeded()

        let visibleLabels = descendants(of: controller.view)
            .compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden && !$0.stringValue.isEmpty && !$0.isEditable }

        XCTAssertFalse(visibleLabels.isEmpty)
        for label in visibleLabels where label.cell?.wraps == true {
            let width = max(1, label.bounds.width)
            let required = ceil(label.attributedStringValue.boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height)
            // AppKit's field cell adds roughly one line of internal leading to this estimate.
            // Allow that decoration, but never an entire additional wrapped content line.
            let cellDecoration = (label.font?.pointSize ?? 11) + 4
            XCTAssertGreaterThanOrEqual(
                label.bounds.height + cellDecoration,
                required,
                "Permission guidance is clipped (width=\(width), height=\(label.bounds.height), required=\(required)): \(label.stringValue)"
            )
        }
    }

    func testPermissionRequestButtonsAreVisiblyDisabledDuringSettle() {
        XCTAssertEqual(
            PermissionRequestButtonPresentation.resolve(
                isGranted: false,
                requestInFlight: false
            ),
            PermissionRequestButtonPresentation(isGranted: false, isEnabled: true)
        )
        XCTAssertEqual(
            PermissionRequestButtonPresentation.resolve(
                isGranted: false,
                requestInFlight: true
            ),
            PermissionRequestButtonPresentation(isGranted: false, isEnabled: false)
        )
        XCTAssertEqual(
            PermissionRequestButtonPresentation.resolve(
                isGranted: true,
                requestInFlight: false
            ),
            PermissionRequestButtonPresentation(isGranted: true, isEnabled: false)
        )
    }

    func testPermissionRecoveryWindowCannotResizeBelowUsableContentBounds() {
        _ = NSApplication.shared
        let window = NSWindow()

        PermissionRecoveryWindowLayout.apply(to: window)

        XCTAssertEqual(window.contentMinSize, NSSize(width: 560, height: 520))
        XCTAssertEqual(window.contentView?.frame.size, NSSize(width: 640, height: 720))
    }

    func testRecoveryWindowOwnsPersistentTapFailureWithoutStackingAModalAlert() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let delegate = try String(
            contentsOf: root.appendingPathComponent("Sources/DevTypeAppCore/AppDelegate.swift"),
            encoding: .utf8
        )
        let alertStart = try XCTUnwrap(delegate.range(of: "private func presentTapFailedAlert()"))
        let monitorStart = try XCTUnwrap(
            delegate.range(of: "private func startSecureInputMonitoring()", range: alertStart.upperBound..<delegate.endIndex)
        )
        let alertBody = delegate[alertStart.lowerBound..<monitorStart.lowerBound]

        XCTAssertTrue(delegate.contains("private var isPermissionRecoveryVisible: Bool"))
        XCTAssertTrue(alertBody.contains("isOnboardingVisible || isPermissionRecoveryVisible"))
    }

    /// A misspelled or unavailable SF Symbol becomes a blank badge with no visible fallback.
    /// Scan every direct `symbol:` literal in the app-core UI so the whole class of defect stays
    /// fixed rather than pinning the test to the one spelling that exposed it.
    func testEveryDirectUISymbolLiteralRenders() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Sources/DevTypeAppCore", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let regex = try NSRegularExpression(pattern: #"\bsymbol:\s*\"([^\"]+)\""#)

        var checked = Set<String>()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let capture = Range(match.range(at: 1), in: source) else { continue }
                checked.insert(String(source[capture]))
            }
        }

        XCTAssertFalse(checked.isEmpty)
        for symbol in checked.sorted() {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "UI symbol does not render on the deployment system: \(symbol)"
            )
        }
    }
}
