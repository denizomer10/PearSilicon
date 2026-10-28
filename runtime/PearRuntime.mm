// PearRuntime.mm
//
// The runtime. It does exactly two things: load the keymap, and turn keyboard
// input into synthesized touches (see TouchSynthesizer.mm). It adds no UI to the
// game — the keymapper UI is owned and drawn by PearSilicon.app as its own
// overlay window, keeping this process's footprint minimal.

#import "PearRuntime.h"
#import <GameController/GameController.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <os/log.h>
#import <pwd.h>
#import <unistd.h>

/// The log file used when the launcher did not pass PEAR_LOG_FILE. GUI launches
/// need the same trace as `--log` runs, otherwise an exception inside a third
/// party crash reporter leaves no actionable information behind.
NSString *PearLogFilePath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *home = getpwuid(getuid()) ? getpwuid(getuid())->pw_dir : NULL;
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        if (!home || bundleID.length == 0) return;
        NSString *directory = [NSString stringWithFormat:
            @"%s/Library/Application Support/PearSilicon/Logs", home];
        [NSFileManager.defaultManager createDirectoryAtPath:directory
                               withIntermediateDirectories:YES attributes:nil error:NULL];
        path = [directory stringByAppendingPathComponent:
                [bundleID stringByAppendingString:@".log"]];
    });
    return path;
}

void PearLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    // Emit as public: the unified log redacts dynamic `%@` arguments as
    // `<private>`, which would hide everything we care about. Also mirror to a
    // file when PEAR_LOG_FILE is set.
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handle = os_log_create("com.pearsilicon.runtime", "general"); });
    os_log_with_type(handle, OS_LOG_TYPE_DEFAULT, "%{public}s", message.UTF8String);

    const char *path = getenv("PEAR_LOG_FILE");
    if (!path) path = PearLogFilePath().fileSystemRepresentation;
    if (path) {
        FILE *file = fopen(path, "a");
        if (file) {
            fprintf(file, "%s\n", message.UTF8String);
            fclose(file);
        }
    }
}

#pragma mark - Keymap model

typedef NS_ENUM(NSInteger, PearActionKind) {
    PearActionKindTap = 0,
    PearActionKindHold,
    PearActionKindJoystick,
    PearActionKindMouseLook,
    PearActionKindSwipe,
};

@interface PearBinding : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic) PearActionKind kind;
@property (nonatomic) CGPoint point;      // normalized, for tap/hold/joystick
@property (nonatomic) CGRect region;      // normalized, for mouseLook
@property (nonatomic) CGFloat radius;
@property (nonatomic) CGFloat sensitivity;
@property (nonatomic) CGPoint swipeFrom;  // normalized, for swipe
@property (nonatomic) CGPoint swipeTo;
@property (nonatomic) CGFloat swipeDuration;
@end

@implementation PearBinding
@end

static NSArray<PearBinding *> *gBindings = nil;

static NSString *KeyNameForCode(GCKeyCode code);

static PearBinding *BindingForKey(NSString *key) {
    for (PearBinding *b in gBindings) {
        if ([b.key caseInsensitiveCompare:key] == NSOrderedSame) return b;
    }
    return nil;
}

#pragma mark - Keymap loading

static PearActionKind KindFromString(NSString *s) {
    if ([s isEqualToString:@"hold"]) return PearActionKindHold;
    if ([s isEqualToString:@"joystick"]) return PearActionKindJoystick;
    if ([s isEqualToString:@"mouseLook"]) return PearActionKindMouseLook;
    if ([s isEqualToString:@"swipe"]) return PearActionKindSwipe;
    return PearActionKindTap;
}

static NSArray<PearBinding *> *LoadKeymap(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) { PearLog(@"[PearRuntime] keymap not found at %@", path); return @[]; }

    NSError *error = nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![root isKindOfClass:NSDictionary.class]) {
        PearLog(@"[PearRuntime] invalid keymap: %@", error);
        return @[];
    }

    NSMutableArray<PearBinding *> *result = [NSMutableArray array];
    for (NSDictionary *raw in root[@"bindings"]) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;

        PearBinding *binding = [PearBinding new];
        binding.key = raw[@"key"] ?: @"";

        NSDictionary *action = raw[@"action"];
        if ([action isKindOfClass:NSDictionary.class]) {
            NSDictionary *payload = action[action.allKeys.firstObject];
            binding.kind = KindFromString(action.allKeys.firstObject);

            if ([payload isKindOfClass:NSDictionary.class]) {
                if (payload[@"center"]) {
                    NSDictionary *c = payload[@"center"];
                    binding.point = CGPointMake([c[@"x"] doubleValue], [c[@"y"] doubleValue]);
                    binding.radius = [payload[@"radius"] doubleValue];
                } else if (payload[@"region"]) {
                    NSDictionary *r = payload[@"region"];
                    binding.region = CGRectMake([r[@"x"] doubleValue], [r[@"y"] doubleValue],
                                                [r[@"width"] doubleValue], [r[@"height"] doubleValue]);
                    binding.sensitivity = [payload[@"sensitivity"] doubleValue] ?: 1.0;
                } else if (payload[@"from"] || payload[@"to"]) {
                    NSDictionary *f = payload[@"from"];
                    NSDictionary *t = payload[@"to"];
                    binding.swipeFrom = CGPointMake([f[@"x"] doubleValue], [f[@"y"] doubleValue]);
                    binding.swipeTo = CGPointMake([t[@"x"] doubleValue], [t[@"y"] doubleValue]);
                    binding.swipeDuration = [payload[@"duration"] doubleValue] ?: 0.25;
                } else if (payload[@"_0"]) {
                    NSDictionary *p = payload[@"_0"];
                    binding.point = CGPointMake([p[@"x"] doubleValue], [p[@"y"] doubleValue]);
                } else {
                    binding.point = CGPointMake([payload[@"x"] doubleValue], [payload[@"y"] doubleValue]);
                }
            }
        }
        [result addObject:binding];
    }
    return result;
}

