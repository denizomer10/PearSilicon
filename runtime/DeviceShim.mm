// DeviceShim.mm
//
// Presents one coherent iOS device identity to the loaded app.
//
// A Mac Catalyst process can expose macOS values through several unrelated
// APIs: `sysctl hw.machine`, `uname`, `UIDevice`, and Foundation's operating
// system version. Applications that select a renderer, layout, or feature set
// from those values see a mixture of Mac and iOS facts. This shim makes the
// answers agree.
//
// The values are configurable for diagnostics:
//   PEAR_DEVICE_MODEL      hardware identifier (default iPhone15,2)
//   PEAR_DEVICE_NAME       user-visible model name (default iPhone)
//   PEAR_DEVICE_IDIOM      phone or pad (default phone)
//   PEAR_FAKE_IOS_VERSION  marketing version (default 16.0)
//   PEAR_FAKE_IOS_BUILD    build identifier (default 20A000)
//   PEAR_FAKE_DARWIN       kernel release (default 22.6.0)
//
// Opt out with PEAR_NO_DEVICE_SHIM=1.
//
// This is an environment-consistency layer. It does not inspect, patch, or
// interact with an application's own logic or integrity checks.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <errno.h>
#import <string.h>


static BOOL PearDeviceShimDisabled(void) {
    return getenv("PEAR_NO_DEVICE_SHIM") != NULL;
}

/// C-string variants are used by the sysctl/uname interposers, which can run
/// during libSystem initialization before Foundation is ready. Touching
/// Foundation there once caused a recursive initializer crash.
static const char *PearDeviceModelC(void) {
    const char *value = getenv("PEAR_DEVICE_MODEL");
    return (value && value[0]) ? value : "iPhone15,2";
}

static const char *PearDeviceNameC(void) {
    const char *value = getenv("PEAR_DEVICE_NAME");
    return (value && value[0]) ? value : "iPhone";
}

static const char *PearIOSVersionC(void) {
    const char *value = getenv("PEAR_FAKE_IOS_VERSION");
    return (value && value[0]) ? value : "16.0";
}

static const char *PearIOSBuildC(void) {
    const char *value = getenv("PEAR_FAKE_IOS_BUILD");
    return (value && value[0]) ? value : "20A000";
}

static const char *PearDarwinReleaseC(void) {
    const char *value = getenv("PEAR_FAKE_DARWIN");
    return (value && value[0]) ? value : "22.6.0";
}

static NSString *PearDeviceModel(void) {
    return [NSString stringWithUTF8String:PearDeviceModelC()];
}

static NSString *PearDeviceName(void) {
    return [NSString stringWithUTF8String:PearDeviceNameC()];
}

static NSString *PearIOSVersion(void) {
    return [NSString stringWithUTF8String:PearIOSVersionC()];
}

static NSString *PearIOSBuild(void) {
    return [NSString stringWithUTF8String:PearIOSBuildC()];
}

static NSString *PearDarwinRelease(void) {
    return [NSString stringWithUTF8String:PearDarwinReleaseC()];
}

static BOOL PearWantsPadIdiom(void) {
    const char *value = getenv("PEAR_DEVICE_IDIOM");
    if (!value || !value[0]) return NO;
    return strcasecmp(value, "pad") == 0 || strcasecmp(value, "ipad") == 0;
}

/// The C-string value to report for a sysctl name, or NULL when the real kernel
/// value should be used.
static const char *PearSysctlOverride(const char *name) {
    if (!name) return NULL;
    if (strcmp(name, "hw.machine") == 0 || strcmp(name, "hw.model") == 0
        || strcmp(name, "hw.product") == 0) {
        return PearDeviceModelC();
    }
    // Kernel-version overrides change what system services inside the app see
    // during startup. Keep them behind an explicit switch; hardware identity is
    // the part applications use to select a device profile.
    if (getenv("PEAR_DEVICE_KERNEL")) {
        if (strcmp(name, "kern.osproductversion") == 0) return PearIOSVersionC();
        if (strcmp(name, "kern.osversion") == 0) return PearIOSBuildC();
        if (strcmp(name, "kern.osrelease") == 0) return PearDarwinReleaseC();
    }
    return NULL;
}

