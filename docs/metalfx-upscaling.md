# MetalFX upscaling and the LOD fix

Findings from 21 November 2026 on a MacBook Pro M5 Pro (16-core GPU, 24 GB
RAM), macOS 27.2, BO3 build CODBUILD9-764 under Rosetta 2, playing zombies on
a 2560×1440 monitor. The code is `vendor/BO3MacFix-src/source/metalfx.m`;
the probe used to find all this is in [`tools/metal-probe/`](../tools/metal-probe/).

## Why

On the 1440p monitor the GPU was the limit (77–98% busy) and no CPU thread was
saturated. Lowering the render resolution (`ResolutionPercent`) saves the most
GPU time, but the game stretches the smaller picture with plain bilinear
filtering, which looks soft at 80% and below.

## How the frame is built

Aspyr's port translates the game's D3D11 calls to Metal in its own layer
(`ASL::DX11::Metal`, linked into the game binary). Its shaders are precompiled
in `CoDBlkOps3.app/Contents/Resources/Generic.metallib`, so there's no source
to read, but the function names survive (`fs_main_gbuffer_lit_hlsl_…`). A probe
that swizzles the Metal command buffer, encoder and device classes logged one
frame below 100%:

1. Shadow maps (1024×1024 depth), then the scene at render size: a depth
   prepass, the G-buffer and forward passes into one `Depth32Float_Stencil8`
   depth, with motion vectors written to an `RG16Snorm` target. Lighting is
   compute (`cs_main_deferred_lighting`, `cs_main_light_culling_lights`).
2. Post-processing at render size, ending in `bloom_apply_lut`, which blends
   two bloom textures (quarter and half size; lens flares are drawn into the
   half-size one) and the colour-grading LUT into an `RG11B10Float` image.
3. The first render pass into the swapchain backbuffer (`BGRA8Unorm`) has
   **one draw**, `resample_final`: a full-screen quad that reads that image and
   writes the backbuffer at window size.
4. HUD and UI passes into the backbuffer at full size.
5. A blit copies the backbuffer into the `CAMetalLayer` drawable, then
   `presentDrawable:`.

Reading back pixel blocks around step 3 showed it isn't a plain stretch: the
input holds HDR values in the thousands, the output display values, related by
a non-linear curve. **That draw tone maps and stretches in one go**, so it
can't simply be replaced. At 100% the source is the window's size. In menus the
first backbuffer pass draws UI instead.

## Spatial

When the frame's first backbuffer pass begins, and the previous pass in the
same command buffer rendered a smaller texture with the window's aspect ratio,
the encoder gets a copy of the descriptor whose colour attachment is an
intermediate at render size, with depth/stencil to match. The game's shader
then runs 1:1, so colours stay the game's. Viewports and scissors set on that
encoder are scaled to match. When the encoder ends, `MTLFXSpatialScaler`
(perceptual colour mode) scales the intermediate into the backbuffer, in the
same command buffer and before the HUD passes. If redirected passes keep not
looking like that one draw (about 2 s in a row), it stops redirecting.

MetalFX works in an x86_64 process under Rosetta and accepts the game's
formats directly. Over about 740,000 frames at 80% and 60% the GPU load was
the same with and without it (72–74%).

## Temporal

`MTLFXTemporalScaler` also takes depth, motion vectors and a per-frame
sub-pixel jitter. The temporal scaler is created on a background queue (it
can take a second); spatial covers the gap.

**Motion vectors.** The `RG16Snorm` target written by `motion_vector_static`
and the G-buffer passes; two alternate per frame. Comparing them with the
measured image motion between consecutive dumped frames (phase correlation per
block) gave a linear scale of about 20 pixels per unit, the same horizontally
and vertically, at 60% and at 80%: the game stores pixels / 20, positive when
content moves right or down. MetalFX wants the vector to the previous
position, so `motionVectorScale` is -20. Depth is reversed (far is 0).

**Jitter.** Instead of changing the game's projection, the viewport of every
geometry draw in a scene pass (a pass into the scene depth at render size) is
offset by the frame's jitter. Apple GPUs honour fractional viewport origins
exactly (checked: 0.125 → 0.125). Full-screen effects inside those passes,
recognised by shader name (`motion_vector_static`, `*_ps`, `dof_*`, …), keep
the plain viewport. The game's motion vectors don't include the jitter, which
is what MetalFX expects. With an accurate sub-pixel estimator (a weighted fit
of the cross-spectrum phase slope; checked: a 0.25 px shift measures
0.244–0.249) the MetalFX input follows the jitter 0.9–1.0, and with
`jitterOffset = +jitter` the output moves 0.03 px rms. Flipping either sign
made it move 0.25–0.4 px.

