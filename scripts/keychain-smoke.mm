// Production-code, headless keychain fixture. Only synthetic temporary stores.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
        exit(1); \
    } \
} while (0)

#ifndef PEAR_KEYCHAIN_SOURCE
#define PEAR_KEYCHAIN_SOURCE "../runtime/KeychainShim.mm"
#endif

#if defined(PEAR_KEYCHAIN_ACTIVE_DYLIB)
#import <dlfcn.h>

static unsigned gActiveLegacyCalls;
static void PearLog(NSString *format, ...) {
    // Count entry without formatting queries or key material into the output.
    if ([format hasPrefix:@"[PearRuntime][keychain] SecKeyGeneratePair type="]) ++gActiveLegacyCalls;
}
#include PEAR_KEYCHAIN_SOURCE

extern "C" int PearSmokeActiveAudit(const void *caller, unsigned *calls) {
    Dl_info original = {};
    *calls = gActiveLegacyCalls;
    return caller == kInterposeSecKeyGeneratePair.replacement &&
        kInterposeSecKeyGeneratePair.replacee != kInterposeSecKeyGeneratePair.replacement &&
        dladdr(kInterposeSecKeyGeneratePair.replacee, &original) &&
        original.dli_fname && strstr(original.dli_fname, "/Security.framework/") &&
        original.dli_sname && !strcmp(original.dli_sname, "SecKeyGeneratePair");
}

#elif defined(PEAR_KEYCHAIN_ACTIVE_CLI)
#import <servers/bootstrap.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

extern "C" int PearSmokeActiveAudit(const void *, unsigned *);

