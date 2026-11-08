// LegacyDirectTouch.mm
// Experimental local bridge for scene-less apps whose visual layer has been
// reattached but whose system digitizer cannot route back to the UIKit scene.
// It handles only actual user mouse gestures delivered to our process; it does
// not post system events or generate input on its own.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface PearLegacyTouch : UITouch
@property(nonatomic, weak) UIWindow *pearWindow;
@property(nonatomic, weak) UIView *pearView;
@property(nonatomic) CGPoint pearPoint;
@property(nonatomic) CGPoint pearPrevious;
@property(nonatomic) UITouchPhase pearPhase;
@property(nonatomic) NSTimeInterval pearTimestamp;
@end

@implementation PearLegacyTouch
- (UIWindow *)window { return self.pearWindow; }
- (UIView *)view { return self.pearView; }
- (UITouchPhase)phase { return self.pearPhase; }
- (UITouchType)type { return UITouchTypeDirect; }
- (NSUInteger)tapCount { return 1; }
- (NSTimeInterval)timestamp { return self.pearTimestamp; }
- (CGFloat)force { return self.pearPhase == UITouchPhaseEnded || self.pearPhase == UITouchPhaseCancelled ? 0 : 1; }
- (CGFloat)maximumPossibleForce { return 1; }
- (CGPoint)locationInView:(UIView *)view {
    return view ? [self.pearWindow convertPoint:self.pearPoint toView:view] : self.pearPoint;
}
- (CGPoint)previousLocationInView:(UIView *)view {
    return view ? [self.pearWindow convertPoint:self.pearPrevious toView:view] : self.pearPrevious;
}
- (CGPoint)preciseLocationInView:(UIView *)view { return [self locationInView:view]; }
- (CGPoint)precisePreviousLocationInView:(UIView *)view { return [self previousLocationInView:view]; }
@end

@interface PearLegacyEvent : UIEvent
@property(nonatomic, strong) PearLegacyTouch *pearTouch;
@end
@implementation PearLegacyEvent
- (UIEventType)type { return UIEventTypeTouches; }
- (NSTimeInterval)timestamp { return self.pearTouch.timestamp; }
- (NSSet<UITouch *> *)allTouches { return self.pearTouch ? [NSSet setWithObject:self.pearTouch] : [NSSet set]; }
- (NSSet<UITouch *> *)touchesForWindow:(UIWindow *)window {
    return window == self.pearTouch.window ? self.allTouches : [NSSet set];
}
- (NSSet<UITouch *> *)touchesForView:(UIView *)view {
    return view == self.pearTouch.view ? self.allTouches : [NSSet set];
}
@end

static PearLegacyTouch *gDirectTouch;
static PearLegacyEvent *gDirectEvent;

static BOOL PearLegacyTouchDebug(void) {
    return getenv("PEAR_DEBUG_TOUCH") != NULL;
}

static void PearLogDirectTarget(UIView *view) {
    if (!PearLegacyTouchDebug() || !view) return;
    SEL sel = @selector(touchesBegan:withEvent:);
    IMP impl = class_getMethodImplementation(view.class, sel);
    PearLog(@"[PearRuntime][mouse-touch] direct target=%@ interaction=%d began=%d impl=%p",
            NSStringFromClass(view.class), (int)view.userInteractionEnabled,
            (int)[view respondsToSelector:sel], impl);
}

void PearCancelLegacyDirectTouch(void) {
    if (!gDirectTouch) return;
    gDirectTouch.pearPhase = UITouchPhaseCancelled;
    gDirectTouch.pearTimestamp = NSProcessInfo.processInfo.systemUptime;
    [gDirectTouch.pearView touchesCancelled:gDirectEvent.allTouches withEvent:gDirectEvent];
    gDirectEvent = nil;
    gDirectTouch = nil;
}

// All calls originate from the mouse monitor on the main queue.
void PearSendLegacyDirectTouch(BOOL down, CGFloat nx, CGFloat ny) {
    UIWindow *window = PearPrimaryWindow();
    if (!window || window.bounds.size.width < 1 || window.bounds.size.height < 1) return;
    CGPoint point = CGPointMake(CGRectGetMinX(window.bounds) + nx * window.bounds.size.width,
                                CGRectGetMinY(window.bounds) + ny * window.bounds.size.height);
    if (down && !gDirectTouch) {
        UIView *view = [window hitTest:point withEvent:nil];
        if (!view) {
            PearLog(@"[PearRuntime][mouse-touch] direct hit test returned no view");
            return;
        }
        gDirectTouch = [PearLegacyTouch new];
        gDirectEvent = [PearLegacyEvent new];
        gDirectTouch.pearWindow = window;
        gDirectTouch.pearView = view;
        gDirectTouch.pearPoint = point;
        gDirectTouch.pearPrevious = point;
        gDirectTouch.pearPhase = UITouchPhaseBegan;
        gDirectTouch.pearTimestamp = NSProcessInfo.processInfo.systemUptime;
        gDirectEvent.pearTouch = gDirectTouch;
        if (PearLegacyTouchDebug()) PearLog(@"[PearRuntime][mouse-touch] direct began view=%@ point=%@", NSStringFromClass(view.class), NSStringFromCGPoint(point));
        PearLogDirectTarget(view);
        [view touchesBegan:gDirectEvent.allTouches withEvent:gDirectEvent];
        return;
    }
    if (!gDirectTouch) return;
    UIView *view = gDirectTouch.pearView;
    gDirectTouch.pearPrevious = gDirectTouch.pearPoint;
    gDirectTouch.pearPoint = point;
    gDirectTouch.pearTimestamp = NSProcessInfo.processInfo.systemUptime;
    gDirectTouch.pearPhase = down ? UITouchPhaseMoved : UITouchPhaseEnded;
    if (down) [view touchesMoved:gDirectEvent.allTouches withEvent:gDirectEvent];
    else {
        [view touchesEnded:gDirectEvent.allTouches withEvent:gDirectEvent];
        gDirectEvent = nil;
        gDirectTouch = nil;
    }
}


// Opt-in diagnostic used by the runtime smoke tests: deliver one tap at the
// centre of the reattached legacy window without posting system events.
void PearRunLegacyDirectTouchSelfTest(void) {
    if (!getenv("PEAR_TEST_LEGACY_TOUCH")) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PearLog(@"[PearRuntime][mouse-touch] self-test tap begin");
        PearSendLegacyDirectTouch(YES, 0.5, 0.5);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PearSendLegacyDirectTouch(NO, 0.5, 0.5);
            PearLog(@"[PearRuntime][mouse-touch] self-test tap end");
        });
    });
}
