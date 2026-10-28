// NetworkShim.mm
//
// Makes an app's network traffic look like it came from an iPhone.
//
// A Mac Catalyst process reports a macOS identity: NSURLSession sends a
// "Macintosh; Intel Mac OS X" User-Agent, some code paths negotiate HTTP/3
// (QUIC), and a few backends reject the resulting requests or answer with a
// 404. This shim rewrites the outgoing requests:
//
//   - User-Agent becomes an iOS-style product token built from the app's own
//     executable name and version, e.g.
//     "MyApp/1.0 (iPhone; iOS 16.0; Scale/3.00)".
//   - X-Device-Model and X-OS-Version are added when the app did not set them.
//   - NSURLSessionConfiguration.assumesHTTP3Capable reads as NO and ignores
//     attempts to turn it on, so new connections use HTTP/2 instead of QUIC.
//
// Requests are covered at three points:
//   - the NSMutableURLRequest header setters (setValue:forHTTPHeaderField:,
//     setAllHTTPHeaderFields:), so requests that set headers themselves get
//     the iOS values;
//   - NSURLSessionConfiguration.HTTPAdditionalHeaders, so requests created
//     from a URL (with no headers of their own) get them too;
//   - the NSURLSession task factory methods, as a belt-and-braces rewrite for
//     requests that already exist before they reach the session.
//
// Opt out with PEAR_NO_NETWORK_SHIM=1. Set PEAR_NETWORK_KEEP_UA=1 to keep an
// app-supplied non-Mac User-Agent instead of replacing it.
//
// This is a compatibility shim for the platform's HTTP client. It does not
// defeat any protection mechanism.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "PearRuntime.h"

static BOOL gInstalled;
static BOOL gKeepUA;

static BOOL PearNetworkDebug(void) {
    return getenv("PEAR_DEBUG_NETWORK") != NULL;
}

/// Logs the request line and headers (never the body). Encrypted payloads are
/// opaque by design; this is enough to spot a host-only header or user agent.
static void PearLogRequest(NSString *phase, NSURLRequest *request) {
    if (!PearNetworkDebug() || !request) return;
    PearLog(@"[PearRuntime][network] %@ %@ %@ headers=%@",
            phase, request.HTTPMethod ?: @"GET", request.URL.absoluteString ?: @"(null)",
            request.allHTTPHeaderFields ?: @{});
}

#pragma mark - Header values

static NSString *PearDeviceModel(void) {
    const char *override = getenv("PEAR_DEVICE_MODEL");
    if (override && override[0]) return [NSString stringWithUTF8String:override];
    // A current iPhone model identifier. X-Device-Model is a custom header, so
    // the exact model only has to be plausible and stable.
    return @"iPhone15,2";
}

static NSString *PearIOSVersion(void) {
    const char *override = getenv("PEAR_FAKE_IOS_VERSION");
    if (override && override[0]) return [NSString stringWithUTF8String:override];
    return @"16.0";
}

static NSString *PearUserAgent(void) {
    static NSString *agent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
        NSString *name = info[@"CFBundleExecutable"] ?: info[@"CFBundleName"] ?: @"App";
        name = [name stringByReplacingOccurrencesOfString:@" " withString:@""];
        NSString *version = info[@"CFBundleShortVersionString"] ?: @"1.0";
        agent = [NSString stringWithFormat:@"%@/%@ (iPhone; iOS %@; Scale/3.00)",
                 name, version, PearIOSVersion()];
    });
    return agent;
}

static BOOL PearLooksLikeMacUserAgent(NSString *agent) {
    if (agent.length == 0) return YES;
    NSString *lower = agent.lowercaseString;
    return [lower containsString:@"macintosh"] ||
           [lower containsString:@"mac os x"] ||
           [lower containsString:@"darwin"];
}

/// Merges the iOS headers into a header dictionary, preserving anything the
/// caller set except a macOS User-Agent (unless PEAR_NETWORK_KEEP_UA is set).
static NSDictionary *PearMergedHeaders(NSDictionary *headers) {
    NSMutableDictionary *merged = [headers isKindOfClass:[NSDictionary class]]
        ? [headers mutableCopy]
        : [NSMutableDictionary dictionary];

    NSString *existing = merged[@"User-Agent"];
    if (!gKeepUA || PearLooksLikeMacUserAgent(existing)) {
        merged[@"User-Agent"] = PearUserAgent();
    }
    if (!merged[@"X-Device-Model"]) merged[@"X-Device-Model"] = PearDeviceModel();
    if (!merged[@"X-OS-Version"]) merged[@"X-OS-Version"] = PearIOSVersion();
    return merged;
}

static void PearApplyHeaders(NSMutableURLRequest *request) {
    if (!request) return;
    NSDictionary *headers = PearMergedHeaders(request.allHTTPHeaderFields);
    for (NSString *field in headers) {
        [request setValue:headers[field] forHTTPHeaderField:field];
    }
}

#pragma mark - Swizzling

