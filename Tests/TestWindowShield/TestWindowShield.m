#import "TestWindowShield.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// How it works: `-[NSWindow setAlphaValue:]` is the call that pushes a window's alpha to the
// WindowServer, and `-[NSWindow alphaValue]` reads it back. The shield replaces both. The value
// the code asked for is kept on the window, and the WindowServer is always given 0. The
// designated initialisers apply the same treatment to every new window, whose alpha starts at 1
// without ever going through the setter.
//
// Who sees which alpha: AppKit itself re-applies a window's alpha to the WindowServer through
// private paths that skip `setAlphaValue:` (attaching a sheet, the close animation of a panel).
// It reads `alphaValue` to do so, so a read from inside AppKit gets the real value, 0, and the
// window stays hidden. Every other caller (the app, the tests, Foundation's KVC) gets the value
// the code set. TestWindowShieldTests covers both of those AppKit paths.
//
// `animator()` fades are unchanged as far as code can tell: they interpolate the logical value,
// take their full duration and fire their completion on time (checked against an unshielded
// run). A window at alpha 0 is also click-through, so a transparent test window never takes the
// person's clicks.
//
// Only NSWindow's own implementations are replaced. A subclass override still reaches them
// through `super`.

static const void *kDTLogicalAlphaKey = &kDTLogicalAlphaKey;

typedef void (*DTSetAlphaIMP)(id, SEL, CGFloat);
typedef CGFloat (*DTAlphaIMP)(id, SEL);
typedef id (*DTInitIMP)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL);
typedef id (*DTInitScreenIMP)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL, NSScreen *);

static DTSetAlphaIMP gOriginalSetAlpha;
static DTAlphaIMP gOriginalAlpha;
static DTInitIMP gOriginalInit;
static DTInitScreenIMP gOriginalInitScreen;

/// Added to NSWindow once the shield is in. Each test bundle links its own copy of this file;
/// the selector is how every copy agrees, process-wide, that the hooks are installed once.
static SEL DTMarkerSelector(void) {
    return sel_registerName("dt_testWindowShieldInstalled");
}

static void DTShieldSetAlpha(id self, SEL _cmd, CGFloat alpha) {
    objc_setAssociatedObject(self, kDTLogicalAlphaKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    gOriginalSetAlpha(self, _cmd, 0);
}

/// The load address of AppKit's own image, for telling AppKit's internal reads from the code under test.
static const void *gAppKitBase;

static BOOL DTCalledFromAppKit(const void *returnAddress) {
    Dl_info info;
    return dladdr(returnAddress, &info) != 0 && info.dli_fbase == gAppKitBase;
}

// noinline: the return address must be the caller of `alphaValue`, not a frame inlined into it.
__attribute__((noinline))
static CGFloat DTShieldAlpha(id self, SEL _cmd) {
    NSNumber *logical = objc_getAssociatedObject(self, kDTLogicalAlphaKey);
    if (logical == nil || DTCalledFromAppKit(__builtin_return_address(0))) {
        return gOriginalAlpha(self, _cmd);
    }
    return (CGFloat)logical.doubleValue;
}

/// Keeps the alpha the window was born with as its logical value, then hides it.
static id DTShieldNewWindow(id window) {
    if (window != nil && objc_getAssociatedObject(window, kDTLogicalAlphaKey) == nil) {
        DTShieldSetAlpha(window, @selector(setAlphaValue:), gOriginalAlpha(window, @selector(alphaValue)));
    }
    return window;
}

static id DTShieldInit(id self, SEL _cmd, NSRect rect, NSWindowStyleMask style, NSBackingStoreType backing, BOOL defer) {
    return DTShieldNewWindow(gOriginalInit(self, _cmd, rect, style, backing, defer));
}

static id DTShieldInitScreen(id self, SEL _cmd, NSRect rect, NSWindowStyleMask style, NSBackingStoreType backing,
                             BOOL defer, NSScreen *screen) {
    return DTShieldNewWindow(gOriginalInitScreen(self, _cmd, rect, style, backing, defer, screen));
}

/// Replaces NSWindow's own implementation of `selector`, returning the original. NULL when
/// NSWindow does not implement it itself; the caller then installs nothing.
static IMP DTNSWindowOwnMethod(SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList([NSWindow class], &count);
    IMP found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = method_getImplementation(methods[i]);
            break;
        }
    }
    free(methods);
    return found;
}

BOOL DTTestWindowShieldIsInstalled(void) {
    return class_getInstanceMethod([NSWindow class], DTMarkerSelector()) != NULL;
}

__attribute__((constructor))
static void DTInstallTestWindowShield(void) {
    const char *show = getenv("DEVTYPE_TEST_SHOW_WINDOWS");
    if (show != NULL && strcmp(show, "1") == 0) {
        fprintf(stderr, "TestWindowShield: DEVTYPE_TEST_SHOW_WINDOWS=1, test windows will be visible\n");
        return;
    }
    if (DTTestWindowShieldIsInstalled()) {
        return; // another test bundle in this process already installed it
    }

    SEL setAlpha = @selector(setAlphaValue:);
    SEL alpha = @selector(alphaValue);
    SEL init = @selector(initWithContentRect:styleMask:backing:defer:);
    SEL initScreen = @selector(initWithContentRect:styleMask:backing:defer:screen:);
    IMP originalSetAlpha = DTNSWindowOwnMethod(setAlpha);
    IMP originalAlpha = DTNSWindowOwnMethod(alpha);
    IMP originalInit = DTNSWindowOwnMethod(init);
    IMP originalInitScreen = DTNSWindowOwnMethod(initScreen);
    if (originalSetAlpha == NULL || originalAlpha == NULL || originalInit == NULL || originalInitScreen == NULL) {
        // Leave AppKit untouched and unmarked: TestWindowShieldTests asserts the shield is
        // installed, so this fails the suite rather than quietly showing windows again.
        fprintf(stderr, "TestWindowShield: NSWindow no longer implements an alpha or init method; NOT installed\n");
        return;
    }

    Dl_info appKit;
    if (dladdr((const void *)originalSetAlpha, &appKit) == 0 || appKit.dli_fbase == NULL) {
        fprintf(stderr, "TestWindowShield: cannot locate AppKit's image; NOT installed\n");
        return;
    }
    gAppKitBase = appKit.dli_fbase;
    gOriginalSetAlpha = (DTSetAlphaIMP)originalSetAlpha;
    gOriginalAlpha = (DTAlphaIMP)originalAlpha;
    gOriginalInit = (DTInitIMP)originalInit;
    gOriginalInitScreen = (DTInitScreenIMP)originalInitScreen;

    Class window = [NSWindow class];
    method_setImplementation(class_getInstanceMethod(window, setAlpha), (IMP)DTShieldSetAlpha);
    method_setImplementation(class_getInstanceMethod(window, alpha), (IMP)DTShieldAlpha);
    method_setImplementation(class_getInstanceMethod(window, init), (IMP)DTShieldInit);
    method_setImplementation(class_getInstanceMethod(window, initScreen), (IMP)DTShieldInitScreen);
    class_addMethod(window, DTMarkerSelector(), imp_implementationWithBlock(^BOOL(id _) { return YES; }), "c@:");
}
