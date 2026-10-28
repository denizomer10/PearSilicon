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
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach/vm_statistics.h>
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

#pragma mark - Diagnostics

/// Logs the call site of GarageBand's audio-failure alert. Debug builds only;
/// the alert is never altered, only inspected.
static void PearInstallAlertLogging(void) {
    if (!PearServicesDebug()) return;
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    Class alertClass = objc_getClass("UIAlertController");
    if (!alertClass) return;
    SEL selector = @selector(alertControllerWithTitle:message:preferredStyle:);
    Method method = class_getClassMethod(alertClass, selector);
    if (!method) return;
    IMP original = method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^id(id self, NSString *title, NSString *message, NSInteger style) {
        if ((message && [message containsString:@"audio system"]) ||
            (title && [title containsString:@"Unavailable"])) {
            PearLog([NSString stringWithFormat:@"[PearRuntime][diagnostic] alert title=%@ message=%@", title, message]);
            for (NSString *line in [NSThread callStackSymbols]) {
                PearLog([NSString stringWithFormat:@"[PearRuntime][diagnostic]   %@", line]);
            }
        }
        return ((id (*)(id, SEL, NSString *, NSString *, NSInteger))original)(self, selector, title, message, style);
    }));
}

#pragma mark - Process memory

// iOS reports a per-process jetsam budget through os_proc_available_memory().
// macOS has no such limit, so the symbol the Catalyst app imports is not
// provided by any host library: dyld aborts at launch with a missing-symbol
// error. The app imports the C++-mangled name (the iOSSupport header declares
// it as C++), so this definition must have C++ linkage as well.
static size_t PearAvailableProcessMemory(void) {
    mach_port_t host = mach_host_self();
    vm_size_t pageSize = 0;
    if (host_page_size(host, &pageSize) != KERN_SUCCESS || pageSize == 0) {
        pageSize = 4096;
    }
    vm_statistics64_data_t stats = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&stats, &count) == KERN_SUCCESS) {
        uint64_t pages = (uint64_t)stats.free_count
                       + (uint64_t)stats.inactive_count
                       + (uint64_t)stats.speculative_count
                       + (uint64_t)stats.purgeable_count;
        return (size_t)(pages * (uint64_t)pageSize);
    }
    return (size_t)NSProcessInfo.processInfo.physicalMemory;
}

// The main binary calls the C symbol, which the host does export — as a stub
// that always returns 0. Redirect it to the real host value. (The interpose
// entry references libSystem's stub, so the C symbol itself is not defined
// here.)
extern "C" size_t os_proc_available_memory(void);

static size_t PearOSProcAvailableMemory(void) {
    return PearAvailableProcessMemory();
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeProcAvailableMemory
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearOSProcAvailableMemory,
        (const void *)(uintptr_t)&os_proc_available_memory
    };

// Deliberately C++ linkage: a bundled framework imports this symbol as
// __Z24os_proc_available_memoryv, which no host library provides. The C name
// above is left undefined so the interpose entry can target libSystem's stub.
extern "C" size_t PearMangledProcAvailableMemory(void) __asm__("__Z24os_proc_available_memoryv");

extern "C" size_t PearMangledProcAvailableMemory(void) {
    size_t available = PearAvailableProcessMemory();
    if (PearServicesDebug()) {
        static BOOL logged = NO;
        if (!logged) {
            logged = YES;
            PearLog([NSString stringWithFormat:@"[PearRuntime][memory] available=%zu MB",
                     available / (1024 * 1024)]);
        }
    }
    return available;
}

#pragma mark - Audio session

// The iOS session's preferred I/O buffer is a request, not a hint: RemoteIO
// runs at that size. A Mac output device defaults to a much larger buffer
// (often 4096 frames), so an iOS engine that allocated for 256 frames returns
// kAudioUnitErr_TooManyFramesToProcess from its render callback and its task
// queue stalls. Apply the requested duration to the default devices for as
// long as this process is alive, then restore the previous sizes.
static AudioDeviceID gSavedOutputDevice = 0;
static UInt32 gSavedOutputFrames = 0;
static AudioDeviceID gSavedInputDevice = 0;
static UInt32 gSavedInputFrames = 0;
static BOOL gDeviceBuffersCaptured = NO;

static AudioDeviceID PearDefaultDevice(AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    AudioDeviceID device = 0;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL,
                                   &size, &device) != noErr) {
        return 0;
    }
    return device;
}

