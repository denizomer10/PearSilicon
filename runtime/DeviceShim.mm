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
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <ifaddrs.h>
#import <net/if_dl.h>
#import <sys/socket.h>
#import <errno.h>
#import <string.h>
#import "PearDeviceProfile.h"

// IOKit is present in the process through Metal and the graphics stack. These
// declarations avoid a link-time dependency on the framework while still
// letting the interposer see the platform-expert properties.
typedef mach_port_t io_object_t;
typedef io_object_t io_registry_entry_t;
typedef uint32_t IOOptionBits;
extern "C" CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key,
                                                 CFAllocatorRef allocator, IOOptionBits options);
extern "C" CFTypeRef IORegistryEntrySearchCFProperty(io_registry_entry_t entry, const char *plane,
                                                  CFStringRef key, CFAllocatorRef allocator,
                                                  IOOptionBits options);
extern "C" kern_return_t IORegistryEntryCreateCFProperties(io_registry_entry_t entry,
                                                       CFMutableDictionaryRef *properties,
                                                       CFAllocatorRef allocator,
                                                       IOOptionBits options);
extern "C" boolean_t IOObjectConformsTo(io_object_t object, const char *className);
extern "C" CFTypeRef IOPSCopyPowerSourcesInfo(void);
typedef mach_port_t io_iterator_t;
extern "C" kern_return_t IOServiceGetMatchingServices(mach_port_t mainPort, CFDictionaryRef matching,
                                                 io_iterator_t *existing);
extern "C" io_object_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching);

typedef struct {
    const void *replacement;
    const void *replacee;
} PearInterposeEntry;


static BOOL PearDeviceShimDisabled(void) {
    return getenv("PEAR_NO_DEVICE_SHIM") != NULL;
}

/// These run in early sysctl/uname paths. The shared snapshot is pure C and
/// never contacts the host or touches Foundation, even on its first access.
/// NULL means an unavailable snapshot, not permission to pick field defaults.
static const char *PearDeviceModelC(void) { return PearDeviceProfileGet()->model; }
static const char *PearDeviceNameC(void) { return PearDeviceProfileGet()->name; }
static const char *PearIOSVersionC(void) { return PearDeviceProfileGet()->systemVersion; }
static const char *PearIOSBuildC(void) { return PearDeviceProfileGet()->systemBuild; }
static const char *PearDarwinReleaseC(void) { return PearDeviceProfileGet()->darwinRelease; }

static NSString *PearDeviceModel(void) {
    const char *text = PearDeviceModelC();
    return text ? [NSString stringWithUTF8String:text] : nil;
}

static NSString *PearDeviceName(void) {
    const char *text = PearDeviceNameC();
    return text ? [NSString stringWithUTF8String:text] : nil;
}

static NSString *PearIOSVersion(void) {
    const char *text = PearIOSVersionC();
    return text ? [NSString stringWithUTF8String:text] : nil;
}

static NSString *PearIOSBuild(void) {
    const char *text = PearIOSBuildC();
    return text ? [NSString stringWithUTF8String:text] : nil;
}

static NSString *PearDarwinRelease(void) {
    const char *text = PearDarwinReleaseC();
    return text ? [NSString stringWithUTF8String:text] : nil;
}

static BOOL PearWantsPadIdiom(void) {
    const char *idiom = PearDeviceProfileGet()->idiom;
    return idiom && !strcmp(idiom, "pad");
}

/// Typed override for one device fact. A text value is NUL-terminated; a
/// numeric value has `size` 4 or 8 bytes.
typedef struct {
    const char *text;
    uint64_t number;
    size_t size;
} PearDeviceValue;

static uint64_t PearStableHash(const char *text, uint64_t seed) {
    uint64_t hash = seed;
    for (size_t i = 0; text && text[i]; i++) {
        hash = (hash ^ (unsigned char)text[i]) * 1099511628211ULL;
    }
    return hash;
}

