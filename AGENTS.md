# AGENTS.md

Guidance for coding agents working in this repository. Read `README.md` for the
user-facing pitch and `CHANGELOG.md` for recent history. This file covers what
those two leave out: how the pieces fit, how to build them, and the traps.

## What this is

A native macOS launcher (SwiftUI, macOS 14+) for the Aspyr port of
**Call of Duty: Black Ops III** (Steam app ID `311210`). It installs a forked
BO3MacFix into the game folder and launches the game with injected libraries
that add Workshop mod support, DualSense rumble, PlayStation glyphs, and other fixes.

**Most fixes ship in the injected libraries, not in the launcher.** The launcher
installs, refreshes, and launches. Before you change anything, work out which
of the four build products below the change belongs in.

## The four build products

| Product | Source | Arch | Ends up |
|---|---|---|---|
| `BO3 Launcher.app` | `Sources/*.swift` | native (arm64/x86_64) | `/Applications` |
| `BO3MacFix.dylib` (+ upstream assets) | `vendor/BO3MacFix-src/` (LGPL 2.1 fork) | **x86_64** | `Resources/BO3MacFix.tar.gz` → `<game>/BO3MacFix/` |
| `DualSenseRumble.dylib` | `rumble-shim/dualsense_rumble.c` | **x86_64** | app `Resources/` → `<game>/BO3MacFix/` |
| `steam-unsub` helper | `vendor/steam-unsub/steam-unsub.c` | **x86_64** | app `Contents/MacOS/` |

There is also `vendor/SteamRedirector.m`, built by a post-build phase as a
universal binary at `Contents/MacOS/SteamRedirector`. When the player enables
Steam integration, `GameLauncher.installSteamIntegration` copies it over the
game's `AppBundleExe` so that Steam's Play button opens the launcher. The
original is backed up as `AppBundleExe_original`. Players never need a compiler,
so don't reintroduce compiling anything on the user's machine.

Everything that loads into or talks to the game is x86_64, because the game and
Valve's bundled `libsteam_api.dylib` are Intel-only and run under Rosetta. Do
not "fix" these to arm64 or universal.

## Launch flow (`GameLauncher.launch`)

1. Resolve the game folder (`Paths.bo3Root`): a saved custom path, then
   auto-detection from Steam's `libraryfolders.vdf`, then the default Steam path,
   then `~/Documents/Call of Duty Black Ops III` (non-Steam install).
2. If BO3MacFix is missing, prompt and extract the bundled tarball (`MacFixInstaller.install`).
3. **On every launch**, `syncMacFixDylib()` and `syncRumbleDylib()` copy the
   bundled libraries over the game-folder copies when the bytes differ. This is
   how launcher updates reach players. Keep it that way (see 1.2.4 in the changelog).
4. `posix_spawn` `CoDBlkOps3_Exe` with `POSIX_SPAWN_SETSID`, so the game does not
   inherit the launcher's HID claims, and with:
   - `DYLD_INSERT_LIBRARIES=<BO3MacFix.dylib>:<DualSenseRumble.dylib>[:existing]`
   - `WINEPREFIX=<game>/BO3MacFix/pfx`, `SteamAppId=311210`
   - `BO3MACFIX_OFFLINE=1` for "launch without Steam" / non-Steam installs
5. Fallbacks: run `Install_BO3MacFix 9`, then `steam://rungameid/311210`.
6. `LoadingOverlay` covers the black gap until the game window appears.
   `ControllerManager` is suspended while the game runs and resumed on exit.

## Building

Prerequisites: Xcode, `xcodegen` (`brew install xcodegen`). The `.xcodeproj` is
generated and git-ignored, so edit `project.yml` and never the project file.

