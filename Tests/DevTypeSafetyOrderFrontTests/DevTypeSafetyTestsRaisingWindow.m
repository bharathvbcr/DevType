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

@end
