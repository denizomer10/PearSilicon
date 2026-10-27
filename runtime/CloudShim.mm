// CloudShim.mm
//
// Offline cloud compatibility for apps that gate startup on an account.
//
// A locally prepared build has no restricted cloud entitlements, so the real
// cloud stack can report "no account" and keep an app on a sign-in screen
// forever. This shim provides a **local-only** account surface:
//
//   - the key-value store is backed by a plist in the app's own container;
//   - the ubiquity container and identity token resolve to that container;
//   - GameKit's local player reports authenticated, with stable local IDs;
//   - CloudKit's account status reports available and the container/database
//     objects answer requests with an offline result instead of blocking.
//
// Nothing here contacts a remote service, creates an account, or reuses real
// credentials. Save data written through the compatibility layer stays local.
//
// Opt out with PEAR_NO_CLOUD_SHIM=1. Diagnostics: PEAR_DEBUG_CLOUD=1.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "PearRuntime.h"

static BOOL PearCloudDebug(void) {
    return getenv("PEAR_DEBUG_CLOUD") != NULL;
}

static BOOL PearCloudShimDisabled(void) {
    return getenv("PEAR_NO_CLOUD_SHIM") != NULL;
}

static NSString *PearRealHome(void) {
    const char *home = getenv("HOME");
    if (home && home[0]) return [NSString stringWithUTF8String:home];
    return @"/tmp";
}

static NSString *PearCloudRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Resolve the same per-app root PathShim uses, including its override.
        // The cloud surface is local-only, so its files belong beside the rest
        // of the app's contained data.
        const char *override = getenv("PEAR_HOME_DIR");
        NSString *base = nil;
        if (override && override[0]) {
            base = [NSString stringWithUTF8String:override];
        } else {
            NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
            base = [[PearRealHome()
                stringByAppendingPathComponent:@"Library/Application Support/PearSilicon/Games"]
                stringByAppendingPathComponent:bundleID];
        }
        root = [base stringByAppendingPathComponent:@"Library/Cloud"];
        [NSFileManager.defaultManager createDirectoryAtPath:root
                                withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return root;
}

static NSString *PearCloudKVPath(void) {
    return [PearCloudRoot() stringByAppendingPathComponent:@"key-values.plist"];
}

static NSString *PearUbiquityPath(void) {
    NSString *path = [PearCloudRoot() stringByAppendingPathComponent:@"Mobile Documents"];
    [NSFileManager.defaultManager createDirectoryAtPath:path
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    return path;
}

#pragma mark - Local key-value store

static NSMutableDictionary *gKV;
static NSString *gKVPath;

static void PearLoadKV(void) {
    if (gKV) return;
    gKVPath = PearCloudKVPath();
    id stored = [NSPropertyListSerialization propertyListWithData:
                 [NSData dataWithContentsOfFile:gKVPath]
                                                          options:NSPropertyListMutableContainersAndLeaves
                                                           format:NULL error:NULL];
    gKV = [stored isKindOfClass:NSMutableDictionary.class] ? stored : [NSMutableDictionary dictionary];
}

static void PearSaveKV(void) {
    if (!gKV) return;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:gKV
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:NULL];
    if (data) [data writeToFile:gKVPath atomically:YES];
}

static id PearKVObject(NSString *key) {
    if (!key) return nil;
    @synchronized (NSNull.class) {
        PearLoadKV();
        return gKV[key];
    }
}

static void PearKVSet(NSString *key, id value) {
    if (!key) return;
    @synchronized (NSNull.class) {
        PearLoadKV();
        if (value) gKV[key] = value;
        else [gKV removeObjectForKey:key];
        PearSaveKV();
    }
}

