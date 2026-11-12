#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Test support, never linked into the app. Every test target depends on this target, so loading
/// a test bundle installs the shield before any test runs: each `NSWindow` the test process
/// creates stays fully transparent at the WindowServer, while `alphaValue` keeps reporting what
/// the code under test set. `isVisible`, frame, level and key status are untouched, so
/// layout, ordering and fade assertions behave as they would on screen. Nothing reaches the
/// person at the keyboard. It governs what is drawn, not focus or activation. See
/// TestWindowShield.m for how AppKit's own alpha reads are handled.
///
/// Set `DEVTYPE_TEST_SHOW_WINDOWS=1` to see test windows while debugging one.
///
/// Returns whether the shield is active in this process.
BOOL DTTestWindowShieldIsInstalled(void);

NS_ASSUME_NONNULL_END
