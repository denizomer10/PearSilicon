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
#import <string.h>
#import <math.h>
#import "PearRuntime.h"

static BOOL PearGLDebug(void);

static void *OpenGLESHandle(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/iOSSupport/System/Library/Frameworks/OpenGLES.framework/OpenGLES",
                        RTLD_NOW | RTLD_GLOBAL);
    });
    return handle;
}

static CGSize gGLDrawableSize = { 0, 0 };
static __weak CALayer *gDrawableLayer;
static int gLastCropViewport[4] = { -1, -1, -1, -1 };
static int gLastPresentViewport[4] = { -1, -1, -1, -1 };
static BOOL gCropApplied = NO;

static void PearFitDrawable(CALayer *layer);

/// Shows only the region the engine actually rendered, stretched to the
/// drawable. Legacy titles keep a design-resolution viewport in the corner of
/// a window-sized framebuffer; cropping to that viewport makes the visible
/// image fill the window, and the same scale aligns touch with what is shown.
/// Opt out with PEAR_NO_GL_VIEWPORT_FIT=1.
static void PearUpdateDrawableCrop(void) {
    if (getenv("PEAR_NO_GL_VIEWPORT_FIT")) return;
    CALayer *layer = gDrawableLayer;
    if (!layer) return;

    // The window can be resized (or rotated) after the renderbuffer was
    // created. Re-fit on every present so the visible scale follows the window;
    // a stale scale makes taps land away from the controls.
    PearFitDrawable(layer);

    typedef void (*PearGetIntegervFn)(int pname, int *params);
    static PearGetIntegervFn getIntegerv;
    if (getIntegerv == NULL) {
        void *handle = OpenGLESHandle();
        getIntegerv = (PearGetIntegervFn)dlsym(handle ? handle : RTLD_DEFAULT, "glGetIntegerv");
    }
    if (getIntegerv == NULL) return;

    int viewport[4] = { 0, 0, 0, 0 };
    getIntegerv(0x0BA2 /* GL_VIEWPORT */, viewport);
    if (viewport[2] <= 0 || viewport[3] <= 0) return;

    int drawableWidth = (int)llround(gGLDrawableSize.width);
    int drawableHeight = (int)llround(gGLDrawableSize.height);
    if (drawableWidth <= 0 || drawableHeight <= 0) return;

    if (PearGLDebug() &&
        (viewport[0] != gLastPresentViewport[0] ||
         viewport[1] != gLastPresentViewport[1] ||
         viewport[2] != gLastPresentViewport[2] ||
         viewport[3] != gLastPresentViewport[3])) {
        memcpy(gLastPresentViewport, viewport, sizeof(viewport));
        PearLog(@"[PearRuntime][gl] present viewport=(%d,%d,%d,%d) drawable=%dx%d",
                viewport[0], viewport[1], viewport[2], viewport[3],
                drawableWidth, drawableHeight);
    }

    BOOL small = drawableWidth >= viewport[2] * 1.4 &&
                 drawableHeight >= viewport[3] * 1.4;

    if (!small) {
        if (!gCropApplied) return;
        gCropApplied = NO;
        gLastCropViewport[0] = -1;
        dispatch_async(dispatch_get_main_queue(), ^{
            CALayer *current = gDrawableLayer;
            if (!current) return;
            current.contentsRect = CGRectMake(0, 0, 1, 1);
        });
        return;
    }

    if (viewport[0] == gLastCropViewport[0] &&
        viewport[1] == gLastCropViewport[1] &&
        viewport[2] == gLastCropViewport[2] &&
        viewport[3] == gLastCropViewport[3]) return;

    memcpy(gLastCropViewport, viewport, sizeof(viewport));
    gCropApplied = YES;

    int top = drawableHeight - (viewport[1] + viewport[3]);
    CGRect rect = CGRectMake((CGFloat)viewport[0] / drawableWidth,
                             (CGFloat)top / drawableHeight,
                             (CGFloat)viewport[2] / drawableWidth,
                             (CGFloat)viewport[3] / drawableHeight);

    if (PearGLDebug()) {
        PearLog(@"[PearRuntime][gl] crop %dx%d at (%d,%d) from drawable %dx%d",
                viewport[2], viewport[3], viewport[0], viewport[1],
                drawableWidth, drawableHeight);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        CALayer *current = gDrawableLayer;
        if (!current) return;
        current.contentsRect = rect;
        current.contentsGravity = kCAGravityResize;
        current.magnificationFilter = kCAFilterLinear;
    });
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

static CGSize gLastFitWindowSize = { 0, 0 };
static CGSize gLastFitLayerSize = { 0, 0 };
static CGFloat gLastFitScale = 0;
static BOOL gFitApplied = NO;

