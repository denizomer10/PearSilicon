// KeychainShim.mm
//
// Reimplements the iOS keychain API (SecItemAdd / SecItemCopyMatching /
// SecItemUpdate / SecItemDelete) on top of a plain file store, and interposes
// it into the target process via dyld interposing.
//
// Why: an iOS app running on macOS as a Mac Catalyst process cannot use the
// system keychain without restricted entitlements (keychain-access-groups),
// which cannot be granted by adhoc signing. SecItemAdd then fails with
// -34018 (errSecMissingEntitlement). This shim provides the same API surface
// backed by local storage, so apps that persist data in the keychain work.
//
// This is a compatibility shim for a generic storage API. It does not defeat
// any protection mechanism.

#import <Foundation/Foundation.h>
#import <Security/SecItem.h>
#import <Security/Security.h>
#import <Security/SecKey.h>
#import <dlfcn.h>

#pragma mark - Store

static NSString *StoreDir(void) {
    const char *override = getenv("PEAR_KEYCHAIN_DIR");
    if (override && override[0]) {
        return [NSString stringWithUTF8String:override];
    }
    // Persistent default so credentials survive restarts. Uses the real home
    // (from the environment) because PathShim redirects NSHomeDirectory.
    const char *home = getenv("HOME");
    NSString *realHome = (home && home[0]) ? [NSString stringWithUTF8String:home] : NSHomeDirectory();
    return [realHome stringByAppendingPathComponent:@"Library/Application Support/PearSilicon/Keychain"];
}

/// The access group iOS would attach to an item automatically. Some SDKs read
/// it back and split it on '.' to get the team identifier; a missing value
/// makes them call -[NSString initWithString:] with nil and abort. The shim is
/// a local file store, so the value only has to be present and stable.
static NSString *DefaultAccessGroup(void) {
    static NSString *group = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
        group = [@"PEARSILICON" stringByAppendingFormat:@".%@", bundleID];
    });
    return group;
}

static NSString *ItemPath(NSString *identifier) {
    // Stable, filesystem-safe name from the identifier.
    NSData *data = [identifier dataUsingEncoding:NSUTF8StringEncoding];
    uint64_t h = 1469598103934665603ULL; // FNV-1a
    const uint8_t *b = (const uint8_t *)data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) { h ^= b[i]; h *= 1099511628211ULL; }
    return [StoreDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%016llx.plist", h]];
}

/// Keys that select/return data rather than describe the stored item.
static BOOL IsControlKey(id key) {
    static NSSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[
            (__bridge id)kSecValueData,
            (__bridge id)kSecValueRef,
            (__bridge id)kSecValuePersistentRef,
            (__bridge id)kSecReturnData,
            (__bridge id)kSecReturnAttributes,
            (__bridge id)kSecReturnRef,
            (__bridge id)kSecReturnPersistentRef,
            (__bridge id)kSecReturnPersistentRef,
            (__bridge id)kSecMatchLimit,
            (__bridge id)kSecUseDataProtectionKeychain,
            (__bridge id)kSecUseAuthenticationUI,
            (__bridge id)kSecUseAuthenticationContext,
        ]];
    });
    return [set containsObject:key];
}

/// All stored items (each a dictionary).
static NSArray<NSDictionary *> *LoadAll(void) {
    NSMutableArray *items = [NSMutableArray array];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:StoreDir() error:NULL] ?: @[];
    for (NSString *file in files) {
        NSString *path = [StoreDir() stringByAppendingPathComponent:file];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (d) [items addObject:d];
    }
    return items;
}

