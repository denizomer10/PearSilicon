// FoundationShim.mm
//
// Keeps two common Foundation contracts from terminating an app.
//
// 1. Serializers and image decoders raise `NSInvalidArgumentException`
//    ("data parameter is nil") when a caller passes the nil result of a failed
//    download or file read. The documented behaviour for an unreadable payload
//    is a nil result plus an error; several ports do not check the response and
//    would otherwise close the app during their content-download flow
//    (Candy Crush Soda is one).
//
// 2. An uncaught exception is logged with its call stack before the process
//    exits, so a failure inside a third-party crash reporter still leaves a
//    readable trace in the runtime log.
//
// This does not suppress errors: the caller receives the same nil result it
// would get for malformed data, and the error object says what happened.
//
// Disable with PEAR_NO_FOUNDATION_GUARDS=1.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <execinfo.h>
#import <fcntl.h>
#import <signal.h>
#import <stdio.h>
#import <unistd.h>
#import "PearRuntime.h"

static BOOL PearFoundationGuardsDisabled(void) {
    const char *value = getenv("PEAR_NO_FOUNDATION_GUARDS");
    return value && value[0] && strcmp(value, "0") != 0;
}

static NSError *PearNilDataError(NSString *operation) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:4864 userInfo:@{
        NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"%@ received nil data", operation]
    }];
}

static void PearGuardClassMethod(Class cls, SEL selector, IMP replacement) {
    if (!cls) return;
    Method method = class_getClassMethod(cls, selector);
    if (!method) return;
    method_setImplementation(method, replacement);
}

static void PearInstallSerializationGuards(void) {
    Class json = NSClassFromString(@"NSJSONSerialization");
    if (json) {
        SEL dataSelector = @selector(JSONObjectWithData:options:error:);
        Method dataMethod = class_getClassMethod(json, dataSelector);
        if (dataMethod) {
            IMP original = method_getImplementation(dataMethod);
            PearGuardClassMethod(json, dataSelector, imp_implementationWithBlock(
                ^id(id self, NSData *data, NSJSONReadingOptions options, NSError **error) {
                    if (!data) {
                        if (error) *error = PearNilDataError(@"JSONObjectWithData:");
                        PearLog(@"[PearRuntime][data] JSON parse skipped: nil data");
                        return nil;
                    }
                    return ((id (*)(id, SEL, NSData *, NSJSONReadingOptions, NSError **))original)(
                        self, dataSelector, data, options, error);
                }));
        }

        SEL streamSelector = @selector(JSONObjectWithStream:options:error:);
        Method streamMethod = class_getClassMethod(json, streamSelector);
        if (streamMethod) {
            IMP original = method_getImplementation(streamMethod);
            PearGuardClassMethod(json, streamSelector, imp_implementationWithBlock(
                ^id(id self, NSInputStream *stream, NSJSONReadingOptions options, NSError **error) {
                    if (!stream) {
                        if (error) *error = PearNilDataError(@"JSONObjectWithStream:");
                        return nil;
                    }
                    return ((id (*)(id, SEL, NSInputStream *, NSJSONReadingOptions, NSError **))original)(
                        self, streamSelector, stream, options, error);
                }));
        }
    }

    Class plist = NSClassFromString(@"NSPropertyListSerialization");
    if (plist) {
        SEL selector = @selector(propertyListWithData:options:format:error:);
        Method method = class_getClassMethod(plist, selector);
        if (method) {
            IMP original = method_getImplementation(method);
            PearGuardClassMethod(plist, selector, imp_implementationWithBlock(
                ^id(id self, NSData *data, NSPropertyListReadOptions options,
                    NSPropertyListFormat *format, NSError **error) {
                    if (!data) {
                        if (error) *error = PearNilDataError(@"propertyListWithData:");
                        return nil;
                    }
                    return ((id (*)(id, SEL, NSData *, NSPropertyListReadOptions,
                                    NSPropertyListFormat *, NSError **))original)(
                        self, selector, data, options, format, error);
                }));
        }
    }

    Class unarchiver = NSClassFromString(@"NSKeyedUnarchiver");
    if (unarchiver) {
        SEL selector = @selector(unarchivedObjectOfClass:fromData:error:);
        Method method = class_getClassMethod(unarchiver, selector);
        if (method) {
            IMP original = method_getImplementation(method);
            PearGuardClassMethod(unarchiver, selector, imp_implementationWithBlock(
                ^id(id self, Class cls, NSData *data, NSError **error) {
                    if (!data) {
                        if (error) *error = PearNilDataError(@"unarchivedObjectOfClass:fromData:error:");
                        return nil;
                    }
                    return ((id (*)(id, SEL, Class, NSData *, NSError **))original)(
                        self, selector, cls, data, error);
                }));
        }

        // The streaming initializer is the other common entry point (and the
        // one several game SDKs use for their cached download manifests).
        SEL initSelector = @selector(initForReadingFromData:error:);
        Method initMethod = class_getInstanceMethod(unarchiver, initSelector);
        if (initMethod) {
            IMP original = method_getImplementation(initMethod);
            method_setImplementation(initMethod, imp_implementationWithBlock(
                ^id(id self, NSData *data, NSError **error) {
                    if (!data) {
                        if (error) *error = PearNilDataError(@"initForReadingFromData:error:");
                        return nil;
                    }
                    return ((id (*)(id, SEL, NSData *, NSError **))original)(
                        self, initSelector, data, error);
                }));
        }

        SEL legacySelector = @selector(initForReadingWithData:);
        Method legacyMethod = class_getInstanceMethod(unarchiver, legacySelector);
        if (legacyMethod) {
            IMP original = method_getImplementation(legacyMethod);
            method_setImplementation(legacyMethod, imp_implementationWithBlock(
                ^id(id self, NSData *data) {
                    if (!data) return nil;
                    return ((id (*)(id, SEL, NSData *))original)(
                        self, legacySelector, data);
                }));
        }
    }

    Class parser = NSClassFromString(@"NSXMLParser");
    if (parser) {
        SEL selector = @selector(initWithData:);
        Method method = class_getInstanceMethod(parser, selector);
        if (method) {
            IMP original = method_getImplementation(method);
            method_setImplementation(method, imp_implementationWithBlock(^id(id self, NSData *data) {
                if (!data) return nil;
                return ((id (*)(id, SEL, NSData *))original)(self, selector, data);
            }));
        }
    }
}

