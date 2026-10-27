// TouchSynthesizer.mm
//
// How a touch gets into an iOS app running on arm64 macOS.
//
//   * UINSVirtualDigitizer (default, working) — macOS's own virtual-touch
//     machinery (the one behind Touch Alternatives). Each binding drives a
//     named virtual finger, so real multi-touch works and the system cursor is
//     untouched.
//
//   * CGEvent (opt-in via PEAR_TOUCH_CGEVENT) — post a real system mouse event
//     at the game window's *screen* position. Only one pointer exists, and the
//     post moves the real cursor (stashed/restored around a tap). Kept for
//     comparison and diagnostics.
//
//   * IOHIDEvent (experimental, opt-in via PEAR_TOUCH_IOHID) — build a
//     digitizer event and hand it to UIKit's own event pipeline. Inert on
//     macOS: touches arrive through the UIKitMac glue, not an in-process HID
//     client.
//
// Everything here is our own code. The private symbols are reached dynamically,
// since the SDK declares no headers for them.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import <os/lock.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef int32_t IOFixed; // 16.16 fixed point

// the platform's private digitizer constants.
enum {
    PearTransducerHand = 0,
    PearTransducerFinger = 1,
};
enum {
    PearDigitizerEventRange = 1 << 0,
    PearDigitizerEventTouch = 1 << 1,
};
// IOHIDEventFieldDigitizerIsDisplayIntegrated: field base for event type
// Digitizer (7) with field index 0x0c.
#define PEAR_FIELD_DIGITIZER_IS_DISPLAY_INTEGRATED ((7 << 16) | 0x0c)

typedef IOHIDEventRef (*PearCreateFingerFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                            uint32_t, IOFixed, IOFixed, IOFixed, IOFixed,
                                            IOFixed, Boolean, Boolean, CFOptionFlags);
typedef IOHIDEventRef (*PearCreateHandFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                          uint32_t, uint32_t, uint32_t, IOFixed, IOFixed,
                                          IOFixed, IOFixed, IOFixed, Boolean, Boolean,
                                          CFOptionFlags);
typedef IOHIDEventRef (*PearCreateFn)(CFAllocatorRef, int, uint64_t);
typedef void *IOHIDEventSystemClientRef;
typedef IOHIDEventSystemClientRef (*PearClientCreateFn)(CFAllocatorRef);
typedef void (*PearClientDispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef void (*PearClientSetPropFn)(IOHIDEventSystemClientRef, CFStringRef, CFTypeRef);
typedef IOHIDEventRef (*PearCreateCopyFn)(CFAllocatorRef, IOHIDEventRef);
typedef void (*PearAppendEventFn)(IOHIDEventRef, IOHIDEventRef);
typedef void (*PearSetIntegerFn)(IOHIDEventRef, uint32_t, CFIndex);
typedef void (*PearSetFloatFn)(IOHIDEventRef, uint32_t, double);
typedef void (*PearSetSenderFn)(IOHIDEventRef, uint32_t);
typedef CFIndex (*PearGetIntegerValFn)(IOHIDEventRef, uint32_t);
typedef double (*PearGetFloatValFn)(IOHIDEventRef, uint32_t);
typedef CFArrayRef (*PearGetChildrenFn)(IOHIDEventRef);
typedef uint64_t (*PearGetTimeStampFn)(IOHIDEventRef);
typedef int (*PearGetTypeFn)(IOHIDEventRef);
typedef uint32_t (*PearGetSenderFn)(IOHIDEventRef);

static PearCreateFingerFn gCreateFinger;
static PearCreateHandFn gCreateHand;
static PearCreateFn gCreate;
static PearClientCreateFn gClientCreate;
static PearClientDispatchFn gClientDispatch;
static PearClientSetPropFn gClientSetProperty;
static PearCreateCopyFn gCreateCopy;
static PearAppendEventFn gAppendEvent;
static PearSetIntegerFn gSetInteger;
static PearSetFloatFn gSetFloat;
static PearSetSenderFn gSetSender;
static PearGetIntegerValFn gGetIntegerVal;
static PearGetFloatValFn gGetFloatVal;
static PearGetChildrenFn gGetChildren;
static PearGetTimeStampFn gGetTimeStamp;
static PearGetTypeFn gGetType;
static PearGetSenderFn gGetSender;
static SEL gEnqueueSelector;
static BOOL gReady;

void PearSynthesizeTouchBegin(void); // resolve symbols lazily

static void PearResolve(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        gCreateFinger = (PearCreateFingerFn)dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
        gCreateHand = (PearCreateHandFn)dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
        gCreate = (PearCreateFn)dlsym(iokit, "IOHIDEventCreate");
        gClientCreate = (PearClientCreateFn)dlsym(iokit, "IOHIDEventSystemClientCreate");
        gClientDispatch = (PearClientDispatchFn)dlsym(iokit, "IOHIDEventSystemClientDispatchEvent");
        gClientSetProperty = (PearClientSetPropFn)dlsym(iokit, "IOHIDEventSystemClientSetProperty");
        gCreateCopy = (PearCreateCopyFn)dlsym(iokit, "IOHIDEventCreateCopy");
        gAppendEvent = (PearAppendEventFn)dlsym(iokit, "IOHIDEventAppendEvent");
        gSetInteger = (PearSetIntegerFn)dlsym(iokit, "IOHIDEventSetIntegerValue");
        gSetFloat = (PearSetFloatFn)dlsym(iokit, "IOHIDEventSetFloatValue");
        gSetSender = (PearSetSenderFn)dlsym(iokit, "IOHIDEventSetSenderID");
        gGetIntegerVal = (PearGetIntegerValFn)dlsym(iokit, "IOHIDEventGetIntegerValue");
        gGetFloatVal = (PearGetFloatValFn)dlsym(iokit, "IOHIDEventGetFloatValue");
        gGetChildren = (PearGetChildrenFn)dlsym(iokit, "IOHIDEventGetChildren");
        gGetTimeStamp = (PearGetTimeStampFn)dlsym(iokit, "IOHIDEventGetTimeStamp");
        gGetType = (PearGetTypeFn)dlsym(iokit, "IOHIDEventGetType");
        gGetSender = (PearGetSenderFn)dlsym(iokit, "IOHIDEventGetSenderID");
        gEnqueueSelector = NSSelectorFromString(@"_enqueueHIDEvent:");
        gReady = gCreateFinger && gCreateHand && gAppendEvent && gSetInteger;
        PearLog(@"[PearRuntime][touch] IOHIDEvent ready=%d (finger=%p hand=%p append=%p)",
              gReady, gCreateFinger, gCreateHand, gAppendEvent);
    });
}

