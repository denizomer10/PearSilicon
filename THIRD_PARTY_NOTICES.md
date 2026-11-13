# Third-party notices

PearSilicon is MIT licensed (see `LICENSE`). The PearSilicon app bundle also
ships components written by others. This file explains what each one is, how
it is combined with PearSilicon, its license, and where its source is.

Inside a built `PearSilicon.app`, every license text named below is in
`Contents/Resources`:

| Path in `Contents/Resources` | What it covers |
| --- | --- |
| `Licenses/` | PearSilicon, PearRuntime and PearDebug licenses, this file, and `SOURCE.txt` (the exact commits the app was built from) |
| `PearANGLE/LICENSE.ANGLE`, `PearANGLE/THIRD_PARTY_LICENSES.txt` | ANGLE for Mac Catalyst apps and the libraries linked into it |
| `PearLegacyEngine/COPYING`, `LICENSE.MPL-2.0`, `NOTICES.txt`, `SOURCE.txt` | the 32-bit iOS engine binary |
| `PearLegacyEngine/touchHLE_dylibs/` (`README.md`, `COPYING.*`, `angle/`) | guest libraries and the engine's ANGLE build |
| `PearLegacyEngine/touchHLE_fonts/LICENSE.*` | bundled fonts |

`scripts/verify-licenses.sh` checks this layout on every build
(`scripts/build-app.sh`) and release (`scripts/publish-release.sh`), and fails
when a shipped binary has no license next to it.

## Components by the PearSilicon project

