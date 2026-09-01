#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>

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

/// # Legacy keychain trampolines
///
/// `SecKeychain*` was deprecated wholesale in macOS 10.10 in favour of the data-protection
/// keychain. DevType cannot use that one, and the reason is not preference: per TN3137 its
/// access groups "must be authorized by a provisioning profile", and a self-signed DevType
/// build claiming that entitlement is SIGKILLed by AMFI on launch. `KeychainSecretBackingStore`
/// documents the same decision from the Swift side. So the file-based keychain is the only
/// store available to this app, and these four functions are the only API that reaches the
/// parts of it DevType needs — none of them has a data-protection equivalent, because the
/// data-protection keychain has neither partition dialogs nor a user-lockable state.
///
/// That makes the deprecation permanent rather than a migration DevType has not got round to.
/// Left inline in Swift it produced five warnings on every clean build, which is exactly the
/// noise that hides a *new* warning. Swift has no per-call diagnostic suppression; ObjC does,
/// so the calls live here behind a documented pragma — the same reason the trampolines above
/// live here.
///
/// These are deliberately one-to-one with the C functions: same arguments, same return values,
/// same order. Nothing about what is stored, where, under which ACL, or who may read it is
/// changed by routing through them.

/// `SecKeychainGetUserInteractionAllowed`. Leaves `*outAllowed` untouched on failure, so a
/// caller that pre-seeds it with its desired default keeps that default.
OSStatus DTKeychainGetUserInteractionAllowed(Boolean *outAllowed);

/// `SecKeychainSetUserInteractionAllowed`. Process-wide, which is why callers restore it.
OSStatus DTKeychainSetUserInteractionAllowed(Boolean allowed);

/// `SecKeychainGetStatus` for the default keychain. A non-`errSecSuccess` return means there is
/// no default keychain — distinct from one that exists and is locked, and callers rely on that.
OSStatus DTKeychainGetDefaultStatus(SecKeychainStatus *outStatus);

/// `SecKeychainUnlock(NULL, 0, NULL, false)` — the system login-password dialog.
OSStatus DTKeychainUnlockDefault(void);

NS_ASSUME_NONNULL_END
