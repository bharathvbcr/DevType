#import <AppKit/AppKit.h>
@import DevTypeSafety;
#import <XCTest/XCTest.h>

/// Raises from both ordering methods. The raiser has to be ObjC: a Swift
/// subclass that raises an NSException aborts before an ObjC `@catch` above a
/// Swift frame can run.
@interface DTRaisingOrderWindow : NSWindow
@end

@implementation DTRaisingOrderWindow

- (void)orderFrontRegardless {
    [NSException raise:@"DTTestOrderFrontRegardless" format:@"orderFrontRegardless"];
}

- (void)makeKeyAndOrderFront:(id)sender {
    [NSException raise:@"DTTestMakeKeyAndOrderFront" format:@"makeKeyAndOrderFront"];
}

@end

/// `makeKeyAndOrderFront:` is a no-op. `orderFrontRegardless` raises.
@interface DTRaisesOnlyOnRegardless : NSWindow
@end

/// `orderFrontRegardless` is a no-op. `makeKeyAndOrderFront:` raises.
@interface DTRaisesOnlyOnMakeKey : NSWindow
@end

@interface DevTypeSafetyTestsRaisingWindow : XCTestCase
@end

@implementation DevTypeSafetyTestsRaisingWindow

- (DTRaisingOrderWindow *)raisingWindow {
    return [[DTRaisingOrderWindow alloc] initWithContentRect:NSMakeRect(0, 0, 120, 80)
                                                    styleMask:NSWindowStyleMaskTitled
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
}

- (void)testCatchFunctionsReturnRaisedExceptionAndProcessSurvives {
    DTRaisingOrderWindow *window = [self raisingWindow];

    NSException *ordered = DTOrderFrontRegardlessCatchingException(window);
    XCTAssertNotNil(ordered);
    XCTAssertEqualObjects(ordered.name, @"DTTestOrderFrontRegardless");

    NSException *keyed = DTMakeKeyAndOrderFrontCatchingException(window);
    XCTAssertNotNil(keyed);
    XCTAssertEqualObjects(keyed.name, @"DTTestMakeKeyAndOrderFront");

    // Reaching this line is the assertion that the process is still alive.
    XCTAssertTrue(YES);
}

/// `makeKeyAndOrderFront:` succeeds. `orderFrontRegardless` raises, so the
/// make-key trampoline only returns this exception when both calls sit in one
/// `@try` and the second call is reached.
- (void)testMakeKeyCatchAlsoCatchesOrderFrontRegardless {
    DTRaisesOnlyOnRegardless *window = [[DTRaisesOnlyOnRegardless alloc]
        initWithContentRect:NSMakeRect(0, 0, 120, 80)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];

    NSException *keyed = DTMakeKeyAndOrderFrontCatchingException(window);
    XCTAssertNotNil(keyed);
    XCTAssertEqualObjects(keyed.name, @"DTTestOnlyRegardless");
    XCTAssertTrue(YES);
}

/// A successful `orderFrontRegardless` must not go on to `makeKeyAndOrderFront:`.
/// The following make-key call proves this window still raises from that method.
- (void)testRegardlessCatchDoesNotCallMakeKeyAndOrderFront {
    DTRaisesOnlyOnMakeKey *window = [[DTRaisesOnlyOnMakeKey alloc]
        initWithContentRect:NSMakeRect(0, 0, 120, 80)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];

    NSException *ordered = DTOrderFrontRegardlessCatchingException(window);
    XCTAssertNil(ordered);

    NSException *keyed = DTMakeKeyAndOrderFrontCatchingException(window);
    XCTAssertNotNil(keyed);
    XCTAssertEqualObjects(keyed.name, @"DTTestOnlyMakeKey");
    XCTAssertTrue(YES);
}

@end

@implementation DTRaisesOnlyOnRegardless

- (void)makeKeyAndOrderFront:(id)sender {
    (void)sender;
}

- (void)orderFrontRegardless {
    [NSException raise:@"DTTestOnlyRegardless" format:@"only regardless"];
}

@end

@implementation DTRaisesOnlyOnMakeKey

- (void)orderFrontRegardless {
}

- (void)makeKeyAndOrderFront:(id)sender {
    (void)sender;
    [NSException raise:@"DTTestOnlyMakeKey" format:@"only make key"];
}

@end
