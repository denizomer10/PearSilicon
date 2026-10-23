# `pearsilicon` — command line tool

`pearsilicon` installs and launches iOS apps through PearSilicon without using
the GUI. It is built into the app binary, so it shares the installer, patcher,
signer, launcher and keymap code with the app: whatever the GUI does, the CLI
does the same way.

It is designed for two workflows:

- **installing** an app package (or an Xcode-built `.app`) and launching it;
- **developing** an iOS app in Xcode and running it natively on the Mac, with no
  simulator, with logs and LLDB.

---

## Getting the command

The CLI lives in the PearSilicon binary, so there are no extra components to
install.

### After installing the app

```sh
sudo ln -sf /Applications/PearSilicon.app/Contents/MacOS/PearSilicon \
               /usr/local/bin/pearsilicon
pearsilicon --version
```

Or run `pearsilicon link` (from the app binary) and it creates that symlink for
you, printing the `sudo` command if it cannot.

### From a checkout

```sh
swift build
bin/pearsilicon help          # finds .build/debug/PearSilicon
# or, directly:
.build/debug/PearSilicon help
```

`bin/pearsilicon` only finds the binary; every command is implemented in the
app target (`Sources/PearSilicon/App/CLI.swift`).

> **Do not add a SwiftPM product named `pearsilicon`.** macOS filesystems are
> case-insensitive by default, so it collides with the `PearSilicon` app
> product and the two binaries overwrite each other. That is why the wrapper is
> a shell script in `bin/`.

---

## Commands

```
pearsilicon install <package|app>   Prepare and install an app package or an Xcode-built .app
pearsilicon run <package|app>       install + launch (--no-launch to stop after install)
pearsilicon launch <id|name>    Launch an installed app
pearsilicon debug <id|name>     Launch with touch logging and follow the log
pearsilicon stop <id|name>      Terminate a running app
pearsilicon list                List installed apps (--json for machines)
pearsilicon info <id|name>      Paths, version, keymap, runtime, pid
pearsilicon uninstall <id|name> Remove an app and its keymap
pearsilicon keymap <id|name>    Print the keymap (--path, --generate, --set FILE)
pearsilicon keys <id|name> [on|off]  Print or set the keymapper toggle
pearsilicon hud <id|name> [on|off]   Print or set the Metal HUD/FPS overlay
pearsilicon pointerlock <id|name> [on|off]  Allow or disallow the game's pointer lock
pearsilicon logs <id|name>      Print or follow the log (--follow, --system)
pearsilicon paths               Show the Application Support layout
pearsilicon doctor              Check Xcode, runtime and library readiness
pearsilicon link                Symlink this binary to /usr/local/bin
pearsilicon xcode <project>     Build a scheme for a device, install, launch
```

`<id|name>` accepts either the bundle identifier or the display name. An
ambiguous display name lists the candidates instead of guessing.

### Common options

| Option | Meaning |
| --- | --- |
| `--keys` / `--no-keys` | Force the keymapper on/off for this launch (otherwise the per-app setting, then the global default, applies) |
| `--metal-hud` / `--no-metal-hud` | Force Metal's FPS/performance overlay on or off for this launch |
| `--pointer-lock` / `--no-pointer-lock` | Force the game's pointer lock on or off for this launch |
| `--log` | Write `~/Library/Application Support/PearSilicon/Logs/<id>.log` and follow it; the CLI exits when the app exits |
| `--wait` | Wait for the app to exit without creating a log file |
| `--env KEY=VALUE` | Extra environment variable for the game (repeatable) |
| `--trace` | Shorthand for the runtime's touch debugging (`PEAR_DEBUG_TOUCH=1`) |
| `--lldb` | (`debug` only) attach LLDB to the launched process |
| `--no-keymap` | Do not auto-generate a starter keymap at install time |
| `--yes` | (`uninstall`) skip the confirmation prompt |

Exit codes: `0` success, `1` expected failure (not installed, invalid input),
`126`/`127` the wrapper could not execute PearSilicon.

### Examples

```sh
pearsilicon install ~/Downloads/App.app --launch
pearsilicon run ~/Downloads/App.app --keys --log
pearsilicon debug com.example.game --lldb
pearsilicon logs com.example.game --follow
pearsilicon keymap com.example.game --generate
pearsilicon keymap com.example.game --set ./my-keymap.json
pearsilicon keys com.example.game on
pearsilicon hud com.example.game on
pearsilicon pointerlock com.example.game off
pearsilicon run ~/Downloads/App.app --metal-hud
pearsilicon list --json
pearsilicon doctor
```