static void PearInstallKeyValueStore(void) {
    Class cls = NSClassFromString(@"NSUbiquitousKeyValueStore");
    if (!cls) return;

    typedef id (*GetterFn)(id, SEL, NSString *);
    typedef void (*SetterFn)(id, SEL, id, NSString *);
    typedef void (*RemoveFn)(id, SEL, NSString *);
    typedef BOOL (*SyncFn)(id, SEL);
    typedef NSDictionary *(*DictionaryFn)(id, SEL);

    Method object = class_getInstanceMethod(cls, @selector(objectForKey:));
    if (object) {
        method_setImplementation(object, imp_implementationWithBlock(^id(id self, NSString *key) {
            return PearKVObject(key);
        }));
    }

    Method setObject = class_getInstanceMethod(cls, @selector(setObject:forKey:));
    if (setObject) {
        method_setImplementation(setObject, imp_implementationWithBlock(^(id self, id value, NSString *key) {
            PearKVSet(key, value);
        }));
    }

    Method remove = class_getInstanceMethod(cls, @selector(removeObjectForKey:));
    if (remove) {
        method_setImplementation(remove, imp_implementationWithBlock(^(id self, NSString *key) {
            PearKVSet(key, nil);
        }));
    }

    Method representation = class_getInstanceMethod(cls, @selector(dictionaryRepresentation));
    if (representation) {
        method_setImplementation(representation, imp_implementationWithBlock(^NSDictionary *(id self) {
            @synchronized (NSNull.class) {
                PearLoadKV();
                return [gKV copy];
            }
        }));
    }

    Method synchronize = class_getInstanceMethod(cls, @selector(synchronize));
    if (synchronize) {
        method_setImplementation(synchronize, imp_implementationWithBlock(^BOOL(id self) {
            @synchronized (NSNull.class) { PearSaveKV(); }
            return YES;
        }));
    }

    // The convenience accessors are small value/type bridges. Replacing them
    // too keeps older callers from touching the real cloud store directly.
#define PEAR_KV_GETTER(type, name, expression)                                      \
    {                                                                                \
        SEL sel = NSSelectorFromString(@name);                                       \
        Method method = class_getInstanceMethod(cls, sel);                           \
        if (method) method_setImplementation(method, imp_implementationWithBlock(^type(id self, NSString *key) { \
            id value = PearKVObject(key);                                            \
            return expression;                                                       \
        }));                                                                         \
    }

    PEAR_KV_GETTER(NSString *, "stringForKey:", [value isKindOfClass:NSString.class] ? value : nil)
    PEAR_KV_GETTER(NSArray *, "arrayForKey:", [value isKindOfClass:NSArray.class] ? value : nil)
    PEAR_KV_GETTER(NSDictionary *, "dictionaryForKey:", [value isKindOfClass:NSDictionary.class] ? value : nil)
    PEAR_KV_GETTER(NSData *, "dataForKey:", [value isKindOfClass:NSData.class] ? value : nil)
    PEAR_KV_GETTER(long long, "longLongForKey:", [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0)
    PEAR_KV_GETTER(double, "doubleForKey:", [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0.0)
    PEAR_KV_GETTER(BOOL, "boolForKey:", [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO)

#undef PEAR_KV_GETTER

#define PEAR_KV_SETTER(valueType, name, box)                                        \
    {                                                                                \
        SEL sel = NSSelectorFromString(@name);                                       \
        Method method = class_getInstanceMethod(cls, sel);                           \
        if (method) method_setImplementation(method, imp_implementationWithBlock(^(id self, valueType value, NSString *key) { \
            PearKVSet(key, box);                                                     \
        }));                                                                         \
    }

    PEAR_KV_SETTER(NSString *, "setString:forKey:", value)
    PEAR_KV_SETTER(NSArray *, "setArray:forKey:", value)
    PEAR_KV_SETTER(NSDictionary *, "setDictionary:forKey:", value)
    PEAR_KV_SETTER(NSData *, "setData:forKey:", value)
    PEAR_KV_SETTER(long long, "setLongLong:forKey:", @(value))
    PEAR_KV_SETTER(double, "setDouble:forKey:", @(value))
    PEAR_KV_SETTER(BOOL, "setBool:forKey:", @(value))

#undef PEAR_KV_SETTER

    PearLog(@"[PearRuntime][cloud] local key-value store at %@", gKVPath ?: PearCloudKVPath());
}

#pragma mark - Ubiquity container

static void PearInstallUbiquityContainer(void) {
    Class fileManager = NSFileManager.class;
    SEL urlSelector = NSSelectorFromString(@"URLForUbiquityContainerIdentifier:");
    Method urlMethod = class_getInstanceMethod(fileManager, urlSelector);
    if (urlMethod) {
        method_setImplementation(urlMethod, imp_implementationWithBlock(^NSURL *(id self, NSString *identifier) {
            return [NSURL fileURLWithPath:PearUbiquityPath() isDirectory:YES];
        }));
    }

    SEL tokenSelector = NSSelectorFromString(@"ubiquityIdentityToken");
    Method tokenMethod = class_getInstanceMethod(fileManager, tokenSelector);
    if (tokenMethod) {
        method_setImplementation(tokenMethod, imp_implementationWithBlock(^id(id self) {
            NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
            return [@"pearsilicon-local-" stringByAppendingString:bundleID];
        }));
    }

    // The compatibility container is an ordinary local directory, so every
    // item in it is already present. Answer the ubiquity queries locally
    // instead of letting them reach the file provider.
    SEL isUbiquitous = NSSelectorFromString(@"isUbiquitousItemAtURL:error:");
    Method isUbiquitousMethod = class_getInstanceMethod(fileManager, isUbiquitous);
    if (isUbiquitousMethod) {
        method_setImplementation(isUbiquitousMethod, imp_implementationWithBlock(^BOOL(id self, NSURL *url, NSError **error) {
            if (error) *error = nil;
            return YES;
        }));
    }

    SEL startDownload = NSSelectorFromString(@"startDownloadingUbiquitousItemAtURL:error:");
    Method startDownloadMethod = class_getInstanceMethod(fileManager, startDownload);
    if (startDownloadMethod) {
        method_setImplementation(startDownloadMethod, imp_implementationWithBlock(^BOOL(id self, NSURL *url, NSError **error) {
            if (error) *error = nil;
            return YES;
        }));
    }

    SEL evict = NSSelectorFromString(@"evictUbiquitousItemAtURL:error:");
    Method evictMethod = class_getInstanceMethod(fileManager, evict);
    if (evictMethod) {
        method_setImplementation(evictMethod, imp_implementationWithBlock(^BOOL(id self, NSURL *url, NSError **error) {
            if (error) *error = nil;
            return YES;
        }));
    }

    PearLog(@"[PearRuntime][cloud] ubiquity container at %@", PearUbiquityPath());
}

#pragma mark - CloudKit compatibility objects

static NSString *const PearCloudContainerClassName = @"PearCloudContainer";
static NSString *const PearCloudDatabaseClassName = @"PearCloudDatabase";
static char kPearContainerIdentifierKey;

static Class PearEnsureCloudKitClass(const char *name) {
    Class cls = NSClassFromString(@(name));
    if (cls) return cls;
    static const char *paths[] = {
        "/System/iOSSupport/System/Library/Frameworks/CloudKit.framework/CloudKit",
        "/System/Library/Frameworks/CloudKit.framework/CloudKit",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL);
        cls = NSClassFromString(@(name));
        if (cls) return cls;
    }
    return Nil;
}

static Class PearEnsureGameKitClass(const char *name) {
    Class cls = NSClassFromString(@(name));
    if (cls) return cls;
    static const char *paths[] = {
        "/System/iOSSupport/System/Library/Frameworks/GameKit.framework/GameKit",
        "/System/Library/Frameworks/GameKit.framework/GameKit",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL);
        cls = NSClassFromString(@(name));
        if (cls) return cls;
    }
    return Nil;
}

static void PearAddMethod(Class cls, SEL selector, IMP imp, const char *fallbackTypes) {
    if (!cls || !selector || !imp) return;
    Method existing = class_getInstanceMethod(cls, selector);
    const char *types = existing ? method_getTypeEncoding(existing) : fallbackTypes;
    class_addMethod(cls, selector, imp, types ?: "v@:");
}

static NSError *PearCloudOfflineError(void) {
    return [NSError errorWithDomain:@"CKErrorDomain" code:6 userInfo:@{
        NSLocalizedDescriptionKey: @"The local cloud compatibility layer is offline."
    }];
}

static NSString *PearContainerIdentifier(id container) {
    NSString *identifier = objc_getAssociatedObject(container, &kPearContainerIdentifierKey);
    if (identifier.length > 0) return identifier;
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
    return [@"iCloud." stringByAppendingString:bundleID];
}

static id PearBlockValue(id object, NSString *key) {
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// Returns a local record-zone object for an identifier. A few callers create
/// a zone, save it, then fetch it back; returning a real object keeps that
/// flow working without a network round trip.
static id PearRecordZoneWithID(id zoneID) {
    Class zoneClass = PearEnsureCloudKitClass("CKRecordZone");
    SEL initSelector = NSSelectorFromString(@"initWithZoneID:");
    if (!zoneClass || !zoneID || ![zoneClass instancesRespondToSelector:initSelector]) return nil;
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)([zoneClass alloc], initSelector, zoneID);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// Answers the result block of a cloud operation while the operation is held by
/// the compatibility database/container. The real operation is never started,
/// so no request reaches a remote service.
static void PearFinishCloudOperation(NSOperation *operation) {
    if (!operation) return;
    NSString *name = NSStringFromClass(operation.class);
    id block = nil;

    if ([name isEqualToString:@"CKQueryOperation"]) {
        block = PearBlockValue(operation, @"queryResultBlock")
             ?: PearBlockValue(operation, @"queryCompletionBlock");
        if (block) ((void (^)(id, NSError *))block)(nil, nil);
    } else if ([name isEqualToString:@"CKModifyRecordsOperation"]) {
        block = PearBlockValue(operation, @"modifyRecordsCompletionBlock");
        if (block) ((void (^)(NSArray *, NSArray *, NSError *))block)(@[], @[], nil);
    } else if ([name isEqualToString:@"CKFetchRecordsOperation"]) {
        block = PearBlockValue(operation, @"fetchRecordsCompletionBlock");
        if (block) ((void (^)(NSDictionary *, NSError *))block)(@{}, nil);
    } else if ([name isEqualToString:@"CKFetchRecordZonesOperation"]) {
        block = PearBlockValue(operation, @"fetchRecordZonesCompletionBlock");
        if (block) ((void (^)(NSDictionary *, NSError *))block)(@{}, nil);
    } else if ([name isEqualToString:@"CKModifyRecordZonesOperation"]) {
        block = PearBlockValue(operation, @"modifyRecordZonesCompletionBlock");
        if (block) ((void (^)(NSArray *, NSArray *, NSError *))block)(@[], @[], nil);
    } else if ([name isEqualToString:@"CKFetchSubscriptionsOperation"]) {
        block = PearBlockValue(operation, @"fetchSubscriptionsCompletionBlock");
        if (block) ((void (^)(NSDictionary *, NSError *))block)(@{}, nil);
    } else if ([name isEqualToString:@"CKModifySubscriptionsOperation"]) {
        block = PearBlockValue(operation, @"modifySubscriptionsCompletionBlock");
        if (block) ((void (^)(NSArray *, NSArray *, NSError *))block)(@[], @[], nil);
    } else if ([name isEqualToString:@"CKFetchRecordZoneChangesOperation"]) {
        block = PearBlockValue(operation, @"fetchRecordZoneChangesCompletionBlock");
        if (block) ((void (^)(NSError *))block)(nil);
    } else if ([name isEqualToString:@"CKFetchDatabaseChangesOperation"]) {
        block = PearBlockValue(operation, @"fetchDatabaseChangesCompletionBlock");
        if (block) ((void (^)(id, BOOL, NSError *))block)(nil, NO, nil);
    }

    void (^completion)(void) = operation.completionBlock;
    if (completion) completion();
}

static Class PearCloudDatabaseClass(void) {
    Class base = PearEnsureCloudKitClass("CKDatabase");
    if (!base) return Nil;

    Class cls = NSClassFromString(PearCloudDatabaseClassName);
    if (cls) return cls;

    cls = objc_allocateClassPair(base, PearCloudDatabaseClassName.UTF8String, 0);
    if (!cls) return Nil;

    PearAddMethod(cls, @selector(init), imp_implementationWithBlock(^id(id self) {
        return self;
    }), "@@:");
    PearAddMethod(cls, @selector(databaseScope), imp_implementationWithBlock(^NSInteger(id self) {
        return 2; // private
    }), "q@:");

    PearAddMethod(cls, @selector(saveRecord:completionHandler:),
                  imp_implementationWithBlock(^(id self, id record, void (^done)(id, NSError *)) {
        if (done) done(record, nil);
    }), "v@:@@?");
    PearAddMethod(cls, @selector(fetchRecordWithID:completionHandler:),
                  imp_implementationWithBlock(^(id self, id recordID, void (^done)(id, NSError *)) {
        if (done) done(nil, PearCloudOfflineError());
    }), "v@:@@?");
    PearAddMethod(cls, @selector(deleteRecordWithID:completionHandler:),
                  imp_implementationWithBlock(^(id self, id recordID, void (^done)(id, NSError *)) {
        if (done) done(nil, PearCloudOfflineError());
    }), "v@:@@?");
    PearAddMethod(cls, @selector(fetchRecordZoneWithID:completionHandler:),
                  imp_implementationWithBlock(^(id self, id zoneID, void (^done)(id, NSError *)) {
        if (done) done(PearRecordZoneWithID(zoneID), nil);
    }), "v@:@@?");
    PearAddMethod(cls, @selector(saveRecordZone:completionHandler:),
                  imp_implementationWithBlock(^(id self, id zone, void (^done)(id, NSError *)) {
        if (done) done(zone, nil);
    }), "v@:@@?");
    PearAddMethod(cls, @selector(deleteRecordZoneWithID:completionHandler:),
                  imp_implementationWithBlock(^(id self, id zoneID, void (^done)(NSError *)) {
        if (done) done(nil);
    }), "v@:@@?");
    PearAddMethod(cls, @selector(fetchAllRecordZonesWithCompletionHandler:),
                  imp_implementationWithBlock(^(id self, void (^done)(NSArray *, NSError *)) {
        if (done) done(@[], nil);
    }), "v@:@?");
    PearAddMethod(cls, @selector(fetchAllSubscriptionsWithCompletionHandler:),
                  imp_implementationWithBlock(^(id self, void (^done)(NSArray *, NSError *)) {
        if (done) done(@[], nil);
    }), "v@:@?");
    PearAddMethod(cls, @selector(performQuery:inZoneWithID:completionHandler:),
                  imp_implementationWithBlock(^(id self, id query, id zoneID,
                                               void (^done)(NSArray *, NSError *)) {
        if (done) done(@[], nil);
    }), "v@:@@@?");
    PearAddMethod(cls, @selector(fetchSubscriptionWithID:completionHandler:),
                  imp_implementationWithBlock(^(id self, NSString *subscriptionID,
                                               void (^done)(id, NSError *)) {
        if (done) done(nil, nil);
    }), "v@:@@?");
    PearAddMethod(cls, @selector(saveSubscription:completionHandler:),
                  imp_implementationWithBlock(^(id self, id subscription,
                                               void (^done)(id, NSError *)) {
        if (done) done(subscription, nil);
    }), "v@:@@?");
    PearAddMethod(cls, @selector(deleteSubscriptionWithID:completionHandler:),
                  imp_implementationWithBlock(^(id self, NSString *subscriptionID,
                                               void (^done)(NSError *)) {
        if (done) done(nil);
    }), "v@:@@?");
    PearAddMethod(cls, @selector(addOperation:),
                  imp_implementationWithBlock(^(id self, NSOperation *operation) {
        if (operation) dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool { PearFinishCloudOperation(operation); }
        });
    }), "v@:@");

    objc_registerClassPair(cls);
    return cls;
}

