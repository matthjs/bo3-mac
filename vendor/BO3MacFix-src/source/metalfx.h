#ifndef METALFX_H
#define METALFX_H

// MetalFX upscaling for the render-resolution stretch, plus the LOD fix.
// BO3MACFIX_UPSCALER = off | spatial | temporal (default temporal),
// BO3MACFIX_LODFIX = 1 to start with the LOD fix on (default off),
// BO3MACFIX_SHARPEN = off | low | medium | high (temporal, default medium).
// In game (fn+ on a Mac keyboard): F7 cycles the upscaler, F6 the temporal
// sharpening, F8 toggles the LOD fix.
void metalfx_init(void);

#endif