static BOOL PearFirstPatch(Method method) {
    static NSMutableSet *patched;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ patched = [NSMutableSet set]; });
    if (!method) return NO;
    NSValue *key = [NSValue valueWithPointer:method];
    if ([patched containsObject:key]) return NO;
    [patched addObject:key];
    return YES;
}

static IMP PearSwap(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || !PearFirstPatch(method)) return NULL;
    IMP original = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return original;
}

#pragma mark - NSMutableURLRequest header setters

typedef void (*SetValueFn)(id, SEL, NSString *, NSString *);
typedef void (*SetAllHeadersFn)(id, SEL, NSDictionary *);
static SetValueFn gSetValue;
static SetAllHeadersFn gSetAllHeaders;

static void PearSetValue(id self, SEL _cmd, NSString *value, NSString *field) {
    if ([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame && !gKeepUA) {
        value = PearUserAgent();
    }
    if (gSetValue) gSetValue(self, _cmd, value, field);
}

static void PearSetAllHeaders(id self, SEL _cmd, NSDictionary *headers) {
    if (gSetAllHeaders) gSetAllHeaders(self, _cmd, PearMergedHeaders(headers));
}

#pragma mark - NSURLSessionConfiguration

typedef NSDictionary *(*HeadersGetterFn)(id, SEL);
typedef void (*HeadersSetterFn)(id, SEL, NSDictionary *);
static HeadersGetterFn gHeadersGetter;
static HeadersSetterFn gHeadersSetter;

static NSDictionary *PearHeadersGetter(id self, SEL _cmd) {
    NSDictionary *original = gHeadersGetter ? gHeadersGetter(self, _cmd) : nil;
    return PearMergedHeaders(original);
}

static void PearHeadersSetter(id self, SEL _cmd, NSDictionary *headers) {
    if (gHeadersSetter) gHeadersSetter(self, _cmd, PearMergedHeaders(headers));
}

static void PearPatchConfigurationClass(Class cls) {
    if (!cls) return;

    IMP headersGetter = PearSwap(cls, @selector(HTTPAdditionalHeaders), (IMP)PearHeadersGetter);
    if (headersGetter) gHeadersGetter = (HeadersGetterFn)headersGetter;
    IMP headersSetter = PearSwap(cls, @selector(setHTTPAdditionalHeaders:), (IMP)PearHeadersSetter);
    if (headersSetter) gHeadersSetter = (HeadersSetterFn)headersSetter;

    // assumesHTTP3Capable is public since iOS 14.5 / macOS 11.3. Force it off
    // so CFNetwork does not negotiate QUIC for new connections.
    SEL h3GetterSel = NSSelectorFromString(@"assumesHTTP3Capable");
    SEL h3SetterSel = NSSelectorFromString(@"setAssumesHTTP3Capable:");
    Method h3Getter = class_getInstanceMethod(cls, h3GetterSel);
    if (h3Getter && PearFirstPatch(h3Getter)) {
        method_setImplementation(h3Getter, imp_implementationWithBlock(^BOOL(id _self) {
            return NO;
        }));
    }
    Method h3Setter = class_getInstanceMethod(cls, h3SetterSel);
    if (h3Setter && PearFirstPatch(h3Setter)) {
        method_setImplementation(h3Setter, imp_implementationWithBlock(^(id _self, BOOL _value) {
            // Ignore attempts to turn HTTP/3 back on.
        }));
    }
}

#pragma mark - NSURLSession task factories

typedef NSURLSessionTask *(*TaskWithRequestFn)(id, SEL, NSURLRequest *);
typedef NSURLSessionTask *(*TaskWithRequestHandlerFn)(id, SEL, NSURLRequest *, void *);
typedef NSURLSessionTask *(*TaskWithRequestDataFn)(id, SEL, NSURLRequest *, NSData *);
typedef NSURLSessionTask *(*TaskWithRequestFileFn)(id, SEL, NSURLRequest *, NSURL *);

static TaskWithRequestFn gDataTaskWithRequest;
static TaskWithRequestHandlerFn gDataTaskWithRequestHandler;
static TaskWithRequestFn gDownloadTaskWithRequest;
static TaskWithRequestHandlerFn gDownloadTaskWithRequestHandler;
static TaskWithRequestDataFn gUploadTaskWithRequestFromData;
static TaskWithRequestFileFn gUploadTaskWithRequestFromFile;

static NSMutableURLRequest *PearRewrittenRequest(NSURLRequest *request) {
    NSMutableURLRequest *rewritten = [request mutableCopy];
    if (!rewritten) rewritten = [NSMutableURLRequest requestWithURL:request.URL];
    PearApplyHeaders(rewritten);
    PearLogRequest(@"outgoing", rewritten);
    return rewritten;
}

static NSURLSessionTask *PearDataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    return gDataTaskWithRequest ? gDataTaskWithRequest(self, _cmd, PearRewrittenRequest(request)) : nil;
}