/// If the drawable is larger than the key window, scale the layer visually
/// while leaving its bounds and renderbuffer size untouched. Input continues to
/// arrive in window points, which is the space this class of legacy renderer
/// uses for its hit-testing; transforming the view instead made the game receive
/// 2560-space taps and miss every control.
///
/// This is called on every present, and the window can be resized at any time,
/// so the scale is recomputed from the *current* window bounds and applied on
/// the main queue.
static void PearFitDrawable(CALayer *layer) {
    if (!layer || getenv("PEAR_NO_GL_FIT")) return;
    UIWindow *window = PearGLKeyWindow();
    if (!window) return;

    CGRect windowBounds = window.bounds;
    CGRect layerBounds = layer.bounds;
    if (windowBounds.size.width < 1 || windowBounds.size.height < 1) return;
    if (layerBounds.size.width < 1 || layerBounds.size.height < 1) return;

    BOOL fits = layerBounds.size.width <= windowBounds.size.width * 1.02 &&
                layerBounds.size.height <= windowBounds.size.height * 1.02;
    if (fits) {
        if (!gFitApplied) return;
        gFitApplied = NO;
        gLastFitScale = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            CALayer *current = gDrawableLayer;
            if (!current) return;
            current.transform = CATransform3DIdentity;
            if (current.superlayer) {
                current.position = CGPointMake(CGRectGetMidX(current.superlayer.bounds),
                                               CGRectGetMidY(current.superlayer.bounds));
            }
        });
        return;
    }

    CGFloat scale = MIN(windowBounds.size.width / layerBounds.size.width,
                        windowBounds.size.height / layerBounds.size.height);
    if (gFitApplied &&
        CGSizeEqualToSize(gLastFitWindowSize, windowBounds.size) &&
        CGSizeEqualToSize(gLastFitLayerSize, layerBounds.size) &&
        fabs(gLastFitScale - scale) < 0.001) {
        return;
    }

    gFitApplied = YES;
    gLastFitWindowSize = windowBounds.size;
    gLastFitLayerSize = layerBounds.size;
    gLastFitScale = scale;

    dispatch_async(dispatch_get_main_queue(), ^{
        CALayer *current = gDrawableLayer;
        if (!current) return;
        current.transform = CATransform3DMakeScale(scale, scale, 1);
        if (current.superlayer) {
            current.position = CGPointMake(CGRectGetMidX(current.superlayer.bounds),
                                           CGRectGetMidY(current.superlayer.bounds));
            current.superlayer.backgroundColor = UIColor.blackColor.CGColor;
        }
        window.backgroundColor = UIColor.blackColor;
    });

    if (PearGLDebug()) {
        PearLog(@"[PearRuntime][gl] scaled drawable %@ by %.3f into window %@",
                NSStringFromCGRect(layerBounds), scale, NSStringFromCGRect(windowBounds));
    }
}



#pragma mark - Legacy touch diagnostics

/// Logs touches the legacy GL view receives, before the engine converts them.
/// The stream is what tells a delivery problem from a coordinate-scale problem.
static void PearInstallEAGLTouchLogging(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class viewClass = NSClassFromString(@"EAGLView");
    if (!viewClass) return;
    installed = YES;

    SEL selectors[] = {
        @selector(touchesBegan:withEvent:),
        @selector(touchesEnded:withEvent:)
    };
    for (int i = 0; i < 2; i++) {
        SEL selector = selectors[i];
        Method method = class_getInstanceMethod(viewClass, selector);
        if (!method) continue;
        IMP original = method_getImplementation(method);
        const char *types = method_getTypeEncoding(method);
        IMP replacement = imp_implementationWithBlock(^(id self, NSSet *touches, UIEvent *event) {
            UITouch *touch = touches.anyObject;
            CGPoint point = [touch locationInView:self];
            CGRect bounds = [self bounds];
            PearLog(@"[PearRuntime][touch] %@ point=(%.1f,%.1f) bounds=%@ scale=%.2f",
                    NSStringFromSelector(selector), point.x, point.y,
                    NSStringFromCGRect(bounds), [self contentScaleFactor]);
            ((void (*)(id, SEL, NSSet *, UIEvent *))original)(self, selector, touches, event);
        });
        if (!class_addMethod(viewClass, selector, replacement, types)) {
            method_setImplementation(method, replacement);
        }
    }
    PearLog(@"[PearRuntime][touch] EAGLView touch logging installed");
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
            gGLDrawableSize = CGSizeMake(layer.bounds.size.width * layer.contentsScale,
                                         layer.bounds.size.height * layer.contentsScale);
            gDrawableLayer = layer;
            PearFitDrawable(layer);
        } else if (PearGLDebug()) {
            PearLog(@"[PearRuntime][gl] renderbufferStorage fromDrawable %@", NSStringFromClass([drawable class]));
        }
        return ((BOOL (*)(id, SEL, NSUInteger, id))original)(self, selector, target, drawable);
    }));

    PearLog(@"[PearRuntime][gl] EAGL drawable fit installed");

    // The viewport is only final while the engine is presenting. Reading it
    // here catches both directly linked GL calls and engines that resolve GL
    // through their own table.
    SEL presentSelector = NSSelectorFromString(@"presentRenderbuffer:");
    Method presentMethod = class_getInstanceMethod(context, presentSelector);
    if (presentMethod) {
        IMP presentOriginal = method_getImplementation(presentMethod);
        method_setImplementation(presentMethod, imp_implementationWithBlock(^BOOL(id self, NSUInteger target) {
            PearUpdateDrawableCrop();
            return ((BOOL (*)(id, SEL, NSUInteger))presentOriginal)(self, presentSelector, target);
        }));
        PearLog(@"[PearRuntime][gl] EAGL present hook installed");
    }
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
            PearInstallEAGLTouchLogging();
            PearInstallLegacyTouchLogging();
        });
    }
}
