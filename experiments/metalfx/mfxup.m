// Prototype: replace BO3's render-resolution stretch with MetalFX spatial
// upscaling. Injected into the game alongside BO3MacFix.
//
// Frame structure (Aspyr's D3D11->Metal layer, ResolutionPercent < 100):
//   ... post-processing composite -> RG11B10F at render size
//   first pass into the swapchain backbuffer: ONE draw that tone maps that
//     texture and stretches it to the window size
//   HUD / UI passes into the backbuffer at full size
//   blit backbuffer -> CAMetalLayer drawable, present
//
// The tone-map pass is redirected into an intermediate at render size, so
// the game's own shader runs 1:1, and when it ends MetalFX scales the
// intermediate into the backbuffer. The HUD then draws on top as before.
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

static pthread_mutex_t g_lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;

static id<MTLTexture> g_backbuffer;     // texture ASL copies into the drawable
static int g_bbPassThisFrame;           // a backbuffer pass has begun this frame
static int g_off;                       // toggled by ~/Library/Logs/bo3-mfx-off
static int g_disabled;                  // a redirected pass didn't look right

#define NCB 32
static struct { id cb; id<MTLTexture> color0; } g_last[NCB]; // last color0 per command buffer
static int g_lastNext;

// The redirected encoder and what it needs at endEncoding.
static id g_rEnc, g_rCb;
static id<MTLTexture> g_rSrc;
static int g_rDraws, g_rSrcSeen;
static double g_rSx, g_rSy;

static id<MTLTexture> g_inter, g_interDepth;
static id<MTLFXSpatialScaler> g_scaler;
static NSUInteger g_sIW, g_sIH, g_sOW, g_sOH;

static unsigned long g_frames, g_upscaled;

#define HOOK(selname, ret, ...)                                   \
    static ret (*orig_##selname)(id, SEL, ##__VA_ARGS__);        \
    static ret repl_##selname(id self, SEL _cmd, ##__VA_ARGS__)

static id<MTLTexture> last_color0(id cb) {
    for (int i = 0; i < NCB; i++) if (g_last[i].cb == cb) return g_last[i].color0;
    return nil;
}
static void set_last_color0(id cb, id<MTLTexture> t) {
    for (int i = 0; i < NCB; i++) if (g_last[i].cb == cb) { g_last[i].color0 = t; return; }
    g_last[g_lastNext].cb = cb; g_last[g_lastNext].color0 = t; // weak: pointers only compared
    g_lastNext = (g_lastNext + 1) % NCB;
}

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
        fprintf(stderr, "mfx: scaler %lux%lu -> %lux%lu %s\n", (unsigned long)iw, (unsigned long)ih, (unsigned long)ow, (unsigned long)oh, g_scaler ? "ok" : "FAILED");
    }
    return g_inter && g_scaler && (depthFmt == MTLPixelFormatInvalid || g_interDepth);
}

