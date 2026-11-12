# Vice City / signed MetalSharp Wine validation — 2026-11-11

The supplied Windows `gta-vc.exe` is a 3,088,896-byte i386 PE32 executable
with 14 sections. Its PE header is at `0x880`, its optional header is 224
bytes, and `SizeOfHeaders` is `0xE00`. The `.text` section starts at file
`0xC00`, with `0x27CE00` raw bytes. All nonempty raw sections fit within the
file; `.bss` has no raw data. Rejecting sections solely for starting before
`SizeOfHeaders` incorrectly rejected this game.

Admission now allows that overlap and unused layout declarations while
checking signatures, machine/magic pairing, executable flags, header/table
bounds and nonempty raw-section bounds. This is not proof that Wine can load
any admitted executable. The three EXEs in the supplied game folder passed;
the complete folder imported successfully through ManagedAppService.

The engine (installed then as "PearWine 1.0.1", now loaded as MetalSharp Wine 6.0)
is `MetalSharp-Wine-6.0-arm64.zip` with SHA-256
`25f7dff91000c03c835b800980878acb12c1f952a4b7853f77de7f21fb87046f`.
The upstream bundle has Developer ID team `TQK8H7V7RP`, identifier
`com.metalsharp.wine`, a stapled notarization ticket, and the
`com.apple.developer.cross-architecture-support` entitlement. Its CDHash is
`0d367719bca6c7cce709c4c1deec6d9c2fb5d4a4`. The installed copy passes
`codesign --verify --deep --strict`; no code or signing metadata is changed.
Launch and prefix defaults are now built into PearSilicon (`MetalSharpDefaults`).

Tests on this M1:

- Full suite: 331 XCTest tests, 20 optional skips, zero failures; 24 backup
  tests also passed. A prior updater process-inspection failure did not recur.
- Targeted follow-up after increasing the signed-runtime bootstrap timeout:
  34 tests, one optional skip, zero failures.
- Signed ZIP: hash verification, link/path admission, extraction, external
  registration, installed signature verification and game import passed.
- Managed Vice City launch: `G:\gta-vc.exe` stayed running for the eight-second
  smoke test. The initial 45-second prefix timeout was too short; signed
  bundle initialization now has a bounded 180-second timeout. A fresh-prefix
  rerun passed in 39 seconds including the game smoke interval. Wineboot can
  exit before wineserver flushes system.reg; the launcher now waits up to 15
  seconds for that flush. A fake-engine regression covers the delayed write.

Computer Use permission was unavailable. Rendering, menus, controls and actual
playability are not visually verified. The game is not included in releases.

## 2026-11-12 follow-up

The real game folder was imported again; the CLI observed 35 seconds of
execution and the user confirmed the correct menu/game image (executable
SHA-256 `565ac7f80db4374a5bac5e195f947815451eade528a7bbe877d43317624a4022`).
Sustained gameplay, controls and performance are unverified.

Windows Steam (x64 client build 1794424036) on the same engine: MetalSharp's
kernelbase launcher rule for `\\Steam\\bin\\cef\\` crashed StorageService
(`FATAL target_services.cc(121)`). A drive letter mapped to the Steam folder
avoided it, but Steam recorded the drive root as its install folder and asked to
repair it on the next start. Starting the unchanged client through a link at the
root of C: works across repeated starts; the user confirmed Steam opened.
Sign-in, library and games through Steam are unverified.
