// MetalFX upscaling for BO3's render resolution (ResolutionPercent < 100),
// spatial or temporal, and the LOD fix. Built for macOS 14 and later, with
// MetalFX weakly linked; the rest of BO3MacFix targets older macOS.
//
// Frame structure (Aspyr's D3D11->Metal layer, render resolution below 100%):
//   shadow maps; scene passes at render size into the scene depth
//     (Depth32Float_Stencil8), writing motion vectors (RG16Snorm, pixels / 20,
//     two textures alternating per frame); post-processing, then the bloom
//     composite (bloom_apply_lut) into RG11B10Float at render size
//   first pass into the swapchain backbuffer: ONE draw that tone maps that
//     texture and stretches it to the window size
//   HUD / UI passes into the backbuffer at full size
//   blit backbuffer -> CAMetalLayer drawable, present
//
// The tone-map pass is redirected into an intermediate at render size, so
// the game's own shader runs 1:1 and colours stay the game's, and when it
// ends MetalFX scales the intermediate into the backbuffer. The HUD then
// draws on top at full resolution as before. Nothing here patches game code:
// it all goes through swizzled Metal methods.
//
// Temporal mode also needs a sub-pixel camera jitter. Instead of changing the
// game's projection, the viewport of every geometry draw in a scene pass is
// offset by the frame's jitter, which moves rasterisation by exactly that
// much. Full-screen effects inside those passes (recognised by shader name)
// keep the plain viewport. The game's motion vectors don't include the
// jitter, which is what MetalFX expects. Measured on the MetalFX input and
// output: the jitter reaches the image 1:1, and MetalFX removes it with
// jitterOffset = +jitter and motionVectorScale = -20.
//
// Findings and measurements: docs/metalfx-upscaling.md in the launcher repo.
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "metalfx.h"
#include "offsets.h"

extern uint64_t game_base_address;

static pthread_mutex_t g_lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;

enum { MODE_OFF, MODE_SPATIAL, MODE_TEMPORAL };
static int g_mode = MODE_SPATIAL;
static int g_lodFix = 0;

static id<MTLTexture> g_backbuffer;     // texture ASL copies into the drawable
static int g_bbPassThisFrame;           // a backbuffer pass has begun this frame
static int g_disabled;                  // redirected passes kept not looking right

#define NCB 32
static struct { id cb; id<MTLTexture> color0; } g_last[NCB]; // last color0 per command buffer
static int g_lastNext;

// The redirected tone-map encoder and what it needs at endEncoding.
static id g_rEnc, g_rCb;
static id<MTLTexture> g_rSrc;
static int g_rDraws, g_rSrcSeen, g_oddStreak;
static double g_rSx, g_rSy;

static id<MTLTexture> g_inter, g_interDepth;
static id<MTLFXSpatialScaler> g_scaler;
static NSUInteger g_sIW, g_sIH, g_sOW, g_sOH;

// Temporal inputs, from this frame's scene passes.
static id<MTLTexture> g_vel, g_sceneDepth;
static unsigned long g_sceneDepthFrame; // frame the scene depth was last seen (LOD fix)
static id<MTLFXTemporalScaler> g_tscaler;
static NSUInteger g_tIW, g_tIH, g_tOW, g_tOH;
static int g_tCreating, g_tReset = 1, g_tFailed; // failed: temporal falls back to spatial
static NSUInteger g_sceneW, g_sceneH;   // render size, from the last tone-map source
static unsigned long g_frames;
static int g_framesSinceToneMap = 1000; // presents since the last upscaled frame

// Jitter: Halton(2,3) at 0.35 of full size, so offsets stay within about
// +-0.18 px. At full size (+-0.5) a light on Ascension (most likely a lens
// flare, whose visibility the game tests against the depth buffer) vanished
// for single frames whenever the offset passed about 0.3 px; at half size it
// still flickered faintly from further away, at 0.35 it didn't.
#define JITTER_SCALE 0.35f
static unsigned g_jIndex;
static float g_jx, g_jy;
static int g_jitterOn;                  // temporal scaler ready for this size

// Scene encoders being jittered.
#define NJE 16
static struct { id enc; MTLViewport vp; int jittered; } g_je[NJE];
static NSMutableSet *g_fullscreenPSO;   // NSValue(pso) of full-screen effect pipelines

// Texture mip bias (temporal). Rendering at a lower resolution makes the GPU
// pick blurrier mip levels; temporal upscaling should sample as if at the
// output resolution: bias = log2(render / output). Sampler states are
// immutable, so scene passes get biased copies, made from the descriptor the
// game created each sampler with. Metal has lodBias from macOS 26.
static NSMutableDictionary *g_samplerDesc;   // NSValue(sampler) -> descriptor
static NSMutableDictionary *g_biased;        // NSValue(sampler) -> biased sampler, for g_biasCache
static float g_bias, g_biasCache;

// Bloom stabiliser (temporal). The game computes bloom before the upscaler,
// from the jittered frame, so bright detail makes the glow around it shimmer.
// Just before the pass that blends bloom into the image (bloom_apply_lut),
// each bloom texture it reads is mixed with its own history, reprojected
// with the game's motion vectors. It was on in the configuration that tested
// clean, together with the smaller jitter.
#define NBLOOM 8                         // by the composite pass's texture index
static id g_compEnc;                     // this frame's bloom_apply_lut pass
static id<MTLTexture> g_lastToneSrc;     // last frame's tone-map input = that pass's output
static id<MTLTexture> g_bloom[NBLOOM];
static id<MTLTexture> g_bloomHist[NBLOOM][2];
static int g_bloomPing, g_bloomReset = 1, g_bloomBroken;
static id<MTLComputePipelineState> g_bloomPSO;

