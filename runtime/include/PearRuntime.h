// PearRuntime.h
// Runtime that translates keyboard/mouse input into synthesized touches for an
// iOS app running on arm64 macOS.
//
// Loaded into the target process via an `LC_LOAD_DYLIB` entry, with
//   PEAR_KEYMAP=/path/to/<bundleID>.json
//
// This library is built for the iOS SDK (arm64) because the host process is an
// iOS binary, not a macOS one. See runtime/build.sh.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Logs like NSLog, and additionally appends to the file named by PEAR_LOG_FILE
/// when set. The unified log redacts dynamic values (geometry, key names) as
/// `<private>`, which makes in-process debugging hard; this gives a readable log.
void PearLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

@interface PearRuntime : NSObject

/// Reads PEAR_KEYMAP, installs input handlers and the on-screen overlay.
/// Called automatically from a constructor when the library is loaded.
+ (void)bootstrap;

@end

NS_ASSUME_NONNULL_END
