// MetalLayerShim.mm
//
// Keeps an app's visible CAMetalLayer renderable, and makes sure a window that
// renders has a key window to receive input.
//
// Some engines create their CAMetalLayer before the scene has finished
// attaching it. The layer then has no device and a zero drawable size, so the
// engine presents frames into nothing and the window stays black. This shim
// fills in the platform defaults and re-checks while the app is starting. It
// does not replace the engine's rendering, alter shaders, or touch app memory.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import "PearRuntime.h"

static BOOL PearMetalDebug(void) {
    return getenv("PEAR_DEBUG_METAL") != NULL;
}

/// Some engines create a texture from a zero-sized backbuffer before the
/// window exists. Metal's validation then aborts the process. Clamping the
/// descriptor at the public device entry point keeps the validation pass alive;
/// the ordinary window/layer path replaces the size once it is available.
static void PearClampTextureDescriptor(MTLTextureDescriptor *descriptor) {
    if (!descriptor) return;
    if (descriptor.width == 0) {
        descriptor.width = 1;
        if (PearMetalDebug()) PearLog(@"[PearRuntime][metal] clamped zero texture width");
    }
    if (descriptor.height == 0) {
        descriptor.height = 1;
        if (PearMetalDebug()) PearLog(@"[PearRuntime][metal] clamped zero texture height");
    }
}

static void PearInstallTextureGuard(id<MTLDevice> device) {
    if (!device) return;
    static BOOL installed = NO;
    if (installed) return;

    Class cls = [device class];
    SEL plain = @selector(newTextureWithDescriptor:);
    Method method = class_getInstanceMethod(cls, plain);
    if (!method) return;
    installed = YES;

    IMP original = method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^id(id self, MTLTextureDescriptor *descriptor) {
        PearClampTextureDescriptor(descriptor);
        return ((id (*)(id, SEL, id))original)(self, plain, descriptor);
    }));

    SEL offset = @selector(newTextureWithDescriptor:offset:bytesPerRow:);
    Method offsetMethod = class_getInstanceMethod(cls, offset);
    if (offsetMethod) {
        IMP offsetOriginal = method_getImplementation(offsetMethod);
        method_setImplementation(offsetMethod, imp_implementationWithBlock(^
            id(id self, MTLTextureDescriptor *descriptor, NSUInteger byteOffset, NSUInteger bytesPerRow) {
                PearClampTextureDescriptor(descriptor);
                return ((id (*)(id, SEL, id, NSUInteger, NSUInteger))offsetOriginal)(
                    self, offset, descriptor, byteOffset, bytesPerRow
                );
            }
        ));
    }

    SEL iosurface = NSSelectorFromString(@"newTextureWithDescriptor:iosurface:plane:");
    Method surfaceMethod = class_getInstanceMethod(cls, iosurface);
    if (surfaceMethod) {
        IMP surfaceOriginal = method_getImplementation(surfaceMethod);
        method_setImplementation(surfaceMethod, imp_implementationWithBlock(^
            id(id self, MTLTextureDescriptor *descriptor, IOSurfaceRef surface, NSUInteger plane) {
                PearClampTextureDescriptor(descriptor);
                return ((id (*)(id, SEL, id, IOSurfaceRef, NSUInteger))surfaceOriginal)(
                    self, iosurface, descriptor, surface, plane
                );
            }
        ));
    }

    if (PearMetalDebug()) PearLog(@"[PearRuntime][metal] zero-size texture guard installed");
}

static UIWindow *PearKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static UIWindow *PearFirstVisibleWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.rootViewController) return window;
        }
    }
    return nil;
}

/// If the scene rendered a window but never made it key, UIKit will not deliver
/// touches. Making the first visible window key is the same state a normal iOS
/// launch produces.
static void PearEnsureKeyWindow(void) {
    if (PearKeyWindow()) return;
    UIWindow *window = PearFirstVisibleWindow();
    if (!window) return;
    [window makeKeyAndVisible];
    PearLog(@"[PearRuntime][window] promoted %@ to key window", NSStringFromClass(window.class));
}

static void PearFixMetalLayers(void);
static void PearInstallNextDrawableFix(void);

