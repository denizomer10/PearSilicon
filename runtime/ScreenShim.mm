// ScreenShim.mm
//
// Makes `UIScreen.main` describe the app's *window* rather than the whole Mac
// display.
//
// An iOS app windowed on macOS still sees the full display through
// `UIScreen.main`: on a 2560×1440 screen `bounds` reports 2560×1440 while the
// actual window is, say, 1816×1210. Games that size their framebuffer and
// viewport from `UIScreen` then render a 2560×1440 image into a smaller window,
// so the content overflows and looks oversized.
//
// This replaces `UIScreen`'s geometry accessors so they follow the key window
// live — which also means the values track window resizes. Disable with
// PEAR_NO_SCREEN_SHIM.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>

/// Set by the deprecated `UIViewController.interfaceOrientation` override when
/// an app actually reads it. Only those apps cache the launch-time orientation
/// and need the one-shot notification nudge below.
static _Atomic BOOL gInterfaceOrientationRead = NO;

static UIWindow *PearMainWindow(void) {
    UIWindow *first = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (first == nil) first = window;
            if (window.isKeyWindow) return window;
        }
    }
    return first;
}

/// A legacy GL surface can be larger than its window. When the GL shim fits it,
/// it publishes that logical size here so UIScreen and the view agree; touch
/// hit-testing then uses the same coordinate space as the rendered frame.
static CGSize gReportedOverride = {0, 0};

void PearSetScreenOverride(CGSize size) {
    gReportedOverride = size;
}

void PearClearScreenOverride(void) {
    gReportedOverride = CGSizeZero;
}

/// The screen geometry to report: the window's bounds, with the display's scale.
static CGRect PearReportedBounds(void) {
    if (gReportedOverride.width > 0 && gReportedOverride.height > 0) {
        return CGRectMake(0, 0, gReportedOverride.width, gReportedOverride.height);
    }
    UIWindow *window = PearMainWindow();
    if (window && window.bounds.size.width > 0 && window.bounds.size.height > 0) {
        return window.bounds;
    }

    // Before the first scene/window is connected, UIKit can report an empty
    // screen. Engines that build a Metal render target from that size create a
    // zero-width/zero-height texture and abort. Report a conservative
    // landscape surface until the real window is available; the value follows
    // the window immediately afterwards.
    static BOOL loggedFallback = NO;
    if (!loggedFallback) {
        loggedFallback = YES;
        PearLog(@"[PearRuntime][screen] no window yet; reporting 1024x768 fallback");
    }
    return CGRectMake(0, 0, 1024, 768);
}

/// The orientation implied by the app's actual window shape. Used instead of
/// the scene wrapper's stale portrait/landscape flag.
static UIInterfaceOrientation PearDesiredOrientation(void) {
    UIWindow *window = PearMainWindow();
    if (!window) return UIInterfaceOrientationUnknown;
    CGSize size = window.bounds.size;
    if (size.width < 1 || size.height < 1) return UIInterfaceOrientationUnknown;
    if (size.width > size.height + 1) return UIInterfaceOrientationLandscapeLeft;
    if (size.height > size.width + 1) return UIInterfaceOrientationPortrait;
    return UIInterfaceOrientationUnknown;
}

