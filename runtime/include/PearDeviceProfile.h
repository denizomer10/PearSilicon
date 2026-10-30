// Startup device identity shared by the early C hooks and Objective-C shims.
// Deliberately independent of PearRuntime.h, Foundation, UIKit, and host IPC.
#ifndef PEAR_DEVICE_PROFILE_H
#define PEAR_DEVICE_PROFILE_H

#ifdef __cplusplus
extern "C" {
#endif

#define PEAR_DEVICE_PROFILE_LEGACY_MAX_BYTES 4095
#define PEAR_DEVICE_PROFILE_BUNDLE_MAX_BYTES 255

typedef enum {
    PearDeviceProfileSourceLegacy = 0,
    PearDeviceProfileSourceHostV1 = 1,
    PearDeviceProfileSourceUnknown = 2
} PearDeviceProfileSource;

typedef enum {
    PearDeviceProfileStatusUnavailable = 0,
    PearDeviceProfileStatusReady = 1,
    PearDeviceProfileStatusInvalidSource = 2,
    PearDeviceProfileStatusMissingField = 3,
    PearDeviceProfileStatusInvalidField = 4,
    PearDeviceProfileStatusTooLong = 5
} PearDeviceProfileStatus;

typedef struct {
    PearDeviceProfileSource source;
    PearDeviceProfileStatus status;
    // Environment key responsible for rejection, or NULL on success.
    const char *invalidField;
    // ALL value pointers are NULL on rejection; no partially accepted profile.
    const char *bundle;
    const char *model;
    const char *name;
    const char *idiom;             // "phone" or "pad"
    const char *systemName;        // "iOS"
    const char *systemVersion;
    const char *systemBuild;
    const char *darwinRelease;
    // Host-computed UUID text. NULL in legacy mode (UIDevice keeps its old seed).
    const char *vendorIdentifier;
} PearDeviceProfile;

// Never returns NULL. Captures the environment once, on first use, using only
// pthread_once, getenv, bounded copies, and pure C validation. No allocation,
// ObjC, Foundation, files, IPC, constructors, or dynamic C++ initialization.
// Returned storage lives for the process; later environment edits are ignored.
// As with getenv itself, do not mutate environ concurrently with FIRST capture.
// The initializer has no callbacks/reentrant APIs and never calls a device hook.
//
// Absent source AND absent metadata select legacy defaults/nonempty overrides.
// Legacy text is kept verbatim up to LEGACY_MAX_BYTES, never silently truncated;
// oversized overrides reject the whole snapshot. This is an intentional safety
// bound on the previously unbounded legacy inputs, not host-style validation.
// Any source/metadata presence selects managed validation: only host-v1, a
// complete canonical six-field profile, bundle, and UUID are accepted. Unknown
// sources, orphan metadata, or bad fields remain unavailable for this process.
const PearDeviceProfile *PearDeviceProfileGet(void);

#ifdef __cplusplus
}
#endif
#endif