#pragma mark - HID event dump

// Prints an IOHIDEvent and its children: type, sender, timestamp and every
// digitizer field (integer and float). Used to compare a *real* delivered event
// against the one we synthesize, so the missing precondition is visible instead
// of guessed.
static void PearDumpHIDTree(IOHIDEventRef event, int depth) {
    if (!event) return;
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    PearLog(@"[PearRuntime][hid] %@event type=%d sender=%u timestamp=%llu",
          pad, gGetType ? gGetType(event) : -1,
          gGetSender ? gGetSender(event) : 0,
          gGetTimeStamp ? gGetTimeStamp(event) : 0);
    for (uint32_t i = 0; i < 0x30; i++) {
        uint32_t field = (11u << 16) | i;
        CFIndex iv = gGetIntegerVal ? gGetIntegerVal(event, field) : 0;
        double fv = gGetFloatVal ? gGetFloatVal(event, field) : 0.0;
        if (iv || fv != 0.0) {
            PearLog(@"[PearRuntime][hid] %@  d[0x%02x] int=%ld float=%.6f", pad, i, (long)iv, fv);
        }
    }
    CFArrayRef children = gGetChildren ? gGetChildren(event) : NULL;
    if (children) {
        for (CFIndex i = 0; i < CFArrayGetCount(children); i++) {
            PearDumpHIDTree((IOHIDEventRef)CFArrayGetValueAtIndex(children, i), depth + 1);
        }
    }
}

