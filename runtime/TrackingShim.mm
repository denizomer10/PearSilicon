// TrackingShim.mm
//
// Answers the advertising-permission surface locally.
//
// A Mac Catalyst process can call the tracking-permission API but the host does
// not always present the corresponding prompt. The completion handler is then
// never invoked, leaving an app on a loading screen after sign-in. This shim
// reports a stable local decision so the caller can continue; it does not read
// or create an advertising identifier.
//
// Opt out with PEAR_NO_TRACKING_SHIM=1.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "PearRuntime.h"

static Class PearTrackingClass(NSString *className, NSString *framework) {
    Class cls = NSClassFromString(className);
    if (cls) return cls;

    NSString *paths[] = {
        [@"/System/iOSSupport/System/Library/Frameworks" stringByAppendingFormat:@"/%@.framework/%@", framework, framework],
        [@"/System/Library/Frameworks" stringByAppendingFormat:@"/%@.framework/%@", framework, framework],
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        dlopen(paths[i].UTF8String, RTLD_LAZY | RTLD_GLOBAL);
        cls = NSClassFromString(className);
        if (cls) return cls;
    }
    return Nil;
}

static void PearTrackingReplaceClassMethod(Class cls, SEL selector, id block, const char *fallbackTypes) {
    if (!cls || !selector || !block) return;
    Method method = class_getClassMethod(cls, selector);
    IMP imp = imp_implementationWithBlock(block);
    if (method) method_setImplementation(method, imp);
    else class_addMethod(object_getClass(cls), selector, imp, fallbackTypes ?: "v@:");
}

static void PearTrackingReplaceInstanceMethod(Class cls, SEL selector, id block, const char *fallbackTypes) {
    if (!cls || !selector || !block) return;
    Method method = class_getInstanceMethod(cls, selector);
    IMP imp = imp_implementationWithBlock(block);
    if (method) method_setImplementation(method, imp);
    else class_addMethod(cls, selector, imp, fallbackTypes ?: "v@:");
}

static void PearInstallTrackingShim(void) {
    // ATTrackingManagerAuthorizationStatusDenied. Denied is the privacy-safe
    // answer and lets a caller that only waits for a decision proceed.
    Class tracking = PearTrackingClass(@"ATTrackingManager",
                                       @"AppTrackingTransparency");
    if (tracking) {
        PearTrackingReplaceClassMethod(tracking, @selector(trackingAuthorizationStatus),
            ^NSInteger(id self) {
                return 2;
            }, "q@:");
        PearTrackingReplaceClassMethod(tracking, @selector(requestTrackingAuthorizationWithCompletionHandler:),
            ^(id self, void (^completion)(NSInteger)) {
                if (!completion) return;
                dispatch_async(dispatch_get_main_queue(), ^{ completion(2); });
            }, "v@:@?");
    }

    Class identifier = PearTrackingClass(@"ASIdentifierManager", @"AdSupport");
    if (identifier) {
        PearTrackingReplaceInstanceMethod(identifier, @selector(advertisingIdentifier),
            ^id(id self) {
                return [[NSUUID alloc] initWithUUIDString:@"00000000-0000-0000-0000-000000000000"];
            }, "@@:");
        PearTrackingReplaceInstanceMethod(identifier, @selector(isAdvertisingTrackingEnabled),
            ^BOOL(id self) {
                return NO;
            }, "c@:");
    }

    PearLog(@"[PearRuntime][tracking] local permission surface installed");
}

__attribute__((constructor))
static void PearTrackingShimInit(void) {
    if (getenv("PEAR_NO_TRACKING_SHIM")) return;
    @autoreleasepool {
        PearInstallTrackingShim();
    }
}