/// Returns the iOS-looking value for a hardware or kernel fact.
static BOOL PearDeviceValueForName(const char *name, PearDeviceValue *value) {
    if (!name || !value) return NO;
    memset(value, 0, sizeof(*value));

    if (!strcmp(name, "hw.machine") || !strcmp(name, "hw.model")
        || !strcmp(name, "hw.product") || !strcmp(name, "hw.targettype")) {
        value->text = PearDeviceModelC();
        return value->text != NULL;
    }
    if (!strcmp(name, "hw.machinearch")) { value->text = "arm64"; return YES; }
    if (!strcmp(name, "hw.memsize")) {
        value->number = 6ULL * 1024 * 1024 * 1024; // A16 device class
        value->size = sizeof(uint64_t);
        return YES;
    }
    if (!strcmp(name, "hw.ncpu") || !strcmp(name, "hw.physicalcpu")
        || !strcmp(name, "hw.logicalcpu") || !strcmp(name, "hw.physicalcpu_max")
        || !strcmp(name, "hw.logicalcpu_max")) {
        value->number = 6;
        value->size = sizeof(uint32_t);
        return YES;
    }
    if (!strcmp(name, "hw.pagesize")) {
        value->number = 16384;
        value->size = sizeof(uint32_t);
        return YES;
    }
    if (!strcmp(name, "hw.cpufrequency") || !strcmp(name, "hw.cpufrequency_max")
        || !strcmp(name, "hw.cpufrequency_min")) {
        value->number = 3460000000ULL;
        value->size = sizeof(uint64_t);
        return YES;
    }
    if (!strcmp(name, "hw.l1icachesize") || !strcmp(name, "hw.l1dcachesize")) {
        value->number = 131072;
        value->size = sizeof(uint32_t);
        return YES;
    }
    if (!strcmp(name, "hw.l2cachesize")) {
        value->number = 16777216;
        value->size = sizeof(uint32_t);
        return YES;
    }
    if (!strcmp(name, "hw.l3cachesize")) {
        value->number = 0;
        value->size = sizeof(uint32_t);
        return YES;
    }
    if (!strcmp(name, "hw.cachelinesize")) {
        value->number = 128;
        value->size = sizeof(uint32_t);
        return YES;
    }
    if (!strcmp(name, "hw.byteorder") || !strcmp(name, "hw.vectorunit")) {
        value->number = 1;
        value->size = sizeof(uint32_t);
        return YES;
    }
    if (!strcmp(name, "machdep.cpu.brand_string")) {
        value->text = "Apple A16 Bionic";
        return YES;
    }
    if (!strcmp(name, "machdep.cpu.vendor")) { value->text = "Apple"; return YES; }
    if (!strcmp(name, "kern.osproductversion")) {
        return getenv("PEAR_DEVICE_KERNEL") && (value->text = PearIOSVersionC()) != NULL;
    }
    if (!strcmp(name, "kern.osversion")) {
        return getenv("PEAR_DEVICE_KERNEL") && (value->text = PearIOSBuildC()) != NULL;
    }
    if (!strcmp(name, "kern.osrelease")) {
        return getenv("PEAR_DEVICE_KERNEL") && (value->text = PearDarwinReleaseC()) != NULL;
    }
    if (!strcmp(name, "kern.ostype")) { value->text = "Darwin"; return YES; }
    if (!strcmp(name, "kern.hostname")) { value->text = "iPhone"; return YES; }
    if (!strcmp(name, "kern.maxfilesperproc")) {
        value->number = 10240;
        value->size = sizeof(uint32_t);
        return YES;
    }
    if (!strcmp(name, "kern.maxproc")) {
        value->number = 1024;
        value->size = sizeof(uint32_t);
        return YES;
    }
    return NO;
}

/// Writes an override into a caller-provided buffer and returns the same
/// conventions as sysctl: 0 on success, -1 with ENOMEM when the buffer is too
/// small. A size query reports the length required.
static int PearWriteDeviceValue(const PearDeviceValue *value, void *oldp, size_t *oldlenp) {
    if (!value) return -1;
    size_t need = value->text ? strlen(value->text) + 1 : value->size;
    if (need == 0) return -1;

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
    if (value->text) {
        memcpy(oldp, value->text, need);
    } else if (value->size == sizeof(uint64_t)) {
        memcpy(oldp, &value->number, sizeof(uint64_t));
    } else {
        uint32_t number = (uint32_t)value->number;
        memcpy(oldp, &number, sizeof(uint32_t));
    }
    *oldlenp = need;
    return 0;
}

/// Old name kept for the string-only call sites.
static int PearWriteOverride(const char *bytes, void *oldp, size_t *oldlenp) {
    PearDeviceValue value = { .text = bytes };
    return PearWriteDeviceValue(&value, oldp, oldlenp);
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
        PearDeviceValue value;
        if (PearDeviceValueForName(name, &value)) {
            return PearWriteDeviceValue(&value, oldp, oldlenp);
        }
    }
    PearSysctlByNameFn original = (PearSysctlByNameFn)kInterposeSysctlByName.replacee;
    return original ? original(name, oldp, oldlenp, newp, newlen) : -1;
}

#pragma mark - sysctl (MIB)