Three things that went wrong on the way:

- **The jitter amplitude.** With Halton(2,3) at full size (±0.5 px) a light
  on Ascension vanished for single frames: in dumps its brightness fell to
  13–30% in one frame of four. A constant offset, half size and quarter size
  didn't; half size still flickered faintly from further away; **0.35 of full
  size** (±0.18 px) didn't. Most likely a lens flare, whose visibility the game
  tests against the depth buffer, failing when the light sits on an edge.
  Excluding occlusion-query draws from the jitter didn't help (there were none
  in that frame), nor did the bloom stabiliser on its own.
- **The jitter sequence.** A closed Moore curve through a 4×4 grid (small
  steps, full coverage) looked much worse than Halton: MetalFX reconstructs
  badly from consecutive samples that are neighbours, and the picture crawled.
- **Where the jitter changes.** It was first advanced in `presentDrawable:`,
  which runs on another thread than the render thread, so a change could land
  mid-frame. It's now advanced on the render thread when the tone-map pass
  ends, after the scaler used that frame's value.

An early measurement that the game "cancels" the jitter was wrong: the first
estimator (peak position with a parabolic fit) underestimated sub-pixel shifts
by a factor of 2–3.

**Texture mip bias.** At a lower render resolution the GPU picks blurrier mip
levels. In temporal mode, scene passes get copies of the game's samplers with
`lodBias = log2(render / output)` (-0.74 at 60%). `lodBias` exists from macOS
26; earlier systems skip it.

**Bloom.** The game computes bloom before the upscaler, from the jittered
frame. Before `bloom_apply_lut`, each bloom texture it reads is mixed 65/35
with its history, reprojected with the motion vectors. It was on in the
configuration that tested clean. `RG11B10Float` has no read-write access on
Apple GPUs, so the kernel writes a history texture and a blit copies it back.

**Sharpening.** MetalFX temporal doesn't sharpen, and next to spatial
(which does) it looked softer. Its output now goes to an intermediate, and
AMD's RCAS from FSR 1 writes the backbuffer before the HUD: a 5-tap filter
whose negative lobe is limited by the neighbourhood's range (and to 0.1875),
which keeps halos down. Strengths: low 0.35, medium 0.65 (default), high 1.0;
FSR's own default is about 0.87 on that scale. Anti-aliasing is best set to
None with temporal: SMAA before it removes sub-pixel detail the temporal pass
would use.

Cost, standing still at 60% with a 120 FPS cap: GPU 72% in off, spatial and
temporal alike; CPU 377% off, 379% spatial, 397% temporal (the per-draw hooks).

## The LOD fix

The game picks model detail by on-screen size, so the render resolution
matters. A counter of draws and indices in the scene passes, same viewpoint,
paused in the menu:

| Render resolution | Draws | Indices |
|---|---|---|
| 60% | 3558 | 2,894,574 |
| 90% | 3642 | 3,209,664 (+10.9%) |

`Dvar_SetFromStringByName` (BO3MacFix already had its address) can set dvars
by name. `r_lodScaleRigid`, `r_lodScaleSkinned` and several other scale names
had no effect. `r_lodBiasRigid` / `r_lodBiasSkinned` did, negative values
only, on the same frozen frame:

| LOD bias | Indices |
|---|---|
| 0 | 2,958,543 |
| -50 | 3,000,738 (+1.4%) |
| -200 | 3,274,005 (+10.7%) |
| -500 | 3,806,772 (+29%) |
| -1000 | 5,146,560 (+74%) |

BO3MacFix sets both to `-400 × (1/scale - 1)`, rounded to 5 (-270 at 60%, 0 at
100%), whenever the render resolution changes, on the main thread. It costs
about 5% FPS (113 → 108) for native-level detail. The bias is a distance, not
a ratio, so it can't match a resolution change exactly at every distance.

## Controls

The launcher passes `BO3MACFIX_UPSCALER` (`temporal`, `spatial`, `off`) and
`BO3MACFIX_LODFIX`; `BO3MACFIX_SHARPEN` sets the temporal sharpening. In
game, F7 cycles the upscaler, F6 the sharpening and F8 toggles the LOD fix
(fn+F7 / fn+F6 / fn+F8 on a Mac keyboard, where plain F-keys are media keys).
Both are unbound in BO3's default controls; modifier combinations were ruled
out because Ctrl is prone and Shift sprint. They're caught with a local `NSEvent`
monitor, which keeps them from the game, and a label is blitted into the
drawable for 2.5 s.