```bash
# 1. Once, or whenever vendor/BO3MacFix-src changes. Downloads upstream's pinned
#    release tar (checksum-verified) on first run, or pass a path to one.
./scripts/build-macfix-payload.sh

# 2. Debug build + open
./build-and-run.sh        # runs xcodegen, builds into ./build, opens the app

# Shim only (also builds `rumbletest`, a native tool that pulses a DualSense):
./rumble-shim/build.sh            # add `install` to copy into a mounted game folder
```

- The Xcode post-build phases build the rumble shim and `steam-unsub` **from
  source** every time and copy `Resources/BO3MacFix.tar.gz` in. The build fails
  if the payload tarball hasn't been generated.
- `scripts/build-macfix-payload.sh`, `rumble-shim/build.sh` and
  `build-and-run.sh` sign with the maintainer's identity when it's in the
  keychain and fall back to ad-hoc signing otherwise. Ad-hoc is fine for local
  runs. Notarization requires the Developer ID on every binary, including the
  ones inside the tarball.
- `./release.sh` archives, signs, notarizes (keychain profile `notarytool-profile`),
  staples, and writes `build/BO3-Launcher.zip`. It's maintainer-only.

There are **no automated tests**. Verify by building, launching the game, and
reading the shim log at `~/Library/Logs/bo3-rumble.log`.

## Releasing / versioning

A version bump touches all of these. Keep them consistent:

- `project.yml`: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (the build number)
- `VERSION.json`
- `CHANGELOG.md`: newest first, `## X.Y.Z (build N) - YYYY-MM-DD`
- A GitHub release on `matthjs/bo3-mac` tagged `vX.Y.Z`, matching
  `MARKETING_VERSION`. `UpdateChecker` compares that tag numerically against
  `CFBundleShortVersionString`, so a release whose tag isn't higher is
  invisible to users. It only opens the release page; nothing auto-installs.
  Upstream's feed on bo3.redxam.com is deliberately not used: it would offer
  upstream builds, and its `auth` block was a remote sign-in switch that this
  fork removed (`AccountGate`).

Never hardcode the version string. Read `CFBundleShortVersionString` (see the 1.2.3 fix).

## Rumble shim internals (`rumble-shim/dualsense_rumble.c`)

The shim loads as a constructor (`ds_init`) and works in three ways:

- **dyld interposing** (`DYLD_INTERPOSE`) of the ForceFeedback API, the
  IOHIDManager matching callback, and `AudioQueueSetProperty`. Bluetooth
  DualSense pads (054C:0CE6) look like FF devices to the game's static SDL
  2.0.7, and effects become 78-byte BT output reports (`0x31`, CRC32 over a
  `0xA2` seed). Up to 4 pads, each with its own HID handle and sequence counter.
- **Patching data in the game binary**: the button-glyph table at
  `GLYPH_TABLE_VMADDR` is repointed at its PS3 column.
- **An inline hook** on `DB_FindXAssetHeader` (`DB_FIND_VMADDR`, 17-byte
  prologue moved into a trampoline) that swaps menu image names to PlayStation icons.

The addresses are specific to game build **CODBUILD9-764**. Every patch checks
the expected bytes, row IDs, and segment permissions before writing, so a
different game build is left alone instead of corrupted. Keep that rule for any
new patch: verify before you write, and do nothing if the check fails.

**Audio:** the shim swallows `kAudioQueueProperty_CurrentDevice` so queues
follow the system default output. Don't try to re-point a live queue instead.
A running queue rejects it with `kAudioQueueErr_InvalidRunState` (-66678), and
stopping the queue to force the change ends the stream for good, which leaves
silence on the right device.

Debug env vars, set in the game's environment: `DS_PAD_ORDER`, `DS_XBOX_GLYPHS`
(disable the PS swap), `DS_MENU_PROBE` (log requested asset names),
`DS_DUMP_LUA`, `DS_NO_AUDIO_FOLLOW`. BO3MacFix reads `BO3MACFIX_OFFLINE`,
`BO3MACFIX_PLAYERNAME`, `BO3MACFIX_NETWORKPASSWORD`, `BO3MACFIX_FRIENDSONLY`,
and `BO3MACFIX_WINEPATH`.

