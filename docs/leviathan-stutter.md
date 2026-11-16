# Leviathan stutter on macOS

Findings from 16 November 2026 on a MacBook Pro M5 Pro with 24 GB RAM, running macOS 27.2.1, BO3 build CODBUILD9-764 under Rosetta 2.
The map is [Leviathan](https://steamcommunity.com/sharedfiles/filedetails/?id=2112576356) (Workshop 2112576356, last updated 2020-07-12).

## Symptom

Leviathan stuttered constantly on the Mac. It ran at about 120 fps, and about once a second it dropped to 20 to 40 fps for a moment.
Official maps such as Gorod Krovi ran smoothly, and so did the custom map Isle of Cthulhu.
The same map runs without problems on a Windows PC (RTX 4090, Ryzen, 32 GB).

## Cause

**The image streamer's priority sort goes quadratic.**

Each frame, the image streamer re-sorts its list of streamed images by priority (`0x101526340` calls the sort).
If the list is the same length as last frame, it uses an insertion sort (`0x1015273cb`). Otherwise it uses a quicksort (`0x10152746c`). Both use the comparison at `0x101527878`.
The insertion sort is quick when the order barely changed, but quadratic when many priorities change at once.

Leviathan streams about 29,000 images. There the insertion sort took about 550 ms roughly once a second, on a job worker. The render thread sat idle waiting for the next frame, which is the stutter.

How it was found:

- A frame-time hook on the per-frame streamer pass showed frames of about 550 ms roughly once a second during play.
- During those frames a watchdog thread sampled every thread's x86 call stack, by suspending the thread, reading its state and walking the frame pointers.
- The render thread was sleeping, waiting for work. `JQ Worker 2` was inside the insertion sort and its comparison function in almost every sample.

## Fix

BO3MacFix hooks the insertion sort. It runs the same insertion sort, with a budget of 8 element moves per list entry. If the budget runs out, it finishes with the engine's own quicksort, the path the engine already takes when the list length changed.
The list ends up sorted by the same comparison, so nothing downstream changes. On lists that barely changed, the work stays as small as before.

Before hooking, BO3MacFix checks the expected bytes at all three functions and leaves the game alone on any other build.

| | Before | After |
|---|---|---|
| Frames over 400 ms during play | about 70 | none (the remaining long frames are map loads) |
| Slowest sort | about 550 ms | 4.4 ms (29,037 images) |

## Why only on the Mac

Not proven.
The sort is engine code, so Windows probably runs the same algorithm, but much faster: natively, on a fast desktop CPU.
On the Mac, the game runs under Rosetta. Because BO3MacFix patches game code, the whole executable runs on Rosetta's JIT instead of its ahead-of-time translation (see below).
The Mac port is also built on a 2018 engine build (`CL(3017537) Port Build Machine Win64 [10:42:00 4/26/2018]`), so the Windows build may have a fixed version.

## Which maps it affects

Any map that streams lots of textures can hit this, which in practice means big custom maps. Leviathan is the tested example: about 29,000 streamed images, a hitch every second before the fix, none after.
Maps that never use up the budget, such as the official maps, behave exactly as before.

## Other things found along the way

These were real, but not the stutter.

- **Lighting resources reload at volume boundaries.**
  - Leviathan has several lighting volumes, each with its own sun shadow tree, reflection probes and skybox.
  - The streamer evicts a loaded lighting resource once nothing has touched it for 14 passes (`0x1013524b2`).
  - At some spots the camera's volume lookup flickers for a single frame into the neighbouring volume. That requests the neighbour's sun shadow tree, which takes 0.1 to 1.5 s to load. By the time it finishes, the camera is back, so the tree is evicted straight away.
  - A prototype that kept them loaded for 10 s cut the reloads from 90 to 2 in a session, but the stutter stayed, so it was not shipped.
  - Lower `TextureQualityBakedSunShadows` and `TextureQualityProbes` make those reloads cheaper.
- **Leviathan's scripts fail at startup.**
  - About a dozen systems fail to initialise. Examples are `zm_underwater` building `self.script_noteworthy + "_unbreached"` for `water_trigger` entities that have no `script_noteworthy`, and `zm_equipment_hacker.gsc` throwing `struct is not an entity` 50 to 360 times a second.
  - The same data and scripts run on Windows, so these are the map's own bugs.
  - Logging them costs almost nothing.
- **BO3MacFix's path hook called `getcwd` on every file lookup.** That took up to a fifth of the file thread's time on Leviathan. It now caches the working directory (commit d731146).
- **The Mac port leaves Havok's Visual Debugger server on.** It listens on TCP port 25001 on all interfaces while a map is loaded. BO3MacFix now refuses that bind (commit b13eaa7).
- **Patching game code makes Rosetta drop its ahead-of-time translation for the whole executable.**
  - A one-byte write anywhere in `__TEXT` puts all of the game on the JIT, and BO3MacFix makes about 30 such writes.
  - A pre-patched executable would put the game back on the AOT path. [BO3MacFix PR #76](https://github.com/InvoxiPlayGames/BO3MacFix/pull/76) does this.
- **Aspyr's job workers spin rather than sleep.** PR #76 adds a 2 ms idle wait for them.

## Ruled out

| Suspect | Result |
|---|---|
| This fork of BO3MacFix | Upstream's unmodified 1.2-beta3 dylib stutters the same |
| BO3MacFix's Windows patch scripts (`core_patch.ff`, `zm_patch.ff`, `mp_patch.ff`) | Same with them moved aside |
| A Workshop mod clashing with the map | No mod loaded |
| Texture streaming budget and video memory detection | Budget is VRAM × `VideoMemory` in 64-bit (about 18 GB), and `CGLDescribeRenderer` reports 18186 MB correctly |
| Memory pressure | About 8 GB footprint and 7 GB free |
| Shader compilation | `MTLCompilerService` idle |
| Missing engine functions | All 404 functions the map imports from outside it resolve, except one called only by `zm_giant_teleporter.gsc` |
| Script override priority | The map zone (priority 1407) overrides `zm_patch` (1115) for all 3,474 duplicate scripts. The "Redundant scriptparsetree asset" line is informational. |
| PBG and world fog bank switches | 18 bank changes against 79 shadow tree evictions, no correlation |
| Entity text over 1 MiB being cut off | Failing systems use entities before the 1 MiB mark |