/// Synthesizes a touch at a normalized (0..1) point in the key window.
/// `down` selects a finger-down or finger-up transition.
void PearSynthesizeTouch(BOOL down, CGFloat nx, CGFloat ny) {
    PearResolve();
    if (!gReady) return;

    UIApplication *app = UIApplication.sharedApplication;
    BOOL hasSelector = [app respondsToSelector:gEnqueueSelector];
    UIWindow *key = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) { if (w.isKeyWindow) key = w; }
    }
    if (getenv("PEAR_DEBUG_TOUCH")) {
        PearLog(@"[PearRuntime][touch] synthesize down=%d state=%ld keyWindow=%@ sel=%d",
              down, (long)app.applicationState,
              key ? NSStringFromCGRect(key.frame) : @"nil", hasSelector);
    }
    if (!hasSelector) return;

    // Field layout and values taken verbatim from a *real* delivered digitizer
    // event (IOHIDEvent type 11), captured by dumping what the window server
    // delivers for a genuine click — see PEAR_DUMP_HIDEVENT. The tree is:
    //
    //   root (type 11, sender 10572147)      d[4]=3 d[7]=2 d[8]=1 d[9]=touch d[0x18]=6 d[0x19]=1
    //     ├ finger (type 11, sender 0)       d[0]=x d[1]=y d[4]=2 d[5]=19 d[7]=6 d[8]=1 d[9]=touch
    //     │                                  d[0x11]=1 d[0x12]=1 d[0x13]=1 d[0x14]=0.015 d[0x15]=5 d[0x1f]=2
    //     ├ (type 17, empty)
    //     └ (type 1,  empty)
    //
    // Coordinates are in the window's *UIKit point* space (x = nx * window.width),
    // which is larger than the on-screen window: a real touch's digitizer x/y
    // equal its `locationInView:` (measured).
    const uint32_t base = 11u << 16;
    uint64_t now = mach_absolute_time();

    CGSize pts = key ? key.bounds.size : CGSizeMake(1000, 1000);
    double x = (double)nx * pts.width;
    double y = (double)ny * pts.height;

    IOHIDEventRef finger = gCreateFinger(kCFAllocatorDefault, now,
                                         0, 0,   // index, identity
                                         6,      // eventMask
                                         0, 0, 0, 0, 0, // x,y,z,pressure,twist (set below)
                                         down, down, 0); // range, touch, options
    if (!finger) { PearLog(@"[PearRuntime][touch] finger event nil"); return; }
    gSetInteger(finger, base | 0x04, 2);
    gSetInteger(finger, base | 0x05, 19);
    gSetInteger(finger, base | 0x07, 6);
    gSetInteger(finger, base | 0x08, 1);
    gSetInteger(finger, base | 0x09, down ? 1 : 0);
    gSetFloat(finger, base | 0x00, x);
    gSetFloat(finger, base | 0x01, y);
    gSetInteger(finger, base | 0x11, 1);
    gSetInteger(finger, base | 0x12, 1);
    gSetInteger(finger, base | 0x13, 1);
    gSetFloat(finger, base | 0x14, 0.015);
    gSetInteger(finger, base | 0x15, 5);
    gSetInteger(finger, base | 0x1f, 2);

    IOHIDEventRef root = gCreateHand(kCFAllocatorDefault, now,
                                     3, 0, 0,   // transducerType, index, identity
                                     2, 0,       // eventMask, buttonMask
                                     0, 0, 0, 0, 0, // x,y,z,pressure,twist (unused at root)
                                     down, down, 0);
    gSetInteger(root, base | 0x04, 3);
    gSetInteger(root, base | 0x07, 2);
    gSetInteger(root, base | 0x08, 1);
    gSetInteger(root, base | 0x09, down ? 1 : 0);
    gSetInteger(root, base | 0x18, 6);
    gSetInteger(root, base | 0x19, 1);
    gAppendEvent(root, finger);

    // The two trailing children a real event carries.
    if (gCreate) {
        IOHIDEventRef c17 = gCreate(kCFAllocatorDefault, 17, now);
        if (c17) gAppendEvent(root, c17);
        IOHIDEventRef c1 = gCreate(kCFAllocatorDefault, 1, now);
        if (c1) gAppendEvent(root, c1);
    }
    if (gSetSender) gSetSender(root, 10572147);

    if (getenv("PEAR_DEBUG_TOUCH")) {
        PearLog(@"[PearRuntime][touch] synthesize down=%d nx=%.3f ny=%.3f -> (%.1f,%.1f) of (%.0f,%.0f)",
              down, (double)nx, (double)ny, x, y, pts.width, pts.height);
    }
    if (getenv("PEAR_DUMP_HIDEVENT")) {
        PearLog(@"[PearRuntime][hid] ---- synthetic toSend ----");
        PearDumpHIDTree(root, 0);
    }

    // Sink: PEAR_TOUCH_SINK picks explicitly.
    //   handle   _handleHIDEvent:                       (UIKit's HID entry point)
    //   enqueue  _enqueueHIDEvent:                      (HID system's entry point)
    //   direct   _handleHIDEventBypassingUIEvent:
    //   dispatch IOHIDEventSystemClientDispatchEvent    (send into the HID system,
    //            so UIKit's own observer receives it — no private method call)
    const char *sinkName = getenv("PEAR_TOUCH_SINK");
    if (sinkName && strcmp(sinkName, "dispatch") == 0) {
        static IOHIDEventSystemClientRef client = NULL;
        if (!client && gClientCreate) client = gClientCreate(kCFAllocatorDefault);
        if (client && gClientDispatch) {
            gClientDispatch(client, root);
            PearLog(@"[PearRuntime][touch] dispatched via IOHIDEventSystemClient=%p", client);
        } else {
            PearLog(@"[PearRuntime][touch] dispatch unavailable (create=%p dispatch=%p)",
                  gClientCreate, gClientDispatch);
        }
        CFRelease(root);
        return;
    }

    SEL sink = NSSelectorFromString(@"_handleHIDEvent:");
    if (sinkName && strcmp(sinkName, "enqueue") == 0) sink = gEnqueueSelector;
    else if (sinkName && strcmp(sinkName, "direct") == 0) sink = NSSelectorFromString(@"_handleHIDEventBypassingUIEvent:");
    if (![app respondsToSelector:sink]) sink = gEnqueueSelector;
    [app performSelector:sink withObject:(__bridge id)root];

    CFRelease(root);
}

