// SandboxShim.mm
//
// Gives an app an iOS-like view of the host filesystem.
//
// A Mac Catalyst process normally sees the whole macOS userland. Some apps
// interpret the presence of host-only tools and directories as an integrity
// problem, even though the process is running normally. This shim applies a
// local sandbox profile that hides the host userland while leaving system
// frameworks, the app bundle and the app's container available.
//
// Every launch sets PEAR_IOS_SANDBOX=1; the variable only exists so a runtime
// loaded by hand can opt out. The profile is deliberately broad: it hides host
// directories and tools, not an app-specific check.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <limits.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/syscall.h>
#import <sys/mount.h>
#import <sys/wait.h>
#import <errno.h>
#import <dirent.h>
#import <os/lock.h>
#import <os/log.h>
#import "PearRuntime.h"

typedef int (*PearSandboxInitFn)(const char *, uint64_t, char **);
typedef void (*PearSandboxFreeErrorFn)(char *);

// Implemented by DeviceShim; routes raw sysctl syscalls through the same
// hardware identity layer as the libc wrappers.
extern "C" int PearSysctlMIB(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                             void *newp, size_t newlen);

#pragma mark - Diagnostic tracing

// Enabled only with PEAR_DEBUG_PATHS. It answers one question: which host
// paths does an app probe before it decides the environment is not a stock
// device? The trace is read-only; calls behave exactly as before.
static int gTraceEnabled = 0;

static BOOL PearTraceEnabled(void) { return gTraceEnabled == 1; }

// Reads the switch before getenv() is interposed below.
__attribute__((constructor)) static void PearPathTraceInit(void) {
    gTraceEnabled = getenv("PEAR_DEBUG_PATHS") != NULL ? 1 : 0;
}

static int gTraceFD = -1;
static os_unfair_lock gTraceLock = OS_UNFAIR_LOCK_INIT;

static void PearTraceWrite(const char *api, const char *path, long result, int error) {
    os_unfair_lock_lock(&gTraceLock);
    if (gTraceFD < 0) {
        // openat keeps this out of the interposed open() above.
        gTraceFD = openat(AT_FDCWD, "/tmp/pear-fs.log",
                          O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    if (gTraceFD >= 0) {
        char line[2048];
        int length = snprintf(line, sizeof(line), "%s %s -> %ld (errno %d)\n",
                              api, path, result, error);
        if (length > 0) {
            size_t count = (size_t)length < sizeof(line) ? (size_t)length : sizeof(line) - 1;
            (void)write(gTraceFD, line, count);
        }
    }
    os_unfair_lock_unlock(&gTraceLock);
}

static BOOL PearTraceInteresting(const char *path) {
    if (!path || path[0] != '/') return NO;

    // This runs from inside interposed path calls, so it must not use
    // Foundation: NSBundle resolves paths through the same calls and would
    // recurse.
    static char supportPrefix[PATH_MAX];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Launcher-selected storage root; the prefix must follow it so a
        // relocated root is hidden like the default one.
        const char *root = getenv("PEAR_SUPPORT_ROOT");
        if (root && root[0]) {
            snprintf(supportPrefix, sizeof(supportPrefix), "%s/", root);
            return;
        }
        const char *home = getenv("HOME");
        if (!home || !home[0]) home = "/tmp";
        snprintf(supportPrefix, sizeof(supportPrefix), "%s/Library/Application Support/PearSilicon/", home);
    });

    static const char *boring[] = {
        "/System/", "/usr/lib/", "/usr/share/", "/Library/Frameworks/",
        "/private/var/folders/", "/dev/", "/private/tmp/", "/tmp/",
        "/private/var/db/", "/private/var/run/", "/private/var/log/",
    };
    for (size_t i = 0; i < sizeof(boring) / sizeof(boring[0]); i++) {
        if (strncmp(path, boring[i], strlen(boring[i])) == 0) return NO;
    }
    if (supportPrefix[0] && strncmp(path, supportPrefix, strlen(supportPrefix)) == 0) return NO;
    return YES;
}

static void PearTracePath(const char *api, const char *path, long result, int error) {
    if (!PearTraceEnabled() || !PearTraceInteresting(path)) return;
    PearTraceWrite(api, path, result, error);
}

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
        int result = original ? original(path, mode) : -1;
        if (result != 0) PearTracePath("access", path, result, errno);
        return result;
    }

    struct stat info;
    if (stat(path, &info) != 0) {
        if (errno == EPERM || errno == EACCES) errno = ENOENT;
        PearTracePath("access", path, -1, errno);
        return -1;
    }
    int result = original(path, mode);
    if (result != 0) PearTracePath("access", path, result, errno);
    else PearTracePath("access-ok", path, mode, 0);
    return result;
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
    if (result != 0) {
        PearMapSandboxError();
        PearTracePath("stat", path, result, errno);
    }
    return result;
}

