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

static void PearInstallFoundationGuards(void) {
    if (PearFoundationGuardsDisabled()) return;
    PearInstallSerializationGuards();
    PearInstallImageGuards();
    NSSetUncaughtExceptionHandler(&PearLogUncaughtException);
    PearLog(@"[PearRuntime][data] Foundation nil-data guards installed");
}

__attribute__((constructor))
static void PearFoundationShimInit(void) {
    @autoreleasepool {
        PearInstallFoundationGuards();
    }
}