`doctor` prints the macOS/arch, whether a full Xcode is installed *and selected*,
the runtime dylib it would load, and the library location. If Xcode is
missing, `pearsilicon xcode` refuses with the same instructions instead of
letting `xcodebuild` fail cryptically.

---

## Installing an app

`install` accepts two shapes:

- **package** — unzipped, the `Payload/*.app` is prepared and signed;
- **`.app`** — a bundle produced by an Xcode device build (or any iOS `.app`).

The pipeline is the same as the GUI: `Info.plist` rewrite → legacy metadata
removal → Mach-O platform patch (iOS → Mac Catalyst, arm64) → loading the
runtime with `LC_LOAD_DYLIB` → inside-out ad-hoc signing with the loader entitlements.

**Simulator builds are rejected** at install time. Their binaries target the
simulator runtime and cannot be turned into Catalyst binaries; build for a
device (`generic/platform=iOS`) instead. `pearsilicon xcode` does that for you.

A starter keymap is generated if the app has none (disable with `--no-keymap`).
The keymapper itself stays opt-in: pass `--keys`, or enable it for the app in
the GUI. Without it, no keymap path is passed and the runtime installs no input
handlers at all.

---

## Xcode integration

### Option 1 — let the CLI build

```sh
pearsilicon xcode ~/Code/MyApp/MyApp.xcodeproj --scheme MyApp
# workspace:
pearsilicon xcode ~/Code/MyApp/MyApp.xcworkspace --scheme MyApp
```

This runs `xcodebuild` for `generic/platform=iOS` with code signing disabled
(PearSilicon signs the bundle itself), reads `BUILT_PRODUCTS_DIR` /
`FULL_PRODUCT_NAME` from the build settings, installs the product and launches
it. If no full Xcode is selected it stops with the `xcode-select` command to run
(see `pearsilicon doctor`). Options:

| Option | Default |
| --- | --- |
| `--scheme NAME` | required |
| `--configuration NAME` | `Debug` |
| `--destination DEST` | `generic/platform=iOS` |
| `--no-launch` | install only |
| `--keys` / `--no-keys`, `--log`, `--env` | as usual |

Derived data is kept under
`~/Library/Application Support/PearSilicon/Work/XcodeDerivedData`, so rebuilds
are incremental.

### Option 2 — keep Xcode's Run button

Point the scheme's Run action at the PearSilicon binary and pass the built
product as an argument:

1. **Product → Scheme → Edit Scheme → Run**
2. **Executable:** *Other…* →
   `/Applications/PearSilicon.app/Contents/MacOS/PearSilicon`
3. **Arguments:** `run "$(BUILT_PRODUCTS_DIR)/$(FULL_PRODUCT_NAME)" --log`
4. Set the destination to a **device** (not a simulator) before building.

Xcode expands the build settings in scheme arguments. The command installs the
just-built bundle, launches it and follows the log; when the app exits, the CLI
exits, so the Run session ends cleanly.

If Xcode insists on a simulator destination for a custom executable, use Option
1 (or a *Run Script* phase that calls `pearsilicon run …`) instead.

---

## Debugging

`debug` launches with a log file and touch tracing, then follows the log:

```sh
pearsilicon debug com.example.game
pearsilicon debug com.example.game --lldb
```

The installer always ad-hoc signs with `com.apple.security.get-task-allow`, so
LLDB can attach to the process. `--lldb` waits a moment and runs `lldb -p <pid>`.

The runtime also logs through `os_log` (subsystem `com.pearsilicon.runtime`):

```sh
pearsilicon logs com.example.game --system
# equivalent to:
log stream --style compact --predicate 'subsystem == "com.pearsilicon.runtime"'
```

For the full environment-variable reference, see the README diagnostics table.

---

## Environment overrides

| Variable | Purpose |
| --- | --- |
| `PEARSILICON_APP` | Path to an `.app` or binary to use (wrapper and runtime lookup) |
| `PEARSILICON_RUNTIME` | Path to `libPearRuntime.dylib` to load |
| `--env KEY=VALUE` | Anything passed to the launched app (`PEAR_*`) |

`bin/pearsilicon` prefers a checkout's `.build/debug/PearSilicon`, then
`.build/release`, then an installed app that carries the CLI marker
(`Contents/Resources/pearsilicon-cli`) — an older app without the marker is
skipped so that it cannot open the GUI by accident.

---

## Files it touches

```
~/Library/Application Support/PearSilicon/
  Applications/<bundleID>.app
  Keymaps/<bundleID>.json
  Logs/<bundleID>.log
  Work/XcodeDerivedData/          (pearsilicon xcode)
```

The GUI listens for `com.pearsilicon.libraryChanged` and refreshes its library
when the CLI installs or removes an app, so an open window stays in sync.