static void SaveItem(NSDictionary *item) {
    [[NSFileManager defaultManager] createDirectoryAtPath:StoreDir()
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *key = item[@"__id"];
    [item writeToFile:ItemPath(key) atomically:YES];
}

static void DeleteItemWithId(NSString *identifier) {
    [[NSFileManager defaultManager] removeItemAtPath:ItemPath(identifier) error:NULL];
}

/// Builds a stable identifier from the query's descriptive attributes.
static NSString *IdentifierForQuery(NSDictionary *query) {
    NSMutableArray *pairs = [NSMutableArray array];
    for (id key in query) {
        if (IsControlKey(key)) continue;
        // The synthetic default group is what an omitted group means, so it
        // must not change the identity: an item added without a group and one
        // added with the group read back from an earlier item stay the same
        // item, and items written by earlier versions are still overwritten
        // rather than duplicated.
        if ([key isEqual:(__bridge id)kSecAttrAccessGroup] &&
            [query[key] isEqual:DefaultAccessGroup()]) {
            continue;
        }
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", key, query[key]]];
    }
    // A real (non-default) access group stays part of the identity, as it is
    // on iOS, so items in different groups do not overwrite each other.
    [pairs sortUsingSelector:@selector(compare:)];
    return [pairs componentsJoinedByString:@"|"];
}

/// True if every descriptive attribute in `query` matches `item`.
static BOOL Matches(NSDictionary *item, NSDictionary *query) {
    // A persistent reference identifies a specific stored item.
    id wantPersistent = query[(__bridge id)kSecValuePersistentRef];
    if (wantPersistent != nil) {
        if (![item[@"__persistentRef"] isEqual:wantPersistent]) return NO;
    }

    for (id key in query) {
        if (IsControlKey(key)) continue;
        id want = query[key];
        id have = item[key];
        if (have == nil) {
            // Items written before the shim recorded a group belong to the
            // default group, so an explicit default-group query still finds
            // them.
            if ([key isEqual:(__bridge id)kSecAttrAccessGroup]) {
                have = DefaultAccessGroup();
            } else {
                return NO;
            }
        }
        if (![want isEqual:have]) return NO;
    }
    // An omitted access group means the default group.
    if (!query[(__bridge id)kSecAttrAccessGroup]) {
        id have = item[(__bridge id)kSecAttrAccessGroup] ?: DefaultAccessGroup();
        if (![have isEqual:DefaultAccessGroup()]) return NO;
    }
    return YES;
}

#pragma mark - SecKey persistence

// SecKeyRefs cannot be handed to securityd here, so we persist keys ourselves:
// store the key's external representation plus its descriptive attributes, and
// rebuild a SecKeyRef later with SecKeyCreateWithData.

static void StoreSecKey(SecKeyRef key, NSDictionary *params, CFStringRef keyClass) {
    if (!key) return;

    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[(__bridge id)kSecClass] = (__bridge id)kSecClassKey;
    item[(__bridge id)kSecAttrKeyClass] = (__bridge id)keyClass;

    for (id k in params) {
        if (IsControlKey(k)) continue;
        if ([k isEqual:(__bridge id)kSecAttrIsPermanent]) continue;
        if ([k isEqual:(__bridge id)kSecAttrKeyClass]) continue;
        if ([k isEqual:(__bridge id)kSecPrivateKeyAttrs]) continue;
        if ([k isEqual:(__bridge id)kSecPublicKeyAttrs]) continue;
        if ([k isEqual:(__bridge id)kSecAttrAccessControl]) continue;
        if ([k isEqual:(__bridge id)kSecAttrTokenID]) continue;
        if ([k isEqual:(__bridge id)kSecAttrAccessGroup]) continue;
        id value = params[k];
        if (![NSPropertyListSerialization propertyList:value
                                isValidForFormat:NSPropertyListBinaryFormat_v1_0]) continue;
        item[k] = value;
    }

    CFDictionaryRef keyAttrs = SecKeyCopyAttributes(key);
    if (keyAttrs) {
        NSDictionary *a = CFBridgingRelease(keyAttrs);
        for (id k in @[ (__bridge id)kSecAttrKeyType, (__bridge id)kSecAttrKeySizeInBits ]) {
            if (a[k] && !item[k]) item[k] = a[k];
        }
    }

    CFErrorRef err = NULL;
    CFDataRef ext = SecKeyCopyExternalRepresentation(key, &err);
    if (!ext) {
        PearLog(@"[PearRuntime][keychain] SecKeyCopyExternalRepresentation failed: %@", err);
        return;
    }
    item[@"__keydata"] = CFBridgingRelease(ext);

    item[@"__id"] = IdentifierForQuery(item);
    SaveItem(item);
}

/// Rebuilds a SecKeyRef from a stored key item. Keys may be stored either as a
/// SecKeyRef (kSecValueRef → __keydata) or as raw data with kSecClassKey
/// (kSecValueData → __data).
static SecKeyRef CopySecKeyFromItem(NSDictionary *item) {
    NSData *keyData = item[@"__keydata"] ?: item[@"__data"];
    if (!keyData) return NULL;

    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[(__bridge id)kSecClass] = (__bridge id)kSecClassKey;
    for (id k in @[ (__bridge id)kSecAttrKeyType, (__bridge id)kSecAttrKeyClass,
                    (__bridge id)kSecAttrKeySizeInBits ]) {
        if (item[k]) attrs[k] = item[k];
    }
    // A key class is required to interpret the data; default to RSA public.
    if (!attrs[(__bridge id)kSecAttrKeyClass]) {
        attrs[(__bridge id)kSecAttrKeyClass] = (__bridge id)kSecAttrKeyClassPublic;
    }

    CFErrorRef err = NULL;
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)keyData,
                                         (__bridge CFDictionaryRef)attrs, &err);
    if (!key) PearLog(@"[PearRuntime][keychain] SecKeyCreateWithData failed: %@", err);
    return key;
}