#pragma mark - Touch synthesis

// Touch is produced by the platform's own virtual-touch machinery on macOS
// (`UINSVirtualDigitizer`, implemented in TouchSynthesizer.mm). Each binding drives
// a *named* finger, so multiple bindings can be down at once (real multi-touch).
extern void PearSynthesizeVirtualFinger(BOOL down, NSString *key, CGFloat nx, CGFloat ny);
extern void PearSynthesizeTapCGEvent(CGFloat nx, CGFloat ny);
extern void PearContainCursorInWindow(void);

/// A stable virtual-finger name per binding, so its hold/joystick occupies its
/// own finger and can run alongside others.
static NSString *FingerKeyForBinding(PearBinding *binding) {
    return [@"f:" stringByAppendingString:binding.key.lowercaseString];
}

/// A swipe: a finger presses at `from` and drags to `to` over `duration`, then
/// lifts. Interpolated with our own finger posts so it does not depend on the
/// private swipe helper's exact semantics.
static void SynthesizeSwipe(PearBinding *binding) {
    NSString *key = FingerKeyForBinding(binding);
    CGPoint from = binding.swipeFrom;
    CGPoint to = binding.swipeTo;
    double duration = binding.swipeDuration > 0 ? binding.swipeDuration : 0.25;
    const int steps = 14;

    PearSynthesizeVirtualFinger(YES, key, from.x, from.y);
    for (int i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        double nx = from.x + (to.x - from.x) * t;
        double ny = from.y + (to.y - from.y) * t;
        int64_t delay = (int64_t)(t * duration * NSEC_PER_SEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
            PearSynthesizeVirtualFinger(YES, key, nx, ny);
            if (i == steps) PearSynthesizeVirtualFinger(NO, key, nx, ny);
        });
    }
}

static void SynthesizeTouch(PearBinding *binding, BOOL down, CGPoint point) {
    switch (binding.kind) {
        case PearActionKindTap:
            // A tap is a complete gesture: only fire on the press, so a key-down
            // produces exactly one down/up pair.
            if (down) {
                NSString *key = FingerKeyForBinding(binding);
                PearSynthesizeVirtualFinger(YES, key, point.x, point.y);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    PearSynthesizeVirtualFinger(NO, key, point.x, point.y);
                });
            }
            break;
        case PearActionKindHold:
            // Press-hold: a real finger that stays down until the key is released.
            PearSynthesizeVirtualFinger(down, FingerKeyForBinding(binding), point.x, point.y);
            break;
        case PearActionKindSwipe:
            // A swipe is a complete gesture: fire on the press only.
            if (down) SynthesizeSwipe(binding);
            break;
        default:
            break;
    }
}

#pragma mark - Joystick

// W/A/S/D drive a single virtual joystick. A joystick binding's `key` is
// "wasd"; while any of the four keys is held the touch sits at
// `center + direction * radius`, and moving between keys drags the finger.
static PearBinding *gJoystickBinding = nil;
static BOOL gJoyUp = NO, gJoyDown = NO, gJoyLeft = NO, gJoyRight = NO;
static BOOL gJoystickActive = NO;
static CGPoint gJoystickTouch = {0, 0};
static CGPoint gJoystickTarget = {0, 0};
static uint64_t gJoystickGeneration = 0;

static void UpdateJoystick(void) {
    if (!gJoystickBinding) return;

    CGFloat dx = (gJoyRight ? 1.0 : 0.0) - (gJoyLeft ? 1.0 : 0.0);
    CGFloat dy = (gJoyDown ? 1.0 : 0.0) - (gJoyUp ? 1.0 : 0.0);
    CGFloat len = sqrt(dx * dx + dy * dy);
    BOOL want = len > 0;

    CGPoint center = gJoystickBinding.point;
    CGFloat radius = gJoystickBinding.radius;
    if (len > 0) { dx /= len; dy /= len; }
    CGPoint target = CGPointMake(center.x + dx * radius, center.y + dy * radius);

    NSString *key = @"f:joystick";
    if (want && !gJoystickActive) {
        gJoystickActive = YES;
        gJoystickTouch = target;
        gJoystickTarget = target;
        gJoystickGeneration++;
        uint64_t generation = gJoystickGeneration;

        // Touch down at the stick *centre*, then drag to the direction on the
        // next frame. Mobile sticks derive the direction from
        // (current - touchDown): jumping straight to the offset reports a zero
        // vector, so the character does not move.
        PearSynthesizeVirtualFinger(YES, key, center.x, center.y);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gJoystickActive && generation == gJoystickGeneration) {
                PearSynthesizeVirtualFinger(YES, key, gJoystickTarget.x, gJoystickTarget.y);
            }
        });
    } else if (want && gJoystickActive) {
        // Direction changed while held: drag the existing finger.
        gJoystickTouch = target;
        gJoystickTarget = target;
        PearSynthesizeVirtualFinger(YES, key, target.x, target.y);
    } else if (!want && gJoystickActive) {
        gJoystickActive = NO;
        gJoystickGeneration++;
        PearSynthesizeVirtualFinger(NO, key, gJoystickTouch.x, gJoystickTouch.y);
    }
}