static id PearCloudDatabase(void) {
    static id database;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = PearCloudDatabaseClass();
        if (cls) database = [[cls alloc] init];
    });
    return database;
}

static Class PearCloudContainerClass(void) {
    Class base = PearEnsureCloudKitClass("CKContainer");
    if (!base) return Nil;

    Class cls = NSClassFromString(PearCloudContainerClassName);
    if (cls) return cls;

    cls = objc_allocateClassPair(base, PearCloudContainerClassName.UTF8String, 0);
    if (!cls) return Nil;

    PearAddMethod(cls, @selector(init), imp_implementationWithBlock(^id(id self) {
        return self;
    }), "@@:");
    PearAddMethod(cls, @selector(containerIdentifier), imp_implementationWithBlock(^NSString *(id self) {
        return PearContainerIdentifier(self);
    }), "@@:");
    PearAddMethod(cls, @selector(accountStatusWithCompletionHandler:),
                  imp_implementationWithBlock(^(id self, void (^done)(NSInteger, NSError *)) {
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(1, nil); }); // available
    }), "v@:@?");
    PearAddMethod(cls, @selector(statusForApplicationPermission:completionHandler:),
                  imp_implementationWithBlock(^(id self, NSInteger permission,
                                               void (^done)(NSInteger, NSError *)) {
        if (done) done(1, nil); // granted
    }), "v@:q@?");
    PearAddMethod(cls, @selector(requestApplicationPermission:completionHandler:),
                  imp_implementationWithBlock(^(id self, NSInteger permission,
                                               void (^done)(NSInteger, NSError *)) {
        if (done) done(1, nil); // granted
    }), "v@:q@?");
    PearAddMethod(cls, @selector(fetchAllLongLivedOperationIDsWithCompletionHandler:),
                  imp_implementationWithBlock(^(id self, void (^done)(NSArray *, NSError *)) {
        if (done) done(@[], nil);
    }), "v@:@?");
    PearAddMethod(cls, @selector(fetchLongLivedOperationWithID:completionHandler:),
                  imp_implementationWithBlock(^(id self, NSString *operationID,
                                               void (^done)(id, NSError *)) {
        if (done) done(nil, nil);
    }), "v@:@@?");
    PearAddMethod(cls, @selector(discoverAllContactUserInfosWithCompletionHandler:),
                  imp_implementationWithBlock(^(id self, void (^done)(NSArray *, NSError *)) {
        if (done) done(@[], nil);
    }), "v@:@?");
    PearAddMethod(cls, @selector(discoverUserIdentityWithEmailAddress:completionHandler:),
                  imp_implementationWithBlock(^(id self, NSString *address,
                                               void (^done)(id, NSError *)) {
        if (done) done(nil, nil);
    }), "v@:@@?");
    PearAddMethod(cls, @selector(discoverUserIdentityWithPhoneNumber:completionHandler:),
                  imp_implementationWithBlock(^(id self, NSString *number,
                                               void (^done)(id, NSError *)) {
        if (done) done(nil, nil);
    }), "v@:@@?");
    PearAddMethod(cls, @selector(fetchAllShareParticipantsWithCompletionHandler:),
                  imp_implementationWithBlock(^(id self, void (^done)(NSArray *, NSError *)) {
        if (done) done(@[], nil);
    }), "v@:@?");
    PearAddMethod(cls, @selector(fetchShareMetadataWithURL:completionHandler:),
                  imp_implementationWithBlock(^(id self, NSURL *url,
                                               void (^done)(id, NSError *)) {
        if (done) done(nil, PearCloudOfflineError());
    }), "v@:@@?");
    PearAddMethod(cls, @selector(acceptShareMetadata:completionHandler:),
                  imp_implementationWithBlock(^(id self, id metadata,
                                               void (^done)(id, NSError *)) {
        if (done) done(nil, PearCloudOfflineError());
    }), "v@:@@?");
    PearAddMethod(cls, @selector(fetchUserRecordIDWithCompletionHandler:),
                  imp_implementationWithBlock(^(id self, void (^done)(id, NSError *)) {
        Class recordIDClass = PearEnsureCloudKitClass("CKRecordID");
        id recordID = nil;
        @try {
            SEL initSelector = NSSelectorFromString(@"initWithRecordName:");
            if (recordIDClass && [recordIDClass instancesRespondToSelector:initSelector]) {
                recordID = ((id (*)(id, SEL, id))objc_msgSend)([recordIDClass alloc],
                                                              initSelector, @"pearsilicon-local");
            }
        } @catch (__unused NSException *exception) {
            recordID = nil;
        }
        if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(recordID, nil); });
    }), "v@:@?");
    PearAddMethod(cls, @selector(privateCloudDatabase), imp_implementationWithBlock(^id(id self) {
        return PearCloudDatabase();
    }), "@@:");
    PearAddMethod(cls, @selector(publicCloudDatabase), imp_implementationWithBlock(^id(id self) {
        return PearCloudDatabase();
    }), "@@:");
    PearAddMethod(cls, @selector(sharedCloudDatabase), imp_implementationWithBlock(^id(id self) {
        return PearCloudDatabase();
    }), "@@:");
    PearAddMethod(cls, @selector(addOperation:),
                  imp_implementationWithBlock(^(id self, NSOperation *operation) {
        if (operation) dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool { PearFinishCloudOperation(operation); }
        });
    }), "v@:@");

    objc_registerClassPair(cls);
    return cls;
}

