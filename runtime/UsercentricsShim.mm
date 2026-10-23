// UsercentricsShim.mm
//
// Skips the Usercentrics consent SDK in titles that ship it.
//
// Some titles bundle UsercentricsUI, a Swift consent-management SDK. Its Swift
// metadata is built for the iOS Swift runtime; under the macOS iOS-on-Mac
// runtime the metadata accessor returns an invalid pointer and the app dies
// with SIGBUS in the Swift runtime while the consent banner is being
// configured. The crash is deterministic and happens before any gameplay.
//
// The app only needs a consent decision to continue. This shim replaces the
// C# entry points that create/show the native banner. `Initialize` is replaced
// with a function that reports "no consent required" to the app's callback,
// so the app proceeds without the Swift UI. Everything else is a no-op.
//
// The shim discovers the assemblies, classes and methods at runtime. It
// contains no game names, bundle identifiers or hardcoded addresses; the
// assembly and class names below are the SDK's own public metadata.
//
// Opt out with PEAR_NO_USERCENTRICS_SHIM=1.
//
// This is a compatibility shim for a third-party UI SDK.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>
#import "PearRuntime.h"

typedef void *(*GetCorlibFn)(void);
typedef void *(*DomainGetFn)(void);
typedef void *(*ThreadAttachFn)(void *);
typedef void (*ClassForEachFn)(void (*)(void *, void *), void *);
typedef void *(*ClassGetImageFn)(void *);
typedef const char *(*ImageGetNameFn)(void *);
typedef bool (*ClassIsGenericFn)(void *);
typedef bool (*ClassIsInflatedFn)(void *);
typedef size_t (*ImageGetClassCountFn)(void *);
typedef void *(*ImageGetClassFn)(void *, size_t);
typedef const char *(*ClassGetNameFn)(void *);
typedef const char *(*ClassGetNamespaceFn)(void *);
typedef void *(*ClassGetMethodsFn)(void *, void **);
typedef void *(*ClassGetFieldsFn)(void *, void **);
typedef const char *(*MethodGetNameFn)(void *);
typedef uint32_t (*MethodGetParamCountFn)(void *);
typedef bool (*MethodIsInstanceFn)(void *);
typedef void *(*MethodGetReturnTypeFn)(void *);
typedef int (*TypeGetTypeFn)(void *);
typedef const char *(*FieldGetNameFn)(void *);
typedef void *(*FieldGetTypeFn)(void *);
typedef void (*FieldGetValueFn)(void *, void *, void *);
typedef void *(*ClassFromTypeFn)(void *);
typedef void *(*ClassFromNameFn)(void *, const char *, const char *);
typedef void *(*ClassGetTypeFn)(void *);
typedef void *(*ObjectNewFn)(void *);
typedef void (*FieldSetValueFn)(void *, void *, void *);
typedef void *(*RuntimeInvokeFn)(void *, void *, void **, void **);
typedef void *(*StringNewWrapperFn)(const char *);

static GetCorlibFn gGetCorlib;
static DomainGetFn gDomainGet;
static ThreadAttachFn gThreadAttach;
static ClassForEachFn gClassForEach;
static ClassGetImageFn gClassGetImage;
static ImageGetNameFn gImageGetName;
static ClassIsGenericFn gClassIsGeneric;
static ClassIsInflatedFn gClassIsInflated;
static ImageGetClassCountFn gImageGetClassCount;
static ImageGetClassFn gImageGetClass;
static ClassGetNameFn gClassGetName;
static ClassGetNamespaceFn gClassGetNamespace;
static ClassGetMethodsFn gClassGetMethods;
static ClassGetFieldsFn gClassGetFields;
static MethodGetNameFn gMethodGetName;
static MethodGetParamCountFn gMethodGetParamCount;
static MethodIsInstanceFn gMethodIsInstance;
static MethodGetReturnTypeFn gMethodGetReturnType;
static TypeGetTypeFn gTypeGetType;
static FieldGetNameFn gFieldGetName;
static FieldGetTypeFn gFieldGetType;
static FieldGetValueFn gFieldGetValue;
static ClassFromTypeFn gClassFromType;
static ClassFromNameFn gClassFromName;
static ClassGetTypeFn gClassGetType;

static ObjectNewFn gObjectNew;
static FieldSetValueFn gFieldSetValue;
static RuntimeInvokeFn gRuntimeInvoke;
static StringNewWrapperFn gStringNewWrapper;