#pragma mark - Mouse look

// The right-hand camera: mouse movement drags a finger inside the mouseLook
// region. A finger presses at the region centre on the first movement, drags by
// the movement amount, and lifts shortly after movement stops. When the drag
// would leave the region it lifts and re-presses at the centre, so rotation can
// continue indefinitely.
static PearBinding *gLookBinding = nil;
static NSString *const kPearLookKey = @"f:mouselook";
static BOOL gLookActive = NO;
static CGPoint gLookPoint = {0, 0};
static uint64_t gLookGeneration = 0;
static BOOL gLookFlushScheduled = NO;
static float gLookPendingDx = 0;
static float gLookPendingDy = 0;

// Mouse points -> normalized window units. Tunable: bigger = faster camera.
static const CGFloat kPearLookScale = 0.0015;

static CGPoint LookCenter(void) {
    return CGPointMake(CGRectGetMidX(gLookBinding.region), CGRectGetMidY(gLookBinding.region));
}

static void LookLiftIfIdle(uint64_t generation) {
    if (generation != gLookGeneration || !gLookActive) return;
    gLookActive = NO;
    PearSynthesizeVirtualFinger(NO, kPearLookKey, gLookPoint.x, gLookPoint.y);
}

// Applies the accumulated mouse delta: moves the look finger, re-pressing at the
// region centre when the drag would leave the region (so rotation continues).
static void LookFlush(void) {
    gLookFlushScheduled = NO;
    if (!gLookBinding) return;

    float dx = gLookPendingDx, dy = gLookPendingDy;
    gLookPendingDx = gLookPendingDy = 0;
    if (dx == 0 && dy == 0) return;

    // Only steer while the game is actually in front — GCMouse reports movement
    // globally, so we must not rotate the camera when the game is in the
    // background.
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    CGRect region = gLookBinding.region;
    CGFloat sensitivity = gLookBinding.sensitivity > 0 ? gLookBinding.sensitivity : 1.0;
    CGFloat step = kPearLookScale * sensitivity;

    if (!gLookActive) {
        gLookActive = YES;
        gLookPoint = LookCenter();
        PearSynthesizeVirtualFinger(YES, kPearLookKey, gLookPoint.x, gLookPoint.y);
    }

    CGFloat nx = gLookPoint.x + dx * step;
    CGFloat ny = gLookPoint.y + dy * step;

    if (nx < region.origin.x || nx > CGRectGetMaxX(region) ||
        ny < region.origin.y || ny > CGRectGetMaxY(region)) {
        PearSynthesizeVirtualFinger(NO, kPearLookKey, gLookPoint.x, gLookPoint.y);
        gLookPoint = LookCenter();
        PearSynthesizeVirtualFinger(YES, kPearLookKey, gLookPoint.x, gLookPoint.y);
        nx = MIN(MAX(gLookPoint.x + dx * step, region.origin.x), CGRectGetMaxX(region));
        ny = MIN(MAX(gLookPoint.y + dy * step, region.origin.y), CGRectGetMaxY(region));
    }

    gLookPoint = CGPointMake(nx, ny);
    PearSynthesizeVirtualFinger(YES, kPearLookKey, gLookPoint.x, gLookPoint.y);

    // Keep the hardware pointer inside the game window. Once it leaves, clicks
    // land on the desktop, the game resigns active and GCMouse stops reporting
    // deltas — the camera then appears to stop responding.
    PearContainCursorInWindow();

    if (getenv("PEAR_DEBUG_TOUCH")) {
        PearLog(@"[PearRuntime][look] d=(%.1f,%.1f) at (%.3f,%.3f)", dx, dy, gLookPoint.x, gLookPoint.y);
    }

    gLookGeneration++;
    uint64_t generation = gLookGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ LookLiftIfIdle(generation); });
}

// Coalesces raw mouse movement: GCMouse fires at device rate, so accumulate and
// post at most ~60 times a second.
static void UpdateMouseLook(float dx, float dy) {
    if (!gLookBinding) return;
    gLookPendingDx += dx;
    gLookPendingDy += dy;
    if (gLookFlushScheduled) return;
    gLookFlushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 60),
                   dispatch_get_main_queue(), ^{ LookFlush(); });
}

#pragma mark - Input handlers

#pragma mark - Input rate guard

// Bounds how fast the keymapper can produce presses. This is mandatory: a held
// key and a scripted repeat both look like machine input, so the rate is
// clamped for every app. Releases are never blocked, so nothing can get stuck.
//
// Two limits apply: one per key and one across all keys. The per-key limit is
// what stops a single key from being held down as a rapid-fire button; the
// global limit stops a script from rotating through keys to get around it.
// Neither is configurable.
static const double kMinKeyInterval = 0.12;    // ~8 presses/second per key
static const double kMinAnyKeyInterval = 0.04; // ~25 presses/second overall
static NSMutableDictionary<NSNumber *, NSNumber *> *gLastPressTime = nil;
static double gLastAnyPressTime = 0;

static BOOL InputRateAllows(GCKeyCode keyCode) {
    if (!gLastPressTime) gLastPressTime = [NSMutableDictionary dictionary];
    double now = CACurrentMediaTime();
    if (now - gLastAnyPressTime < kMinAnyKeyInterval) return false;
    double last = gLastPressTime[@(keyCode)].doubleValue;
    if (now - last < kMinKeyInterval) {
        if (getenv("PEAR_DEBUG_TOUCH")) {
            PearLog(@"[PearRuntime][inputrate] rejected key %ld (%.1f ms since last)",
                  (long)keyCode, (now - last) * 1000.0);
        }
        return false;
    }
    gLastAnyPressTime = now;
    gLastPressTime[@(keyCode)] = @(now);
    return true;
}