static UInt32 PearDeviceBufferFrames(AudioDeviceID device, AudioObjectPropertyScope scope) {
    if (!device) return 0;
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyBufferFrameSize, scope, kAudioObjectPropertyElementMain
    };
    UInt32 frames = 0;
    UInt32 size = sizeof(frames);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &frames) != noErr) {
        return 0;
    }
    return frames;
}

static void PearSetDeviceBufferFrames(AudioDeviceID device, AudioObjectPropertyScope scope, UInt32 frames) {
    if (!device) return;
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyBufferFrameSize, scope, kAudioObjectPropertyElementMain
    };
    UInt32 value = frames;
    OSStatus status = AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(value), &value);
    if (PearServicesDebug()) {
        AudioObjectPropertyAddress readAddress = address;
        UInt32 actual = 0;
        UInt32 size = sizeof(actual);
        AudioObjectGetPropertyData(device, &readAddress, 0, NULL, &size, &actual);
        PearLog([NSString stringWithFormat:
            @"[PearRuntime][audio] device buffer device=%u scope=%u want=%u status=%d actual=%u",
            (unsigned)device, (unsigned)scope, (unsigned)frames, (int)status, (unsigned)actual]);
    }
}

static void PearRestoreDeviceBuffers(void) {
    if (gSavedOutputFrames) {
        PearSetDeviceBufferFrames(gSavedOutputDevice, kAudioObjectPropertyScopeOutput, gSavedOutputFrames);
    }
    if (gSavedInputFrames) {
        PearSetDeviceBufferFrames(gSavedInputDevice, kAudioObjectPropertyScopeInput, gSavedInputFrames);
    }
}

static void PearApplyPreferredIOBuffer(UInt32 frames) {
    if (frames < 32 || frames > 4096) return;
    if (PearServicesDebug()) {
        PearLog([NSString stringWithFormat:@"[PearRuntime][audio] preferred IO buffer %u frames", (unsigned)frames]);
    }

    if (!gDeviceBuffersCaptured) {
        gDeviceBuffersCaptured = YES;
        gSavedOutputDevice = PearDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice);
        gSavedOutputFrames = PearDeviceBufferFrames(gSavedOutputDevice, kAudioObjectPropertyScopeOutput);
        gSavedInputDevice = PearDefaultDevice(kAudioHardwarePropertyDefaultInputDevice);
        gSavedInputFrames = PearDeviceBufferFrames(gSavedInputDevice, kAudioObjectPropertyScopeInput);
        atexit(PearRestoreDeviceBuffers);
    }

    if (gSavedOutputFrames && gSavedOutputFrames != frames) {
        PearSetDeviceBufferFrames(PearDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
                                  kAudioObjectPropertyScopeOutput, frames);
    }
    if (gSavedInputFrames && gSavedInputFrames != frames) {
        PearSetDeviceBufferFrames(PearDefaultDevice(kAudioHardwarePropertyDefaultInputDevice),
                                  kAudioObjectPropertyScopeInput, frames);
    }
}

static BOOL PearAudioSucceeded(NSError **error) {
    if (error) *error = nil;
    return YES;
}

/// Mirrors the state we report back to the app. The real AVAudioSession on the
/// host never runs the iOS activation path, so its `isActive` stays NO even
/// after `setActive:YES` succeeded — GarageBand treats that as an interruption.
static BOOL gAudioSessionActive = NO;
static NSString *gAudioSessionCategory = nil;
static NSString *gAudioSessionMode = nil;