typedef int (*PearSysctlFn)(int *, u_int, void *, size_t *, void *, size_t);

static int PearSysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);

// Defined below; the public `sysctl` wrapper calls this private entry point.
// Calling the replacee of the public wrapper here would recurse through it.
static PearSysctlFn PearRealSysctl(void);

#pragma mark - sysctl (MIB)
/// Maps a `sysctl` MIB to the equivalent name used by `sysctlbyname`.
static const char *PearSysctlNameForMIB(const int *name, u_int namelen) {
    if (!name || namelen < 2) return NULL;
    if (name[0] == CTL_HW) {
        switch (name[1]) {
            case HW_MACHINE: return "hw.machine";
            case HW_MODEL: return "hw.model";
            case HW_PRODUCT: return "hw.product";
            case HW_NCPU: return "hw.ncpu";
            case HW_BYTEORDER: return "hw.byteorder";
            case HW_PAGESIZE: return "hw.pagesize";
            case HW_MACHINE_ARCH: return "hw.machinearch";
            case HW_CPU_FREQ: return "hw.cpufrequency";
            case HW_CACHELINE: return "hw.cachelinesize";
            case HW_L1ICACHESIZE: return "hw.l1icachesize";
            case HW_L1DCACHESIZE: return "hw.l1dcachesize";
            case HW_L2CACHESIZE: return "hw.l2cachesize";
            case HW_L3CACHESIZE: return "hw.l3cachesize";
            case HW_MEMSIZE: return "hw.memsize";
            default: return NULL;
        }
    }
    if (name[0] == CTL_KERN) {
        switch (name[1]) {
            case KERN_OSTYPE: return "kern.ostype";
            case KERN_OSRELEASE: return "kern.osrelease";
            case KERN_OSVERSION: return "kern.osversion";
            case KERN_HOSTNAME: return "kern.hostname";
            case KERN_MAXPROC: return "kern.maxproc";
            case KERN_MAXFILESPERPROC: return "kern.maxfilesperproc";
            default: return NULL;
        }
    }
    return NULL;
}

static int PearSysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!PearDeviceShimDisabled()) {
        const char *mapped = PearSysctlNameForMIB(name, namelen);
        PearDeviceValue value;
        if (mapped && PearDeviceValueForName(mapped, &value)) {
            return PearWriteDeviceValue(&value, oldp, oldlenp);
        }
    }

    PearSysctlFn original = PearRealSysctl();
    return original ? original(name, namelen, oldp, oldlenp, newp, newlen) : -1;
}

/// Entry point for the raw `syscall(SYS_sysctl, ...)` path.
extern "C" int PearSysctlMIB(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                             void *newp, size_t newlen) {
    return PearSysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

// Some code binds the private `__sysctl` alias instead of the public wrapper.
// Interposing both keeps the MIB overrides effective on either path.
extern "C" int __sysctl(int *, u_int, void *, size_t *, void *, size_t);

static int PearSysctlAlias(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                           void *newp, size_t newlen);

__attribute__((used)) static PearInterposeEntry kInterposeSysctlAlias
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSysctlAlias,
        (const void *)(uintptr_t)&__sysctl
    };

static int PearSysctlAlias(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                           void *newp, size_t newlen) {
    return PearSysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

static PearSysctlFn PearRealSysctl(void) {
    return (PearSysctlFn)kInterposeSysctlAlias.replacee;
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
    // System frameworks (AppIntents, Swift concurrency) use uname to select a
    // platform code path, so changing it by default asserts inside those
    // frameworks. Keep it behind the explicit switch; sysctl remains spoofed.
    if (result == 0 && value && !PearDeviceShimDisabled() && getenv("PEAR_DEVICE_UNAME")
            && PearDeviceModelC() && PearDarwinReleaseC()) {
        strlcpy(value->machine, PearDeviceModelC(), sizeof(value->machine));
        strlcpy(value->release, PearDarwinReleaseC(), sizeof(value->release));
    }
    return result;
}

#pragma mark - IORegistry identity

static char gSyntheticSerial[13];
static char gSyntheticUUID[37];

static void PearBuildSyntheticIdentifiers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *seed = NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "com.pearsilicon.app";
        uint64_t a = PearStableHash(seed, 1469598103934665603ULL);
        uint64_t b = PearStableHash(PearDeviceModelC(), a ^ 1099511628211ULL);
        static const char alphabet[] = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ";
        for (int i = 0; i < 12; i++) {
            gSyntheticSerial[i] = alphabet[(a >> ((i * 5) % 60)) & 31];
        }
        gSyntheticSerial[12] = 0;
        snprintf(gSyntheticUUID, sizeof(gSyntheticUUID),
                 "%08X-%04X-%04X-%04X-%012llX",
                 (unsigned)(a >> 32), (unsigned)(a & 0xFFFF),
                 (unsigned)((b >> 48) & 0x0FFF) | 0x4000,
                 (unsigned)((b >> 32) & 0x3FFF) | 0x8000,
                 (unsigned long long)(b & 0xFFFFFFFFFFFFULL));
    });
}

