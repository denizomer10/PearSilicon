// SandboxShim.mm
//
// Gives an app an iOS-like view of the host filesystem.
//
// A Mac Catalyst process normally sees the whole macOS userland. Some apps
// interpret the presence of host-only tools and directories as an integrity
// problem, even though the process is running normally. This optional shim
// applies a local sandbox profile that hides the host userland while leaving
// system frameworks, the app bundle and the app's container available.
//
// Opt in with PEAR_IOS_SANDBOX=1. The profile is deliberately broad: it hides
// host directories and tools, not an app-specific check.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <errno.h>
#import <dirent.h>
#import "PearRuntime.h"

typedef int (*PearSandboxInitFn)(const char *, uint64_t, char **);
typedef void (*PearSandboxFreeErrorFn)(char *);

static BOOL PearSandboxEnabled(void) {
    const char *value = getenv("PEAR_IOS_SANDBOX");
    return value && value[0] && strcmp(value, "0") != 0;
}

static void PearApplyIOSSandbox(void) {
    if (!PearSandboxEnabled()) return;

    PearSandboxInitFn initialize = (PearSandboxInitFn)dlsym(RTLD_DEFAULT, "sandbox_init");
    if (!initialize) {
        PearLog(@"[PearRuntime][sandbox] sandbox_init unavailable");
        return;
    }

    const char *profile =
        "(version 1)"
        "(allow default)"
        "(deny file-read* (subpath \"/bin\"))"
        "(deny file-read* (subpath \"/sbin\"))"
        "(deny file-read* (subpath \"/usr/bin\"))"
        "(deny file-read* (subpath \"/usr/sbin\"))"
        "(deny file-read* (subpath \"/usr/libexec\"))"
        "(deny file-read* (subpath \"/Applications\"))"
        "(deny file-read* (subpath \"/Library/MobileSubstrate\"))"
        "(deny file-read* (subpath \"/var/jb\"))"
        "(deny file-read* (subpath \"/private/var/jb\"))"
        "(deny file-read* (subpath \"/private/var/lib/apt\"))"
        "(deny file-read* (subpath \"/private/var/lib/cydia\"))"
        "(deny file-read* (subpath \"/private/var/stash\"))"
        "(deny file-read* (subpath \"/private/var/tmp/cydia.log\"))"
        "(deny file-read* (subpath \"/private/var/mobile/Library/SBSettings\"))"
        "(deny file-read* (subpath \"/System/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist\"))"
        "(deny file-read* (subpath \"/System/Library/LaunchDaemons/com.ikey.bbot.plist\"))"
        "(deny file-read* (subpath \"/usr/lib/libsubstrate.dylib\"))"
        "(deny file-read* (subpath \"/usr/lib/libhooker.dylib\"))"
        "(deny file-read* (subpath \"/usr/lib/libellekit.dylib\"))";

    char *error = NULL;
    int result = initialize(profile, 0, &error);
    if (result == 0) {
        PearLog(@"[PearRuntime][sandbox] iOS-like filesystem view installed");
    } else {
        PearLog(@"[PearRuntime][sandbox] profile failed: %s", error ?: "unknown");
    }

    if (error) {
        PearSandboxFreeErrorFn freeError =
            (PearSandboxFreeErrorFn)dlsym(RTLD_DEFAULT, "sandbox_free_error");
        if (freeError) freeError(error);
    }
}

__attribute__((constructor))
static void PearSandboxShimInit(void) {
    @autoreleasepool {
        PearApplyIOSSandbox();
    }
}

// Inside the sandbox, `access` should not report a path that `stat` denies.
// The kernel mediates stat/open/opendir through the profile, while access is
// not filtered the same way; reconciling them keeps existence checks coherent.
extern "C" int PearSandboxAccess(const char *path, int mode);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeAccess
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSandboxAccess,
        (const void *)(uintptr_t)&access
    };

extern "C" int PearSandboxAccess(const char *path, int mode) {
    int (*original)(const char *, int) = (int (*)(const char *, int))kInterposeAccess.replacee;
    if (!PearSandboxEnabled() || !path || !original) {
        return original ? original(path, mode) : -1;
    }

    struct stat info;
    if (stat(path, &info) != 0) {
        if (errno == EPERM || errno == EACCES) errno = ENOENT;
        return -1;
    }
    return original(path, mode);
}

// The sandbox reports a denial as EPERM. An iOS-like view should make a hidden
// path look absent instead, so callers do not mistake the sandbox itself for an
// integrity problem.
extern "C" int PearSandboxStat(const char *path, struct stat *info);
extern "C" int PearSandboxLstat(const char *path, struct stat *info);
extern "C" ssize_t PearSandboxReadlink(const char *path, char *buffer, size_t size);
extern "C" DIR *PearSandboxOpendir(const char *path);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeStat
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSandboxStat,
        (const void *)(uintptr_t)&stat
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeLstat
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSandboxLstat,
        (const void *)(uintptr_t)&lstat
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeReadlink
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSandboxReadlink,
        (const void *)(uintptr_t)&readlink
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeOpendir
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSandboxOpendir,
        (const void *)(uintptr_t)&opendir
    };

static void PearMapSandboxError(void) {
    if (PearSandboxEnabled() && (errno == EPERM || errno == EACCES)) errno = ENOENT;
}

extern "C" int PearSandboxStat(const char *path, struct stat *info) {
    int (*original)(const char *, struct stat *) =
        (int (*)(const char *, struct stat *))kInterposeStat.replacee;
    int result = original ? original(path, info) : -1;
    if (result != 0) PearMapSandboxError();
    return result;
}

extern "C" int PearSandboxLstat(const char *path, struct stat *info) {
    int (*original)(const char *, struct stat *) =
        (int (*)(const char *, struct stat *))kInterposeLstat.replacee;
    int result = original ? original(path, info) : -1;
    if (result != 0) PearMapSandboxError();
    return result;
}

extern "C" ssize_t PearSandboxReadlink(const char *path, char *buffer, size_t size) {
    ssize_t (*original)(const char *, char *, size_t) =
        (ssize_t (*)(const char *, char *, size_t))kInterposeReadlink.replacee;
    ssize_t result = original ? original(path, buffer, size) : -1;
    if (result < 0) PearMapSandboxError();
    return result;
}

extern "C" DIR *PearSandboxOpendir(const char *path) {
    DIR *(*original)(const char *) = (DIR *(*)(const char *))kInterposeOpendir.replacee;
    DIR *result = original ? original(path) : NULL;
    if (!result) PearMapSandboxError();
    return result;
}