// LOD fix. The game picks model detail from on-screen size, so at a lower
// render resolution it draws coarser models (about 9% less geometry at 60%
// than at 90%). Its LOD bias dvars bring native detail back: -270 at 60%
// matched; the r_lodScale* dvars have no effect in this build.
static float g_lodApplied;              // value last given to the dvars

// On-screen label after a shortcut, drawn into the drawable after the HUD.
static id<MTLTexture> g_label;
static double g_labelUntil;

#define HOOK(selname, ret, ...)                                   \
    static ret (*orig_##selname)(id, SEL, ##__VA_ARGS__);        \
    static ret repl_##selname(id self, SEL _cmd, ##__VA_ARGS__)

static void (*orig_vp)(id, SEL, MTLViewport);  // used before its hook
static void (*orig_copytt)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin);

static id<MTLTexture> last_color0(id cb) {
    for (int i = 0; i < NCB; i++) if (g_last[i].cb == cb) return g_last[i].color0;
    return nil;
}
static void set_last_color0(id cb, id<MTLTexture> t) {
    for (int i = 0; i < NCB; i++) if (g_last[i].cb == cb) { g_last[i].color0 = t; return; }
    g_last[g_lastNext].cb = cb; g_last[g_lastNext].color0 = t; // weak: pointers only compared
    g_lastNext = (g_lastNext + 1) % NCB;
}

static float halton(unsigned i, unsigned b) {
    float f = 1, r = 0;
    while (i) { f /= b; r += f * (i % b); i /= b; }
    return r;
}

static void retain_set(id<MTLTexture> *slot, id<MTLTexture> t) {
    if (*slot == t) return;
    [*slot release]; *slot = [t retain];
}

static const char *mode_name(int m) { return m == MODE_OFF ? "off" : m == MODE_SPATIAL ? "spatial" : "temporal"; }

// ---- dvars

// Dvar_SetFromStringByName, checked against its first bytes so a different
// game build is left alone.
static void (*dvar_set_fn(void))(const char *, const char *, bool) {
    static const uint8_t expect[] = { 0x55, 0x48, 0x89, 0xe5, 0x44, 0x0f, 0xb6, 0xc2, 0x31, 0xd2, 0x31, 0xc9, 0x5d, 0xe9 };
    void *f = (void *)(game_base_address + ADDR_Dvar_SetFromStringByName);
    return memcmp(f, expect, sizeof expect) == 0 ? f : NULL;
}

static void set_lod_bias(float v) {
    char val[32];
    snprintf(val, sizeof val, "%.0f", v);
    char *copy = strdup(val);
    // On the main thread, where the game handles its dvars.
    dispatch_async(dispatch_get_main_queue(), ^{
        void (*set)(const char *, const char *, bool) = dvar_set_fn();
        if (set) {
            set("r_lodBiasRigid", copy, false);
            set("r_lodBiasSkinned", copy, false);
            printf("[BO3MacFix] LOD bias %s\n", copy);
        } else {
            printf("[BO3MacFix] LOD fix: unexpected Dvar_SetFromStringByName, not setting the LOD bias\n");
        }
        free(copy);
    });
}

// Called every frame: the bias the LOD fix wants for the current render
// resolution, applied when it changes. 0 at 100% and above, or when off.
static void update_lod_fix(void) {
    float target = 0;
    if (g_lodFix && g_backbuffer && g_sceneDepth && g_frames - g_sceneDepthFrame < 30) {
        float s = (float)g_sceneDepth.width / g_backbuffer.width;
        if (s < 0.99f) target = fmaxf(-600.0f, -400.0f * (1.0f / s - 1.0f));
    }
    target = roundf(target / 5) * 5;
    if (target != g_lodApplied) {
        g_lodApplied = target;
        set_lod_bias(target);
    }
}

// ---- label

static id<MTLTexture> make_label(id<MTLDevice> dev, NSString *text) {
    NSDictionary *attrs = @{ (id)kCTFontAttributeName: [NSFont boldSystemFontOfSize:26],
                             (id)kCTForegroundColorAttributeName: (id)[[NSColor whiteColor] CGColor] };
    NSAttributedString *as = [[[NSAttributedString alloc] initWithString:text attributes:attrs] autorelease];
    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)as);
    CGFloat ascent = 0, descent = 0;
    double tw = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
    size_t padX = 20, padY = 12;
    size_t w = (size_t)ceil(tw) + 2 * padX, h = (size_t)ceil(ascent + descent) + 2 * padY;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) { CFRelease(line); return nil; }
    CGContextSetRGBFillColor(ctx, 0.08, 0.08, 0.08, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    CGContextSetTextPosition(ctx, padX, padY + descent);
    CTLineDraw(line, ctx);
    CFRelease(line);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:CGBitmapContextGetData(ctx) bytesPerRow:w * 4];
    CGContextRelease(ctx);
    return t;
}

static void show_label(NSString *text) {
    id<MTLDevice> dev = g_backbuffer ? [g_backbuffer device] : nil;
    if (!dev) return;
    id<MTLTexture> t = make_label(dev, text);
    pthread_mutex_lock(&g_lock);
    [g_label release]; g_label = t;
    g_labelUntil = CFAbsoluteTimeGetCurrent() + 2.5;
    pthread_mutex_unlock(&g_lock);
}

