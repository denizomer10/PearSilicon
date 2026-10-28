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
/// The size the engine itself created its drawable at. This is the coordinate
/// space its hit-testing uses. It must not follow window resizes: the fit
/// transform is visual only, and allowing the view's bounds to grow with the
/// window makes every touch land in the wrong place (most visible in full
/// screen).
static CGSize gNativeDrawableSize = { 0, 0 };
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

/// The window the app laid its controls out for when it created the drawable.
/// Legacy renderers convert touches with the window's point space, so after a
/// Mac window resize (full screen, zoom) the touch must be reported in this
/// reference space or every control is offset by the difference in scale. The
/// visible image is fitted by the layer transform below.
static CGSize gReferenceWindowSize = { 0, 0 };
/// A window resize animates through intermediate sizes. Recording one of those
/// as the reference would leave every touch slightly offset, so the size only
/// becomes the reference after it has stayed put briefly.
static CGSize gPendingWindowSize = { 0, 0 };
static CFAbsoluteTime gPendingWindowSince = 0;
static BOOL gTouchRemapInstalled = NO;

/// Maps a point in the current window's space back to the coordinate space the
/// app laid its controls out in. The visible content is the native drawable
/// fitted to the current window; the inverse of that fit gives the point in the
/// drawable, and applying the reference fit gives the window point the engine
/// expects. Returns `point` unchanged when no fit/reference is available.
static CGPoint PearRemapWindowPoint(CGPoint point, CGSize currentWindow) {
    CGSize native = gNativeDrawableSize;
    CGSize reference = gReferenceWindowSize;
    if (native.width < 1 || native.height < 1) return point;
    if (reference.width < 1 || reference.height < 1) return point;
    if (currentWindow.width < 1 || currentWindow.height < 1) return point;

    CGFloat currentScale = MIN(currentWindow.width / native.width,
                               currentWindow.height / native.height);
    CGFloat referenceScale = MIN(reference.width / native.width,
                                 reference.height / native.height);
    if (currentScale <= 0 || referenceScale <= 0) return point;
    if (fabs(currentScale - referenceScale) < 0.001 &&
        fabs(currentWindow.width - reference.width) < 0.5 &&
        fabs(currentWindow.height - reference.height) < 0.5) {
        return point;
    }

    CGPoint currentOrigin = CGPointMake((currentWindow.width - native.width * currentScale) * 0.5,
                                        (currentWindow.height - native.height * currentScale) * 0.5);
    CGPoint referenceOrigin = CGPointMake((reference.width - native.width * referenceScale) * 0.5,
                                          (reference.height - native.height * referenceScale) * 0.5);

    CGPoint inDrawable = CGPointMake((point.x - currentOrigin.x) / currentScale,
                                     (point.y - currentOrigin.y) / currentScale);
    return CGPointMake(referenceOrigin.x + inDrawable.x * referenceScale,
                       referenceOrigin.y + inDrawable.y * referenceScale);
}

/// Legacy GL titles ask for `locationInView:window` (or `nil`, which means the
/// window) and divide that point by their design scale. When the Mac window is
/// resized, the view is fitted but that window point is not, so the engine sees
/// a shifted coordinate. Rewrite only the window-space answer; the touch's
/// location in the GL view itself is left untouched.
static void PearInstallTouchRemap(void) {
    if (gTouchRemapInstalled) return;
    Class touchClass = NSClassFromString(@"UITouch");
    if (!touchClass) return;
    SEL selector = @selector(locationInView:);
    Method method = class_getInstanceMethod(touchClass, selector);
    if (!method) return;
    gTouchRemapInstalled = YES;

    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    IMP replacement = imp_implementationWithBlock(^CGPoint(id self, UIView *view) {
        CGPoint point = ((CGPoint (*)(id, SEL, UIView *))original)(self, selector, view);

        // `nil` means window coordinates. A UIWindow (or a root view whose
        // bounds match the window) is the same space for a full-window GL app.
        CGSize windowSize = CGSizeZero;
        if (!view) {
            UIWindow *window = PearGLKeyWindow();
            if (window) windowSize = window.bounds.size;
        } else if ([view isKindOfClass:UIWindow.class]) {
            windowSize = view.bounds.size;
        } else if (view.window &&
                   CGSizeEqualToSize(view.bounds.size, view.window.bounds.size) &&
                   view.layer != gDrawableLayer) {
            windowSize = view.window.bounds.size;
        }
        if (windowSize.width < 1 || windowSize.height < 1) return point;

        CGPoint remapped = PearRemapWindowPoint(point, windowSize);
        if (getenv("PEAR_DEBUG_TOUCH") &&
            (fabs(remapped.x - point.x) > 0.5 || fabs(remapped.y - point.y) > 0.5)) {
            PearLog(@"[PearRuntime][touch] remap window %@: (%.1f,%.1f) -> (%.1f,%.1f)",
                    NSStringFromClass([view class]) ?: @"nil",
                    point.x, point.y, remapped.x, remapped.y);
        }
        return remapped;
    });
    if (!class_addMethod(touchClass, selector, replacement, types)) {
        method_setImplementation(method, replacement);
    }
    PearLog(@"[PearRuntime][touch] window-space touch remap installed");
}