/// Translates one key state change into touches. Shared by the plain and the
/// chained handler paths.
static void HandleKeyPress(GCKeyCode keyCode, BOOL pressed) {
    NSString *key = KeyNameForCode(keyCode);
    if (!key) return;

    // Input rate guard: drop implausibly fast repeat presses.
    if (pressed && !InputRateAllows(keyCode)) return;

    // W/A/S/D feed the virtual joystick rather than a point tap, but only
    // while a joystick binding exists. Without it they are ordinary keys and
    // can be bound to taps or holds.
    if (gJoystickBinding) {
        if ([key isEqualToString:@"w"]) { gJoyUp = pressed; UpdateJoystick(); return; }
        if ([key isEqualToString:@"a"]) { gJoyLeft = pressed; UpdateJoystick(); return; }
        if ([key isEqualToString:@"s"]) { gJoyDown = pressed; UpdateJoystick(); return; }
        if ([key isEqualToString:@"d"]) { gJoyRight = pressed; UpdateJoystick(); return; }
    }

    PearBinding *binding = BindingForKey(key);
    if (!binding) return;
    if (getenv("PEAR_DEBUG_TOUCH")) {
        PearLog(@"[PearRuntime][key] %@ %s", key, pressed ? "down" : "up");
    }
    SynthesizeTouch(binding, pressed, binding.point);
}

#pragma mark - Handler chaining

// GameController exposes a single handler per input stream, process-wide. The
// game process we are loaded into may install its own mouse/keyboard handlers; a
// plain assignment from the runtime silently replaces them, after which the
// game's mouse stops responding (observed as the mouse "freezing" in Dead
// Cells). Swizzle the setters so the game's handler and ours both run — the
// game's first, so its own input latency is unchanged.
typedef void (^PearMouseMovedBlock)(GCMouseInput *input, float dx, float dy);
typedef void (^PearKeyChangedBlock)(GCKeyboardInput *input, GCControllerButtonInput *button,
                                    GCKeyCode keyCode, BOOL pressed);

static IMP gOriginalSetMouseMoved = NULL;
static IMP gOriginalSetKeyChanged = NULL;
static PearMouseMovedBlock gGameMouseMoved = nil;
static PearKeyChangedBlock gGameKeyChanged = nil;
static PearMouseMovedBlock gCombinedMouseMoved = nil;
static PearKeyChangedBlock gCombinedKeyChanged = nil;

static void PearSetMouseMovedHandler(id self, SEL _cmd, PearMouseMovedBlock handler) {
    if (!gOriginalSetMouseMoved) return;
    if (handler == gCombinedMouseMoved) {
        ((void (*)(id, SEL, PearMouseMovedBlock))gOriginalSetMouseMoved)(self, _cmd, handler);
        return;
    }
    // The game installed (or cleared) its own handler: remember it and put our
    // chained handler back in its place.
    gGameMouseMoved = handler;
    ((void (*)(id, SEL, PearMouseMovedBlock))gOriginalSetMouseMoved)(self, _cmd, gCombinedMouseMoved);
}

static void PearSetKeyChangedHandler(id self, SEL _cmd, PearKeyChangedBlock handler) {
    if (!gOriginalSetKeyChanged) return;
    if (handler == gCombinedKeyChanged) {
        ((void (*)(id, SEL, PearKeyChangedBlock))gOriginalSetKeyChanged)(self, _cmd, handler);
        return;
    }
    gGameKeyChanged = handler;
    ((void (*)(id, SEL, PearKeyChangedBlock))gOriginalSetKeyChanged)(self, _cmd, gCombinedKeyChanged);
}

static void InstallHandlerChaining(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class mouseInput = NSClassFromString(@"GCMouseInput");
        Method setMouse = mouseInput ? class_getInstanceMethod(
            mouseInput, NSSelectorFromString(@"setMouseMovedHandler:")) : NULL;
        if (setMouse) {
            gOriginalSetMouseMoved = method_setImplementation(setMouse, (IMP)PearSetMouseMovedHandler);
        }

        Class keyboardInput = NSClassFromString(@"GCKeyboardInput");
        Method setKey = keyboardInput ? class_getInstanceMethod(
            keyboardInput, NSSelectorFromString(@"setKeyChangedHandler:")) : NULL;
        if (setKey) {
            gOriginalSetKeyChanged = method_setImplementation(setKey, (IMP)PearSetKeyChangedHandler);
        }

        PearLog(@"[PearRuntime][input] handler chaining installed (mouse=%d keyboard=%d)",
                gOriginalSetMouseMoved != NULL, gOriginalSetKeyChanged != NULL);
    });
}

static void InstallKeyboard(void) {
    InstallHandlerChaining();

    if (!gCombinedKeyChanged) {
        gCombinedKeyChanged = ^(GCKeyboardInput *input, GCControllerButtonInput *button,
                                GCKeyCode keyCode, BOOL pressed) {
            PearKeyChangedBlock game = gGameKeyChanged;
            if (game) game(input, button, keyCode, pressed);
            HandleKeyPress(keyCode, pressed);
        };
    }

    void (^attach)(GCKeyboard *) = ^(GCKeyboard *keyboard) {
        SEL setter = NSSelectorFromString(@"setKeyChangedHandler:");
        if (gOriginalSetKeyChanged && [keyboard.keyboardInput respondsToSelector:setter]) {
            ((void (*)(id, SEL, PearKeyChangedBlock))gOriginalSetKeyChanged)(
                keyboard.keyboardInput, setter, gCombinedKeyChanged);
        } else {
            keyboard.keyboardInput.keyChangedHandler = gCombinedKeyChanged;
        }
    };

    if (GCKeyboard.coalescedKeyboard) {
        PearLog(@"[PearRuntime][input] keyboard attached (coalesced)");
        attach(GCKeyboard.coalescedKeyboard);
    } else {
        PearLog(@"[PearRuntime][input] no GCKeyboard.coalescedKeyboard yet");
    }
    [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification
                                                     object:nil queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(NSNotification *note) {
        PearLog(@"[PearRuntime][input] keyboard connected");
        attach((GCKeyboard *)note.object);
    }];
}