static BOOL gInstalled;
static BOOL gResolved;
static CFAbsoluteTime gLastScanTime;
static BOOL gLoggedResolveFailure;
static BOOL gLoggedDomainMissing;
static BOOL gLoggedAssemblyMissing;
static BOOL gLoggedNoMatch;
static BOOL gLoggedClassImages;
static BOOL gLoggedCorlib;
static BOOL gDebug;

static void *PearFindMethod(void *klass, const char *wantedName, uint32_t wantedParams);

// Metadata needed by the Initialize replacement.
static void *gStatusClass;
static void *gStatusCtor;
static void *gOnInitializedInvoke;
static void *gShouldCollectField;
static void *gBannerRequiredField;
static void *gActiveSettingsField;
static void *gCountryField;
static void *gRegionField;
static void *gServiceConsentsField;
static void *gPrivacyOnInitialized;

/// Void-returning C function used as the replacement body for the UI entry
/// points. The C# methods we replace all return System.Void.
static void PearUsercentricsNoop(void) {}

/// Returns true for PrivacyManager.IsReady(). A bool return travels in w0.
static bool PearUsercentricsReturnTrue(void) { return true; }

/// Handle to UnityFramework. The framework is not always loaded into the
/// global symbol scope, so RTLD_DEFAULT can miss its exports; resolving from
/// the framework handle works either way. RTLD_NOLOAD returns the handle for
/// the copy the app already loaded instead of loading a second one.
static void *PearUnityFrameworkHandle(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle.privateFrameworksPath
                          stringByAppendingPathComponent:@"UnityFramework.framework/UnityFramework"];
        if (path) {
            handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
            if (!handle) handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY);
        }
    });
    return handle;
}

/// Resolves an IL2CPP export, preferring the UnityFramework handle and falling
/// back to the global scope.
static void *PearSymbol(const char *name) {
    void *handle = PearUnityFrameworkHandle();
    void *symbol = handle ? dlsym(handle, name) : NULL;
    return symbol ? symbol : dlsym(RTLD_DEFAULT, name);
}