/// Catalyst apps configure an audio session before starting playback. On a Mac
/// the host audio system already routes the process, so the configuration is
/// accepted instead of failing with a platform error.
static void PearInstallAudioSession(void) {
    Class session = objc_getClass("AVAudioSession");
    if (!session) return;

    PearReplaceInstance(session, @selector(setCategory:error:),
        ^BOOL(id self, NSString *category, NSError **error) {
            gAudioSessionCategory = category;
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setCategory:withOptions:error:),
        ^BOOL(id self, NSString *category, NSUInteger options, NSError **error) {
            gAudioSessionCategory = category;
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setCategory:mode:options:error:),
        ^BOOL(id self, NSString *category, NSString *mode, NSUInteger options, NSError **error) {
            gAudioSessionCategory = category;
            gAudioSessionMode = mode;
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setMode:error:),
        ^BOOL(id self, NSString *mode, NSError **error) {
            gAudioSessionMode = mode;
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setActive:error:),
        ^BOOL(id self, BOOL active, NSError **error) {
            gAudioSessionActive = active;
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setActive:withOptions:error:),
        ^BOOL(id self, BOOL active, NSUInteger options, NSError **error) {
            gAudioSessionActive = active;
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setPreferredSampleRate:error:),
        ^BOOL(id self, double rate, NSError **error) {
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setPreferredIOBufferDuration:error:),
        ^BOOL(id self, double duration, NSError **error) {
            UInt32 frames = (UInt32)(duration * 48000.0 + 0.5);
            PearApplyPreferredIOBuffer(frames);
            return PearAudioSucceeded(error);
        });
    PearReplaceInstance(session, @selector(setPreferredInputNumberOfChannels:error:),
        ^BOOL(id self, NSInteger count, NSError **error) {
            return PearAudioSucceeded(error);
        });

    PearReplaceInstance(session, @selector(category), ^NSString *(id self) {
        return gAudioSessionCategory ?: @"AVAudioSessionCategoryAmbient";
    });
    PearReplaceInstance(session, @selector(mode), ^NSString *(id self) {
        return gAudioSessionMode ?: @"AVAudioSessionModeDefault";
    });
    PearReplaceInstance(session, @selector(isActive), ^BOOL(id self) {
        return gAudioSessionActive;
    });
    // There is no other iOS app competing for the host mixer: macOS mixes all
    // clients. Reporting playback from "another app" makes recording apps
    // conclude that their session was interrupted and quit.
    PearReplaceInstance(session, @selector(isOtherAudioPlaying), ^BOOL(id self) {
        return NO;
    });
    PearReplaceInstance(session, @selector(secondaryAudioShouldBeSilencedHint), ^BOOL(id self) {
        return NO;
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

#pragma mark - RemoteIO

static BOOL PearAudioBoolProperty(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static id PearAudioObjectProperty(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSInteger PearAudioIntegerProperty(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return -1;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(object, selector);
}

/// Diagnostic: log the audio session state and any interruption notification.
/// GarageBand (and other recording apps) quit with "audio system interrupted"
/// when the session layer reports an interruption, so the notifications are
/// worth seeing in the launch log.
static void PearObserveAudioInterruptions(void) {
    if (!PearServicesDebug()) return;
    static BOOL observed = NO;
    if (observed) return;
    observed = YES;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[ @"AVAudioSessionInterruptionNotification",
                              @"AVAudioSessionRouteChangeNotification",
                              @"AVAudioSessionMediaServicesWereResetNotification" ]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(NSNotification *note) {
            PearLog([NSString stringWithFormat:@"[PearRuntime][audio] %@ %@",
                     note.name, note.userInfo ?: @{}]);
        }];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Class sessionClass = NSClassFromString(@"AVAudioSession");
        id session = sessionClass ? ((id (*)(id, SEL))objc_msgSend)(sessionClass,
                                                                   @selector(sharedInstance)) : nil;
        if (!session) return;
        PearLog([NSString stringWithFormat:
            @"[PearRuntime][audio] session active=%@ otherAudio=%@ category=%@ mode=%@ inputAvailable=%@ outputChannels=%@",
            @(PearAudioBoolProperty(session, @"isActive")),
            @(PearAudioBoolProperty(session, @"isOtherAudioPlaying")),
            PearAudioObjectProperty(session, @"category") ?: @"?",
            PearAudioObjectProperty(session, @"mode") ?: @"?",
            @(PearAudioBoolProperty(session, @"isInputAvailable")),
            @(PearAudioIntegerProperty(session, @"outputNumberOfChannels"))]);
    });
}

// iOS audio graphs open the RemoteIO output unit. macOS has no component with
// that subtype; its VoiceProcessingIO unit provides the same duplex I/O
// elements. Mapping the request keeps an iOS engine's topology intact while
// using the host's audio device. No audio is synthesized; the engine still
// talks to the real device.
static const UInt32 PearAudioTypeOutput = 0x61756F75;          // 'auou'
static const UInt32 PearAudioSubtypeRemoteIO = 0x72696F63;      // 'rioc'
static const UInt32 PearAudioSubtypeVoiceProcessing = 0x7670696F; // 'vpio'
static const UInt32 PearAudioSubtypeDefaultOutput = 0x64656620; // 'def '
static const UInt32 PearAudioSubtypeHALOutput = 0x6168616C;     // 'ahal'

static AudioComponent gRemoteIOAliases[8];
static int gRemoteIOAliasCount = 0;

/// The host unit used for RemoteIO requests. HAL Output is the desktop sibling
/// of RemoteIO (same duplex element layout: 0 = output, 1 = input), so an iOS
/// engine's topology carries over unchanged. VoiceProcessingIO also has the
/// topology but installs its own echo-cancellation render path; GarageBand's
/// private CRemoteIODriver assumes it owns the unit and then frees state that
/// belongs to vpio at teardown. `PEAR_REMOTEIO_SUBTYPE` selects another host
/// unit for diagnosis (`hal`, `vpio`, `default`, `none`).
static UInt32 PearRemoteIOHostSubtype(void) {
    const char *value = getenv("PEAR_REMOTEIO_SUBTYPE");
    if (!value || !value[0]) return PearAudioSubtypeHALOutput;
    if (strcmp(value, "vpio") == 0) return PearAudioSubtypeVoiceProcessing;
    if (strcmp(value, "default") == 0 || strcmp(value, "def") == 0) return PearAudioSubtypeDefaultOutput;
    if (strcmp(value, "none") == 0) return 0;
    return PearAudioSubtypeHALOutput;
}

static AudioComponent PearAudioComponentFindNext(AudioComponent existing,
                                                 const AudioComponentDescription *description);
static OSStatus PearAudioComponentGetDescription(AudioComponent component,
                                                  AudioComponentDescription *description);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeAudioFindNext
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearAudioComponentFindNext,
        (const void *)(uintptr_t)&AudioComponentFindNext
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeAudioGetDescription
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearAudioComponentGetDescription,
        (const void *)(uintptr_t)&AudioComponentGetDescription
    };

static void PearRememberRemoteIOAlias(AudioComponent component) {
    for (int i = 0; i < gRemoteIOAliasCount; i++) {
        if (gRemoteIOAliases[i] == component) return;
    }
    if (gRemoteIOAliasCount < 8) {
        gRemoteIOAliases[gRemoteIOAliasCount++] = component;
    }
}

static AudioComponent PearAudioComponentFindNext(AudioComponent existing,
                                                 const AudioComponentDescription *description) {
    AudioComponent (*original)(AudioComponent, const AudioComponentDescription *) =
        (AudioComponent (*)(AudioComponent, const AudioComponentDescription *))
            kInterposeAudioFindNext.replacee;

    if (description &&
        description->componentType == PearAudioTypeOutput &&
        description->componentSubType == PearAudioSubtypeRemoteIO) {
        UInt32 hostSubtype = PearRemoteIOHostSubtype();
        if (hostSubtype == 0) return original ? original(existing, description) : NULL;

        AudioComponentDescription patched = *description;
        patched.componentSubType = hostSubtype;
        AudioComponent component = original ? original(existing, &patched) : NULL;
        if (!component && hostSubtype != PearAudioSubtypeVoiceProcessing) {
            patched.componentSubType = PearAudioSubtypeVoiceProcessing;
            component = original ? original(existing, &patched) : NULL;
        }
        if (!component && hostSubtype != PearAudioSubtypeDefaultOutput) {
            patched.componentSubType = PearAudioSubtypeDefaultOutput;
            component = original ? original(existing, &patched) : NULL;
        }
        if (component) {
            PearRememberRemoteIOAlias(component);
            if (PearServicesDebug()) {
                static BOOL loggedMapping = NO;
                if (!loggedMapping) {
                    loggedMapping = YES;
                    char subtype[5] = {0};
                    UInt32 mapped = hostSubtype;
                    subtype[0] = (char)(mapped >> 24);
                    subtype[1] = (char)(mapped >> 16);
                    subtype[2] = (char)(mapped >> 8);
                    subtype[3] = (char)mapped;
                    PearLog([NSString stringWithFormat:@"[PearRuntime][audio] RemoteIO mapped to host unit '%s'", subtype]);
                }
            }
            return component;
        }
    }

    return original ? original(existing, description) : NULL;
}

static OSStatus PearAudioComponentGetDescription(AudioComponent component,
                                                  AudioComponentDescription *description) {
    OSStatus (*original)(AudioComponent, AudioComponentDescription *) =
        (OSStatus (*)(AudioComponent, AudioComponentDescription *))
            kInterposeAudioGetDescription.replacee;
    OSStatus status = original ? original(component, description) : -1;
    if (status == noErr && description) {
        for (int i = 0; i < gRemoteIOAliasCount; i++) {
            if (gRemoteIOAliases[i] == component) {
                description->componentSubType = PearAudioSubtypeRemoteIO;
                break;
            }
        }
    }
    return status;
}

#pragma mark - Audio unit diagnostics

static void PearAudioUnitFourCC(UInt32 value, char out[5]) {
    out[0] = (char)(value >> 24);
    out[1] = (char)(value >> 16);
    out[2] = (char)(value >> 8);
    out[3] = (char)value;
    out[4] = 0;
    for (int i = 0; i < 4; i++) {
        if (out[i] < 0x20 || out[i] > 0x7e) out[i] = '?';
    }
}

static void PearLogAudioUnitStatus(const char *call, AudioUnit unit, OSStatus status,
                                   const char *detail) {
    if (!PearServicesDebug()) return;
    char type[5], subtype[5];
    AudioComponentDescription description = {0};
    AudioComponent component = unit ? AudioComponentInstanceGetComponent(unit) : NULL;
    if (component) AudioComponentGetDescription(component, &description);
    PearAudioUnitFourCC(description.componentType, type);
    PearAudioUnitFourCC(description.componentSubType, subtype);
    PearLog([NSString stringWithFormat:@"[PearRuntime][audio] %s unit=%p %s/%s status=%d %s",
             call, unit, type, subtype, (int)status, detail ?: ""]);
}

static OSStatus PearAudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID propertyID,
                                         AudioUnitScope scope, AudioUnitElement element,
                                         const void *data, UInt32 dataSize);
