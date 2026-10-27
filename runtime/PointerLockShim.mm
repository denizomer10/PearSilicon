// PointerLockShim.mm
//
// Disables iPadOS pointer lock for the loaded app.
// Opt out with PEAR_ALLOW_POINTER_LOCK=1 (for a game that genuinely wants a
// locked pointer). Diagnostics: PEAR_DEBUG_POINTER=1 logs the classes touched.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static BOOL PearPointerDebug(void) {
    return NSProcessInfo.processInfo.environment[@"PEAR_DEBUG_POINTER"] != nil;
}

/// Returns NO for every view-controller class in the live hierarchy that
/// implements `prefersPointerLocked`.
///
/// Deliberately does not call `objc_copyClassList`: some engines have class
/// metadata that can only be realized after their own launch path, and walking
/// the whole list during startup crashes inside the Objective-C runtime. The
/// live controller chain is the only place the preference matters.
static NSMutableSet<NSValue *> *gHandledPointerLockMethods = nil;

static NSUInteger PearDisablePointerLock(void) {
    if (NSProcessInfo.processInfo.environment[@"PEAR_ALLOW_POINTER_LOCK"]) return 0;
    if (!gHandledPointerLockMethods) gHandledPointerLockMethods = [NSMutableSet set];

    SEL selector = NSSelectorFromString(@"prefersPointerLocked");
    IMP replacement = imp_implementationWithBlock(^BOOL(id self) {
        (void)self;
        return NO;
    });

    __block NSUInteger swizzled = 0;
    __block void (^visit)(UIViewController *) = nil;
    visit = ^(UIViewController *controller) {
        if (!controller) return;
        Class cls = object_getClass(controller);
        Method method = class_getInstanceMethod(cls, selector);
        if (method) {
            NSValue *key = [NSValue valueWithPointer:method];
            if (![gHandledPointerLockMethods containsObject:key]) {
                method_setImplementation(method, replacement);
                [gHandledPointerLockMethods addObject:key];
                swizzled++;
                if (PearPointerDebug()) {
                    PearLog(@"[PearRuntime][pointer] disabled prefersPointerLocked on %s",
                            class_getName(cls));
                }
            }
        }
        for (UIViewController *child in controller.childViewControllers) visit(child);
        if (controller.presentedViewController) visit(controller.presentedViewController);
    };

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            visit(window.rootViewController);
        }
    }

    if (swizzled > 0) {
        PearLog(@"[PearRuntime][pointer] pointer lock disabled (%lu method%s)",
                (unsigned long)swizzled, swizzled == 1 ? "" : "s");
    }
    return swizzled;
}

/// Asks UIKit to read the preference again on the live view controller chain.
static void PearRefreshPointerPreference(void) {
    SEL update = NSSelectorFromString(@"setNeedsUpdateOfPrefersPointerLocked");
    __block NSUInteger updated = 0;

    __block void (^visit)(UIViewController *) = nil;
    visit = ^(UIViewController *controller) {
        if (!controller) return;
        if ([controller respondsToSelector:update]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, update);
            updated++;
        }
        for (UIViewController *child in controller.childViewControllers) visit(child);
        if (controller.presentedViewController) visit(controller.presentedViewController);
    };

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            visit(window.rootViewController);
        }
    }

    if (PearPointerDebug()) {
        PearLog(@"[PearRuntime][pointer] refresh requested on %lu controller%s", (unsigned long)updated,
                updated == 1 ? "" : "s");
    }
}

__attribute__((constructor))
static void PearPointerLockShimInit(void) {
    @autoreleasepool {
        if (NSProcessInfo.processInfo.environment[@"PEAR_ALLOW_POINTER_LOCK"]) return;

        // Do not walk the Objective-C class list from a dyld initializer: Swift
        // classes may not be realized yet, and some apps have metadata that is
        // only safe after the runtime has finished loading images. The first
        // launch callback is early enough for a user click.
        for (int i = 1; i <= 4; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.75 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                PearDisablePointerLock();
                PearRefreshPointerPreference();
            });
        }

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
            PearDisablePointerLock();
            PearRefreshPointerPreference();
        }];
    }
}