void PearSynthesizeTouchBegin(void) { PearResolve(); }

#pragma mark - Virtual digitizer (macOS Catalyst)

// On macOS the app's touches do NOT flow through UIApplication's IOHIDEvent
// entry points (feeding one there delivers nothing, even when replaying an event
// UIKit just accepted). They flow through the "UIKitMac" glue, which ships its
// own way to synthesize touches: UINSVirtualDigitizer / UINSVirtualFinger
// (the machinery behind Touch Alternatives). We drive it directly.
//
//   digitizer = [[UINSVirtualDigitizer alloc] init]
//   [digitizer addVirtualFingerAtLoc:forKey:]
//   [digitizer modifyVirtualFingerForKey:withBlock:^(f){ [f setTouching:YES]; }]
//   [digitizer _postHIDDigitizerCollectionToUIKitWithTimestamp:]   // → UIKit
//
// These are private classes, reached dynamically because the SDK declares no
// headers for them.
static id gVirtualDigitizer = nil;

static id PearVirtualDigitizer(void) {
    if (gVirtualDigitizer) return gVirtualDigitizer;
    Class cls = NSClassFromString(@"UINSVirtualDigitizer");
    if (!cls) { PearLog(@"[PearRuntime][touch] UINSVirtualDigitizer not found"); return nil; }
    id digitizer = ((id (*)(id, SEL))objc_msgSend)([cls alloc], @selector(init));
    if (!digitizer) return nil;

    // Bind to the key window's context, so the touch lands in the right scene.
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) key = w;
    }
    SEL ctxSel = NSSelectorFromString(@"_contextId");
    if (key && [key respondsToSelector:ctxSel]) {
        uint32_t contextId = (uint32_t)((unsigned long (*)(id, SEL))objc_msgSend)(key, ctxSel);
        SEL setCtx = NSSelectorFromString(@"setContextId:");
        if ([digitizer respondsToSelector:setCtx]) {
            ((void (*)(id, SEL, uint32_t))objc_msgSend)(digitizer, setCtx, contextId);
        }
        PearLog(@"[PearRuntime][touch] virtual digitizer=%p contextId=0x%x", digitizer, contextId);
    } else {
        PearLog(@"[PearRuntime][touch] virtual digitizer=%p (no contextId)", digitizer);
    }
    gVirtualDigitizer = digitizer;
    return digitizer;
}

/// Address of a UINSVirtualDigitizer's `_spinLock` (its first ivar), which
/// `_postHIDDigitizerCollectionToUIKitWithTimestamp:` asserts the caller holds.
static os_unfair_lock *PearVirtualDigitizerLock(id digitizer) {
    static ptrdiff_t offset = 0;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        Ivar ivar = class_getInstanceVariable(NSClassFromString(@"UINSVirtualDigitizer"), "_spinLock");
        if (ivar) offset = ivar_getOffset(ivar);
    }
    if (offset == 0 && class_getInstanceVariable(NSClassFromString(@"UINSVirtualDigitizer"), "_spinLock") == NULL) {
        return NULL;
    }
    return (os_unfair_lock *)((char *)(__bridge void *)digitizer + offset);
}