static OSStatus PearAudioUnitGetProperty(AudioUnit unit, AudioUnitPropertyID propertyID,
                                         AudioUnitScope scope, AudioUnitElement element,
                                         void *data, UInt32 *dataSize);
static OSStatus PearAudioUnitInitialize(AudioUnit unit);
static OSStatus PearAudioUnitUninitialize(AudioUnit unit);
static OSStatus PearAudioOutputUnitStart(AudioUnit unit);
static OSStatus PearAudioOutputUnitStop(AudioUnit unit);
static OSStatus PearAudioComponentInstanceNew(AudioComponent component, AudioUnit *outInstance);
static OSStatus PearAudioComponentInstanceDispose(AudioUnit unit);

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeAudioUnitSetProperty
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearAudioUnitSetProperty,
        (const void *)(uintptr_t)&AudioUnitSetProperty
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeAudioUnitGetProperty
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearAudioUnitGetProperty,
        (const void *)(uintptr_t)&AudioUnitGetProperty
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeAudioUnitInitialize
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearAudioUnitInitialize,
        (const void *)(uintptr_t)&AudioUnitInitialize
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeAudioUnitUninitialize
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearAudioUnitUninitialize,
        (const void *)(uintptr_t)&AudioUnitUninitialize
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeAudioOutputUnitStart
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearAudioOutputUnitStart,
        (const void *)(uintptr_t)&AudioOutputUnitStart
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeAudioOutputUnitStop
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearAudioOutputUnitStop,
        (const void *)(uintptr_t)&AudioOutputUnitStop
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeAudioComponentInstanceNew
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearAudioComponentInstanceNew,
        (const void *)(uintptr_t)&AudioComponentInstanceNew
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} kInterposeAudioComponentInstanceDispose
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)(uintptr_t)&PearAudioComponentInstanceDispose,
        (const void *)(uintptr_t)&AudioComponentInstanceDispose
    };

