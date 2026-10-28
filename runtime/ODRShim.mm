// ODRShim.mm
//
// Makes the platform's On-Demand Resources resolve to the bundles shipped inside the
// app, instead of asking the (nonexistent) ODR service.
//
// Some Unity titles are built with Addressables over ODR: their content lives
// in `Data/Raw/aa/BuildTarget/*.bundle`, and the app asks
// `NSBundleResourceRequest` for the tag that owns each bundle before loading
// it. On a Mac the ODR daemon has no manifest for a sideloaded app, so every
// request fails with
//
//   Error Domain=NSCocoaErrorDomain Code=4994
//   "The requested application data doesn't exist."
//
// The app treats that as fatal, stops loading and leaves a black window.
//
// This shim makes the request succeed and points `bundle` at the local
// Addressables directory, so the app gets past the preload. A package that
// was stripped of its ODR asset packs still cannot load those bundles, and the
// log below names the files that are missing.
//
// Disable with PEAR_NO_ODR_SHIM=1.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "PearRuntime.h"

static NSBundle *gODRLocalBundle;
static NSProgress *gODRProgress;
static dispatch_queue_t gODRQueue;
static BOOL gODRReportedMissingContent;

/// The directory that stands in for the ODR asset pack. The Addressables
/// bundles are in `Data/Raw/aa/BuildTarget`; the parent directories are
/// fallbacks for titles that keep them elsewhere.
static NSBundle *PearODRLocalBundle(void) {
    if (gODRLocalBundle) return gODRLocalBundle;

    NSString *app = NSBundle.mainBundle.bundlePath;
    NSArray<NSString *> *candidates = @[
        [app stringByAppendingPathComponent:@"Data/Raw/aa/BuildTarget"],
        [app stringByAppendingPathComponent:@"Data/Raw/aa"],
        [app stringByAppendingPathComponent:@"Data/Raw"],
    ];

    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in candidates) {
        BOOL isDirectory = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) {
            gODRLocalBundle = [NSBundle bundleWithPath:path];
            PearLog(@"[PearRuntime][odr] local resource root: %@", path);
            return gODRLocalBundle;
        }
    }

    gODRLocalBundle = NSBundle.mainBundle;
    PearLog(@"[PearRuntime][odr] no local resource root, using %@", gODRLocalBundle.bundlePath);
    return gODRLocalBundle;
}

/// The local file that stands in for a tag, or nil when the package does not
/// carry it. Addressables writes one file per tag as
/// `<tag>_assets_all.bundle`; other layouts use `<tag>.bundle` or a directory
/// named after the tag.
static NSString *PearODRLocalPathForTag(NSString *tag) {
    NSString *root = PearODRLocalBundle().bundlePath;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *names = @[
        [tag stringByAppendingString:@"_assets_all.bundle"],
        [tag stringByAppendingPathExtension:@"bundle"],
        tag,
    ];
    for (NSString *name in names) {
        NSString *path = [root stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

/// Warns once when the app declares ODR tags but the app package carries no bundles
/// for them. iOS delivers ODR packs separately, so a package that was prepared
/// for sideloading often does not include them.
static void PearODRCheckForMissingContent(void) {
    if (gODRReportedMissingContent) return;
    gODRReportedMissingContent = YES;

    NSString *app = NSBundle.mainBundle.bundlePath;
    NSString *manifest = [app stringByAppendingPathComponent:@"OnDemandResources.plist"];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:manifest];
    if (![plist isKindOfClass:[NSDictionary class]]) return;

    NSString *root = PearODRLocalBundle().bundlePath;
    NSArray<NSString *> *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    NSUInteger bundles = 0;
    for (NSString *entry in entries) {
        if ([entry.pathExtension isEqualToString:@"bundle"]) bundles++;
    }
    if (bundles == 0) {
        PearLog(@"[PearRuntime][odr] WARNING: this app uses On-Demand Resources but the app package "
                "contains no asset bundles. The game will stop loading (black window). "
                "Use an app package that includes the ODR asset packs.");
        return;
    }

    NSDictionary *tags = plist[@"NSBundleResourceRequestTags"];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *tag in tags) {
        if ([tag isKindOfClass:[NSString class]] && !PearODRLocalPathForTag(tag)) {
            [missing addObject:tag];
        }
    }
    if (missing.count == 0) {
        PearLog(@"[PearRuntime][odr] %lu local bundle(s) available for ODR requests",
                (unsigned long)bundles);
        return;
    }

    NSUInteger shown = MIN((NSUInteger)8, missing.count);
    NSString *names = [[missing subarrayWithRange:NSMakeRange(0, shown)] componentsJoinedByString:@", "];
    PearLog(@"[PearRuntime][odr] WARNING: %lu of %lu ODR tag(s) have no local asset bundle: %@%@. "
            "Expected %@_assets_all.bundle under %@. Loading will stop at the first missing bundle; "
            "the app package must include its On-Demand Resources.",
            (unsigned long)missing.count, (unsigned long)tags.count, names,
            missing.count > shown ? @", ..." : @"", missing.firstObject, root);
}

static NSProgress *PearODRProgress(void) {
    if (!gODRProgress) {
        gODRProgress = [NSProgress progressWithTotalUnitCount:1];
        gODRProgress.completedUnitCount = 1;
    }
    return gODRProgress;
}

/// The asset pack names the app's ODR manifest lists for a tag. Logging them
/// makes a missing-content warning actionable: the user can see which packs
/// the store download would have brought.
static NSArray<NSString *> *PearODRAssetPacksForTag(NSString *tag) {
    NSString *app = NSBundle.mainBundle.bundlePath;
    NSString *manifest = [app stringByAppendingPathComponent:@"OnDemandResources.plist"];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:manifest];
    NSDictionary *tags = plist[@"NSBundleResourceRequestTags"];
    NSDictionary *entry = [tags isKindOfClass:[NSDictionary class]] ? tags[tag] : nil;
    NSArray *packs = [entry isKindOfClass:[NSDictionary class]] ? entry[@"NSAssetPacks"] : nil;
    return [packs isKindOfClass:[NSArray class]] ? packs : @[];
}

