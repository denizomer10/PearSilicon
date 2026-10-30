// Headless filesystem fixture: production wrappers, synthetic temporary files.
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string>

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL line %d: %s (errno=%d: %s)\n", \
                __LINE__, #condition, errno, strerror(errno)); \
        exit(1); \
    } \
} while (0)

static int FixtureFstat(int, struct stat *);
static int FixtureFchmod(int, mode_t);
static int FixtureGetPath(int, int, char *);

// Keep the actual production tables, but in an inert section: the fixture must
// not interpose libc for Foundation, setup, native controls, or process startup.
// Only these three adapters inject deterministic metadata/failure/race cases;
// normal runs use the real filesystem and the real libc original entry points.
#define section(name) section("__DATA,__pear_fs_test")
#define fstat FixtureFstat
#define fchmod FixtureFchmod
#define fcntl FixtureGetPath
#ifndef PEAR_FILESYSTEM_SOURCE
#define PEAR_FILESYSTEM_SOURCE "../runtime/SandboxShim.mm"
#endif
#include PEAR_FILESYSTEM_SOURCE
#undef section
#undef fstat
#undef fchmod
#undef fcntl

void PearLog(NSString *, ...) { abort(); }
extern "C" int PearSysctlMIB(int *, u_int, void *, size_t *, void *, size_t) {
    errno = ENOTSUP;
    return -1;
}

static std::string gRoot, gHome, gOutside;
static const char kPayload[] = "synthetic placeholder; preserve these bytes\n";
static unsigned gChmodCalls, gProbeCalls;
static ino_t gForeignInode;
static int gChmodError, gGetPathError, gProbeError, gRetryError, gOpenCalls;
static std::string gReportedPath, gRedirectProbe, gSwapPath, gSwapTarget;

static bool Below(const std::string &path, const std::string &root) {
    return path.size() > root.size() && path.compare(0, root.size(), root) == 0 &&
           path[root.size()] == '/';
}
static void TemporaryPath(const std::string &path) { CHECK(Below(path, gRoot)); }
static void MakeDirectory(const std::string &path, mode_t mode = 0700) {
    TemporaryPath(path);
    CHECK(mkdir(path.c_str(), mode) == 0);
}
static struct stat Info(const std::string &path) {
    struct stat info;
    CHECK(stat(path.c_str(), &info) == 0);
    return info;
}
static void CheckMode(const std::string &path, mode_t mode) {
    mode_t actual = Info(path).st_mode & ALLPERMS;
    if (actual != mode) {
        fprintf(stderr, "FAIL permissions %s: expected %04o, got %04o\n",
                path.c_str(), (unsigned)mode, (unsigned)actual);
        exit(1);
    }
}
static void Seed(const std::string &path, mode_t mode, off_t size = sizeof(kPayload) - 1) {
    TemporaryPath(path);
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    CHECK(fd >= 0);
    CHECK(write(fd, kPayload, sizeof(kPayload) - 1) == sizeof(kPayload) - 1);
    CHECK(ftruncate(fd, size) == 0);
    CHECK(fchmod(fd, mode) == 0);
    CHECK(close(fd) == 0);
    CHECK(Info(path).st_uid == geteuid());
    CheckMode(path, mode);
}
static void CheckContents(const std::string &path, off_t size = sizeof(kPayload) - 1) {
    CHECK(Info(path).st_size == size);
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    CHECK(fd >= 0);
    char bytes[sizeof(kPayload) - 1];
    CHECK(read(fd, bytes, sizeof(bytes)) == sizeof(bytes));
    CHECK(memcmp(bytes, kPayload, sizeof(bytes)) == 0);
    CHECK(close(fd) == 0);
}
static void Link(const std::string &target, const std::string &path) {
    TemporaryPath(target);
    TemporaryPath(path);
    CHECK(symlink(target.c_str(), path.c_str()) == 0);
}
static int DirectoryFD(const std::string &path) {
    int fd = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    CHECK(fd >= 0);
    return fd;
}
#define Close(expression) do { \
    int closeFD = (expression); \
    CHECK(closeFD >= 0); \
    CHECK(close(closeFD) == 0); \
} while (0)
static void Denied(int result) { CHECK(result == -1); CHECK(errno == EACCES); }
static void Denied(FILE *result) { CHECK(result == NULL); CHECK(errno == EACCES); }

