import AppKit
import DevTypeSafety
import ExpanderEngine

/// Logs an `NSException` already caught below a pure ObjC frame.
///
/// The `@catch` lives in `DevTypeSafety.m`. This helper must not pass a Swift
/// closure into ObjC: the exception would unwind through a Swift frame and abort.
enum WindowOrdering {
    /// `nil` windows are a no-op, matching the previous `window?.` call sites.
    /// The ObjC trampoline takes a non-null `NSWindow`.
    static func makeKeyAndOrderFront(_ window: NSWindow?, context: String) {
        guard let window else { return }
        logCaught(DTMakeKeyAndOrderFrontCatchingException(window), context: context)
    }

    static func logCaught(_ raised: NSException?, context: String) {
        guard let raised else { return }
        DevTypeLog.app.error(
            """
            [\(context, privacy: .public)] window ordering raised \(DevTypeLog.boundedPublicIdentifier(raised.name.rawValue, label: "exceptionName"), privacy: .public): \
            \(DevTypeLog.publicTextMetadata(raised.reason), privacy: .public)
            stackFrames=\(raised.callStackReturnAddresses.count, privacy: .public)
            """
        )
    }
}
