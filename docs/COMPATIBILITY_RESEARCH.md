# Compatibility investigation — 2026-11-07

This work uses original project code, public API declarations/documentation, process logs, and locally observed behavior. No Apple operating-system implementation or third-party compatibility-runtime source was incorporated. This is a development record, not a legal clean-room provenance certification. Existing runtime use of dynamically resolved UIKitMac interfaces remains a compatibility dependency.

## Confirmed observations

- Host under test: Apple M1, 8-core integrated GPU, 2560×1440 display at 180 Hz, macOS 27.2. No M5/M6 hardware was tested.
- Older scene-less apps can have a live UIKit window and rendering thread while their native UINSWindow is 0×0, or its backing layer has no game content.
- A blanket override of AppKit constraint traversal also suppressed the layout of the system window-restoration alert. Forwarding layout for the alert and its glass host restored readable controls.
- With its saved 1024×768 legacy profile, Gutterball passed the user's clicking, dragging and window-resizing check after contentless key windows were excluded from primary-window selection. Run Sackboy Run also passed an isolated process/window test and received a successful user report. These profiles are not a universal compatibility claim.
- GTA Vice City connected the hidden GCVirtualController and accepted keyboard input, but camera movement failed when native pointer lock reported `locked=0`; raw mouse samples arrived and were discarded. The mode now captures the cursor with `CGAssociateMouseAndMouseCursorPosition(false)` instead of the game's pointer lock, accepts GCMouse deltas while that capture is active, and falls back to NSEvent deltas. The first click inside the game arms capture; Escape releases it. Keyboard/mouse bindings are configurable per app and passed as JSON. In-game camera verification is still pending a user test; this mode uses controller elements and raw mouse deltas rather than touch mouse-look.

## Short performance sample

A 10-second Game Performance trace was collected from the Gutterball menu on this M1. The exported presentation-callback segment contained 247 callbacks over 8.2065 seconds. Callback intervals: median 33.3388 ms, p95 38.8760 ms, p99 38.9445 ms, maximum 38.9825 ms. This sample resembles a 30 Hz menu; it is not a gameplay benchmark or evidence of a GPU-selection defect. Startup and other games need separate captures. Raw traces are local diagnostics and are not release assets.

The runtime now offers opt-in PEAR_PERF_TRACE drawable-acquisition timing. This reports acquisition waits, not GPU duration or FPS. Normal launches do not take timing locks or write per-frame diagnostics. The Metal class-install retry uses one bounded timer which stops on success instead of scheduling 400 separate work items.

## Public interface references

- [Pointer lock behavior](https://developer.apple.com/documentation/uikit/uiviewcontroller/preferspointerlocked)
- [Raw mouse input](https://developer.apple.com/documentation/gamecontroller/gcmouseinput)
- [Hidden virtual controllers](https://developer.apple.com/documentation/gamecontroller/gcvirtualcontroller/configuration/ishidden)
- [Indirect-input compatibility](https://developer.apple.com/documentation/bundleresources/information-property-list/uiapplicationsupportsindirectinputevents)
- [Metal drawable pixel size](https://developer.apple.com/documentation/quartzcore/cametallayer/drawablesize)
- [GPU feature-family detection](https://developer.apple.com/documentation/metal/mtldevice/supportsfamily(_:))
- [Performance timeline analysis](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app)

Chip-model names are not used to fabricate GPU capabilities. A game remains responsible for shaders and rendering choices it makes from actual Metal capabilities. Supporting an API path on M1 does not establish behavior on a later chip.
