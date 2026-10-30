# Startup failures and preparation integrity

## The Genshin / Telemetry report

The reported Genshin 7.1.0 crash is `EXC_BAD_INSTRUCTION (SIGILL)` while dyld is
running an initializer in `Telemetry.framework`. Its image-relative PC is
`0x1ab1c`, and the first instruction word supplied by the report is `0x7a0d1c64`.
The stack contains no positive Metal/AGX evidence. It establishes a CPU instruction
failure during pre-main initialization, **not a demonstrated GPU-generation bug**.
Constructors can call graphics APIs, so the timing alone does not rule every
possible graphics interaction out either.

The original tester binaries are not available in this checkout. The exact
cause of that crash—and whether the other two games have the same cause—remains
unconfirmed. These changes do not certify Genshin as playable on M2, M3, M4 or M5.

## Proven preparation defects addressed

- **Encryption metadata:** previous code called `LC_ENCRYPTION_INFO[_64]` fields
  “legacy guards” and cleared `cryptid` without decrypting the referenced code.
  A nonzero marker is now rejected without changing file bytes. Clearing a marker
  does not make encrypted instructions executable, and PearSilicon does not
  decrypt packages or supply protected content.
- **Universal images:** FAT64 offsets and sizes are read as 64-bit fields. Slice
  ranges, alignment, headers and CPU/subtype agreement are checked. A portable
  ARM64 slice is preferred over ARM64e; ARM64e-only input is not relabeled.
- **Chained imports:** format 3 uses the correct weak-import bit and name offset;
  library ordinal, name and addend fields are preserved by that edit.
- **Command edits:** load-command/section bounds and header slack are checked;
  failed single-image edits do not commit earlier thinning/platform changes.
  Legacy platform conversion preserves version values. Legitimate zippered
  macOS/Catalyst dylibs retain their two platform declarations.
- **Bundle admission:** the main executable and recognized Mach-O files throughout
  the bundle—including extensionless code in resource bundles—are checked before
  plist, signature or code preparation. Errors identify the relative file path.
  Unsupported, encrypted and malformed nested code cannot bypass a same-mode launch.
- **Installation:** extraction errors, including CRC failures, stop installation.
  New installs and replacements are prepared, signed and verified in sibling
  staging directories before an atomic commit. A failed staging transaction does
  not delete the previous installed bundle. This is not a general backup guarantee
  for all app data or every possible filesystem failure.

Preflight is not complete verification of every ABI, binding, initializer,
service or graphics behavior. In particular, general dependency-ordinal remapping
is not implemented; dependency removal is not a general-purpose linker operation.

## Read-only checks

With a build containing these changes:

```sh
pearsilicon validate ~/Downloads/App.app
pearsilicon validate ~/Downloads/App.app/Frameworks/Telemetry.framework/Telemetry
```

The command does not launch the app, install it, create library/work folders,
or initialize/migrate PearSilicon settings. A successful result checks supported
structure, ARM64 ABI, platform metadata and encryption markers—not signatures,
correct decryption, genuine device capabilities or playability.

Run it against an **original, authorized input**, not only a previously prepared
copy. If an older PearSilicon version already cleared encryption metadata, the
new validator cannot reconstruct it or prove that the remaining code is plaintext.
Back up saves and reinstall from a verified unencrypted build; do not patch the
faulting instruction, skip SDK initializers or treat a device-profile change as
proof of GPU compatibility.

## Evidence needed for the remaining diagnosis

1. The other games' complete, sanitized crash reports and exact app/runtime builds.
   “Does not open” is not a shared crash signature.
2. Preflight output for the original app and its Telemetry framework.
3. Matching binary UUIDs/hashes and a comparison of original versus prepared code
   around the fault, if a private binary investigation is possible. Translate the
   image-relative address through segment VM/file mappings; `0x1ab1c` is not
   automatically the file offset.
4. A controlled comparison of the same authorized package on the affected and a
   working machine. CPU generation, OS build, package hash and settings must be
   recorded separately. Attribute a graphics failure only with corresponding
   graphics-path evidence.

Share diagnostics first; do not post app packages, credentials or saves to public
issues. Keep SIP and Gatekeeper enabled.

## Upstream context

- [Apple: SIGTRAP / SIGILL](https://developer.apple.com/documentation/xcode/sigtrap_sigill)
  describes illegal CPU instructions and deliberate traps.
- [PlayCover #1962](https://github.com/PlayCover/PlayCover/issues/1962) reports
  Genshin 6.0 on M2 rejecting Telemetry's iOS platform when Catalyst was required.
- [PlayCover #2138](https://github.com/PlayCover/PlayCover/issues/2138) reports
  Genshin 6.6 on M3 rejecting AstrolabeCommon's platform.

Those upstream reports demonstrate nested-framework preparation failures. They
are **different from** the supplied Telemetry initializer SIGILL and do not
establish an M2–M5-wide GPU defect or a verified fix for Genshin 7.1.