static CFDataRef PearCreateData(const char *bytes, size_t length) {
    return CFDataCreate(kCFAllocatorDefault, (const UInt8 *)bytes, (CFIndex)length);
}

/// A value the platform expert would return on an iOS device, or NULL when the
/// key is not identity-related. Follows the Create rule (caller releases).
static CFTypeRef PearSpoofedIORegistryValue(CFStringRef key) {
    if (!key || !PearDeviceModelC()) return NULL;
    char name[128];
    if (!CFStringGetCString(key, name, sizeof(name), kCFStringEncodingUTF8)) return NULL;
    PearBuildSyntheticIdentifiers();

    if (!strcmp(name, "model") || !strcmp(name, "target-type")) {
        return PearCreateData(PearDeviceModelC(), strlen(PearDeviceModelC()));
    }
    if (!strcmp(name, "product-name")) {
        return CFStringCreateWithCString(kCFAllocatorDefault, "iPhone 14 Pro",
                                         kCFStringEncodingUTF8);
    }
    if (!strcmp(name, "board-id")) {
        return PearCreateData("D63AP", 5);
    }
    if (!strcmp(name, "IOPlatformSerialNumber")) {
        return CFStringCreateWithCString(kCFAllocatorDefault, gSyntheticSerial,
                                         kCFStringEncodingUTF8);
    }
    if (!strcmp(name, "serial-number")) {
        return PearCreateData(gSyntheticSerial, strlen(gSyntheticSerial));
    }
    if (!strcmp(name, "IOPlatformUUID")) {
        return CFStringCreateWithCString(kCFAllocatorDefault, gSyntheticUUID,
                                         kCFStringEncodingUTF8);
    }
    if (!strcmp(name, "device-id")) {
        const unsigned char deviceID[4] = { 0x0A, 0x00, 0x00, 0x01 };
        return PearCreateData((const char *)deviceID, sizeof(deviceID));
    }
    if (!strcmp(name, "compatible")) {
        char compatible[32];
        snprintf(compatible, sizeof(compatible), "%s", PearDeviceModelC());
        return PearCreateData(compatible, strlen(compatible) + 1);
    }
    return NULL;
}

static CFTypeRef PearIORegistryCreate(io_registry_entry_t entry, CFStringRef key,
                                      CFAllocatorRef allocator, IOOptionBits options);
static CFTypeRef PearIORegistrySearch(io_registry_entry_t entry, const char *plane,
                                      CFStringRef key, CFAllocatorRef allocator,
                                      IOOptionBits options);
static kern_return_t PearIORegistryCreateProperties(io_registry_entry_t entry,
                                                    CFMutableDictionaryRef *properties,
                                                    CFAllocatorRef allocator,
                                                    IOOptionBits options);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeIORegCreate
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearIORegistryCreate,
        (const void *)(uintptr_t)&IORegistryEntryCreateCFProperty
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeIORegSearch
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearIORegistrySearch,
        (const void *)(uintptr_t)&IORegistryEntrySearchCFProperty
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeIORegProperties
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearIORegistryCreateProperties,
        (const void *)(uintptr_t)&IORegistryEntryCreateCFProperties
    };

typedef CFTypeRef (*PearIORegCreateFn)(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits);
typedef CFTypeRef (*PearIORegSearchFn)(io_registry_entry_t, const char *, CFStringRef,
                                       CFAllocatorRef, IOOptionBits);
typedef kern_return_t (*PearIORegPropertiesFn)(io_registry_entry_t, CFMutableDictionaryRef *,
                                               CFAllocatorRef, IOOptionBits);

typedef boolean_t (*PearIOObjectConformsFn)(io_object_t, const char *);

static BOOL PearIsPlatformExpert(io_registry_entry_t entry) {
    PearIOObjectConformsFn conforms = (PearIOObjectConformsFn)dlsym(RTLD_DEFAULT, "IOObjectConformsTo");
    return conforms ? conforms(entry, "IOPlatformExpertDevice") : NO;
}

