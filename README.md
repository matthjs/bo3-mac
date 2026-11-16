# BO3 for Mac

A launcher and a patched build of BO3MacFix for **Call of Duty: Black Ops III**
on macOS. Together they make Steam Workshop mods and custom zombies maps work
on a Mac, and let you play online with friends on Windows. The app itself is
called **BO3 Launcher**.

**[Download the latest build](https://github.com/matthjs/bo3-mac/releases/latest)** ·
[Original project](https://github.com/redxam/bo3-launcher)

This is a fork of the original BO3 Launcher by redxam. It changes both the
launcher and the copy of BO3MacFix it installs; see
[What this fork changes](#what-this-fork-changes).

## The problem

The Aspyr macOS port of Black Ops III ships without mod support. Subscribe to a
Workshop map on a Mac and nothing happens: the game never loads it, and there is
no in-game mods menu like the Windows version has.

[BO3MacFix](https://github.com/InvoxiPlayGames/BO3MacFix) by Emma
(InvoxiPlayGames) and Anthony (serious) solves the hard part by patching the
game at runtime. Installing it, though, means a terminal, a hand-edited app
bundle, installing Wine, and redoing the whole thing every time Steam verifies
your files.

This launcher wraps that in something you can hand to a friend.

## What BO3MacFix fixes

The Mac port was last updated in 2019 (v98), while the Windows version kept
getting updates. Upstream BO3MacFix patches the running game to fix:

- **Online play.** Sign-in fails on current macOS, because a newer system
  libcurl rejects an HTTP header the game sets by hand. BO3MacFix removes it.
- **Matchmaking with Windows players.** The Mac build reports older network and
  protocol versions, so lobbies turn it away. BO3MacFix reports the Windows
  versions and loads the Windows version's updated scripts and assets, so both
  sides run the same rules.
- **Workshop map crashes.** Aspyr's PNG-to-texture conversion crashes when you
  hover over or select a Workshop map. BO3MacFix skips it.
- **Zombies AI on custom maps.** Havok navmesh files use a different format on
  Mac. BO3MacFix converts them on first load with a patched Windows modding tool
  (`cod2map64`) run under Wine, so a map's first load takes longer.
- **Fatal script errors.** Aspyr made every script error end the game, which
  breaks many mods. BO3MacFix makes them non-fatal, as on Windows.
- **Smaller bugs:** a crash when parsing commands, a controller bug in the
  bundled SDL, and broken navigation in the campaign mission Demon Within.

The game is Intel-only and runs under Rosetta 2 on Apple Silicon, so BO3MacFix
and everything else injected into it is built for x86_64.

## What the launcher does

These come from redxam's original launcher.

- **One-click BO3MacFix install.** Bundles a forked build of the patch and
  installs it into your game, no terminal involved.
- **Workshop mod browser.** Lists every mod you're subscribed to, with sizes,
  thumbnails and descriptions pulled from Steam.
- **Real uninstall.** Deleting a mod unsubscribes you on Steam first, then
  permanently removes the files. Deleting the folder alone does nothing: Steam
  re-downloads it on next launch.
- **Storage breakdown.** Shows how much of your drive the game, the mods, and
  everything else are using, so you know what you're reclaiming.
- **Works from any drive.** Detects Steam libraries on external drives by
  reading `libraryfolders.vdf`, not by assuming a path under your home folder.
- **Skips the intro videos.** Straight to the main menu.
- **Steam integration.** Optionally makes Steam's Play button open the launcher.
  Starting the game straight from Steam skips BO3MacFix and everything else the
  launcher injects, so without this you have to start it from the launcher.
- **DualSense rumble**, for up to four controllers at once. The Mac port's
  ForceFeedback path does nothing on a DualSense, so the launcher injects a shim
  that turns the game's effects into Bluetooth output reports.
- **PlayStation button prompts and icons** everywhere the game would otherwise
  draw Xbox ones: the HUD, the keybind list, the menu footers, and the
  controller diagram on the layout screens.
- **A loading screen** over the black gap between launching and the game's first
  window, which can run close to a minute.

## What this fork changes

### In BO3MacFix

The bundled BO3MacFix is upstream's plus redxam's changes (offline mode, the
friends-only message filter, branding). This fork adds:

- **No stutter on custom maps that stream lots of textures.** The game keeps
  its texture streaming list in order with an insertion sort, which gets very
  slow when many textures change priority at once. On big maps that stalled a
  frame for about half a second, roughly once a second. BO3MacFix now stops the
  insertion sort once it runs too long and finishes with the game's own
  quicksort. Tested on
  [Leviathan](https://steamcommunity.com/sharedfiles/filedetails/?id=2112576356),
  which went from a hitch every second to smooth play. Details in
  [`docs/leviathan-stutter.md`](docs/leviathan-stutter.md).
- **Preview and loading images for Workshop maps and mods.** The Mac port's
  PNG loading crashed the game, so BO3MacFix used to switch it off and the
  menus showed no picture for custom maps. BO3MacFix now loads the images with
  macOS's own decoder.
- **Safer, more reliable map conversion.** The navmesh converter is started
  directly instead of through a shell command built from the map name, its
  output is read to the end, and a map is converted again when its navmesh
  changes, so updated Workshop maps don't keep stale AI navigation.
- **Faster file lookups.** The path hook asked the system for the working
  directory on every file the game opened. It now caches it, which took up to
  a fifth of the file thread's time on large maps.
- **No open debugger port.** The Mac port leaves Havok's Visual Debugger server
  listening on TCP port 25001 on every network interface while a map is loaded.
  BO3MacFix now stops it from opening.
- **Smaller fixes** to string handling and file reads.

### In the launcher

- **One-click Wine install for custom maps.** BO3MacFix converts each custom
  map's navigation data with a Windows modding tool, which needs Wine. The
  launcher downloads a pinned, checksum-verified Wine build and sets it up, so
  you don't need Homebrew. Wine runs quietly during conversion, with no setup
  dialogs hidden behind the game.
- **Updates from this repository.** The launcher checks this fork's GitHub
  releases. The original's update feed also carried a switch that could require
  signing in to an account before playing; this fork removed it.
- **Friends-Only Messages** option, which blocks in-game messages such as
  invites from players who aren't your Steam friends.
- **PlayStation prompts only with a PlayStation controller.** The original
  showed them to every controller, including Xbox and Switch pads.
- **Steam integration fixes.** The Steam redirector ships prebuilt instead of
  being compiled on your Mac, which needed Xcode's command line tools. The
  launcher reads whether integration is on from the game's files, so it notices
  when Steam restores the original, and a failed install puts the original back.
  An option, **Steam's Play Starts the Game**, makes Steam's Play button start
  the game in one click instead of only opening the launcher.
- **Steam overlay** (Shift+Tab) in games started from the launcher, on by
  default and switchable in Options.
- **Removed:** the game downloader (its download server is gone) and the empty
  DLC tab.
- **Smaller fixes:** mod deletion no longer freezes the window, Workshop titles
  with HTML entities display correctly, BO3MacFix is only offered once the game
  is installed, and moving the app to Applications keeps the old copy until the
  new one is in place.

## Requirements

- macOS 14 or later, Apple Silicon or Intel
- A legitimate Steam copy of Call of Duty: Black Ops III (app ID 311210)
- Steam installed and signed in
- For custom maps: Wine, which the launcher offers to install (Options →
  Install Wine for Custom Maps)

The launcher does not distribute the game, any game assets, or Valve's
Steamworks libraries. You need to own and install the game yourself.

## Install

1. Download `BO3-Launcher.zip` from the
   [latest release](https://github.com/matthjs/bo3-mac/releases/latest), unzip
   it, and drag **BO3 Launcher** to **Applications**.
2. Open it. The app isn't notarized by Apple, so the first time macOS says it
   can't verify it. Click **Done**, open **System Settings → Privacy &
   Security**, scroll down, and click **Open Anyway** next to BO3 Launcher.
   You only need to do this once.
3. If macOS asks for permission to read removable volumes, allow it:
   that is how the launcher finds a game installed on an external drive.
4. If it doesn't find your game automatically, drag the game folder onto the
   drop zone. In Steam: right-click **Call of Duty: Black Ops III** →
   **Manage** → **Browse local files**.
5. Click install when it offers to patch the game.
6. Always start the game from the launcher, or turn on Steam integration
   (Options) so Steam's Play button goes through the launcher. Turn on
   **Steam's Play Starts the Game** as well to start it in one click. Starting
   the game from Steam without integration runs it without BO3MacFix.

## Building from source

Requires Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
# Build the BO3MacFix payload the launcher installs (~81 MB output). On first
# run it downloads upstream's pinned release and verifies its checksum.
./scripts/build-macfix-payload.sh

./build-and-run.sh   # runs xcodegen, builds, and opens the app
```

Without an Apple Developer ID in your keychain, the scripts sign ad-hoc, which
is fine for running on your own Mac.

`rumble-shim/dualsense_rumble.c` is compiled by a build phase and bundled into
the app, which installs it next to the game. It is **x86_64** because the game
is, and it carries both the rumble bridge and the PlayStation glyph swap.
`rumble-shim/build.sh` also builds `rumbletest`, a native binary that pulses a
connected DualSense so you can check the Bluetooth path without the game.

`vendor/steam-unsub/steam-unsub.c` is compiled as a separate **x86_64** helper
by a build phase. It has to be: Valve's `libsteam_api.dylib` shipped with the
game is Intel-only, so an arm64 launcher cannot link against it directly. The
helper runs under Rosetta and handles Workshop unsubscribes.

`vendor/SteamRedirector.m` is built into the app as `SteamRedirector`. Steam
integration puts it in place of the game's executable so that Steam's Play
button opens the launcher. It's prebuilt, so players don't need Xcode's
command line tools.

## Licensing and credits

The launcher is a fork of
[redxam/bo3-launcher](https://github.com/redxam/bo3-launcher) by redxam
(maxawad), who wrote the launcher, the DualSense rumble shim and the PlayStation glyph
swap. The original repository has no license file.

`vendor/BO3MacFix-src/` is a fork of
[InvoxiPlayGames/BO3MacFix](https://github.com/InvoxiPlayGames/BO3MacFix),
licensed under the **LGPL 2.1** (see `vendor/BO3MacFix-src/LICENSE.txt`).
redxam's changes and this fork's are listed under
[In BO3MacFix](#in-bo3macfix); the source is published here to satisfy the
license. The patching work it builds on is upstream's.

Credit also to Alyssa / alltheamps for t7patch and the cod2map64 patch, and to
[Dobby](https://github.com/jmpews/Dobby) for the macOS code hooking. The Wine
the launcher installs is [Gcenx](https://github.com/Gcenx/macOS_Wine_builds)'s
macOS build of [Wine](https://www.winehq.org) (LGPL); it is downloaded from
there, not bundled.

Not affiliated with, endorsed by, or supported by Activision, Treyarch, Aspyr,
or Valve.
