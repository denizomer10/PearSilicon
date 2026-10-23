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

/// Returns NO for every class that implements `prefersPointerLocked`.
static NSMutableSet<NSString *> *gHandledPointerLockClasses = nil;

static NSUInteger PearDisablePointerLock(void) {
    if (NSProcessInfo.processInfo.environment[@"PEAR_ALLOW_POINTER_LOCK"]) return 0;
    if (!gHandledPointerLockClasses) gHandledPointerLockClasses = [NSMutableSet set];

    SEL selector = NSSelectorFromString(@"prefersPointerLocked");
    IMP replacement = imp_implementationWithBlock(^BOOL(id self) {
        (void)self;
        return NO;
    });

    NSUInteger swizzled = 0;
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        NSString *className = @(class_getName(classes[i]));
        if ([gHandledPointerLockClasses containsObject:className]) continue;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int m = 0; m < methodCount; m++) {
            if (sel_isEqual(method_getName(methods[m]), selector)) {
                method_setImplementation(methods[m], replacement);
                [gHandledPointerLockClasses addObject:className];
                swizzled++;
                if (PearPointerDebug()) {
                    PearLog(@"[PearRuntime][pointer] disabled prefersPointerLocked on %s",
                            class_getName(classes[i]));
                }
                break;
            }
        }
        free(methods);
    }
    free(classes);

    if (swizzled > 0) {
        PearLog(@"[PearRuntime][pointer] pointer lock disabled (%lu implementation%s)",
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

        PearDisablePointerLock();

        // The game's view controller (and its preference) may be installed after
        // this constructor runs; re-check shortly after launch and whenever the
        // app becomes active.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PearDisablePointerLock();
            PearRefreshPointerPreference();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PearRefreshPointerPreference();
        });

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
            PearDisablePointerLock();
            PearRefreshPointerPreference();
        }];
    }
}
