// MetalLayerShim.mm
//
// Gives an app's visible CAMetalLayer a Metal device if it does not have one.
//
// Unity's Vulkan/MoltenVK backend on this runtime ends up with the window's
// CAMetalLayer present but `device == nil` (observed with a Unity title).
// A CAMetalLayer without a device can never vend a drawable, so presents go
// nowhere and the window stays black even though the engine keeps presenting
// frames. Assigning the system default device lets the layer work.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

static void PearFixMetalLayers(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        PearLog(@"[PearRuntime][metal] MTLCreateSystemDefaultDevice returned nil");
        return;
    }

    NSMutableArray<CALayer *> *stack = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.layer) [stack addObject:window.layer];
        }
    }

    int fixed = 0;
    while (stack.count > 0) {
        CALayer *layer = stack.lastObject;
        [stack removeLastObject];

        if ([layer isKindOfClass:CAMetalLayer.class]) {
            CAMetalLayer *metal = (CAMetalLayer *)layer;
            if (metal.device == nil) {
                metal.device = device;
                CGFloat scale = metal.contentsScale > 0 ? metal.contentsScale : 1.0;
                if (metal.drawableSize.width <= 0 || metal.drawableSize.height <= 0) {
                    metal.drawableSize = CGSizeMake(metal.bounds.size.width * scale,
                                                    metal.bounds.size.height * scale);
                }
                fixed++;
                PearLog(@"[PearRuntime][metal] assigned device to %@ (bounds=%@ drawableSize=%@ scale=%.2f)",
                      NSStringFromClass(layer.class), NSStringFromCGRect(metal.bounds),
                      NSStringFromCGSize(metal.drawableSize), scale);
            }
        }
        if (layer.sublayers.count) [stack addObjectsFromArray:layer.sublayers];
    }
    PearLog(@"[PearRuntime][metal] scan complete, %d layer(s) fixed", fixed);
}

__attribute__((constructor))
static void PearMetalLayerShimInit(void) {
    if (NSProcessInfo.processInfo.environment[@"PEAR_NO_METAL_FIX"]) return;
    // The layer exists only after the engine has created its surface; retry a
    // few times to catch it whenever it appears.
    for (int i = 1; i <= 6; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool { PearFixMetalLayers(); }
        });
    }
}