static NSString *ActiveEnvironment(const char *name) {
    const char *value = getenv(name);
    CHECK(value && value[0]);
    return [NSString stringWithUTF8String:value];
}
static void ActiveGuards(void) {
    NSString *root = ActiveEnvironment("KEYCHAIN_SMOKE_ROOT");
    CHECK([ActiveEnvironment("PEAR_KEYCHAIN_DIR") hasPrefix:[root stringByAppendingString:@"/"]]);
    CHECK([ActiveEnvironment("HOME") hasPrefix:[root stringByAppendingString:@"/"]]);
    // A bootstrap lookup is not a credential operation. It must be rejected
    // before any Security API is invoked, even if this service exists.
    mach_port_t service = MACH_PORT_NULL;
    kern_return_t lookup = bootstrap_look_up(bootstrap_port, "com.apple.securityd", &service);
    if (lookup == BOOTSTRAP_SUCCESS) mach_port_deallocate(mach_task_self(), service);
    CHECK(lookup == BOOTSTRAP_NOT_PRIVILEGED);
    NSString *denied = ActiveEnvironment("KEYCHAIN_SMOKE_DENIED_FILE");
    errno = 0;
    int fd = open(denied.fileSystemRepresentation, O_RDONLY);
    int readError = errno;
    if (fd >= 0) close(fd);
    CHECK(fd == -1 && (readError == EPERM || readError == EACCES));
    errno = 0;
    fd = open(denied.fileSystemRepresentation, O_WRONLY);
    int writeError = errno;
    if (fd >= 0) close(fd);
    CHECK(fd == -1 && (writeError == EPERM || writeError == EACCES));
    NSString *positive = [root stringByAppendingPathComponent:@"guard-positive"];
    fd = open(positive.fileSystemRepresentation, O_CREAT | O_WRONLY, 0600);
    CHECK(fd >= 0);
    CHECK(close(fd) == 0);
    unsigned calls = 999;
    CHECK(PearSmokeActiveAudit((const void *)(uintptr_t)&SecKeyGeneratePair, &calls));
    CHECK(calls == 0);
    printf("PASS active guards: securityd lookup=%d, outside read=%d/write=%d denied; temp write allowed\n",
           lookup, readError, writeError);
    puts("PASS active binding: CLI -> production replacement; replacee -> Security.framework/SecKeyGeneratePair");
}
static NSData *ActiveTag(NSString *side) {
    NSString *tag = [ActiveEnvironment("KEYCHAIN_SMOKE_RUN_ID") stringByAppendingFormat:@"-%@", side];
    return [tag dataUsingEncoding:NSUTF8StringEncoding];
}
static void ActiveKeyClass(SecKeyRef key, CFStringRef keyClass) {
    CHECK(key && CFGetTypeID(key) == SecKeyGetTypeID());
    NSDictionary *attrs = CFBridgingRelease(SecKeyCopyAttributes(key));
    CHECK([attrs[(__bridge id)kSecAttrKeyClass] isEqual:(__bridge id)keyClass]);
    CHECK([attrs[(__bridge id)kSecAttrKeySizeInBits] integerValue] == 512);
}
static SecKeyRef ActiveLookup(NSString *side, CFStringRef keyClass) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassKey,
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeyClass: (__bridge id)keyClass,
        (__bridge id)kSecAttrApplicationTag: ActiveTag(side),
        (__bridge id)kSecReturnRef: @YES,
    };
    CFTypeRef result = NULL;
    CHECK(SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess);
    ActiveKeyClass((SecKeyRef)result, keyClass);
    return (SecKeyRef)result;
}
static NSData *ActiveExport(SecKeyRef key) {
    CFErrorRef error = NULL;
    NSData *result = CFBridgingRelease(SecKeyCopyExternalRepresentation(key, &error));
    CHECK(result && error == NULL);
    return result;
}
static void ActiveSignVerify(SecKeyRef pub, SecKeyRef priv) {
    NSData *message = [@"synthetic active-interpose message" dataUsingEncoding:NSUTF8StringEncoding];
    CFErrorRef error = NULL;
    NSData *signature = CFBridgingRelease(SecKeyCreateSignature(priv,
        kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)message, &error));
    CHECK(signature && error == NULL);
    CHECK(SecKeyVerifySignature(pub, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
        (__bridge CFDataRef)message, (__bridge CFDataRef)signature, &error));
    CHECK(error == NULL);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        CHECK(argc == 2);
        ActiveGuards();
        if (!strcmp(argv[1], "guard")) return 0;
        CHECK(!strcmp(argv[1], "generate") || !strcmp(argv[1], "reload"));
        BOOL generate = !strcmp(argv[1], "generate");
        SecKeyRef pub = NULL, priv = NULL;
        if (generate) {
            NSString *label = ActiveEnvironment("KEYCHAIN_SMOKE_RUN_ID");
            NSDictionary *request = @{
                (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
                (__bridge id)kSecAttrKeySizeInBits: @512,
                (__bridge id)kSecPublicKeyAttrs: @{
                    (__bridge id)kSecAttrIsPermanent: @YES,
                    (__bridge id)kSecAttrApplicationTag: ActiveTag(@"public"),
                    (__bridge id)kSecAttrLabel: [label stringByAppendingString:@"-public"],
                    (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                },
                (__bridge id)kSecPrivateKeyAttrs: @{
                    (__bridge id)kSecAttrIsPermanent: @YES,
                    (__bridge id)kSecAttrApplicationTag: ActiveTag(@"private"),
                    (__bridge id)kSecAttrLabel: [label stringByAppendingString:@"-private"],
                    (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                },
            };
            // No macro remapping, adapter, or substitute Security implementation.
            OSStatus status = SecKeyGeneratePair((__bridge CFDictionaryRef)request, &pub, &priv);
            unsigned calls = 0;
            CHECK(PearSmokeActiveAudit((const void *)(uintptr_t)&SecKeyGeneratePair, &calls));
            printf("ACTUAL Catalyst SecKeyGeneratePair: status=%d, production wrapper entries=%u, requested RSA bits=512\n",
                   (int)status, calls);
            CHECK(calls == 1);
            if (status != errSecSuccess) {
                if (pub) CFRelease(pub);
                if (priv) CFRelease(priv);
                return 2;
            }
            ActiveKeyClass(pub, kSecAttrKeyClassPublic);
            ActiveKeyClass(priv, kSecAttrKeyClassPrivate);
            ActiveSignVerify(pub, priv);
            CHECK([ActiveExport(pub) writeToFile:[ActiveEnvironment("KEYCHAIN_SMOKE_ROOT")
                stringByAppendingPathComponent:@"active-public.der"] atomically:YES]);
            CFRelease(pub); CFRelease(priv);
        }
        pub = ActiveLookup(@"public", kSecAttrKeyClassPublic);
        priv = ActiveLookup(@"private", kSecAttrKeyClassPrivate);
        ActiveSignVerify(pub, priv);
        NSData *expected = [NSData dataWithContentsOfFile:[ActiveEnvironment("KEYCHAIN_SMOKE_ROOT")
            stringByAppendingPathComponent:@"active-public.der"]];
        CHECK(expected && [ActiveExport(pub) isEqual:expected]);
        CFRelease(pub); CFRelease(priv);
        unsigned calls = 999;
        CHECK(PearSmokeActiveAudit((const void *)(uintptr_t)&SecKeyGeneratePair, &calls));
        CHECK(calls == (generate ? 1U : 0U));
        puts(generate ? "PASS actual legacy generation, RSA 512 sign/verify and shim tag lookup"
                      : "PASS active-interpose fresh-process RSA 512 tag reload/sign/verify without generation");
    }
    return 0;
}

#else

// Capture the modern platform entry point before remapping the interpose table.
// Never call native SecKeyGeneratePair: macOS can ignore its transient flags.
static SecKeyRef PlatformRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    return SecKeyCreateRandomKey(parameters, error);
}
static OSStatus UnexpectedAdd(CFDictionaryRef, CFTypeRef *) { abort(); }
static OSStatus UnexpectedCopy(CFDictionaryRef, CFTypeRef *) { abort(); }
static OSStatus UnexpectedUpdate(CFDictionaryRef, CFDictionaryRef) { abort(); }
static OSStatus UnexpectedDelete(CFDictionaryRef) { abort(); }
static OSStatus FixtureGeneratePair(CFDictionaryRef, SecKeyRef *, SecKeyRef *);
static SecKeyRef FixtureRandomKey(CFDictionaryRef, CFErrorRef *);

