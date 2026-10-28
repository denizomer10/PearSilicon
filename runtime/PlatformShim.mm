// PlatformShim.mm
//
// Local answers for iOS platform services that cannot work in a sideloaded
// Catalyst process. These surfaces do not simulate a purchase, a biometric
// success, an attestation, or health data; they report the documented
// "unavailable" state so an app can take its fallback path instead of waiting
// for a callback that never arrives.
//
// No iCloud, CloudKit or Apple sign-in integration is added here.
//
// Disable with PEAR_NO_PLATFORM=1 (or PEAR_NO_SERVICES=1). Set
// PEAR_DEBUG_SERVICES=1 for one log line per installed surface.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "PearRuntime.h"

static BOOL PearPlatformDisabled(void) {
    const char *platform = getenv("PEAR_NO_PLATFORM");
    if (platform && platform[0] && strcmp(platform, "0") != 0) return YES;
    const char *services = getenv("PEAR_NO_SERVICES");
    return services && services[0] && strcmp(services, "0") != 0;
}

static BOOL PearPlatformDebug(void) {
    const char *value = getenv("PEAR_DEBUG_SERVICES");
    return value && value[0] && strcmp(value, "0") != 0;
}

#define PEAR_PLATFORM_LOG_ONCE(message) do { \
    static BOOL _pearPlatformLogged = NO; \
    if (!_pearPlatformLogged && PearPlatformDebug()) { \
        _pearPlatformLogged = YES; \
        PearLog(message); \
    } \
} while (0)

static NSError *PearUnavailableError(NSString *domain, NSString *message) {
    return [NSError errorWithDomain:domain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// Adds the override to `cls` itself when the implementation is inherited, so
/// replacing an inherited method does not affect unrelated subclasses.
static void PearReplaceInstance(Class cls, SEL selector, id block) {
    if (!cls || !selector) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP imp = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, selector, imp, method_getTypeEncoding(method))) {
        method_setImplementation(method, imp);
    }
}

static void PearReplaceClass(Class cls, SEL selector, id block) {
    if (!cls || !selector) return;
    Method method = class_getClassMethod(cls, selector);
    if (!method) return;
    IMP imp = imp_implementationWithBlock(block);
    if (!class_addMethod(object_getClass(cls), selector, imp, method_getTypeEncoding(method))) {
        method_setImplementation(method, imp);
    }
}

static id PearObject(id object, SEL selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

#pragma mark - StoreKit

@protocol PearSKRequestDelegate <NSObject>
@optional
- (void)request:(id)request didFailWithError:(NSError *)error;
- (void)productsRequest:(id)request didReceiveResponse:(id)response;
@end

/// A product query has no local catalog. A real store with no matching
/// products answers with an empty response; reporting that instead of a
/// transient error keeps IAP initialization from retrying forever. No product
/// or price is fabricated.
static Class PearEmptyProductsResponseClass(void) {
    static Class responseClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = objc_getClass("SKProductsResponse");
        if (!base) return;
        Class subclass = objc_allocateClassPair(base, "PearEmptySKProductsResponse", 0);
        if (!subclass) return;
        class_addMethod(subclass, @selector(products),
                        imp_implementationWithBlock(^NSArray *(id self) { return @[]; }), "@@:");
        class_addMethod(subclass, @selector(invalidProductIdentifiers),
                        imp_implementationWithBlock(^NSArray *(id self) { return @[]; }), "@@:");
        objc_registerClassPair(subclass);
        responseClass = subclass;
    });
    return responseClass;
}

static void PearInstallStoreRequests(void) {
    Class request = objc_getClass("SKProductsRequest");
    if (!request) return;

    PearReplaceInstance(request, @selector(start), ^(id self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            id<PearSKRequestDelegate> delegate =
                (id<PearSKRequestDelegate>)PearObject(self, @selector(delegate));

            if ([delegate respondsToSelector:@selector(productsRequest:didReceiveResponse:)]) {
                Class responseClass = PearEmptyProductsResponseClass();
                if (responseClass) {
                    [delegate productsRequest:self didReceiveResponse:[[responseClass alloc] init]];
                    return;
                }
            }

            if (![delegate respondsToSelector:@selector(request:didFailWithError:)]) return;
            NSError *error = PearUnavailableError(
                @"PearSiliconStore",
                @"The App Store is unavailable in this environment."
            );
            [delegate request:self didFailWithError:error];
        });
    });

    PEAR_PLATFORM_LOG_ONCE(@"[PearRuntime][platform] StoreKit product requests report an empty catalog");
}

#pragma mark - Local authentication

