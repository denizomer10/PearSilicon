// In-memory UIKit test. It creates no visible window or system input events.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "../runtime/include/PearRuntime.h"
#import <assert.h>
// Links the Rust runtime's smoke build (scripts/build-smoke-runtime.sh): the
// production input/legacy_touch.rs with the window lookup and GL touch mapping
// replaced through its test hooks (pear-catalyst/src/smoke.rs).
extern void PearSendLegacyDirectTouch(BOOL down, CGFloat nx, CGFloat ny);
extern void PearCancelLegacyDirectTouch(void);
extern "C" void PearSmokeLegacyTouchInit(void);
extern "C" void PearSmokeSetPrimaryWindow(UIWindow *(*)(void));
extern "C" void PearSmokeSetGLMapTouchPoint(CGPoint (*)(UITouch *, UIView *, CGPoint));
static UIWindow *gWindow;
static UIWindow *FakePrimaryWindow(void) { return gWindow; }
static BOOL gMapTouch;
static CGPoint FakeGLMapTouchPoint(UITouch *touch, UIView *view, CGPoint point) {
    assert(touch.view != nil);
    return gMapTouch ? CGPointMake(point.x * 0.5, point.y * 0.5) : point;
}

@interface PearSpyView : NSObject
@property(nonatomic) int beganCount;
@property(nonatomic) int movedCount;
@property(nonatomic) int endedCount;
@property(nonatomic) int cancelledCount;
@property(nonatomic) CGPoint observed;
@property(nonatomic) UITouch *identity;
@end
@implementation PearSpyView
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.beganCount++; self.identity = touches.anyObject;
    assert(event.allTouches.count == 1 && self.identity.phase == UITouchPhaseBegan);
    self.observed = [self.identity locationInView:nil];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.movedCount++; assert(touches.anyObject == self.identity && self.identity.phase == UITouchPhaseMoved);
    self.observed = [self.identity locationInView:nil];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.endedCount++; assert(touches.anyObject == self.identity && self.identity.phase == UITouchPhaseEnded);
    self.observed = [self.identity locationInView:nil];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.cancelledCount++; assert(touches.anyObject.phase == UITouchPhaseCancelled);
}
@end
@interface PearFakeWindow : NSObject
@property(nonatomic, strong) PearSpyView *spy;
@end
@implementation PearFakeWindow
- (CGRect)bounds { return CGRectMake(0, 0, 800, 600); }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return (UIView *)(id)self.spy; }
@end
int main(void) {
    @autoreleasepool {
        PearSmokeLegacyTouchInit();
        PearSmokeSetPrimaryWindow(FakePrimaryWindow);
        PearSmokeSetGLMapTouchPoint(FakeGLMapTouchPoint);
        PearFakeWindow *window = [PearFakeWindow new];
        window.spy = [PearSpyView new]; gWindow = (UIWindow *)(id)window;
        PearSendLegacyDirectTouch(YES, 0.25, 0.5);
        assert(window.spy.beganCount == 1 && window.spy.observed.x == 200 && window.spy.observed.y == 300);
        PearSendLegacyDirectTouch(YES, 0.5, 0.75);
        assert(window.spy.movedCount == 1 && window.spy.observed.x == 400 && window.spy.observed.y == 450);
        PearSendLegacyDirectTouch(NO, 0.75, 1.0);
        assert(window.spy.endedCount == 1 && window.spy.observed.x == 600 && window.spy.observed.y == 600);
        PearSendLegacyDirectTouch(YES, 0.5, 0.5);
        PearCancelLegacyDirectTouch();
        assert(window.spy.beganCount == 2 && window.spy.cancelledCount == 1 && window.spy.endedCount == 1);
        // The synthetic UITouch subclass must use the same renderer mapping as
        // native touches; a base UITouch swizzle alone cannot intercept it.
        gMapTouch = YES;
        PearSendLegacyDirectTouch(YES, 0.5, 0.5);
        assert(window.spy.observed.x == 200 && window.spy.observed.y == 150);
        PearSendLegacyDirectTouch(YES, 0.75, 1.0);
        assert(window.spy.observed.x == 300 && window.spy.observed.y == 300);
        CGPoint previous = [window.spy.identity previousLocationInView:nil];
        assert(previous.x == 200 && previous.y == 150);
        assert(CGPointEqualToPoint([window.spy.identity preciseLocationInView:nil], window.spy.observed));
        PearSendLegacyDirectTouch(NO, 0.75, 1.0);
        puts("PASS: in-memory legacy touch begin, move, end, cancellation and coordinates");
    }
}