// No production logging: even synthetic private key representations stay out of
// stdout. Remapping these names does not interpose any system Security symbol.
static void PearLog(NSString *, ...) {}
#define SecItemAdd UnexpectedAdd
#define SecItemCopyMatching UnexpectedCopy
#define SecItemUpdate UnexpectedUpdate
#define SecItemDelete UnexpectedDelete
#define SecKeyGeneratePair FixtureGeneratePair
#define SecKeyCreateRandomKey FixtureRandomKey
#include PEAR_KEYCHAIN_SOURCE
#undef SecItemAdd
#undef SecItemCopyMatching
#undef SecItemUpdate
#undef SecItemDelete
#undef SecKeyGeneratePair
#undef SecKeyCreateRandomKey

static NSDictionary *gExpectedRequest;
static OSStatus gPairFailure;
static CFErrorRef gRandomFailure;
static OSStatus gNativeStatus;
static CFErrorRef gNativeError; // Borrowed until the caller releases its error.
static BOOL gReenterRandom;
static NSUInteger gReentrantItems;
static NSUInteger gPairCalls, gRandomCalls;

static NSString *Root(void) {
    const char *root = getenv("KEYCHAIN_SMOKE_ROOT");
    CHECK(root && root[0] == '/');
    return [NSString stringWithUTF8String:root];
}
static void SelectStore(NSString *name) {
    NSString *path = [Root() stringByAppendingPathComponent:name];
    CHECK(setenv("PEAR_KEYCHAIN_DIR", path.fileSystemRepresentation, 1) == 0);
}
static NSData *Tag(NSString *name) { return [name dataUsingEncoding:NSUTF8StringEncoding]; }
static NSString *PublicTag(NSString *prefix) { return [prefix stringByAppendingString:@"-public"]; }
static NSString *PrivateTag(NSString *prefix) { return [prefix stringByAppendingString:@"-private"]; }
static NSUInteger Items(void) { return LoadAll().count; }

static NSDictionary *Snapshot(NSDictionary *request) {
    NSMutableDictionary *copy = [request mutableCopy];
    for (id key in @[ (__bridge id)kSecPublicKeyAttrs, (__bridge id)kSecPrivateKeyAttrs ]) {
        id nested = request[key];
        if ([nested isKindOfClass:NSDictionary.class]) copy[key] = [nested copy];
    }
    return copy;
}
static NSMutableDictionary *Request(NSString *prefix, NSUInteger bits,
                                    NSNumber *shared, NSNumber *pub, NSNumber *priv) {
    NSMutableDictionary *result = [@{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeySizeInBits: @(bits),
        (__bridge id)kSecAttrLabel: @"shared-label",
    } mutableCopy];
    if (shared) result[(__bridge id)kSecAttrIsPermanent] = shared;
    NSMutableDictionary *publicAttrs = [@{
        (__bridge id)kSecAttrApplicationTag: Tag(PublicTag(prefix)),
        (__bridge id)kSecAttrLabel: @"public-label",
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    } mutableCopy];
    NSMutableDictionary *privateAttrs = [@{
        (__bridge id)kSecAttrApplicationTag: Tag(PrivateTag(prefix)),
        (__bridge id)kSecAttrLabel: @"private-label",
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    } mutableCopy];
    if (pub) publicAttrs[(__bridge id)kSecAttrIsPermanent] = pub;
    if (priv) privateAttrs[(__bridge id)kSecAttrIsPermanent] = priv;
    result[(__bridge id)kSecPublicKeyAttrs] = publicAttrs;
    result[(__bridge id)kSecPrivateKeyAttrs] = privateAttrs;
    return result;
}

