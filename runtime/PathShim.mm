// PathShim.mm
//
// Keeps an app's data out of the real user folders.
//
// On macOS a windowed iOS app is not sandboxed, so its home-relative directories
// resolve to the user's real ones: `NSDocumentDirectory` is `~/Documents`,
// `NSLibraryDirectory` is `~/Library`, and so on. Games then scatter their saves
// across `~/Documents` (and friends), which is both messy and indistinguishable
// from the user's own files.
//
// This redirects the app's home-relative directories into a per-app folder:
//
//   ~/Library/Application Support/PearSilicon/Games/<bundleID>/
//     Documents/            Library/            Library/Caches/ …
//
// It covers the APIs apps actually use for this — the two `NSFileManager`
// directory lookups and the classic `NSSearchPathForDirectoriesInDomains` — plus
// `NSHomeDirectory`, so a path built by hand is contained too.
//
// Disable with `PEAR_NO_PATH_SHIM`; override the container with `PEAR_HOME_DIR`.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString *gShimRoot = nil; // nil = disabled / not yet resolved

/// The real home directory. Read from the environment, not `NSHomeDirectory`,
/// because that is exactly what we are redirecting.
static NSString *PearRealHome(void) {
    const char *home = getenv("HOME");
    if (home && home[0]) return [NSString stringWithUTF8String:home];
    return @"/tmp";
}

/// The per-app container root, resolved once.
static NSString *PearShimRoot(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *env = NSProcessInfo.processInfo.environment;
        if (env[@"PEAR_NO_PATH_SHIM"]) return;

        if ([env[@"PEAR_HOME_DIR"] length] > 0) {
            gShimRoot = [env[@"PEAR_HOME_DIR"] copy];
            return;
        }
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
        gShimRoot = [[PearRealHome()
            stringByAppendingPathComponent:@"Library/Application Support/PearSilicon/Games"]
            stringByAppendingPathComponent:bundleID];
    });
    return gShimRoot;
}

/// Maps a user-domain directory into the container, or nil to leave it alone.
static NSString *PearShimmedSubpath(NSSearchPathDirectory directory) {
    switch (directory) {
        case NSDocumentDirectory:          return @"Documents";
        case NSLibraryDirectory:           return @"Library";
        case NSApplicationSupportDirectory: return @"Library/Application Support";
        case NSCachesDirectory:            return @"Library/Caches";
        case NSUserDirectory:              return @"";
        default:                           return nil;
    }
}

/// The shimmed path for a directory, optionally creating it. nil = don't shim.
static NSString *PearShimmedPath(NSSearchPathDirectory directory, NSSearchPathDomainMask domain, BOOL create) {
    NSString *root = PearShimRoot();
    if (!root) return nil;
    if (domain != NSUserDomainMask) return nil; // only the user domain lives under home
    NSString *subpath = PearShimmedSubpath(directory);
    if (!subpath) return nil;

    NSString *path = subpath.length ? [root stringByAppendingPathComponent:subpath] : root;
    if (create) {
        [NSFileManager.defaultManager createDirectoryAtPath:path
                                withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    return path;
}

#pragma mark - NSFileManager

static void PearInstallFileManagerShim(void) {
    Class fileManager = NSFileManager.class;

    // - URLForDirectory:inDomain:appropriateForURL:create:error:
    SEL urlSel = NSSelectorFromString(@"URLForDirectory:inDomain:appropriateForURL:create:error:");
    Method urlMethod = class_getInstanceMethod(fileManager, urlSel);
    if (urlMethod) {
        IMP original = method_getImplementation(urlMethod);
        method_setImplementation(urlMethod, imp_implementationWithBlock(
            ^NSURL *(id self, NSSearchPathDirectory directory, NSSearchPathDomainMask domain,
                     NSURL *url, BOOL create, NSError **error) {
                NSString *path = PearShimmedPath(directory, domain, create);
                if (path) return [NSURL fileURLWithPath:path isDirectory:YES];
                return ((NSURL *(*)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask,
                                    NSURL *, BOOL, NSError **))original)(self, urlSel, directory, domain,
                                                                        url, create, error);
            }));
    }

    // - URLsForDirectory:inDomains:  (older API, still used)
    SEL urlsSel = NSSelectorFromString(@"URLsForDirectory:inDomains:");
    Method urlsMethod = class_getInstanceMethod(fileManager, urlsSel);
    if (urlsMethod) {
        IMP original = method_getImplementation(urlsMethod);
        method_setImplementation(urlsMethod, imp_implementationWithBlock(
            ^NSArray<NSURL *> *(id self, NSSearchPathDirectory directory, NSSearchPathDomainMask domain) {
                NSString *path = PearShimmedPath(directory, domain, NO);
                if (path) return @[[NSURL fileURLWithPath:path isDirectory:YES]];
                return ((NSArray<NSURL *> *(*)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask))original)(
                    self, urlsSel, directory, domain);
            }));
    }
}

#pragma mark - dyld interposing

extern "C" NSArray<NSString *> *NSSearchPathForDirectoriesInDomains(
    NSSearchPathDirectory directory, NSSearchPathDomainMask domainMask, BOOL expandTilde);

static NSArray<NSString *> *PearSearchPathForDirectoriesInDomains(
    NSSearchPathDirectory directory, NSSearchPathDomainMask domainMask, BOOL expandTilde);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeSearchPaths
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSearchPathForDirectoriesInDomains,
        (const void *)(uintptr_t)&NSSearchPathForDirectoriesInDomains
    };

static NSArray<NSString *> *PearSearchPathForDirectoriesInDomains(
    NSSearchPathDirectory directory, NSSearchPathDomainMask domainMask, BOOL expandTilde) {
    NSString *path = PearShimmedPath(directory, domainMask, expandTilde);
    if (path) return @[path];
    return ((NSArray<NSString *> *(*)(NSSearchPathDirectory, NSSearchPathDomainMask, BOOL))
            kInterposeSearchPaths.replacee)(directory, domainMask, expandTilde);
}

extern "C" NSString *NSHomeDirectory(void);

static NSString *PearHomeDirectory(void);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeHomeDirectory
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearHomeDirectory,
        (const void *)(uintptr_t)&NSHomeDirectory
    };

static NSString *PearHomeDirectory(void) {
    NSString *root = PearShimRoot();
    if (root) return root;
    return ((NSString *(*)(void))kInterposeHomeDirectory.replacee)();
}

#pragma mark - Install

__attribute__((constructor))
static void PearPathShimInit(void) {
    @autoreleasepool {
        if (!PearShimRoot()) return;
        PearInstallFileManagerShim();
        PearLog(@"[PearRuntime][paths] app data contained under %@", gShimRoot);
    }
}
