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

/// Key-value-codes `value` onto `object` for `key`, returning whether the write
/// landed instead of letting the process abort.
///
/// Same reason this lives in ObjC as `DTMakeKeyAndOrderFrontCatchingException`
/// (read that doc comment first): an `NSException` cannot unwind through Swift
/// frames, so the raising call itself must sit below a frame stack that is ObjC
/// all the way down to the `@catch`.
///
/// **Why KVC into private AppKit views specifically.** `GlassContainerView` drives
/// the private `NSGlassEffectView` (macOS 26+) through `setValue:forKey:` for keys
/// like "cornerRadius" / "tintColor" / "contentView". Those keys exist today, but
/// they are private API with no stability contract — on a future macOS where one
/// is renamed or removed, KVC raises an `NSUndefinedKeyException`, and raised from
/// inside a Swift initializer that aborts the process on launch. With this
/// trampoline the same future change degrades to the existing
/// `NSVisualEffectView` material fallback instead.
///
/// Returns `YES` when the write landed. `NO` means the key was rejected (or the
/// setter raised for any other reason); the caller must treat `object` as not
/// configured and take its documented fallback path.
BOOL DTSetValueForKeyCatching(NSObject *object, id _Nullable value, NSString *key);

NS_ASSUME_NONNULL_END