/// Writes an override into a caller-provided buffer and returns the same
/// conventions as sysctl: 0 on success, -1 with ENOMEM when the buffer is too
/// small. A size query reports the length required.
static int PearWriteOverride(const char *bytes, void *oldp, size_t *oldlenp) {
    if (!bytes) return -1;
    size_t need = strlen(bytes) + 1;

    if (!oldp) {
        if (oldlenp) *oldlenp = need;
        return 0;
    }
    if (!oldlenp) {
        errno = EFAULT;
        return -1;
    }
    if (*oldlenp < need) {
        *oldlenp = need;
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, bytes, need);
    *oldlenp = need;
    return 0;
}

#pragma mark - sysctlbyname

typedef int (*PearSysctlByNameFn)(const char *, void *, size_t *, void *, size_t);

static int PearSysctlByName(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeSysctlByName
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSysctlByName,
        (const void *)(uintptr_t)&sysctlbyname
};

static int PearSysctlByName(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!PearDeviceShimDisabled()) {
        const char *override = PearSysctlOverride(name);
        if (override) return PearWriteOverride(override, oldp, oldlenp);
    }
    PearSysctlByNameFn original = (PearSysctlByNameFn)kInterposeSysctlByName.replacee;
    return original ? original(name, oldp, oldlenp, newp, newlen) : -1;
}

#pragma mark - sysctl (MIB)

typedef int (*PearSysctlFn)(int *, u_int, void *, size_t *, void *, size_t);

static int PearSysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeSysctl
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSysctl,
        (const void *)(uintptr_t)&sysctl
};

static int PearSysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!PearDeviceShimDisabled() && name && namelen >= 2) {
        if (name[0] == CTL_HW && (name[1] == HW_MACHINE
#ifdef HW_MODEL
                                  || name[1] == HW_MODEL
#endif
                                  )) {
            return PearWriteOverride(PearDeviceModelC(), oldp, oldlenp);
        }
        if (name[0] == CTL_KERN && name[1] == KERN_OSRELEASE && getenv("PEAR_DEVICE_KERNEL")) {
            return PearWriteOverride(PearDarwinReleaseC(), oldp, oldlenp);
        }
    }

    PearSysctlFn original = (PearSysctlFn)kInterposeSysctl.replacee;
    return original ? original(name, namelen, oldp, oldlenp, newp, newlen) : -1;
}

#pragma mark - uname

typedef int (*PearUnameFn)(struct utsname *);

static int PearUname(struct utsname *value);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeUname
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearUname,
        (const void *)(uintptr_t)&uname
};

static int PearUname(struct utsname *value) {
    PearUnameFn original = (PearUnameFn)kInterposeUname.replacee;
    int result = original ? original(value) : -1;
    if (result == 0 && value && !PearDeviceShimDisabled() && getenv("PEAR_DEVICE_UNAME")) {
        strlcpy(value->machine, PearDeviceModelC(), sizeof(value->machine));
        strlcpy(value->release, PearDarwinReleaseC(), sizeof(value->release));
    }
    return result;
}

#pragma mark - UIDevice

static NSUUID *PearSyntheticVendorID(void) {
    static NSUUID *identifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *seed = [NSString stringWithFormat:@"%@:%@",
                          NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
                          PearDeviceModel()];
        // FNV-1a gives a stable 128-bit identifier without linking an extra
        // crypto framework. It is an identifier, not a secret.
        uint64_t h1 = 1469598103934665603ULL;
        uint64_t h2 = 1099511628211ULL;
        const char *bytes = seed.UTF8String;
        for (size_t i = 0; bytes && bytes[i]; i++) {
            h1 = (h1 ^ (unsigned char)bytes[i]) * 1099511628211ULL;
            h2 = (h2 ^ (unsigned char)bytes[i]) * 1469598103934665603ULL;
        }
        uuid_t uuid;
        memcpy(uuid, &h1, sizeof(h1));
        memcpy(uuid + sizeof(h1), &h2, sizeof(h2));
        identifier = [[NSUUID alloc] initWithUUIDBytes:uuid];
    });
    return identifier;
}

static void PearSwizzle(Class cls, SEL selector, IMP replacement) {
    if (!cls || !selector) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (method) method_setImplementation(method, replacement);
}

