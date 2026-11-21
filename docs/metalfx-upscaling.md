# MetalFX upscaling

Findings from 21 November 2026 on a MacBook Pro M5 Pro (16-core GPU, 24 GB
RAM), macOS 27.2, BO3 build CODBUILD9-764 under Rosetta 2, playing zombies on
a 2560×1440 144 Hz monitor. The prototype is in
[`experiments/metalfx/`](../experiments/metalfx/). It isn't in BO3MacFix yet.

## Why

With the game on the 1440p monitor, the GPU was the limit (77–98% busy), and no
CPU thread was saturated. Lowering the render resolution (`ResolutionPercent`)
is the biggest saving, but the game stretches the smaller image with plain
bilinear filtering, which looks soft at 80% and below.

## How the frame is built

Aspyr's port translates the game's D3D11 calls to Metal in its own layer
(`ASL::DX11::Metal`, linked into the game binary). Its shaders are precompiled
in `CoDBlkOps3.app/Contents/Resources/Generic.metallib`, so there is no shader
source to read. A probe that swizzles the Metal command buffer, encoder and
layer classes logged one in-game frame at 80%:

1. Shadow maps, then the scene and post-processing at 2048×1152. The final
   composite writes an `RG11B10Float` texture.
2. The first render pass into the swapchain backbuffer (2560×1440,
   `BGRA8Unorm`, private) has **one draw**: a full-screen quad that reads the
   2048×1152 texture and writes the backbuffer.
3. HUD and UI passes into the backbuffer at full size (one of them via a
   3072×1680 target).
4. A blit copies the backbuffer into the `CAMetalLayer` drawable, then
   `presentDrawable:`.

Reading back pixel blocks from that draw's input and output showed it is not a
plain stretch: the input holds HDR values in the thousands and the output
display values, related by a non-linear curve. **The draw tone maps and
stretches in one go**, so it can't just be skipped and replaced.

At 100% the source is the backbuffer's size. In menus, the first backbuffer
pass draws UI instead (`fs_main_techsetdef_unlit_hlsl_*` with a 16×16 texture).

## What the prototype does

`mfxup.dylib` is injected next to BO3MacFix:

- It learns the backbuffer as the source of the blit into the drawable.
- When the frame's first backbuffer pass begins, and the previous pass in the
  same command buffer rendered a smaller texture with the window's aspect
  ratio, it hands the encoder a copy of the descriptor whose colour attachment
  is an intermediate at render size, with depth/stencil to match. The game's
  tone-map shader then runs 1:1 and its colours are untouched. Viewports and
  scissors set on that encoder are scaled to match.
- When that encoder ends, it encodes `MTLFXSpatialScaler` (perceptual colour
  mode) from the intermediate into the backbuffer, in the same command buffer
  and before the HUD passes.
- If the redirected pass has anything other than the one draw reading the
  expected texture, it stops redirecting for the rest of the session.
- Creating `~/Library/Logs/bo3-mfx-off` switches back to the game's stretch
  within a second, for A/B comparison. `BO3_MFX=0` disables it entirely.

MetalFX works in an x86_64 process under Rosetta. It accepts the game's formats
directly, and the backbuffer already has the texture usage it needs.

## Results

- About 740,000 frames over one session, at 80% and 60%, with no unexpected
  passes and no visual problems reported.
- GPU load was the same with and without MetalFX (74% both, 10-second
  averages), so the better scaling costs nothing measurable.
- 60% (1536×864, 36% of the pixels) looked good to the player, which leaves a
  lot of GPU headroom for 144 FPS.

## Next: temporal

`MTLFXTemporalScaler` accumulates detail across frames and would look better
than spatial at low render resolutions. It needs:

- **A sub-pixel camera jitter** applied to the projection each frame, and its
  offset passed to the scaler. BO3's SMAA T2x mode already jitters, which may be
  the way in.
- **Motion vectors** at render size. The engine has velocity for motion blur
  and T2x, but where and in which format is unknown.
- **Depth** at render size: the scene's depth buffer, `Depth32Float_Stencil8`.
- **An input before tone mapping**, or after it with a reversible tone map,
  plus the game's exposure. The scene composite is HDR in large absolute
  values.

The HUD would stay native, as now.