extern "C" int PearSandboxLstat(const char *path, struct stat *info) {
    int (*original)(const char *, struct stat *) =
        (int (*)(const char *, struct stat *))kInterposeLstat.replacee;
    int result = original ? original(path, info) : -1;
    if (result != 0) {
        PearMapSandboxError();
        PearTracePath("lstat", path, result, errno);
    }
    return result;
}

extern "C" ssize_t PearSandboxReadlink(const char *path, char *buffer, size_t size) {
    ssize_t (*original)(const char *, char *, size_t) =
        (ssize_t (*)(const char *, char *, size_t))kInterposeReadlink.replacee;
    ssize_t result = original ? original(path, buffer, size) : -1;
    if (result < 0) {
        PearMapSandboxError();
        PearTracePath("readlink", path, result, errno);
    }
    return result;
}

extern "C" DIR *PearSandboxOpendir(const char *path) {
    DIR *(*original)(const char *) = (DIR *(*)(const char *))kInterposeOpendir.replacee;
    DIR *result = original ? original(path) : NULL;
    if (!result) {
        PearMapSandboxError();
        PearTracePath("opendir", path, 0, errno);
    }
    return result;
}

#pragma mark - Process and write probes

// A stock device does not let an app create processes or write outside its
// container. Those two capabilities are what most environment checks test, so
// the trace records them (without changing the result) to identify a false
// positive.
extern "C" int PearTraceOpen(const char *path, int flags, ...);
extern "C" int PearTraceOpenAt(int dirfd, const char *path, int flags, ...);
extern "C" int PearTraceCreat(const char *path, mode_t mode);
extern "C" FILE *PearTraceFopen(const char *path, const char *mode);
extern "C" mode_t PearTraceUmask(mode_t mask);
extern "C" pid_t PearTraceFork(void);
extern "C" FILE *PearTracePopen(const char *command, const char *mode);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeOpen
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceOpen,
        (const void *)(uintptr_t)&open
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeOpenAt
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceOpenAt,
        (const void *)(uintptr_t)&openat
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeCreat
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceCreat,
        (const void *)(uintptr_t)&creat
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeFopen
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceFopen,
        (const void *)(uintptr_t)&fopen
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeUmask
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceUmask,
        (const void *)(uintptr_t)&umask
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeFork
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceFork,
        (const void *)(uintptr_t)&fork
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposePopen
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTracePopen,
        (const void *)(uintptr_t)&popen
    };

/// A port can create a file with a mode its own process cannot reopen. The
/// common case is mode 0, but some titles create manifests with modes such as
/// 0215 (write + stray execute bits, no owner read); their next launch then
/// cannot read the manifest and the update check waits forever. Owner read is
/// the minimum any app needs for data in its own container. Modes that already
/// grant owner read are left alone, and execute/write bits are preserved.
static mode_t PearSafeMode(mode_t mode) {
    if (mode == 0) return 0644;
    return mode | 0400;
}

static BOOL PearOpenIsWritable(int flags) {
    int access = flags & O_ACCMODE;
    return access == O_WRONLY || access == O_RDWR;
}

static BOOL PearPathIsBelow(const char *path, const char *root) {
    size_t length = strlen(root);
    return strncmp(path, root, length) == 0 && path[length] == '/';
}

// No Foundation here: resolving a bundle or a home directory can reenter open.
// Only the launcher-selected data home is a write-repair capability, never HOME
// or the support root (which also contains installed app bundles).
static BOOL PearDescriptorInManagedHome(int descriptor) {
    const char *home = getenv("PEAR_HOME_DIR");
    char root[PATH_MAX], path[PATH_MAX], resolved[PATH_MAX];
    if (!home || home[0] != '/' || !realpath(home, root) || strcmp(root, "/") == 0) {
        return NO;
    }
    if (fcntl(descriptor, F_GETPATH, path) != 0 || !PearPathIsBelow(path, root)) return NO;
    return realpath(path, resolved) != NULL && PearPathIsBelow(resolved, root);
}