/// Biometrics are a security boundary. This shim never reports success; it
/// reports that the policy cannot be evaluated so apps fall back to their
/// non-biometric path.
static void PearInstallLocalAuthentication(void) {
    Class context = objc_getClass("LAContext");
    if (!context) return;

    PearReplaceInstance(context, @selector(canEvaluatePolicy:error:),
        ^BOOL(id self, NSInteger policy, NSError **error) {
            if (error) {
                *error = PearUnavailableError(
                    @"com.apple.LocalAuthentication",
                    @"Biometric authentication is unavailable in this environment."
                );
            }
            return NO;
        });

    PearReplaceInstance(context, @selector(evaluatePolicy:localizedReason:reply:),
        ^(id self, NSInteger policy, NSString *reason, void (^reply)(BOOL, NSError *)) {
            if (!reply) return;
            NSError *error = PearUnavailableError(
                @"com.apple.LocalAuthentication",
                @"Biometric authentication is unavailable in this environment."
            );
            dispatch_async(dispatch_get_main_queue(), ^{ reply(NO, error); });
        });

    PearReplaceInstance(context, @selector(biometryType), ^NSInteger(id self) {
        return 0;
    });

    PEAR_PLATFORM_LOG_ONCE(@"[PearRuntime][platform] LocalAuthentication reports unavailable");
}

#pragma mark - CoreTelephony

/// A Mac has no cellular carrier. Returning nil/empty values is the same
/// contract a Wi-Fi-only device satisfies.
static void PearInstallTelephony(void) {
    Class networkInfo = objc_getClass("CTTelephonyNetworkInfo");
    if (!networkInfo) return;

    PearReplaceInstance(networkInfo, @selector(subscriberCellularProvider), ^id(id self) {
        return nil;
    });
    PearReplaceInstance(networkInfo, @selector(serviceSubscriberCellularProviders), ^id(id self) {
        return @{};
    });
    PearReplaceInstance(networkInfo, @selector(currentRadioAccessTechnology), ^id(id self) {
        return nil;
    });
    PearReplaceInstance(networkInfo, @selector(serviceCurrentRadioAccessTechnology), ^id(id self) {
        return @{};
    });

    PEAR_PLATFORM_LOG_ONCE(@"[PearRuntime][platform] cellular carrier reports unavailable");
}

#pragma mark - PassKit

/// Wallet and Apple Pay need a signed merchant session and a real payment
/// sheet. Both are reported unavailable; no payment is ever simulated.
static void PearInstallPassKit(void) {
    Class authorization = objc_getClass("PKPaymentAuthorizationViewController");
    if (authorization) {
        PearReplaceClass(authorization, @selector(canMakePayments), ^BOOL(id self) {
            return NO;
        });
        PearReplaceClass(authorization, @selector(canMakePaymentsUsingNetworks:),
            ^BOOL(id self, NSArray *networks) {
                return NO;
            });
        PearReplaceClass(authorization, @selector(canMakePaymentsUsingNetworks:capabilities:),
            ^BOOL(id self, NSArray *networks, NSUInteger capabilities) {
                return NO;
            });
    }

    Class controller = objc_getClass("PKPaymentAuthorizationController");
    if (controller) {
        PearReplaceClass(controller, @selector(canMakePayments), ^BOOL(id self) {
            return NO;
        });
        PearReplaceClass(controller, @selector(canMakePaymentsUsingNetworks:),
            ^BOOL(id self, NSArray *networks) {
                return NO;
            });
    }

    Class passLibrary = objc_getClass("PKPassLibrary");
    if (passLibrary) {
        PearReplaceClass(passLibrary, @selector(isPassLibraryAvailable), ^BOOL(id self) {
            return NO;
        });
    }

    PEAR_PLATFORM_LOG_ONCE(@"[PearRuntime][platform] Wallet and Apple Pay report unavailable");
}

#pragma mark - NFC

static void PearInstallNFC(void) {
    Class ndef = objc_getClass("NFCNDEFReaderSession");
    if (ndef) {
        PearReplaceClass(ndef, @selector(readingAvailable), ^BOOL(id self) {
            return NO;
        });
    }

    Class tag = objc_getClass("NFCTagReaderSession");
    if (tag) {
        PearReplaceClass(tag, @selector(readingAvailable), ^BOOL(id self) {
            return NO;
        });
    }

    if (ndef || tag) {
        PEAR_PLATFORM_LOG_ONCE(@"[PearRuntime][platform] NFC reports unavailable");
    }
}

#pragma mark - DeviceCheck and App Attest