static BOOL PearResolveIL2CPP(void) {
    if (gResolved) return YES;
    gGetCorlib = (GetCorlibFn)PearSymbol("il2cpp_get_corlib");
    gDomainGet = (DomainGetFn)PearSymbol("il2cpp_domain_get");
    gThreadAttach = (ThreadAttachFn)PearSymbol("il2cpp_thread_attach");
    // Some Unity builds do not export il2cpp_domain_get_assemblies, so walk
    // classes instead; il2cpp_class_for_each is available in those builds.
    gClassForEach = (ClassForEachFn)PearSymbol("il2cpp_class_for_each");
    gClassGetImage = (ClassGetImageFn)PearSymbol("il2cpp_class_get_image");
    gImageGetName = (ImageGetNameFn)PearSymbol("il2cpp_image_get_name");
    gClassIsGeneric = (ClassIsGenericFn)PearSymbol("il2cpp_class_is_generic");
    gClassIsInflated = (ClassIsInflatedFn)PearSymbol("il2cpp_class_is_inflated");
    gImageGetClassCount = (ImageGetClassCountFn)PearSymbol("il2cpp_image_get_class_count");
    gImageGetClass = (ImageGetClassFn)PearSymbol("il2cpp_image_get_class");
    gClassGetName = (ClassGetNameFn)PearSymbol("il2cpp_class_get_name");
    gClassGetNamespace = (ClassGetNamespaceFn)PearSymbol("il2cpp_class_get_namespace");
    gClassGetMethods = (ClassGetMethodsFn)PearSymbol("il2cpp_class_get_methods");
    gClassGetFields = (ClassGetFieldsFn)PearSymbol("il2cpp_class_get_fields");
    gMethodGetName = (MethodGetNameFn)PearSymbol("il2cpp_method_get_name");
    gMethodGetParamCount = (MethodGetParamCountFn)PearSymbol("il2cpp_method_get_param_count");
    // Optional: used to pick the right calling convention for the replacement.
    // Older IL2CPP builds may not export it; the shim then assumes an instance
    // method, which is what the consent entry point is.
    gMethodIsInstance = (MethodIsInstanceFn)PearSymbol("il2cpp_method_is_instance");
    gMethodGetReturnType = (MethodGetReturnTypeFn)PearSymbol("il2cpp_method_get_return_type");
    gTypeGetType = (TypeGetTypeFn)PearSymbol("il2cpp_type_get_type");
    gFieldGetName = (FieldGetNameFn)PearSymbol("il2cpp_field_get_name");
    gFieldGetType = (FieldGetTypeFn)PearSymbol("il2cpp_field_get_type");
    gFieldGetValue = (FieldGetValueFn)PearSymbol("il2cpp_field_get_value");
    gClassFromType = (ClassFromTypeFn)PearSymbol("il2cpp_class_from_type");
    gClassFromName = (ClassFromNameFn)PearSymbol("il2cpp_class_from_name");
    gClassGetType = (ClassGetTypeFn)PearSymbol("il2cpp_class_get_type");
    gObjectNew = (ObjectNewFn)PearSymbol("il2cpp_object_new");
    gFieldSetValue = (FieldSetValueFn)PearSymbol("il2cpp_field_set_value");
    gRuntimeInvoke = (RuntimeInvokeFn)PearSymbol("il2cpp_runtime_invoke");
    gStringNewWrapper = (StringNewWrapperFn)PearSymbol("il2cpp_string_new_wrapper");
    // Only symbols the shim actually needs are required. gImageGetName,
    // gFieldGetType, gClassFromName and gClassGetType are resolved for
    // diagnostics but must not gate installation: some Unity builds omit them,
    // and the shim no longer uses them.
    gResolved = gGetCorlib && gDomainGet && gThreadAttach && gClassForEach &&
                gClassGetImage && gClassIsGeneric && gClassIsInflated &&
                gImageGetClassCount && gImageGetClass && gClassGetName &&
                gClassGetNamespace && gClassGetMethods && gClassGetFields && gMethodGetName &&
                gMethodGetParamCount && gMethodGetReturnType && gTypeGetType &&
                gFieldGetName && gFieldGetValue && gClassFromType && gObjectNew &&
                gFieldSetValue && gRuntimeInvoke && gStringNewWrapper;
    // Once the framework is loaded, gGetCorlib resolves; if the set is still
    // incomplete, name the missing exports so a device run is diagnosable.
    if (!gResolved && gGetCorlib) {
        static BOOL loggedMissing;
        if (!loggedMissing) {
            loggedMissing = YES;
            PearLog(@"[PearRuntime][usercentrics] missing IL2CPP exports: "
                    "domain=%d attach=%d assemblies=%d image=%d imageName=%d "
                    "generic=%d inflated=%d classCount=%d class=%d "
                    "className=%d ns=%d methods=%d fields=%d methodName=%d paramCount=%d "
                    "returnType=%d fieldName=%d fieldType=%d classFromName=%d "
                    "classGetType=%d objectNew=%d fieldSet=%d invoke=%d string=%d",
                    gDomainGet != NULL, gThreadAttach != NULL,
                    gClassForEach != NULL, gClassGetImage != NULL,
                    gImageGetName != NULL, gClassIsGeneric != NULL, gClassIsInflated != NULL,
                    gImageGetClassCount != NULL, gImageGetClass != NULL,
                    gClassGetName != NULL, gClassGetNamespace != NULL,
                    gClassGetMethods != NULL, gClassGetFields != NULL,
                    gMethodGetName != NULL, gMethodGetParamCount != NULL,
                    gMethodGetReturnType != NULL, gTypeGetType != NULL, gFieldGetName != NULL,
                    gFieldGetType != NULL, gClassFromName != NULL,
                    gClassGetType != NULL, gObjectNew != NULL,
                    gFieldSetValue != NULL, gRuntimeInvoke != NULL,
                    gStringNewWrapper != NULL);
        }
    }
    return gResolved;
}

static BOOL PearMethodReturnsVoid(void *method) {
    void *type = gMethodGetReturnType(method);
    if (!type || !gTypeGetType) return NO;
    // IL2CPP_TYPE_VOID == 0x01. Reading the type enum avoids both
    // il2cpp_type_get_name (which allocates and can abort on a background
    // thread) and comparing against System.Void's type pointer, which need not
    // be the same pointer the method signature uses.
    return gTypeGetType(type) == 1;
}

static BOOL PearIsUsercentricsClass(const char *ns) {
    return ns && strstr(ns, "Usercentrics") != NULL;
}

static BOOL PearIsUiEntryPoint(const char *name) {
    if (!name) return NO;
    // Keep the Swift UI entry points disabled. This list deliberately includes
    // AutoInitialize.Awake and the init helpers: letting them run reaches the
    // UsercentricsUI Swift metadata and crashes with SIGBUS under the macOS
    // iOS-on-Mac runtime. The trade-off is that Initialize is then never
    // called, which is why the privacy service reports failure 4300 until the
    // request-level work is finished.
    return strcmp(name, "Awake") == 0 ||
           strcmp(name, "CreateUsercentricsObject") == 0 ||
           strcmp(name, "ShowFirstLayer") == 0 ||
           strcmp(name, "ShowSecondLayer") == 0 ||
           strcmp(name, "PromptForAppTrackingTransparency") == 0 ||
           strcmp(name, ".cctor") == 0 ||
           strstr(name, "Init") != NULL;
}