// Independently specify exactly which inputs may change before platform crypto.
static NSMutableDictionary *ExpectedLayer(NSDictionary *original) {
    NSMutableDictionary *expected = [original mutableCopy];
    expected[(__bridge id)kSecAttrIsPermanent] = @NO;
    for (id key in @[ (__bridge id)kSecAttrAccessControl, (__bridge id)kSecAttrAccessGroup,
                      (__bridge id)kSecAttrTokenID, (__bridge id)kSecAttrApplicationTag ]) {
        [expected removeObjectForKey:key];
    }
    return expected;
}
static void AssertSanitized(CFDictionaryRef parameters) {
    CHECK(gExpectedRequest != nil);
    NSMutableDictionary *expected = ExpectedLayer(gExpectedRequest);
    for (id key in @[ (__bridge id)kSecPublicKeyAttrs, (__bridge id)kSecPrivateKeyAttrs ]) {
        id nested = gExpectedRequest[key];
        if ([nested isKindOfClass:NSDictionary.class]) expected[key] = ExpectedLayer(nested);
    }
    CHECK([(__bridge NSDictionary *)parameters isEqual:expected]);
}
static SecKeyRef FixtureRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    ++gRandomCalls;
    AssertSanitized(parameters);
    if (gRandomFailure) {
        if (error) *error = (CFErrorRef)CFRetain(gRandomFailure);
        return NULL;
    }
    SecKeyRef key = PlatformRandomKey(parameters, error);
    gNativeError = error ? *error : NULL;
    return key;
}
static OSStatus FixtureGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    ++gPairCalls;
    AssertSanitized(parameters);
    if (gPairFailure) return gPairFailure;
    CFErrorRef error = NULL;
    SecKeyRef priv;
    if (gReenterRandom) {
        NSDictionary *outer = gExpectedRequest;
        gExpectedRequest = (__bridge NSDictionary *)parameters;
        priv = PearSecKeyCreateRandomKey(parameters, &error);
        gExpectedRequest = outer;
        gReentrantItems = Items();
    } else {
        priv = PlatformRandomKey(parameters, &error);
    }
    if (!priv) {
        gNativeStatus = error ? (OSStatus)CFErrorGetCode(error) : errSecInternalComponent;
        if (error) CFRelease(error);
        return gNativeStatus;
    }
    SecKeyRef pub = SecKeyCopyPublicKey(priv);
    CHECK(pub != NULL);
    if (publicKey) *publicKey = pub; else CFRelease(pub);
    if (privateKey) *privateKey = priv; else CFRelease(priv);
    gNativeStatus = errSecSuccess;
    return errSecSuccess;
}

struct Pair {
    SecKeyRef pub = NULL, priv = NULL;
    Pair() = default;
    Pair(const Pair &) = delete;
    ~Pair() { if (pub) CFRelease(pub); if (priv) CFRelease(priv); }
};
static OSStatus Generate(NSDictionary *request, Pair &pair) {
    NSDictionary *before = Snapshot(request);
    gExpectedRequest = before;
    OSStatus status = PearSecKeyGeneratePair((__bridge CFDictionaryRef)request, &pair.pub, &pair.priv);
    CHECK([request isEqual:before]);
    return status;
}
static SecKeyRef Random(NSDictionary *request, CFErrorRef *error) {
    NSDictionary *before = Snapshot(request);
    gExpectedRequest = before;
    SecKeyRef key = PearSecKeyCreateRandomKey((__bridge CFDictionaryRef)request, error);
    CHECK([request isEqual:before]);
    return key;
}
static NSData *Export(SecKeyRef key) {
    CFErrorRef error = NULL;
    NSData *data = CFBridgingRelease(SecKeyCopyExternalRepresentation(key, &error));
    CHECK(data != nil && error == NULL);
    return data;
}
static void KeyClass(SecKeyRef key, CFStringRef keyClass, NSUInteger bits) {
    CHECK(key && CFGetTypeID(key) == SecKeyGetTypeID());
    NSDictionary *attributes = CFBridgingRelease(SecKeyCopyAttributes(key));
    CHECK([attributes[(__bridge id)kSecAttrKeyClass] isEqual:(__bridge id)keyClass]);
    CHECK([attributes[(__bridge id)kSecAttrKeySizeInBits] unsignedIntegerValue] == bits);
}
static NSMutableDictionary *Query(NSString *tag, CFStringRef keyClass, NSString *group = nil) {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassKey,
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeyClass: (__bridge id)keyClass,
        (__bridge id)kSecAttrApplicationTag: Tag(tag),
    } mutableCopy];
    if (group) query[(__bridge id)kSecAttrAccessGroup] = group;
    return query;
}
static SecKeyRef Lookup(NSString *tag, CFStringRef keyClass, NSUInteger bits = 1024, NSString *group = nil) {
    NSMutableDictionary *query = Query(tag, keyClass, group);
    query[(__bridge id)kSecReturnRef] = @YES;
    CFTypeRef result = NULL;
    CHECK(PearSecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess);
    KeyClass((SecKeyRef)result, keyClass, bits);
    return (SecKeyRef)result;
}
static void Missing(NSString *tag, CFStringRef keyClass, NSString *group = nil) {
    NSMutableDictionary *query = Query(tag, keyClass, group);
    query[(__bridge id)kSecReturnRef] = @YES;
    CFTypeRef result = NULL;
    CHECK(PearSecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecItemNotFound);
    CHECK(result == NULL);
}
static void Metadata(NSString *tag, CFStringRef keyClass, NSString *label,
                     CFStringRef accessibility, NSString *group = nil) {
    NSMutableDictionary *query = Query(tag, keyClass, group);
    query[(__bridge id)kSecReturnAttributes] = @YES;
    CFTypeRef result = NULL;
    CHECK(PearSecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess);
    NSDictionary *attributes = CFBridgingRelease(result);
    CHECK([attributes[(__bridge id)kSecAttrLabel] isEqual:label]);
    CHECK([attributes[(__bridge id)kSecAttrAccessible] isEqual:(__bridge id)accessibility]);
    CHECK([attributes[(__bridge id)kSecAttrKeyClass] isEqual:(__bridge id)keyClass]);
    CHECK(attributes[(__bridge id)kSecPublicKeyAttrs] == nil);
    CHECK(attributes[(__bridge id)kSecPrivateKeyAttrs] == nil);
}
static NSData *Signature(SecKeyRef privateKey) {
    CFErrorRef error = NULL;
    NSData *message = Tag(@"synthetic keychain smoke message");
    NSData *signature = CFBridgingRelease(SecKeyCreateSignature(privateKey,
        kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)message, &error));
    if (!signature) fprintf(stderr, "Signing failed: %ld\n", error ? CFErrorGetCode(error) : 0L);
    CHECK(signature != nil && error == NULL);
    return signature;
}
static void Verify(SecKeyRef publicKey, NSData *signature, BOOL expected = YES) {
    CFErrorRef error = NULL;
    NSData *message = Tag(@"synthetic keychain smoke message");
    BOOL verified = SecKeyVerifySignature(publicKey, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
        (__bridge CFDataRef)message, (__bridge CFDataRef)signature, &error);
    CHECK(verified == expected);
    if (expected) CHECK(error == NULL);
    if (error) CFRelease(error);
}
static void SignVerify(SecKeyRef pub, SecKeyRef priv) { Verify(pub, Signature(priv)); }