#pragma mark - Interposed implementations

static OSStatus PearSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSDictionary *query = CFBridgingRelease(CFRetain(attributes));
    NSMutableDictionary *item = [@{} mutableCopy];
    for (id key in query) {
        if (IsControlKey(key)) continue;
        item[key] = query[key];
    }

    NSData *value = query[(__bridge id)kSecValueData];
    if (value) item[@"__data"] = value;

    // iOS fills this in for the caller; SDKs that read it back expect it.
    if (!item[(__bridge id)kSecAttrAccessGroup]) {
        item[(__bridge id)kSecAttrAccessGroup] = DefaultAccessGroup();
    }

    PearLog(@"[PearRuntime][keychain] SecItemAdd query keys: %@ (valueData=%d valueRef=%d retRef=%d retData=%d)",
          [query.allKeys componentsJoinedByString:@","],
          value != nil,
          query[(__bridge id)kSecValueRef] != nil,
          [query[(__bridge id)kSecReturnRef] boolValue],
          [query[(__bridge id)kSecReturnData] boolValue]);

    // A SecKeyRef (kSecValueRef) is persisted by exporting its representation.
    id valueRef = query[(__bridge id)kSecValueRef];
    if (valueRef && CFGetTypeID((__bridge CFTypeRef)valueRef) == SecKeyGetTypeID()) {
        CFErrorRef err = NULL;
        CFDataRef ext = SecKeyCopyExternalRepresentation((__bridge SecKeyRef)valueRef, &err);
        if (ext) {
            item[@"__keydata"] = CFBridgingRelease(ext);
            CFStringRef keyClass = (__bridge CFStringRef)query[(__bridge id)kSecAttrKeyClass]
                                   ?: kSecAttrKeyClassPublic;
            item[(__bridge id)kSecClass] = (__bridge id)kSecClassKey;
            item[(__bridge id)kSecAttrKeyClass] = (__bridge id)keyClass;
        }
    }

    NSString *identifier = IdentifierForQuery(query);
    if (identifier.length == 0) identifier = [[NSUUID UUID] UUIDString];
    item[@"__id"] = identifier;
    item[@"__persistentRef"] = [identifier dataUsingEncoding:NSUTF8StringEncoding];

    // Upsert: overwrite any item with the same identity rather than failing
    // with errSecDuplicateItem. Apps that delete-then-add keep working, and
    // stale state from a previous run does not cause a spurious failure.
    SaveItem(item);
    PearLog(@"[PearRuntime][keychain] SecItemAdd id=%@", identifier);

    // Match iOS result semantics. A key item added with kSecReturnRef must hand
    // back a SecKeyRef, not an opaque identifier — callers use it as a key.
    if (result) {
        BOOL wantRef = [query[(__bridge id)kSecReturnRef] boolValue];
        BOOL wantData = [query[(__bridge id)kSecReturnData] boolValue];
        BOOL wantPersistent = [query[(__bridge id)kSecReturnPersistentRef] boolValue];

        if (wantRef) {
            if (valueRef) {
                *result = (void *)CFRetain((__bridge CFTypeRef)valueRef);
            } else {
                *result = CFBridgingRetain(identifier);
            }
        } else if (wantPersistent) {
            *result = CFBridgingRetain(item[@"__persistentRef"]);
        } else if (wantData) {
            NSData *data = item[@"__data"] ?: item[@"__keydata"];
            *result = data ? CFBridgingRetain(data) : NULL;
        }
        // otherwise leave *result untouched, as the system does.
    }
    return errSecSuccess;
}