static void PearInstallImageGuards(void) {
    Class image = NSClassFromString(@"UIImage");
    if (!image) return;

    SEL selector = @selector(imageWithData:);
    Method method = class_getClassMethod(image, selector);
    if (method) {
        IMP original = method_getImplementation(method);
        PearGuardClassMethod(image, selector, imp_implementationWithBlock(
            ^id(id self, NSData *data) {
                if (!data) {
                    PearLog(@"[PearRuntime][data] imageWithData: skipped: nil data");
                    return nil;
                }
                return ((id (*)(id, SEL, NSData *))original)(self, selector, data);
            }));
    }

    SEL scaledSelector = @selector(imageWithData:scale:);
    Method scaledMethod = class_getClassMethod(image, scaledSelector);
    if (scaledMethod) {
        IMP original = method_getImplementation(scaledMethod);
        PearGuardClassMethod(image, scaledSelector, imp_implementationWithBlock(
            ^id(id self, NSData *data, CGFloat scale) {
                if (!data) return nil;
                return ((id (*)(id, SEL, NSData *, CGFloat))original)(
                    self, scaledSelector, data, scale);
            }));
    }
}

static void PearLogUncaughtException(NSException *exception) {
    PearLog(@"[PearRuntime][exception] %@: %@\n%@",
            exception.name, exception.reason,
            [exception.callStackSymbols componentsJoinedByString:@"\n"]);
}

#pragma mark - Crash signal log

static int gCrashLogFD = -1;
static struct sigaction gPreviousSignalActions[NSIG];
static volatile sig_atomic_t gInSignalHandler = 0;

static void PearCrashSignalHandler(int signalNumber) {
    if (gInSignalHandler) {
        struct sigaction fallback = {0};
        fallback.sa_handler = SIG_DFL;
        sigaction(signalNumber, &fallback, NULL);
        raise(signalNumber);
        return;
    }
    gInSignalHandler = 1;

    if (gCrashLogFD >= 0) {
        char header[96];
        int length = snprintf(header, sizeof(header),
                              "\n[PearRuntime][signal] received signal %d\n", signalNumber);
        if (length > 0) write(gCrashLogFD, header, (size_t)length);
        void *frames[64];
        int count = backtrace(frames, 64);
        if (count > 0) backtrace_symbols_fd(frames, count, gCrashLogFD);
    }

    struct sigaction previous = gPreviousSignalActions[signalNumber];
    if (previous.sa_handler == SIG_IGN) previous.sa_handler = SIG_DFL;
    sigaction(signalNumber, &previous, NULL);
    raise(signalNumber);
}

static void PearInstallCrashSignalLog(void) {
    if (getenv("PEAR_NO_SIGNAL_LOG")) return;
    NSString *path = PearLogFilePath();
    if (path.length == 0) return;
    gCrashLogFD = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (gCrashLogFD < 0) return;

    const int signals[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        struct sigaction action = {0};
        action.sa_handler = PearCrashSignalHandler;
        sigemptyset(&action.sa_mask);
        action.sa_flags = SA_RESTART;
        sigaction(signals[i], &action, &gPreviousSignalActions[signals[i]]);
    }
}

static void PearInstallFoundationGuards(void) {
    if (PearFoundationGuardsDisabled()) return;
    PearInstallSerializationGuards();
    PearInstallImageGuards();
    NSSetUncaughtExceptionHandler(&PearLogUncaughtException);
    PearInstallCrashSignalLog();
    PearLog(@"[PearRuntime][data] Foundation nil-data guards installed");
}

__attribute__((constructor))
static void PearFoundationShimInit(void) {
    @autoreleasepool {
        PearInstallFoundationGuards();
    }
}