static CFTypeRef PearIORegistryCreate(io_registry_entry_t entry, CFStringRef key,
                                      CFAllocatorRef allocator, IOOptionBits options) {
    if (!PearDeviceShimDisabled() && PearIsPlatformExpert(entry)) {
        CFTypeRef spoofed = PearSpoofedIORegistryValue(key);
        if (spoofed) return spoofed;
    }
    PearIORegCreateFn original = (PearIORegCreateFn)kInterposeIORegCreate.replacee;
    return original ? original(entry, key, allocator, options) : NULL;
}

static CFTypeRef PearIORegistrySearch(io_registry_entry_t entry, const char *plane,
                                      CFStringRef key, CFAllocatorRef allocator,
                                      IOOptionBits options) {
    if (!PearDeviceShimDisabled()) {
        CFTypeRef spoofed = PearSpoofedIORegistryValue(key);
        if (spoofed) return spoofed;
    }
    PearIORegSearchFn original = (PearIORegSearchFn)kInterposeIORegSearch.replacee;
    return original ? original(entry, plane, key, allocator, options) : NULL;
}

static kern_return_t PearIORegistryCreateProperties(io_registry_entry_t entry,
                                                    CFMutableDictionaryRef *properties,
                                                    CFAllocatorRef allocator,
                                                    IOOptionBits options) {
    PearIORegPropertiesFn original =
        (PearIORegPropertiesFn)kInterposeIORegProperties.replacee;
    kern_return_t result = original ? original(entry, properties, allocator, options)
                                    : KERN_FAILURE;
    if (result != KERN_SUCCESS || !properties || !*properties || PearDeviceShimDisabled()
        || !PearIsPlatformExpert(entry)) {
        return result;
    }

    static const char *keys[] = {
        "model", "product-name", "board-id", "IOPlatformSerialNumber",
        "serial-number", "IOPlatformUUID", "device-id", "compatible",
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, keys[i],
                                                    kCFStringEncodingUTF8);
        if (!key) continue;
        CFTypeRef value = PearSpoofedIORegistryValue(key);
        if (value) {
            CFDictionarySetValue(*properties, key, value);
            CFRelease(value);
        }
        CFRelease(key);
    }
    return result;
}

#pragma mark - Power sources

static void PearDictSetString(CFMutableDictionaryRef dict, const char *key, const char *value) {
    CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFStringRef text = CFStringCreateWithCString(kCFAllocatorDefault, value, kCFStringEncodingUTF8);
    if (name && text) CFDictionarySetValue(dict, name, text);
    if (name) CFRelease(name);
    if (text) CFRelease(text);
}

static void PearDictSetInt(CFMutableDictionaryRef dict, const char *key, long long value) {
    CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
    if (name && number) CFDictionarySetValue(dict, name, number);
    if (name) CFRelease(name);
    if (number) CFRelease(number);
}

static void PearDictSetBool(CFMutableDictionaryRef dict, const char *key, bool value) {
    CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (name) {
        CFDictionarySetValue(dict, name, value ? kCFBooleanTrue : kCFBooleanFalse);
        CFRelease(name);
    }
}

static CFTypeRef PearCopyPowerSourcesInfo(void);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposePowerSources
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearCopyPowerSourcesInfo,
        (const void *)(uintptr_t)&IOPSCopyPowerSourcesInfo
    };

typedef CFTypeRef (*PearPowerSourcesFn)(void);

static CFTypeRef PearCopyPowerSourcesInfo(void) {
    if (PearDeviceShimDisabled()) {
        PearPowerSourcesFn original = (PearPowerSourcesFn)kInterposePowerSources.replacee;
        return original ? original() : NULL;
    }

    CFMutableDictionaryRef battery = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!battery) return NULL;

    PearDictSetString(battery, "Type", "InternalBattery");
    PearDictSetString(battery, "Power Source State", "Battery Power");
    PearDictSetInt(battery, "Current Capacity", 87);
    PearDictSetInt(battery, "Max Capacity", 100);
    PearDictSetBool(battery, "Is Charging", false);
    PearDictSetBool(battery, "Is Present", true);
    PearDictSetBool(battery, "Is Charged", false);
    PearDictSetInt(battery, "Time to Empty", 300);
    PearDictSetInt(battery, "Time to Full Charge", -1);
    PearDictSetString(battery, "Battery Health", "Good");
    PearDictSetString(battery, "Battery Health Condition", "Good");
    PearDictSetInt(battery, "Current", 1000);
    PearDictSetInt(battery, "Voltage", 3900);
    PearDictSetInt(battery, "Temperature", 300);
    PearDictSetString(battery, "Transport Type", "Internal");
    PearDictSetBool(battery, "External Connected", false);
    PearDictSetString(battery, "Name", "iPhone Battery");
    PearDictSetString(battery, "Model", "A16");
    PearDictSetString(battery, "Serial", "0");
    PearDictSetString(battery, "Manufacturer", "Apple");
    PearDictSetBool(battery, "Battery Provides Time Remaining", true);

    CFMutableArrayRef array = CFArrayCreateMutable(kCFAllocatorDefault, 1, &kCFTypeArrayCallBacks);
    if (!array) {
        CFRelease(battery);
        return NULL;
    }
    CFArrayAppendValue(array, battery);
    CFRelease(battery);
    return array;
}