/// Drives a virtual finger identified by `key`: `down` presses it and moves it to
/// the normalized window point (nx,ny); `!down` releases it; then posts the
/// digitizer collection to UIKit. Different keys are independent fingers, so
/// several can be down at once (joystick + buttons + taps) — real multi-touch.
void PearSynthesizeVirtualFinger(BOOL down, NSString *key, CGFloat nx, CGFloat ny) {
    id digitizer = PearVirtualDigitizer();
    if (!digitizer) return;

    // Digitizer coordinates are in the window's UIKit point space (larger than
    // the on-screen window; iOSSupport scales it).
    CGSize pts = CGSizeMake(1000, 1000);
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) pts = w.bounds.size;
    }
    double x = (double)nx * pts.width;
    double y = (double)ny * pts.height;

    SEL addSel = NSSelectorFromString(@"addVirtualFingerAtLoc:forKey:");
    SEL modSel = NSSelectorFromString(@"modifyVirtualFingerForKey:withBlock:");
    SEL postSel = NSSelectorFromString(@"_postHIDDigitizerCollectionToUIKitWithTimestamp:");

    void (^mutate)(id) = ^(id finger) {
        // Always move first, so a lift reports the last position.
        SEL setLoc = NSSelectorFromString(@"setLocation:");
        if ([finger respondsToSelector:setLoc]) {
            ((void (*)(id, SEL, CGPoint))objc_msgSend)(finger, setLoc, CGPointMake(x, y));
        }
        SEL setTouching = NSSelectorFromString(@"setTouching:");
        if ([finger respondsToSelector:setTouching]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(finger, setTouching, down);
        }
    };

    if (down && [digitizer respondsToSelector:addSel]) {
        ((void (*)(id, SEL, CGPoint, id))objc_msgSend)(digitizer, addSel, CGPointMake(x, y), key);
    }
    if ([digitizer respondsToSelector:modSel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(digitizer, modSel, key, mutate);
    }
    if ([digitizer respondsToSelector:postSel]) {
        // _postHIDDigitizerCollectionToUIKitWithTimestamp: requires the caller to
        // hold the digitizer's os_unfair_lock (it asserts ownership). Take
        // _spinLock around the post, exactly as its own internals expect.
        os_unfair_lock *lock = PearVirtualDigitizerLock(digitizer);
        if (lock) os_unfair_lock_lock(lock);
        ((void (*)(id, SEL, uint64_t))objc_msgSend)(digitizer, postSel, mach_absolute_time());
        if (lock) os_unfair_lock_unlock(lock);
    }
    if (getenv("PEAR_DEBUG_TOUCH")) {
        PearLog(@"[PearRuntime][touch] virtual finger %@ down=%d nx=%.3f ny=%.3f -> (%.1f,%.1f) of (%.0f,%.0f)",
              key, down, (double)nx, (double)ny, x, y, pts.width, pts.height);
    }
}

// The window's *screen* rectangle, from the window server. UIKit's window.frame
// is (0,0,W,H), so its position must be looked up here or posted events land
// outside the window.
static CGRect PearWindowScreenRect(void) {
    CGRect screenRect = CGRectZero;
    pid_t selfPid = getpid();
    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!info) return screenRect;
    for (CFIndex i = 0; i < CFArrayGetCount(info); i++) {
        NSDictionary *entry = (__bridge NSDictionary *)CFArrayGetValueAtIndex(info, i);
        NSNumber *owner = entry[(id)kCGWindowOwnerPID];
        NSDictionary *bounds = entry[(id)kCGWindowBounds];
        if (owner.integerValue != (NSInteger)selfPid || !bounds) continue;
        CGRect r = CGRectMake([bounds[@"X"] doubleValue], [bounds[@"Y"] doubleValue],
                              [bounds[@"Width"] doubleValue], [bounds[@"Height"] doubleValue]);
        if (r.size.width * r.size.height > screenRect.size.width * screenRect.size.height) {
            screenRect = r;
        }
    }
    CFRelease(info);
    return screenRect;
}

