// GLShim.mm
//
// macOS's iOSSupport OpenGLES framework does NOT export EAGLGetProcAddress,
// which iOS apps use to resolve OpenGL entry points. When it is missing apps
// fail with "Failed to create OpenGLES context" (OpenGL ES titles do this).
//
// We simply *define* EAGLGetProcAddress in the runtime. The app resolves
// it dynamically (dlsym over the global namespace), so our definition is found,
// and we back it with dlsym so the real GL entry points are returned.
//
// With PEAR_DEBUG_GL it also logs how an app sizes its GL surface — useful for
// "content does not fill the window" problems.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>

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

#pragma mark - Diagnostics (PEAR_DEBUG_GL)

// Most EAGL apps size their renderbuffer with
// `-[EAGLContext renderbufferStorage:fromDrawable:]`, which takes the size from
// the drawable layer. Logging it shows the surface the app actually renders at.
static void PearInstallEAGLDiagnostics(void) {
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
            PearLog(@"[PearRuntime][gl] renderbufferStorage fromDrawable bounds=%@ pos=%@ contentsScale=%.2f",
                    NSStringFromCGRect(layer.bounds), NSStringFromCGPoint(layer.position), layer.contentsScale);
        } else {
            PearLog(@"[PearRuntime][gl] renderbufferStorage fromDrawable %@", NSStringFromClass([drawable class]));
        }
        return ((BOOL (*)(id, SEL, NSUInteger, id))original)(self, selector, target, drawable);
    }));
}

__attribute__((constructor))
static void PearGLDiagnosticsInit(void) {
    if (!getenv("PEAR_DEBUG_GL")) return;
    // The OpenGLES framework (and EAGLContext) loads with the app, so retry.
    for (int i = 0; i < 20; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool { PearInstallEAGLDiagnostics(); }
            });
        });
    }
}
