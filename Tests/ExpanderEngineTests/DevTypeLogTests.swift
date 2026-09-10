import Foundation
import XCTest
@testable import ExpanderEngine

final class DevTypeLogTests: XCTestCase {
    private struct SampleError: LocalizedError {
        var errorDescription: String? { "sample-error-description" }
    }

    func testLoggersAndSubsystemExist() {
        XCTAssertEqual(DevTypeLog.subsystem, "com.devtype.app")
        _ = DevTypeLog.permission
        _ = DevTypeLog.eventTap
        _ = DevTypeLog.secureInput
        _ = DevTypeLog.inject
        _ = DevTypeLog.identity
        _ = DevTypeLog.app
        _ = DevTypeLog.store
        _ = DevTypeLog.debounce
        _ = DevTypeLog.voice
        _ = DevTypeLog.selection
        _ = DevTypeLog.updates
    }

    func testGrantLabel() {
        XCTAssertEqual(DevTypeLog.grantLabel(true), "granted")
        XCTAssertEqual(DevTypeLog.grantLabel(false), "denied")
    }

    func testSnapshotSummary() {
        let snap1 = PermissionSnapshot(canListenTap: true, canUseAX: true, canPostEvents: true)
        let summary1 = DevTypeLog.snapshotSummary(snap1)
        XCTAssertTrue(summary1.contains("listen=granted ax=granted post=granted"))

        let snap2 = PermissionSnapshot(canListenTap: false, canUseAX: false, canPostEvents: false)
        let summary2 = DevTypeLog.snapshotSummary(snap2)
        XCTAssertTrue(summary2.contains("listen=denied ax=denied post=denied"))
    }

    func testErrorMetadata() {
        let err = NSError(domain: "test.domain", code: 42, userInfo: nil)
        let meta = DevTypeLog.errorMetadata(err)
        XCTAssertTrue(meta.contains("code=42"))
        XCTAssertTrue(meta.contains("NSError"))

        let sample = SampleError()
        let sampleMeta = DevTypeLog.errorMetadata(sample)
        XCTAssertTrue(sampleMeta.contains("code="))
        XCTAssertFalse(sampleMeta.contains("sample-error-description"))
    }

    func testPublicTextMetadata() {
        XCTAssertEqual(DevTypeLog.publicTextMetadata(nil), "text=absent")
        XCTAssertEqual(DevTypeLog.publicTextMetadata(""), "text=absent")
        let formatted = DevTypeLog.publicTextMetadata("Hello World")
        XCTAssertTrue(formatted.hasPrefix("textChars="))
        XCTAssertFalse(formatted.contains("Hello World"))
    }

    func testPublicPathMetadata() {
        XCTAssertEqual(DevTypeLog.publicPathMetadata(nil), "path=absent")
        XCTAssertEqual(DevTypeLog.publicPathMetadata(""), "path=absent")
        let formatted = DevTypeLog.publicPathMetadata("/Users/test/Documents/file.txt")
        XCTAssertTrue(formatted.hasPrefix("pathChars="))
        XCTAssertFalse(formatted.contains("/Users/test"))
    }

    func testBoundedPublicIdentifier() {
        XCTAssertEqual(DevTypeLog.boundedPublicIdentifier(nil, label: "bundleId"), "(unknown)")
        XCTAssertEqual(DevTypeLog.boundedPublicIdentifier("", label: "bundleId"), "(unknown)")
        let shortId = "com.apple.Safari"
        XCTAssertEqual(DevTypeLog.boundedPublicIdentifier(shortId, label: "bundleId"), shortId)

        let longId = String(repeating: "a", count: 300)
        let bounded = DevTypeLog.boundedPublicIdentifier(longId, label: "bundleId")
        XCTAssertTrue(bounded.hasPrefix("bundleIdChars="))
        XCTAssertFalse(bounded.contains(longId))
    }

    func testKindName() {
        XCTAssertEqual(DevTypeLog.kindName(.accessibility), "Accessibility")
        XCTAssertEqual(DevTypeLog.kindName(.inputMonitoring), "InputMonitoring")
        XCTAssertEqual(DevTypeLog.kindName(.postEvent), "PostEvents")
        XCTAssertEqual(DevTypeLog.kindName(.microphone), "Microphone")
        XCTAssertEqual(DevTypeLog.kindName(.speechRecognition), "SpeechRecognition")
    }

    func testRequestResultSummary() {
        let result1 = PermissionRequester.RequestResult(
            kind: .accessibility,
            apiReturnedTrue: true,
            preflightGranted: true,
            usedListenOnlyProbe: false
        )
        let summary1 = DevTypeLog.requestResultSummary(result1)
        XCTAssertEqual(summary1, "kind=Accessibility apiReturned=true preflight=granted")

        let result2 = PermissionRequester.RequestResult(
            kind: .inputMonitoring,
            apiReturnedTrue: false,
            preflightGranted: false,
            usedListenOnlyProbe: true
        )
        let summary2 = DevTypeLog.requestResultSummary(result2)
        XCTAssertEqual(summary2, "kind=InputMonitoring apiReturned=false preflight=denied listenOnlyProbe=true")
    }
}
