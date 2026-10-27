// GLShim.mm
//
// macOS's iOSSupport OpenGLES framework does NOT export EAGLGetProcAddress,
// which iOS apps use to resolve OpenGL entry points. When it is missing apps
// fail with "Failed to create OpenGLES context" (OpenGL ES titles do this).
//
// We define EAGLGetProcAddress in the runtime. The app resolves it dynamically
// (dlsym over the global namespace), so our definition is found, and we back it
// with dlsym so the real GL entry points are returned.
//
// The same module also clamps an EAGL drawable that was sized from the whole
// display to the app's key window. Older titles can create their GL surface
// before the window is attached and never resize it; the result is a rendered
// image larger than the window, with the bottom/right clipped. Opt out with
// PEAR_NO_GL_FIT=1. With PEAR_DEBUG_GL it logs how an app sizes its GL surface.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "PearRuntime.h"

static void *OpenGLESHandle(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/iOSSupport/System/Library/Frameworks/OpenGLES.framework/OpenGLES",
                        RTLD_NOW | RTLD_GLOBAL);
    });
    return handle;
}

extern "C" void *EAGLGetProcAddress(const char *name) {
    if (name == NULL) return NULL;

    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol == NULL) {
        void *handle = OpenGLESHandle();
        if (handle) symbol = dlsym(handle, name);
    }
    if (symbol == NULL) {
        PearLog(@"[PearRuntime][gl] EAGLGetProcAddress(%s) -> NOT FOUND", name);
    }
    return symbol;
}

#pragma mark - Drawable fit

static BOOL PearGLDebug(void) {
    return getenv("PEAR_DEBUG_GL") != NULL;
}

static UIWindow *PearGLKeyWindow(void) {
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

/// If the drawable is larger than the key window, scale the layer visually
/// while leaving its bounds and renderbuffer size untouched. Input continues to
/// arrive in window points, which is the space this class of legacy renderer
/// uses for its hit-testing; transforming the view instead made the game receive
/// 2560-space taps and miss every control.
static void PearFitDrawable(CALayer *layer) {
    if (!layer || getenv("PEAR_NO_GL_FIT")) return;
    UIWindow *window = PearGLKeyWindow();
    if (!window) return;

    CGRect windowBounds = window.bounds;
    CGRect layerBounds = layer.bounds;
    if (windowBounds.size.width < 1 || windowBounds.size.height < 1) return;
    if (layerBounds.size.width < 1 || layerBounds.size.height < 1) return;
    if (layerBounds.size.width <= windowBounds.size.width * 1.02 &&
        layerBounds.size.height <= windowBounds.size.height * 1.02) {
        return;
    }

    CGFloat scale = MIN(windowBounds.size.width / layerBounds.size.width,
                        windowBounds.size.height / layerBounds.size.height);
    layer.transform = CATransform3DMakeScale(scale, scale, 1);
    if (layer.superlayer) {
        layer.position = CGPointMake(CGRectGetMidX(layer.superlayer.bounds),
                                     CGRectGetMidY(layer.superlayer.bounds));
        layer.superlayer.backgroundColor = UIColor.blackColor.CGColor;
    }
    window.backgroundColor = UIColor.blackColor;

    if (PearGLDebug()) {
        PearLog(@"[PearRuntime][gl] scaled drawable %@ by %.3f into window %@",
                NSStringFromCGRect(layerBounds), scale, NSStringFromCGRect(windowBounds));
    }
}



#pragma mark - EAGL hook

// Most EAGL apps size their renderbuffer with
// `-[EAGLContext renderbufferStorage:fromDrawable:]`, which takes the size from
// the drawable layer. Fixing the layer before the call makes the renderbuffer
// match the window; logging it shows the surface the app actually renders at.
static void PearInstallEAGLHook(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class context = NSClassFromString(@"EAGLContext");
    if (!context) return;
    SEL selector = NSSelectorFromString(@"renderbufferStorage:fromDrawable:");
    Method method = class_getInstanceMethod(context, selector);
    if (!method) return;
    installed = YES;

    IMP original = method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^BOOL(id self, NSUInteger target, id drawable) {
        if ([drawable isKindOfClass:CALayer.class]) {
            CALayer *layer = (CALayer *)drawable;
            if (PearGLDebug()) {
                PearLog(@"[PearRuntime][gl] renderbufferStorage fromDrawable bounds=%@ pos=%@ contentsScale=%.2f",
                        NSStringFromCGRect(layer.bounds), NSStringFromCGPoint(layer.position), layer.contentsScale);
            }
            PearFitDrawable(layer);
        } else if (PearGLDebug()) {
            PearLog(@"[PearRuntime][gl] renderbufferStorage fromDrawable %@", NSStringFromClass([drawable class]));
        }
        return ((BOOL (*)(id, SEL, NSUInteger, id))original)(self, selector, target, drawable);
    }));

    PearLog(@"[PearRuntime][gl] EAGL drawable fit installed");
}

#pragma mark - Legacy touch diagnostics

/// Logs the coordinates the legacy view hands to its engine. The engine's
/// `createZUITouch:withIndex:` is an interface point; observing its input and
/// output shows whether a mismatch is in UIKit delivery or in the engine's own
/// coordinate conversion.
static void PearInstallLegacyTouchLogging(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class viewClass = NSClassFromString(@"OpenGLView");
    if (!viewClass) return;
    SEL selector = NSSelectorFromString(@"createZUITouch:withIndex:");
    Method method = class_getInstanceMethod(viewClass, selector);
    if (!method) return;
    installed = YES;

    Ivar widthIvar = class_getInstanceVariable(viewClass, "m_width");
    Ivar heightIvar = class_getInstanceVariable(viewClass, "m_height");
    Ivar scaleIvar = class_getInstanceVariable(viewClass, "m_contentScale");
    IMP original = method_getImplementation(method);

    method_setImplementation(method, imp_implementationWithBlock(^void *(id self, UITouch *touch, int index) {
        CGPoint point = [touch locationInView:self];
        CGRect bounds = [self bounds];
        int width = widthIvar ? *(int *)((char *)(__bridge void *)self + ivar_getOffset(widthIvar)) : 0;
        int height = heightIvar ? *(int *)((char *)(__bridge void *)self + ivar_getOffset(heightIvar)) : 0;
        float contentScale = scaleIvar
            ? *(float *)((char *)(__bridge void *)self + ivar_getOffset(scaleIvar)) : 0;

        void *zTouch = ((void *(*)(id, SEL, UITouch *, int))original)(self, selector, touch, index);
        float zx = 0, zy = 0;
        if (zTouch) {
            zx = *(float *)((char *)zTouch + 0xc);
            zy = *(float *)((char *)zTouch + 0x10);
        }
        PearLog(@"[PearRuntime][legacytouch] view=%@ bounds=%@ point=(%.1f,%.1f) "
                "m=%dx%d scale=%.2f index=%d -> z=(%.4f,%.4f) phase=%ld",
                NSStringFromClass([self class]), NSStringFromCGRect(bounds), point.x, point.y,
                width, height, contentScale, index, zx, zy, (long)touch.phase);
        return zTouch;
    }));

    PearLog(@"[PearRuntime][legacytouch] diagnostics installed");
}

__attribute__((constructor))
static void PearGLShimInit(void) {
    // The OpenGLES framework (and EAGLContext) loads with the app, so retry.
    for (int i = 0; i < 40; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool { PearInstallEAGLHook(); }
            });
        });
    }
    if (getenv("PEAR_DEBUG_TOUCH")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PearInstallLegacyTouchLogging();
        });
    }
}
