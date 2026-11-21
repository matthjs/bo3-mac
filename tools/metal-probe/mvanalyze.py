"""Compare BO3's motion vectors with the measured image motion between
consecutive frames dumped by frameprobe (touch ~/Library/Logs/bo3-mfx-dump
while turning or strafing). Prints per-burst medians and a fit of measured
pixels per motion-vector unit (it came out at 20).

Usage: python3 mvanalyze.py ~/Library/Logs/bo3-mfx/dump  (needs numpy)
       python3 mvanalyze.py <dir> selftest   checks the shift estimator"""
import sys, numpy as np
D = sys.argv[1]
W, H = map(int, open(D + "/meta.txt").readline().split()[3].split("x"))
BS = 128  # block size


def f11(v):
    e = (v >> 6) & 31; m = v & 63
    return np.where(e == 0, m / 64.0 * 2.0 ** -14, (1 + m / 64.0) * 2.0 ** (e.astype(np.int32) - 15))


def f10(v):
    e = (v >> 5) & 31; m = v & 31
    return np.where(e == 0, m / 32.0 * 2.0 ** -14, (1 + m / 32.0) * 2.0 ** (e.astype(np.int32) - 15))


def lum(b, f):
    v = np.fromfile(f"{D}/b{b}_f{f}_color.raw", dtype=np.uint32).reshape(H, W)
    r, g, bl = f11(v & 0x7ff), f11((v >> 11) & 0x7ff), f10(v >> 22)
    return np.log(1 + 0.2126 * r + 0.7152 * g + 0.0722 * bl)


def vel(b, f):
    return np.fromfile(f"{D}/b{b}_f{f}_vel.raw", dtype=np.int16).reshape(H, W, 2) / 32767.0


def depth(b, f):
    return np.fromfile(f"{D}/b{b}_f{f}_depth.raw", dtype=np.float32).reshape(H, W)


def shift(a, b):
    """d such that b(x) ~= a(x - d): content moved by +d. Sub-pixel accurate:
    integer part from the phase-correlation peak, fraction from a weighted
    least-squares fit of the cross-spectrum phase slope at low frequencies."""
    win = np.outer(np.hanning(a.shape[0]), np.hanning(a.shape[1]))
    A = np.fft.fft2((a - a.mean()) * win); B = np.fft.fft2((b - b.mean()) * win)
    R = B * np.conj(A)
    c = np.real(np.fft.ifft2(R / (np.abs(R) + 1e-12)))
    py, px = np.unravel_index(np.argmax(c), c.shape)
    n0, n1 = c.shape
    ix = px - n1 if px > n1 / 2 else px
    iy = py - n0 if py > n0 / 2 else py
    ky = np.fft.fftfreq(n0)[:, None]; kx = np.fft.fftfreq(n1)[None, :]
    R2 = R * np.exp(2j * np.pi * (kx * ix + ky * iy))           # remove integer part
    m = (np.abs(kx) < 0.12) & (np.abs(ky) < 0.12) & ((kx != 0) | (ky != 0))
    ph = np.angle(R2)[m]; w = np.abs(R2)[m]
    X = np.stack([np.broadcast_to(kx, R.shape)[m], np.broadcast_to(ky, R.shape)[m]], axis=1) * (-2 * np.pi)
    W = w[:, None]
    sol = np.linalg.lstsq(X * np.sqrt(W), ph * np.sqrt(w), rcond=None)[0]
    return ix + sol[0], iy + sol[1], c.max()  # shift, and peak height as confidence


if sys.argv[2:] == ["selftest"]:
    a = np.random.rand(BS, BS)
    b = np.roll(a, (2, 5), axis=(0, 1))  # content moved +5 x, +2 y
    print("selftest", shift(a, b))
    sys.exit()

rows = []
for b in range(6):
    for f in range(3):
        L0, L1 = lum(b, f), lum(b, f + 1)
        V1 = vel(b, f + 1)
        Z1 = depth(b, f + 1)
        for by in range(BS // 2, H - BS, BS):
            for bx in range(BS // 2, W - BS, BS):
                s0, s1 = L0[by:by + BS, bx:bx + BS], L1[by:by + BS, bx:bx + BS]
                if s0.std() < 0.02: continue
                dx, dy, conf = shift(s0, s1)
                v = V1[by + 32:by + 96, bx + 32:bx + 96].reshape(-1, 2)
                rows.append((b, f, bx, by, dx, dy, conf, np.median(v[:, 0]), np.median(v[:, 1]), np.median(Z1[by:by + BS, bx:bx + BS])))
R = np.array(rows)
print("blocks:", len(R))
for b in range(6):
    S = R[(R[:, 0] == b) & (R[:, 6] > 0.15)]
    if len(S) == 0: print(f"burst {b}: no confident blocks"); continue
    print(f"burst {b}: n={len(S)} measured dx median {np.median(S[:,4]):+.2f} dy {np.median(S[:,5]):+.2f} px | vel x median {np.median(S[:,7]):+.5f} y {np.median(S[:,8]):+.5f}")
G = R[(R[:, 6] > 0.15) & (np.abs(R[:, 4]) > 0.3)]
print("\nconfident moving blocks:", len(G))
for r in G[np.argsort(np.abs(G[:, 4]))][:: max(1, len(G) // 25)]:
    vx, vy = r[7], r[8]
    print(f" b{int(r[0])} f{int(r[1])} ({int(r[2]):4d},{int(r[3]):3d}) meas {r[4]:+6.2f},{r[5]:+6.2f}px  vel {vx:+.5f},{vy:+.5f}  ratio x {r[4]/vx if abs(vx)>1e-5 else float('nan'):+9.1f}  z {r[9]:.5f}")
if len(G) > 3:
    vx = G[:, 7]; m = np.abs(vx) > 1e-4
    k = np.sum(G[m, 4] * vx[m]) / np.sum(vx[m] ** 2)
    res = G[m, 4] - k * vx[m]
    print(f"\nlinear fit dx = k*vx: k={k:+.1f} px/unit (=W*{k/W:+.4f}), rms residual {np.sqrt(np.mean(res**2)):.2f}px")
    sq = np.sign(vx[m]) * vx[m] ** 2
    k2 = np.sum(G[m, 4] * sq) / np.sum(sq ** 2)
    res2 = G[m, 4] - k2 * sq
    print(f"square fit dx = k*sign(v)v^2: k={k2:+.1f}, rms residual {np.sqrt(np.mean(res2**2)):.2f}px")