static OSStatus PearAudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID propertyID,
                                         AudioUnitScope scope, AudioUnitElement element,
                                         const void *data, UInt32 dataSize) {
    OSStatus (*original)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32) =
        (OSStatus (*)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32))
            kInterposeAudioUnitSetProperty.replacee;

    OSStatus status = original ? original(unit, propertyID, scope, element, data, dataSize) : -1;

    // The host output unit is configured for the engine's slice size. Match the
    // hardware buffer to it so the render callback is never asked for more
    // frames than it allocated (otherwise it returns -10874).
    if (status == noErr && propertyID == 14 && data && dataSize >= sizeof(UInt32)) {
        AudioComponentDescription description = {0};
        AudioComponent component = unit ? AudioComponentInstanceGetComponent(unit) : NULL;
        if (component) AudioComponentGetDescription(component, &description);
        BOOL isHostUnit = description.componentType == PearAudioTypeOutput;
        if (isHostUnit) PearApplyPreferredIOBuffer(*(const UInt32 *)data);
    }
    if (PearServicesDebug()) {
        char property[5];
        PearAudioUnitFourCC(propertyID, property);
        PearLogAudioUnitStatus(status == noErr ? "SetProperty" : "SetProperty!", unit, status,
            [[NSString stringWithFormat:@"property=%s(%u) scope=%u element=%u size=%u value=%u",
              property, (unsigned)propertyID, (unsigned)scope, (unsigned)element, (unsigned)dataSize,
              (data && dataSize >= 4) ? *(const UInt32 *)data : 0] UTF8String]);
    }
    return status;
}