static OSStatus PearSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *q = CFBridgingRelease(CFRetain(query));

    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *item in LoadAll()) {
        if (Matches(item, q)) [matches addObject:item];
    }

    BOOL wantAll = [q[(__bridge id)kSecMatchLimit] isEqual:(__bridge id)kSecMatchLimitAll];
    if (!wantAll && matches.count > 1) {
        matches = [[matches subarrayWithRange:NSMakeRange(0, 1)] mutableCopy];
    }
    if (matches.count == 0) {
        return errSecItemNotFound;
    }

    BOOL wantData = [q[(__bridge id)kSecReturnData] boolValue];
    BOOL wantAttrs = [q[(__bridge id)kSecReturnAttributes] boolValue];
    BOOL wantRef = [q[(__bridge id)kSecReturnRef] boolValue];

    NSMutableArray *outputs = [NSMutableArray array];
    for (NSDictionary *item in matches) {
        NSData *value = item[@"__data"];

        // Key items: rebuild a SecKeyRef when the caller wants a reference.
        // A key class item must yield a key even when stored as raw data.
        BOOL isKeyClass = [item[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassKey];
        if (item[@"__keydata"] || isKeyClass) {
            PearLog(@"[PearRuntime][keychain] key item: wantData=%d wantAttrs=%d wantRef=%d",
                  wantData, wantAttrs, wantRef);
            if (wantRef) {
                SecKeyRef key = CopySecKeyFromItem(item);
                if (key) { [outputs addObject:(__bridge_transfer id)key]; continue; }
            }
            NSData *keyData = item[@"__keydata"] ?: item[@"__data"];
            // A caller that asked only for data expects NSData, not an
            // attribute dictionary. Returning a dictionary here makes callers
            // that read `bytes` fail with an unrecognized selector.
            if (wantData && !wantAttrs && !wantRef) {
                if (keyData) [outputs addObject:keyData];
                continue;
            }
            NSMutableDictionary *attrs = [item mutableCopy];
            [attrs removeObjectForKey:@"__id"];
            [attrs removeObjectForKey:@"__keydata"];
            [attrs removeObjectForKey:@"__persistentRef"];
            if (!attrs[(__bridge id)kSecAttrAccessGroup]) {
                attrs[(__bridge id)kSecAttrAccessGroup] = DefaultAccessGroup();
            }
            if (wantData && keyData) {
                attrs[(__bridge id)kSecValueData] = keyData;
            }
            [outputs addObject:attrs];
            continue;
        }

        // iOS semantics: attributes (or a ref) produce a dictionary; when data is
        // also requested it is included under kSecValueData. Data alone is only
        // returned when no attribute output was asked for.
        if (wantAttrs || wantRef) {
            NSMutableDictionary *attrs = [item mutableCopy];
            [attrs removeObjectForKey:@"__id"];
            [attrs removeObjectForKey:@"__data"];
            if (!attrs[(__bridge id)kSecAttrAccessGroup]) {
                attrs[(__bridge id)kSecAttrAccessGroup] = DefaultAccessGroup();
            }
            if (wantData && value) attrs[(__bridge id)kSecValueData] = value;
            [outputs addObject:attrs];
        } else if (wantData) {
            if (value) [outputs addObject:value];
        } else {
            NSMutableDictionary *attrs = [item mutableCopy];
            [attrs removeObjectForKey:@"__id"];
            if (!attrs[(__bridge id)kSecAttrAccessGroup]) {
                attrs[(__bridge id)kSecAttrAccessGroup] = DefaultAccessGroup();
            }
            [outputs addObject:attrs];
        }
    }

    if (outputs.count == 0) return errSecItemNotFound;

    id value = wantAll ? outputs : outputs.firstObject;
    if (result) *result = CFBridgingRetain(value);
    PearLog(@"[PearRuntime][keychain] SecItemCopyMatching -> %lu item(s)", (unsigned long)outputs.count);
    return errSecSuccess;
}