/// The app's contained caches directory. Built directly rather than through
/// NSSearchPathForDirectoriesInDomains because dyld interposing does not
/// redirect calls made from this dylib itself, so that API returns the real
/// ~/Library/Caches here.
static NSString *PearContainedCachesPath(void) {
    const char *override = getenv("PEAR_HOME_DIR");
    if (override && override[0]) {
        return [[NSString stringWithUTF8String:override]
                stringByAppendingPathComponent:@"Library/Caches"];
    }
    const char *home = getenv("HOME");
    NSString *realHome = (home && home[0]) ? [NSString stringWithUTF8String:home] : NSHomeDirectory();
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
    NSString *root = [[realHome stringByAppendingPathComponent:@"Library/Application Support/PearSilicon/Games"]
                      stringByAppendingPathComponent:bundleID];
    return [root stringByAppendingPathComponent:@"Library/Caches"];
}

/// The app's active Usercentrics settings id and the region it applies to,
/// discovered from the SDK's own ruleset cache. The game sends the active
/// settings id to the consent service; a made-up id makes that request 404.
/// The cache lives under Library/Caches/usercentrics/etags-<primary>/ruleSet/.
static NSString *PearUsercentricsActiveSettingsId(NSString **outCountry) {
    static NSString *settingsId;
    static NSString *country;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        country = NSLocale.currentLocale.countryCode ?: @"US";
        NSString *caches = PearContainedCachesPath();
        NSString *root = [caches stringByAppendingPathComponent:@"usercentrics"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *primary = nil;
        if (gDebug) {
            NSArray *entries = [fm contentsOfDirectoryAtPath:root error:NULL];
            PearLog(@"[PearRuntime][usercentrics] settings cache root=%@ entries=%lu",
                    root, (unsigned long)entries.count);
        }

        for (NSString *entry in [fm contentsOfDirectoryAtPath:root error:NULL] ?: @[]) {
            if (![entry hasPrefix:@"etags-"]) continue;
            if (!primary) primary = [entry substringFromIndex:@"etags-".length];

            NSString *ruleDir = [[root stringByAppendingPathComponent:entry]
                                 stringByAppendingPathComponent:@"ruleSet"];
            for (NSString *file in [fm contentsOfDirectoryAtPath:ruleDir error:NULL] ?: @[]) {
                NSString *path = [ruleDir stringByAppendingPathComponent:file];
                NSData *data = [NSData dataWithContentsOfFile:path];
                if (!data) continue;
                NSSet *classes = [NSSet setWithObjects:[NSString class], [NSMutableString class], nil];
                id archived = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                                  fromData:data
                                                                     error:NULL];
                if (![archived isKindOfClass:[NSString class]]) continue;
                NSData *jsonData = [(NSString *)archived dataUsingEncoding:NSUTF8StringEncoding];
                id json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:NULL];
                if (![json isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *dict = (NSDictionary *)json;

                id rules = dict[@"rules"];
                if ([rules isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *rule in (NSArray *)rules) {
                        if (![rule isKindOfClass:[NSDictionary class]]) continue;
                        NSArray *locations = rule[@"locations"];
                        if ([locations isKindOfClass:[NSArray class]] &&
                            [locations containsObject:country]) {
                            settingsId = rule[@"settingsId"];
                            if (settingsId.length) break;
                        }
                    }
                }
                if (!settingsId.length) {
                    NSDictionary *def = dict[@"defaultRule"];
                    if ([def isKindOfClass:[NSDictionary class]]) settingsId = def[@"settingsId"];
                }
                if (settingsId.length) break;
            }
            if (settingsId.length) break;
        }
        if (!settingsId.length) settingsId = primary;
        PearLog(@"[PearRuntime][usercentrics] settings id=%@ country=%@",
                settingsId ?: @"(none)", country);
    });
    if (outCountry) *outCountry = country;
    return settingsId;
}

