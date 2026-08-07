import Foundation

/// Debug-only main-thread contract for AppKit-touching helpers.
///
/// Why this exists: `TextInjectionPipeline` fires its completion on the serial
/// `com.devtype.inject` queue, so any UI helper reached from an inject completion runs
/// off-main. AppKit's response to that is not graceful degradation — AutoLayout calls
/// `_AssertAutoLayoutOnAllowedThreadsOnly`, which aborts the process (SIGABRT). That crash
/// surfaces inside CoreAutoLayout, several frames below whichever DevType call was actually
/// at fault, so the stack points at the symptom rather than the offending call site.
///
/// `assertMainThread()` moves the failure to the real call site, in debug builds only.
/// Release behaviour is unchanged: this compiles to nothing, so a violation still reaches
/// AppKit exactly as it does today rather than introducing a new production crash.
///
/// Use it in helpers that mutate AppKit state (status item, menus, views). Helpers that
/// deliberately accept off-main callers should hop with `DispatchQueue.main.async` and place
/// this assertion *after* the hop — see `AppDelegate.refreshStatusItemUI()`.
@inline(__always)
func assertMainThread(
    _ file: StaticString = #fileID,
    _ line: UInt = #line
) {
    #if DEBUG
    dispatchPrecondition(condition: .onQueue(.main))
    #endif
}