static NSString *mode_label(void) {
    NSString *m = g_mode == MODE_OFF ? @"MetalFX: Off (the game's own scaling)" : g_mode == MODE_SPATIAL ? @"MetalFX: Spatial" : @"MetalFX: Temporal";
    // The scene depth at below window size is only seen while the game
    // renders below 100%, whichever mode was on.
    BOOL scaled = g_backbuffer && g_sceneDepth && g_frames - g_sceneDepthFrame < 30;
    if (g_mode != MODE_OFF && !scaled)
        m = [m stringByAppendingString:@"  (works when render resolution is below 100%)"];
    return m;
}

// ---- shortcuts

// F7 cycles the upscaler, F8 toggles the LOD fix. On a Mac keyboard they're
// fn+F7 / fn+F8 (plain F7/F8 are media keys, which never arrive as key
// events); on a PC keyboard just F7 / F8. No Ctrl, Shift, Option or Command:
// Ctrl is crouch/prone and Shift sprint in BO3, and players use the other
// two themselves. Both keys are unbound in the default controls (F9 and F10
// are taken).
#define KEY_F7 98
#define KEY_F8 100

static void install_shortcuts(void) {
    // On the main thread once the game's run loop is going. The game reads
    // keys from NSEvents (SDL), so returning nil keeps the key from it.
    dispatch_async(dispatch_get_main_queue(), ^{
        id monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            if (e.keyCode != KEY_F7 && e.keyCode != KEY_F8) return e;
            NSEventModifierFlags f = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
            if (f & (NSEventModifierFlagControl | NSEventModifierFlagShift | NSEventModifierFlagCommand | NSEventModifierFlagOption)) return e;
            if (e.type == NSEventTypeKeyUp) return nil; // swallow the release too
            if (e.keyCode == KEY_F7) {
                if (!e.isARepeat) {
                    pthread_mutex_lock(&g_lock);
                    g_mode = (g_mode + 1) % 3;
                    g_tReset = 1; g_bloomReset = 1;
                    pthread_mutex_unlock(&g_lock);
                    printf("[BO3MacFix] MetalFX %s\n", mode_name(g_mode));
                    show_label(mode_label());
                }
                return nil;
            }
            if (e.keyCode == KEY_F8) {
                if (!e.isARepeat) {
                    pthread_mutex_lock(&g_lock);
                    g_lodFix = !g_lodFix;
                    pthread_mutex_unlock(&g_lock);
                    show_label(g_lodFix ? @"LOD fix: On" : @"LOD fix: Off");
                }
                return nil;
            }
            return e;
        }];
        [monitor retain];
    });
}

// ---- spatial resources

static BOOL ensure_resources(id<MTLDevice> dev, id<MTLTexture> src, id<MTLTexture> bb, MTLPixelFormat depthFmt) {
    NSUInteger iw = src.width, ih = src.height, ow = bb.width, oh = bb.height;
    if (!g_inter || g_inter.width != iw || g_inter.height != ih || g_inter.pixelFormat != bb.pixelFormat) {
        [g_inter release];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:bb.pixelFormat width:iw height:ih mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        g_inter = [dev newTextureWithDescriptor:td];
        g_inter.label = @"MetalFX input";
    }
    if (depthFmt != MTLPixelFormatInvalid &&
        (!g_interDepth || g_interDepth.width != iw || g_interDepth.height != ih || g_interDepth.pixelFormat != depthFmt)) {
        [g_interDepth release];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:depthFmt width:iw height:ih mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        g_interDepth = [dev newTextureWithDescriptor:td];
    }
    if (!g_scaler || g_sIW != iw || g_sIH != ih || g_sOW != ow || g_sOH != oh) {
        [g_scaler release]; g_scaler = nil;
        MTLFXSpatialScalerDescriptor *sd = [[MTLFXSpatialScalerDescriptor alloc] init];
        sd.inputWidth = iw; sd.inputHeight = ih; sd.outputWidth = ow; sd.outputHeight = oh;
        sd.colorTextureFormat = g_inter.pixelFormat; sd.outputTextureFormat = bb.pixelFormat;
        // The intermediate holds display-ready (gamma-encoded) colour.
        sd.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        g_scaler = [sd newSpatialScalerWithDevice:dev];
        [sd release];
        g_sIW = iw; g_sIH = ih; g_sOW = ow; g_sOH = oh;
        printf("[BO3MacFix] MetalFX spatial %lux%lu -> %lux%lu %s\n", (unsigned long)iw, (unsigned long)ih, (unsigned long)ow, (unsigned long)oh, g_scaler ? "ready" : "FAILED");
    }
    return g_inter && g_scaler && (depthFmt == MTLPixelFormatInvalid || g_interDepth);
}

// ---- temporal scaler, created off the render thread (can take seconds)

static void ensure_temporal(id<MTLDevice> dev, NSUInteger iw, NSUInteger ih, id<MTLTexture> bb) {
    NSUInteger ow = bb.width, oh = bb.height;
    if (g_tscaler && g_tIW == iw && g_tIH == ih && g_tOW == ow && g_tOH == oh) return;
    if (g_tCreating || g_tFailed || !g_vel || !g_sceneDepth) return;
    g_tCreating = 1;
    MTLPixelFormat cf = bb.pixelFormat, df = g_sceneDepth.pixelFormat, mf = g_vel.pixelFormat;
    [g_tscaler release]; g_tscaler = nil;
    g_jitterOn = 0;
    [dev retain];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MTLFXTemporalScalerDescriptor *td = [[MTLFXTemporalScalerDescriptor alloc] init];
        td.inputWidth = iw; td.inputHeight = ih; td.outputWidth = ow; td.outputHeight = oh;
        td.colorTextureFormat = cf; td.outputTextureFormat = cf;
        td.depthTextureFormat = df; td.motionTextureFormat = mf;
        id<MTLFXTemporalScaler> s = [td newTemporalScalerWithDevice:dev];
        [td release];
        printf("[BO3MacFix] MetalFX temporal %lux%lu -> %lux%lu %s\n", (unsigned long)iw, (unsigned long)ih, (unsigned long)ow, (unsigned long)oh, s ? "ready" : "FAILED");
        pthread_mutex_lock(&g_lock);
        g_tscaler = s; g_tIW = iw; g_tIH = ih; g_tOW = ow; g_tOH = oh;
        g_tReset = 1; g_tCreating = 0;
        if (!s) g_tFailed = 1; // e.g. a GPU MetalFX temporal doesn't support: stay spatial
        pthread_mutex_unlock(&g_lock);
        [dev release];
    });
}

