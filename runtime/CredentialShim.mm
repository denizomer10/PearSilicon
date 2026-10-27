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

static NSURLCredential *PearCredentialWithIdentity(id self, SEL _cmd,
                                                   SecIdentityRef identity,
                                                   NSArray *certificates,
                                                   NSURLCredentialPersistence persistence) {
    if (!identity) {
        PearLog(@"[PearRuntime][credential] ignoring a credential with no identity");
        return nil;
    }
    return gOriginalFactory ? gOriginalFactory(self, _cmd, identity, certificates, persistence) : nil;
}

static id PearCredentialInitWithIdentity(id self, SEL _cmd,
                                         SecIdentityRef identity,
                                         NSArray *certificates,
                                         NSURLCredentialPersistence persistence) {
    if (!identity) {
        PearLog(@"[PearRuntime][credential] refusing to initialize a credential with no identity");
        return nil;
    }
    return gOriginalInit ? gOriginalInit(self, _cmd, identity, certificates, persistence) : nil;
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