/// Replacement for UsercentricsCMP.Initialize(OnInitialized callback).
/// Builds a UsercentricsStatus that says "no consent required" and invokes the
/// callback, which is what the game's privacy service waits for.
static void PearUsercentricsInitialize(void *self, void *callback) {
    if (!callback || !gStatusClass || !gStatusCtor || !gOnInitializedInvoke) return;

    void *exception = NULL;
    void *status = gObjectNew(gStatusClass);
    if (!status) return;
    gRuntimeInvoke(gStatusCtor, status, NULL, &exception);
    if (exception) {
        PearLog(@"[PearRuntime][usercentrics] status ctor threw");
        return;
    }

    bool no = false;
    if (gShouldCollectField) gFieldSetValue(status, gShouldCollectField, &no);
    if (gBannerRequiredField) gFieldSetValue(status, gBannerRequiredField, &no);

    // The privacy service walks ServiceConsents; a null list makes it throw and
    // report an initialisation failure. The parameterless ctor may leave it
    // null, so give it an empty List<ServiceConsent> when that happens.
    if (gServiceConsentsField && gFieldGetValue) {
        void *list = NULL;
        gFieldGetValue(status, gServiceConsentsField, &list);
        if (!list && gFieldGetType && gClassFromType && gObjectNew && gRuntimeInvoke) {
            void *type = gFieldGetType(gServiceConsentsField);
            void *klass = type ? gClassFromType(type) : NULL;
            void *newList = klass ? gObjectNew(klass) : NULL;
            void *ctor = newList ? PearFindMethod(klass, ".ctor", 0) : NULL;
            if (newList && ctor) {
                void *e = NULL;
                gRuntimeInvoke(ctor, newList, NULL, &e);
                if (!e) {
                    gFieldSetValue(status, gServiceConsentsField, &newList);
                    PearLog(@"[PearRuntime][usercentrics] initialised ServiceConsents");
                }
            }
        } else if (list) {
            PearLog(@"[PearRuntime][usercentrics] ServiceConsents already set");
        }
    }

    NSString *countryCode = nil;
    NSString *activeSettingsId = PearUsercentricsActiveSettingsId(&countryCode);
    void *settingsId = gStringNewWrapper(activeSettingsId.length
                                        ? activeSettingsId.UTF8String : "pearsilicon");
    void *country = gStringNewWrapper(countryCode.length ? countryCode.UTF8String : "US");
    if (gActiveSettingsField) gFieldSetValue(status, gActiveSettingsField, &settingsId);
    if (gCountryField) gFieldSetValue(status, gCountryField, &country);
    if (gRegionField) gFieldSetValue(status, gRegionField, &country);

    void *error = gStringNewWrapper("");
    void *params[2] = { status, error };
    exception = NULL;
    gRuntimeInvoke(gOnInitializedInvoke, callback, params, &exception);
    if (exception) {
        PearLog(@"[PearRuntime][usercentrics] OnInitialized threw");
    } else {
        PearLog(@"[PearRuntime][usercentrics] reported no consent required");
    }
}

/// Static variant of the Initialize replacement. IL2CPP passes a static
/// method's arguments first and the MethodInfo last, so the callback arrives in
/// the first slot.
static void PearUsercentricsInitializeStatic(void *callback) {
    PearUsercentricsInitialize(NULL, callback);
}

static void *PearFindClass(void *image, size_t count, const char *wantedNamespace,
                           const char *wantedName) {
    for (size_t i = 0; i < count; i++) {
        void *klass = gImageGetClass(image, i);
        if (!klass) continue;
        const char *ns = gClassGetNamespace(klass);
        const char *name = gClassGetName(klass);
        if (!name || strcmp(name, wantedName) != 0) continue;
        if (wantedNamespace && (!ns || strcmp(ns, wantedNamespace) != 0)) continue;
        return klass;
    }
    return NULL;
}

typedef struct {
    const char *name;
    const char *namespaceSubstring;
    void *klass;
    void *image;
} PearClassSearch;

static void PearClassSearchCallback(void *klass, void *userData) {
    PearClassSearch *search = (PearClassSearch *)userData;
    if (search->klass) return;
    const char *name = gClassGetName(klass);
    if (!name || strcmp(name, search->name) != 0) return;
    const char *ns = gClassGetNamespace(klass);
    if (search->namespaceSubstring && (!ns || !strstr(ns, search->namespaceSubstring))) return;
    search->klass = klass;
    search->image = gClassGetImage ? gClassGetImage(klass) : NULL;
}