static void TestSanitizer(void) {
    SelectStore(@"sanitizer");
    NSMutableDictionary *request = Request(@"sanitizer", 1024, @YES, @YES, @YES);
    NSArray *layers = @[ request, request[(__bridge id)kSecPublicKeyAttrs], request[(__bridge id)kSecPrivateKeyAttrs] ];
    for (NSUInteger index = 0; index < layers.count; ++index) {
        NSMutableDictionary *layer = layers[index];
        layer[(__bridge id)kSecAttrAccessControl] = @"synthetic-store-only-control";
        layer[(__bridge id)kSecAttrTokenID] = @"synthetic-store-only-token";
        layer[(__bridge id)kSecAttrAccessGroup] = [NSString stringWithFormat:@"smoke-group-%lu", index];
    }
    request[(__bridge id)kSecAttrApplicationTag] = Tag(@"shared-tag-must-not-win");
    Pair pair;
    CHECK(Generate(request, pair) == errSecSuccess);
    CHECK(Items() == 2);
    SecKeyRef pub = Lookup(PublicTag(@"sanitizer"), kSecAttrKeyClassPublic, 1024, @"smoke-group-1");
    SecKeyRef priv = Lookup(PrivateTag(@"sanitizer"), kSecAttrKeyClassPrivate, 1024, @"smoke-group-2");
    SignVerify(pub, priv);
    CFRelease(pub); CFRelease(priv);
    Metadata(PublicTag(@"sanitizer"), kSecAttrKeyClassPublic, @"public-label",
             kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, @"smoke-group-1");
    Metadata(PrivateTag(@"sanitizer"), kSecAttrKeyClassPrivate, @"private-label",
             kSecAttrAccessibleWhenUnlockedThisDeviceOnly, @"smoke-group-2");
    Missing(PrivateTag(@"sanitizer"), kSecAttrKeyClassPrivate, @"smoke-group-1");
    puts("PASS symmetric sanitizer, immutable input, per-key metadata and groups");
}