#pragma mark - IOKit service queries

static void PearLogIOServiceClass(CFDictionaryRef matching) {
    if (!getenv("PEAR_DEBUG_IOKIT") || !matching) return;
    CFTypeRef value = CFDictionaryGetValue(matching, CFSTR("IOProviderClass"));
    char name[128] = "(unknown)";
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString((CFStringRef)value, name, sizeof(name), kCFStringEncodingUTF8);
    }
    PearLog(@"[PearRuntime][iokit] matching services for %s", name);
}

static kern_return_t PearIOServiceGetMatchingServices(mach_port_t mainPort,
                                                      CFDictionaryRef matching,
                                                      io_iterator_t *existing);

typedef kern_return_t (*PearIOServiceGetMatchingServicesFn)(mach_port_t, CFDictionaryRef,
                                                             io_iterator_t *);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeIOServiceGetMatchingServices
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearIOServiceGetMatchingServices,
        (const void *)(uintptr_t)&IOServiceGetMatchingServices
    };

static kern_return_t PearIOServiceGetMatchingServices(mach_port_t mainPort,
                                                      CFDictionaryRef matching,
                                                      io_iterator_t *existing) {
    PearLogIOServiceClass(matching);
    PearIOServiceGetMatchingServicesFn original =
        (PearIOServiceGetMatchingServicesFn)kInterposeIOServiceGetMatchingServices.replacee;
    return original ? original(mainPort, matching, existing) : KERN_FAILURE;
}

#pragma mark - MAC address placeholders

static int PearGetifaddrs(struct ifaddrs **ifap);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeGetifaddrs
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearGetifaddrs,
        (const void *)(uintptr_t)&getifaddrs
    };

static int PearGetifaddrs(struct ifaddrs **ifap) {
    int (*original)(struct ifaddrs **) = (int (*)(struct ifaddrs **))kInterposeGetifaddrs.replacee;
    int result = original ? original(ifap) : -1;
    if (result != 0 || !ifap || PearDeviceShimDisabled()) return result;

    // A non-entitled app on iOS does not receive the Wi-Fi hardware address.
    for (struct ifaddrs *item = *ifap; item; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_LINK) continue;
        struct sockaddr_dl *link = (struct sockaddr_dl *)item->ifa_addr;
        if (link->sdl_alen != 6) continue;
        unsigned char *mac = (unsigned char *)LLADDR(link);
        memset(mac, 0, 6);
        mac[0] = 0x02;
    }
    return result;
}

#pragma mark - UIDevice