static id PearCloudContainer(NSString *identifier) {
    Class cls = PearCloudContainerClass();
    if (!cls) return nil;
    id container = [[cls alloc] init];
    if (identifier.length > 0) {
        objc_setAssociatedObject(container, &kPearContainerIdentifierKey, identifier,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return container;
}

static void PearInstallCloudKit(void) {
    Class container = PearEnsureCloudKitClass("CKContainer");
    if (!container) return;

    Method withIdentifier = class_getClassMethod(container, @selector(containerWithIdentifier:));
    if (withIdentifier) {
        method_setImplementation(withIdentifier, imp_implementationWithBlock(^id(id self, NSString *identifier) {
            return PearCloudContainer(identifier);
        }));
    }

    Method defaultContainer = class_getClassMethod(container, @selector(defaultContainer));
    if (defaultContainer) {
        method_setImplementation(defaultContainer, imp_implementationWithBlock(^id(id self) {
            return PearCloudContainer(nil);
        }));
    }

    if (PearCloudDebug()) {
        PearLog(@"[PearRuntime][cloud] CloudKit compatibility container installed");
    }
}

#pragma mark - GameKit local player

typedef void (^PearAuthenticateHandler)(id viewController, NSError *error);

static PearAuthenticateHandler gAuthenticateHandler;

static NSString *PearLocalPlayerID(void) {
    return @"G:pearsilicon-local";
}

static Class PearLocalPlayerClass(void) {
    Class base = PearEnsureGameKitClass("GKLocalPlayer");
    if (!base) return Nil;

    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = objc_allocateClassPair(base, "PearLocalPlayer", 0);
        if (!cls) return;

        PearAddMethod(cls, @selector(init), imp_implementationWithBlock(^id(id self) {
            return self;
        }), "@@:");
        PearAddMethod(cls, @selector(isAuthenticated), imp_implementationWithBlock(^BOOL(id self) {
            return YES;
        }), "c@:");
        PearAddMethod(cls, @selector(authenticated), imp_implementationWithBlock(^BOOL(id self) {
            return YES;
        }), "c@:");
        PearAddMethod(cls, @selector(scopedIDsArePersistent), imp_implementationWithBlock(^BOOL(id self) {
            return YES;
        }), "c@:");
        PearAddMethod(cls, @selector(isMultiplayerGamingRestricted), imp_implementationWithBlock(^BOOL(id self) {
            return NO;
        }), "c@:");
        PearAddMethod(cls, @selector(isPersonalizedCommunicationRestricted), imp_implementationWithBlock(^BOOL(id self) {
            return NO;
        }), "c@:");
        PearAddMethod(cls, @selector(playerID), imp_implementationWithBlock(^NSString *(id self) {
            return PearLocalPlayerID();
        }), "@@:");
        PearAddMethod(cls, @selector(gamePlayerID), imp_implementationWithBlock(^NSString *(id self) {
            return PearLocalPlayerID();
        }), "@@:");
        PearAddMethod(cls, @selector(teamPlayerID), imp_implementationWithBlock(^NSString *(id self) {
            return PearLocalPlayerID();
        }), "@@:");
        PearAddMethod(cls, @selector(displayName), imp_implementationWithBlock(^NSString *(id self) {
            return @"Player";
        }), "@@:");
        PearAddMethod(cls, @selector(alias), imp_implementationWithBlock(^NSString *(id self) {
            return @"Player";
        }), "@@:");
        PearAddMethod(cls, @selector(isUnderage), imp_implementationWithBlock(^BOOL(id self) {
            return NO;
        }), "c@:");
        PearAddMethod(cls, @selector(authenticateHandler), imp_implementationWithBlock(^id(id self) {
            return gAuthenticateHandler;
        }), "@@:");
        PearAddMethod(cls, @selector(setAuthenticateHandler:),
                      imp_implementationWithBlock(^(id self, PearAuthenticateHandler handler) {
            gAuthenticateHandler = [handler copy];
            if (handler) {
                dispatch_async(dispatch_get_main_queue(), ^{ handler(nil, nil); });
            }
        }), "v@:@?");
        PearAddMethod(cls, @selector(authenticateWithCompletionHandler:),
                      imp_implementationWithBlock(^(id self, void (^done)(NSError *)) {
            if (done) done(nil);
        }), "v@:@?");
        PearAddMethod(cls, @selector(fetchSavedGamesWithCompletionHandler:),
                      imp_implementationWithBlock(^(id self, void (^done)(NSArray *, NSError *)) {
            if (done) done(@[], nil);
        }), "v@:@?");
        PearAddMethod(cls, @selector(loadFriendsWithCompletionHandler:),
                      imp_implementationWithBlock(^(id self, void (^done)(NSArray *, NSError *)) {
            if (done) done(@[], nil);
        }), "v@:@?");
        PearAddMethod(cls, @selector(loadFriendsAuthorizationStatus:),
                      imp_implementationWithBlock(^(id self, void (^done)(NSInteger, NSError *)) {
            if (done) done(1, nil); // authorized
        }), "v@:@?");
        PearAddMethod(cls, @selector(loadRecentPlayersWithCompletionHandler:),
                      imp_implementationWithBlock(^(id self, void (^done)(NSArray *, NSError *)) {
            if (done) done(@[], nil);
        }), "v@:@?");
        PearAddMethod(cls, @selector(saveGameData:withName:completionHandler:),
                      imp_implementationWithBlock(^(id self, NSData *data, NSString *name, void (^done)(id, NSError *)) {
            if (done) done(nil, nil);
        }), "v@:@@@?");
        PearAddMethod(cls, @selector(deleteSavedGamesWithName:completionHandler:),
                      imp_implementationWithBlock(^(id self, NSString *name, void (^done)(NSError *)) {
            if (done) done(nil);
        }), "v@:@@?");
        PearAddMethod(cls, @selector(resolveConflictingSavedGames:withData:completionHandler:),
                      imp_implementationWithBlock(^(id self, NSArray *games, NSData *data, void (^done)(id, NSError *)) {
            if (done) done(nil, nil);
        }), "v@:@@@?");

        objc_registerClassPair(cls);
    });
    return cls;
}