static NSURLSessionTask *PearDataTaskWithRequestHandler(id self, SEL _cmd, NSURLRequest *request, void *handler) {
    return gDataTaskWithRequestHandler
        ? gDataTaskWithRequestHandler(self, _cmd, PearRewrittenRequest(request), handler)
        : nil;
}

static NSURLSessionTask *PearDownloadTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    return gDownloadTaskWithRequest ? gDownloadTaskWithRequest(self, _cmd, PearRewrittenRequest(request)) : nil;
}

static NSURLSessionTask *PearDownloadTaskWithRequestHandler(id self, SEL _cmd, NSURLRequest *request, void *handler) {
    return gDownloadTaskWithRequestHandler
        ? gDownloadTaskWithRequestHandler(self, _cmd, PearRewrittenRequest(request), handler)
        : nil;
}

static NSURLSessionTask *PearUploadTaskWithRequestFromData(id self, SEL _cmd, NSURLRequest *request, NSData *data) {
    return gUploadTaskWithRequestFromData
        ? gUploadTaskWithRequestFromData(self, _cmd, PearRewrittenRequest(request), data)
        : nil;
}

static NSURLSessionTask *PearUploadTaskWithRequestFromFile(id self, SEL _cmd, NSURLRequest *request, NSURL *file) {
    return gUploadTaskWithRequestFromFile
        ? gUploadTaskWithRequestFromFile(self, _cmd, PearRewrittenRequest(request), file)
        : nil;
}

static void PearPatchSessionClass(Class cls) {
    if (!cls) return;
    IMP imp;

    imp = PearSwap(cls, @selector(dataTaskWithRequest:), (IMP)PearDataTaskWithRequest);
    if (imp) gDataTaskWithRequest = (TaskWithRequestFn)imp;

    imp = PearSwap(cls, @selector(dataTaskWithRequest:completionHandler:), (IMP)PearDataTaskWithRequestHandler);
    if (imp) gDataTaskWithRequestHandler = (TaskWithRequestHandlerFn)imp;

    imp = PearSwap(cls, @selector(downloadTaskWithRequest:), (IMP)PearDownloadTaskWithRequest);
    if (imp) gDownloadTaskWithRequest = (TaskWithRequestFn)imp;

    imp = PearSwap(cls, @selector(downloadTaskWithRequest:completionHandler:), (IMP)PearDownloadTaskWithRequestHandler);
    if (imp) gDownloadTaskWithRequestHandler = (TaskWithRequestHandlerFn)imp;

    imp = PearSwap(cls, @selector(uploadTaskWithRequest:fromData:), (IMP)PearUploadTaskWithRequestFromData);
    if (imp) gUploadTaskWithRequestFromData = (TaskWithRequestDataFn)imp;

    imp = PearSwap(cls, @selector(uploadTaskWithRequest:fromFile:), (IMP)PearUploadTaskWithRequestFromFile);
    if (imp) gUploadTaskWithRequestFromFile = (TaskWithRequestFileFn)imp;
}

#pragma mark - Install

static void PearInstallNetworkShim(void) {
    if (gInstalled) return;
    gInstalled = YES;
    gKeepUA = getenv("PEAR_NETWORK_KEEP_UA") != NULL;

    @autoreleasepool {
        // Concrete class of mutable requests; patching it covers every request
        // the app creates through any initializer.
        NSMutableURLRequest *sample =
            [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://example.com"]];
        Class requestClass = sample ? object_getClass(sample) : [NSMutableURLRequest class];
        IMP imp = PearSwap(requestClass, @selector(setValue:forHTTPHeaderField:), (IMP)PearSetValue);
        if (imp) gSetValue = (SetValueFn)imp;
        imp = PearSwap(requestClass, @selector(setAllHTTPHeaderFields:), (IMP)PearSetAllHeaders);
        if (imp) gSetAllHeaders = (SetAllHeadersFn)imp;

        // Concrete class of session configurations; the default, ephemeral and
        // shared sessions all use it.
        NSURLSessionConfiguration *defaults = [NSURLSessionConfiguration defaultSessionConfiguration];
        PearPatchConfigurationClass(defaults ? object_getClass(defaults) : [NSURLSessionConfiguration class]);
        NSURLSessionConfiguration *ephemeral = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        PearPatchConfigurationClass(ephemeral ? object_getClass(ephemeral) : NULL);

        // Concrete class of the shared session, which is what most code uses.
        NSURLSession *session = [NSURLSession sharedSession];
        PearPatchSessionClass(session ? object_getClass(session) : [NSURLSession class]);
    }

    PearLog(@"[PearRuntime][network] shim installed (UA=%@, HTTP/3 off)", PearUserAgent());
}

__attribute__((constructor))
static void PearNetworkShimInit(void) {
    @autoreleasepool {
        if (NSProcessInfo.processInfo.environment[@"PEAR_NO_NETWORK_SHIM"]) return;
        PearInstallNetworkShim();
    }
}
