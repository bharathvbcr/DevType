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
