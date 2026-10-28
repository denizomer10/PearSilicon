// ServicesShim.mm
//
// Local answers for platform services that Mac Catalyst apps use during
// startup but that have no working host equivalent in a sideloaded app.
//
// The shim never simulates a purchase, a receipt, or a remote notification
// token. It accepts audio-session configuration, makes haptics and review
// prompts inert, reports remote notifications as unavailable, reports ARKit as
// unsupported, and gives background tasks a long-lived local identifier.
//
// Disable with PEAR_NO_SERVICES=1. Set PEAR_DEBUG_SERVICES=1 for a log line per
// installed surface.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "PearRuntime.h"

static BOOL PearServicesDisabled(void) {
    const char *value = getenv("PEAR_NO_SERVICES");
    return value && value[0] && strcmp(value, "0") != 0;
}

static BOOL PearServicesDebug(void) {
    const char *value = getenv("PEAR_DEBUG_SERVICES");
    return value && value[0] && strcmp(value, "0") != 0;
}

/// Logs once per surface even when the installer runs again for a framework
/// that loaded after the first pass.
#define PEAR_SERVICES_LOG_ONCE(message) do { \
    static BOOL _pearServiceLogged = NO; \
    if (!_pearServiceLogged && PearServicesDebug()) { \
        _pearServiceLogged = YES; \
        PearLog(message); \
    } \
} while (0)

static void PearReplaceInstance(Class cls, SEL selector, id block) {
    if (!cls || !selector) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (method) method_setImplementation(method, imp_implementationWithBlock(block));
}

static void PearReplaceClass(Class cls, SEL selector, id block) {
    if (!cls || !selector) return;
    Method method = class_getClassMethod(cls, selector);
    if (method) method_setImplementation(method, imp_implementationWithBlock(block));
}

#pragma mark - Audio session

static BOOL PearAudioSucceeded(NSError **error) {
    if (error) *error = nil;
    return YES;
}

/// Catalyst apps configure an audio session before starting playback. On a Mac
/// the host audio system already routes the process, so the configuration is
/// accepted instead of failing with a platform error.
static void PearInstallAudioSession(void) {
    Class session = objc_getClass("AVAudioSession");
    if (!session) return;

    PearReplaceInstance(session, @selector(setCategory:error:),
        ^BOOL(id self, NSString *category, NSError **error) {
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setCategory:withOptions:error:),
        ^BOOL(id self, NSString *category, NSUInteger options, NSError **error) {
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setCategory:mode:options:error:),
        ^BOOL(id self, NSString *category, NSString *mode, NSUInteger options, NSError **error) {
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setMode:error:),
        ^BOOL(id self, NSString *mode, NSError **error) {
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setActive:error:),
        ^BOOL(id self, BOOL active, NSError **error) {
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setActive:withOptions:error:),
        ^BOOL(id self, BOOL active, NSUInteger options, NSError **error) {
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setPreferredSampleRate:error:),
        ^BOOL(id self, double rate, NSError **error) {
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setPreferredIOBufferDuration:error:),
        ^BOOL(id self, double duration, NSError **error) {
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setPreferredInputNumberOfChannels:error:),
        ^BOOL(id self, NSInteger count, NSError **error) {
            return PearAudioSucceeded(error);
        });

    PearReplaceInstance(session, @selector(category), ^NSString *(id self) {
        return @"AVAudioSessionCategoryAmbient";
    });
    PearReplaceInstance(session, @selector(mode), ^NSString *(id self) {
        return @"AVAudioSessionModeDefault";
    });
    PearReplaceInstance(session, @selector(sampleRate), ^double(id self) {
        return 48000.0;
    });
    PearReplaceInstance(session, @selector(IOBufferDuration), ^double(id self) {
        return 0.005;
    });
    PearReplaceInstance(session, @selector(inputNumberOfChannels), ^NSInteger(id self) {
        return 2;
    });
    PearReplaceInstance(session, @selector(outputNumberOfChannels), ^NSInteger(id self) {
        return 2;
    });

    PEAR_SERVICES_LOG_ONCE(@"[PearRuntime][services] audio session configuration accepted");
}

#pragma mark - Haptics

/// Haptics are a no-op: there is no phone taptic engine to drive, and leaving
/// the generators enabled can make some engines wait for a completion that
/// never arrives.
static void PearInstallHaptics(void) {
    Class impact = objc_getClass("UIImpactFeedbackGenerator");
    if (impact) {
        PearReplaceInstance(impact, @selector(prepare), ^(id self) {});
        PearReplaceInstance(impact, @selector(impactOccurred), ^(id self) {});
        PearReplaceInstance(impact, @selector(impactOccurredWithIntensity:),
            ^(id self, double intensity) {});
    }

    Class notification = objc_getClass("UINotificationFeedbackGenerator");
    if (notification) {
        PearReplaceInstance(notification, @selector(prepare), ^(id self) {});
        PearReplaceInstance(notification, @selector(notificationOccurred:),
            ^(id self, NSInteger type) {});
    }

    Class selection = objc_getClass("UISelectionFeedbackGenerator");
    if (selection) {
        PearReplaceInstance(selection, @selector(prepare), ^(id self) {});
        PearReplaceInstance(selection, @selector(selectionChanged), ^(id self) {});
    }

    Class base = objc_getClass("UIFeedbackGenerator");
    if (base) {
        PearReplaceInstance(base, @selector(prepare), ^(id self) {});
    }

    PEAR_SERVICES_LOG_ONCE(@"[PearRuntime][services] haptics disabled");
}