static void InstallMouse(void) {
    InstallHandlerChaining();

    if (!gCombinedMouseMoved) {
        gCombinedMouseMoved = ^(GCMouseInput *input, float dx, float dy) {
            PearMouseMovedBlock game = gGameMouseMoved;
            if (game) game(input, dx, dy);
            UpdateMouseLook(dx, dy);
        };
    }

    void (^attach)(GCMouse *) = ^(GCMouse *mouse) {
        SEL setter = NSSelectorFromString(@"setMouseMovedHandler:");
        if (gOriginalSetMouseMoved && [mouse.mouseInput respondsToSelector:setter]) {
            ((void (*)(id, SEL, PearMouseMovedBlock))gOriginalSetMouseMoved)(
                mouse.mouseInput, setter, gCombinedMouseMoved);
        } else {
            mouse.mouseInput.mouseMovedHandler = gCombinedMouseMoved;
        }
    };

    if (GCMouse.current) {
        PearLog(@"[PearRuntime][input] mouse attached (current)");
        attach(GCMouse.current);
    } else {
        PearLog(@"[PearRuntime][input] no GCMouse.current yet");
    }
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification
                                                     object:nil queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(NSNotification *note) {
        PearLog(@"[PearRuntime][input] mouse connected");
        attach((GCMouse *)note.object);
    }];
}

/// Maps a GameController key code to our keymap's key names.
///
/// `GCKeyCode` values are USB HID usage ids. Letters, digits and the keypad
/// share the familiar names used by the editor; special keys are spelled out.
/// Returning nil means "no binding can name this key".
static NSString *KeyNameForCode(GCKeyCode code) {
    if (code >= GCKeyCodeKeyA && code <= GCKeyCodeKeyZ) {
        return [NSString stringWithFormat:@"%c", (char)('a' + (code - GCKeyCodeKeyA))];
    }
    if (code >= GCKeyCodeOne && code <= GCKeyCodeNine) {
        return [NSString stringWithFormat:@"%d", (int)(1 + (code - GCKeyCodeOne))];
    }
    if (code == GCKeyCodeZero) return @"0";

    // Editing and navigation keys.
    if (code == GCKeyCodeReturnOrEnter || code == GCKeyCodeKeypadEnter) return @"enter";
    if (code == GCKeyCodeEscape) return @"escape";
    if (code == GCKeyCodeDeleteOrBackspace) return @"backspace";
    if (code == GCKeyCodeDeleteForward) return @"delete";
    if (code == GCKeyCodeTab) return @"tab";
    if (code == GCKeyCodeSpacebar) return @"space";
    if (code == GCKeyCodeInsert) return @"insert";
    if (code == GCKeyCodeHome) return @"home";
    if (code == GCKeyCodeEnd) return @"end";
    if (code == GCKeyCodePageUp) return @"pageup";
    if (code == GCKeyCodePageDown) return @"pagedown";
    if (code == GCKeyCodeLeftArrow) return @"left";
    if (code == GCKeyCodeRightArrow) return @"right";
    if (code == GCKeyCodeUpArrow) return @"up";
    if (code == GCKeyCodeDownArrow) return @"down";

    // Punctuation.
    if (code == GCKeyCodeHyphen) return @"minus";
    if (code == GCKeyCodeEqualSign) return @"equal";
    if (code == GCKeyCodeOpenBracket) return @"openbracket";
    if (code == GCKeyCodeCloseBracket) return @"closebracket";
    if (code == GCKeyCodeBackslash) return @"backslash";
    if (code == GCKeyCodeSemicolon) return @"semicolon";
    if (code == GCKeyCodeQuote) return @"quote";
    if (code == GCKeyCodeGraveAccentAndTilde) return @"grave";
    if (code == GCKeyCodeComma) return @"comma";
    if (code == GCKeyCodePeriod) return @"period";
    if (code == GCKeyCodeSlash) return @"slash";
    if (code == GCKeyCodeNonUSBackslash) return @"backslash";
    if (code == GCKeyCodeNonUSPound) return @"backslash";

    // Modifiers. Left and right share a name so a binding works with either.
    if (code == GCKeyCodeLeftShift || code == GCKeyCodeRightShift) return @"shift";
    if (code == GCKeyCodeLeftControl || code == GCKeyCodeRightControl) return @"control";
    if (code == GCKeyCodeLeftAlt || code == GCKeyCodeRightAlt) return @"option";
    if (code == GCKeyCodeLeftGUI || code == GCKeyCodeRightGUI) return @"command";
    if (code == GCKeyCodeCapsLock) return @"capslock";

    // Function keys.
    if (code == GCKeyCodeF1) return @"f1";
    if (code == GCKeyCodeF2) return @"f2";
    if (code == GCKeyCodeF3) return @"f3";
    if (code == GCKeyCodeF4) return @"f4";
    if (code == GCKeyCodeF5) return @"f5";
    if (code == GCKeyCodeF6) return @"f6";
    if (code == GCKeyCodeF7) return @"f7";
    if (code == GCKeyCodeF8) return @"f8";
    if (code == GCKeyCodeF9) return @"f9";
    if (code == GCKeyCodeF10) return @"f10";
    if (code == GCKeyCodeF11) return @"f11";
    if (code == GCKeyCodeF12) return @"f12";
    if (code == GCKeyCodeF13) return @"f13";
    if (code == GCKeyCodeF14) return @"f14";
    if (code == GCKeyCodeF15) return @"f15";
    if (code == GCKeyCodeF16) return @"f16";
    if (code == GCKeyCodeF17) return @"f17";
    if (code == GCKeyCodeF18) return @"f18";
    if (code == GCKeyCodeF19) return @"f19";
    if (code == GCKeyCodeF20) return @"f20";

    // Keypad keys use a separate namespace so they can differ from the digits.
    if (code == GCKeyCodeKeypad0) return @"keypad0";
    if (code == GCKeyCodeKeypad1) return @"keypad1";
    if (code == GCKeyCodeKeypad2) return @"keypad2";
    if (code == GCKeyCodeKeypad3) return @"keypad3";
    if (code == GCKeyCodeKeypad4) return @"keypad4";
    if (code == GCKeyCodeKeypad5) return @"keypad5";
    if (code == GCKeyCodeKeypad6) return @"keypad6";
    if (code == GCKeyCodeKeypad7) return @"keypad7";
    if (code == GCKeyCodeKeypad8) return @"keypad8";
    if (code == GCKeyCodeKeypad9) return @"keypad9";
    if (code == GCKeyCodeKeypadPeriod) return @"keypadperiod";
    if (code == GCKeyCodeKeypadAsterisk) return @"keypadasterisk";
    if (code == GCKeyCodeKeypadPlus) return @"keypadplus";
    if (code == GCKeyCodeKeypadHyphen) return @"keypadminus";
    if (code == GCKeyCodeKeypadSlash) return @"keypadslash";
    if (code == GCKeyCodeKeypadEqualSign) return @"keypadequal";
    return nil;
}