static int FixtureFstat(int fd, struct stat *info) {
    int result = fstat(fd, info);
    if (result == 0 && gForeignInode && info->st_ino == gForeignInode) {
        info->st_uid = geteuid() + 1; // No chown/root access or real foreign files.
    }
    return result;
}
static int FixtureFchmod(int fd, mode_t mode) {
    ++gChmodCalls;
    if (gChmodError) { errno = gChmodError; return -1; }
    if (!gSwapPath.empty()) {
        CHECK(rename(gSwapPath.c_str(), (gSwapPath + ".pinned").c_str()) == 0);
        Link(gSwapTarget, gSwapPath);
        gSwapPath.clear();
    }
    return fchmod(fd, mode);
}
static int FixtureGetPath(int fd, int command, char *path) {
    CHECK(command == F_GETPATH);
    if (gGetPathError) { errno = gGetPathError; return -1; }
    if (!gReportedPath.empty()) {
        CHECK(gReportedPath.size() < PATH_MAX);
        strcpy(path, gReportedPath.c_str());
        return 0;
    }
    return fcntl(fd, command, path);
}
static int FixtureOpenAt(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    if (flags & O_EVTONLY) {
        ++gProbeCalls;
        CHECK((flags & (O_NOFOLLOW | O_CLOEXEC)) == (O_NOFOLLOW | O_CLOEXEC));
        CHECK((flags & (O_CREAT | O_TRUNC)) == 0);
        if (gProbeError) { errno = gProbeError; return -1; }
        if (!gRedirectProbe.empty()) return openat(AT_FDCWD, gRedirectProbe.c_str(), flags, mode);
    }
    return openat(dirfd, path, flags, mode);
}
static int FixtureOpen(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    if (++gOpenCalls == 2 && gRetryError) { errno = gRetryError; return -1; }
    return open(path, flags, mode);
}

static void PlaceholderRegression(void) {
    MakeDirectory(gHome + "/Library");
    MakeDirectory(gHome + "/Library/g112");
    MakeDirectory(gHome + "/Library/g112/Saved");
    MakeDirectory(gHome + "/Library/g112/Saved/Paks");
    std::string path = gHome + "/Library/g112/Saved/Paks/Patch_100_P.tmp";
    constexpr off_t size = 50967061;
    Seed(path, 0405, size); // Sparse; never reads/copies any installed game data.
    Denied(open(path.c_str(), O_WRONLY | O_CLOEXEC));
    int fd = PearTraceOpen(path.c_str(), O_WRONLY | O_CLOEXEC, 0);
    if (fd < 0) {
        fprintf(stderr, "REGRESSION: mode 0405 writable reopen failed (errno=%d)\n", errno);
        exit(1);
    }
    Close(fd);
    CheckMode(path, 0605);
    CheckContents(path, size);
    Close(open(path.c_str(), O_RDWR | O_CLOEXEC));
    puts("PASS exact 0405 / 50967061-byte placeholder: native EACCES -> shim reopen, 0605, data intact");
}

static void CreationModes(void) {
    int dirfd = DirectoryFD(gHome);
    unsigned serial = 0;
    const mode_t modes[] = {0000, 0405, 0215, 0100, 0444, 04705, 02705, 01705};
    const int accessModes[] = {O_RDONLY, O_WRONLY, O_RDWR};
    for (mode_t mode : modes) {
        for (int access : accessModes) {
            for (int api = 0; api < 3; ++api) {
                if (api == 2 && access != O_WRONLY) continue;
                std::string leaf = "create-" + std::to_string(++serial);
                std::string path = gHome + "/" + leaf;
                int flags = access | O_CREAT | O_EXCL | O_CLOEXEC;
                // Darwin can discard special bits at creation. Compare to a
                // real native control, not bits the kernel never installed.
                std::string control = gHome + "/native-" + std::to_string(serial);
                Close(open(control.c_str(), flags, mode));
                mode_t nativeMode = Info(control).st_mode & ALLPERMS;
                int fd = api == 0 ? PearTraceOpen(path.c_str(), flags, mode) :
                         api == 1 ? PearTraceOpenAt(dirfd, leaf.c_str(), flags, mode) :
                                    PearTraceCreat(path.c_str(), mode);
                Close(fd);
                mode_t expected = nativeMode | S_IRUSR | (access == O_RDONLY ? 0 : S_IWUSR);
                CheckMode(path, expected);
                Close(open(path.c_str(), access | O_CLOEXEC));
                CHECK(Info(path).st_size == 0);
            }
        }
    }
    Close(dirfd);
    for (mode_t mode : {04015, 02015, 01015, 04405, 02405, 01405}) {
        std::string path = gHome + "/special-bits-" + std::to_string(mode);
        Seed(path, mode);
        int access = mode & S_IRUSR ? O_WRONLY : O_RDONLY;
        Close(PearTraceOpen(path.c_str(), access, 0));
        CheckMode(path, mode | S_IRUSR | (access == O_WRONLY ? S_IWUSR : 0));
        CheckContents(path);
    }
    // Simulate a hostile raw umask without altering any process/profile outside
    // this fixture. Post-open repair must not restore masked group/other bits.
    mode_t oldMask = umask(0777);
    std::string path = gHome + "/masked-creation";
    Close(PearTraceOpen(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0405));
    umask(oldMask);
    CheckMode(path, 0600);
    puts("PASS open/openat/creat malformed creation modes, O_ACCMODE, special bits, restrictive umask");
}

