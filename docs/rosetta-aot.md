# Rosetta AOT vs JIT

Findings from 16 November 2026 on a MacBook Pro M5 Pro with 24 GB RAM, running macOS 27.2.1, BO3 build CODBUILD9-764 under Rosetta 2.

## Question

BO3MacFix and the rumble shim write into the game's code at runtime. That makes Rosetta drop its ahead-of-time (AOT) translation of the whole executable, so the whole game runs through its just-in-time (JIT) translator.
[BO3MacFix PR #76](https://github.com/InvoxiPlayGames/BO3MacFix/pull/76) avoids this by starting a copy of the executable with every patch already written into the file.
It reports AOT coverage going from about 1% to about 96%, but no frame rate numbers.
Is building the same thing here worth it?

## Result

**Not on this machine.** Both runs held the 120 fps display cap with no hitches the frame log could see. The JIT run used about 7% more CPU.

| | Stock game (AOT) | Through the launcher (JIT) |
|---|---|---|
| `CoDBlkOps3_Exe.aot` mapped | yes, 23 MB resident | no |
| Rosetta JIT region, resident | about 1 MB | 22.6 MB |
| Gameplay recorded | 212 s | 225 s |
| Average fps during gameplay | 119.95 | 119.99 |
| Windows with dropped frames (out of about 270) | 2, the worst losing about 33 ms | 0 |
| CPU in use during gameplay | about 3.4 to 3.5 cores | about 3.7 cores |

- **The problem is real.** Through the launcher, Rosetta runs the game entirely on the JIT, as PR #76 describes.
- **On an M5 Pro it costs little.** The game stays at the cap either way, so AOT would show up only as lower CPU use, and so lower power and heat.
- **Where AOT could still matter:**
  - slower Macs, such as a base M1
  - scenes heavy enough to drop below the cap, such as large custom maps or high rounds
  - launch time, and one-off hitches the first time new code runs. These runs didn't measure either.

## Method

The official Zombies map The Giant was played solo twice, with the same settings and roughly the same route:

1. **Stock:** `CoDBlkOps3_Exe` started from Terminal with `SteamAppId=311210` and nothing injected, so nothing writes the game's code.
2. **Launcher:** started from Terminal and played with Play as usual. That injects `BO3MacFix.dylib` and `DualSenseRumble.dylib`.

Both runs had `MTL_HUD_ENABLED=1 MTL_HUD_LOG_ENABLED=1` set. The launcher passes its own environment on to the game, so starting it from Terminal is enough.

What was recorded:

- **AOT or JIT:** `vmmap <pid>` lists the files Rosetta maps, with their resident size. An AOT run maps `/private/var/db/oah/<hash>/<hash>/CoDBlkOps3_Exe.aot`. A JIT run maps no `.aot` for the game, and the `Rosetta JIT` region grows instead.
- **CPU:** `ps -o time= -p <pid>` every 5 seconds.
- **Frame rate:** with `MTL_HUD_LOG_ENABLED=1` the Metal HUD writes a line about every 0.8 s, read with `/usr/bin/log stream --predicate 'process == "CoDBlkOps3_Exe" AND eventMessage CONTAINS[c] "metal-hud"'`. The first field is the frame count, so the difference between lines gives the frames per window. At 120 fps a full window holds about 98 frames.

Traps:

- In zsh, `log` is a shell builtin. Call `/usr/bin/log`.
- The HUD line's per-frame timings are `<private>` in the log, so only frames per window are available.
- `vmmap` on the game takes 13 to 15 seconds and drops the game to about 20 fps meanwhile. Take snapshots sparingly, and leave those moments out of the frame-rate data.
- Menus run at about 60 fps in both runs, so gameplay windows were picked by time.

## Limits

- **One run each, with different gameplay.** The CPU difference is a rough figure, and the JIT run also includes BO3MacFix's own hooks.
- **The frame log only sees dropped frames.** A hitch short enough to be absorbed without missing a frame (the Metal layer allows 2 frames in flight) doesn't show. Neither does stutter in audio or input.
  - The player still noticed minor hitches that never became frame drops, and couldn't say when they happened. Their cause is unknown.
- **No CPU-bound test.** At the 120 Hz cap the GPU and display set the pace. Lower resolution or a heavier map might show a gap.
- **Only official maps can be compared this way.** The stock game can't load Workshop maps, so a custom-map comparison needs a BO3MacFix switch that skips all code patches, like PR #76's `NoCodePatches`.

## If it gets built

What a pre-patched copy would have to cover in this fork:

- **BO3MacFix:** about 20 inline hooks (`dylib_main`) and about 10 byte patches, including the network version patches and the image-streamer sort hook from `docs/leviathan-stutter.md`.
- **The rumble shim:** its inline hook on `DB_FindXAssetHeader` (`DB_FIND_VMADDR`). The glyph-table patch is in `__DATA` and doesn't affect AOT.

Findings about the executable:

- It is 37 MB, x86_64, and signed by Aspyr (team `VF8SGH77F7`) without hardened runtime. A patched copy needs an ad-hoc signature (`/usr/bin/codesign -s - -f`), which works without Xcode.
- `__TEXT` ends at `0x101965000` and its last section (`__eh_frame`) at `0x101964080`. That leaves 3,968 bytes for hook stubs and trampolines.
- PR #76's design fits: each hooked function jumps to a stub in that padding, and the stub jumps through a slot in `__DATA`'s zero-filled tail. BO3MacFix fills the slots at startup, so nothing writes code at runtime. With every slot at 0 the copy runs like the original.

What differs from PR #76:

- **Building the copy.** PR #76's launcher builds the copy by loading the x86_64 `BO3MacFix.dylib`. Our launcher runs natively and can't load it. The patcher would be an x86_64 helper, like `steam-unsub`, or Swift.
- **The copy's name.** `dylib_main` only starts when the running executable is named `CoDBlkOps3_Exe`. It has to accept the copy's name too.
- **First launch.** The first launch of a new copy is slower while Rosetta translates it. Later launches reuse the translation until the copy changes, for example after a game or BO3MacFix update.
- **Fallback.** The launcher should start the original executable when building or signing the copy fails.
- **Same rule as every patch here.** Check the expected bytes before writing anything, and leave a different game build alone.