static void TestPermanence(void) {
    NSArray *flags = @[ NSNull.null, @NO, @YES ];
    NSUInteger cases = 0;
    for (id shared in flags) for (id pub in flags) for (id priv in flags) {
        NSNumber *s = shared == NSNull.null ? nil : shared;
        NSNumber *p = pub == NSNull.null ? nil : pub;
        NSNumber *v = priv == NSNull.null ? nil : priv;
        SelectStore([NSString stringWithFormat:@"pair-permanence-%lu", cases]);
        NSDictionary *request = Request(@"matrix", 1024, s, p, v);
        Pair pair;
        CHECK(Generate(request, pair) == errSecSuccess);
        BOOL persistPublic = p ? p.boolValue : (s ? s.boolValue : YES);
        BOOL persistPrivate = v ? v.boolValue : (s ? s.boolValue : YES);
        CHECK(Items() == (NSUInteger)persistPublic + (NSUInteger)persistPrivate);
        for (NSUInteger side = 0; side < 2; ++side) {
            BOOL persistent = side == 0 ? persistPublic : persistPrivate;
            NSString *tag = side == 0 ? PublicTag(@"matrix") : PrivateTag(@"matrix");
            CFStringRef keyClass = side == 0 ? kSecAttrKeyClassPublic : kSecAttrKeyClassPrivate;
            if (persistent) { SecKeyRef key = Lookup(tag, keyClass); CFRelease(key); }
            else Missing(tag, keyClass);
        }
        SelectStore([NSString stringWithFormat:@"random-permanence-%lu", cases]);
        CFErrorRef error = NULL;
        SecKeyRef random = Random(request, &error);
        CHECK(random && error == NULL);
        BOOL persistRandom = v ? v.boolValue : (s ? s.boolValue : NO);
        CHECK(Items() == (NSUInteger)persistRandom);
        if (persistRandom) {
            SecKeyRef key = Lookup(PrivateTag(@"matrix"), kSecAttrKeyClassPrivate);
            CHECK([Export(key) isEqual:Export(random)]);
            CFRelease(key);
        } else Missing(PrivateTag(@"matrix"), kSecAttrKeyClassPrivate);
        Missing(PublicTag(@"matrix"), kSecAttrKeyClassPublic);
        CFRelease(random);
        ++cases;
    }
    CHECK(cases == 27);
    puts("PASS 27 pair + 27 RandomKey permanence/override cases");
}

static void TestOutputsAndReentry(void) {
    for (NSUInteger mask = 0; mask < 4; ++mask) {
        SelectStore([NSString stringWithFormat:@"optional-outputs-%lu", mask]);
        NSDictionary *request = Request(@"optional", 1024, @YES, nil, nil);
        Pair pair;
        gExpectedRequest = Snapshot(request);
        CHECK(PearSecKeyGeneratePair((__bridge CFDictionaryRef)request,
              mask & 1 ? &pair.pub : NULL, mask & 2 ? &pair.priv : NULL) == errSecSuccess);
        CHECK(Items() == 2);
        SecKeyRef pub = Lookup(PublicTag(@"optional"), kSecAttrKeyClassPublic);
        SecKeyRef priv = Lookup(PrivateTag(@"optional"), kSecAttrKeyClassPrivate);
        SignVerify(pub, priv);
        CFRelease(pub); CFRelease(priv);
    }
    SelectStore(@"reentry");
    gReenterRandom = YES;
    Pair pair;
    CHECK(Generate(Request(@"reentry", 1024, @YES, @YES, @YES), pair) == errSecSuccess);
    gReenterRandom = NO;
    CHECK(gReentrantItems == 0 && Items() == 2);
    SignVerify(pair.pub, pair.priv);
    puts("PASS nullable outputs and nested RandomKey call without double persistence");
}

static void TestClassesAndUntagged(void) {
    SelectStore(@"class");
    Pair pair;
    CHECK(Generate(Request(@"class", 1024, @NO, nil, nil), pair) == errSecSuccess);
    NSMutableDictionary *wrong = Request(@"class", 1024, @YES, nil, nil);
    wrong[(__bridge id)kSecAttrKeyClass] = (__bridge id)kSecAttrKeyClassPrivate;
    wrong[(__bridge id)kSecPublicKeyAttrs][(__bridge id)kSecAttrKeyClass] = (__bridge id)kSecAttrKeyClassPrivate;
    StoreSecKey(pair.pub, wrong, kSecAttrKeyClassPublic);
    SecKeyRef pub = Lookup(PublicTag(@"class"), kSecAttrKeyClassPublic);
    CHECK([Export(pub) isEqual:Export(pair.pub)]);
    CFRelease(pub);
    NSDictionary *add = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassKey,
        (__bridge id)kSecAttrApplicationTag: Tag(@"value-ref-private"),
        (__bridge id)kSecValueRef: (__bridge id)pair.priv,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
    };
    CHECK(PearSecItemAdd((__bridge CFDictionaryRef)add, NULL) == errSecSuccess);
    SecKeyRef priv = Lookup(@"value-ref-private", kSecAttrKeyClassPrivate);
    SignVerify(pair.pub, priv);
    CFRelease(priv);
    SelectStore(@"untagged");
    NSDictionary *untagged = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeySizeInBits: @1024,
    };
    Pair first, second;
    CHECK(Generate(untagged, first) == errSecSuccess);
    CHECK(Generate(untagged, second) == errSecSuccess);
    CHECK(Items() == 4);
    StoreSecKey(first.pub, untagged, kSecAttrKeyClassPublic);
    CHECK(Items() == 4);
    puts("PASS actual public/private key classes; independent untagged keys");
}