static void WritableReopens(void) {
    int dirfd = DirectoryFD(gHome);
    unsigned serial = 0;
    for (mode_t mode : {0000, 0105, 0200, 0405}) {
        for (int api = 0; api < 4; ++api) {
            std::string leaf = "writable-reopen-" + std::to_string(++serial);
            std::string path = gHome + "/" + leaf;
            Seed(path, mode);
            if (api == 0) Close(PearTraceOpen(path.c_str(), O_RDWR, 0));
            else if (api == 1) Close(PearTraceOpenAt(dirfd, leaf.c_str(), O_WRONLY, 0));
            else if (api == 2) Close(PearTraceCreat(path.c_str(), 0405));
            else {
                FILE *stream = PearTraceFopen(path.c_str(), "r+");
                CHECK(stream != NULL);
                CHECK(fclose(stream) == 0);
            }
            CheckMode(path, mode | S_IRUSR | S_IWUSR);
            if (api == 2) CHECK(Info(path).st_size == 0); // Requested creat truncation.
            else CheckContents(path);
        }
    }
    Close(dirfd);
    std::string outside = gOutside + "/inaccessible-outside";
    Seed(outside, 0000);
    Denied(PearTraceOpen(outside.c_str(), O_WRONLY | O_TRUNC, 0));
    CheckMode(outside, 0400);
    CheckContents(outside);
    puts("PASS open/openat/creat/fopen existing writable reopens, missing read/write bits, outside 0000 never gains write");
}

static void FopenModesAndReadOnly(void) {
    unsigned serial = 0;
    for (const char *mode : {"w", "wb", "a", "ab", "r+", "r+b", "w+", "a+"}) {
        std::string path = gHome + "/fopen-" + std::to_string(++serial);
        Seed(path, 0405);
        FILE *stream = PearTraceFopen(path.c_str(), mode);
        CHECK(stream != NULL);
        CHECK(fclose(stream) == 0);
        CheckMode(path, 0605);
        if (mode[0] == 'w') CHECK(Info(path).st_size == 0);
        else CheckContents(path);
    }
    for (const std::string &directory : {gHome, gOutside}) {
        std::string path = directory + "/readonly";
        Seed(path, 0405);
        unsigned calls = gChmodCalls;
        Close(PearTraceOpen(path.c_str(), O_RDONLY | O_NONBLOCK, 0));
        Close(PearTraceOpen(path.c_str(), O_RDONLY | O_CREAT, 0000));
        int dirfd = DirectoryFD(directory);
        Close(PearTraceOpenAt(dirfd, "readonly", O_RDONLY, 0));
#ifndef PEAR_FILESYSTEM_BASELINE
        // Actual libc-compatible calls with no mode argument at all.
        Close(PearTraceOpen(path.c_str(), O_RDONLY));
        Close(PearTraceOpenAt(dirfd, "readonly", O_RDONLY));
#endif
        Close(dirfd);
        FILE *stream = PearTraceFopen(path.c_str(), "rb");
        CHECK(stream != NULL);
        CHECK(fclose(stream) == 0);
        CHECK(gChmodCalls == calls);
        CheckMode(path, 0405);
        CheckContents(path);

        std::string unreadable = directory + "/owner-read-floor";
        Seed(unreadable, 0000);
        Close(PearTraceOpen(unreadable.c_str(), O_RDONLY, 0));
        CheckMode(unreadable, 0400); // Generic read recovery must NOT add write.
        CheckContents(unreadable);
    }
    mode_t oldMask = umask(0777);
    for (const std::string &directory : {gHome, gOutside}) {
        for (const char *mode : {"w", "a"}) {
            std::string path = directory + "/masked-fopen-" + mode;
            FILE *stream = PearTraceFopen(path.c_str(), mode);
            CHECK(stream != NULL);
            CHECK(fclose(stream) == 0);
            CheckMode(path, directory == gHome ? 0600 : 0400);
        }
    }
    umask(oldMask);
    std::string event = gHome + "/event-only";
    Seed(event, 0000);
    Close(PearTraceOpen(event.c_str(), O_EVTONLY | O_CLOEXEC, 0));
    CheckMode(event, 0400);
    puts("PASS fopen w/a/+ modes; read-only requests and O_EVTONLY do not acquire write permission");
}