#pragma mark - Entry point

static void LogScreenMetrics(void);
static void LogViewTree(void);
static void PearProbeHID(void);

#pragma mark - Keymap reload

// (Re)loads the keymap and re-resolves the joystick binding. Called at startup
// and again whenever the file changes, so edits saved by PearSilicon.app's
// overlay take effect without relaunching the game.
static void ApplyKeymap(NSString *path) {
    gBindings = path ? LoadKeymap(path) : @[];
    gJoystickBinding = nil;
    gLookBinding = nil;
    for (PearBinding *binding in gBindings) {
        if (binding.kind == PearActionKindJoystick && !gJoystickBinding) gJoystickBinding = binding;
        if (binding.kind == PearActionKindMouseLook && !gLookBinding) gLookBinding = binding;
    }
    PearLog(@"[PearRuntime] loaded %lu bindings from %@", (unsigned long)gBindings.count, path);
}

// Polls the keymap's modification time once a second and reloads on change.
// Polling (rather than a vnode source) is deliberate: the keymap is written
// atomically, so the file is replaced (rename) and a vnode watch would need
// re-arming each time.
static void WatchKeymap(NSString *path) {
    if (path.length == 0) return;
    struct stat initial;
    __block time_t lastMTime = (stat(path.fileSystemRepresentation, &initial) == 0) ? initial.st_mtime : 0;

    // Retained for the life of the process; a local source would be released by
    // ARC when this function returns and never fire.
    static dispatch_source_t gKeymapTimer = nil;
    if (gKeymapTimer) dispatch_source_cancel(gKeymapTimer);
    gKeymapTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          dispatch_get_main_queue());
    dispatch_source_set_timer(gKeymapTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, (uint64_t)(0.2 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gKeymapTimer, ^{
        struct stat st;
        if (stat(path.fileSystemRepresentation, &st) != 0) return;
        if (st.st_mtime == lastMTime) return;
        lastMTime = st.st_mtime;
        ApplyKeymap(path);
    });
    dispatch_resume(gKeymapTimer);
}

@implementation PearRuntime

