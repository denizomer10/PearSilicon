# Vice City / signed PearWine validation — 2026-11-11

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

PearWine 1.0.1 pins `MetalSharp-Wine-6.0-arm64.zip` with SHA-256
`25f7dff91000c03c835b800980878acb12c1f952a4b7853f77de7f21fb87046f`.
The upstream bundle has Developer ID team `TQK8H7V7RP`, identifier
`com.metalsharp.wine`, a stapled notarization ticket, and the
`com.apple.developer.cross-architecture-support` entitlement. Its CDHash is
`0d367719bca6c7cce709c4c1deec6d9c2fb5d4a4`. The installed copy passes
`codesign --verify --deep --strict`; no code or signing metadata is changed.
PearWine's overlay lives beside the app at `Runtime/share/pearwine`.

Tests on this M1:

- Full suite: 331 XCTest tests, 20 optional skips, zero failures; 24 backup
  tests also passed. A prior updater process-inspection failure did not recur.
- Targeted follow-up after increasing the signed-runtime bootstrap timeout:
  34 tests, one optional skip, zero failures.
- Signed ZIP: hash verification, link/path admission, extraction, external
  overlay, registration, installed signature verification and game import passed.
- Managed Vice City launch: `G:\gta-vc.exe` stayed running for the eight-second
  smoke test. The initial 45-second prefix timeout was too short; signed
  bundle initialization now has a bounded 180-second timeout. A fresh-prefix
  rerun passed in 39 seconds including the game smoke interval. Wineboot can
  exit before wineserver flushes system.reg; the launcher now waits up to 15
  seconds for that flush. A fake-engine regression covers the delayed write.

Computer Use permission was unavailable. Rendering, menus, controls and actual
playability are not visually verified. The game is not included in releases.

## 2026-11-12 integration follow-up

The subsequent PearWine 2.0 integration used the real game folder again. The
integrated CLI observed 35 seconds of execution and the user confirmed correct
menu/game image. This supersedes the earlier lack of visual confirmation for
that local run only. See [scoped evidence and Steam blocker](PEARWINE_INTEGRATION.md)
for the exact executable hash, host and limits; sustained gameplay is unverified.