// ---- pipeline classification

// Full-screen effects drawn inside scene passes must not be jittered.
static BOOL is_fullscreen_name(NSString *n) {
    if (!n) return NO;
    static const char *tok[] = { "motion_vector", "_ps_hlsl", "dof_", "postfx", "blur", "fill", "resolve", "copy",
                                 "downsample", "upsample", "composite", "ssao", "gtao", "deferred", "shadow_mask",
                                 "fullscreen", "screen_space", "ssr", "lighting_", "tonemap", "bloom", "fxaa", "smaa" };
    const char *s = n.UTF8String;
    for (size_t i = 0; i < sizeof tok / sizeof *tok; i++) if (strstr(s, tok[i])) return YES;
    return NO;
}

HOOK(newpso, id, MTLRenderPipelineDescriptor *d, NSError **e) {
    id p = orig_newpso(self, _cmd, d, e);
    if (p && (is_fullscreen_name(d.vertexFunction.name) || is_fullscreen_name(d.fragmentFunction.name))) {
        pthread_mutex_lock(&g_lock);
        [g_fullscreenPSO addObject:[NSValue valueWithPointer:p]];
        pthread_mutex_unlock(&g_lock);
    }
    return p;
}

// ---- jittered scene encoders

static int je_find(id enc) {
    for (int i = 0; i < NJE; i++) if (g_je[i].enc == enc) return i;
    return -1;
}

static MTLViewport jittered(MTLViewport v) {
    v.originX += g_jx; v.originY += g_jy;
    return v;
}

// ---- bloom stabiliser

// RG11B10Float has no read_write access on Apple GPUs, so the kernel only
// writes the history texture and a blit copies it back into the game's.
static const char *k_bloomSrc =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct P { float2 bloomSize; float2 velScale; float histWeight; };\n"
    "kernel void stab(texture2d<float> cur [[texture(0)]],\n"
    "                 texture2d<float> histIn [[texture(1)]],\n"
    "                 texture2d<float, access::write> histOut [[texture(2)]],\n"
    "                 texture2d<float> vel [[texture(3)]],\n"
    "                 constant P &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {\n"
    "    if (gid.x >= uint(p.bloomSize.x) || gid.y >= uint(p.bloomSize.y)) return;\n"
    "    constexpr sampler lin(filter::linear, address::clamp_to_edge);\n"
    "    float2 uv = (float2(gid) + 0.5) / p.bloomSize;\n"
    "    float4 c = cur.read(gid);\n"
    "    float4 out = c;\n"
    "    if (p.histWeight > 0) {\n"
    "        // motion vectors: pixels / 20 at render size, + = content moved right/down\n"
    "        float2 mv = vel.sample(lin, uv).xy * p.velScale;\n"
    "        float2 puv = uv - mv;\n"
    "        if (all(puv >= 0.0) && all(puv <= 1.0)) out = mix(c, histIn.sample(lin, puv), p.histWeight);\n"
    "    }\n"
    "    histOut.write(max(out, 0.0), gid);\n"
    "}\n";

static void stabilise_bloom(id<MTLCommandBuffer> cb) {
    if (g_bloomBroken || !g_jitterOn || !g_vel) return;
    id<MTLDevice> dev = [cb device];
    if (!g_bloomPSO) {
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:k_bloomSrc] options:nil error:&err];
        id<MTLFunction> fn = [lib newFunctionWithName:@"stab"];
        g_bloomPSO = fn ? [dev newComputePipelineStateWithFunction:fn error:&err] : nil;
        [fn release]; [lib release];
        if (!g_bloomPSO) {
            printf("[BO3MacFix] MetalFX bloom stabiliser failed: %s\n", err ? err.localizedDescription.UTF8String : "?");
            g_bloomBroken = 1;
            return;
        }
    }
    int ping = g_bloomPing, pong = ping ^ 1;
    id<MTLComputeCommandEncoder> ce = nil;
    for (int i = 0; i < NBLOOM; i++) {
        id<MTLTexture> b = g_bloom[i];
        if (!b) continue;
        int reset = g_bloomReset;
        for (int k = 0; k < 2; k++) {
            id<MTLTexture> h = g_bloomHist[i][k];
            if (!h || h.width != b.width || h.height != b.height || h.pixelFormat != b.pixelFormat) {
                [h release];
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:b.pixelFormat width:b.width height:b.height mipmapped:NO];
                td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
                td.storageMode = MTLStorageModePrivate;
                g_bloomHist[i][k] = [dev newTextureWithDescriptor:td];
                reset = 1;
            }
        }
        if (!ce) { ce = [cb computeCommandEncoder]; [ce setComputePipelineState:g_bloomPSO]; }
        struct { float bw, bh, vx, vy, w; } prm = { (float)b.width, (float)b.height,
            20.0f / g_vel.width, 20.0f / g_vel.height, reset ? 0.0f : 0.65f };
        [ce setTexture:b atIndex:0];
        [ce setTexture:g_bloomHist[i][ping] atIndex:1];
        [ce setTexture:g_bloomHist[i][pong] atIndex:2];
        [ce setTexture:g_vel atIndex:3];
        [ce setBytes:&prm length:sizeof prm atIndex:0];
        [ce dispatchThreads:MTLSizeMake(b.width, b.height, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    }
    if (!ce) return;
    [ce endEncoding];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    for (int i = 0; i < NBLOOM; i++) {
        id<MTLTexture> b = g_bloom[i], h = g_bloomHist[i][pong];
        if (!b || !h) continue;
        orig_copytt(be, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:),
                    h, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(b.width, b.height, 1), b, 0, 0, MTLOriginMake(0, 0, 0));
    }
    [be endEncoding];
    g_bloomPing = pong; g_bloomReset = 0;
}

