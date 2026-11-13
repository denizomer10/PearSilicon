# ANGLE integration — development progress, 2026-11-13

## Implemented and verified

- Work branches: `codex/angle-metal-bridge` in PearSilicon/PearRuntime;
  `codex/pearruntime-metal` in the existing `denizomer10/angle` fork checkout.
- PearRuntime pins the fork as `third_party/angle`. The initial upstream base
  was `686adbb2a39854ab687da009e534f6842a85f453`; the tested Apple thread-exit
  fixes are `9e214cf` (thread cleanup) and `f405241` (host-layer positioning)
  on `codex/pearruntime-metal`. Its original LICENSE is retained.
- The original `PearANGLEBackend` loader is compiled into `graphics-gl`.
  It initializes an explicit ANGLE Metal display, resolves EGL/GLES entry
  points and refuses backend replacement in a running process. It never
  silently falls back to system EAGL. No initializer switches games to it yet.
- A real arm64 Catalyst process loaded the existing legacy engine's macOS
  ANGLE libraries, initialized EGL 1.5/Metal, cleared a 16×16 pbuffer and read
  back the expected RGBA `(64,128,191,255)` on Apple M1.
- A separate loader test passed missing-library recovery and immutable
  backend selection. Neither test creates a window or generates input.

The first probe used existing staged binaries. The current suite defaults to
the **source-built fork** in `runtime/third_party/angle/out/PearMetal`.
Run `bash scripts/build-angle-metal.sh --sync` to provision/build/test it,
or omit `--sync` once dependencies are present. It uses DEPS-pinned Chromium
Clang, the local Xcode SDK, Metal only and four compile jobs by default.
`pearruntime-build.json` records the revision, tracked source diff, GN args
and dylib/test-source hashes after tests pass. A new build invalidates any old
success manifest before compilation. These binaries are not yet bundled for
64-bit games. Final redistribution requires dependency license notices.

## Context and presentation milestone

- `PearANGLEContext` implements same-version sharegroups, thread-local current
  contexts and explicit pixel-sized pbuffer drawables. Ownership uses pthread
  identities, independent of Foundation's thread dictionary lifecycle.
- Resize allocates/rebinds the replacement before destroying the old surface.
  A context current on another thread cannot be stolen or resized.
- Source framebuffer color attachment 0 can be copied to the EGL drawable;
  read/draw framebuffer bindings, viewport, scissor, color mask and pre-existing
  caller GL errors survive presentation. Current format contract is RGBA8.
- GLES2 `ANGLE_framebuffer_blit` prohibits scaling, so mismatched pixel sizes
  are rejected before GL calls. GLES3 uses core blit for scaling. This is not
  a claim that upscaling increases a game's internal rendering resolution.
- Real GPU tests pass shared-texture survival after the first context is
  destroyed, resize/readback, incomplete-FBO rollback, explicit cross-thread
  migration, 16 implicit thread-exit/rebind cycles, and GLES2/3 GLSL compile,
  link and triangle readback on Metal. No visible windows or input automation.

The thread-exit test first reproduced `EGL_BAD_ACCESS (0x3002)` with the old
staged ANGLE. The fork enables Apple thread cleanup and temporarily restores
the original ANGLE thread TLS pointer during cleanup. Without that restoration
the scoped current-context synchronizer dereferenced a cleared TLS slot. Both
failures were caught before enabling any game routing.

## Native-layer surface milestone

- Contexts can bind an explicit `CAMetalLayer` or a `CALayer` host through
  `eglCreateWindowSurface`. EGL-reported dimensions are the committed pixel
  dimensions; layer points and backing scale remain separate.
- A change to bounds or contentsScale rejects presentation until an explicit
  detach/rebind at the frame boundary. The future EAGL adapter must update its
  renderbuffer and input geometry in the same transaction. This core does not
  yet provide that game-level geometry transaction.
- Replacement binding creates/makes-current the new surface before releasing
  the previous one. Invalid geometry and duplicate native hosts preserve the
  previous drawable. Detaching restores a pbuffer without replacing the context.
- A regression test first failed for a host whose frame origin was nonzero:
  ANGLE positioned its child using the host's **frame** in the ancestor's
  coordinate space. The fork now uses the host's **bounds**. The test also uses
  a nonzero bounds origin, verifies child removal on detach, and reads back
  actual cyan pixels before swapping.
- Tests passed native Metal clear/readback/swap at 1x, 2x and 1.5x scales,
  changed-geometry rejection, duplicate-host rollback and pbuffer recovery.
  All layers belong to the headless test process. This validates EGL/Metal
  surfaces, not visible game composition, mouse input or fullscreen behavior.
