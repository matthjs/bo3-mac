#ifndef METALFX_H
#define METALFX_H

// MetalFX upscaling for the render-resolution stretch, plus the LOD fix.
// BO3MACFIX_UPSCALER = off | spatial | temporal (default spatial),
// BO3MACFIX_LODFIX = 1 to start with the LOD fix on (default off). In game, F7 (fn+F7 on
// a Mac keyboard) cycles the upscaler and F8 toggles the LOD fix.
void metalfx_init(void);

#endif