static NSUUID *PearSyntheticVendorID(void) {
    static NSUUID *identifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const PearDeviceProfile *profile = PearDeviceProfileGet();
        if (profile->status != PearDeviceProfileStatusReady) return;
        if (profile->source == PearDeviceProfileSourceHostV1) {
            identifier = [[NSUUID alloc] initWithUUIDString:
                [NSString stringWithUTF8String:profile->vendorIdentifier]];
            return; // Managed identity is computed by the host, never regenerated.
        }
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
    BOOL profileReady = PearDeviceProfileGet()->status == PearDeviceProfileStatusReady;

    // Keep the basic identity consistent. The layout idiom and vendor token are
    // opt-in: system services inside a Catalyst app use them to choose a UIKit
    // code path, and forcing the phone idiom there can trip an availability
    // assertion before the app's first scene.
    if (profileReady) {
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
    }

    PearSwizzle(device, @selector(batteryLevel), imp_implementationWithBlock(^float(id self) {
        return 0.87f;
    }));
    PearSwizzle(device, @selector(batteryState), imp_implementationWithBlock(^NSInteger(id self) {
        return 1; // UIDeviceBatteryStateUnplugged
    }));
    PearSwizzle(device, @selector(isBatteryMonitoringEnabled),
                imp_implementationWithBlock(^BOOL(id self) { return YES; }));

    if (getenv("PEAR_DEVICE_UI_DETAILS")) {
        if (profileReady) {
            PearSwizzle(device, @selector(identifierForVendor), imp_implementationWithBlock(^NSUUID *(id self) {
                return PearSyntheticVendorID();
            }));
            PearSwizzle(device, @selector(userInterfaceIdiom), imp_implementationWithBlock(^NSInteger(id self) {
                return PearWantsPadIdiom() ? 1 : 0; // pad : phone
            }));
        }
        PearSwizzle(device, @selector(isMultitaskingSupported), imp_implementationWithBlock(^BOOL(id self) {
            return YES;
        }));
    }

    // Diagnostic only: forcing the trait idiom changes the whole layout mode of
    // the app and can push a tablet-sized UI offscreen. Asset lookups are
    // handled narrowly below instead.
    if (profileReady && getenv("PEAR_FORCE_TRAIT_IDIOM")) {
        Class traits = NSClassFromString(@"UITraitCollection");
        Method idiomMethod = traits
            ? class_getInstanceMethod(traits, @selector(userInterfaceIdiom)) : NULL;
        if (idiomMethod) {
            IMP originalIdiom = method_getImplementation(idiomMethod);
            method_setImplementation(idiomMethod, imp_implementationWithBlock(^NSInteger(id self) {
                if (PearWantsPadIdiom()) return 1;
                NSInteger value = ((NSInteger (*)(id, SEL))originalIdiom)(self, @selector(userInterfaceIdiom));
                return (value == 1 || value == 5) ? 0 : value; // pad/mac -> phone
            }));
        }
    }
}

#pragma mark - Foundation version