#pragma mark - Store surface

/// The review prompt is cosmetic; showing it has no host equivalent.
/// Payments are deliberately not simulated: canMakePayments reports NO and no
/// transaction is ever completed.
static void PearInstallStoreSurface(void) {
    Class review = objc_getClass("SKStoreReviewController");
    if (review) {
        PearReplaceClass(review, @selector(requestReview), ^(id self) {});
        PearReplaceClass(review, @selector(requestReviewInScene:), ^(id self, id scene) {});
    }

    Class queue = objc_getClass("SKPaymentQueue");
    if (queue) {
        PearReplaceClass(queue, @selector(canMakePayments), ^BOOL(id self) {
            return NO;
        });
    }

    PEAR_SERVICES_LOG_ONCE(@"[PearRuntime][services] store surface reports unavailable");
}

#pragma mark - Remote notifications

static void PearReportRemoteNotificationFailure(UIApplication *application) {
    id<UIApplicationDelegate> delegate = application.delegate;
    SEL selector = @selector(application:didFailToRegisterForRemoteNotificationsWithError:);
    if (![delegate respondsToSelector:selector]) return;

    NSError *error = [NSError errorWithDomain:@"PearSiliconRemoteNotifications"
                                          code:1
                                      userInfo:@{
        NSLocalizedDescriptionKey: @"Remote notifications are unavailable in this environment."
    }];
    [delegate application:application didFailToRegisterForRemoteNotificationsWithError:error];
}

/// A sideloaded app has no APNs environment, so report the documented failure
/// callback instead of leaving the app waiting for a token that never arrives.
static void PearInstallRemoteNotifications(void) {
    Class application = objc_getClass("UIApplication");
    if (!application) return;

    PearReplaceInstance(application, @selector(registerForRemoteNotifications), ^(id self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PearReportRemoteNotificationFailure((UIApplication *)self);
        });
    });
    PearReplaceInstance(application, @selector(registerForRemoteNotificationTypes:),
        ^(id self, NSUInteger types) {
            dispatch_async(dispatch_get_main_queue(), ^{
                PearReportRemoteNotificationFailure((UIApplication *)self);
            });
        });
    PearReplaceInstance(application, @selector(unregisterForRemoteNotifications), ^(id self) {});

    PEAR_SERVICES_LOG_ONCE(@"[PearRuntime][services] remote notifications report unavailable");
}

#pragma mark - ARKit

/// Tracking needs a camera pipeline that does not exist in this environment.
/// Reporting unsupported lets apps take their non-AR path instead of failing
/// when a session is created.
static void PearInstallARAvailability(void) {
    Class configuration = objc_getClass("ARConfiguration");
    if (configuration) {
        PearReplaceClass(configuration, @selector(isSupported), ^BOOL(id self) {
            return NO;
        });
    }
    Class world = objc_getClass("ARWorldTrackingConfiguration");
    if (world) {
        PearReplaceClass(world, @selector(isSupported), ^BOOL(id self) {
            return NO;
        });
    }

    PEAR_SERVICES_LOG_ONCE(@"[PearRuntime][services] ARKit reports unsupported");
}

#pragma mark - Background tasks

static _Atomic NSUInteger gNextBackgroundTask = 1;

/// macOS keeps the process alive while its window is open, so there is no
/// background-time budget to consume. Returning a stable identifier prevents
/// loaders that gate work on a valid task from aborting.
static void PearInstallBackgroundTasks(void) {
    Class application = objc_getClass("UIApplication");
    if (!application) return;

    PearReplaceInstance(application, @selector(beginBackgroundTaskWithExpirationHandler:),
        ^NSUInteger(id self, void (^handler)(void)) {
            return atomic_fetch_add(&gNextBackgroundTask, 1);
        });
    PearReplaceInstance(application, @selector(beginBackgroundTaskWithName:expirationHandler:),
        ^NSUInteger(id self, NSString *name, void (^handler)(void)) {
            return atomic_fetch_add(&gNextBackgroundTask, 1);
        });
    PearReplaceInstance(application, @selector(endBackgroundTask:),
        ^(id self, NSUInteger identifier) {});

    PEAR_SERVICES_LOG_ONCE(@"[PearRuntime][services] background tasks stay local");
}

__attribute__((constructor))
static void PearServicesShimInit(void) {
    if (PearServicesDisabled()) return;
    @autoreleasepool {
        PearInstallAudioSession();
        PearInstallHaptics();
        PearInstallStoreSurface();
        PearInstallRemoteNotifications();
        PearInstallARAvailability();
        PearInstallBackgroundTasks();
    }

    // A few frameworks load lazily. Re-run the installer so a late-loaded
    // StoreKit, ARKit or UIKit class still gets its local surface.
    for (int i = 1; i <= 3; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                PearInstallAudioSession();
                PearInstallHaptics();
                PearInstallStoreSurface();
                PearInstallRemoteNotifications();
                PearInstallARAvailability();
                PearInstallBackgroundTasks();
            }
        });
    }
}