static BOOL PearRepairFileMode(int descriptor, BOOL writable) {
    struct stat info;
    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != geteuid()) {
        return NO;
    }

    mode_t perms = info.st_mode & ALLPERMS;
    mode_t repaired = perms | S_IRUSR;
    // A writable creation can succeed with a read-only mode, leaving the next
    // launch unable to reopen it (e.g. a 0405 placeholder pak). Repair both the
    // first descriptor and EACCES reopens. Hard links can alias unrelated data
    // outside the home, so they must not acquire write access through this shim.
    if (writable && !(perms & S_IWUSR) && info.st_nlink == 1 &&
        PearDescriptorInManagedHome(descriptor)) {
        repaired |= S_IWUSR;
    }
    if (repaired == perms) return NO;
    return fchmod(descriptor, repaired) == 0;
}

static BOOL PearRepairOwnerReadAt(int dirfd, const char *path) {
    struct stat info;
    if (fstatat(dirfd, path, &info, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISREG(info.st_mode) || info.st_uid != geteuid()) return NO;

    mode_t perms = info.st_mode & ALLPERMS;
    // Darwin cannot give us an event descriptor without read OR write access.
    // Retain the legacy owner-read recovery for inaccessible files, but never
    // copy an owner-write bit onto a pathname that could have been swapped.
    if (perms & (S_IRUSR | S_IWUSR)) return NO;
    return fchmodat(dirfd, path, perms | S_IRUSR, AT_SYMLINK_NOFOLLOW) == 0;
}

static BOOL PearRepairFileModeAt(int dirfd, const char *path, BOOL writable) {
    int (*original)(int, const char *, int, ...) =
        (int (*)(int, const char *, int, ...))kInterposeOpenAt.replacee;
    if (!path || !original) return NO;

    // Pin the actual target without following a final symlink or creating/
    // truncating anything, and honor the caller's dirfd. O_EVTONLY still checks
    // access on Darwin; a write-only event descriptor can recover owner read.
    int probeFlags = O_EVTONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK;
    int descriptor = original(dirfd, path, probeFlags, 0);
    if (descriptor < 0 && errno == EACCES) {
        descriptor = original(dirfd, path, probeFlags | O_WRONLY, 0);
    }
    BOOL readRepaired = NO;
    if (descriptor < 0 && errno == EACCES && PearRepairOwnerReadAt(dirfd, path)) {
        readRepaired = YES;
        descriptor = original(dirfd, path, probeFlags, 0);
    }
    if (descriptor < 0) return readRepaired;
    // Only this pinned descriptor can acquire owner write, never a pathname.
    BOOL repaired = PearRepairFileMode(descriptor, writable);
    close(descriptor);
    return repaired || readRepaired;
}

extern "C" int PearTraceOpen(const char *path, int flags, ...) {
    int (*original)(const char *, int, ...) =
        (int (*)(const char *, int, ...))kInterposeOpen.replacee;

    // Darwin arm64 passes variadic arguments on the stack, not in the fixed
    // third-argument register. Preserve libc's ABI in both directions, and do
    // not read a nonexistent mode argument on non-creating opens.
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    BOOL creating = (flags & O_CREAT) != 0;
    BOOL writable = PearOpenIsWritable(flags);
    int result = original ? original(path, flags, mode) : -1;
    int saved = result < 0 ? errno : 0;
    if (result < 0 && saved == EACCES && PearRepairFileModeAt(AT_FDCWD, path, writable)) {
        result = original ? original(path, flags, mode) : -1;
        saved = result < 0 ? errno : 0;
    }
    if (result >= 0 && (creating || writable)) {
        PearRepairFileMode(result, writable);
    }
    if (result < 0) {
        PearTracePath("open", path, result, saved);
    } else if ((flags & (O_CREAT | O_WRONLY | O_RDWR)) != 0) {
        PearTracePath("open-write", path, result, 0);
    }
    errno = saved;
    return result;
}

extern "C" int PearTraceOpenAt(int dirfd, const char *path, int flags, ...) {
    int (*original)(int, const char *, int, ...) =
        (int (*)(int, const char *, int, ...))kInterposeOpenAt.replacee;

    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    // The path trace writes through openat; do not route it back here.
    if (path && strcmp(path, "/tmp/pear-fs.log") == 0) {
        return original ? original(dirfd, path, flags, mode) : -1;
    }

    BOOL creating = (flags & O_CREAT) != 0;
    BOOL writable = PearOpenIsWritable(flags);
    int result = original ? original(dirfd, path, flags, mode) : -1;
    int saved = result < 0 ? errno : 0;
    if (result < 0 && saved == EACCES && PearRepairFileModeAt(dirfd, path, writable)) {
        result = original ? original(dirfd, path, flags, mode) : -1;
        saved = result < 0 ? errno : 0;
    }
    if (result >= 0 && (creating || writable)) {
        PearRepairFileMode(result, writable);
    }
    if (result < 0) {
        PearTracePath("openat", path, result, saved);
    } else if ((flags & (O_CREAT | O_WRONLY | O_RDWR)) != 0) {
        PearTracePath("openat-write", path, result, 0);
    }
    errno = saved;
    return result;
}

extern "C" int PearTraceCreat(const char *path, mode_t mode) {
    int (*original)(const char *, mode_t) =
        (int (*)(const char *, mode_t))kInterposeCreat.replacee;

    int result = original ? original(path, mode) : -1;
    int saved = result < 0 ? errno : 0;
    if (result < 0 && saved == EACCES && PearRepairFileModeAt(AT_FDCWD, path, YES)) {
        result = original ? original(path, mode) : -1;
        saved = result < 0 ? errno : 0;
    }
    if (result >= 0) {
        PearRepairFileMode(result, YES);
    }
    PearTracePath("creat", path, result, saved);
    errno = saved;
    return result;
}

extern "C" FILE *PearTraceFopen(const char *path, const char *mode) {
    FILE *(*original)(const char *, const char *) =
        (FILE *(*)(const char *, const char *))kInterposeFopen.replacee;

    BOOL writable = mode != NULL && strpbrk(mode, "wa+") != NULL;
    FILE *result = original ? original(path, mode) : NULL;
    int saved = result == NULL ? errno : 0;
    if (result == NULL && saved == EACCES && PearRepairFileModeAt(AT_FDCWD, path, writable)) {
        result = original ? original(path, mode) : NULL;
        saved = result == NULL ? errno : 0;
    }
    if (result != NULL && writable) {
        int descriptor = fileno(result);
        if (descriptor >= 0) PearRepairFileMode(descriptor, YES);
    }
    if (result == NULL) PearTracePath("fopen", path, 0, saved);
    errno = saved;
    return result;
}

extern "C" mode_t PearTraceUmask(mode_t mask) {
    mode_t (*original)(mode_t) = (mode_t (*)(mode_t))kInterposeUmask.replacee;

    // Never mask the owner's own access. A port that sets 0777 otherwise
    // writes files and directories that it cannot read itself.
    mode_t sanitized = mask & 0077;
    return original ? original(sanitized) : sanitized;
}

extern "C" int PearTraceChmod(const char *path, mode_t mode);
extern "C" int PearTraceFchmod(int descriptor, mode_t mode);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeChmod
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceChmod,
        (const void *)(uintptr_t)&chmod
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeFchmod
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceFchmod,
        (const void *)(uintptr_t)&fchmod
    };