static void PearReplaceClassMethod(Class cls, SEL selector, id block, const char *fallbackTypes) {
    if (!cls || !selector || !block) return;
    Method existing = class_getClassMethod(cls, selector);
    IMP imp = imp_implementationWithBlock(block);
    if (existing) method_setImplementation(existing, imp);
    else class_addMethod(object_getClass(cls), selector, imp, fallbackTypes ?: "v@:");
}

/// Local answers for the GameKit surfaces apps commonly touch before or during
/// startup. None of these calls reaches a remote service.
static void PearInstallGameKitExtras(void) {
    Class player = PearEnsureGameKitClass("GKPlayer");
    if (player) {
        PearReplaceClassMethod(player, @selector(loadPlayersForIdentifiers:completionHandler:),
            ^(id self, NSArray *identifiers, void (^done)(NSArray *, NSError *)) {
                if (done) done(@[], nil);
            }, "v@:@?");
    }

    Class achievement = PearEnsureGameKitClass("GKAchievement");
    if (achievement) {
        PearReplaceClassMethod(achievement, @selector(loadAchievementsWithCompletionHandler:),
            ^(id self, void (^done)(NSArray *, NSError *)) {
                if (done) done(@[], nil);
            }, "v@:@?");
        PearReplaceClassMethod(achievement, @selector(reportAchievements:withCompletionHandler:),
            ^(id self, NSArray *achievements, void (^done)(NSError *)) {
                if (done) done(nil);
            }, "v@:@@?");
        PearReplaceClassMethod(achievement, @selector(resetAchievementsWithCompletionHandler:),
            ^(id self, void (^done)(NSError *)) {
                if (done) done(nil);
            }, "v@:@?");
    }

    Class leaderboard = PearEnsureGameKitClass("GKLeaderboard");
    if (leaderboard) {
        PearReplaceClassMethod(leaderboard, @selector(loadLeaderboardsWithCompletionHandler:),
            ^(id self, void (^done)(NSArray *, NSError *)) {
                if (done) done(@[], nil);
            }, "v@:@?");
        PearReplaceClassMethod(leaderboard, @selector(loadCategoriesWithCompletionHandler:),
            ^(id self, void (^done)(NSArray *, NSError *)) {
                if (done) done(@[], nil);
            }, "v@:@?");
    }

    Class score = PearEnsureGameKitClass("GKScore");
    if (score) {
        PearReplaceClassMethod(score, @selector(reportScores:withCompletionHandler:),
            ^(id self, NSArray *scores, void (^done)(NSError *)) {
                if (done) done(nil);
            }, "v@:@@?");
    }
}