/// Finds a class by name across every class in the IL2CPP domain. The optional
/// namespace substring narrows the match without hardcoding a vendor's assembly
/// or namespace name. Walks classes rather than assemblies because some Unity
/// builds do not export il2cpp_domain_get_assemblies.
static void *PearFindClassAnywhere(const char *wantedName, const char *namespaceSubstring,
                                   void **outImage) {
    if (!gClassForEach) return NULL;
    PearClassSearch search = { wantedName, namespaceSubstring, NULL, NULL };
    gClassForEach(PearClassSearchCallback, &search);
    if (outImage) *outImage = search.image;
    return search.klass;
}

static void *PearFindMethod(void *klass, const char *wantedName, uint32_t wantedParams) {
    void *iter = NULL;
    while (YES) {
        void *method = gClassGetMethods(klass, &iter);
        if (!method) break;
        const char *name = gMethodGetName(method);
        if (name && strcmp(name, wantedName) == 0 &&
            gMethodGetParamCount(method) == wantedParams) {
            return method;
        }
    }
    return NULL;
}

static void *PearFindField(void *klass, const char *wantedName) {
    void *iter = NULL;
    while (YES) {
        void *field = gClassGetFields(klass, &iter);
        if (!field) break;
        const char *name = gFieldGetName(field);
        if (name && strcmp(name, wantedName) == 0) return field;
    }
    return NULL;
}

/// Debug helper: list a class's fields and their IL2CPP type kinds. Used to
/// learn what the privacy service reads from UsercentricsStatus. Fields are
/// metadata-only, so this is safe on a class that is not initialized yet.
static void PearDumpFields(void *klass) {
    if (!klass || !gDebug) return;
    const char *ns = gClassGetNamespace(klass);
    const char *name = gClassGetName(klass);
    PearLog(@"[PearRuntime][usercentrics] fields of %s.%s", ns ?: "", name ?: "");
    void *iter = NULL;
    while (YES) {
        void *field = gClassGetFields(klass, &iter);
        if (!field) break;
        const char *fname = gFieldGetName(field);
        void *ftype = gFieldGetType ? gFieldGetType(field) : NULL;
        int kind = (ftype && gTypeGetType) ? gTypeGetType(ftype) : -1;
        PearLog(@"[PearRuntime][usercentrics]   %s kind=%d", fname ?: "", kind);
    }
}

/// Reports a successful privacy initialisation to the game's own event
/// handler. The native Usercentrics SDK would normally fire this; with the
/// banner disabled we supply a "no consent required" payload.
static void PearFirePrivacyInitialized(void) {
    if (!gPrivacyOnInitialized || !gStringNewWrapper || !gRuntimeInvoke) return;
    if (gThreadAttach && gDomainGet) {
        void *domain = gDomainGet();
        if (domain) gThreadAttach(domain);
    }

    NSString *countryCode = nil;
    NSString *activeSettingsId = PearUsercentricsActiveSettingsId(&countryCode);
    NSString *json = [NSString stringWithFormat:
        @"{\"shouldCollectConsent\":false,\"consents\":[],"
         "\"geolocationRuleset\":{\"activeSettingsId\":\"%@\","
         "\"bannerRequiredAtLocation\":false},"
         "\"location\":{\"countryCode\":\"%@\",\"regionCode\":\"%@\"}}",
        activeSettingsId ?: @"pearsilicon",
        countryCode ?: @"US", countryCode ?: @"US"];

    void *jsonString = gStringNewWrapper(json.UTF8String);
    void *errorString = gStringNewWrapper("");
    void *params[2] = { jsonString, errorString };
    void *exception = NULL;
    gRuntimeInvoke(gPrivacyOnInitialized, NULL, params, &exception);
    if (exception) {
        PearLog(@"[PearRuntime][usercentrics] privacy OnInitialized threw");
    } else {
        PearLog(@"[PearRuntime][usercentrics] reported privacy initialized (no consent required)");
    }
}

typedef struct {
    int patched;
} PearPatchContext;

