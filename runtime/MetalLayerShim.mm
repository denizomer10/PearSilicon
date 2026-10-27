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
#import "PearRuntime.h"

static BOOL PearMetalDebug(void) {
    return getenv("PEAR_DEBUG_METAL") != NULL;
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

static void PearFixMetalLayers(void) {
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

__attribute__((constructor))
static void PearMetalLayerShimInit(void) {
    if (NSProcessInfo.processInfo.environment[@"PEAR_NO_METAL_FIX"]) return;
    // The layer and the key window can appear well after the app's first frame,
    // especially when an engine preloads content. Check for a full minute.
    for (int i = 1; i <= 60; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool { PearFixMetalLayers(); }
        });
    }
}
