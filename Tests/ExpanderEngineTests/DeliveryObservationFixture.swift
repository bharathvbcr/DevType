import ApplicationServices
import Foundation
@testable import ExpanderEngine

/// Pure verifier fixtures use an AX reference only as an identity token. No AX
/// reads, writes, focus changes, or synthetic events occur through this helper.
enum DeliveryObservationFixture {
    static let target = AXUIElementCreateApplication(getpid())

    static func at(
        _ value: String, _ location: Int, _ length: Int = 0,
        selectedText: String? = nil, target: AXUIElement = target
    ) -> DeliveryVerifier.FocusedTextObservation {
        .init(value: value, selectedText: selectedText,
              selectedRange: NSRange(location: location, length: length), target: target)
    }
}