static void AllWritableAPIsDenied(const std::string &path) {
    unsigned calls = gChmodCalls;
    Denied(PearTraceOpen(path.c_str(), O_WRONLY | O_TRUNC, 0));
    Denied(PearTraceOpen(path.c_str(), O_RDWR | O_TRUNC | O_CREAT, 0600));
    Denied(PearTraceOpenAt(AT_FDCWD, path.c_str(), O_WRONLY | O_TRUNC, 0));
    Denied(PearTraceCreat(path.c_str(), 0600));
    for (const char *mode : {"w", "a", "r+", "w+", "a+"}) {
        Denied(PearTraceFopen(path.c_str(), mode));
    }
    CHECK(gChmodCalls == calls);
    CheckMode(path, 0405);
    CheckContents(path); // In particular, failed w/creat/O_TRUNC did not truncate.
}

static void Boundaries(void) {
    std::string sibling = gHome + "-sibling";
    std::string bundle = gRoot + "/Installed.app";
    std::string defaultHome = gRoot + "/default-support";
    MakeDirectory(sibling);
    MakeDirectory(bundle);
    MakeDirectory(defaultHome);
    for (const std::string &directory : {gOutside, sibling, bundle, defaultHome,
                                        std::string(getenv("HOME"))}) {
        std::string path = directory + "/protected";
        Seed(path, 0405);
        AllWritableAPIsDenied(path);
        // Even successful first creations outside the data home must not gain
        // owner-write from repair (including the formerly special mode zero).
        for (mode_t mode : {0000, 0405}) {
            std::string created = directory + "/created-" + std::to_string(mode);
            Close(PearTraceOpen(created.c_str(), O_WRONLY | O_CREAT | O_EXCL, mode));
            CheckMode(created, mode | S_IRUSR);
        }
    }
    std::string victim = gOutside + "/protected";
    Link(gOutside, gHome + "/escape-directory");
    AllWritableAPIsDenied(gHome + "/escape-directory/protected");
    Link(victim, gHome + "/escape-file");
    AllWritableAPIsDenied(gHome + "/escape-file");
    AllWritableAPIsDenied(gHome + "/../../user-files/protected");

    std::string hardlink = gHome + "/hardlink";
    CHECK(link(victim.c_str(), hardlink.c_str()) == 0);
    AllWritableAPIsDenied(hardlink);
    CheckMode(victim, 0405);

    const std::string configuredHome = getenv("PEAR_HOME_DIR");
    for (const char *invalidHome : {"", "/", "relative-home", "/nonexistent-filesystem-smoke-root"}) {
        CHECK(setenv("PEAR_HOME_DIR", invalidHome, 1) == 0);
        std::string path = gHome + "/invalid-home-" + std::to_string(gProbeCalls);
        Seed(path, 0405);
        AllWritableAPIsDenied(path);
    }
    CHECK(unsetenv("PEAR_HOME_DIR") == 0);
    std::string absent = gHome + "/absent-home";
    Seed(absent, 0405);
    AllWritableAPIsDenied(absent);
    CHECK(setenv("PEAR_HOME_DIR", configuredHome.c_str(), 1) == 0);

    // A relocated root may itself have a symlink alias and trailing slash.
    std::string alias = gRoot + "/home-alias";
    Link(gHome, alias);
    CHECK(setenv("PEAR_HOME_DIR", (alias + "/").c_str(), 1) == 0);
    std::string aliased = alias + "/aliased-file";
    Seed(aliased, 0405);
    Close(PearTraceOpen(aliased.c_str(), O_RDWR, 0));
    CheckMode(aliased, 0605);
    CHECK(setenv("PEAR_HOME_DIR", configuredHome.c_str(), 1) == 0);
    puts("PASS relocated-home boundary, bundle/HOME/support/prefix siblings, symlink escapes, hardlinks, unset/invalid roots");
}