static void PearInstallGameKit(void) {
    Class localPlayer = PearEnsureGameKitClass("GKLocalPlayer");
    if (!localPlayer) return;

    Class fake = PearLocalPlayerClass();

    Method localPlayerMethod = class_getClassMethod(localPlayer, @selector(localPlayer));
    if (localPlayerMethod && fake) {
        static id instance;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ instance = [[fake alloc] init]; });
        method_setImplementation(localPlayerMethod, imp_implementationWithBlock(^id(id self) {
            return instance;
        }));
    }

    if (PearCloudDebug()) {
        PearLog(@"[PearRuntime][cloud] GameKit local player compatibility installed");
    }

    PearInstallGameKitExtras();
}

#pragma mark - Install

__attribute__((constructor))
static void PearCloudShimInit(void) {
    if (PearCloudShimDisabled()) return;
    @autoreleasepool {
        PearInstallKeyValueStore();
        PearInstallUbiquityContainer();
        PearInstallCloudKit();
        PearInstallGameKit();

        // Some frameworks load after the app's first scene. Re-run once or twice
        // so a late-loaded GameKit/CloudKit class still gets the compatibility
        // surface.
        for (int i = 1; i <= 4; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    PearInstallCloudKit();
                    PearInstallGameKit();
                }
            });
        }
    }
}
