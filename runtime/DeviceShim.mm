// DeviceShim.mm
//
// Makes `sysctlbyname("hw.machine")` report an iOS device model instead of the
// Mac's.
//
// On arm64 macOS that key returns "arm64". Some engines look it up to
// choose a device profile and refuse to start when it is not a known
// iPhone/iPad model.The
// model can be overridden with PEAR_DEVICE_MODEL.
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <string.h>

static const char *kPearDefaultDeviceModel = "iPhone14,2"; // iPhone 13 Pro

static const char *DeviceModel(void) {
    const char *override = getenv("PEAR_DEVICE_MODEL");
    return (override && override[0]) ? override : kPearDefaultDeviceModel;
}

/// Copies the model string into a sysctl output buffer if it is big enough.
static void WriteDeviceModel(void *oldp, size_t *oldlenp) {
    const char *model = DeviceModel();
    size_t need = strlen(model) + 1;
    if (*oldlenp >= need) {
        memcpy(oldp, model, need);
        *oldlenp = need;
    }
}

/// The length a caller must allocate for `hw.machine`.
static size_t DeviceModelSize(void) {
    return strlen(DeviceModel()) + 1;
}

#pragma mark - sysctlbyname

typedef int (*PearSysctlByNameFn)(const char *, void *, size_t *, void *, size_t);

static int PearSysctlByName(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen);

// dyld fills `replacee` with the original. We must read it from the interpose
// entry: `dlsym(RTLD_NEXT, …)` would return our own replacement and recurse.
__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeSysctlByName
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSysctlByName,
        (const void *)(uintptr_t)&sysctlbyname
};

static int PearSysctlByName(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    PearSysctlByNameFn original = (PearSysctlByNameFn)kInterposeSysctlByName.replacee;
    BOOL isMachine = name && strcmp(name, "hw.machine") == 0;

    if (getenv("PEAR_DEBUG_DEVICE") && name) {
        PearLog(@"[PearRuntime][device] sysctlbyname(%s)", name);
    }

    // A size query (oldp == NULL) must report OUR length, otherwise the caller
    // allocates a buffer sized for the original "arm64" and the later copy does
    // not fit — leaving the caller with "arm64".
    if (isMachine && oldp == NULL) {
        if (oldlenp) *oldlenp = DeviceModelSize();
        return 0;
    }

    int result = original ? original(name, oldp, oldlenp, newp, newlen) : -1;
    if (result == 0 && isMachine && oldp && oldlenp) {
        WriteDeviceModel(oldp, oldlenp);
        if (getenv("PEAR_DEBUG_DEVICE")) {
            PearLog(@"[PearRuntime][device] sysctlbyname(hw.machine) returned '%s' (len %zu)",
                  (const char *)oldp, *oldlenp);
        }
    }
    return result;
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
    PearSysctlFn original = (PearSysctlFn)kInterposeSysctl.replacee;
    BOOL isMachine = name && namelen >= 2 && name[0] == CTL_HW && name[1] == HW_MACHINE;

    if (getenv("PEAR_DEBUG_DEVICE") && name && namelen >= 2) {
        PearLog(@"[PearRuntime][device] sysctl(%d.%d)", name[0], name[1]);
    }

    if (isMachine && oldp == NULL) {
        if (oldlenp) *oldlenp = DeviceModelSize();
        return 0;
    }

    int result = original ? original(name, namelen, oldp, oldlenp, newp, newlen) : -1;
    if (result == 0 && isMachine && oldp && oldlenp) {
        WriteDeviceModel(oldp, oldlenp);
    }
    return result;
}