/// Some update modules explicitly chmod their manifests to a write-only mode.
/// Applying the same owner-read floor here makes the repair independent of how
/// the mode was chosen (open, creat, fopen, chmod or fchmod).
extern "C" int PearTraceChmod(const char *path, mode_t mode) {
    int (*original)(const char *, mode_t) =
        (int (*)(const char *, mode_t))kInterposeChmod.replacee;
    return original ? original(path, PearSafeMode(mode)) : -1;
}

extern "C" int PearTraceFchmod(int descriptor, mode_t mode) {
    int (*original)(int, mode_t) =
        (int (*)(int, mode_t))kInterposeFchmod.replacee;
    return original ? original(descriptor, PearSafeMode(mode)) : -1;
}

extern "C" int PearTraceFaccessat(int dirfd, const char *path, int mode, int flags);
extern "C" int PearTraceStatfs(const char *path, struct statfs *info);
extern "C" int PearTraceCsops(pid_t pid, unsigned int ops, void *address, size_t size);
extern "C" long PearTraceSyscall(int number, ...);
extern "C" char *PearTraceGetenv(const char *name);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeFaccessat
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceFaccessat,
        (const void *)(uintptr_t)&faccessat
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeStatfs
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceStatfs,
        (const void *)(uintptr_t)&statfs
    };

extern "C" int csops(pid_t pid, unsigned int ops, void *address, size_t size);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeCsops
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceCsops,
        (const void *)(uintptr_t)&csops
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeSyscall
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceSyscall,
        (const void *)(uintptr_t)&syscall
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeGetenv
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearTraceGetenv,
        (const void *)(uintptr_t)&getenv
    };

static BOOL PearTraceEnvInteresting(const char *name) {
    static const char *names[] = {
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH",
        "SIMULATOR_UDID", "SIMULATOR_MODEL_IDENTIFIER", "XCTestConfigurationFilePath",
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (strcmp(name, names[i]) == 0) return YES;
    }
    return NO;
}