// The bloom textures the composite pass reads at each index: half or quarter
// render size, RG11B10Float. History belongs to the index; only a size change
// resets it (in stabilise_bloom).
static void note_bloom(id<MTLTexture> t, NSUInteger i) {
    if (!t || i >= NBLOOM || t.pixelFormat != MTLPixelFormatRG11B10Float || !g_sceneW) return;
    if (!((t.width == g_sceneW / 4 && t.height == g_sceneH / 4) || (t.width == g_sceneW / 2 && t.height == g_sceneH / 2))) return;
    if (g_bloom[i] == t) return;
    pthread_mutex_lock(&g_lock);
    retain_set(&g_bloom[i], t);
    pthread_mutex_unlock(&g_lock);
}

// Next frame's jitter. Only while the temporal scaler for this size is
// ready, or the picture would shake. Called on the render thread when a
// frame's tone-map pass ends, after the scaler used this frame's jitter. Not
// at present: that runs on another thread, and a change there could land
// mid-frame and give the passes of one frame different jitter.
static void advance_jitter(void) {
    g_jitterOn = g_mode == MODE_TEMPORAL && !g_disabled && g_tscaler && g_tIW == g_sceneW && g_tIH == g_sceneH;
    g_bias = 0;
    if (g_jitterOn && g_backbuffer && [MTLSamplerDescriptor instancesRespondToSelector:@selector(setLodBias:)])
        g_bias = log2f((float)g_sceneW / g_backbuffer.width);
    if (g_jitterOn) {
        g_jIndex = g_jIndex % 32 + 1;
        g_jx = (halton(g_jIndex, 2) - 0.5f) * JITTER_SCALE;
        g_jy = (halton(g_jIndex, 3) - 0.5f) * JITTER_SCALE;
    } else {
        g_jx = g_jy = 0;
    }
}

// ---- command buffer hooks

HOOK(rce, id, MTLRenderPassDescriptor *d) {
    pthread_mutex_lock(&g_lock);
    id<MTLTexture> c0 = d.colorAttachments[0].texture;
    id<MTLTexture> dt = d.depthAttachment.texture;
    MTLRenderPassDescriptor *use = d, *copy = nil;
    BOOL redirect = NO;
    id<MTLTexture> src = nil;

    // This frame's motion vectors and scene depth.
    if (g_backbuffer) {
        for (int i = 0; i < 8; i++) {
            id<MTLTexture> t = d.colorAttachments[i].texture;
            if (t && t.pixelFormat == MTLPixelFormatRG16Snorm && t.width < g_backbuffer.width && t.width > g_backbuffer.width / 4)
                retain_set(&g_vel, t);
        }
        if (dt && dt.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 && dt.width < g_backbuffer.width && dt.width > g_backbuffer.width / 4) {
            retain_set(&g_sceneDepth, dt);
            g_sceneDepthFrame = g_frames;
        }
    }

    if (g_backbuffer && c0 == g_backbuffer && !g_bbPassThisFrame) {
        g_bbPassThisFrame = 1;
        src = last_color0(self);
        id<MTLTexture> bb = g_backbuffer;
        // Only when the pass right before it in this command buffer rendered
        // a smaller image with the window's aspect ratio: the scene at render
        // resolution. Menus draw UI here instead.
        if (g_mode != MODE_OFF && !g_disabled && src && src != bb && src.width < bb.width && src.height < bb.height &&
            fabs((double)src.width / src.height - (double)bb.width / bb.height) < 0.01) {
            id<MTLTexture> zt = dt ? dt : d.stencilAttachment.texture;
            if (ensure_resources([bb device], src, bb, zt ? zt.pixelFormat : MTLPixelFormatInvalid)) {
                copy = [d copy];
                copy.colorAttachments[0].texture = g_inter;
                copy.colorAttachments[0].loadAction = MTLLoadActionClear;
                copy.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                copy.colorAttachments[0].storeAction = MTLStoreActionStore;
                if (d.depthAttachment.texture) {
                    copy.depthAttachment.texture = g_interDepth;
                    copy.depthAttachment.loadAction = MTLLoadActionClear;
                    copy.depthAttachment.clearDepth = 1.0;
                    copy.depthAttachment.storeAction = MTLStoreActionDontCare;
                }
                if (d.stencilAttachment.texture) {
                    copy.stencilAttachment.texture = g_interDepth;
                    copy.stencilAttachment.loadAction = MTLLoadActionClear;
                    copy.stencilAttachment.clearStencil = 0;
                    copy.stencilAttachment.storeAction = MTLStoreActionDontCare;
                }
                use = copy;
                redirect = YES;
            }
        }
    }
    BOOL isComp = g_lastToneSrc && c0 == g_lastToneSrc && g_mode == MODE_TEMPORAL;
    if (isComp) stabilise_bloom(self);
    id e = orig_rce(self, _cmd, use);
    [copy release];
    if (isComp && e) g_compEnc = e;
    if (redirect && e) {
        g_rEnc = e; g_rCb = self; g_rSrc = src; g_rDraws = 0; g_rSrcSeen = 0;
        g_rSx = (double)g_inter.width / g_backbuffer.width;
        g_rSy = (double)g_inter.height / g_backbuffer.height;
        g_sceneW = src.width; g_sceneH = src.height;
        retain_set(&g_lastToneSrc, src);
    }
    // A scene pass: jitter its geometry. The encoder's default viewport is
    // the whole attachment, so set a jittered one right away.
    if (e && g_jitterOn && dt && dt == g_sceneDepth && dt.width == g_sceneW && dt.height == g_sceneH) {
        int slot = je_find(nil);
        if (slot >= 0) {
            g_je[slot].enc = e;
            g_je[slot].vp = (MTLViewport){ 0, 0, (double)dt.width, (double)dt.height, 0, 1 };
            g_je[slot].jittered = 1;
            orig_vp(e, @selector(setViewport:), jittered(g_je[slot].vp));
        }
    }
    set_last_color0(self, c0);
    pthread_mutex_unlock(&g_lock);
    return e;
}