/// The ODR asset pack for a tag is not in the app package when none of the
/// candidate file names exists in the local resource root.
static void PearODRReportMissingTag(NSString *tag) {
    if (PearODRLocalPathForTag(tag)) return;
    NSString *root = PearODRLocalBundle().bundlePath;
    NSArray<NSString *> *packs = PearODRAssetPacksForTag(tag);
    NSString *packList = packs.count ? [packs componentsJoinedByString:@", "] : @"none listed";
    PearLog(@"[PearRuntime][odr] WARNING: tag '%@' has no local bundle; expected %@_assets_all.bundle "
            "in %@ (the app package is missing its On-Demand Resources; asset pack(s): %@)",
            tag, tag, root, packList);
}

static void PearODRBegin(id self, SEL _cmd, void (^handler)(NSError *)) {
    PearODRCheckForMissingContent();
    for (NSString *tag in [self tags]) PearODRReportMissingTag(tag);
    PearLog(@"[PearRuntime][odr] begin tags=%@ -> %@", [self tags], PearODRLocalBundle().bundlePath);
    if (!handler) return;
    dispatch_async(gODRQueue, ^{ handler(nil); });
}

static void PearODRConditional(id self, SEL _cmd, void (^handler)(BOOL)) {
    PearLog(@"[PearRuntime][odr] conditional tags=%@ -> YES", [self tags]);
    if (!handler) return;
    dispatch_async(gODRQueue, ^{ handler(YES); });
}

static NSBundle *PearODRBundle(id self, SEL _cmd) {
    return PearODRLocalBundle();
}

static NSProgress *PearODRProgressGetter(id self, SEL _cmd) {
    return PearODRProgress();
}

static void PearODREnd(id self, SEL _cmd) {
    PearLog(@"[PearRuntime][odr] end tags=%@", [self tags]);
}

// NSBundle's preservation-priority API throws when the bundle has no ODR tag
// information, which is exactly our case.
static void PearODRSetPreservation(id self, SEL _cmd, double priority, NSSet *tags) {
    (void)priority;
    (void)tags;
}

static double PearODRGetPreservation(id self, SEL _cmd, NSString *tag) {
    (void)tag;
    return 0.0;
}

static void PearInstallODRShim(void) {
    if (NSProcessInfo.processInfo.environment[@"PEAR_NO_ODR_SHIM"]) return;

    Class request = objc_getClass("NSBundleResourceRequest");
    if (!request) {
        PearLog(@"[PearRuntime][odr] NSBundleResourceRequest not found");
        return;
    }

    gODRQueue = dispatch_queue_create("com.pearsilicon.odr", DISPATCH_QUEUE_SERIAL);

    class_replaceMethod(request, @selector(beginAccessingResourcesWithCompletionHandler:),
                        (IMP)PearODRBegin, "v@:@?");
    class_replaceMethod(request, @selector(conditionallyBeginAccessingResourcesWithCompletionHandler:),
                        (IMP)PearODRConditional, "v@:@?");
    class_replaceMethod(request, @selector(bundle), (IMP)PearODRBundle, "@@:");
    class_replaceMethod(request, @selector(progress), (IMP)PearODRProgressGetter, "@@:");
    class_replaceMethod(request, @selector(endAccessingResources), (IMP)PearODREnd, "v@:");

    Class bundle = objc_getClass("NSBundle");
    if (bundle) {
        class_replaceMethod(bundle, @selector(setPreservationPriority:forTags:),
                            (IMP)PearODRSetPreservation, "v@:d@");
        class_replaceMethod(bundle, @selector(preservationPriorityForTag:),
                            (IMP)PearODRGetPreservation, "d@:@");
    }

    PearLog(@"[PearRuntime][odr] shim installed on %@", NSStringFromClass(request));
}

__attribute__((constructor))
static void PearODRShimInit(void) {
    @autoreleasepool {
        PearInstallODRShim();
    }
}