extern "C" long PearTraceSyscall(int number, ...) {
    va_list args;
    va_start(args, number);
    long a1 = va_arg(args, long);
    long a2 = va_arg(args, long);
    long a3 = va_arg(args, long);
    long a4 = va_arg(args, long);
    long a5 = va_arg(args, long);
    long a6 = va_arg(args, long);
    va_end(args);

    // A raw syscall skips the interposed libc wrappers. Route the sysctl
    // number through the device layer so hardware queries stay consistent.
    if (number == SYS_sysctl && a1 != 0) {
        long result = PearSysctlMIB((int *)a1, (u_int)a2, (void *)a3,
                                    (size_t *)a4, (void *)a5, (size_t)a6);
        if (PearTraceEnabled()) {
            PearTraceWrite("syscall-sysctl", "", result, errno);
        }
        return result;
    }

    long (*original)(int, ...) = (long (*)(int, ...))kInterposeSyscall.replacee;
    long result = original ? original(number, a1, a2, a3, a4, a5, a6) : -1;
    int saved = errno;
    if (PearTraceEnabled()) {
        char label[160];
        snprintf(label, sizeof(label), "nr=%d a1=0x%lx a2=0x%lx a3=0x%lx",
                 number, a1, a2, a3);
        PearTraceWrite("syscall", label, result, saved);
    }
    errno = saved;
    return result;
}

extern "C" char *PearTraceGetenv(const char *name) {
    char *(*original)(const char *) = (char *(*)(const char *))kInterposeGetenv.replacee;
    char *value = original ? original(name) : NULL;
    if (PearTraceEnabled() && name && PearTraceEnvInteresting(name)) {
        PearTraceWrite("getenv", name, value ? 1 : 0, 0);
    }
    return value;
}

extern "C" int PearTraceFaccessat(int dirfd, const char *path, int mode, int flags) {
    int (*original)(int, const char *, int, int) =
        (int (*)(int, const char *, int, int))kInterposeFaccessat.replacee;
    int result = original ? original(dirfd, path, mode, flags) : -1;
    int saved = errno;
    if (result != 0) PearTracePath("faccessat", path, result, saved);
    else PearTracePath("faccessat-ok", path, mode, 0);
    errno = saved;
    return result;
}

extern "C" int PearTraceStatfs(const char *path, struct statfs *info) {
    int (*original)(const char *, struct statfs *) =
        (int (*)(const char *, struct statfs *))kInterposeStatfs.replacee;
    int result = original ? original(path, info) : -1;
    int saved = errno;
    if (result == 0 || saved != ENOENT) {
        PearTracePath("statfs", path, result, saved);
    }
    errno = saved;
    return result;
}

extern "C" int PearTraceCsops(pid_t pid, unsigned int ops, void *address, size_t size) {
    int (*original)(pid_t, unsigned int, void *, size_t) =
        (int (*)(pid_t, unsigned int, void *, size_t))kInterposeCsops.replacee;
    int result = original ? original(pid, ops, address, size) : -1;
    int saved = errno;
    if (PearTraceEnabled()) {
        char label[512];
        int used = snprintf(label, sizeof(label), "pid=%d ops=0x%x size=%zu", pid, ops, size);
        if (result == 0 && address && size > 0 && used > 0 && used < (int)sizeof(label)) {
            size_t shown = size < 24 ? size : 24;
            used += snprintf(label + used, sizeof(label) - (size_t)used, " data=");
            for (size_t i = 0; i < shown && used + 3 < (int)sizeof(label); i++) {
                used += snprintf(label + used, sizeof(label) - (size_t)used, "%02x",
                                 ((const unsigned char *)address)[i]);
            }
        }
        PearTraceWrite("csops", label, result, saved);
    }
    errno = saved;
    return result;
}

extern "C" pid_t PearTraceFork(void) {
    pid_t (*original)(void) = (pid_t (*)(void))kInterposeFork.replacee;
    if (PearTraceEnabled()) {
        PearTraceWrite("fork", "", 0, 0);
    }
    return original ? original() : -1;
}

extern "C" FILE *PearTracePopen(const char *command, const char *mode) {
    FILE *(*original)(const char *, const char *) =
        (FILE *(*)(const char *, const char *))kInterposePopen.replacee;
    if (PearTraceEnabled()) {
        PearTraceWrite("popen", command ?: "(null)", 0, 0);
    }
    return original ? original(command, mode) : NULL;
}