static void RelativeOpenAt(void) {
    std::string inside = gHome + "/dirfd";
    std::string cwd = gRoot + "/cwd";
    MakeDirectory(inside);
    MakeDirectory(cwd);
    Seed(inside + "/relative.tmp", 0405);
    Seed(cwd + "/relative.tmp", 0405);
    int dirfd = DirectoryFD(inside);
    CHECK(chdir(cwd.c_str()) == 0);
    Close(PearTraceOpenAt(dirfd, "relative.tmp", O_RDWR, 0));
    CheckMode(inside + "/relative.tmp", 0605);
    CheckContents(inside + "/relative.tmp");
    CheckMode(cwd + "/relative.tmp", 0405);
    CheckContents(cwd + "/relative.tmp");
    Close(PearTraceOpenAt(dirfd, "new-relative.tmp", O_WRONLY | O_CREAT | O_EXCL, 0405));
    CheckMode(inside + "/new-relative.tmp", 0605);
    Close(dirfd);

    // Conversely, an inside CWD cannot authorize a target reached by an outside
    // dirfd; nor may a symlinked intermediate component escape containment.
    CHECK(chdir(gHome.c_str()) == 0);
    Seed(gHome + "/protected", 0405);
    int outsidefd = DirectoryFD(gOutside);
    Denied(PearTraceOpenAt(outsidefd, "protected", O_WRONLY | O_TRUNC, 0));
    Close(outsidefd);
    int homefd = DirectoryFD(gHome);
    Denied(PearTraceOpenAt(homefd, "escape-directory/protected", O_RDWR | O_TRUNC, 0));
    Close(homefd);
    CheckMode(gHome + "/protected", 0405);
    CheckContents(gOutside + "/protected");
    // Absolute openat paths ignore even an invalid dirfd.
    std::string absolute = gHome + "/absolute-openat";
    Seed(absolute, 0405);
    Close(PearTraceOpenAt(-1, absolute.c_str(), O_WRONLY, 0));
    CheckMode(absolute, 0605);
    CHECK(chdir(gRoot.c_str()) == 0);
    puts("PASS non-CWD dirfd-relative openat, inverse outside dirfd, relative symlink escape, absolute paths");
}

static void ErrorsAndDescriptorGuards(void) {
    std::string path = gHome + "/error-target";
    Seed(path, 0405);
    unsigned probes = gProbeCalls, calls = gChmodCalls;
    CHECK(PearTraceOpen((gHome + "/missing").c_str(), O_WRONLY, 0) == -1 && errno == ENOENT);
    CHECK(PearTraceOpen((path + "/child").c_str(), O_WRONLY, 0) == -1 && errno == ENOTDIR);
    CHECK(PearTraceOpen(gHome.c_str(), O_WRONLY, 0) == -1 && errno == EISDIR);
    CHECK(PearTraceOpen(path.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0600) == -1 && errno == EEXIST);
    CHECK(PearTraceOpenAt(-1, "relative", O_WRONLY, 0) == -1 && errno == EBADF);
    CHECK(PearTraceOpen((gHome + "/escape-file").c_str(), O_WRONLY | O_NOFOLLOW, 0) == -1 && errno == ELOOP);
    CHECK(gProbeCalls == probes && gChmodCalls == calls);
    CheckContents(path);

    gProbeError = ENOENT;
    Denied(PearTraceOpen(path.c_str(), O_WRONLY, 0));
    gProbeError = 0;
    gGetPathError = EIO;
    Denied(PearTraceOpen(path.c_str(), O_WRONLY, 0));
    gGetPathError = 0;
    gChmodError = EPERM;
    Denied(PearTraceOpen(path.c_str(), O_WRONLY, 0));
    gChmodError = 0;
    CheckMode(path, 0405);

    gForeignInode = Info(path).st_ino;
    calls = gChmodCalls;
    Denied(PearTraceOpen(path.c_str(), O_WRONLY, 0));
    CHECK(gChmodCalls == calls);
    gForeignInode = 0;
    CheckMode(path, 0405);

    std::string fifo = gHome + "/not-a-regular-file";
    CHECK(mkfifo(fifo.c_str(), 0405) == 0);
    Denied(PearTraceOpen(fifo.c_str(), O_RDWR | O_NONBLOCK, 0));
    CheckMode(fifo, 0405);

    // Prove the actual probe descriptor, not the requested inside pathname,
    // determines containment. All redirected objects are still synthetic.
    gRedirectProbe = gOutside + "/protected";
    Denied(PearTraceOpen(path.c_str(), O_WRONLY, 0));
    CheckMode(gRedirectProbe, 0405);
    // Independently exercise the canonical-path boundary after F_GETPATH.
    gReportedPath = gHome + "/escape-file";
    Denied(PearTraceOpen(path.c_str(), O_WRONLY, 0));
    gReportedPath.clear();
    gRedirectProbe.clear();
    CheckMode(path, 0405);

    const void *original = kInterposeOpen.replacee;
    kInterposeOpen.replacee = (const void *)(uintptr_t)&FixtureOpen;
    gOpenCalls = 0;
    gRetryError = ENOSPC;
    CHECK(PearTraceOpen(path.c_str(), O_WRONLY, 0) == -1 && errno == ENOSPC);
    CHECK(gOpenCalls == 2);
    kInterposeOpen.replacee = original;
    gRetryError = 0;
    CheckMode(path, 0605);
    CheckContents(path);
    puts("PASS unrelated errno, failed probe/fchmod errno, regular-file and simulated foreign-UID guards, actual fd + realpath checks");
}

