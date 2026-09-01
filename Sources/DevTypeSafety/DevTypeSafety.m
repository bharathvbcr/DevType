#import "DevTypeSafety.h"

NSException *DTMakeKeyAndOrderFrontCatchingException(NSWindow *window) {
    @try {
        [window makeKeyAndOrderFront:nil];
        [window orderFrontRegardless];
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}

BOOL DTSetValueForKeyCatching(NSObject *object, id _Nullable value, NSString *key) {
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

#pragma mark - Legacy keychain trampolines

// The deprecation is permanent by design, not pending: see the header. Scoped to exactly these
// four calls so a genuinely new deprecation anywhere else still surfaces.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

OSStatus DTKeychainGetUserInteractionAllowed(Boolean *outAllowed) {
    return SecKeychainGetUserInteractionAllowed(outAllowed);
}

OSStatus DTKeychainSetUserInteractionAllowed(Boolean allowed) {
    return SecKeychainSetUserInteractionAllowed(allowed);
}

OSStatus DTKeychainGetDefaultStatus(SecKeychainStatus *outStatus) {
    return SecKeychainGetStatus(NULL, outStatus);
}

OSStatus DTKeychainUnlockDefault(void) {
    return SecKeychainUnlock(NULL, 0, NULL, false);
}

#pragma clang diagnostic pop
