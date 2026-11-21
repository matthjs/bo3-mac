// Frame-structure probe for the Aspyr D3D11->Metal layer. Injected into the
// game. Logs one frame to ~/Library/Logs/bo3-mfx/frame.txt when
// ~/Library/Logs/bo3-mfx-capture exists, and compares the tone-map pass's
// input and output pixels into pixels.txt when ~/Library/Logs/bo3-mfx-pixels
// exists. Both trigger files are deleted once used.
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

static pthread_mutex_t g_lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;
static FILE *g_log;
static int g_capturing;     // 1 while logging a frame
static int g_frame_cap_done;
static long g_draws, g_passes;
static NSMutableDictionary *g_libSrc;   // lib ptr -> source
static NSMutableDictionary *g_funcLib;  // func ptr -> lib ptr
static NSMutableDictionary *g_psoFuncs; // pso ptr -> @[vs, fs]
static NSMutableSet *g_dumpedLibs;
static NSString *g_dir;
static NSMutableDictionary *g_funcName; // func ptr -> name
static id<MTLTexture> g_backbuffer;                 // texture ASL copies into the drawable
static int g_bbPasses;                  // backbuffer passes this frame
static id g_upEnc, g_upCb, g_upTex, g_upPso;
static int g_upDraws, g_upLogged;
static uint32_t g_upCount;
static void up_end(id enc);
static id g_compEnc;                    // the bloom_apply_lut pass
static id<MTLTexture> g_compTex[8];     // what it read, by index
static NSMutableDictionary *g_cpsoName; // compute pso -> function name
static id<MTLTexture> g_vel, g_sceneDepth; // render-size RG16Snorm target and depth seen this frame
static double g_t0;

#define KEY(o) [NSValue valueWithPointer:(const void *)(o)]