HOOK(present, void, id drawable) {
    pthread_mutex_lock(&g_lock);
    g_bbPassThisFrame = 0;
    g_frames++;
    // No upscaled frame lately (menus, 100%, mode off): advance_jitter isn't
    // being called, so drop the jitter here or the picture would stay shifted.
    if (++g_framesSinceToneMap > 2 && (g_jitterOn || g_jx || g_jy)) { g_jitterOn = 0; g_jx = g_jy = 0; g_bias = 0; }
    update_lod_fix();
    pthread_mutex_unlock(&g_lock);
    orig_present(self, _cmd, drawable);
}

static void repl_copytt(id self, SEL _cmd, id s, NSUInteger ss, NSUInteger sl, MTLOrigin so, MTLSize sz, id d, NSUInteger ds, NSUInteger dl, MTLOrigin dor) {
    BOOL toDrawable = [[d label] isEqualToString:@"CAMetalLayer Drawable"];
    if (toDrawable) {
        pthread_mutex_lock(&g_lock);
        if (g_backbuffer != s) retain_set(&g_backbuffer, s);
        pthread_mutex_unlock(&g_lock);
    }
    orig_copytt(self, _cmd, s, ss, sl, so, sz, d, ds, dl, dor);
    if (toDrawable) {
        // The shortcut label, on top of everything in the frame.
        pthread_mutex_lock(&g_lock);
        id<MTLTexture> lbl = g_label, dt = d;
        if (lbl && CFAbsoluteTimeGetCurrent() < g_labelUntil && lbl.pixelFormat == dt.pixelFormat &&
            lbl.width + 32 <= dt.width && lbl.height + 32 <= dt.height)
            orig_copytt(self, _cmd, lbl, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(lbl.width, lbl.height, 1), dt, 0, 0, MTLOriginMake(32, 32, 0));
        pthread_mutex_unlock(&g_lock);
    }
}

// ---- render encoder hooks

static void repl_vp(id self, SEL _cmd, MTLViewport v) {
    if (self == g_rEnc) { v.originX *= g_rSx; v.width *= g_rSx; v.originY *= g_rSy; v.height *= g_rSy; }
    else {
        pthread_mutex_lock(&g_lock);
        int i = je_find(self);
        if (i >= 0) { g_je[i].vp = v; if (g_je[i].jittered) v = jittered(v); }
        pthread_mutex_unlock(&g_lock);
    }
    orig_vp(self, _cmd, v);
}
HOOK(pso, void, id p) {
    orig_pso(self, _cmd, p);
    pthread_mutex_lock(&g_lock);
    int i = je_find(self);
    if (i >= 0) {
        int want = ![g_fullscreenPSO containsObject:[NSValue valueWithPointer:p]];
        if (want != g_je[i].jittered) {
            g_je[i].jittered = want;
            orig_vp(self, @selector(setViewport:), want ? jittered(g_je[i].vp) : g_je[i].vp);
        }
    }
    pthread_mutex_unlock(&g_lock);
}
HOOK(sc, void, MTLScissorRect r) {
    if (self == g_rEnc) {
        NSUInteger x0 = (NSUInteger)(r.x * g_rSx), y0 = (NSUInteger)(r.y * g_rSy);
        NSUInteger x1 = (NSUInteger)ceil((r.x + r.width) * g_rSx), y1 = (NSUInteger)ceil((r.y + r.height) * g_rSy);
        if (x1 > g_inter.width) x1 = g_inter.width;
        if (y1 > g_inter.height) y1 = g_inter.height;
        if (x0 >= x1) x0 = x1 ? x1 - 1 : 0;
        if (y0 >= y1) y0 = y1 ? y1 - 1 : 0;
        r = (MTLScissorRect){ x0, y0, x1 - x0 ? x1 - x0 : 1, y1 - y0 ? y1 - y0 : 1 };
    }
    orig_sc(self, _cmd, r);
}
HOOK(ftex, void, id t, NSUInteger i) {
    if (self == g_rEnc && t == g_rSrc) g_rSrcSeen = 1;
    if (self == g_compEnc) note_bloom(t, i);
    orig_ftex(self, _cmd, t, i);
}
HOOK(ftexs, void, const id *t, NSRange r) {
    if (self == g_compEnc) for (NSUInteger i = 0; i < r.length; i++) note_bloom(t[i], r.location + i);
    if (self == g_rEnc) for (NSUInteger i = 0; i < r.length; i++) if (t[i] == g_rSrc) g_rSrcSeen = 1;
    orig_ftexs(self, _cmd, t, r);
}

