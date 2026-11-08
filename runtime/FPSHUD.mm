// FPSHUD.mm
//
// Lightweight FPS overlay for iOS games that render through OpenGL ES.
// Metal's own HUD (MTL_HUD_ENABLED) cannot observe an EAGL swap chain, so the
// runtime counts presents and draws a small, non-interactive overlay instead.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <atomic>
#import "PearRuntime.h"

static std::atomic<uint64_t> gPresentedFrames{0};
static UIView *gFPSHUDRoot = nil;
static __weak UIWindow *gFPSHUDHost = nil;
static UILabel *gFPSHUDLabel = nil;
static dispatch_source_t gFPSHUDTimer = nil;
static uint64_t gFPSHUDLastFrames = 0;
static CFTimeInterval gFPSHUDLastSample = 0;

/// Called from the EAGL `presentRenderbuffer:` hook. Cheap enough for the
/// render thread: one relaxed atomic increment per presented frame.
void PearRecordFramePresented(void) {
    gPresentedFrames.fetch_add(1, std::memory_order_relaxed);
}

static void PearPlaceFPSHUD(void) {
    if (!gFPSHUDRoot || !gFPSHUDLabel) return;
    CGRect bounds = gFPSHUDRoot.bounds;
    if (CGRectIsEmpty(bounds)) return;
    const CGFloat width = 112, height = 30, margin = 12;
    gFPSHUDLabel.frame = CGRectMake(bounds.size.width - width - margin,
                                    margin, width, height);
}

static void PearInstallFPSHUDOverlay(void) {
    if (gFPSHUDRoot) return;
    // Only OpenGL ES titles present through the EAGL hook. Waiting for a real
    // frame keeps the overlay off Metal apps, where MTL_HUD_ENABLED is used.
    if (gPresentedFrames.load(std::memory_order_relaxed) == 0) return;
    UIWindow *host = PearPrimaryWindow();
    if (!host) return;

    CGRect bounds = host.bounds;
    if (CGRectIsEmpty(bounds)) bounds = UIScreen.mainScreen.bounds;
    if (CGRectIsEmpty(bounds)) return;

    // A sibling subview inside the game window is important: a separate
    // UIWindow can become the touch target and swallow clicks even when it is
    // non-interactive. A passthrough subview lets hit-testing continue to the
    // game view underneath.
    UIView *root = [[UIView alloc] initWithFrame:bounds];
    root.backgroundColor = UIColor.clearColor;
    root.userInteractionEnabled = NO;
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = @"FPS --";
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = UIColor.systemGreenColor;
    label.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.58];
    label.layer.cornerRadius = 8.0;
    label.layer.masksToBounds = YES;
    label.layer.borderWidth = 0.5;
    label.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    label.userInteractionEnabled = NO;
    label.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    label.accessibilityLabel = @"Frames per second";
    [root addSubview:label];

    [host addSubview:root];
    [host bringSubviewToFront:root];

    gFPSHUDRoot = root;
    gFPSHUDHost = host;
    gFPSHUDLabel = label;
    PearPlaceFPSHUD();
    gFPSHUDLastFrames = gPresentedFrames.load(std::memory_order_relaxed);
    gFPSHUDLastSample = CACurrentMediaTime();

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                              500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        if (!gFPSHUDLabel) return;
        if (gFPSHUDHost) [gFPSHUDHost bringSubviewToFront:gFPSHUDRoot];
        CFTimeInterval now = CACurrentMediaTime();
        uint64_t frames = gPresentedFrames.load(std::memory_order_relaxed);
        CFTimeInterval elapsed = now - gFPSHUDLastSample;
        double fps = elapsed > 0.05 ? (double)(frames - gFPSHUDLastFrames) / elapsed : 0.0;
        gFPSHUDLabel.text = [NSString stringWithFormat:@"FPS %.0f", fps];
        gFPSHUDLastFrames = frames;
        gFPSHUDLastSample = now;
        PearPlaceFPSHUD();
    });
    gFPSHUDTimer = timer;
    dispatch_resume(timer);

    PearLog(@"[PearRuntime][hud] FPS overlay installed (OpenGL ES)");
}

static void PearAttemptFPSHUD(int remaining) {
    if (gFPSHUDRoot || remaining <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (gFPSHUDRoot) return;
        PearInstallFPSHUDOverlay();
        if (!gFPSHUDRoot) PearAttemptFPSHUD(remaining - 1);
    });
}

void PearInstallFPSHUD(void) {
    if (!NSProcessInfo.processInfo.environment[@"PEAR_FPS_HUD"].boolValue) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The key window may not exist yet when the runtime bootstraps, and a
        // locked or background desktop can delay it well past the first retry
        // window. Retry again when the app becomes active or a window becomes
        // key so the HUD still appears after the user returns.
        PearAttemptFPSHUD(120);
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                PearAttemptFPSHUD(20);
            }];
        [center addObserverForName:UIWindowDidBecomeKeyNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                PearAttemptFPSHUD(20);
            }];
    });
}