- The complete PearRuntime Catalyst dylib builds with the new surface core.
  Installed games and their default renderer remain unchanged.

## Remaining routing work

1. Route game class imports to the separately named, tested public-selector
   adapter. Audit dynamic class lookups; system and ANGLE contexts cannot mix.
2. Extend the RGBA8 renderbuffer adapter for RGB565/sRGB, multisampling,
   scheduled presentation and GLES1. Detached-layer tests are not onscreen game
   presentation. Track deletion/reuse of GL names in the import wrappers.
3. Import/re-export routing for linked GLES calls as well as dynamic
   `EAGLGetProcAddress` lookups. Do not mix system GL objects with ANGLE ones.
4. One geometry snapshot for logical game points, drawable pixels, visible
   rectangle, backing scale and generation. Resize updates rendering and
   input together. Preserve the logical aspect instead of guessing from a
   maximized Mac window. Pixel density remains separate from game coordinates.
5. Complete license/dependency notices and packaging/signing. Then native
   surface/readback and actual-game
   resize, fullscreen, touch, rendering and performance checks before defaults.

## EAGL selector and renderbuffer milestone

- `PearEAGLContext`/`PearEAGLSharegroup` implement the public context,
  sharegroup, current-context, drawable-storage and immediate-presentation
  selectors over ANGLE. They retain distinct Objective-C class names and do
  not intercept installed games. Wrapper TLS retains the current wrapper;
  the context core independently owns/unbinds the native EGL context.
- Drawable-property constant values were checked through the system's public
  exported constants in a separate read-only probe. The adapter includes no
  Apple implementation and calls no system GL entry points.
- `ANGLEDrawable.mm` allocates the bound ANGLE renderbuffer at EGL's actual
  pixel dimensions, validates RGBA8/single-sample storage and presents through
  a private cached FBO. The FBO is detached from the game renderbuffer after
  each presentation and freed when its native context is destroyed. Caller
  read/draw FBOs, renderbuffer, viewport/scissor and existing GL errors survive.
- Source renderbuffer contents survive presentation, including retained
  backing. Nil drawable releases storage. Unsupported formats and scheduled
  presentation fail explicitly; they are not silently approximated.
- Successful allocation publishes one immutable geometry record containing
  logical bounds, drawable pixels, scale and a generation. Input-thread
  queries require no GL context or GL state changes. A changed layer, an
  invalidated storage record or a stale event generation is rejected.
  These mappings are not yet connected to the game's UIKit touch events.
- The render thread checks actual renderbuffer dimensions/format/sample count
  before presentation. Direct engine reallocation invalidates mismatched
  metadata. Future GL import wrappers must track deletion/name reuse; metadata
  alone cannot distinguish a deleted and recreated identical GL name.
- Real GLES2/3 tests passed EAGL-style allocation/presentation, retained blue
  pixel readback, separate read/draw FBO restoration, resize generation and
  input-thread mapping. A selector-level test passed RGBA8 magenta readback,
  sharegroup version guards, context ownership and eight implicit thread-exit
  wrapper-release cycles. The full Catalyst runtime builds successfully.

The public adapter and renderbuffer bridge are development components. They
do not yet route a game's imported GLES functions, dynamic proc/class lookups,
or resize/touch dispatch. Do not infer a Minecraft or Cut the Rope fix from
these tests. No installed application or default graphics profile was changed.

`scripts/audit-angle-imports.py` inventories public ABI imports only. The main
Cut the Rope executable imports 50 GL functions and EAGLContext; Minecraft's
imports 88 and EAGLContext. Imports and loaded frameworks do **not** establish
which renderer a particular run uses. Frameworks and runtime lookups still
need auditing. No game implementation is copied or disassembled by the script.

ANGLE translates GLES/EGL into a backend such as Metal. It does not consume
arbitrary native Metal API calls. A native Metal game needs a separate adapter
if it is to enter the same abstraction; this is not provided by this milestone.
ANGLE's Metal backend still uses the OS Metal driver.

The bridge code is original PearRuntime code based on public API interfaces.
ANGLE is an explicitly selected, licensed third-party dependency; it is not
presented as original clean-room PearRuntime implementation or as a legal
provenance certification. No Apple OS implementation is included.

References: [ANGLE fork](https://github.com/denizomer10/angle),
[upstream support matrix](https://chromium.googlesource.com/angle/angle/+/main/README.md).