+ (void)bootstrap {
    // Debug affordance: let a launch disable the runtime entirely so we can tell
    // whether a loaded component is responsible for a misbehaving app.
    if (NSProcessInfo.processInfo.environment[@"PEAR_DISABLE"]) {
        PearLog(@"[PearRuntime] disabled via PEAR_DISABLE");
        return;
    }

    NSString *keymapPath = NSProcessInfo.processInfo.environment[@"PEAR_KEYMAP"];
    ApplyKeymap(keymapPath);
    WatchKeymap(keymapPath);

    // Input translation is opt-in: with no keymap (the app did not enable the
    // keymapper) the runtime installs no input handlers at all.
    if (gBindings.count > 0) {
        InstallMouse();
        InstallKeyboard();
    } else {
        PearLog(@"[PearRuntime] keymapper disabled (no bindings); input translation off");
    }

    // Opt-in self-tests for the two relative/path gestures, so they can be
    // verified without a real mouse/keyboard.
    if (NSProcessInfo.processInfo.environment[@"PEAR_TEST_TAP_AT"]) {
        NSString *spec = NSProcessInfo.processInfo.environment[@"PEAR_TEST_TAP_AT"];
        // Several taps can be chained with `;` so a coordinate sweep can be
        // checked without a second launch or a screenshot tool.
        NSArray<NSString *> *taps = [spec componentsSeparatedByString:@";"];
        [taps enumerateObjectsUsingBlock:^(NSString *tap, NSUInteger index, BOOL *stop) {
            NSArray<NSString *> *parts = [tap componentsSeparatedByString:@","];
            if (parts.count < 2) return;
            CGFloat nx = parts[0].doubleValue;
            CGFloat ny = parts[1].doubleValue;
            double delay = parts.count >= 3 ? parts[2].doubleValue : 8.0;
            NSString *key = [NSString stringWithFormat:@"pear-test-at-%lu", (unsigned long)index];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                PearLog(@"[PearRuntime][touch] TEST tap %lu at (%.3f,%.3f) after %.1fs state=%ld",
                        (unsigned long)index, nx, ny, delay,
                        (long)UIApplication.sharedApplication.applicationState);
                if (getenv("PEAR_TOUCH_CGEVENT")) {
                    PearSynthesizeTapCGEvent(nx, ny);
                } else {
                    PearSynthesizeVirtualFinger(YES, key, nx, ny);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        PearSynthesizeVirtualFinger(NO, key, nx, ny);
                    });
                }
            });
        }];
    }
    if (NSProcessInfo.processInfo.environment[@"PEAR_TEST_LOOK"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PearLog(@"[PearRuntime][look] TEST mouse-look (synthetic deltas)");
            for (int i = 0; i < 40; i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.03 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ UpdateMouseLook(25, 8); });
            }
        });
    }
    if (NSProcessInfo.processInfo.environment[@"PEAR_TEST_SWIPE"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PearLog(@"[PearRuntime][swipe] TEST swipe (0.3,0.5) -> (0.7,0.5)");
            PearBinding *b = [PearBinding new];
            b.kind = PearActionKindSwipe;
            b.key = @"test-swipe";
            b.swipeFrom = CGPointMake(0.3, 0.5);
            b.swipeTo = CGPointMake(0.7, 0.5);
            b.swipeDuration = 0.3;
            SynthesizeSwipe(b);
        });
    }

    if (NSProcessInfo.processInfo.environment[@"PEAR_DEBUG_SCREEN"]) {
        LogScreenMetrics();
    }
    if (NSProcessInfo.processInfo.environment[@"PEAR_DEBUG_VIEWS"]) {
        LogViewTree();
    }
    if (NSProcessInfo.processInfo.environment[@"PEAR_PROBE_HID"]) {
        PearProbeHID();
    }
}

#pragma mark - HID touch-synthesis probe

// Reports whether the pieces needed for *native* (real UITouch) synthesis are
// reachable: the IOHIDEvent digitizer constructors and UIKit's private
// event-enqueue entry point.
static void PearProbeHID(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        PearLog(@"[PearRuntime][probe] IOKit=%p DigitizerEvent=%p DigitizerFingerEvent=%p "
              @"EventSystemClientCreate=%p",
              iokit,
              dlsym(iokit, "IOHIDEventCreateDigitizerEvent"),
              dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent"),
              dlsym(iokit, "IOHIDEventSystemClientCreate"));
        void *gs = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_LAZY);
        PearLog(@"[PearRuntime][probe] GraphicsServices=%p GSSendEvent=%p",
              gs, gs ? dlsym(gs, "GSSendEvent") : NULL);
        id app = UIApplication.sharedApplication;
        PearLog(@"[PearRuntime][probe] app _enqueueHIDEvent: = %d | _enqueueHIDEventRecord: = %d",
              [app respondsToSelector:NSSelectorFromString(@"_enqueueHIDEvent:")],
              [app respondsToSelector:NSSelectorFromString(@"_enqueueHIDEventRecord:")]);
        for (Class c = UIApplication.class; c; c = class_getSuperclass(c)) {
            unsigned int ivcount = 0;
            Ivar *ivars = class_copyIvarList(c, &ivcount);
            for (unsigned int i = 0; i < ivcount; i++) {
                const char *name = ivar_getName(ivars[i]);
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (name && (strcasestr(name, "hid") || strcasestr(name, "observer")
                             || strcasestr(name, "eventqueue") || strcasestr(name, "eventqueue"))) {
                    PearLog(@"[PearRuntime][probe]   ivar %s :: %s %s", class_getName(c), name, type);
                }
            }
            free(ivars);
        }

        // On macOS the iOS app's touches arrive through the window server and are
        // turned into UIKit events by the "UIKitMac" glue, not by an in-process
        // IOHIDEvent client. Look for that glue and its event entry points.
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        for (unsigned int i = 0; i < classCount; i++) {
            const char *cname = class_getName(classes[i]);
            if (!cname) continue;
            BOOL interesting = strcasestr(cname, "UINSVirtual") || strcasestr(cname, "VirtualDigitizer")
                || strcasestr(cname, "VirtualFinger");
            if (!interesting) continue;
            PearLog(@"[PearRuntime][probe] CLASS %s : %s", cname,
                  class_getSuperclass(classes[i]) ? class_getName(class_getSuperclass(classes[i])) : "-");
            unsigned int icount = 0;
            Ivar *ivs = class_copyIvarList(classes[i], &icount);
            for (unsigned int k = 0; k < icount; k++) {
                PearLog(@"[PearRuntime][probe]   ivar %s %s", ivar_getName(ivs[k]), ivar_getTypeEncoding(ivs[k]));
            }
            free(ivs);
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(classes[i], &mcount);
            for (unsigned int m = 0; m < mcount; m++) {
                PearLog(@"[PearRuntime][probe]   meth %s", sel_getName(method_getName(methods[m])));
            }
            free(methods);
        }
        free(classes);
        for (Class c = UIApplication.class; c; c = class_getSuperclass(c)) {
            unsigned int count = 0;
            Method *methods = class_copyMethodList(c, &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *name = sel_getName(method_getName(methods[i]));
                if ((strcasestr(name, "hid") || strcasestr(name, "enqueue")) && strchr(name, ':')) {
                    PearLog(@"[PearRuntime][probe]   %s :: %s", class_getName(c), name);
                }
            }
            free(methods);
        }
    });
}