static OSStatus PearSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSDictionary *q = CFBridgingRelease(CFRetain(query));
    NSDictionary *update = CFBridgingRelease(CFRetain(attributesToUpdate));

    BOOL updated = NO;
    for (NSDictionary *item in LoadAll()) {
        if (!Matches(item, q)) continue;
        NSMutableDictionary *changed = [item mutableCopy];
        for (id key in update) {
            if ([key isEqual:(__bridge id)kSecValueData]) {
                changed[@"__data"] = update[key];
            } else if (!IsControlKey(key)) {
                changed[key] = update[key];
            }
        }
        SaveItem(changed);
        updated = YES;
    }
    PearLog(@"[PearRuntime][keychain] SecItemUpdate updated=%d", updated);
    return updated ? errSecSuccess : errSecItemNotFound;
}

static OSStatus PearSecItemDelete(CFDictionaryRef query) {
    NSDictionary *q = CFBridgingRelease(CFRetain(query));
    BOOL deleted = NO;
    for (NSDictionary *item in LoadAll()) {
        if (!Matches(item, q)) continue;
        DeleteItemWithId(item[@"__id"]);
        deleted = YES;
    }
    PearLog(@"[PearRuntime][keychain] SecItemDelete deleted=%d", deleted);
    return deleted ? errSecSuccess : errSecItemNotFound;
}

#pragma mark - dyld interposing

#define PEAR_INTERPOSE(replacement, replacee)                                     \
    __attribute__((used)) static struct {                                         \
        const void *replacement;                                                  \
        const void *replacee;                                                     \
    } _interpose_##replacee                                                       \
        __attribute__((section("__DATA,__interpose"))) = {                        \
            (const void *)(uintptr_t)&replacement,                                \
            (const void *)(uintptr_t)&replacee                                    \
    };

PEAR_INTERPOSE(PearSecItemAdd, SecItemAdd)
PEAR_INTERPOSE(PearSecItemCopyMatching, SecItemCopyMatching)
PEAR_INTERPOSE(PearSecItemUpdate, SecItemUpdate)
PEAR_INTERPOSE(PearSecItemDelete, SecItemDelete)

// SecKeyCreateRandomKey on a locally prepared build routes through a
// keychain-backed store, which fails with -34018 (errSecMissingEntitlement)
// without restricted entitlements. Removing the store-only attributes lets the
// platform build an in-memory key; the shim persists the result itself when the
// caller asked for a permanent key.
typedef SecKeyRef (*SecKeyCreateRandomKeyFn)(CFDictionaryRef, CFErrorRef *);

static SecKeyRef PearSecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error);

// The interpose table is the reliable source of the original function. A
// `dlsym(RTLD_NEXT, …)` lookup can resolve back to this replacement on the
// macOS iOS-support runtime, which recursed until the stack overflowed.
__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeSecKeyCreateRandomKey
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSecKeyCreateRandomKey,
        (const void *)(uintptr_t)&SecKeyCreateRandomKey
    };

