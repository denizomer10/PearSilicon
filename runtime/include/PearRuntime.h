// PearRuntime.h
// Runtime that translates keyboard/mouse input into synthesized touches for an
// iOS app running on arm64 macOS.
//
// Loaded via an `LC_LOAD_DYLIB` entry in legacy mode, or by the launcher through
// `DYLD_INSERT_LIBRARIES` in experimental host-backed mode, with
//   PEAR_KEYMAP=/path/to/<bundleID>.json
//
// Built for arm64 Mac Catalyst and the system iOSSupport/UIKit runtime.
// API bridging remains in-process. See runtime/build.sh.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Logs like NSLog, and additionally appends to the file named by PEAR_LOG_FILE
/// when set. The unified log redacts dynamic values (geometry, key names) as
/// `<private>`, which makes in-process debugging hard; this gives a readable log.
void PearLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// The per-app log file used when PEAR_LOG_FILE is not set. Also used by the
/// crash-signal diagnostic, which cannot call Foundation from a signal handler.
NSString *PearLogFilePath(void);

/// Reports `size` through the UIScreen geometry and orientation accessors.
/// Used by the GL shim once an app has a fixed drawable, so a Mac window resize
/// (including full screen) does not move the app's coordinate space.
void PearSetScreenOverride(CGSize size);
void PearClearScreenOverride(void);

/// Fixed on first use: presence of PEAR_HOST_SOCKET selects host-authoritative
/// KV for this process, even if the path/token is invalid or the host is down.
/// Only an absent socket selects legacy local KV. Never fall back across modes.
BOOL PearHostIsConfigured(void);

/// Cold-state IPC only; not for input/render/audio. Adds version=1 and the
/// launch token to every bounded binary-plist call and verifies the peer UID.
/// nil means a local/transport/protocol failure (including timeout/backoff).
/// A valid server rejection is returned as a dictionary with ok=false/error.
/// Main-thread calls have a 100 ms budget, other calls 500 ms, including lock
/// waits and all I/O; failed connections have a short reconnect cooldown.
/// No request is replayed after any bytes were sent, even if the ACK was lost.
NSDictionary * _Nullable PearHostCall(NSDictionary *request);

/// Start one cold-state operation budget at entry (100 ms main / 500 ms worker).
/// The absolute deadline is in CLOCK_MONOTONIC nanoseconds. Share it across
/// outer operation gates and IPC; never start another budget after a gate wait.
uint64_t PearHostDeadline(void);
/// On YES the caller owns the semaphore and must signal it. On NO it owns
/// nothing, including when the deadline expires just as the gate is acquired.
BOOL PearHostAcquireUntil(dispatch_semaphore_t gate, uint64_t deadline);
/// Same contract as PearHostCall, but consumes only the inherited budget for
/// the client lock, encoding, connect, and all I/O. Never extends the deadline.
NSDictionary * _Nullable PearHostCallUntil(NSDictionary *request, uint64_t deadline);

/// YES with *value=nil means confirmed missing; NO means unavailable/rejected.
/// Clears the optional out parameter on failure. Values are immutable plists.
BOOL PearHostKVGet(NSString *key, id _Nullable __autoreleasing * _Nullable value);
/// nil deletes by omitting value, not by sending NSNull. YES requires an ACK
/// after host persistence; NO may be an unknown commit outcome, never a replay.
BOOL PearHostKVSet(NSString *key, id _Nullable value);
/// A confirmed snapshot, or nil on failure (an empty dictionary is success).
NSDictionary * _Nullable PearHostKVAll(void);

@interface PearRuntime : NSObject

/// Reads PEAR_KEYMAP, installs input handlers and the on-screen overlay.
/// Called automatically from a constructor when the library is loaded.
+ (void)bootstrap;

@end

NS_ASSUME_NONNULL_END