static void PearPatchClassCallback(void *klass, void *userData) {
    PearPatchContext *ctx = (PearPatchContext *)userData;
    const char *ns = gClassGetNamespace(klass);
    if (!PearIsUsercentricsClass(ns)) return;
    // il2cpp_class_get_methods on a generic definition blocks on the main
    // thread's class initializer (a semaphore wait), so skip generic and
    // inflated classes. Their concrete implementations are patched instead.
    if (gClassIsGeneric && gClassIsGeneric(klass)) return;
    if (gClassIsInflated && gClassIsInflated(klass)) return;
    const char *name = gClassGetName(klass);
    if (gDebug) PearLog(@"[PearRuntime][usercentrics] scanning %s.%s", ns, name);

    void *iter = NULL;
    while (YES) {
        void *method = gClassGetMethods(klass, &iter);
        if (!method) break;

        const char *methodName = gMethodGetName(method);
        if (!methodName) continue;
        if (gDebug) {
            void *ret = gMethodGetReturnType(method);
            PearLog(@"[PearRuntime][usercentrics] method %s.%s::%s kind=%d",
                    ns, name, methodName, (ret && gTypeGetType) ? gTypeGetType(ret) : -1);
        }
        if (!PearMethodReturnsVoid(method)) continue;

        void **slot = (void **)method;
        if (strcmp(methodName, "Initialize") == 0) {
            // The replacement takes (self, callback), so only a one-argument
            // method can be replaced. Patching an overload with a different
            // arity would misread its arguments and crash.
            if (gStatusClass && gStatusCtor && gOnInitializedInvoke &&
                gMethodGetParamCount(method) == 1) {
                BOOL isStatic = gMethodIsInstance ? !gMethodIsInstance(method) : NO;
                *slot = isStatic ? (void *)&PearUsercentricsInitializeStatic
                                 : (void *)&PearUsercentricsInitialize;
                ctx->patched++;
                PearLog(@"[PearRuntime][usercentrics] replaced %s.%s::%s%s",
                        ns, name, methodName, isStatic ? " (static)" : "");
            } else {
                // Leave it alone rather than no-op it: a no-op would never
                // invoke the callback and the app would wait forever.
                PearLog(@"[PearRuntime][usercentrics] left %s.%s::%s alone "
                        "(metadata incomplete)", ns, name, methodName);
            }
            continue;
        }
        if (PearIsUiEntryPoint(methodName)) {
            *slot = (void *)&PearUsercentricsNoop;
            ctx->patched++;
            PearLog(@"[PearRuntime][usercentrics] skipped %s.%s::%s", ns, name, methodName);
        }
    }
}

static void PearLogClassImageCallback(void *klass, void *userData) {
    if (!gDebug) return;
    const char *ns = gClassGetNamespace(klass);
    if (!PearIsUsercentricsClass(ns)) return;
    const char *name = gClassGetName(klass);
    void *image = gClassGetImage ? gClassGetImage(klass) : NULL;
    const char *imageName = (image && gImageGetName) ? gImageGetName(image) : "?";
    PearLog(@"[PearRuntime][usercentrics] found %s.%s image=%s", ns, name, imageName);
}