/// Attributes that make the platform store a key in securityd. An in-memory
/// compatibility key cannot use them without restricted entitlements, so they
/// are removed before key generation.
static void PearStripStoreOnlyKeyAttributes(NSMutableDictionary *params) {
    if (!params) return;
    params[(__bridge id)kSecAttrIsPermanent] = @NO;
    NSArray *keys = @[ (__bridge id)kSecAttrAccessControl,
                       (__bridge id)kSecAttrAccessGroup,
                       (__bridge id)kSecAttrTokenID,
                       (__bridge id)kSecAttrApplicationTag ];
    for (id key in keys) [params removeObjectForKey:key];

    id privateAttrs = params[(__bridge id)kSecPrivateKeyAttrs];
    if ([privateAttrs isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *priv = [privateAttrs mutableCopy];
        priv[(__bridge id)kSecAttrIsPermanent] = @NO;
        for (id key in keys) [priv removeObjectForKey:key];
        params[(__bridge id)kSecPrivateKeyAttrs] = priv;
    }
}

static BOOL PearWantsPersistentKey(NSDictionary *params) {
    if ([params[(__bridge id)kSecAttrIsPermanent] boolValue]) return YES;
    id privateAttrs = params[(__bridge id)kSecPrivateKeyAttrs];
    return [privateAttrs isKindOfClass:NSDictionary.class] &&
           [privateAttrs[(__bridge id)kSecAttrIsPermanent] boolValue];
}

static SecKeyRef PearSecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    SecKeyCreateRandomKeyFn original = (SecKeyCreateRandomKeyFn)kInterposeSecKeyCreateRandomKey.replacee;
    if (!original) return NULL;

    NSDictionary *requested = parameters ? (__bridge NSDictionary *)parameters : @{};
    BOOL persistent = PearWantsPersistentKey(requested);

    NSMutableDictionary *params = [requested mutableCopy] ?: [NSMutableDictionary dictionary];
    PearStripStoreOnlyKeyAttributes(params);

    PearLog(@"[PearRuntime][keychain] SecKeyCreateRandomKey type=%@ size=%@ persistent=%d",
            params[(__bridge id)kSecAttrKeyType] ?: @"?",
            params[(__bridge id)kSecAttrKeySizeInBits] ?: @"?", persistent);

    SecKeyRef key = original((__bridge CFDictionaryRef)params, error);
    if (!key) {
        PearLog(@"[PearRuntime][keychain] SecKeyCreateRandomKey failed: %@",
                (error && *error) ? (__bridge id)*error : @"unknown");
        return NULL;
    }
    if (persistent) StoreSecKey(key, requested, kSecAttrKeyClassPrivate);
    return key;
}

typedef OSStatus (*SecKeyGeneratePairFn)(CFDictionaryRef, SecKeyRef *, SecKeyRef *);

// The interpose entry's `replacee` is filled in by dyld with the ORIGINAL
// function. We must read it from here: dlsym(RTLD_NEXT, ...) returns our own
// replacement and would recurse forever.
static OSStatus PearSecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeSecKeyGeneratePair
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearSecKeyGeneratePair,
        (const void *)(uintptr_t)&SecKeyGeneratePair
    };

static OSStatus PearSecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    SecKeyGeneratePairFn original = (SecKeyGeneratePairFn)kInterposeSecKeyGeneratePair.replacee;
    if (!original) return errSecUnimplemented;

    NSDictionary *requested = parameters ? (__bridge NSDictionary *)parameters : @{};
    NSMutableDictionary *params = [requested mutableCopy] ?: [NSMutableDictionary dictionary];
    PearStripStoreOnlyKeyAttributes(params);

    PearLog(@"[PearRuntime][keychain] SecKeyGeneratePair type=%@ size=%@",
            params[(__bridge id)kSecAttrKeyType] ?: @"?",
            params[(__bridge id)kSecAttrKeySizeInBits] ?: @"?");

    OSStatus status = original((__bridge CFDictionaryRef)params, publicKey, privateKey);
    if (status != errSecSuccess) {
        PearLog(@"[PearRuntime][keychain] SecKeyGeneratePair failed: %d", (int)status);
        return status;
    }
    if (publicKey && privateKey && *publicKey && *privateKey) {
        // Persist both keys in our own store so later lookups succeed.
        StoreSecKey(*publicKey, requested, kSecAttrKeyClassPublic);
        StoreSecKey(*privateKey, requested, kSecAttrKeyClassPrivate);
    }
    return status;
}
