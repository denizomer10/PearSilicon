# Third-party notices

PearSilicon itself is MIT licensed (see `LICENSE`). It builds on, ships, and
drives the components below. None of them are bundled into this repository as
source: the pins live in `docs/ARCHITECTURE.md`, and
`scripts/setup-legacy-engine.sh` fetches and builds them.

## PearLegacyEngine — 32-bit iOS compatibility layer

- Source: https://github.com/denizomer10/PearLegacyEngine
- License: Mozilla Public License 2.0 (`LICENSE` in that repository)
- Derived from touchHLE (https://github.com/touchHLE/touchHLE) and its
  contributors.

PearSilicon runs it as a **separate process**: `AppLauncher.launchLegacy32Bit`
executes the engine binary with the installed `.app` bundle as an argument. The
engine is never linked into the PearSilicon executable, so the MPL's
file-level copyleft applies to the engine's own files only.

The engine binary is redistributed unmodified, built from the pinned commit
recorded in `docs/ARCHITECTURE.md`. PearSilicon's changes to the engine live in
that repository, where the corresponding source is available, as MPL-2.0
requires. If you build your own engine, point PearSilicon at it with
`PEARSILICON_LEGACY_ENGINE` (binary or directory) or place it in the
`PearLegacyEngine/` folder next to the app's resources.

The engine's runtime resources include ANGLE
(https://github.com/google/angle, BSD-3-Clause), which provides the OpenGL ES
implementation that is backed by Metal.

## PearLegacyJIT — Dynarmic fork for Apple Silicon

- Source: https://github.com/denizomer10/PearLegacyJIT
- License: 0BSD (`LICENSE.txt` in that repository)
- Derived from Dynarmic by merryhime (https://github.com/merryhime/dynarmic).

PearLegacyJIT is the ARMv7/Thumb-2 dynamic recompiler inside PearLegacyEngine. It
is compiled into the engine, not into PearSilicon, and is not distributed with
PearSilicon as a separate library. Set `PEAR_DYNARMIC_ROOT` to a checkout of it
when building the engine, otherwise the engine falls back to its bundled
Dynarmic submodule.

## Guest application content

PearSilicon does not include, download, or distribute any iOS application.
Installing an IPA is a user action performed against a file the user already
has.