HOOK(rce, id, MTLRenderPassDescriptor *d) {
    pthread_mutex_lock(&g_lock);
    id<MTLTexture> c0 = d.colorAttachments[0].texture;
    MTLRenderPassDescriptor *use = d, *copy = nil;
    BOOL redirect = NO;
    id<MTLTexture> src = nil;
    if (g_backbuffer && c0 == g_backbuffer && !g_bbPassThisFrame) {
        g_bbPassThisFrame = 1;
        src = last_color0(self);
        id<MTLTexture> bb = g_backbuffer;
        // Only when the pass right before it in this command buffer rendered
        // a smaller image with the window's aspect ratio: the scene at
        // render resolution. Menus draw UI here instead.
        if (!g_off && !g_disabled && src && src != bb && src.width < bb.width && src.height < bb.height &&
            fabs((double)src.width / src.height - (double)bb.width / bb.height) < 0.01) {
            id<MTLTexture> dt = d.depthAttachment.texture ? d.depthAttachment.texture : d.stencilAttachment.texture;
            if (ensure_resources([bb device], src, bb, dt ? dt.pixelFormat : MTLPixelFormatInvalid)) {
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
    id e = orig_rce(self, _cmd, use);
    [copy release];
    if (redirect && e) {
        g_rEnc = e; g_rCb = self; g_rSrc = src; g_rDraws = 0; g_rSrcSeen = 0;
        g_rSx = (double)g_inter.width / g_backbuffer.width;
        g_rSy = (double)g_inter.height / g_backbuffer.height;
    }
    set_last_color0(self, c0);
    pthread_mutex_unlock(&g_lock);
    return e;
}

HOOK(present, void, id drawable) {
    pthread_mutex_lock(&g_lock);
    g_bbPassThisFrame = 0;
    if ((++g_frames & 63) == 0)
        g_off = access([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/bo3-mfx-off"] fileSystemRepresentation], F_OK) == 0;
    if ((g_frames % 3600) == 0) fprintf(stderr, "mfx: %lu frames, %lu upscaled%s%s\n", g_frames, g_upscaled, g_off ? " (off)" : "", g_disabled ? " (disabled)" : "");
    pthread_mutex_unlock(&g_lock);
    orig_present(self, _cmd, drawable);
}

HOOK(copytt, void, id s, NSUInteger ss, NSUInteger sl, MTLOrigin so, MTLSize sz, id d, NSUInteger ds, NSUInteger dl, MTLOrigin dor) {
    if ([[d label] isEqualToString:@"CAMetalLayer Drawable"]) {
        pthread_mutex_lock(&g_lock);
        if (g_backbuffer != s) {
            [g_backbuffer release]; g_backbuffer = [s retain];
            fprintf(stderr, "mfx: backbuffer %lux%lu fmt %lu\n", (unsigned long)[s width], (unsigned long)[s height], (unsigned long)[s pixelFormat]);
        }
        pthread_mutex_unlock(&g_lock);
    }
    orig_copytt(self, _cmd, s, ss, sl, so, sz, d, ds, dl, dor);
}

HOOK(vp, void, MTLViewport v) {
    if (self == g_rEnc) { v.originX *= g_rSx; v.width *= g_rSx; v.originY *= g_rSy; v.height *= g_rSy; }
    orig_vp(self, _cmd, v);
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
    orig_ftex(self, _cmd, t, i);
}
HOOK(ftexs, void, const id *t, NSRange r) {
    if (self == g_rEnc) for (NSUInteger i = 0; i < r.length; i++) if (t[i] == g_rSrc) g_rSrcSeen = 1;
    orig_ftexs(self, _cmd, t, r);
}
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
    if (self != g_rEnc) return;
    pthread_mutex_lock(&g_lock);
    if (g_rDraws != 1 || !g_rSrcSeen) {
        // Not the tone-map pass we expected. Still scale what was drawn so
        // this frame shows something, but stop redirecting.
        fprintf(stderr, "mfx: unexpected pass (draws=%d srcBound=%d), disabling\n", g_rDraws, g_rSrcSeen);
        g_disabled = 1;
    }
    g_scaler.colorTexture = g_inter;
    g_scaler.outputTexture = g_backbuffer;
    g_scaler.inputContentWidth = g_inter.width;
    g_scaler.inputContentHeight = g_inter.height;
    [g_scaler encodeToCommandBuffer:g_rCb];
    g_upscaled++;
    g_rEnc = nil; g_rCb = nil; g_rSrc = nil;
    pthread_mutex_unlock(&g_lock);
}

static void swz(Class c, SEL s, IMP repl, IMP *orig) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) { fprintf(stderr, "mfx: no %s on %s\n", sel_getName(s), class_getName(c)); return; }
    *orig = method_setImplementation(m, repl);
}
#define SWZ(cls, sel, name) swz(cls, @selector(sel), (IMP)repl_##name, (IMP *)&orig_##name)

__attribute__((constructor)) static void mfx_init(void) {
    if (getenv("BO3_MFX") && !strcmp(getenv("BO3_MFX"), "0")) return;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (![MTLFXSpatialScalerDescriptor supportsDevice:dev]) { fprintf(stderr, "mfx: MetalFX not supported\n"); return; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t;
        id re = [cb renderCommandEncoderWithDescriptor:rp]; Class reC = object_getClass(re); [re endEncoding];
        id be = [cb blitCommandEncoder]; Class beC = object_getClass(be); [be endEncoding];
        Class cbC = object_getClass(cb);

        SWZ(cbC, renderCommandEncoderWithDescriptor:, rce);
        SWZ(cbC, presentDrawable:, present);
        SWZ(beC, copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:, copytt);
        SWZ(reC, setViewport:, vp);
        SWZ(reC, setScissorRect:, sc);
        SWZ(reC, setFragmentTexture:atIndex:, ftex);
        SWZ(reC, setFragmentTextures:withRange:, ftexs);
        SWZ(reC, drawPrimitives:vertexStart:vertexCount:, dp);
        SWZ(reC, drawPrimitives:vertexStart:vertexCount:instanceCount:, dpi);
        SWZ(reC, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:, dip);
        SWZ(reC, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:, dipi);
        SWZ(reC, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:, dipib);
        SWZ(reC, endEncoding, rend);
        fprintf(stderr, "mfx: installed (%s)\n", class_getName(cbC));
        [t release]; [q release]; [dev release];
    }
}