static void PearInstallDeviceProperties(void) {
    if (PearDeviceShimDisabled()) return;
    if (getenv("PEAR_NO_DEVICE_UI")) return;
    Class device = NSClassFromString(@"UIDevice");
    if (!device) return;

    // Keep the basic identity consistent. The layout idiom and vendor token are
    // opt-in: system services inside a Catalyst app use them to choose a UIKit
    // code path, and forcing the phone idiom there can trip an availability
    // assertion before the app's first scene.
    PearSwizzle(device, @selector(model), imp_implementationWithBlock(^NSString *(id self) {
        return PearDeviceName();
    }));
    PearSwizzle(device, @selector(localizedModel), imp_implementationWithBlock(^NSString *(id self) {
        return PearDeviceName();
    }));
    PearSwizzle(device, @selector(systemName), imp_implementationWithBlock(^NSString *(id self) {
        return @"iOS";
    }));
    PearSwizzle(device, @selector(systemVersion), imp_implementationWithBlock(^NSString *(id self) {
        return PearIOSVersion();
    }));
    PearSwizzle(device, @selector(name), imp_implementationWithBlock(^NSString *(id self) {
        return PearDeviceName();
    }));

    if (getenv("PEAR_DEVICE_UI_DETAILS")) {
        PearSwizzle(device, @selector(identifierForVendor), imp_implementationWithBlock(^NSUUID *(id self) {
            return PearSyntheticVendorID();
        }));
        PearSwizzle(device, @selector(userInterfaceIdiom), imp_implementationWithBlock(^NSInteger(id self) {
            return PearWantsPadIdiom() ? 1 : 0; // pad : phone
        }));
        PearSwizzle(device, @selector(isMultitaskingSupported), imp_implementationWithBlock(^BOOL(id self) {
            return YES;
        }));
    }
}

#pragma mark - Foundation version

static void PearInstallOperatingSystemVersion(void) {
    if (PearDeviceShimDisabled()) return;
    // Foundation's version is also consumed by system services inside the app
    // (for example the app-intent registration path). Reporting an iOS version
    // there can make those services fail an availability assertion, so this is
    // opt-in for diagnostics rather than part of the default identity.
    if (!getenv("PEAR_SPOOF_OS_VERSION")) return;
    Class processInfo = NSClassFromString(@"NSProcessInfo");
    if (!processInfo) return;

    NSArray<NSString *> *parts = [PearIOSVersion() componentsSeparatedByString:@"."];
    NSInteger major = parts.count > 0 ? parts[0].integerValue : 16;
    NSInteger minor = parts.count > 1 ? parts[1].integerValue : 0;
    NSInteger patch = parts.count > 2 ? parts[2].integerValue : 0;

    Method version = class_getInstanceMethod(processInfo, @selector(operatingSystemVersion));
    if (version) {
        method_setImplementation(version, imp_implementationWithBlock(^NSOperatingSystemVersion(id self) {
            return (NSOperatingSystemVersion){ major, minor, patch };
        }));
    }

    Method versionString = class_getInstanceMethod(processInfo, @selector(operatingSystemVersionString));
    if (versionString) {
        method_setImplementation(versionString, imp_implementationWithBlock(^NSString *(id self) {
            return [NSString stringWithFormat:@"Version %@ (Build %@)", PearIOSVersion(), PearIOSBuild()];
        }));
    }

    Method atLeast = class_getInstanceMethod(processInfo, @selector(isOperatingSystemAtLeastVersion:));
    if (atLeast) {
        method_setImplementation(atLeast, imp_implementationWithBlock(^BOOL(id self, NSOperatingSystemVersion requested) {
            if (major != requested.majorVersion) return major > requested.majorVersion;
            if (minor != requested.minorVersion) return minor > requested.minorVersion;
            return patch >= requested.patchVersion;
        }));
    }
}

__attribute__((constructor))
static void PearDeviceShimInit(void) {
    @autoreleasepool {
        if (PearDeviceShimDisabled()) return;
        PearInstallDeviceProperties();
        PearInstallOperatingSystemVersion();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PearLog(@"[PearRuntime][device] identity=%@/%@ model=%@ iOS=%@ build=%@",
                    PearDeviceModel(), PearDeviceName(), PearDeviceName(),
                    PearIOSVersion(), PearIOSBuild());
        });
    }
}