static void PearFixMetalLayers(void) {
    PearInstallNextDrawableFix();
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        if (PearMetalDebug()) {
            PearLog(@"[PearRuntime][metal] MTLCreateSystemDefaultDevice returned nil");
        }
        return;
    }

    PearEnsureKeyWindow();

    NSMutableArray<CALayer *> *stack = [NSMutableArray array];
    NSUInteger windowCount = 0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.layer) [stack addObject:window.layer];
            windowCount++;
        }
    }

    int fixed = 0;
    while (stack.count > 0) {
        CALayer *layer = stack.lastObject;
        [stack removeLastObject];

        if ([layer isKindOfClass:CAMetalLayer.class]) {
            CAMetalLayer *metal = (CAMetalLayer *)layer;
            BOOL changed = NO;

            if (metal.device == nil) {
                metal.device = device;
                changed = YES;
            }

            CGRect bounds = metal.bounds;
            if (bounds.size.width <= 0 || bounds.size.height <= 0) {
                CALayer *host = metal.superlayer;
                bounds = host ? host.bounds : CGRectZero;
                if (bounds.size.width > 0 && bounds.size.height > 0) {
                    metal.bounds = bounds;
                    changed = YES;
                }
            }

            CGFloat scale = metal.contentsScale > 0 ? metal.contentsScale : 1.0;
            CGSize wanted = CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);
            if (metal.drawableSize.width <= 0 || metal.drawableSize.height <= 0) {
                if (wanted.width > 0 && wanted.height > 0) {
                    metal.drawableSize = wanted;
                    changed = YES;
                }
            }

            if (changed) {
                fixed++;
                if (PearMetalDebug()) {
                    PearLog(@"[PearRuntime][metal] normalized %@ bounds=%@ drawable=%@ scale=%.2f device=%@",
                            NSStringFromClass(layer.class), NSStringFromCGRect(metal.bounds),
                            NSStringFromCGSize(metal.drawableSize), scale,
                            metal.device ? @"yes" : @"nil");
                }
            }
        }
        if (layer.sublayers.count) [stack addObjectsFromArray:layer.sublayers];
    }

    if (PearMetalDebug()) {
        PearLog(@"[PearRuntime][metal] scan: %lu window(s), %d layer(s) normalized",
                (unsigned long)windowCount, fixed);
    }
}

/// A layer can be created and asked for a drawable before it is attached to a
/// window, so the periodic scan below cannot see it yet. Setting the device at
/// the moment a drawable is requested closes that window without changing the
/// layer's size or contents.
static void PearInstallNextDrawableFix(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class layerClass = (Class)objc_getClass("CAMetalLayer");
    if (!layerClass) {
        if (PearMetalDebug()) PearLog(@"[PearRuntime][metal] CAMetalLayer not registered yet");
        return;
    }
    SEL selector = NSSelectorFromString(@"nextDrawable");
    Method method = class_getInstanceMethod(layerClass, selector);
    if (!method) {
        if (PearMetalDebug()) PearLog(@"[PearRuntime][metal] CAMetalLayer has no nextDrawable");
        return;
    }
    installed = YES;
    if (PearMetalDebug()) PearLog(@"[PearRuntime][metal] nextDrawable fix installed");

    IMP original = method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^id(id self) {
        CAMetalLayer *layer = (CAMetalLayer *)self;
        if (layer.device == nil) {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            if (device) {
                layer.device = device;
                PearInstallTextureGuard(device);
                if (PearMetalDebug()) {
                    PearLog(@"[PearRuntime][metal] assigned device before nextDrawable");
                }
            }
        }

        // Some engines create their backbuffer textures before the layer has
        // been attached to a window. A zero drawable size makes those textures
        // zero-sized and Metal aborts validation. Seed a conservative size;
        // the periodic window scan replaces it as soon as real bounds exist.
        if (layer.bounds.size.width <= 0 || layer.bounds.size.height <= 0) {
            layer.bounds = CGRectMake(0, 0, 1920, 1080);
        }
        if (layer.drawableSize.width <= 0 || layer.drawableSize.height <= 0) {
            layer.drawableSize = CGSizeMake(1920, 1080);
        }

        return ((id (*)(id, SEL))original)(self, selector);
    }));
}

__attribute__((constructor))
static void PearMetalLayerShimInit(void) {
    if (NSProcessInfo.processInfo.environment[@"PEAR_NO_METAL_FIX"]) return;
    PearInstallTextureGuard(MTLCreateSystemDefaultDevice());
    PearInstallNextDrawableFix();
    // CAMetalLayer may not be registered yet during dyld initializers, and the
    // app's main thread can be busy for a long time while it loads content, so
    // retry from a background queue.
    for (int i = 1; i <= 400; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.05 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool { PearInstallNextDrawableFix(); }
        });
    }
    // The layer and the key window can appear well after the app's first frame,
    // especially when an engine preloads content. Check for a full minute.
    for (int i = 1; i <= 60; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool { PearFixMetalLayers(); }
        });
    }
}