// Posts one mouse event of `type` at a normalized point in the game window.
// This is the system's own event path (the window server turns it into a real
// UITouch for an iOS-on-Mac app), i.e. native synthetic input, not a fake event
// synthesized at the UIKit level.
//
// Where the event is posted matters: posting to the global HID tap
// (`CGEventPost`) is dropped when the process is not trusted for Accessibility,
// whereas posting directly to our own pid (`CGEventPostToPid`) is not. Select
// with PEAR_POST_TARGET = hid (default) | self | annotated | session.
static void PearPostMouse(CGEventType type, CGFloat nx, CGFloat ny) {
    CGRect rect = PearWindowScreenRect();
    if (rect.size.width <= 0 || rect.size.height <= 0) {
        PearLog(@"[PearRuntime][touch] cgevent: no window rect");
        return;
    }
    CGPoint p = CGPointMake(rect.origin.x + nx * rect.size.width,
                            rect.origin.y + ny * rect.size.height);
    CGEventRef e = CGEventCreateMouseEvent(NULL, type, p, kCGMouseButtonLeft);
    if (e) {
        const char *target = getenv("PEAR_POST_TARGET");
        if (target && strcmp(target, "self") == 0) {
            CGEventPostToPid(getpid(), e);
        } else if (target && strcmp(target, "annotated") == 0) {
            CGEventPost(kCGAnnotatedSessionEventTap, e);
        } else if (target && strcmp(target, "session") == 0) {
            CGEventPost(kCGSessionEventTap, e);
        } else {
            CGEventPost(kCGHIDEventTap, e);
        }
        CFRelease(e);
    }
    if (getenv("PEAR_DEBUG_TOUCH")) {
        PearLog(@"[PearRuntime][touch] cgevent type=%d at (%.0f, %.0f) rect={{%0.f,%0.f},{%.0f,%.0f}} target=%s",
              (int)type, p.x, p.y, rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
              getenv("PEAR_POST_TARGET") ?: "hid");
    }
}

/// A held finger: down on press, up on release.
void PearSynthesizeMouse(BOOL down, CGFloat nx, CGFloat ny) {
    PearPostMouse(down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp, nx, ny);
}

/// A finger that is already down and moves to a new point (joystick drag).
void PearSynthesizeDrag(CGFloat nx, CGFloat ny) {
    PearPostMouse(kCGEventLeftMouseDragged, nx, ny);
}

#pragma mark - Cursor stash

// A CGEvent tap moves the real pointer, so a synthetic touch would otherwise
// steal the user's cursor. Stash/restore let a caller confine that jump to the
// duration of a gesture.
static CGPoint gStashedCursor;
static BOOL gCursorStashed;

static CGPoint PearCursorLocation(void) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = e ? CGEventGetLocation(e) : CGPointZero;
    if (e) CFRelease(e);
    return p;
}

void PearStashCursor(void) {
    if (gCursorStashed) return;
    gStashedCursor = PearCursorLocation();
    gCursorStashed = YES;
}

void PearUnstashCursor(void) {
    if (!gCursorStashed) return;
    CGWarpMouseCursorPosition(gStashedCursor);
    CGAssociateMouseAndMouseCursorPosition(true);
    gCursorStashed = NO;
}

#pragma mark - Pointer capture

// Keeps the hardware pointer inside the game window while mouse-look is in use.
// Without this the cursor escapes onto the desktop on large camera movements:
// the click lands on another app, the game resigns active, and GCMouse stops
// reporting deltas (the camera then looks "stuck"). This is containment, not a
// pointer lock: the cursor stays visible and can still reach the keymapper
// button in the window's top-right corner.
//
// The window rectangle is cached briefly because CGWindowListCopyWindowInfo is
// not cheap enough to call on every 60 Hz mouse flush. Opt in with
// PEAR_MOUSE_CAPTURE=1: by default the pointer is left alone, so it can always
// leave the game window (a game's own pointer lock is handled by the separate
// PointerLockShim).
void PearContainCursorInWindow(void) {
    if (!getenv("PEAR_MOUSE_CAPTURE")) return;

    static CGRect cachedRect = CGRectZero;
    static double cachedAt = 0;
    double now = CACurrentMediaTime();
    if (now - cachedAt > 0.5) {
        cachedRect = PearWindowScreenRect();
        cachedAt = now;
    }
    if (cachedRect.size.width < 2 || cachedRect.size.height < 2) return;

    CGPoint p = PearCursorLocation();
    const CGFloat margin = 4;
    CGRect inner = CGRectInset(cachedRect, margin, margin);
    if (inner.size.width <= 0 || inner.size.height <= 0) return;
    if (CGRectContainsPoint(inner, p)) return;

    CGPoint clamped = CGPointMake(MIN(MAX(p.x, CGRectGetMinX(inner)), CGRectGetMaxX(inner)),
                                  MIN(MAX(p.y, CGRectGetMinY(inner)), CGRectGetMaxY(inner)));
    CGWarpMouseCursorPosition(clamped);
    // A game may have unassociated the pointer from the cursor; re-associating
    // makes sure our warp takes effect and the cursor continues to follow the
    // mouse inside the window.
    CGAssociateMouseAndMouseCursorPosition(true);

    if (getenv("PEAR_DEBUG_TOUCH")) {
        PearLog(@"[PearRuntime][capture] cursor (%.0f,%.0f) clamped to (%.0f,%.0f) window={{%.0f,%.0f},{%.0f,%.0f}}",
                p.x, p.y, clamped.x, clamped.y,
                cachedRect.origin.x, cachedRect.origin.y,
                cachedRect.size.width, cachedRect.size.height);
    }
}

