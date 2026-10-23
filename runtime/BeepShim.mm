// BeepShim.mm
//
// Silences the macOS alert beep for unhandled key events in the loaded app.
//
// An iOS app on the Mac receives hardware key events through UIKitMac/AppKit.
// When neither the app nor a responder handles a key, AppKit plays the system
// alert sound — once per key press, with or without the keymapper. PearSilicon
// should be silent: the loaded process has no business beeping at the user.
//
// This swizzles every zero-argument `…beep…` method on NSApplication (AppKit is
// loaded in these processes by UIKitMacHelper) to a no-op, and interposes the
// C function `NSBeep()` itself: AppKit exposes no `-beep` method, so the C
// entry point is what actually plays the alert. Opt out with PEAR_KEEP_BEEP=1.
// Diagnostics: PEAR_DEBUG_BEEP=1 logs what was found.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

// Linked with AppKit; see runtime/build.sh.
extern "C" void NSBeep(void);

static void PearNoBeep(void) {}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} PearNsBeepInterpose __attribute__((section("__DATA,__interpose"))) = {
    (const void *)&PearNoBeep,
    (const void *)&NSBeep,
};

static BOOL PearBeepDebug(void) {
    return NSProcessInfo.processInfo.environment[@"PEAR_DEBUG_BEEP"] != nil;
}

static void PearSilenceSystemBeeps(void) {
    if (NSProcessInfo.processInfo.environment[@"PEAR_KEEP_BEEP"]) return;

    // UIKitMacHelper links AppKit; loading it here is harmless if already loaded.
    dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY);

    Class application = NSClassFromString(@"NSApplication");
    if (!application) {
        PearLog(@"[PearRuntime][beep] NSApplication not found");
        return;
    }

    NSUInteger swizzled = 0;
    for (Class cls = application; cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = sel_getName(method_getName(methods[i]));
            if (!strcasestr(name, "beep")) continue;
            if (method_getNumberOfArguments(methods[i]) != 2) continue; // self + _cmd

            method_setImplementation(methods[i], imp_implementationWithBlock(^(__unused id self) {}));
            swizzled++;
            if (PearBeepDebug()) {
                PearLog(@"[PearRuntime][beep] silenced %s on %s", name, class_getName(cls));
            }
        }
        free(methods);
    }

    PearLog(@"[PearRuntime][beep] NSBeep interposed; %lu method%s silenced",
            (unsigned long)swizzled, swizzled == 1 ? "" : "s");
}

__attribute__((constructor))
static void PearBeepShimInit(void) {
    @autoreleasepool {
        PearSilenceSystemBeeps();
    }
}