static id biased_sampler(id smp) {
    if (!smp || g_bias == 0) return smp;
    if (g_biasCache != g_bias) { [g_biased removeAllObjects]; g_biasCache = g_bias; }
    NSValue *k = [NSValue valueWithPointer:smp];
    id b = g_biased[k];
    if (b) return b;
    MTLSamplerDescriptor *d = g_samplerDesc[k];
    // Only mipmapped, non-comparison samplers (not shadow maps).
    if (!d || d.mipFilter == MTLSamplerMipFilterNotMipmapped || d.compareFunction != MTLCompareFunctionNever) {
        g_biased[k] = smp;
        return smp;
    }
    MTLSamplerDescriptor *c = [d copy];
    if (@available(macOS 26.0, *)) c.lodBias = d.lodBias + g_bias;
    b = [[smp device] newSamplerStateWithDescriptor:c];
    [c release];
    if (!b) b = [smp retain];
    g_biased[k] = b;
    [b release];
    return b;
}
HOOK(newsmp, id, MTLSamplerDescriptor *d) {
    id smp = orig_newsmp(self, _cmd, d);
    if (smp) {
        pthread_mutex_lock(&g_lock);
        g_samplerDesc[[NSValue valueWithPointer:smp]] = [[d copy] autorelease];
        pthread_mutex_unlock(&g_lock);
    }
    return smp;
}
HOOK(fsmp, void, id smp, NSUInteger i) {
    pthread_mutex_lock(&g_lock);
    if (g_bias != 0 && je_find(self) >= 0) smp = biased_sampler(smp);
    pthread_mutex_unlock(&g_lock);
    orig_fsmp(self, _cmd, smp, i);
}
HOOK(fsmps, void, const id *smps, NSRange r) {
    id tmp[32];
    pthread_mutex_lock(&g_lock);
    if (g_bias != 0 && r.length <= 32 && je_find(self) >= 0) {
        for (NSUInteger i = 0; i < r.length; i++) tmp[i] = biased_sampler(smps[i]);
        smps = tmp;
    }
    pthread_mutex_unlock(&g_lock);
    orig_fsmps(self, _cmd, smps, r);
}
HOOK(fsmpc, void, id smp, float lo, float hi, NSUInteger i) {
    pthread_mutex_lock(&g_lock);
    if (g_bias != 0 && je_find(self) >= 0) smp = biased_sampler(smp);
    pthread_mutex_unlock(&g_lock);
    orig_fsmpc(self, _cmd, smp, lo, hi, i);
}
HOOK(fsmpcs, void, const id *smps, const float *lo, const float *hi, NSRange r) {
    id tmp[32];
    pthread_mutex_lock(&g_lock);
    if (g_bias != 0 && r.length <= 32 && je_find(self) >= 0) {
        for (NSUInteger i = 0; i < r.length; i++) tmp[i] = biased_sampler(smps[i]);
        smps = tmp;
    }
    pthread_mutex_unlock(&g_lock);
    orig_fsmpcs(self, _cmd, smps, lo, hi, r);
}

// Draw counting, for the redirected pass only.
HOOK(dipi, void, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id b, NSUInteger o, NSUInteger n) {
    if (self == g_rEnc) g_rDraws++;
    orig_dipi(self, _cmd, t, c, it, b, o, n);
}
HOOK(dipib, void, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id b, NSUInteger o, NSUInteger n, NSInteger bv, NSUInteger bi) {
    if (self == g_rEnc) g_rDraws++;
    orig_dipib(self, _cmd, t, c, it, b, o, n, bv, bi);
}
HOOK(dip, void, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id b, NSUInteger o) {
    if (self == g_rEnc) g_rDraws++;
    orig_dip(self, _cmd, t, c, it, b, o);
}
HOOK(dp, void, MTLPrimitiveType t, NSUInteger s, NSUInteger c) {
    if (self == g_rEnc) g_rDraws++;
    orig_dp(self, _cmd, t, s, c);
}
HOOK(dpi, void, MTLPrimitiveType t, NSUInteger s, NSUInteger c, NSUInteger n) {
    if (self == g_rEnc) g_rDraws++;
    orig_dpi(self, _cmd, t, s, c, n);
}