| Component | Repository | License | How it is shipped |
| --- | --- | --- | --- |
| PearSilicon | [denizomer10/PearSilicon](https://github.com/denizomer10/PearSilicon) | MIT | app executable |
| PearDebug | [denizomer10/PearDebug](https://github.com/denizomer10/PearDebug) | MIT | Swift package, statically linked into the app executable |
| PearRuntime | [denizomer10/PearRuntime](https://github.com/denizomer10/PearRuntime) | MIT | `libPearRuntime`, `libPearOpenGLES`, `libcxxcompat`, `libswiftUIKit` and the `MarketplaceKit` stub, all built from source |

PearRuntime compiles against the EGL/OpenGL ES headers in the ANGLE checkout
(Khronos headers, Apache-2.0 or MIT); it contains no other third-party code.

## ANGLE for Mac Catalyst apps (`PearANGLE/`)

- Source: [denizomer10/PearANGLE](https://github.com/denizomer10/PearANGLE), a
  modified fork of [ANGLE](https://chromium.googlesource.com/angle/angle),
  pinned by PearRuntime as `third_party/angle`.
- License: BSD-3-Clause (`LICENSE.ANGLE`), copyright The ANGLE Project Authors.
- Shipped as `libEGL.dylib` and `libGLESv2.dylib`, built from source with
  `scripts/build-angle-metal.sh` and loaded dynamically by `libPearOpenGLES`.
  The installer copies the whole `PearANGLE` folder, licenses included, into
  each compatibility app it prepares.
- The non-component build links further libraries straight into the two
  dylibs. `runtime/build.sh` reads them from the build's link inputs and
  collects their licenses into `THIRD_PARTY_LICENSES.txt`: abseil-cpp
  (Apache-2.0), astc-encoder (Apache-2.0), Perfetto (Apache-2.0), Chromium zlib
  (Zlib), xxHash (BSD-2-Clause) and volk (MIT). compiler-rt objects are
  Apache-2.0 WITH LLVM-exception, which needs no notice in binaries.

## PearLegacyEngine — 32-bit iOS engine (`PearLegacyEngine/`)

- Source: [denizomer10/PearLegacyEngine](https://github.com/denizomer10/PearLegacyEngine),
  a modified fork of [touchHLE](https://github.com/touchHLE/touchHLE) by the
  touchHLE project contributors.
- **Source files:** Mozilla Public License 2.0 (`LICENSE.MPL-2.0`).
- **The shipped `touchHLE` binary: GNU GPL version 3 or later** (`COPYING`).
  It statically links OpenAL Soft, which is LGPL-2.0-or-later, so, as upstream
  touchHLE does, the executable as a whole is distributed under
  GPL-3.0-or-later. Every library inside it is listed with its license in
  `NOTICES.txt` (the output of `touchHLE --copyright`):
  - PearLegacyJIT ([denizomer10/PearLegacyJIT](https://github.com/denizomer10/PearLegacyJIT)),
    a fork of [Dynarmic](https://github.com/merryhime/dynarmic) — 0BSD, with
    its bundled libraries (fmt, mcl, oaknut, robin-map, xbyak, zydis, …) under
    MIT/BSD-style licenses and Boost (BSL-1.0);
  - SDL 2 — Zlib; OpenAL Soft — LGPL-2.0-or-later; stb_image — MIT or public
    domain; PVRTDecompress — MIT;
  - about 90 Rust crates under MIT, Apache-2.0, MPL-2.0, Zlib, BSD-3-Clause
    and Unicode licenses, all GPL-3.0 compatible.
- **Corresponding Source:** `SOURCE.txt` names the exact engine, PearLegacyJIT
  and ANGLE commits and every submodule pin of the shipped build. All of them
  are public; `scripts/publish-release.sh` refuses to publish when one of the
  named commits is not on GitHub.
- **Separate program:** PearSilicon starts the engine as its own process
  (`AppLauncher.launchLegacy32Bit`) and talks to it only through command-line
  arguments, environment variables and files. It is never linked into
  PearSilicon, so the GPL applies to the engine, not to the MIT-licensed app
  that ships alongside it.
- Build or replace the engine yourself with `scripts/setup-legacy-engine.sh`,
  or point PearSilicon at another build with `PEARSILICON_LEGACY_ENGINE`.

### Files shipped with the engine

| Path | Content | License |
| --- | --- | --- |
| `touchHLE_dylibs/libgcc_s.1.dylib`, `libstdc++.6.0.9.dylib` | Apple's iPhoneOS 4.0 SDK builds of the GCC runtime, loaded into the emulated iOS app | GPL-2.0-or-later with the libgcc/libstdc++ exceptions (`COPYING.libgcc`, `COPYING.libstdcxx`); source links in `README.md` |
| `touchHLE_dylibs/libz.1.2.3.dylib` | zlib | Zlib (`COPYING.libz`) |
| `touchHLE_dylibs/libsqlite3.dylib` | SQLite 3.6.10 | public domain (`COPYING.libsqlite3`) |
| `touchHLE_dylibs/libxml2.2.dylib` | libxml2 | MIT-style libxml2 license (`COPYING.libxml2`) |
| `touchHLE_dylibs/angle/` | ANGLE component build used by the engine: `libEGL`, `libGLESv2`, Dawn, abseil, libc++ and zlib dylibs | BSD-3-Clause (`LICENSE.ANGLE`); Dawn BSD-3-Clause, abseil Apache-2.0, libc++/libc++abi Apache-2.0 WITH LLVM-exception, zlib Zlib, and others (`THIRD_PARTY_LICENSES.txt`) |
| `touchHLE_fonts/` | Liberation 2.1.5 and Noto Sans CJK JP fonts | SIL Open Font License 1.1 (`LICENSE.liberation`, `LICENSE.noto`) |

## Components PearSilicon downloads, not ships

PearSilicon does not bundle Wine or Windows graphics layers. When the user asks
for them, it downloads upstream release archives directly from their
publishers and verifies GitHub's SHA-256 digest: MetalSharp Wine (Wine,
LGPL-2.1-or-later, with FEX, DXVK and VKD3D), WineHQ builds packaged by Gcenx
(LGPL-2.1-or-later), DXVK (Zlib) and MoltenVK (Apache-2.0). Their licenses and
sources are published with those releases.

## Guest application content

PearSilicon does not include, download or distribute any iOS application or
Windows game. Installing one is a user action performed on a file the user
already has.

## Points that still need confirmation

These are recorded so that they are checked, not assumed:

- PearLegacyEngine's README credits HyperHLE-Reborn. If any of its code was
  copied, its license and copyright lines must be kept and listed here.
- The engine's `touchHLE --copyright` text describes the engine's
  `vendor/dynarmic` submodule; release builds use PearLegacyJIT instead. Both
  are 0BSD with the same bundled libraries, but the text names the upstream
  project.
- `touchHLE_dylibs/angle` was taken from the 0.8.10 package; the binaries
  report ANGLE commit `686adbb2a398`, which is public, but the exact GN
  arguments of that build are not recorded. `THIRD_PARTY_LICENSES.txt` there
  lists a superset of the libraries an ANGLE Metal/Dawn build links.
- The GCC runtime dylibs come from Apple's SDK with Apple's source offer, as in
  upstream touchHLE (see `touchHLE_dylibs/README.md`).