static const char *tdesc(id<MTLTexture> t) {
    static __thread char buf[4][160];
    static __thread int k;
    char *b = buf[k++ & 3];
    if (!t) { snprintf(b, 160, "nil"); return b; }
    snprintf(b, 160, "%p %lux%lu fmt=%lu use=%lx st=%lu type=%lu%s%s", t,
             (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat,
             (unsigned long)t.usage, (unsigned long)t.storageMode, (unsigned long)t.textureType,
             t.parentTexture ? " view" : "", t.label ? [[@" " stringByAppendingString:t.label] UTF8String] : "");
    return b;
}

static void L(const char *fmt, ...) {
    if (!g_capturing || !g_log) return;
    va_list ap; va_start(ap, fmt);
    fprintf(g_log, "[%p] ", (void *)pthread_self());
    vfprintf(g_log, fmt, ap);
    fputc('\n', g_log);
    va_end(ap);
}

static void dump_lib(id lib) {
    if (!lib || [g_dumpedLibs containsObject:KEY(lib)]) return;
    NSString *src = g_libSrc[KEY(lib)];
    if (!src) return;
    [g_dumpedLibs addObject:KEY(lib)];
    NSString *p = [g_dir stringByAppendingFormat:@"/lib_%p.metal", lib];
    [src writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static const char *psodesc(id pso) {
    static __thread char buf[200];
    NSArray *f = g_psoFuncs[KEY(pso)];
    id vs = f.count > 0 ? f[0] : nil, fs = f.count > 1 ? f[1] : nil;
    id vl = vs ? g_funcLib[vs] : nil, fl = fs ? g_funcLib[fs] : nil;
    if (g_capturing) { if (vl) dump_lib([vl pointerValue]); if (fl) dump_lib([fl pointerValue]); }
    snprintf(buf, sizeof buf, "pso=%p vs=%s fs=%s", pso, vs ? [[g_funcName[vs] description] UTF8String] : "?", fs ? [[g_funcName[fs] description] UTF8String] : "?");
    (void)vl; (void)fl;
    return buf;
}

#define HOOK(cls, selname, ret, ...)                                              \
    static ret (*orig_##selname)(id, SEL, ##__VA_ARGS__);                        \
    static ret repl_##selname(id self, SEL _cmd, ##__VA_ARGS__)

// ---- command buffer
HOOK(cb, rce, id, MTLRenderPassDescriptor *d) {
    id e = orig_rce(self, _cmd, d);
    pthread_mutex_lock(&g_lock);
    if (g_backbuffer) {
        for (int i = 0; i < 8; i++) {
            id<MTLTexture> t = d.colorAttachments[i].texture;
            if (t && t.pixelFormat == MTLPixelFormatRG16Snorm && t.width < g_backbuffer.width && t.width > g_backbuffer.width / 4 && g_vel != t) { [g_vel release]; g_vel = [t retain]; }
        }
        id<MTLTexture> dt = d.depthAttachment.texture;
        if (dt && dt.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 && dt.width < g_backbuffer.width && dt.width > g_backbuffer.width / 4 && g_sceneDepth != dt) { [g_sceneDepth release]; g_sceneDepth = [dt retain]; }
    }
    if (g_backbuffer && d.colorAttachments[0].texture == g_backbuffer && g_bbPasses++ == 0) {
        g_upEnc = e; g_upCb = self; g_upTex = nil; g_upPso = nil; g_upDraws = 0;
    }
    if (g_capturing) {
        g_passes++;
        L("RENDERPASS enc=%p cb=%p", e, self);
        for (int i = 0; i < 8; i++) {
            MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
            if (c.texture) L("  color%d %s lvl=%lu slice=%lu load=%lu store=%lu resolve=%s", i, tdesc(c.texture), (unsigned long)c.level, (unsigned long)c.slice, (unsigned long)c.loadAction, (unsigned long)c.storeAction, tdesc(c.resolveTexture));
        }
        if (d.depthAttachment.texture) L("  depth %s load=%lu store=%lu", tdesc(d.depthAttachment.texture), (unsigned long)d.depthAttachment.loadAction, (unsigned long)d.depthAttachment.storeAction);
        if (d.stencilAttachment.texture) L("  stencil %s load=%lu store=%lu", tdesc(d.stencilAttachment.texture), (unsigned long)d.stencilAttachment.loadAction, (unsigned long)d.stencilAttachment.storeAction);
    }
    pthread_mutex_unlock(&g_lock);
    return e;
}
HOOK(cb, blit, id) {
    id e = orig_blit(self, _cmd);
    pthread_mutex_lock(&g_lock); L("BLITPASS enc=%p cb=%p", e, self); pthread_mutex_unlock(&g_lock);
    return e;
}
HOOK(cb, comp, id) {
    id e = orig_comp(self, _cmd);
    pthread_mutex_lock(&g_lock); L("COMPUTEPASS enc=%p cb=%p", e, self); pthread_mutex_unlock(&g_lock);
    return e;
}
HOOK(cb, commit, void) {
    pthread_mutex_lock(&g_lock); L("COMMIT cb=%p", self); pthread_mutex_unlock(&g_lock);
    orig_commit(self, _cmd);
}
HOOK(cb, present, void, id drawable) {
    pthread_mutex_lock(&g_lock);
    g_bbPasses = 0;
    if (g_capturing) {
        L("PRESENT cb=%p drawable=%p tex=%s", self, drawable, tdesc([drawable texture]));
        if (++g_frame_cap_done >= 2) {
            fprintf(g_log, "END passes=%ld draws=%ld\n", g_passes, g_draws);
            fclose(g_log); g_log = NULL; g_capturing = 0;
        }
    } else if (access([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/bo3-mfx-capture"] fileSystemRepresentation], F_OK) == 0) {
        unlink([[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/bo3-mfx-capture"] fileSystemRepresentation]);
        [[NSFileManager defaultManager] createDirectoryAtPath:g_dir withIntermediateDirectories:YES attributes:nil error:nil];
        g_log = fopen([[g_dir stringByAppendingPathComponent:@"frame.txt"] fileSystemRepresentation], "w");
        g_capturing = 1; g_frame_cap_done = 0; g_draws = g_passes = 0;
        L("START (after present of cb=%p drawable tex=%s)", self, tdesc([drawable texture]));
    }
    pthread_mutex_unlock(&g_lock);
    orig_present(self, _cmd, drawable);
}

// ---- render encoder
HOOK(re, pso, void, id p) {
    pthread_mutex_lock(&g_lock);
    {
        NSArray *f = g_psoFuncs[KEY(p)];
        NSString *fn = f.count > 1 ? g_funcName[f[1]] : nil;
        if (fn && [fn rangeOfString:@"bloom_apply_lut"].location != NSNotFound) g_compEnc = self;
    } if (self == g_upEnc) g_upPso = p; if (g_capturing) L(" setPSO %s", psodesc(p)); pthread_mutex_unlock(&g_lock);
    orig_pso(self, _cmd, p);
}
HOOK(re, ftex, void, id t, NSUInteger i) {
    pthread_mutex_lock(&g_lock);
    if (self == g_compEnc && i < 8 && g_compTex[i] != t) { [g_compTex[i] release]; g_compTex[i] = [t retain]; } if (self == g_upEnc && i == 0) g_upTex = t; if (g_capturing) L(" fs.tex[%lu] %s", (unsigned long)i, tdesc(t)); pthread_mutex_unlock(&g_lock);
    orig_ftex(self, _cmd, t, i);
}
HOOK(re, ftexs, void, const id *t, NSRange r) {
    pthread_mutex_lock(&g_lock); if (self == g_upEnc && r.location == 0 && r.length) g_upTex = t[0];
    if (g_capturing) for (NSUInteger i = 0; i < r.length; i++) if (t[i]) L(" fs.tex[%lu] %s", (unsigned long)(r.location + i), tdesc(t[i]));
    pthread_mutex_unlock(&g_lock);
    orig_ftexs(self, _cmd, t, r);
}
HOOK(re, vtex, void, id t, NSUInteger i) {
    pthread_mutex_lock(&g_lock); if (g_capturing) L(" vs.tex[%lu] %s", (unsigned long)i, tdesc(t)); pthread_mutex_unlock(&g_lock);
    orig_vtex(self, _cmd, t, i);
}
HOOK(re, vtexs, void, const id *t, NSRange r) {
    pthread_mutex_lock(&g_lock);
    if (g_capturing) for (NSUInteger i = 0; i < r.length; i++) if (t[i]) L(" vs.tex[%lu] %s", (unsigned long)(r.location + i), tdesc(t[i]));
    pthread_mutex_unlock(&g_lock);
    orig_vtexs(self, _cmd, t, r);
}
HOOK(re, vp, void, MTLViewport v) {
    pthread_mutex_lock(&g_lock); if (g_capturing) L(" viewport %.0f,%.0f %.0fx%.0f", v.originX, v.originY, v.width, v.height); pthread_mutex_unlock(&g_lock);
    orig_vp(self, _cmd, v);
}
HOOK(re, dp, void, MTLPrimitiveType t, NSUInteger s, NSUInteger c) {
    pthread_mutex_lock(&g_lock); if (self == g_upEnc) { g_upDraws++; } if (g_capturing) { g_draws++; L(" DRAW prim=%lu count=%lu", (unsigned long)t, (unsigned long)c); } pthread_mutex_unlock(&g_lock);
    orig_dp(self, _cmd, t, s, c);
}
HOOK(re, dpi, void, MTLPrimitiveType t, NSUInteger s, NSUInteger c, NSUInteger n) {
    pthread_mutex_lock(&g_lock); if (self == g_upEnc) { g_upDraws++; } if (g_capturing) { g_draws++; L(" DRAW prim=%lu count=%lu inst=%lu", (unsigned long)t, (unsigned long)c, (unsigned long)n); } pthread_mutex_unlock(&g_lock);
    orig_dpi(self, _cmd, t, s, c, n);
}
HOOK(re, dip, void, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id b, NSUInteger o) {
    pthread_mutex_lock(&g_lock); if (self == g_upEnc) { g_upDraws++; } if (g_capturing) { g_draws++; L(" DRAWIDX prim=%lu count=%lu", (unsigned long)t, (unsigned long)c); } pthread_mutex_unlock(&g_lock);
    orig_dip(self, _cmd, t, c, it, b, o);
}
HOOK(re, dipi, void, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id b, NSUInteger o, NSUInteger n) {
    pthread_mutex_lock(&g_lock); if (self == g_upEnc) { g_upDraws++; } if (g_capturing) { g_draws++; L(" DRAWIDX prim=%lu count=%lu inst=%lu", (unsigned long)t, (unsigned long)c, (unsigned long)n); } pthread_mutex_unlock(&g_lock);
    orig_dipi(self, _cmd, t, c, it, b, o, n);
}
HOOK(re, dipib, void, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id b, NSUInteger o, NSUInteger n, NSInteger bv, NSUInteger bi) {
    pthread_mutex_lock(&g_lock); if (self == g_upEnc) { g_upDraws++; } if (g_capturing) { g_draws++; L(" DRAWIDX prim=%lu count=%lu inst=%lu", (unsigned long)t, (unsigned long)c, (unsigned long)n); } pthread_mutex_unlock(&g_lock);
    orig_dipib(self, _cmd, t, c, it, b, o, n, bv, bi);
}
HOOK(re, rend, void) {
    pthread_mutex_lock(&g_lock); if (g_capturing) L(" endEncoding enc=%p", self); pthread_mutex_unlock(&g_lock);
    orig_rend(self, _cmd);
    if (self == g_upEnc) { pthread_mutex_lock(&g_lock); up_end(self); g_upEnc = nil; pthread_mutex_unlock(&g_lock); }
}

static float f11(uint32_t v) { uint32_t e = (v >> 6) & 31, m = v & 63; if (!e) return ldexpf(m, -14 - 6); return ldexpf(1.0f + m / 64.0f, (int)e - 15); }
static float f10(uint32_t v) { uint32_t e = (v >> 5) & 31, m = v & 31; if (!e) return ldexpf(m, -14 - 5); return ldexpf(1.0f + m / 32.0f, (int)e - 15); }

// Every 8th scene frame, read 5 blocks of the suspected velocity buffer and
// the centre of the scene depth into ~/Library/Logs/bo3-mfx/vel.txt.
static void log_vel(id<MTLCommandBuffer> cb) {
    static unsigned n;
    if ((n++ & 7) || !g_vel || !g_sceneDepth) return;
    enum { B = 32, NB = 5 };
    id<MTLTexture> v = [g_vel retain], dz = [g_sceneDepth retain];
    NSUInteger w = MIN(v.width, dz.width), h = MIN(v.height, dz.height);
    NSUInteger bx[NB] = { w / 2, w / 4, 3 * w / 4, w / 4, 3 * w / 4 }, by[NB] = { h / 2, h / 4, h / 4, 3 * h / 4, 3 * h / 4 };
    id<MTLDevice> dev = [v device];
    id<MTLBuffer> bv = [dev newBufferWithLength:NB * B * B * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> bd = [dev newBufferWithLength:NB * B * B * 4 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    for (int k = 0; k < NB; k++) {
        MTLOrigin o = MTLOriginMake(bx[k] - B / 2, by[k] - B / 2, 0);
        [be copyFromTexture:v sourceSlice:0 sourceLevel:0 sourceOrigin:o sourceSize:MTLSizeMake(B, B, 1) toBuffer:bv destinationOffset:k * B * B * 4 destinationBytesPerRow:B * 4 destinationBytesPerImage:B * B * 4];
        [be copyFromTexture:dz sourceSlice:0 sourceLevel:0 sourceOrigin:o sourceSize:MTLSizeMake(B, B, 1) toBuffer:bd destinationOffset:k * B * B * 4 destinationBytesPerRow:B * 4 destinationBytesPerImage:B * B * 4 options:MTLBlitOptionDepthFromDepthStencil];
    }
    [be endEncoding];
    double t = CFAbsoluteTimeGetCurrent() - g_t0;
    NSString *path = [[g_dir stringByAppendingPathComponent:@"vel.txt"] retain];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        FILE *o = fopen([path fileSystemRepresentation], "a");
        if (!o) { [bv release]; [bd release]; [path release]; [v release]; [dz release]; return; }
        fprintf(o, "%8.2f", t);
        const int16_t *pv = bv.contents; const float *pd = bd.contents;
        for (int k = 0; k < NB; k++) {
            double mx = 0, my = 0, ax = 0, ay = 0, dsum = 0, dmin = 1e9, dmax = -1e9;
            for (int p = 0; p < B * B; p++) {
                double x = pv[(k * B * B + p) * 2] / 32767.0, y = pv[(k * B * B + p) * 2 + 1] / 32767.0;
                mx += x; my += y; ax += fabs(x); ay += fabs(y);
                double z = pd[k * B * B + p]; dsum += z; if (z < dmin) dmin = z; if (z > dmax) dmax = z;
            }
            mx /= B * B; my /= B * B; ax /= B * B; ay /= B * B;
            fprintf(o, " | v%+.5f,%+.5f a%.5f,%.5f z%.5f[%.5f..%.5f]", mx, my, ax, ay, dsum / (B * B), dmin, dmax);
        }
        fprintf(o, "\n");
        fclose(o);
        [bv release]; [bd release]; [path release]; [v release]; [dz release];
    }];
}

// Ground truth for the motion vectors: when ~/Library/Logs/bo3-mfx-dump
// appears, wait 8 s (time to get back into the game), then save bursts of 4
// consecutive frames every 4 s, 6 bursts: the tone-map input, the motion
// vectors and the scene depth, raw, into ~/Library/Logs/bo3-mfx/dump/.
static double g_dumpStart = -1;
static int g_dumpFrame, g_dumpBurst;
static void dump_frame(id<MTLCommandBuffer> cb, id<MTLTexture> src) {
    const char *flag = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/bo3-mfx-dump"] fileSystemRepresentation];
    double now = CFAbsoluteTimeGetCurrent();
    if (g_dumpStart < 0) {
        static unsigned n;
        if ((n++ & 31) || access(flag, F_OK) != 0) return;
        unlink(flag);
        g_dumpStart = now + 8; g_dumpBurst = 0; g_dumpFrame = 0;
        [[NSFileManager defaultManager] createDirectoryAtPath:[g_dir stringByAppendingPathComponent:@"dump"] withIntermediateDirectories:YES attributes:nil error:nil];
        fprintf(stderr, "mfx-probe: dump armed\n");
        return;
    }
    if (now < g_dumpStart + g_dumpBurst * 4.0) return;
    if (!g_vel || !g_sceneDepth || g_vel.width != src.width || g_sceneDepth.width != src.width) return;
    NSUInteger w = src.width, h = src.height, sz = w * h * 4;
    id<MTLDevice> dev = [src device];
    id<MTLTexture> tx[3] = { [src retain], [g_vel retain], [g_sceneDepth retain] };
    id<MTLBuffer> bf[3];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    for (int i = 0; i < 3; i++) {
        bf[i] = [dev newBufferWithLength:sz options:MTLResourceStorageModeShared];
        [be copyFromTexture:tx[i] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:bf[i] destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:sz options:i == 2 ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionNone];
    }
    // The composite pass's inputs: 0 = bloom, 2 = scene, 4 = half-size bloom with lens flares.
    int ci[3] = { 0, 2, 4 };
    id<MTLBuffer> cbuf[3] = { nil, nil, nil };
    id<MTLTexture> ctex[3] = { nil, nil, nil };
    for (int k = 0; k < 3; k++) {
        id<MTLTexture> t = g_compTex[ci[k]];
        if (!t || t.pixelFormat != MTLPixelFormatRG11B10Float) continue;
        ctex[k] = [t retain];
        cbuf[k] = [dev newBufferWithLength:t.width * t.height * 4 options:MTLResourceStorageModeShared];
        [be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:cbuf[k] destinationOffset:0 destinationBytesPerRow:t.width * 4 destinationBytesPerImage:t.width * t.height * 4];
    }
    [be endEncoding];
    int b = g_dumpBurst, f = g_dumpFrame;
    id<MTLBuffer> cb0 = cbuf[0], cb1 = cbuf[1], cb2 = cbuf[2];
    id<MTLTexture> ct0 = ctex[0], ct1 = ctex[1], ct2 = ctex[2];
    double t = now - g_t0;
    NSString *dir = [[g_dir stringByAppendingPathComponent:@"dump"] retain];
    id<MTLBuffer> b0 = bf[0], b1 = bf[1], b2 = bf[2];
    id<MTLTexture> t0 = tx[0], t1 = tx[1], t2 = tx[2];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        const char *names[3] = { "color", "vel", "depth" };
        id<MTLBuffer> bb[3] = { b0, b1, b2 };
        for (int i = 0; i < 3; i++) {
            FILE *o = fopen([[dir stringByAppendingFormat:@"/b%d_f%d_%s.raw", b, f, names[i]] fileSystemRepresentation], "wb");
            if (o) { fwrite([bb[i] contents], 1, sz, o); fclose(o); }
            [bb[i] release];
        }
        id<MTLBuffer> cbb[3] = { cb0, cb1, cb2 };
        id<MTLTexture> ctt[3] = { ct0, ct1, ct2 };
        for (int k = 0; k < 3; k++) {
            if (!cbb[k]) continue;
            FILE *o = fopen([[dir stringByAppendingFormat:@"/b%d_f%d_c%d_%lux%lu.raw", b, f, k * 2, (unsigned long)ctt[k].width, (unsigned long)ctt[k].height] fileSystemRepresentation], "wb");
            if (o) { fwrite([cbb[k] contents], 1, ctt[k].width * ctt[k].height * 4, o); fclose(o); }
            [cbb[k] release]; [ctt[k] release];
        }
        FILE *m = fopen([[dir stringByAppendingPathComponent:@"meta.txt"] fileSystemRepresentation], "a");
        if (m) { fprintf(m, "b%d f%d t=%.4f %lux%lu vel=%p\n", b, f, t, (unsigned long)w, (unsigned long)h, t1); fclose(m); }
        [dir release]; [t0 release]; [t1 release]; [t2 release];
    }];
    if (++g_dumpFrame == 4) {
        g_dumpFrame = 0;
        if (++g_dumpBurst == 6) { g_dumpStart = -1; fprintf(stderr, "mfx-probe: dump done\n"); }
    }
}

// Called after the first backbuffer pass of a frame ends.
static void up_end(id enc) {
    id<MTLTexture> src = g_upTex, dst = g_backbuffer;
    if (g_upDraws != 1 || !src || src.width >= dst.width) return;
    if (!g_upLogged) {
        g_upLogged = 1;
        NSArray *f = g_psoFuncs[KEY(g_upPso)];
        fprintf(stderr, "mfx-probe: upscale pass src=%s dst=%s pso=%p vs=%s fs=%s\n", tdesc(src), tdesc(dst), g_upPso,
                f.count > 0 ? [[g_funcName[f[0]] description] UTF8String] : "?", f.count > 1 ? [[g_funcName[f[1]] description] UTF8String] : "?");
    }
    g_upCount++;
    log_vel(g_upCb);
    dump_frame(g_upCb, src);
    const char *flag = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/bo3-mfx-pixels"] fileSystemRepresentation];
    if (access(flag, F_OK) != 0) return;
    unlink(flag);
    const int B = 32, G = 3;
    NSUInteger sw = src.width, sh = src.height, dw = dst.width, dh = dst.height;
    int sb = (int)(B * sw / dw);
    id<MTLDevice> dev = [dst device];
    id<MTLBuffer> bs = [dev newBufferWithLength:G * G * sb * sb * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> bd = [dev newBufferWithLength:G * G * B * B * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = g_upCb;
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    for (int j = 0; j < G; j++) for (int i = 0; i < G; i++) {
        int k = j * G + i;
        NSUInteger dx = dw * (i + 1) / (G + 1) - B / 2, dy = dh * (j + 1) / (G + 1) - B / 2;
        NSUInteger sx = dx * sw / dw, sy = dy * sh / dh;
        [be copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sx, sy, 0) sourceSize:MTLSizeMake(sb, sb, 1) toBuffer:bs destinationOffset:k * sb * sb * 4 destinationBytesPerRow:sb * 4 destinationBytesPerImage:sb * sb * 4];
        [be copyFromTexture:dst sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(dx, dy, 0) sourceSize:MTLSizeMake(B, B, 1) toBuffer:bd destinationOffset:k * B * B * 4 destinationBytesPerRow:B * 4 destinationBytesPerImage:B * B * 4];
    }
    [be endEncoding];
    MTLPixelFormat sf = src.pixelFormat;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        FILE *o = fopen([[g_dir stringByAppendingPathComponent:@"pixels.txt"] fileSystemRepresentation], "a");
        if (!o) { [bs release]; [bd release]; return; }
        fprintf(o, "--- src fmt %lu %lux%lu -> dst %lux%lu\n", (unsigned long)sf, (unsigned long)sw, (unsigned long)sh, (unsigned long)dw, (unsigned long)dh);
        const uint32_t *ps = bs.contents; const uint8_t *pd = bd.contents;
        for (int k = 0; k < G * G; k++) {
            double s3[3] = {0}, d3[3] = {0}, smax = 0;
            for (int p = 0; p < sb * sb; p++) {
                uint32_t v = ps[k * sb * sb + p];
                float r = f11(v & 0x7ff), g = f11((v >> 11) & 0x7ff), b = f10(v >> 22);
                s3[0] += r; s3[1] += g; s3[2] += b; if (r > smax) smax = r;
            }
            for (int p = 0; p < B * B; p++) { const uint8_t *q = pd + (k * B * B + p) * 4; d3[2] += q[0] / 255.0; d3[1] += q[1] / 255.0; d3[0] += q[2] / 255.0; }
            for (int c3 = 0; c3 < 3; c3++) { s3[c3] /= sb * sb; d3[c3] /= B * B; }
            fprintf(o, "blk%d src %.4f %.4f %.4f (max %.3f)  dst %.4f %.4f %.4f  ratio %.3f %.3f %.3f\n", k, s3[0], s3[1], s3[2], smax, d3[0], d3[1], d3[2],
                    s3[0] > 0.001 ? d3[0] / s3[0] : 0, s3[1] > 0.001 ? d3[1] / s3[1] : 0, s3[2] > 0.001 ? d3[2] / s3[2] : 0);
        }
        fclose(o);
        [bs release]; [bd release];
    }];
}

// ---- blit / compute encoders
HOOK(be, copytt, void, id s, NSUInteger ss, NSUInteger sl, MTLOrigin so, MTLSize sz, id d, NSUInteger ds, NSUInteger dl, MTLOrigin dor) {
    pthread_mutex_lock(&g_lock);
    if ([[d label] isEqualToString:@"CAMetalLayer Drawable"] && g_backbuffer != s) {
        [g_backbuffer release]; g_backbuffer = [s retain];
        fprintf(stderr, "mfx-probe: backbuffer %s\n", tdesc(s));
    } if (g_capturing) L(" COPY %s -> %s size %lux%lu", tdesc(s), tdesc(d), (unsigned long)sz.width, (unsigned long)sz.height); pthread_mutex_unlock(&g_lock);
    orig_copytt(self, _cmd, s, ss, sl, so, sz, d, ds, dl, dor);
}
HOOK(ce, ctex, void, id t, NSUInteger i) {
    pthread_mutex_lock(&g_lock); if (g_capturing) L(" cs.tex[%lu] %s", (unsigned long)i, tdesc(t)); pthread_mutex_unlock(&g_lock);
    orig_ctex(self, _cmd, t, i);
}
HOOK(dev, newcpso, id, id fn, NSError **e) {
    id p = orig_newcpso(self, _cmd, fn, e);
    if (p) { pthread_mutex_lock(&g_lock); g_cpsoName[KEY(p)] = [[fn name] copy]; pthread_mutex_unlock(&g_lock); }
    return p;
}
HOOK(ce, cpso, void, id p) {
    pthread_mutex_lock(&g_lock); if (g_capturing) L(" setComputePSO %p %s", p, [[g_cpsoName[KEY(p)] description] UTF8String]); pthread_mutex_unlock(&g_lock);
    orig_cpso(self, _cmd, p);
}
HOOK(ce, disp, void, MTLSize g, MTLSize t) {
    pthread_mutex_lock(&g_lock); if (g_capturing) L(" DISPATCH %lux%lux%lu x %lux%lux%lu", (unsigned long)g.width, (unsigned long)g.height, (unsigned long)g.depth, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth); pthread_mutex_unlock(&g_lock);
    orig_disp(self, _cmd, g, t);
}

// ---- device / library (shader source bookkeeping)
HOOK(dev, newlib, id, NSString *src, MTLCompileOptions *o, NSError **e) {
    id lib = orig_newlib(self, _cmd, src, o, e);
    if (lib) { pthread_mutex_lock(&g_lock); g_libSrc[KEY(lib)] = [src copy]; pthread_mutex_unlock(&g_lock); }
    return lib;
}
HOOK(lib, newfunc, id, NSString *name) {
    id f = orig_newfunc(self, _cmd, name);
    if (f) { pthread_mutex_lock(&g_lock); g_funcLib[KEY(f)] = KEY(self); g_funcName[KEY(f)] = [name copy]; pthread_mutex_unlock(&g_lock); }
    return f;
}
HOOK(dev, newpso, id, MTLRenderPipelineDescriptor *d, NSError **e) {
    id p = orig_newpso(self, _cmd, d, e);
    if (p) {
        pthread_mutex_lock(&g_lock);
        g_psoFuncs[KEY(p)] = @[ d.vertexFunction ? KEY(d.vertexFunction) : KEY(NULL), d.fragmentFunction ? KEY(d.fragmentFunction) : KEY(NULL) ];
        pthread_mutex_unlock(&g_lock);
    }
    return p;
}

// ---- layer
HOOK(layer, nextd, id) {
    id d = orig_nextd(self, _cmd);
    pthread_mutex_lock(&g_lock);
    if (g_capturing) {
        CAMetalLayer *l = self;
        L("nextDrawable %p tex=%s layer size=%.0fx%.0f fmt=%lu fbOnly=%d maxDrawables=%lu sync=%d", d, tdesc([d texture]), l.drawableSize.width, l.drawableSize.height, (unsigned long)l.pixelFormat, l.framebufferOnly, (unsigned long)l.maximumDrawableCount, l.displaySyncEnabled);
    }
    pthread_mutex_unlock(&g_lock);
    return d;
}

static void swz(Class c, SEL s, IMP repl, IMP *orig) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) { fprintf(stderr, "mfx-probe: no %s on %s\n", sel_getName(s), class_getName(c)); return; }
    *orig = method_setImplementation(m, repl);
}
#define SWZ(cls, sel, name) swz(cls, @selector(sel), (IMP)repl_##name, (IMP *)&orig_##name)

__attribute__((constructor)) static void probe_init(void) {
    @autoreleasepool {
        g_libSrc = [NSMutableDictionary new]; g_funcLib = [NSMutableDictionary new];
        g_psoFuncs = [NSMutableDictionary new]; g_cpsoName = [NSMutableDictionary new]; g_funcName = [NSMutableDictionary new]; g_dumpedLibs = [NSMutableSet new];
        g_t0 = CFAbsoluteTimeGetCurrent();
        g_dir = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/bo3-mfx"] retain];
        [[NSFileManager defaultManager] createDirectoryAtPath:g_dir withIntermediateDirectories:YES attributes:nil error:nil];

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t;
        id re = [cb renderCommandEncoderWithDescriptor:rp]; Class reC = object_getClass(re); [re endEncoding];
        id be = [cb blitCommandEncoder]; Class beC = object_getClass(be); [be endEncoding];
        id ce = [cb computeCommandEncoder]; Class ceC = object_getClass(ce); [ce endEncoding];
        id lib = [dev newLibraryWithSource:@"#include <metal_stdlib>\nvertex float4 v(){return 0;}" options:nil error:nil];
        Class cbC = object_getClass(cb), devC = object_getClass(dev), libC = object_getClass(lib);

        SWZ(cbC, renderCommandEncoderWithDescriptor:, rce);
        SWZ(cbC, blitCommandEncoder, blit);
        SWZ(cbC, computeCommandEncoder, comp);
        SWZ(cbC, commit, commit);
        SWZ(cbC, presentDrawable:, present);
        SWZ(reC, setRenderPipelineState:, pso);
        SWZ(reC, setFragmentTexture:atIndex:, ftex);
        SWZ(reC, setFragmentTextures:withRange:, ftexs);
        SWZ(reC, setViewport:, vp);
        SWZ(reC, setVertexTexture:atIndex:, vtex);
        SWZ(reC, setVertexTextures:withRange:, vtexs);
        SWZ(reC, drawPrimitives:vertexStart:vertexCount:, dp);
        SWZ(reC, drawPrimitives:vertexStart:vertexCount:instanceCount:, dpi);
        SWZ(reC, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:, dip);
        SWZ(reC, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:, dipi);
        SWZ(reC, drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:, dipib);
        SWZ(reC, endEncoding, rend);
        SWZ(beC, copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:, copytt);
        SWZ(ceC, setTexture:atIndex:, ctex);
        SWZ(ceC, setComputePipelineState:, cpso);
        SWZ(devC, newComputePipelineStateWithFunction:error:, newcpso);
        SWZ(ceC, dispatchThreadgroups:threadsPerThreadgroup:, disp);
        SWZ(devC, newLibraryWithSource:options:error:, newlib);
        SWZ(libC, newFunctionWithName:, newfunc);
        SWZ(devC, newRenderPipelineStateWithDescriptor:error:, newpso);
        SWZ([CAMetalLayer class], nextDrawable, nextd);
        fprintf(stderr, "mfx-probe: cb=%s re=%s be=%s ce=%s dev=%s lib=%s\n", class_getName(cbC), class_getName(reC), class_getName(beC), class_getName(ceC), class_getName(devC), class_getName(libC));
    }
}