static void DescriptorSwap(void) {
    std::string path = gHome + "/swap-target";
    std::string victim = gOutside + "/swap-victim";
    Seed(path, 0405);
    Seed(victim, 0405);
    gSwapPath = path;
    gSwapTarget = victim;
    // Swap the pathname after validation, immediately before the real fchmod.
    // Only the pinned inode may change; retrying the new outside link must fail.
    Denied(PearTraceOpen(path.c_str(), O_WRONLY | O_TRUNC, 0));
    CHECK(gSwapPath.empty());
    CheckMode(path + ".pinned", 0605);
    CheckContents(path + ".pinned");
    CheckMode(victim, 0405);
    CheckContents(victim);
    puts("PASS deterministic pathname swap: fchmod changes pinned inside inode, never outside replacement; no truncation");
}

static void PersistentNativeReopens(void) {
    std::string placeholder = gHome + "/Library/g112/Saved/Paks/Patch_100_P.tmp";
    Close(open(placeholder.c_str(), O_RDWR | O_CLOEXEC));
    CheckMode(placeholder, 0605);
    CheckContents(placeholder, 50967061);
    for (const char *leaf : {"masked-creation", "masked-fopen-w", "masked-fopen-a"}) {
        std::string path = gHome + "/" + leaf;
        Close(open(path.c_str(), O_RDWR | O_CLOEXEC));
        CheckMode(path, 0600);
    }
    for (const std::string &path : {gHome + "/readonly", gOutside + "/protected"}) {
        Denied(open(path.c_str(), O_WRONLY | O_TRUNC));
        CheckMode(path, 0405);
        CheckContents(path);
    }
    CHECK(gChmodCalls == 0 && gProbeCalls == 0);
    puts("PASS fresh-process native-only reopen: repaired permissions persist; read-only/outside files still protected");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        CHECK(argc == 2);
        CHECK(geteuid() != 0); // Native EACCES is a required regression control.
        CHECK(getenv("PEAR_IOS_SANDBOX") == NULL);
        CHECK(getenv("PEAR_DEBUG_PATHS") == NULL && !PearTraceEnabled());
        const char *root = getenv("FILESYSTEM_SMOKE_ROOT");
        const char *home = getenv("PEAR_HOME_DIR");
        CHECK(root && root[0] == '/' && home && home[0] == '/');
        char canonical[PATH_MAX];
        CHECK(realpath(root, canonical) != NULL);
        gRoot = canonical;
        gHome = home;
        gOutside = gRoot + "/user-files";
        CHECK(Below(gHome, gRoot));
        CHECK(chdir(gRoot.c_str()) == 0);
        umask(0); // Child process only; exact permission-bit assertions.
        kInterposeOpenAt.replacee = (const void *)(uintptr_t)&FixtureOpenAt;
        if (strcmp(argv[1], "persist") == 0) {
            PersistentNativeReopens();
            return 0;
        }
        PlaceholderRegression();
        if (strcmp(argv[1], "regression") == 0) return 0;
        CHECK(strcmp(argv[1], "all") == 0);
        CreationModes();
        WritableReopens();
        FopenModesAndReadOnly();
        Boundaries();
        RelativeOpenAt();
        ErrorsAndDescriptorGuards();
        DescriptorSwap();
        puts("PASS all production filesystem-wrapper checks (no sandbox profile, UI, network, or installed app access)");
    }
    return 0;
}