static void PearInstallUsercentricsShim(void) {
    if (gInstalled) return;
    if (!PearResolveIL2CPP()) {
        if (!gLoggedResolveFailure) {
            gLoggedResolveFailure = YES;
            PearLog(@"[PearRuntime][usercentrics] IL2CPP exports not available yet");
        }
        return;
    }

    // Calling into IL2CPP before il2cpp_init has finished dereferences null
    // globals; il2cpp_get_corlib() is the documented readiness check.
    if (!gGetCorlib()) return;
    if (!gLoggedCorlib) {
        gLoggedCorlib = YES;
        PearLog(@"[PearRuntime][usercentrics] IL2CPP corlib resolved");
    }

    void *domain = gDomainGet();
    if (!domain) {
        if (!gLoggedDomainMissing) {
            gLoggedDomainMissing = YES;
            PearLog(@"[PearRuntime][usercentrics] IL2CPP domain not ready yet");
        }
        return;
    }

    // The IL2CPP API requires the calling thread to be attached to the domain;
    // calling it from a bare dispatch thread aborts inside the runtime.
    gThreadAttach(domain);

    // Discover the consent classes by walking every class in the domain. Some
    // Unity builds do not export il2cpp_domain_get_assemblies, and the classes
    // can live in more than one assembly, so a class walk is both portable and
    // complete. Throttle it: the poll runs every 10 ms and a full walk is not
    // free.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastScanTime < 0.1) return;
    gLastScanTime = now;

    void *image = NULL;
    void *statusClass = PearFindClassAnywhere("UsercentricsStatus", "Usercentrics", &image);
    if (!statusClass || !image) {
        if (!gLoggedAssemblyMissing) {
            gLoggedAssemblyMissing = YES;
            PearLog(@"[PearRuntime][usercentrics] consent assembly not loaded yet");
        }
        return;
    }

    size_t classCount = gImageGetClassCount(image);

    // Metadata for the Initialize replacement.
    void *onInitialized = PearFindClass(image, classCount, "", "OnInitialized");
    gStatusClass = statusClass;
    gStatusCtor = PearFindMethod(statusClass, ".ctor", 0);
    gShouldCollectField = PearFindField(statusClass, "ShouldCollectConsent");
    gBannerRequiredField = PearFindField(statusClass, "BannerRequiredAtLocation");
    gActiveSettingsField = PearFindField(statusClass, "ActiveSettingsId");
    gCountryField = PearFindField(statusClass, "CountryCode");
    gRegionField = PearFindField(statusClass, "RegionCode");
    gServiceConsentsField = PearFindField(statusClass, "ServiceConsents");
    PearDumpFields(statusClass);
    if (onInitialized) {
        gOnInitializedInvoke = PearFindMethod(onInitialized, "Invoke", 2);
    }

    // The app listens to PrivacyEventsApple.OnInitialized(string, string).
    void *privacyImage = NULL;
    void *privacyEvents = PearFindClassAnywhere("PrivacyEventsApple", NULL, &privacyImage);
    if (privacyEvents) {
        gPrivacyOnInitialized = PearFindMethod(privacyEvents, "OnInitialized", 2);
        PearDumpFields(privacyEvents);
    }
    if (privacyImage) {
        size_t privacyCount = gImageGetClassCount(privacyImage);

        // The app's privacy gate is PrivacyManager.IsReady(). The native
        // privacy SDK cannot initialise here, so report ready directly.
        void *privacyManager = PearFindClass(privacyImage, privacyCount, NULL, "PrivacyManager");
        void *isReady = privacyManager ? PearFindMethod(privacyManager, "IsReady", 0) : NULL;
        PearDumpFields(privacyManager);
        PearLog(@"[PearRuntime][usercentrics] privacy image=%p manager=%p isReady=%p",
                privacyImage, privacyManager, isReady);
        // Note: do not force IsReady here. The app creates its main UI after
        // the privacy screen dismisses through the normal callback; forcing the
        // flag makes it skip both and run headless.
    }

    // Log which image owns each consent class once, so a device run shows why
    // a patch walk may miss them.
    if (!gLoggedClassImages) {
        gLoggedClassImages = YES;
        gClassForEach(PearLogClassImageCallback, NULL);
    }

    PearPatchContext patch = { 0 };
    gClassForEach(PearPatchClassCallback, &patch);
    int patched = patch.patched;

    if (patched > 0) {
        gInstalled = YES;
        PearLog(@"[PearRuntime][usercentrics] %d consent entry point(s) disabled", patched);

        // The privacy service subscribes after start-up; fire a few times so
        // one lands after it is listening.
        // Unity API calls must run on the main thread; invoking the game's
        // event from a worker corrupts its UI state.
        for (int i = 5; i <= 30; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @autoreleasepool { PearFirePrivacyInitialized(); }
            });
        }
    } else if (!gLoggedNoMatch) {
        gLoggedNoMatch = YES;
        PearLog(@"[PearRuntime][usercentrics] assembly loaded but no entry points matched");
    }
}

static void PearScheduleUsercentricsShim(void) {
    NSDictionary *env = NSProcessInfo.processInfo.environment;
    if (env[@"PEAR_NO_USERCENTRICS_SHIM"]) return;
    gDebug = env[@"PEAR_DEBUG_USERCENTRICS"] != nil;
    PearLog(@"[PearRuntime][usercentrics] shim scheduled");

    // If IL2CPP and the assembly are already up (the runtime can be loaded
    // after UnityFramework's constructor), patch before the game's first call.
    PearInstallUsercentricsShim();

    // The assembly is loaded after IL2CPP starts, often several seconds in
    // (the surrounding SDK initialisation can take ~7 s), but a cold launch can
    // take minutes before IL2CPP is ready. Poll until installed rather than for
    // a fixed window; a fixed window silently gives up on a slow launch. Use a
    // background queue: the app's main thread is busy loading and would delay
    // (or never run) a main-queue timer before the consent crash.
    dispatch_queue_t queue = dispatch_queue_create("com.pearsilicon.usercentrics", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                              250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    __block int attempts = 0;
    dispatch_source_set_event_handler(timer, ^{
        @autoreleasepool {
            // 2400 * 250 ms = 10 minutes: long enough for a cold launch, short
            // enough that the timer does not outlive the consent flow.
            if (gInstalled || attempts++ >= 2400) {
                dispatch_source_cancel(timer);
                return;
            }
            PearInstallUsercentricsShim();
        }
    });
    dispatch_resume(timer);
}

__attribute__((constructor))
static void PearUsercentricsShimInit(void) {
    @autoreleasepool {
        PearScheduleUsercentricsShim();
    }
}