`rumble-shim/play-with-rumble.command` runs the shim through upstream's own
installer menu, which is handy for testing outside the launcher.

## Hard-won rules

- **Writing into the game folder:** stage the file in the **same directory**,
  then `replaceItemAt`/`mv`. Never stage in `NSTemporaryDirectory`, because the
  game is often on another volume and `replaceItemAt` fails across volumes.
  Never overwrite a dylib in place either, because dyld can see a half-written
  file and reject its signature.
- **Clear quarantine** (`xattr -c`) on anything copied into the game folder.
  dyld won't inject a quarantined library.
- **Don't re-extract the whole tarball** over an existing install. The Wine
  prefix `BO3MacFix/pfx` lives there and is machine-specific. The payload script
  strips `pfx` for the same reason.
- **Tarballs:** build with `--no-mac-metadata --disable-copyfile`. AppleDouble
  files break extraction onto non-APFS drives.
- **Steam libraries can be on any volume.** Identify one by its
  `steamapps/common/<game>` layout (`Paths.steamAppsRoot`), never by comparing
  against a home-folder path.
- **Never redistribute Valve or game files.** `steam-unsub` `dlopen`s the game's
  own `libsteam_api.dylib`.
- **Workshop uninstall** must unsubscribe through Steam (`SteamUnsubscriber`)
  before deleting files. Otherwise Steam downloads the mod again.
- **The BO3MacFix fork** stays LGPL 2.1 with its source published. Keep the diff
  from upstream small, and credit upstream. It currently changes branding and
  window titles, and fixes map conversion (`posix_spawn` instead of a shell
  command built from the map name, the converter's output read to the end,
  reconversion when a map's navmesh hash changes) plus a few small memory and
  string bugs. Those fixes are worth offering upstream.
- The launcher is not sandboxed (the entitlements are empty) and uses hardened
  runtime only in Release. The game is launched unhardened, which is what makes
  `DYLD_INSERT_LIBRARIES` work.

## Swift source map

| File | Role |
|---|---|
| `LauncherApp.swift` | `@main`, AppDelegate startup sequence, trims the menu bar |
| `ContentView.swift`, `HeaderView.swift` | Routing (setup / download / tabs), Play button, options menu |
| `Paths.swift` | Game-folder resolution, Steam library detection, drag and drop |
| `GameLauncher.swift` | Spawning the game, Steam integration (AppBundleExe swap) |
| `MacFixInstaller.swift` | Tarball install, per-launch dylib sync |
| `ModsView.swift`, `SteamWorkshop.swift`, `SteamUnsubscriber.swift` | Workshop list, metadata (Steam Web API with HTML-title fallback), unsubscribe |
| `StorageInfo.swift`, `StorageBarView.swift` | Disk usage breakdown |
| `GameDownloader.swift`, `DownloadView.swift` | Chunked download and decompression of a non-Steam game install (S3 manifest) |
| `ControllerManager.swift`, `FocusManager.swift` | GameController navigation of the launcher UI |
| `LoadingOverlay.swift` | Full-screen cover until the game window appears (240 s timeout) |
| `UpdateChecker.swift` | Manual update check against this fork's GitHub releases |
| `AppMover.swift`, `PermissionChecker.swift` | Move to /Applications, Input Monitoring permission prompt |
| `WhatsNewView.swift`, `SteamWebView.swift`, `SetupView.swift`, `Theme.swift` | UI |

## Style

- Swift 5.9, SwiftUI with AppKit where needed (`NSAlert`, `NSOpenPanel`). Static
  `enum`/`struct` namespaces for services, `ObservableObject` singletons for state.
- Comments explain **why**, often citing the bug that forced the choice. Keep
  writing them that way, and don't delete one unless the reason it gives no longer holds.
- Changelog entries say what the user sees, then the root cause, with code
  identifiers in backticks.
