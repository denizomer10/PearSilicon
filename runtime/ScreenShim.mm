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

/// The screen geometry to report: the window's bounds, with the display's scale.
static CGRect PearReportedBounds(void) {
    UIWindow *window = PearMainWindow();
    if (window && window.bounds.size.width > 0 && window.bounds.size.height > 0) {
        return window.bounds;
    }
    return CGRectNull;
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
}

__attribute__((constructor))
static void PearScreenShimInit(void) {
    @autoreleasepool {
        PearInstallScreenShim();
    }
}