#pragma mark - Diagnostics

static void LogViewTree(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __block void (^dump)(UIView *, int) = nil;
        dump = ^(UIView *view, int depth) {
            if (depth > 40) return;
            NSMutableString *indent = [NSMutableString string];
            for (int i = 0; i < depth; i++) [indent appendString:@"  "];
            PearLog(@"[PearRuntime][views] %@%@ frame=%@ bounds=%@ transform=%@ scale=%.2f hidden=%d alpha=%.2f layer=%@",
                  indent, NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
                  NSStringFromCGRect(view.bounds),
                  NSStringFromCGAffineTransform(view.transform), view.contentScaleFactor,
                  view.hidden, view.alpha, NSStringFromClass(view.layer.class));
            for (UIView *sub in view.subviews) dump(sub, depth + 1);
        };
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                PearLog(@"[PearRuntime][views] window %@ level=%.0f hidden=%d key=%d frame=%@",
                      NSStringFromClass(window.class), window.windowLevel, window.hidden,
                      window.isKeyWindow, NSStringFromCGRect(window.frame));
                if (window.rootViewController) {
                    UIViewController *root = window.rootViewController;
                    PearLog(@"[PearRuntime][views]   rootVC=%@ viewLoaded=%d",
                          NSStringFromClass(root.class), root.isViewLoaded);
                    if (root.isViewLoaded) {
                        UIView *vcView = root.view;
                        PearLog(@"[PearRuntime][views]   rootVC.view=%@ frame=%@ superview=%@ hidden=%d",
                              NSStringFromClass(vcView.class), NSStringFromCGRect(vcView.frame),
                              vcView.superview ? NSStringFromClass(vcView.superview.class) : @"nil",
                              vcView.hidden);
                    }
                }
                dump(window, 1);
            }
        }

        // Modal legacy alerts can live on their own window and are not part of
        // the scene's window list. Include them so a blocking alert that never
        // became visible is still discoverable.
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            PearLog(@"[PearRuntime][views] app window %@ level=%.0f hidden=%d key=%d alpha=%.2f frame=%@",
                  NSStringFromClass(window.class), window.windowLevel, window.hidden,
                  window.isKeyWindow, window.alpha, NSStringFromCGRect(window.frame));
            dump(window, 1);
        }

        __block void (^dumpLayer)(CALayer *, int) = nil;
        dumpLayer = ^(CALayer *layer, int depth) {
            if (depth > 40) return;
            NSMutableString *indent = [NSMutableString string];
            for (int i = 0; i < depth; i++) [indent appendString:@"  "];
            NSMutableString *extra = [NSMutableString string];
            if ([layer isKindOfClass:CAMetalLayer.class]) {
                CAMetalLayer *metal = (CAMetalLayer *)layer;
                [extra appendFormat:@" drawableSize=%@ device=%@ pixelFormat=%d framebufferOnly=%d",
                 NSStringFromCGSize(metal.drawableSize), metal.device ? @"yes" : @"nil",
                 (int)metal.pixelFormat, metal.framebufferOnly];
            }
            PearLog(@"[PearRuntime][layers] %@%@ bounds=%@ pos=%@ transform=[%.3f %.3f %.3f %.3f] opacity=%.2f hidden=%d%@",
                  indent, NSStringFromClass(layer.class), NSStringFromCGRect(layer.bounds),
                  NSStringFromCGPoint(layer.position), layer.transform.m11, layer.transform.m12,
                  layer.transform.m21, layer.transform.m22, layer.opacity, layer.hidden, extra);
            for (CALayer *sub in layer.sublayers) dumpLayer(sub, depth + 1);
        };
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                dumpLayer(window.layer, 0);
            }
        }
    });
}

static void LogScreenMetrics(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIScreen *screen = UIScreen.mainScreen;
        PearLog(@"[PearRuntime][screen] bounds=%@ nativeBounds=%@ scale=%.2f nativeScale=%.2f",
              NSStringFromCGRect(screen.bounds), NSStringFromCGRect(screen.nativeBounds),
              screen.scale, screen.nativeScale);
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            PearLog(@"[PearRuntime][screen] scene=%@ coords=%@",
                  windowScene.activationState == UISceneActivationStateForegroundActive ? @"active" : @"other",
                  NSStringFromCGRect(windowScene.coordinateSpace.bounds));
            PearLog(@"[PearRuntime][screen] orientation statusBar=%ld scene=%ld device=%ld",
                  (long)UIApplication.sharedApplication.statusBarOrientation,
                  (long)windowScene.interfaceOrientation,
                  (long)UIDevice.currentDevice.orientation);
            for (UIWindow *window in windowScene.windows) {
                PearLog(@"[PearRuntime][screen] window frame=%@ bounds=%@ key=%d",
                      NSStringFromCGRect(window.frame), NSStringFromCGRect(window.bounds),
                      window.isKeyWindow);
            }
        }
    });
}

@end

__attribute__((constructor))
static void PearRuntimeInit(void) {
    @autoreleasepool {
        [PearRuntime bootstrap];
    }
}