static void PearInstallScreenShim(void) {
    if (NSProcessInfo.processInfo.environment[@"PEAR_NO_SCREEN_SHIM"]) return;
    Class screen = objc_getClass("UIScreen");
    if (!screen) return;

    Method boundsMethod = class_getInstanceMethod(screen, @selector(bounds));
    IMP originalBounds = method_getImplementation(boundsMethod);
    method_setImplementation(boundsMethod, imp_implementationWithBlock(^CGRect(id self) {
        CGRect reported = PearReportedBounds();
        if (!CGRectIsNull(reported)) return reported;
        return ((CGRect (*)(id, SEL))originalBounds)(self, @selector(bounds));
    }));

    Method nativeBoundsMethod = class_getInstanceMethod(screen, @selector(nativeBounds));
    IMP originalNative = method_getImplementation(nativeBoundsMethod);
    method_setImplementation(nativeBoundsMethod, imp_implementationWithBlock(^CGRect(id self) {
        CGRect reported = PearReportedBounds();
        if (!CGRectIsNull(reported)) return reported;
        return ((CGRect (*)(id, SEL))originalNative)(self, @selector(nativeBounds));
    }));

    Method scaleMethod = class_getInstanceMethod(screen, @selector(scale));
    IMP originalScale = method_getImplementation(scaleMethod);
    method_setImplementation(scaleMethod, imp_implementationWithBlock(^CGFloat(id self) {
        if (!CGRectIsNull(PearReportedBounds())) return 1.0;
        return ((CGFloat (*)(id, SEL))originalScale)(self, @selector(scale));
    }));

    Method nativeScaleMethod = class_getInstanceMethod(screen, @selector(nativeScale));
    IMP originalNativeScale = method_getImplementation(nativeScaleMethod);
    method_setImplementation(nativeScaleMethod, imp_implementationWithBlock(^CGFloat(id self) {
        if (!CGRectIsNull(PearReportedBounds())) return 1.0;
        return ((CGFloat (*)(id, SEL))originalNativeScale)(self, @selector(nativeScale));
    }));

    PearLog(@"[PearRuntime][screen] shim installed (UIScreen follows the window)");

    if (NSProcessInfo.processInfo.environment[@"PEAR_NO_ORIENTATION_SHIM"]) {
        PearLog(@"[PearRuntime][screen] orientation shim disabled");
        return;
    }

    // The Mac scene wrapper reports portrait for a landscape window (and vice
    // versa on tall windows). Engines that swap their backbuffer dimensions
    // from the interface orientation then render transposed. Derive the
    // orientation from the actual window instead.
    Method statusMethod = class_getInstanceMethod(UIApplication.class,
                                                   @selector(statusBarOrientation));
    if (statusMethod) {
        IMP originalStatus = method_getImplementation(statusMethod);
        method_setImplementation(statusMethod, imp_implementationWithBlock(^UIInterfaceOrientation(id self) {
            if ([NSThread isMainThread]) {
                UIInterfaceOrientation desired = PearDesiredOrientation();
                if (desired != UIInterfaceOrientationUnknown) return desired;
            }
            return ((UIInterfaceOrientation (*)(id, SEL))originalStatus)(self, @selector(statusBarOrientation));
        }));
    }

    Class sceneClass = objc_getClass("UIWindowScene");
    Method sceneMethod = sceneClass
        ? class_getInstanceMethod(sceneClass, @selector(interfaceOrientation)) : NULL;
    if (sceneMethod) {
        IMP originalScene = method_getImplementation(sceneMethod);
        method_setImplementation(sceneMethod, imp_implementationWithBlock(^UIInterfaceOrientation(id self) {
            if ([NSThread isMainThread]) {
                UIInterfaceOrientation desired = PearDesiredOrientation();
                if (desired != UIInterfaceOrientationUnknown) return desired;
            }
            return ((UIInterfaceOrientation (*)(id, SEL))originalScene)(self, @selector(interfaceOrientation));
        }));
    }

    // Catalyst reports `UIDeviceOrientationUnknown`; a port that treats that
    // as portrait swaps its backbuffer dimensions and renders transposed.
    Method deviceMethod = class_getInstanceMethod(UIDevice.class, @selector(orientation));
    if (deviceMethod) {
        IMP originalDevice = method_getImplementation(deviceMethod);
        method_setImplementation(deviceMethod, imp_implementationWithBlock(^UIDeviceOrientation(id self) {
            if ([NSThread isMainThread]) {
                UIInterfaceOrientation desired = PearDesiredOrientation();
                if (desired == UIInterfaceOrientationLandscapeLeft ||
                    desired == UIInterfaceOrientationLandscapeRight) {
                    return UIDeviceOrientationLandscapeLeft;
                }
                if (desired == UIInterfaceOrientationPortrait) return UIDeviceOrientationPortrait;
            }
            return ((UIDeviceOrientation (*)(id, SEL))originalDevice)(self, @selector(orientation));
        }));
    }

    // Old UIKit code (and MonoGame's iOS backend) reads the view controller's
    // deprecated `interfaceOrientation`, which stays at its launch value.
    Method controllerMethod = class_getInstanceMethod(UIViewController.class,
                                                      @selector(interfaceOrientation));
    if (controllerMethod) {
        IMP originalController = method_getImplementation(controllerMethod);
        method_setImplementation(controllerMethod, imp_implementationWithBlock(^UIInterfaceOrientation(id self) {
            atomic_store(&gInterfaceOrientationRead, YES);
            if ([NSThread isMainThread]) {
                UIInterfaceOrientation desired = PearDesiredOrientation();
                if (desired != UIInterfaceOrientationUnknown) return desired;
            }
            return ((UIInterfaceOrientation (*)(id, SEL))originalController)(self, @selector(interfaceOrientation));
        }));
    }

    PearLog(@"[PearRuntime][screen] interface orientation follows the window");

    // The shim above only helps if the app re-reads the orientation. Titles
    // that cache it during launch keep the launch-time (portrait) value and
    // render a transposed backbuffer. Nudge the normal notification path once
    // the window exists — but only for apps that actually used the deprecated
    // controller property. Broadcasting an orientation change to every app
    // makes UIKit rebuild navigation bars mid-transition; apps that never read
    // the cached value (iMovie) then get stuck laying out nav-bar buttons.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!atomic_load(&gInterfaceOrientationRead)) {
            PearLog(@"[PearRuntime][screen] orientation notification skipped (no cached read)");
            return;
        }
        [[NSNotificationCenter defaultCenter]
            postNotificationName:UIDeviceOrientationDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:UIApplicationDidChangeStatusBarOrientationNotification object:nil];
        PearLog(@"[PearRuntime][screen] posted orientation change");
    });
}

__attribute__((constructor))
static void PearScreenShimInit(void) {
    @autoreleasepool {
        PearInstallScreenShim();
    }
}