static void TestFailures(void) {
    SelectStore(@"failures");
    NSDictionary *request = Request(@"failure", 1024, @YES, @YES, @YES);
    gPairFailure = errSecMissingEntitlement;
    Pair failed;
    CHECK(Generate(request, failed) == errSecMissingEntitlement);
    CHECK(!failed.pub && !failed.priv && Items() == 0);
    gPairFailure = errSecSuccess;
    gRandomFailure = CFErrorCreate(NULL, CFSTR("keychain-smoke-error"), -1234, NULL);
    CFErrorRef error = NULL;
    CHECK(Random(request, &error) == NULL);
    CHECK(error == gRandomFailure && CFErrorGetCode(error) == -1234 && Items() == 0);
    CFRelease(error);
    CHECK(Random(request, NULL) == NULL);
    CFRelease(gRandomFailure); gRandomFailure = NULL;

    NSMutableDictionary *invalid = [request mutableCopy];
    invalid[(__bridge id)kSecAttrKeySizeInBits] = @(-1);
    Pair invalidPair;
    OSStatus status = Generate(invalid, invalidPair);
    CHECK(status != errSecSuccess && status == gNativeStatus && Items() == 0);
    error = NULL;
    CHECK(Random(invalid, &error) == NULL);
    CHECK(error && error == gNativeError && Items() == 0);
    printf("PASS real invalid RSA size -1 errors: pair=%d random=%ld\n", (int)status, CFErrorGetCode(error));
    CFRelease(error);

    // Invalid nested values are passed through to the generator, not silently
    // changed into valid dictionaries or made into successful generations.
    invalid[(__bridge id)kSecPublicKeyAttrs] = @"invalid-public-attributes";
    gPairFailure = errSecParam;
    CHECK(Generate(invalid, invalidPair) == errSecParam && Items() == 0);
    gPairFailure = errSecSuccess;
    Pair saved;
    CHECK(Generate(request, saved) == errSecSuccess);
    gPairFailure = errSecParam;
    Pair replacement;
    CHECK(Generate(request, replacement) == errSecParam && Items() == 2);
    gPairFailure = errSecSuccess;
    SecKeyRef stored = Lookup(PublicTag(@"failure"), kSecAttrKeyClassPublic);
    CHECK([Export(stored) isEqual:Export(saved.pub)]);
    CFRelease(stored);
    puts("PASS injected errors, original CFError identity, and no persistence on failure");
}

