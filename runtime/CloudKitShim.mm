// CloudKitShim.mm
//
// Makes CloudKit usable from an ad-hoc signed app.
//
// A signed build gets iCloud through entitlements
// (`com.apple.developer.icloud-container-identifiers`, …), which are restricted:
// they can only be granted by a provisioning profile. An ad-hoc signature cannot
// carry them — if we add them, AMFI refuses to start the process at all
// ("Killed: 9"). Without them, `+[CKContainer containerWithIdentifier:]`
// dereferences the missing entitlement and crashes with SIGSEGV deep inside
// CloudKit (seen with Cult of the Lamb).
//
// The pragmatic fix is to make CloudKit report "no container": we replace the
// container factory so it returns nil, which is the documented way to say the
// container is unavailable. Apps then take their normal "iCloud unavailable"
// path instead of crashing. The trade-off is that iCloud sync is disabled —
// which was never going to work for an ad-hoc build anyway.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static void PearInstallCloudKitStub(void) {
    dlopen("/System/iOSSupport/System/Library/Frameworks/CloudKit.framework/CloudKit",
           RTLD_NOW | RTLD_GLOBAL);

    Class container = objc_getClass("CKContainer");
    if (!container) return;

    SEL sel = @selector(containerWithIdentifier:);
    Method method = class_getClassMethod(container, sel);
    if (!method) return;

    IMP imp = imp_implementationWithBlock(^id(id self, NSString *identifier) {
        PearLog(@"[PearRuntime][cloudkit] containerWithIdentifier:%@ -> nil (no iCloud entitlement)",
              identifier);
        return nil;
    });
    method_setImplementation(method, imp);

    // `defaultContainer` has the same problem for apps that use it.
    Method defaultMethod = class_getClassMethod(container, @selector(defaultContainer));
    if (defaultMethod) {
        IMP defaultImp = imp_implementationWithBlock(^id(id self) {
            PearLog(@"[PearRuntime][cloudkit] defaultContainer -> nil (no iCloud entitlement)");
            return nil;
        });
        method_setImplementation(defaultMethod, defaultImp);
    }
}

__attribute__((constructor))
static void PearCloudKitShimInit(void) {
    if (NSProcessInfo.processInfo.environment[@"PEAR_NO_CLOUDKIT_STUB"]) return;
    @autoreleasepool {
        PearInstallCloudKitStub();
    }
}