static void PearInstallOperatingSystemVersion(void) {
    if (PearDeviceShimDisabled()) return;
    // Foundation's version is consumed by system services inside the app (for
    // example AppIntents registers Swift concurrency executors and asserts if
    // the process claims an iOS version). Keep it opt-in; the kernel facts
    // below are spoofed by default instead.
    if (!getenv("PEAR_SPOOF_OS_VERSION") || !PearIOSVersionC()) return;
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

/// Process-level hardware facts. These are separate from `sysctl` and are
/// commonly read by engines and analytics SDKs.
static void PearInstallProcessInfoIdentity(void) {
    if (PearDeviceShimDisabled()) return;
    Class processInfo = NSClassFromString(@"NSProcessInfo");
    if (!processInfo) return;

    PearSwizzle(processInfo, @selector(physicalMemory),
                imp_implementationWithBlock(^unsigned long long(id self) {
        return 6ULL * 1024 * 1024 * 1024;
    }));
    PearSwizzle(processInfo, @selector(processorCount),
                imp_implementationWithBlock(^NSUInteger(id self) { return 6; }));
    PearSwizzle(processInfo, @selector(activeProcessorCount),
                imp_implementationWithBlock(^NSUInteger(id self) { return 6; }));
    PearSwizzle(processInfo, @selector(hostName),
                imp_implementationWithBlock(^NSString *(id self) { return @"iPhone"; }));
}

/// Minimal motion surface: an iPhone has an accelerometer and a gyroscope, and
/// the data objects report a resting orientation. Device-motion fusion is left
/// to the real implementation because its attitude object cannot be synthesized
/// faithfully.
typedef struct { double x, y, z; } PearMotionVector;

static id gMockAccelerometer;
static id gMockGyro;

static void PearInstallMotionIdentity(void) {
    if (PearDeviceShimDisabled()) return;
    dlopen("/System/Library/Frameworks/CoreMotion.framework/CoreMotion", RTLD_LAZY);
    Class manager = NSClassFromString(@"CMMotionManager");
    if (!manager) return;

    Class accelerometer = NSClassFromString(@"CMAccelerometerData");
    if (accelerometer) {
        Class mock = objc_allocateClassPair(accelerometer, "PearAccelerometerData", 0);
        if (mock) {
            class_addMethod(mock, @selector(init),
                            imp_implementationWithBlock(^id(id self) { return self; }), "@@:");
            class_addMethod(mock, @selector(acceleration),
                            imp_implementationWithBlock(^PearMotionVector(id self) {
                return (PearMotionVector){ 0.0, 0.0, -1.0 };
            }), "{CMAcceleration=ddd}@:");
            class_addMethod(mock, @selector(timestamp),
                            imp_implementationWithBlock(^NSTimeInterval(id self) {
                return NSDate.date.timeIntervalSinceReferenceDate;
            }), "d@:");
            objc_registerClassPair(mock);
            gMockAccelerometer = [[mock alloc] init];
        }
    }

    Class gyro = NSClassFromString(@"CMGyroData");
    if (gyro) {
        Class mock = objc_allocateClassPair(gyro, "PearGyroData", 0);
        if (mock) {
            class_addMethod(mock, @selector(init),
                            imp_implementationWithBlock(^id(id self) { return self; }), "@@:");
            class_addMethod(mock, @selector(rotationRate),
                            imp_implementationWithBlock(^PearMotionVector(id self) {
                return (PearMotionVector){ 0.0, 0.0, 0.0 };
            }), "{CMRotationRate=ddd}@:");
            class_addMethod(mock, @selector(timestamp),
                            imp_implementationWithBlock(^NSTimeInterval(id self) {
                return NSDate.date.timeIntervalSinceReferenceDate;
            }), "d@:");
            objc_registerClassPair(mock);
            gMockGyro = [[mock alloc] init];
        }
    }

    PearSwizzle(manager, @selector(isAccelerometerAvailable),
                imp_implementationWithBlock(^BOOL(id self) { return YES; }));
    PearSwizzle(manager, @selector(isGyroAvailable),
                imp_implementationWithBlock(^BOOL(id self) { return YES; }));
    PearSwizzle(manager, @selector(accelerometerData),
                imp_implementationWithBlock(^id(id self) { return gMockAccelerometer; }));
    PearSwizzle(manager, @selector(gyroData),
                imp_implementationWithBlock(^id(id self) { return gMockGyro; }));
    PearSwizzle(manager, @selector(startAccelerometerUpdates),
                imp_implementationWithBlock(^(id self) {}));
    PearSwizzle(manager, @selector(startGyroUpdates),
                imp_implementationWithBlock(^(id self) {}));
}

#pragma mark - Asset idiom fallback

/// An iPhone-thinned bundle contains only `~iphone` renditions. UIKit resolves
/// named images against the *scene's* idiom, which on a Mac is pad/mac, so
/// every phone-only asset comes back nil and apps that force-unwrap it trap.
/// Keep the layout idiom untouched and only retry the lookup with a phone
/// trait collection when the normal lookup found nothing. Opt out with
/// PEAR_NO_ASSET_FALLBACK.
static void PearInstallAssetIdiomFallback(void) {
    if (getenv("PEAR_NO_ASSET_FALLBACK")) return;
    Class imageClass = NSClassFromString(@"UIImage");
    Class traitsClass = NSClassFromString(@"UITraitCollection");
    if (!imageClass || !traitsClass) return;

    SEL named = @selector(imageNamed:);
    SEL namedWithTraits = @selector(imageNamed:inBundle:compatibleWithTraitCollection:);
    Method plainMethod = class_getClassMethod(imageClass, named);
    Method traitsMethod = class_getClassMethod(imageClass, namedWithTraits);
    if (!plainMethod || !traitsMethod) return;

    IMP plain = method_getImplementation(plainMethod);
    IMP withTraits = method_getImplementation(traitsMethod);

    method_setImplementation(plainMethod, imp_implementationWithBlock(^id(id cls, NSString *name) {
        id image = ((id (*)(id, SEL, NSString *))plain)(cls, named, name);
        if (image || !name) return image;

        id (*makeTraits)(id, SEL, NSInteger) = (id (*)(id, SEL, NSInteger))objc_msgSend;
        id phoneTraits = makeTraits(traitsClass, @selector(traitCollectionWithUserInterfaceIdiom:), 0);
        if (!phoneTraits) return nil;
        return ((id (*)(id, SEL, NSString *, NSBundle *, id))withTraits)(
            cls, namedWithTraits, name, nil, phoneTraits);
    }));

    PearLog(@"[PearRuntime][device] asset idiom fallback installed");
}

__attribute__((constructor))
static void PearDeviceShimInit(void) {
    if (PearDeviceShimDisabled()) return;
    @autoreleasepool {
        PearInstallDeviceProperties();
        PearInstallAssetIdiomFallback();
        PearInstallMotionIdentity();
        PearInstallProcessInfoIdentity();
        PearInstallOperatingSystemVersion();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            const PearDeviceProfile *profile = PearDeviceProfileGet();
            if (profile->status != PearDeviceProfileStatusReady) {
                PearLog(@"[PearRuntime][device] profile unavailable (status=%d field=%s); profile overrides skipped",
                        (int)profile->status, profile->invalidField ?: "unknown");
            } else {
                PearLog(@"[PearRuntime][device] identity=%@/%@ model=%@ iOS=%@ build=%@",
                        PearDeviceModel(), PearDeviceName(), PearDeviceName(),
                        PearIOSVersion(), PearIOSBuild());
            }
        });
    }
}