HOOK(rend, void) {
    orig_rend(self, _cmd);
    pthread_mutex_lock(&g_lock);
    int ji = je_find(self);
    if (ji >= 0) g_je[ji].enc = nil;
    if (self == g_compEnc) g_compEnc = nil;
    if (self != g_rEnc) { pthread_mutex_unlock(&g_lock); return; }
    if (g_rDraws != 1 || !g_rSrcSeen) {
        // Not the tone-map pass we expected. Whatever it drew is at render
        // size, so scale it anyway. Only stop redirecting if this keeps
        // happening (about 2 s in a row).
        if (++g_oddStreak > 240) {
            printf("[BO3MacFix] MetalFX: unexpected frames for %d frames in a row, turning it off\n", g_oddStreak);
            g_disabled = 1;
        }
    } else {
        g_oddStreak = 0;
    }
    id<MTLTexture> bb = g_backbuffer;
    BOOL done = NO;
    if (g_mode == MODE_TEMPORAL && !g_disabled) {
        ensure_temporal([bb device], g_inter.width, g_inter.height, bb);
        // Only when this frame was jittered for this scaler, and the inputs
        // match its size.
        if (g_jitterOn && g_tscaler && g_tIW == g_inter.width && g_tIH == g_inter.height &&
            g_vel.width == g_inter.width && g_sceneDepth.width == g_inter.width) {
            g_tscaler.colorTexture = g_inter;
            g_tscaler.depthTexture = g_sceneDepth;
            g_tscaler.motionTexture = g_vel;
            g_tscaler.outputTexture = bb;
            g_tscaler.inputContentWidth = g_inter.width;
            g_tscaler.inputContentHeight = g_inter.height;
            g_tscaler.jitterOffsetX = g_jx;
            g_tscaler.jitterOffsetY = g_jy;
            g_tscaler.motionVectorScaleX = -20;
            g_tscaler.motionVectorScaleY = -20;
            g_tscaler.depthReversed = YES;
            g_tscaler.reset = g_tReset;
            g_tReset = 0;
            [g_tscaler encodeToCommandBuffer:g_rCb];
            done = YES;
        }
    }
    if (!done) {
        g_scaler.colorTexture = g_inter;
        g_scaler.outputTexture = bb;
        g_scaler.inputContentWidth = g_inter.width;
        g_scaler.inputContentHeight = g_inter.height;
        [g_scaler encodeToCommandBuffer:g_rCb];
    }
    g_rEnc = nil; g_rCb = nil; g_rSrc = nil;
    advance_jitter();
    g_framesSinceToneMap = 0;
    pthread_mutex_unlock(&g_lock);
}

static BOOL swz(Class c, SEL s, IMP repl, IMP *orig) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) { printf("[BO3MacFix] MetalFX: no %s on %s\n", sel_getName(s), class_getName(c)); return NO; }
    *orig = method_setImplementation(m, repl);
    return YES;
}
#define SWZ(cls, sel, name) ok &= swz(cls, @selector(sel), (IMP)repl_##name, (IMP *)&orig_##name)

// Spatial by default: temporal looked softer to the player (it doesn't
// sharpen, and the jitter is limited to 0.35), so it's opt-in for now.
static int parse_mode(const char *s) {
    if (!s) return MODE_SPATIAL;
    if (!strcasecmp(s, "off")) return MODE_OFF;
    if (!strcasecmp(s, "temporal")) return MODE_TEMPORAL;
    return MODE_SPATIAL;
}

void metalfx_init(void) {
    const char *lod = getenv("BO3MACFIX_LODFIX");
    // Off unless asked for: it costs about 5% FPS.
    g_lodFix = lod && (!strcmp(lod, "1") || !strcasecmp(lod, "true"));
    g_mode = parse_mode(getenv("BO3MACFIX_UPSCALER"));
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev || !NSClassFromString(@"MTLFXSpatialScalerDescriptor") || ![MTLFXSpatialScalerDescriptor supportsDevice:dev]) {
            printf("[BO3MacFix] MetalFX not available, upscaling stays the game's\n");
            [dev release];
            return;
        }
        g_fullscreenPSO = [NSMutableSet new];
        g_samplerDesc = [NSMutableDictionary new];
        g_biased = [NSMutableDictionary new];

        // The driver's concrete classes, from throwaway objects.
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t;
        id re = [cb renderCommandEncoderWithDescriptor:rp]; Class reC = object_getClass(re); [re endEncoding];
        id be = [cb blitCommandEncoder]; Class beC = object_getClass(be); [be endEncoding];
        Class cbC = object_getClass(cb), devC = object_getClass(dev);

        BOOL ok = YES;
        SWZ(cbC, renderCommandEncoderWithDescriptor:, rce);
        SWZ(cbC, presentDrawable:, present);
        SWZ(beC, copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:, copytt);
        SWZ(devC, newRenderPipelineStateWithDescriptor:error:, newpso);
        SWZ(devC, newSamplerStateWithDescriptor:, newsmp);
        SWZ(reC, setViewport:, vp);
        SWZ(reC, setRenderPipelineState:, pso);
        SWZ(reC, setScissorRect:, sc);
        SWZ(reC, setFragmentTexture:atIndex:, ftex);
        SWZ(reC, setFragmentTextures:withRange:, ftexs);
        SWZ(reC, setFragmentSamplerState:atIndex:, fsmp);
        SWZ(reC, setFragmentSamplerStates:withRange:, fsmps);
        SWZ(reC, setFragmentSamplerState:lodMinClamp:lodMaxClamp:atIndex:, fsmpc);
        SWZ(reC, setFragmentSamplerStates:lodMinClamps:lodMaxClamps:withRange:, fsmpcs);
        SWZ(reC, drawPrimitives:vertexStart:vertexCount:, dp);
        SWZ(reC, drawPrimitives:vertexStart:vertexCount:instanceCount:, dpi);
        SWZ(reC, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:, dip);
        SWZ(reC, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:, dipi);
        SWZ(reC, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:, dipib);
        SWZ(reC, endEncoding, rend);
        [t release]; [q release]; [dev release];
        if (!ok) {
            // A hook is missing, so the passes can't be followed: never redirect.
            g_disabled = 1;
            printf("[BO3MacFix] MetalFX: Metal driver differs, upscaling stays the game's\n");
            return;
        }
        install_shortcuts();
        printf("[BO3MacFix] MetalFX %s, LOD fix %s (F7 / F8)\n", mode_name(g_mode), g_lodFix ? "on" : "off");
    }
}