static void SavePublic(NSString *name, SecKeyRef key) {
    CHECK([Export(key) writeToFile:[Root() stringByAppendingPathComponent:name] atomically:YES]);
}
static void ExpectedPublic(NSString *name, SecKeyRef key) {
    NSData *expected = [NSData dataWithContentsOfFile:[Root() stringByAppendingPathComponent:name]];
    CHECK(expected && [Export(key) isEqual:expected]);
}
static void WritePersistent(void) {
    SelectStore(@"persistent");
    Pair first, second, replacement;
    NSDictionary *a = Request(@"pair-a", 2048, nil, @YES, @YES);
    CHECK(Generate(a, first) == errSecSuccess);
    CHECK(Generate(Request(@"pair-b", 2048, @YES, nil, nil), second) == errSecSuccess);
    CHECK(Items() == 4 && ![Export(first.pub) isEqual:Export(second.pub)]);

    // Seed the older byte-dependent identifier form. Regeneration must retire
    // that alias without affecting another pair or leaving stale query matches.
    NSMutableDictionary *legacy = nil;
    for (NSDictionary *item in LoadAll()) {
        if (Matches(item, Query(PublicTag(@"pair-a"), kSecAttrKeyClassPublic))) {
            legacy = [item mutableCopy];
            break;
        }
    }
    CHECK(legacy != nil);
    legacy[@"__id"] = @"synthetic-old-byte-dependent-identifier";
    SaveItem(legacy);
    CHECK(Items() == 5);
    NSMutableDictionary *updated = Request(@"pair-a", 2048, @YES, @YES, @YES);
    updated[(__bridge id)kSecPublicKeyAttrs][(__bridge id)kSecAttrLabel] = @"updated-public-label";
    updated[(__bridge id)kSecPrivateKeyAttrs][(__bridge id)kSecAttrLabel] = @"updated-private-label";
    CHECK(Generate(updated, replacement) == errSecSuccess);
    CHECK(Items() == 4 && ![Export(first.pub) isEqual:Export(replacement.pub)]);
    SecKeyRef restored = Lookup(PublicTag(@"pair-a"), kSecAttrKeyClassPublic, 2048);
    CHECK([Export(restored) isEqual:Export(replacement.pub)]);
    CFRelease(restored);

    // Explicitly transient generations must not replace an existing tagged key.
    Pair transient;
    CHECK(Generate(Request(@"pair-a", 2048, @NO, nil, nil), transient) == errSecSuccess);
    SignVerify(transient.pub, transient.priv);
    CHECK(Items() == 4);
    restored = Lookup(PublicTag(@"pair-a"), kSecAttrKeyClassPublic, 2048);
    CHECK([Export(restored) isEqual:Export(replacement.pub)]);
    CFRelease(restored);
    CFErrorRef error = NULL;
    SecKeyRef randomTransient = Random(Request(@"pair-a", 2048, @YES, nil, @NO), &error);
    CHECK(randomTransient && error == NULL && Items() == 4);
    CFRelease(randomTransient);
    SecKeyRef random = Random(Request(@"random-c", 2048, nil, nil, @YES), &error);
    CHECK(random && error == NULL && Items() == 5);
    SecKeyRef randomPub = SecKeyCopyPublicKey(random);
    SavePublic(@"pair-a-public.der", replacement.pub);
    SavePublic(@"pair-b-public.der", second.pub);
    SavePublic(@"random-c-public.der", randomPub);
    SignVerify(replacement.pub, replacement.priv);
    SignVerify(second.pub, second.priv);
    SignVerify(randomPub, random);
    CFRelease(randomPub); CFRelease(random);
    puts("PASS independent pairs, tagged regeneration/upsert, legacy alias cleanup, transient non-replacement");
}
static void ReadPersistent(void) {
    SelectStore(@"persistent");
    CHECK(gPairCalls == 0 && gRandomCalls == 0 && Items() == 5);
    SecKeyRef aPub = Lookup(PublicTag(@"pair-a"), kSecAttrKeyClassPublic, 2048);
    SecKeyRef aPriv = Lookup(PrivateTag(@"pair-a"), kSecAttrKeyClassPrivate, 2048);
    SecKeyRef bPub = Lookup(PublicTag(@"pair-b"), kSecAttrKeyClassPublic, 2048);
    SecKeyRef bPriv = Lookup(PrivateTag(@"pair-b"), kSecAttrKeyClassPrivate, 2048);
    SecKeyRef random = Lookup(PrivateTag(@"random-c"), kSecAttrKeyClassPrivate, 2048);
    SecKeyRef randomPub = SecKeyCopyPublicKey(random);
    ExpectedPublic(@"pair-a-public.der", aPub);
    ExpectedPublic(@"pair-b-public.der", bPub);
    ExpectedPublic(@"random-c-public.der", randomPub);
    SignVerify(aPub, aPriv); SignVerify(bPub, bPriv); SignVerify(randomPub, random);
    Verify(bPub, Signature(aPriv), NO);
    Metadata(PublicTag(@"pair-a"), kSecAttrKeyClassPublic, @"updated-public-label", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
    Metadata(PrivateTag(@"pair-a"), kSecAttrKeyClassPrivate, @"updated-private-label", kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
    CFRelease(aPub); CFRelease(aPriv); CFRelease(bPub); CFRelease(bPriv);
    CFRelease(randomPub); CFRelease(random);
    puts("PASS fresh-process per-tag reload, metadata, signing and cross-pair rejection");
}
static int RSA512(BOOL reading) {
    SelectStore(@"rsa512");
    if (!reading) {
        Pair pair;
        OSStatus status = Generate(Request(@"rsa512", 512, nil, @YES, @YES), pair);
        printf("RSA 512 generation actual status: %d\n", (int)status);
        if (status != errSecSuccess) {
            CHECK(status == gNativeStatus && !pair.pub && !pair.priv && Items() == 0);
            puts("PASS platform RSA 512 rejection propagated unchanged; no substitute key size");
            return 77;
        }
        KeyClass(pair.pub, kSecAttrKeyClassPublic, 512);
        KeyClass(pair.priv, kSecAttrKeyClassPrivate, 512);
        SignVerify(pair.pub, pair.priv);
        SavePublic(@"rsa512-public.der", pair.pub);
    } else {
        CHECK(gPairCalls == 0 && gRandomCalls == 0 && Items() == 2);
        SecKeyRef pub = Lookup(PublicTag(@"rsa512"), kSecAttrKeyClassPublic, 512);
        SecKeyRef priv = Lookup(PrivateTag(@"rsa512"), kSecAttrKeyClassPrivate, 512);
        ExpectedPublic(@"rsa512-public.der", pub);
        SignVerify(pub, priv);
        CFRelease(pub); CFRelease(priv);
    }
    puts(reading ? "PASS fresh-process RSA 512 reload/sign/verify" : "PASS unchanged RSA 512 generation/sign/verify");
    return 0;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        CHECK(argc == 2);
        // The runner supplies all paths; refuse to fall back to any user store.
        CHECK(getenv("PEAR_KEYCHAIN_DIR") && getenv("PEAR_SUPPORT_ROOT") && getenv("PEAR_LOG_FILE"));
        Root();
        if (!strcmp(argv[1], "unit")) {
            TestSanitizer(); TestPermanence(); TestOutputsAndReentry(); TestClassesAndUntagged(); TestFailures();
        } else if (!strcmp(argv[1], "write")) WritePersistent();
        else if (!strcmp(argv[1], "read")) ReadPersistent();
        else if (!strcmp(argv[1], "rsa512")) return RSA512(NO);
        else if (!strcmp(argv[1], "read512")) return RSA512(YES);
        else CHECK(false);
    }
    return 0;
}
#endif