/// Fits the drawable into the key window while keeping the engine's coordinate
/// space intact. The visual size is changed with a layer transform; the layer's
/// bounds stay at the size the engine allocated its renderbuffer at.
///
/// This distinction matters on a window resize (full screen in particular):
/// UIKit autoresizing sets the view's *frame*, and with a transform applied the
/// view then reports `bounds = frame / scale`. The engine keeps hit-testing in
/// its original space while touches start arriving in the inflated one, so
/// every control is offset. Restoring the native bounds on the main queue keeps
/// `locationInView:` in the space the engine was built for, while the transform
/// still makes the frame fill the window.
static void PearFitDrawable(CALayer *layer) {
    if (!layer || getenv("PEAR_NO_GL_FIT")) return;
    CGSize native = gNativeDrawableSize;
    if (native.width < 1 || native.height < 1) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        CALayer *current = gDrawableLayer;
        UIWindow *window = PearGLKeyWindow();
        if (!current || !window) return;

        CGRect windowBounds = window.bounds;
        if (windowBounds.size.width < 1 || windowBounds.size.height < 1) return;

        // Remember the last window the app was actually laid out in. A window
        // that is much larger than the drawable in both axes is the full-screen
        // (or otherwise maximised) form and must not become the reference.
        BOOL fullScreenLike = windowBounds.size.width > native.width * 1.4 &&
                              windowBounds.size.height > native.height * 1.4;
        if (!fullScreenLike) {
            if (gReferenceWindowSize.width < 1) gReferenceWindowSize = windowBounds.size;
            if (!CGSizeEqualToSize(gPendingWindowSize, windowBounds.size)) {
                gPendingWindowSize = windowBounds.size;
                gPendingWindowSince = CFAbsoluteTimeGetCurrent();
            } else if (CFAbsoluteTimeGetCurrent() - gPendingWindowSince > 0.4) {
                gReferenceWindowSize = windowBounds.size;
            }
        }

        // In the windowed form the app keeps following the real window, as it
        // did before the fit. Only the full-screen form is frozen at the last
        // windowed geometry: the app laid its controls out there, and growing
        // UIScreen to the display makes those controls move while the drawable
        // stays native.
        if (fullScreenLike && gReferenceWindowSize.width > 0) {
            PearSetScreenOverride(gReferenceWindowSize);
        } else {
            PearClearScreenOverride();
        }

        // Undo any resize the app (or autoresizing) applied to the view. The
        // renderbuffer still has the native size, so the engine's coordinates
        // must stay native too.
        CGRect bounds = current.bounds;
        if (fabs(bounds.size.width - native.width) > 0.5 ||
            fabs(bounds.size.height - native.height) > 0.5) {
            current.bounds = CGRectMake(0, 0, native.width, native.height);
        }

        CGFloat scale = MIN(windowBounds.size.width / native.width,
                            windowBounds.size.height / native.height);
        if (scale <= 0) return;

        // Re-apply the position even when the scale is unchanged: a window
        // resize can move the view before the next present.
        current.position = current.superlayer
            ? CGPointMake(CGRectGetMidX(current.superlayer.bounds),
                          CGRectGetMidY(current.superlayer.bounds))
            : current.position;

        if (gFitApplied &&
            CGSizeEqualToSize(gLastFitWindowSize, windowBounds.size) &&
            CGSizeEqualToSize(gLastFitLayerSize, native) &&
            fabs(gLastFitScale - scale) < 0.001) {
            return;
        }

        gFitApplied = YES;
        gLastFitWindowSize = windowBounds.size;
        gLastFitLayerSize = native;
        gLastFitScale = scale;

        current.transform = CATransform3DMakeScale(scale, scale, 1);
        if (current.superlayer) current.superlayer.backgroundColor = UIColor.blackColor.CGColor;
        window.backgroundColor = UIColor.blackColor;

        if (PearGLDebug()) {
            PearLog(@"[PearRuntime][gl] fit drawable %@ x%.3f into window %@",
                    NSStringFromCGSize(native), scale, NSStringFromCGRect(windowBounds));
        }
    });
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
            if (gNativeDrawableSize.width < 1 || gNativeDrawableSize.height < 1) {
                gNativeDrawableSize = layer.bounds.size;
                PearInstallTouchRemap();
            } else if ([NSThread isMainThread] &&
                       (fabs(layer.bounds.size.width - gNativeDrawableSize.width) > 0.5 ||
                        fabs(layer.bounds.size.height - gNativeDrawableSize.height) > 0.5)) {
                // The app resized its view (window resize/full screen) and is
                // allocating a new drawable at the inflated size. Keep the
                // renderbuffer and the touch space at the engine's native size;
                // the transform handles the visible size.
                layer.bounds = CGRectMake(0, 0, gNativeDrawableSize.width,
                                          gNativeDrawableSize.height);
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
