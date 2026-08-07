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