void PearSynthesizeTapCGEvent(CGFloat nx, CGFloat ny) {
    BOOL restore = getenv("PEAR_NO_CURSOR_RESTORE") == NULL;
    if (restore) PearStashCursor();
    PearSynthesizeMouse(YES, nx, ny);
    usleep(40000);
    PearSynthesizeMouse(NO, nx, ny);
    if (restore) PearUnstashCursor();
}

// Self-test: with PEAR_TEST_TAP, tap the window centre ~8 s after launch, so the
// synthesis can be verified against a running game.
__attribute__((constructor))
static void PearTouchSynthesizerInit(void) {
    BOOL testTap = NSProcessInfo.processInfo.environment[@"PEAR_TEST_TAP"] != nil;
    BOOL dumpHID = NSProcessInfo.processInfo.environment[@"PEAR_DUMP_HIDEVENT"] != nil;
    if (!testTap && !dumpHID) return;

    // Resolve the IOHID symbols up front: the CGEvent path never calls
    // PearResolve(), and the HID-event dump below needs gGetIntegerVal.
    PearResolve();

    // Posting synthetic events is gated on the poster's Accessibility trust.
    // Report it so a "posted but never delivered" symptom is unambiguous.
    // (AXIsProcessTrusted is macOS-only, so reach it through dlsym.)
    void *as = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
    Boolean (*axTrusted)(void) = as ? (Boolean (*)(void))dlsym(as, "AXIsProcessTrusted") : NULL;
    BOOL trusted = axTrusted ? (BOOL)axTrusted() : NO;
    PearLog(@"[PearRuntime][touch] AXIsProcessTrusted=%d pid=%d",
          axTrusted ? (int)trusted : -1, (int)getpid());

    // With PEAR_AX_PROMPT, ask the user to grant Accessibility so synthetic
    // events are actually delivered (an untrusted poster's events are dropped).
    if (!trusted && getenv("PEAR_AX_PROMPT")) {
        Boolean (*axTrustedWithOptions)(CFDictionaryRef) =
            as ? (Boolean (*)(CFDictionaryRef))dlsym(as, "AXIsProcessTrustedWithOptions") : NULL;
        if (axTrustedWithOptions) {
            NSDictionary *options = @{ @"AXTrustedCheckOptionPrompt": @YES };
            axTrustedWithOptions((__bridge CFDictionaryRef)options);
            PearLog(@"[PearRuntime][touch] requested Accessibility prompt");
        }
    }

    // Diagnostic: post a cursor move and read it back. If the cursor does not
    // move, the post itself is being dropped (untrusted poster); if it moves but
    // no UITouch arrives, the post is accepted and the problem is elsewhere.
    if (getenv("PEAR_MOVE_PROBE")) {
        CGPoint target = CGPointMake(200, 200);
        CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, target, kCGMouseButtonLeft);
        if (move) { CGEventPost(kCGHIDEventTap, move); CFRelease(move); }
        usleep(200000);
        CGEventRef now = CGEventCreate(NULL);
        CGPoint got = now ? CGEventGetLocation(now) : CGPointZero;
        if (now) CFRelease(now);
        PearLog(@"[PearRuntime][touch] move probe: target=(200,200) cursor=(%.0f,%.0f) accepted=%d",
              got.x, got.y, (got.x == target.x && got.y == target.y));
    }

    // Verify delivery: log any touch that reaches a window's event pipeline.
    Method sendEvent = class_getInstanceMethod(UIWindow.class, @selector(sendEvent:));
    IMP original = method_getImplementation(sendEvent);
    method_setImplementation(sendEvent, imp_implementationWithBlock(^id(UIWindow *self, UIEvent *event) {
        if (event.type == UIEventTypeTouches) {
            NSSet *touches = [event allTouches];
            for (UITouch *touch in touches) {
                CGPoint p = [touch locationInView:self];
                UIView *target = touch.view;
                CGPoint local = target ? [touch locationInView:target] : CGPointZero;
                PearLog(@"[PearRuntime][touch] DELIVERED phase=%ld window=(%.0f,%.0f) view=%@ local=(%.0f,%.0f)",
                      (long)touch.phase, p.x, p.y,
                      target ? NSStringFromClass(target.class) : @"nil", local.x, local.y);
            }
            // Dump the underlying HID event, so a real delivered event can be
            // compared field-for-field against our synthesized one.
            if (getenv("PEAR_DUMP_HIDEVENT") && gGetIntegerVal && gGetType) {
                SEL hidSel = NSSelectorFromString(@"_hidEvent");
                if ([event respondsToSelector:hidSel]) {
                    IOHIDEventRef hid = ((IOHIDEventRef (*)(id, SEL))objc_msgSend)(event, hidSel);
                    if (hid) {
                        PearLog(@"[PearRuntime][hid] ---- real delivered ----");
                        PearDumpHIDTree(hid, 0);
                        // Replay the exact event UIKit just accepted back through
                        // _handleHIDEvent:. If this delivers, the sink is fine and
                        // only our own construction is at fault; if not, the sink
                        // (or its precondition) is the problem.
                        if (getenv("PEAR_REPLAY") && gCreateCopy) {
                            IOHIDEventRef copy = gCreateCopy(kCFAllocatorDefault, hid);
                            if (copy) {
                                SEL h = NSSelectorFromString(@"_handleHIDEvent:");
                                UIApplication *a = UIApplication.sharedApplication;
                                if ([a respondsToSelector:h]) {
                                    PearLog(@"[PearRuntime][hid] replaying captured event via _handleHIDEvent:");
                                    ((void (*)(id, SEL, id))objc_msgSend)(a, h, (__bridge id)copy);
                                }
                                CFRelease(copy);
                            }
                        }
                    } else {
                        PearLog(@"[PearRuntime][hid] real event but _hidEvent was NULL");
                    }
                } else {
                    PearLog(@"[PearRuntime][hid] event %@ has no _hidEvent (classes: %@)",
                          NSStringFromClass(event.class),
                          [event.class respondsToSelector:NSSelectorFromString(@"_hidEvent")] ? @"class-level" : @"none");
                }
            }
        }
        return ((id (*)(id, SEL, UIEvent *))original)(self, @selector(sendEvent:), event);
    }));

    if (!testTap) return;

    // Multi-touch check: hold two independent fingers at once, then release.
    if (NSProcessInfo.processInfo.environment[@"PEAR_TEST_MULTITOUCH"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            PearLog(@"[PearRuntime][touch] TEST multi-touch: two fingers");
            PearSynthesizeVirtualFinger(YES, @"mt-a", 0.30, 0.30);
            PearSynthesizeVirtualFinger(YES, @"mt-b", 0.70, 0.70);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                PearSynthesizeVirtualFinger(NO, @"mt-a", 0.30, 0.30);
                PearSynthesizeVirtualFinger(NO, @"mt-b", 0.70, 0.70);
            });
        });
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PearLog(@"[PearRuntime][touch] TEST tapping centre");
        // Tap repeatedly so we can tell "never delivered" from "occasionally".
        for (int i = 0; i < 6; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                // Virtual digitizer (UINSVirtualDigitizer) is the native, working
                // path and the default; CGEvent and IOHIDEvent are opt-in for
                // comparison via PEAR_TOUCH_CGEVENT / PEAR_TOUCH_IOHID.
                if (getenv("PEAR_TOUCH_CGEVENT")) {
                    PearSynthesizeTapCGEvent(0.5, 0.5);
                } else if (getenv("PEAR_TOUCH_IOHID")) {
                    PearSynthesizeTouch(YES, 0.5, 0.5);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        PearSynthesizeTouch(NO, 0.5, 0.5);
                    });
                } else {
                    PearSynthesizeVirtualFinger(YES, @"pear-test", 0.5, 0.5);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        PearSynthesizeVirtualFinger(NO, @"pear-test", 0.5, 0.5);
                    });
                }
            });
        }
    });
}