/// Attestation proves hardware integrity. It is never fabricated here; the
/// service reports unsupported and its callbacks receive a clear error.
static void PearInstallDeviceCheck(void) {
    Class device = objc_getClass("DCDevice");
    if (device) {
        PearReplaceInstance(device, @selector(isSupported), ^BOOL(id self) {
            return NO;
        });
        PearReplaceInstance(device, @selector(generateTokenWithCompletionHandler:),
            ^(id self, void (^done)(NSData *, NSError *)) {
                if (!done) return;
                NSError *error = PearUnavailableError(
                    @"PearSiliconDeviceCheck",
                    @"Device attestation is unavailable in this environment."
                );
                dispatch_async(dispatch_get_main_queue(), ^{ done(nil, error); });
            });
    }

    Class attest = objc_getClass("DCAppAttestService");
    if (attest) {
        PearReplaceInstance(attest, @selector(isSupported), ^BOOL(id self) {
            return NO;
        });
        PearReplaceInstance(attest, @selector(generateKeyWithCompletionHandler:),
            ^(id self, void (^done)(NSString *, NSError *)) {
                if (!done) return;
                NSError *error = PearUnavailableError(
                    @"PearSiliconAppAttest",
                    @"App Attest is unavailable in this environment."
                );
                dispatch_async(dispatch_get_main_queue(), ^{ done(nil, error); });
            });
        PearReplaceInstance(attest, @selector(attestKey:clientDataHash:completionHandler:),
            ^(id self, NSString *keyID, NSData *hash, void (^done)(NSData *, NSError *)) {
                if (!done) return;
                NSError *error = PearUnavailableError(
                    @"PearSiliconAppAttest",
                    @"App Attest is unavailable in this environment."
                );
                dispatch_async(dispatch_get_main_queue(), ^{ done(nil, error); });
            });
        PearReplaceInstance(attest, @selector(generateAssertion:clientDataHash:completionHandler:),
            ^(id self, NSString *keyID, NSData *hash, void (^done)(NSData *, NSError *)) {
                if (!done) return;
                NSError *error = PearUnavailableError(
                    @"PearSiliconAppAttest",
                    @"App Attest is unavailable in this environment."
                );
                dispatch_async(dispatch_get_main_queue(), ^{ done(nil, error); });
            });
    }

    if (device || attest) {
        PEAR_PLATFORM_LOG_ONCE(@"[PearRuntime][platform] DeviceCheck and App Attest report unavailable");
    }
}

#pragma mark - HealthKit

static void PearInstallHealthKit(void) {
    Class store = objc_getClass("HKHealthStore");
    if (!store) return;

    PearReplaceClass(store, @selector(isHealthDataAvailable), ^BOOL(id self) {
        return NO;
    });

    PEAR_PLATFORM_LOG_ONCE(@"[PearRuntime][platform] HealthKit reports unavailable");
}

#pragma mark - MarketplaceKit

/// The Catalyst SDK advertises `MarketplaceKit` at an absolute path, but the
/// framework actually lives in the iOSSupport tree and carries no binary.
/// The installer puts a compatibility stub in the app's own Frameworks
/// directory; loading it into the global namespace before an app's Swift
/// metadata is resolved keeps weak references to its types from turning into
/// a fatal demangling error.
static void PearLoadMarketplaceKit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bundlePath = [NSBundle mainBundle].bundlePath;
        NSString *local = [bundlePath stringByAppendingPathComponent:
            @"Frameworks/MarketplaceKit.framework/MarketplaceKit"];
        const char *path = local.fileSystemRepresentation;
        void *handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
        if (handle) {
            PearLog(@"[PearRuntime][platform] loaded MarketplaceKit from the app bundle");
            return;
        }

        path = "/System/iOSSupport/System/Library/Frameworks/MarketplaceKit.framework/MarketplaceKit";
        handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
        if (handle) {
            PearLog(@"[PearRuntime][platform] loaded MarketplaceKit from iOSSupport");
        } else {
            const char *error = dlerror();
            PearLog(@"[PearRuntime][platform] MarketplaceKit unavailable: %s",
                    error ?: "unknown");
        }
    });
}

#pragma mark - Install

static void PearInstallPlatformShims(void) {
    PearLoadMarketplaceKit();
    PearInstallStoreRequests();
    PearInstallLocalAuthentication();
    PearInstallTelephony();
    PearInstallPassKit();
    PearInstallNFC();
    PearInstallDeviceCheck();
    PearInstallHealthKit();
}

__attribute__((constructor))
static void PearPlatformShimInit(void) {
    if (PearPlatformDisabled()) return;
    @autoreleasepool {
        PearInstallPlatformShims();
    }

    // These frameworks are often loaded lazily. Re-run the installer so a
    // late-loaded StoreKit, Wallet, NFC or HealthKit class still gets its
    // local surface before the app calls it.
    for (int i = 1; i <= 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                PearInstallPlatformShims();
            }
        });
    }
}
