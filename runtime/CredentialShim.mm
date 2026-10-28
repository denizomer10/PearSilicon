// CredentialShim.mm
//
// Prevents a null client identity from reaching CFNetwork's credential
// constructor.
//
// During a TLS client-certificate challenge, an app can call
// `NSURLCredential` with a null identity when it has no certificate. The
// platform's implementation compares that identity with CFEqual and traps.
// The documented factory returns nil for an unusable credential, so this shim
// restores that behaviour for both the class factory and the initializer.
//
// This is an API-shape compatibility fix; it does not alter certificate
// validation, trust decisions, or the app's networking logic.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import "PearRuntime.h"

typedef NSURLCredential *(*PearCredentialFactoryFn)(id, SEL, SecIdentityRef,
                                                    NSArray *, NSURLCredentialPersistence);
typedef id (*PearCredentialInitFn)(id, SEL, SecIdentityRef,
                                   NSArray *, NSURLCredentialPersistence);

static PearCredentialFactoryFn gOriginalFactory;
static PearCredentialInitFn gOriginalInit;

/// CFNetwork compares the identity and every certificate with CFEqual. A
/// bridged CFArray from an app can contain a NULL entry (NSArray itself cannot,
/// but the app may build the array with a NULL callback); that reaches
/// CFEqual(NULL) and traps. Drop empty entries before handing the array over.
static NSArray *PearSanitizedCertificates(NSArray *certificates) {
    if (!certificates) return nil;
    CFArrayRef array = (__bridge CFArrayRef)certificates;
    if (CFGetTypeID(array) != CFArrayGetTypeID()) return nil;

    CFIndex count = CFArrayGetCount(array);
    if (count == 0) return nil;

    CFMutableArrayRef filtered = CFArrayCreateMutable(kCFAllocatorDefault, count,
                                                       &kCFTypeArrayCallBacks);
    if (!filtered) return nil;
    for (CFIndex index = 0; index < count; index++) {
        const void *item = CFArrayGetValueAtIndex(array, index);
        if (item) CFArrayAppendValue(filtered, item);
    }
    NSArray *result = (__bridge_transfer NSArray *)filtered;
    return result.count > 0 ? result : nil;
}

/// A non-NULL pointer is not necessarily a valid identity. Asking Security to
/// copy its certificate rejects an uninitialised value before CFNetwork sees
/// it; a real identity keeps its normal validation and trust path.
static BOOL PearIdentityIsUsable(SecIdentityRef identity) {
    if (!identity) return NO;
    SecCertificateRef certificate = NULL;
    OSStatus status = SecIdentityCopyCertificate(identity, &certificate);
    if (certificate) CFRelease(certificate);
    return status == errSecSuccess && certificate != NULL;
}

static NSURLCredential *PearCredentialWithIdentity(id self, SEL _cmd,
                                                   SecIdentityRef identity,
                                                   NSArray *certificates,
                                                   NSURLCredentialPersistence persistence) {
    if (!PearIdentityIsUsable(identity)) {
        PearLog(@"[PearRuntime][credential] ignoring a credential with no usable identity");
        return nil;
    }
    NSArray *safeCertificates = PearSanitizedCertificates(certificates);
    return gOriginalFactory
        ? gOriginalFactory(self, _cmd, identity, safeCertificates, persistence)
        : nil;
}

static id PearCredentialInitWithIdentity(id self, SEL _cmd,
                                         SecIdentityRef identity,
                                         NSArray *certificates,
                                         NSURLCredentialPersistence persistence) {
    if (!PearIdentityIsUsable(identity)) {
        PearLog(@"[PearRuntime][credential] refusing to initialize a credential with no usable identity");
        return nil;
    }
    NSArray *safeCertificates = PearSanitizedCertificates(certificates);
    return gOriginalInit
        ? gOriginalInit(self, _cmd, identity, safeCertificates, persistence)
        : nil;
}

static void PearInstallCredentialGuard(void) {
    Class cls = NSClassFromString(@"NSURLCredential");
    if (!cls) return;

    SEL factorySelector = @selector(credentialWithIdentity:certificates:persistence:);
    Method factory = class_getClassMethod(cls, factorySelector);
    if (factory) {
        gOriginalFactory = (PearCredentialFactoryFn)method_getImplementation(factory);
        method_setImplementation(factory, (IMP)PearCredentialWithIdentity);
    }

    SEL initSelector = @selector(initWithIdentity:certificates:persistence:);
    Method init = class_getInstanceMethod(cls, initSelector);
    if (init) {
        gOriginalInit = (PearCredentialInitFn)method_getImplementation(init);
        method_setImplementation(init, (IMP)PearCredentialInitWithIdentity);
    }
}

__attribute__((constructor))
static void PearCredentialShimInit(void) {
    if (getenv("PEAR_NO_CREDENTIAL_SHIM")) return;
    @autoreleasepool {
        PearInstallCredentialGuard();
    }
}
