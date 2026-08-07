#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Orders `window` on screen, returning any `NSException` raised while it does
/// instead of letting the process abort.
///
/// **Why this is a whole ObjC function and not a `@try/@catch` around a block.**
/// A generic `NSException *DTRunCatching(void (^block)(void))` looks like the
/// reusable shape, and it does not work from Swift: the exception then has to
/// unwind from AppKit *through the Swift closure frame* to reach the `@catch`.
/// Swift frames are not unwindable, so that path calls `std::terminate` and the
/// process aborts anyway — the `@catch` never runs. Verified under lldb: with the
/// block form, a raising window-ordering observer still produced `SIGABRT`.
/// Every frame between the `@try` and the raiser must be ObjC, so the AppKit call
/// itself lives here.
///
/// **Why window ordering specifically.** Ordering a window posts
/// `_NSWindowWillBecomeVisible` and AppKit fans it out to every registered
/// observer, including out-of-process `NSRemoteView`s created by system services
/// we neither own nor can unregister. One of those raising is not our bug, but it
/// is our crash. See §8.7 and `InlineSearchPanel.PaletteSearchField`.
///
/// Returns `nil` on success. A non-nil return means the window may be only
/// partially ordered; the caller is expected to log what it caught.
NSException *_Nullable DTMakeKeyAndOrderFrontCatchingException(NSWindow *window);

NS_ASSUME_NONNULL_END