static OSStatus PearAudioUnitGetProperty(AudioUnit unit, AudioUnitPropertyID propertyID,
                                         AudioUnitScope scope, AudioUnitElement element,
                                         void *data, UInt32 *dataSize) {
    OSStatus (*original)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, void *, UInt32 *) =
        (OSStatus (*)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, void *, UInt32 *))
            kInterposeAudioUnitGetProperty.replacee;
    OSStatus status = original ? original(unit, propertyID, scope, element, data, dataSize) : -1;
    if (PearServicesDebug()) {
        char property[5];
        PearAudioUnitFourCC(propertyID, property);
        PearLogAudioUnitStatus(status == noErr ? "GetProperty" : "GetProperty!", unit, status,
            [[NSString stringWithFormat:@"property=%s(%u) scope=%u element=%u size=%u value=%u",
              property, (unsigned)propertyID, (unsigned)scope, (unsigned)element,
              dataSize ? *dataSize : 0,
              (data && dataSize && *dataSize >= 4 && status == noErr) ? *(const UInt32 *)data : 0] UTF8String]);
    }
    return status;
}

static OSStatus PearAudioUnitInitialize(AudioUnit unit) {
    OSStatus (*original)(AudioUnit) =
        (OSStatus (*)(AudioUnit))kInterposeAudioUnitInitialize.replacee;
    OSStatus status = original ? original(unit) : -1;
    PearLogAudioUnitStatus("Initialize", unit, status, status == noErr ? "ok" : "failed");
    return status;
}

static OSStatus PearAudioUnitUninitialize(AudioUnit unit) {
    OSStatus (*original)(AudioUnit) =
        (OSStatus (*)(AudioUnit))kInterposeAudioUnitUninitialize.replacee;
    OSStatus status = original ? original(unit) : -1;
    PearLogAudioUnitStatus("Uninitialize", unit, status, "");
    return status;
}

static OSStatus PearAudioOutputUnitStart(AudioUnit unit) {
    OSStatus (*original)(AudioUnit) =
        (OSStatus (*)(AudioUnit))kInterposeAudioOutputUnitStart.replacee;
    OSStatus status = original ? original(unit) : -1;
    PearLogAudioUnitStatus("Start", unit, status, status == noErr ? "ok" : "failed");
    return status;
}

static OSStatus PearAudioOutputUnitStop(AudioUnit unit) {
    OSStatus (*original)(AudioUnit) =
        (OSStatus (*)(AudioUnit))kInterposeAudioOutputUnitStop.replacee;
    OSStatus status = original ? original(unit) : -1;
    PearLogAudioUnitStatus("Stop", unit, status, "");
    return status;
}

static OSStatus PearAudioComponentInstanceNew(AudioComponent component, AudioUnit *outInstance) {
    OSStatus (*original)(AudioComponent, AudioUnit *) =
        (OSStatus (*)(AudioComponent, AudioUnit *))kInterposeAudioComponentInstanceNew.replacee;
    OSStatus status = original ? original(component, outInstance) : -1;
    if (PearServicesDebug()) {
        AudioComponentDescription description = {0};
        if (component) AudioComponentGetDescription(component, &description);
        char type[5], subtype[5];
        PearAudioUnitFourCC(description.componentType, type);
        PearAudioUnitFourCC(description.componentSubType, subtype);
        PearLog([NSString stringWithFormat:@"[PearRuntime][audio] InstanceNew %s/%s status=%d instance=%p",
                 type, subtype, (int)status, outInstance ? *outInstance : NULL]);
    }
    return status;
}

static OSStatus PearAudioComponentInstanceDispose(AudioUnit unit) {
    OSStatus (*original)(AudioUnit) =
        (OSStatus (*)(AudioUnit))kInterposeAudioComponentInstanceDispose.replacee;
    PearLogAudioUnitStatus("Dispose", unit, 0, "");
    return original ? original(unit) : -1;
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
        PearObserveAudioInterruptions();
        PearInstallAlertLogging();
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
                PearObserveAudioInterruptions();
                PearInstallAlertLogging();
                PearInstallHaptics();
                PearInstallStoreSurface();
                PearInstallRemoteNotifications();
                PearInstallARAvailability();
                PearInstallBackgroundTasks();
            }
        });
    }
}
